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

-- The lobby: typing a code and a server, the relay switch, starting.
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

    lobby.open("join")
    check("the lobby remembers the server", lobby.state().settings.server == "10.0.0.9:4000")
    lobby.textinput("12a34")
    lobby.textinput("5678")
    check("a room code takes 6 digits only", lobby.state().code == "123456", lobby.state().code)
    lobby.keypressed("backspace")
    lobby.textinput("9")
    check("backspace erases a digit", lobby.state().code == "123459")
    lobby.keypressed("down")
    lobby.keypressed("return")
    check("the relay switch toggles and is kept", lobby.state().settings.relayOnly
        and files["online.txt"]:match("relayOnly=1") ~= nil)
    lobby.keypressed("down")
    for _ = 1, 20 do lobby.keypressed("backspace") end
    lobby.keypressed("down")
    check("no server: the lobby says so", lobby.keypressed("return") == nil
        and lobby.state().notice ~= nil)
    lobby.keypressed("up")
    lobby.textinput("127.0.0.1:9")
    lobby.keypressed("down")
    local nextScene = lobby.keypressed("return")
    check("join starts network play as a client of that room", nextScene == "gameplay"
        and gameplay.getMode() == "client" and gameplay.getNetwork() ~= nil
        and files["online.txt"]:match("server=127.0.0.1:9") ~= nil, tostring(nextScene))
    gameplay.closeNetwork()
    gameplay.configure({})
    gameplay.load()
    check("back to playing alone", gameplay.getMode() == nil and gameplay.getNetwork() == nil)

    lobby.open("host")
    check("the host screen has no code field", lobby.state().selected == 1
        and lobby.keypressed("escape") == "menu")
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
    check("relay only: the client connects through the relay", relayed(viaRelay, PORT),
        tostring(viaRelay.closed) .. " " .. via(viaRelay))

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
