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

local SERVER = os.getenv("KUSOGAKI_SERVER")
if not SERVER then
    print("skip  online: no KUSOGAKI_SERVER (tests/run.sh starts one when Go is installed)")
    return
end

local PORT = 26993

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
        port = port, bind = "127.0.0.1",
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

do
    local host = newHost(PORT)
    local code = openRoom(host)
    check("a host opens a room with a 6-digit code", code and code:match("^%d%d%d%d%d%d$") ~= nil, tostring(code))

    local direct = newClient(code)
    pump({ host, direct.client }, function() return direct.welcome or direct.closed end)
    check("a client joins by code, directly", direct.welcome and via(direct) == "127.0.0.1:" .. PORT,
        tostring(direct.closed) .. " " .. via(direct))

    local relayed = newClient(code, true)
    pump({ host, direct.client, relayed.client }, function() return relayed.welcome or relayed.closed end)
    check("relay only: the client connects through the relay", relayed.welcome and via(relayed) ~= "127.0.0.1:" .. PORT,
        tostring(relayed.closed) .. " " .. via(relayed))

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
    pump({ host, direct.client, relayed.client, fallback.client },
        function() return fallback.welcome or fallback.closed end, rendezvous.FALLBACK_SECONDS + 4)
    check("when direct fails the relay takes over", fallback.welcome
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

    for _, side in ipairs({ direct, relayed, fallback }) do side.client:close() end
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
    check("a relay-only host is reached only through the relay", got.welcome and via(got) ~= "127.0.0.1:" .. (PORT + 1),
        tostring(got.closed) .. " " .. via(got))
    got.client:close()
    host:close()
end
