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
    local long = { t = "reject", reason = ("ab"):rep(100) }
    local packed = protocol.encode(long)
    check("large messages travel compressed", packed:byte(1) == 255 and #packed < #wire.encode(long)
        and protocol.decode(packed, 1024).reason == long.reason)
    check("small messages stay plain", protocol.encode({ t = "left", id = 3 }) == wire.encode({ t = "left", id = 3 }))
    local raw = love.data.compress("string", "lz4", ("\0"):rep(100000))
    check("compressed messages are checked", protocol.decode("\255" .. raw, 1024) == nil
        and protocol.decode("\255\5\0\0\0", 1024) == nil
        and protocol.decode("\255" .. love.data.pack("string", "<I4", 10) .. raw:sub(5), 1024) == nil
        and protocol.decode(packed:sub(1, -4), 1024) == nil
        and protocol.decode(packed, 100) == nil)
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
            restart = function(message) got.restart = message end,
            joined = function(id) got.joined[#got.joined + 1] = id end,
            left = function(id) got.left[#got.left + 1] = id end,
            closed = function(reason) got.closed = reason end,
        }))
        return got
    end

    local first = newClient()
    pump({ host, first.client }, function() return first.welcome ~= nil end)
    check("a client joins: level, welcome with the seed, generation and players",
        first.level == "example" and first.welcome and first.welcome.you == 2 and first.welcome.seed == 4242
        and first.welcome.generation == 3 and #first.welcome.players == 2, tostring(first.closed))

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

-- ── The bad network simulator ────────────────────────────────────────────
do
    local level = Level.load("example", { seed = 4 })
    level:addPlayer(playerModule.new(100, 100))
    local votes, states = {}, 0
    local host = assert(session.host({
        port = PORT + 2, bind = "127.0.0.1",
        level = { name = "example", fingerprint = levelpack.fingerprint("levels/example") },
        handler = {
            accept = function() return 2 end,
            welcome = function() return { seed = 4, generation = 1, players = { 1, 2 } } end,
            left = function() end,
            vote = function(_, on) votes[#votes + 1] = { on = on, at = love.timer.getTime() } end,
            input = function() states = states + 1 end,
        },
    }))
    local joined = false
    local client = assert(session.join("127.0.0.1:" .. (PORT + 2), {
        level = function() return true end,
        welcome = function() joined = true end,
        closed = function() end,
    }))
    pump({ host, client }, function() return joined end)
    -- In one process both sides go through it: 150 ms each way, 5% each way.
    session.emulate(0.15, 0.05)
    love.math.setRandomSeed(12345) -- the simulator's losses repeat run to run
    local sentAt = love.timer.getTime()
    client:vote(true)
    pump({ host, client }, function() return #votes == 1 end)
    check("the simulator delays messages", votes[1] and votes[1].at - sentAt >= 0.14,
        votes[1] and string.format("%.3f s", votes[1].at - sentAt))
    for i = 1, 40 do
        client:vote(i % 2 == 0)
    end
    for i = 1, 55 do -- under the host's limit a second
        client:sendInput({ t = "input", g = 1, n = i, f = { 1, 0 }, k = 0 })
    end
    for _ = 1, 3 do -- reliable resends can take a few round trips
        pump({ host, client }, function() return #votes == 41 end)
    end
    local inOrder = #votes == 41
    for i = 2, #votes do
        inOrder = inOrder and votes[i].on == ((i - 1) % 2 == 0)
    end
    check("reliable messages all arrive, in order", inOrder, #votes)
    pump({ host, client }, function() return false end) -- let the late ones in (2 s)
    check("unreliable ones are lost now and then", states >= 40 and states < 55, states)
    session.emulate(0, 0)
    client:close()
    host:close()
end

-- ── Inputs (core/net/inputsync.lua) ─────────────────────────────────────
local inputsync = require("core.net.inputsync")
local input = require("core.input")
local statesync = require("core.net.statesync")
local fullstate = require("core.level.fullstate")
do
    local own = inputsync.client()
    for t = 1, 20 do inputsync.record(own, t, t % 4) end
    local message = inputsync.message(own, 20)
    check("an input message repeats the last ticks", message.n == 20 and #message.f == inputsync.REDUNDANCY
        and message.f[#message.f] == 0 and message.f[#message.f - 1] == 3)
    message.g, message.k = 1, 0
    check("input messages are checked", protocol.decode(protocol.encode(message), 1024) ~= nil
        and protocol.decode(wire.encode({ t = "input", g = 1, n = 5, f = { -1 }, k = 0 }), 1024) == nil
        and protocol.decode(wire.encode({ t = "input", g = 1, n = 5, f = { 1, 2, 3, 4, 5, 6, 7, 8, 9 }, k = 0 }),
            1024) == nil)

    local host = inputsync.host()
    inputsync.addPlayer(host, 2)
    inputsync.receive(host, 2, { n = 12, f = { 5, 6, 7 } }, 10) -- ticks 10 (too late), 11, 12
    check("the host uses each tick's input", inputsync.take(host, 2, 11) == 6 and inputsync.take(host, 2, 12) == 7)
    check("a missing input repeats the last one", inputsync.take(host, 2, 13) == 7)
    check("inputs for ticks already run are dropped", host.players[2].frames[10] == nil
        and inputsync.newest(host, 2) == 12)
end

-- ── Host state to clients (core/net/statesync.lua) ──────────────────────
do
    local function newLevel()
        local level = Level.load("example", { seed = 5 })
        level:addPlayer(playerModule.new(level.spawn.x, level.spawn.y))
        level:addPlayer(playerModule.new(level.spawn.x + 20, level.spawn.y))
        return level
    end
    local function hashOf(level)
        return statesync.hashOf(statesync.flatten(fullstate.capture(level)))
    end
    local hostLevel, clientLevel = newLevel(), newLevel()
    local function step(ticks)
        for i = 1, ticks do
            hostLevel.players[1].input = { right = true, jump = i % 40 < 15, kick = i % 50 == 0 }
            hostLevel.players[2].input = { right = true, hold = i % 90 < 30 }
            hostLevel:update(1 / 60)
            hostLevel:takeEvents()
        end
    end
    local function through(message)
        message.g, message.ack, message.inp, message.vt, message.cd = 1, 0, {}, {}, false
        return protocol.decode(protocol.encode(message), protocol.MAX_HOST_MESSAGE)
    end
    local host, client = statesync.host(), statesync.client()
    statesync.addClient(host, 2)
    step(60)
    local entry = statesync.record(host, 60, fullstate.capture(hostLevel))
    local message, full = statesync.messageFor(host, 2, entry, 0)
    local fullBytes = #protocol.encode(through(message))
    check("a client without a base gets the full state", full and message.base == 0)
    local state, h = statesync.receive(client, through(message))
    fullstate.restore(clientLevel, state)
    check("the client's level becomes the host's (hash)", h == 60 and hashOf(clientLevel) == hashOf(hostLevel))
    statesync.acknowledge(host, 2, statesync.ack(client))

    step(90)
    entry = statesync.record(host, 150, fullstate.capture(hostLevel))
    message, full = statesync.messageFor(host, 2, entry, 2)
    check("after its ack the client gets a delta", not full and message.base == 60)
    state = statesync.receive(client, through(message))
    fullstate.restore(clientLevel, state)
    check("deltas keep the client's level equal to the host's", hashOf(clientLevel) == hashOf(hostLevel))
    statesync.acknowledge(host, 2, statesync.ack(client))
    step(3)
    entry = statesync.record(host, 153, fullstate.capture(hostLevel))
    message = statesync.messageFor(host, 2, entry, 3)
    local deltaBytes = #protocol.encode(through(message))
    print(string.format("      state: full %d bytes, delta over 3 ticks %d bytes", fullBytes, deltaBytes))
    check("a delta over 3 ticks is much smaller than the full state", deltaBytes * 3 < fullBytes, deltaBytes)
    local copy = through(message)
    check("an old state is ignored", statesync.receive(client, through(message)) ~= nil
        and select(2, statesync.receive(client, copy)) == "old")
    local tampered = through(message)
    tampered.h, tampered.hash = tampered.h + 3, ("0"):rep(16)
    check("a hash mismatch asks for a full state", select(2, statesync.receive(client, tampered)) == "hash"
        and statesync.ack(client) == 0)
end

-- ── The gameplay scene as host, with a client over localhost ─────────────
do
    local gameplay = require("scenes.gameplay")
    gameplay.configure({ mode = "host", port = PORT + 1, bind = "127.0.0.1", level = "example" })
    gameplay.load()
    check("the scene hosts a session", gameplay.getNetwork() ~= nil)
    gameplay.setSource(1, { read = function() return {} end })
    local got = { snaps = {} }
    local client = assert(session.join("127.0.0.1:" .. (PORT + 1), {
        level = function() return true end,
        welcome = function(message) got.welcome = message end,
        restart = function() end,
        joined = function() end,
        left = function() end,
        snap = function(message) got.snaps[#got.snaps + 1] = message end,
        closed = function(reason) got.closed = reason end,
    }))
    local function run(frames, done)
        for _ = 1, frames do
            gameplay.update(1 / 60)
            client:service()
            if done and done() then return true end
            love.timer.sleep(0.002)
        end
        return false
    end
    run(400, function() return got.welcome ~= nil and #got.snaps > 0 end)
    check("a joined client gets the host's full state", got.snaps[1] and got.snaps[1].base == 0
        and #got.snaps[1].set > 100, tostring(got.closed))
    local level = gameplay.getLevel()
    local remote
    for _, player in ipairs(level.players) do
        if player.id == got.welcome.you then remote = player end
    end
    check("the client's player is simulated on the host", remote and not remote.remote and not remote.immovable)

    -- The client holds right: the host moves its player from those inputs.
    local names = level.actionNames
    local right = input.pack({ right = true }, names)
    local own = inputsync.client()
    local startX = remote.x
    local hostTick = gameplay.getTick()
    local t = hostTick + 3
    local early = -math.huge
    for _ = 1, 60 do
        t = t + 1
        local snap = got.snaps[#got.snaps]
        early = math.max(early, snap.ack - snap.h)
        inputsync.record(own, t, right)
        local message = inputsync.message(own, t)
        message.g, message.k = got.welcome.generation, got.snaps[#got.snaps].h
        client:sendInput(message)
        run(1)
    end
    run(20)
    check("the host moves the client's player from its inputs", remote.x > startX + 40,
        string.format("%.1f -> %.1f", startX, remote.x))
    local last = got.snaps[#got.snaps]
    local usedRight = false
    for _, entry in ipairs(last.inp) do
        if entry[1] == got.welcome.you and entry[2] == right then usedRight = true end
    end
    check("states carry the input each player used", usedRight)
    check("after acknowledging, the client gets deltas", last.base > 0 and #last.set < #got.snaps[1].set)
    check("states tell how early its inputs arrive", early >= 1, early)

    client:close()
    run(60)
    check("the scene notices the client leaving", #gameplay.getLevel().players == 1)
    gameplay.closeNetwork()
    gameplay.configure({ mode = nil })
end
