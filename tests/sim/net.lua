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
        and refused({ t = "welcome", you = 9 })
        and refused({ t = "restart", seed = 5, generation = 1, players = { 1, 1 } })
        and refused({ t = "hello", protocol = 9, game = "x", name = "new\nline" })
        and refused({ t = "has", fp = "abc" })
        and refused({ t = "room", name = "r", code = "12345", level = "example", fp = ("ab"):rep(32), st = "waiting",
            cd = 0, di = true, pub = true, relay = false, players = {} })
        and refused({ t = "room", name = "r", code = "", level = "example", fp = ("ab"):rep(32), st = "waiting",
            cd = 0, di = true, pub = true, relay = false, players = { { id = 1, name = "a", has = "yes" } } }))
    check("room messages decode", protocol.decode(protocol.encode({ t = "room", name = "Bob's room", code = "123456",
        level = "example", fp = ("ab"):rep(32), st = "countdown", cd = 3, di = false, pub = true, relay = true,
        players = { { id = 1, name = "Bob", has = true }, { id = 2, name = "Al", has = false } } }), 1000) ~= nil
        and protocol.decode(protocol.encode({ t = "start", level = "example", fp = ("ab"):rep(32), seed = 4,
        generation = 2, players = { 1, 2 } }), 1000) ~= nil)
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
    check("a level's fingerprint is stable", a == b and #a == 64)
    check("... and the same as the built-in level it was copied from", a == levelpack.fingerprint("builtin/example"))
    check("different levels differ", a ~= levelpack.fingerprint("levels/topdown"))
    check("a download's fingerprint is its id", levelpack.fingerprint("downloads/" .. ("ab"):rep(32))
        == ("ab"):rep(32))
end

-- ── Host and clients ──────────────────────────────────────────────────────
do
    local level = Level.load("example", { seed = 4242 })
    level:addPlayer(playerModule.new(100, 100))
    local fingerprint = levelpack.fingerprint("levels/example")
    local generation = 3
    local left, names, has = {}, {}, {}
    local host = assert(session.host({
        port = PORT,
        bind = "127.0.0.1",
        handler = {
            accept = function()
                if #level.players >= Level.MAX_PLAYERS then
                    return nil, "session is full"
                end
                return #level.players + 1
            end,
            welcome = function(id, name)
                level:addPlayer(playerModule.new(200, 100), id)
                names[id] = name
            end,
            has = function(id, fp) has[id] = fp end,
            left = function(id) left[#left + 1] = id end,
        },
    }))
    check("a second host cannot take the same port", session.host({ port = PORT, bind = "127.0.0.1",
        handler = {} }) == nil)

    -- A client that records what it gets.
    local function newClient(options)
        options = options or {}
        local got = { joined = {}, left = {} }
        got.client = assert(session.join("127.0.0.1:" .. PORT, {
            welcome = function(message) got.welcome = message end,
            restart = function(message) got.restart = message end,
            joined = function(id) got.joined[#got.joined + 1] = id end,
            left = function(id) got.left[#got.left + 1] = id end,
            closed = function(reason) got.closed = reason end,
        }, { name = options.name }))
        return got
    end

    local first = newClient({ name = "Ann" })
    pump({ host, first.client }, function() return first.welcome ~= nil end)
    check("a client joins: welcome with its player id, the host learns its name",
        first.welcome and first.welcome.you == 2 and names[2] == "Ann", tostring(first.closed))
    first.client:has(fingerprint)
    pump({ host, first.client }, function() return has[2] ~= nil end)
    check("a client tells the host which level copy it has", has[2] == fingerprint)

    local second = newClient()
    pump({ host, first.client, second.client }, function() return second.welcome ~= nil end)
    check("a second client gets the next id", second.welcome and second.welcome.you == 3 and names[3] == "")

    host:broadcast({ t = "restart", seed = 99, generation = 4, players = { 1, 2, 3 } })
    pump({ host, first.client, second.client }, function() return first.restart and second.restart end)
    check("restart{seed} reaches every client", first.restart and first.restart.seed == 99
        and second.restart and second.restart.generation == 4)

    host:kick(3, "you do not have the host's level")
    pump({ host, first.client, second.client }, function() return second.closed ~= nil and #first.left == 1 end)
    check("a kicked client stops with the reason, the others hear it left",
        second.closed == "you do not have the host's level" and first.left[1] == 3 and left[1] == 3)
    second = newClient()
    pump({ host, first.client, second.client }, function() return second.welcome ~= nil end)

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
    pump({ host, first.client }, function() return #left == 2 and #first.left == 2 end)
    check("leaving is noticed by the host and the others", left[2] == 4 and first.left[2] == 4,
        tostring(left[2]) .. " " .. tostring(first.left[2]))

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
        handler = {
            accept = function() return 2 end,
            welcome = function() end,
            left = function() end,
            vote = function(_, on) votes[#votes + 1] = { on = on, at = love.timer.getTime() } end,
            input = function() states = states + 1 end,
        },
    }))
    local joined = false
    local client = assert(session.join("127.0.0.1:" .. (PORT + 2), {
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

    -- Forwarding to the other clients: what the host used, then what it has
    -- for its next ticks.
    inputsync.receive(host, 2, { n = 17, f = { 8, 9, 9, 1 } }, 13) -- ticks 14..17
    inputsync.take(host, 2, 14)
    local n, f = inputsync.forward(host, 2, 14, 0)
    check("forwarded inputs: used ones, then the ones the host has next", n == 17
        and table.concat(f, ",") == "6,7,7,8,9,9,1", tostring(n) .. " " .. table.concat(f or {}, ","))
    n, f = inputsync.forward(host, 2, 14, 17)
    check("forwarding repeats the last ticks already sent", n == 17 and #f == inputsync.REDUNDANCY - 1)
    inputsync.played(host, 1, 14, 3)
    n, f = inputsync.forward(host, 1, 14, 0)
    check("the host's own player is forwarded up to its tick", n == 14 and table.concat(f, ",") == "3")
    local ahead = { t = "ahead", g = 1, p = { { 2, 17, { 6, 7, 7, 8, 9, 9, 1 } }, { 1, 14, { 3 } } } }
    local long = {}
    for i = 1, inputsync.FORWARD + 1 do long[i] = 0 end
    check("ahead messages are checked", protocol.decode(protocol.encode(ahead), 1024) ~= nil
        and protocol.decode(wire.encode({ t = "ahead", g = 1, p = { { 2, 40, long } } }), 1024) == nil
        and protocol.decode(wire.encode({ t = "ahead", g = 1, p = { { 2, 3, { 1, 2, 3, 4 } } } }), 1024) == nil)
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
    local client
    client = assert(session.join("127.0.0.1:" .. (PORT + 1), {
        welcome = function(message) got.welcome = message end,
        room = function(message)
            got.room = message
            client:has(message.fp)
        end,
        start = function(message) got.start = message end,
        restart = function() end,
        joined = function() end,
        left = function() end,
        snap = function(message) got.snaps[#got.snaps + 1] = message end,
        ahead = function(message) got.ahead = message end,
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
    run(400, function() return got.start ~= nil and #got.snaps > 0 end)
    check("--host plays at once: a joining client drops in", got.room and got.room.st == "playing"
        and got.start and got.start.level == "example" and #got.start.players == 2, tostring(got.closed))
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
        message.g, message.k = got.start.generation, got.snaps[#got.snaps].h
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
    local hostEntry = got.ahead and got.ahead.p[1]
    check("the host forwards the other players' inputs every tick", hostEntry and hostEntry[1] == 1
        and #got.ahead.p == 1 and hostEntry[2] >= last.h and hostEntry[3][#hostEntry[3]] == 0,
        hostEntry and (hostEntry[1] .. " " .. hostEntry[2] .. " vs " .. last.h))
    check("after acknowledging, the client gets deltas", last.base > 0 and #last.set < #got.snaps[1].set)
    check("states tell how early its inputs arrive", early >= 1, early)

    client:close()
    run(60)
    check("the scene notices the client leaving", #gameplay.getLevel().players == 1)
    gameplay.closeNetwork()
    gameplay.configure({ mode = nil })
end

-- ── The waiting room: level choice, the countdown, starting, back to the room ─
do
    local gameplay = require("scenes.gameplay")
    gameplay.configure({ mode = "host", port = PORT + 3, bind = "127.0.0.1", level = "example", name = "Hosty",
        room = { name = "Test room", dropIn = false, public = true } })
    gameplay.load()
    check("a room host waits in the room", gameplay.getLevel() == nil and gameplay.getNetwork() ~= nil)
    gameplay.setSource(1, { read = function() return {} end })

    local function newClient(name, claim)
        local got = { rooms = 0 }
        got.client = assert(session.join("127.0.0.1:" .. (PORT + 3), {
            welcome = function(message) got.welcome = message end,
            room = function(message)
                got.room, got.rooms = message, got.rooms + 1
                got.client:has(claim and claim(message) or message.fp)
            end,
            start = function(message) got.start = message end,
            toroom = function(message) got.toroom = message end,
            restart = function() end, joined = function() end, left = function() end,
            snap = function() end, ahead = function() end,
            closed = function(reason) got.closed = reason end,
        }, { name = name }))
        return got
    end
    local clients = {}
    local function run(frames, done)
        for _ = 1, frames do
            gameplay.update(1 / 60)
            for _, got in ipairs(clients) do got.client:service() end
            if done and done() then return true end
            love.timer.sleep(0.002)
        end
        return false
    end

    local missing = false
    local ann = newClient("Ann", function(message) return missing and "" or message.fp end)
    clients[1] = ann
    run(300, function() return ann.room and #ann.room.players == 2 and ann.room.players[2].has end)
    local roomScene = require("scenes.room")
    local drawn, err = pcall(roomScene.draw)
    check("the waiting room draws (host)", drawn, tostring(err))
    roomScene.keypressed("right")
    check("Right on Level picks the next level", (gameplay.getRoom()) and select(1, gameplay.getRoom()).level ~= nil)
    roomScene.keypressed("left")
    local room = ann.room
    check("the room reaches a joining player: name, level, players and their names", room
        and room.name == "Test room" and room.level == "example" and room.st == "waiting" and not room.di
        and room.players[1].name == "Hosty" and room.players[2].name == "Ann" and room.players[2].has,
        room and (room.name .. " " .. room.st))

    gameplay.roomAction("level", 1)
    run(300, function() return ann.room.level ~= "example" and ann.room.players[2].has end)
    check("the host changes the level; players say whether they have it", ann.room.level == "topdown"
        and ann.room.players[2].has)
    gameplay.roomAction("level", -1)
    missing = true
    run(300, function() return ann.room.level == "example" and not ann.room.players[2].has end)
    local ok, reason = gameplay.roomAction("start")
    check("no start while someone lacks the level", not ok and reason ~= nil and not ann.room.players[2].has)
    missing = false
    gameplay.roomAction("dropIn")
    gameplay.roomAction("dropIn")
    run(300, function() return ann.room.players[2].has end)

    check("the host starts the countdown", gameplay.roomAction("start"))
    run(60, function() return ann.room.st == "countdown" end)
    check("players see the countdown", ann.room.st == "countdown" and ann.room.cd == 3, ann.room.cd)
    local roomScene = require("scenes.room")
    local drawn, err = pcall(roomScene.draw)
    check("the waiting room draws (host, counting down)", drawn, tostring(err))
    run(400, function() return ann.start ~= nil end)
    local level = gameplay.getLevel()
    check("at the end of the countdown everyone plays the room's level", ann.start and level
        and ann.start.level == "example" and #ann.start.players == 2 and #level.players == 2)

    local bob = newClient("Bob")
    clients[2] = bob
    run(300, function() return bob.closed ~= nil end)
    check("without drop-in a playing room refuses joins", bob.closed == "the game has already started",
        tostring(bob.closed))
    table.remove(clients, 2)

    check("the host takes everyone back to the room", gameplay.backToRoom())
    run(300, function() return ann.toroom ~= nil and ann.room.st == "waiting" end)
    check("players go back to the room with it", ann.toroom and ann.room.st == "waiting"
        and gameplay.getLevel() == nil and ann.toroom.generation > ann.start.generation)

    ann.client:close()
    run(60)
    gameplay.closeNetwork()
    gameplay.configure({ mode = nil })
end
