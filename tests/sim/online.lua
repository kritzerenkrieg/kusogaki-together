-- Internet play (Phase 3): rooms on our rendezvous server, joining by code,
-- direct connections, the relay and the fallback to it. Needs the server:
-- tests/run.sh builds and starts one and names it in KUSOGAKI_SERVER;
-- without it only the offline checks run.
local helpers = require("tests.sim.helpers")
local check = helpers.check
local session = require("core.net.session")
local rendezvous = require("core.net.rendezvous")
local version = require("core.version")

do
    check("server addresses", rendezvous.resolve("127.0.0.1") == "127.0.0.1"
        and select(2, rendezvous.resolve("127.0.0.1")) == rendezvous.PORT
        and select(2, rendezvous.resolve("10.0.0.1:4000")) == 4000
        and rendezvous.resolve("a b") == nil and rendezvous.resolve(nil) == nil)
    local enet = require("enet")
    local socketHost = enet.host_create(nil, 2, 3)
    check("a room code is 6 digits", rendezvous.join({ server = "127.0.0.1", code = "12345", enet = socketHost,
        protocol = version.PROTOCOL }) == nil)
    socketHost:destroy()
end

-- Multiplayer: the room list, creating a room, joining by room ID.
do
    local lobby = require("scenes.lobby")
    local gameplay = require("scenes.gameplay")
    local files = {}
    local realRead, realWrite = love.filesystem.read, love.filesystem.write
    love.filesystem.read = function(name, ...)
        if name == "online.txt" then return files[name] end
        return realRead(name, ...)
    end
    love.filesystem.write = function(name, data, ...)
        if name == "online.txt" then files[name] = data return true end
        return realWrite(name, data, ...)
    end
    files["online.txt"] = "server=10.0.0.9:4000\nrelayOnly=0\n"

    lobby.open()
    local state = lobby.state()
    check("Multiplayer opens the room list on the remembered server", state.page == "list"
        and state.settings.server == "10.0.0.9:4000" and state.browser ~= nil)
    check("an old online.txt gets the defaults", state.settings.public and state.settings.dropIn
        and not state.settings.relayOnly)

    lobby.keypressed("return") -- Create room (no rooms listed)
    check("the room list draws", pcall(lobby.draw))
    check("Create room opens its page", lobby.state().page == "create")
    check("the create page draws", pcall(lobby.draw))
    lobby.textinput("Friday\tfun")
    check("the room name takes printable text", lobby.state().settings.roomName == "Fridayfun",
        lobby.state().settings.roomName)
    lobby.keypressed("down")
    lobby.keypressed("return")
    lobby.keypressed("down")
    lobby.keypressed("down")
    lobby.keypressed("return")
    check("the switches toggle and are kept", not lobby.state().settings.public
        and lobby.state().settings.relayOnly and files["online.txt"]:match("public=0") ~= nil
        and files["online.txt"]:match("relayOnly=1") ~= nil)
    check("Esc goes back to the list", lobby.keypressed("escape") == nil and lobby.state().page == "list")

    lobby.keypressed("down")
    lobby.keypressed("return") -- Join by room ID
    check("Join by room ID opens its page", lobby.state().page == "code")
    lobby.textinput("12a34")
    lobby.textinput("5678")
    check("a room ID takes 6 digits only", lobby.state().code == "123456", lobby.state().code)
    lobby.keypressed("backspace")
    lobby.textinput("9")
    check("backspace erases a digit", lobby.state().code == "123459")
    lobby.keypressed("down")
    local nextScene = lobby.keypressed("return")
    check("joining goes to the waiting room as a client", nextScene == "room"
        and gameplay.getMode() == "client" and gameplay.getNetwork() ~= nil, tostring(nextScene))
    gameplay.closeNetwork()

    lobby.open()
    lobby.state().settings.server = ""
    lobby.keypressed("return")
    for _ = 1, 4 do lobby.keypressed("down") end
    check("no server: Create says so", lobby.keypressed("return") == nil and lobby.state().notice ~= nil)
    check("back on the list, Esc goes to the menu", lobby.keypressed("escape") == nil
        and lobby.keypressed("escape") == "menu")
    gameplay.configure({})
    gameplay.load()
    check("back to playing alone", gameplay.getMode() == nil and gameplay.getNetwork() == nil)
    love.filesystem.read, love.filesystem.write = realRead, realWrite
end

local SERVER = os.getenv("KUSOGAKI_SERVER")
if not SERVER then
    print("skip  online: no KUSOGAKI_SERVER (tests/run.sh starts one when Go is installed)")
    return
end

local PORT = 26993
-- A server on this machine: everything on loopback. A remote one (for example
-- KUSOGAKI_SERVER=<vps> love . --sim-test): bind every interface so probes reach it.
local SERVER_IP = rendezvous.resolve(SERVER)
local BIND = SERVER_IP == "127.0.0.1" and "127.0.0.1" or "*"

local function pump(sides, done, seconds)
    local deadline = love.timer.getTime() + (seconds or 3)
    while love.timer.getTime() < deadline do
        for _, side in ipairs(sides) do
            side:service()
        end
        if done() then
            return true
        end
        love.timer.sleep(0.005)
    end
    return false
end

local function newHost(port, relayOnly)
    return assert(session.host({
        port = port, bind = BIND,
        level = { name = "example", fingerprint = ("ab"):rep(32) },
        rendezvous = { server = SERVER, relayOnly = relayOnly },
        handler = {
            accept = function() return 2 end,
            welcome = function() return { seed = 7, generation = 1, players = { 1, 2 } } end,
            left = function() end,
        },
    }))
end

local function newClient(code, relayOnly)
    local got = {}
    got.client = assert(session.join(nil, {
        level = function() return true end,
        welcome = function(message) got.welcome = message end,
        restart = function() end, joined = function() end, left = function() end, snap = function() end,
        closed = function(reason) got.closed = reason end,
    }, { rendezvous = { server = SERVER, code = code, relayOnly = relayOnly } }))
    return got
end

local function openRoom(host)
    pump({ host }, function() return host:room() ~= nil end)
    return (host:room())
end

local function via(got)
    return tostring(got.client.peer)
end

-- Through the relay: the peer is a relay port on the server, not the host's port.
local function relayed(got, hostPort)
    local ip, port = via(got):match("^(.+):(%d+)$")
    return got.welcome ~= nil and ip == SERVER_IP and tonumber(port) ~= hostPort
end

do
    local host = newHost(PORT)
    local code = openRoom(host)
    check("a host opens a room with a 6-digit code", code and code:match("^%d%d%d%d%d%d$") ~= nil, tostring(code))

    local direct = newClient(code)
    pump({ host, direct.client }, function() return direct.welcome or direct.closed end)
    check("a client joins by code, directly", direct.welcome and not relayed(direct, PORT),
        tostring(direct.closed) .. " " .. via(direct))

    local viaRelay = newClient(code, true)
    pump({ host, direct.client, viaRelay.client }, function() return viaRelay.welcome or viaRelay.closed end)
    check("only the host chooses the relay: a client asking for it connects directly",
        viaRelay.welcome and not relayed(viaRelay, PORT), tostring(viaRelay.closed) .. " " .. via(viaRelay))

    -- Direct attempts that cannot work: after FALLBACK_SECONDS the relay.
    local realJoin = rendezvous.join
    rendezvous.join = function(options)
        local room = realJoin(options)
        local realUpdate = room.update
        room.update = function(self, now, connected)
            local actions = realUpdate(self, now, connected)
            for _, action in ipairs(actions) do
                if action.data == 0 then
                    action.address = "127.0.0.1:9"
                end
            end
            return actions
        end
        return room
    end
    local fallback = newClient(code)
    rendezvous.join = realJoin
    local started = love.timer.getTime()
    pump({ host, direct.client, viaRelay.client, fallback.client },
        function() return fallback.welcome or fallback.closed end, rendezvous.FALLBACK_SECONDS + 4)
    check("when direct fails the relay takes over", relayed(fallback, PORT)
        and love.timer.getTime() - started >= rendezvous.FALLBACK_SECONDS,
        tostring(fallback.closed) .. " " .. via(fallback))

    local wrong = newClient(code == "000000" and "000001" or "000000")
    pump({ wrong.client }, function() return wrong.closed end)
    check("a wrong code says so", wrong.closed == "no such room", tostring(wrong.closed))

    local realProtocol = version.PROTOCOL
    version.PROTOCOL = realProtocol + 1
    local other = newClient(code)
    version.PROTOCOL = realProtocol
    pump({ host, other.client }, function() return other.closed end)
    check("another protocol is refused before connecting", other.closed and other.closed:match("version") ~= nil,
        tostring(other.closed))

    for _, side in ipairs({ direct, viaRelay, fallback }) do side.client:close() end
    host:close()
    local late = newClient(code)
    pump({ late.client }, function() return late.closed end)
    check("a closed room is gone", late.closed == "no such room", tostring(late.closed))
end

-- The room list: a public room shows with its info, a private one does not.
do
    local host = newHost(PORT + 2)
    local hidden = newHost(PORT + 3)
    local code = openRoom(host)
    openRoom(hidden)
    host:setRoomInfo({ players = 2, playing = true, dropIn = false, public = true, level = "example",
        name = "  Friday\n night " })
    hidden:setRoomInfo({ players = 1, playing = false, dropIn = true, public = false, level = "example", name = "Secret" })
    local browser = assert(rendezvous.browse(SERVER, version.PROTOCOL))
    local found
    local deadline = love.timer.getTime() + 3
    while love.timer.getTime() < deadline and not found do
        host:service()
        hidden:service()
        browser:update(love.timer.getTime())
        for _, entry in ipairs(browser.rooms) do
            if entry.code == code and entry.name == "Friday night" then found = entry end
        end
        love.timer.sleep(0.01)
    end
    check("the room list shows a public room's name, level, players and state", found and found.players == 2
        and found.level == "example" and found.playing and not found.dropIn and not found.relay)
    local listed = false
    for _, entry in ipairs(browser.rooms) do
        if entry.name == "Secret" then listed = true end
    end
    check("a private room is not listed", not listed)
    local late = newClient(code)
    pump({ host, late.client }, function() return late.closed end)
    check("a playing room without drop-in refuses joins", late.closed == "the game has already started",
        tostring(late.closed))
    browser:close()
    host:close()
    hidden:close()
end

do
    local host = newHost(PORT + 1, true)
    local code = openRoom(host)
    local got = newClient(code)
    pump({ host, got.client }, function() return got.welcome or got.closed end)
    check("a relay-only host is reached only through the relay", relayed(got, PORT + 1),
        tostring(got.closed) .. " " .. via(got))
    got.client:close()
    host:close()
end

-- A client in a room without the room's level gets it from the server (the
-- level repository), then tells the host it has it. A host whose level is
-- not on the server is told players cannot get it. Uploads only to a test
-- server: the real one's list is public.
if SERVER_IP == "127.0.0.1" then
    local gameplay = require("scenes.gameplay")
    local levels = require("core.levels")
    local levelpack = require("core.levelpack")
    local repo = require("core.net.repo")
    local json = require("core.json")

    -- A level of its own (the top-down level under another name), on the server only.
    local function makeLevel(name)
        levelpack.removeTree("levels/" .. name)
        love.filesystem.createDirectory("levels/" .. name)
        for _, entry in ipairs(assert(levelpack.unpack((levelpack.pack("builtin/topdown"))))) do
            local data = entry.data
            if entry.path == "level.json" then
                local decoded = json.decode(data)
                decoded.name = name
                data = json.encode(decoded)
            end
            love.filesystem.createDirectory(("levels/%s/%s"):format(name, entry.path):match("^(.*)/"))
            love.filesystem.write(("levels/%s/%s"):format(name, entry.path), data)
        end
        levels.refresh()
        return levelpack.fingerprint("levels/" .. name)
    end
    local id = makeLevel("roomdl")
    local uploaded = repo.upload(SERVER, "levels/roomdl", "Tester"):wait()
    levelpack.removeTree("levels/roomdl")
    levels.refresh()
    check("the room's level is on the server, not here", uploaded and levels.byId(id) == nil)

    local has = nil
    local host = assert(session.host({
        port = PORT + 2, bind = BIND,
        rendezvous = { server = SERVER },
        handler = {
            accept = function() return 2 end,
            welcome = function() end,
            has = function(_, fp) has = fp end,
            left = function() end,
        },
    }))
    local code = openRoom(host)
    gameplay.configure({ mode = "client", name = "Dl", online = { server = SERVER, code = code } })
    gameplay.load()
    local sentRoom = false
    local function step()
        host:service()
        gameplay.update(1 / 60)
        if not sentRoom then -- once the client is in
            sentRoom = host:sendTo(2, { t = "room", name = "Dl room", code = code, level = "roomdl", fp = id,
                st = "waiting", cd = 0, di = true, pub = true, relay = false,
                players = { { id = 1, name = "Host", has = true }, { id = 2, name = "Dl", has = false } } })
        end
    end
    local sawDownloading = false
    local deadline = love.timer.getTime() + 8
    while love.timer.getTime() < deadline and has ~= id do
        step()
        sawDownloading = sawDownloading or (gameplay.levelStatus() or ""):find("Downloading") ~= nil
        love.timer.sleep(0.005)
    end
    check("a client without the room's level downloads it", levels.byId(id) and levels.byId(id).downloaded,
        tostring(gameplay.levelStatus()))
    check("... says so in the room meanwhile", sawDownloading)
    check("... and then tells the host it has it", has == id, tostring(has))
    local roomScene = require("scenes.room")
    local lines = roomScene.settingLines() or {}
    check("a player in the room sees the host's settings", lines[1] == "Level: roomdl"
        and lines[2] == "Drop-in: On" and lines[3] == "Public: On" and lines[4] == "Connection: direct",
        table.concat(lines, ", "))
    check("the waiting room draws (client)", pcall(roomScene.draw))
    check("... with Leave as its only item", roomScene.keypressed("down") == nil
        and roomScene.keypressed("up") == nil)
    gameplay.closeNetwork()
    host:close()
    levels.remove("downloads/" .. id)

    local missingId = makeLevel("nothere")
    gameplay.configure({ mode = "host", port = PORT + 4, bind = BIND, level = "nothere", name = "Hosty",
        online = { server = SERVER }, room = { name = "Lonely", public = false, dropIn = true } })
    gameplay.load()
    local warned
    deadline = love.timer.getTime() + 5
    while love.timer.getTime() < deadline and not warned do
        gameplay.update(1 / 60)
        local line, warning = gameplay.levelStatus()
        warned = warning and line and line:find("not on the server") and line
        love.timer.sleep(0.005)
    end
    check("a host whose level is not on the server is told", warned ~= nil and levelpack.isId(missingId))
    gameplay.closeNetwork()
    levelpack.removeTree("levels/nothere")
    levels.refresh()
    gameplay.configure({})
    gameplay.load()
end
