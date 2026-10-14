-- Network sessions (core/net): the join handshake, refusals, session messages
-- and leaving, with a host and clients in one process over localhost.
local helpers = require("tests.sim.helpers")
local check = helpers.check
local protocol = require("core.net.protocol")
local session = require("core.net.session")
local version = require("core.version")
local levelpack = require("core.levelpack")
local netstate = require("core.level.netstate")
local wire = require("core.wire")
local Level = require("core.level")
local playerModule = require("core.player")

local PORT = 26990 -- not the game's port, so a running game does not interfere

-- Run both sides until `done()` or about 2 s.
local function pump(sides, done)
    for _ = 1, 400 do
        for _, side in ipairs(sides) do
            side:service()
        end
        if done and done() then
            return true
        end
        love.timer.sleep(0.005)
    end
    return done == nil
end

-- ── Messages ──────────────────────────────────────────────────────────────
do
    check("a well-formed message decodes", protocol.decode(protocol.encode({ t = "left", id = 3 }), 100).id == 3)
    local function refused(message)
        return protocol.decode(wire.encode(message), 1000) == nil
    end
    check("bad messages are refused", refused({ t = "left", id = 9 }) and refused({ t = "nope" })
        and refused({ t = "left", id = 2, extra = true }) and refused("text")
        and refused({ t = "welcome", you = 1, seed = 0, generation = 0, players = {} })
        and refused({ t = "restart", seed = 5, generation = 1, players = { 1, 1 } }))
    check("garbage bytes are refused", protocol.decode("\7\255\255\255\255", 100) == nil
        and protocol.decode(("x"):rep(2000), 1024) == nil)
    check("addresses", protocol.address("192.168.1.5") == "192.168.1.5:26967"
        and protocol.address("localhost:4000") == "localhost:4000"
        and protocol.address("a b") == nil and protocol.address("1.2.3.4:99999") == nil)
    check("the default port is 26967", protocol.PORT == 26967)
end

-- ── Level fingerprints ───────────────────────────────────────────────────
do
    local a, b = levelpack.fingerprint("levels/example"), levelpack.fingerprint("levels/example")
    check("a bundled level's fingerprint is stable", a == b and #a == 64)
    check("different levels differ", a ~= levelpack.fingerprint("levels/topdown"))
    check("an online package's fingerprint is its hash", levelpack.fingerprint("online/" .. ("ab"):rep(32))
        == ("ab"):rep(32))
end

-- ── Host and clients ──────────────────────────────────────────────────────
do
    local level = Level.load("example", { seed = 4242 })
    level:addPlayer(playerModule.new(100, 100))
    local fingerprint = levelpack.fingerprint("levels/example")
    local generation = 3
    local left = {}
    local host = assert(session.host({
        port = PORT,
        bind = "127.0.0.1",
        level = { name = "example", fingerprint = fingerprint },
        handler = {
            accept = function()
                if #level.players >= Level.MAX_PLAYERS then
                    return nil, "session is full"
                end
                return #level.players + 1
            end,
            welcome = function(id)
                level:addPlayer(playerModule.new(200, 100), id)
                local ids = {}
                for _, player in ipairs(level.players) do ids[#ids + 1] = player.id end
                return { seed = level.seed, generation = generation, players = ids }
            end,
            snapshot = function()
                return { generation = generation, data = netstate.pack(netstate.snapshot(level, 7)) }
            end,
            left = function(id) left[#left + 1] = id end,
        },
    }))
    check("a second host cannot take the same port", session.host({ port = PORT, bind = "127.0.0.1",
        level = { name = "example", fingerprint = fingerprint }, handler = {} }) == nil)

    -- A client that records what it gets.
    local function newClient(options)
        options = options or {}
        local got = { joined = {}, left = {} }
        got.client = assert(session.join("127.0.0.1:" .. PORT, {
            level = function(name, print)
                got.level = name
                if options.wrongLevel then return false, "missing level" end
                return true
            end,
            welcome = function(message) got.welcome = message end,
            snapshot = function(message) got.snapshot = message end,
            restart = function(message) got.restart = message end,
            joined = function(id) got.joined[#got.joined + 1] = id end,
            left = function(id) got.left[#got.left + 1] = id end,
            closed = function(reason) got.closed = reason end,
        }))
        return got
    end

    local first = newClient()
    pump({ host, first.client }, function() return first.snapshot ~= nil end)
    check("a client joins: level, welcome with the seed, generation and players",
        first.level == "example" and first.welcome and first.welcome.you == 2 and first.welcome.seed == 4242
        and first.welcome.generation == 3 and #first.welcome.players == 2, tostring(first.closed))
    local expected = netstate.snapshot(level, 7)
    local received = first.snapshot and netstate.unpack(first.snapshot.data)
    check("the join's full snapshot arrives intact", received and received.tick == 7
        and #received.players == #expected.players and #received.entities == #expected.entities
        and received.entities[5].x == expected.entities[5].x and received.players[2].id == 2)

    local second = newClient()
    pump({ host, first.client, second.client }, function() return second.welcome ~= nil and #first.joined == 1 end)
    check("others hear about a new player", second.welcome and second.welcome.you == 3 and first.joined[1] == 3)

    host:broadcast({ t = "restart", seed = 99, generation = 4, players = { 1, 2, 3 } })
    pump({ host, first.client, second.client }, function() return first.restart and second.restart end)
    check("restart{seed} reaches every client", first.restart and first.restart.seed == 99
        and second.restart and second.restart.generation == 4)

    local wrong = newClient({ wrongLevel = true })
    pump({ host, wrong.client }, function() return wrong.closed ~= nil end)
    check("a client without the level stops with a reason", wrong.closed == "missing level")

    -- A client with a different game version is refused by the host.
    local realGame = version.GAME
    version.GAME = "0.0.0-other" -- the host keeps the version it opened with
    local old = newClient()
    pump({ host, old.client }, function() return old.closed ~= nil end)
    version.GAME = realGame
    check("a different game version is refused", old.closed and old.closed:find("version mismatch") ~= nil,
        tostring(old.closed))

    -- Garbage from a connected peer gets it refused, not the host crashed.
    local enet = require("enet")
    local raw = enet.host_create(nil, 1, protocol.CHANNELS)
    local rawPeer = raw:connect("127.0.0.1:" .. PORT, protocol.CHANNELS)
    local rawClosed = false
    for _ = 1, 400 do
        host:service()
        local event = raw:service(0)
        if event and event.type == "connect" then
            rawPeer:send("\8\255\255\255\127garbage", protocol.RELIABLE)
        elseif event and event.type == "disconnect" then
            rawClosed = true
            break
        end
        love.timer.sleep(0.005)
    end
    check("a peer sending garbage is dropped", rawClosed)
    raw:destroy()

    second.client:close()
    pump({ host, first.client }, function() return #left == 1 and #first.left == 1 end)
    check("leaving is noticed by the host and the others", left[1] == 3 and first.left[1] == 3)

    host:close()
    pump({ first.client }, function() return first.closed ~= nil end)
    check("the host ending the session closes clients with a reason", first.closed == "the host ended the session",
        tostring(first.closed))
    first.client:close()
end
