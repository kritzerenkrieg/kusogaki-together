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
            state = function() states = states + 1 end,
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
    local p = require("core.net.playersync").pack(playerModule.new(1, 1))
    for i = 1, 55 do -- under the host's 60 a second
        client:sendState({ t = "state", g = 1, s = i, a = 0, p = p, e = {}, k = 0 })
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

-- ── Player state sync (core/net/playersync.lua) ──────────────────────────
local playersync = require("core.net.playersync")
do
    local player = playerModule.new(100.3, 50.06)
    player.vx, player.vy, player.facing, player.onGround, player.kickTime = 117.4, -360, -1, true, 0.1
    local p = playersync.pack(player)
    local back = playersync.unpack(p)
    check("a player's wire form is 9 integers", playersync.valid(p) and #p == 9)
    check("positions round to 1/8 px, velocities to 1/16 px per tick",
        math.abs(back.x - 100.3) <= 1 / 16 and math.abs(back.y - 50.06) <= 1 / 16
        and math.abs(back.vx - 117.4) <= 60 / 32 and back.vy == -360)
    check("flags and timers survive", back.facing == -1 and back.onGround and not back.jumping and not back.dead
        and back.kickAnimationTime == nil and math.abs(back.kickTime - 0.1) < 0.01)
    check("bad wire players are refused", not playersync.valid({ 1, 2, 3 })
        and not playersync.valid({ 1, 2, 3, 4, 99, 0, -1, 0, 0 })
        and not playersync.valid({ 0.5, 0, 0, 0, 0, 0, -1, 0, 0 })
        and not playersync.valid({ 0, 0, 0, 0, 0, 0, -1, 0, 0, 9 }))
    local function decodes(message)
        return protocol.decode(wire.encode(message), 1024) ~= nil
    end
    check("state messages are checked", decodes({ t = "state", g = 1, s = 5, a = 0, p = p, e = { "jump" }, k = 0 })
        and not decodes({ t = "state", g = 1, s = 5, a = 0, p = p, e = { "no spaces" }, k = 0 })
        and not decodes({ t = "state", g = 1, s = -1, a = 0, p = p, e = {}, k = 0 }))
    check("players messages are checked", decodes({ t = "players", g = 1, list = { { 1, 3, p, {} }, { 2, 9, p, {} } } })
        and not decodes({ t = "players", g = 1, list = { { 1, 3, p, {} }, { 1, 4, p, {} } } })
        and not decodes({ t = "players", g = 1, list = { { 7, 3, p, {} } } }))
    check("setPlayer messages are checked", decodes({ t = "setPlayer", g = 1, a = 1, x = 1, y = 2, vx = 0, vy = 0 })
        and decodes({ t = "setPlayer", g = 1, a = 1, x = 1, y = 2, vx = 0, vy = 0, sx = 1, sy = 2 })
        and decodes({ t = "setPlayer", g = 1, a = 1, sx = 1, sy = 2 })
        and not decodes({ t = "setPlayer", g = 1, a = 1, x = 0 / 0, y = 2, vx = 0, vy = 0 }))

    -- The referee refuses only the clearly impossible.
    local level = Level.load("example", { seed = 1 })
    local puppet = playersync.makePuppet(playerModule.new(100, 100))
    local last = { x = 100, y = 100, dead = false }
    local function at(x, y, extra)
        local fields = { x = x, y = y, vx = 0, vy = 0, dead = false }
        for key, value in pairs(extra or {}) do fields[key] = value end
        return fields
    end
    check("the referee accepts normal movement", playersync.possible(level, puppet, last, at(104, 98), 0.05))
    check("the referee refuses a teleport", not playersync.possible(level, puppet, last, at(900, 100), 0.05))
    check("the referee refuses impossible speed", not playersync.possible(level, puppet, last, at(100, 100, { vx = 5000 }), 0.05))
    check("the referee refuses leaving the level", not playersync.possible(level, puppet, last, at(-1000, 100), 1))
    check("a respawn may jump to the checkpoint", playersync.possible(level, puppet, { x = 100, y = 900, dead = true },
        at(900, 100), 0.05))

    -- Puppets: solid, never pushed, untouched by rules that change players.
    level = Level.load("example", { seed = 1 })
    local mover = level:addPlayer(playerModule.new(level.spawn.x, level.spawn.y))
    local still = level:addPlayer(playersync.makePuppet(playerModule.new(level.spawn.x + 40, level.spawn.y)))
    for _ = 1, 60 do -- settle on the ground
        mover.input = {}
        level:update(1 / 60)
    end
    still.y = mover.y -- on the ground beside the walker (a puppet does not fall by itself)
    local puppetX = still.x
    for _ = 1, 90 do
        mover.input = { right = true }
        level:update(1 / 60)
    end
    check("a local player walking into a puppet stops at it", mover.x < still.x - (mover.w + still.w) / 2 + 2,
        string.format("%.1f vs %.1f", mover.x, still.x))
    check("a puppet is never pushed or simulated here", still.x == puppetX)
    still.y = level.height + 500
    level:update(1 / 60)
    check("a puppet does not die here (its owner decides)", not still.dead)

    -- Smoothing: an owner walking 200 px/s, states every 50 ms arriving 30 ms
    -- late; shown 100 ms behind, blended between states.
    local smooth = require("core.net.smooth")
    local walker = playersync.makePuppet(playerModule.new(0, 0))
    local function stateAt(seq)
        local fields = { x = seq * 10, y = 0, vx = 200, vy = 0, facing = 1, onGround = true, jumping = false,
            dead = false, kickTime = 0, respawns = 0, carryingId = 0 }
        playersync.hear(walker, fields, seq, seq == 2 and { "jump" } or {}, seq * 0.05 + 0.03)
    end
    for seq = 1, 5 do stateAt(seq) end
    local names = playersync.advance(walker, 1 / 60, nil, 0.3)
    check("a puppet is shown 100 ms behind, blended between states", math.abs(walker.x - 34) < 0.01
        and walker.state == "run", string.format("%.2f %s", walker.x, walker.state))
    check("its sounds play when their state is shown, once", #names == 1 and names[1] == "jump"
        and #playersync.advance(walker, 1 / 60, nil, 0.31) == 0)
    playersync.advance(walker, 1 / 60, nil, 0.5)
    check("past its newest state it moves on 100 ms, then waits", math.abs(walker.x - 70) < 0.01,
        string.format("%.2f", walker.x))
    stateAt(7) -- 6 was lost
    playersync.advance(walker, 1 / 60, nil, 0.03 + 0.1 + 0.3)
    check("a lost state is bridged", math.abs(walker.x - 60) < 0.01, string.format("%.2f", walker.x))
    local track = smooth.track()
    smooth.push(track, 0, { x = 0, y = 0 })
    smooth.push(track, 0.05, { x = 500, y = 0 })
    check("a teleport between states is not slid across", (smooth.sample(track, 0.04)) == 0)
    local clock = smooth.clock()
    smooth.heard(clock, 1, 1.2)
    smooth.heard(clock, 2, 2.05)
    smooth.heard(clock, 3, 3.3)
    check("a sender's clock follows the quickest delivery, creeping up slowly",
        clock.offset > 0.05 and clock.offset < 0.06, clock.offset)

    -- Owner override: newer authority only.
    local owned = playerModule.new(0, 0)
    local own = playersync.owner()
    check("an override moves the owner's player", playersync.override(own, owned,
        { a = 2, x = 50, y = 60, vx = 0, vy = 0, sx = 50, sy = 60 }) and owned.x == 50 and owned.spawnX == 50)
    check("an older override is ignored", not playersync.override(own, owned, { a = 1, x = 0, y = 0, vx = 0, vy = 0 })
        and owned.x == 50)
    check("states carry the authority they obey", playersync.nextState(own, owned).a == 2)
end

-- ── World sync (core/net/worldsync.lua) ──────────────────────────────────
local worldsync = require("core.net.worldsync")
do
    -- The host runs the example level with a player walking and jumping
    -- right; a client level (same seed) only applies what it is sent.
    local hostLevel = Level.load("example", { seed = 9 })
    local runner = hostLevel:addPlayer(playerModule.new(hostLevel.spawn.x, hostLevel.spawn.y))
    local clientLevel = Level.load("example", { seed = 9 })
    clientLevel.remoteWorld = true
    local hostSide, clientSide = worldsync.host(), worldsync.client()
    worldsync.addClient(hostSide, 2)
    local function through(message)
        message.g, message.vt, message.cd = 1, {}, false
        return protocol.decode(protocol.encode(message), protocol.MAX_HOST_MESSAGE)
    end
    local function step(ticks)
        for i = 1, ticks do
            runner.input = { right = true, jump = (i % 40) < 20 }
            hostLevel:update(1 / 60)
            hostLevel:takeEvents()
        end
    end
    local function sameWorld()
        for id, entity in pairs(hostLevel.byId) do
            local other = clientLevel:get(id)
            if not other or math.abs(other.x - entity.x) > 1 / 16 or math.abs(other.y - entity.y) > 1 / 16 then
                return false, "entity " .. id
            end
        end
        for id in pairs(clientLevel.byId) do
            if not hostLevel:get(id) then
                return false, "extra entity " .. id
            end
        end
        return true
    end

    local state = worldsync.capture(hostSide, hostLevel)
    local message, full = worldsync.messageFor(hostSide, 2, state, 0)
    check("a client without a base gets a full snapshot", full and message.base == 0)
    check("no second full snapshot before FULL_EVERY", worldsync.messageFor(hostSide, 2,
        worldsync.capture(hostSide, hostLevel), 0.5) == nil)
    local rebuilt = worldsync.receive(clientSide, through(message))
    check("the client rebuilds the full snapshot (hash matches)", rebuilt ~= nil)
    clientLevel:protect(worldsync.apply, clientLevel, rebuilt)
    check("the client's world matches the host's", sameWorld())
    worldsync.acknowledge(hostSide, 2, worldsync.ack(clientSide))

    local enemiesBefore, removedBefore = #hostLevel.enemies, 0
    for _, _ in pairs(hostLevel.byId) do removedBefore = removedBefore + 1 end
    hostLevel.enemies[1].killedBy = "stomp" -- removed by the host's next step
    step(600)
    hostLevel:spawnEntity("brick", 300, 100)
    local entityCount = 0
    for _ in pairs(hostLevel.byId) do entityCount = entityCount + 1 end
    state = worldsync.capture(hostSide, hostLevel)
    message, full = worldsync.messageFor(hostSide, 2, state, 2)
    local fresh = worldsync.host()
    worldsync.addClient(fresh, 1)
    local fullMessage = worldsync.messageFor(fresh, 1, state, 0)
    fullMessage.g, fullMessage.vt, fullMessage.cd = 1, {}, false
    local fullBytes = #protocol.encode(fullMessage)
    check("after its ack the client gets a delta", not full and message.base == rebuilt.n
        and #message.gone > 0, string.format("gone %d, entities %d -> %d", #message.gone, removedBefore, entityCount))
    rebuilt = worldsync.receive(clientSide, through(message))
    clientLevel:protect(worldsync.apply, clientLevel, rebuilt)
    local ok, why = sameWorld()
    check("deltas keep the client's world equal: moves, removals, a spawn", rebuilt and ok, why)
    check("enemies the host killed are gone on the client", #clientLevel.enemies == #hostLevel.enemies
        and #hostLevel.enemies < enemiesBefore, ("%d -> %d, client %d"):format(enemiesBefore,
        #hostLevel.enemies, #clientLevel.enemies))
    worldsync.acknowledge(hostSide, 2, worldsync.ack(clientSide))

    -- A quiet delta is small.
    state = worldsync.capture(hostSide, hostLevel)
    message = worldsync.messageFor(hostSide, 2, state, 3)
    message.g, message.vt, message.cd = 1, {}, false
    check("a delta with little change is small", #protocol.encode(message) < 400,
        #protocol.encode(message) .. " bytes")
    print(string.format("      world: delta %d bytes", #protocol.encode(message)))

    check("an old snapshot is ignored", worldsync.receive(clientSide, through(message)) ~= nil
        and select(2, worldsync.receive(clientSide, through(message))) == "old")
    local orphan = through(message)
    orphan.n, orphan.base = orphan.n + 5, 999
    check("a delta to a base the client lacks is dropped", select(2, worldsync.receive(clientSide, orphan)) == "no base")
    local tampered = through(message)
    tampered.n, tampered.hash = tampered.n + 1, ("0"):rep(16)
    check("a hash mismatch asks for a full snapshot", select(2, worldsync.receive(clientSide, tampered)) == "hash"
        and worldsync.ack(clientSide) == 0)
    worldsync.acknowledge(hostSide, 2, 0)
    local _, again = worldsync.messageFor(hostSide, 2, worldsync.capture(hostSide, hostLevel), 10)
    check("then the host sends a full one", again == true)

    -- Level state: script state and the outcome.
    hostLevel.net.score = 7
    hostLevel:finish("win", "done")
    local full = worldsync.messageFor(hostSide, 2, worldsync.capture(hostSide, hostLevel), 20)
    clientLevel:protect(worldsync.apply, clientLevel, worldsync.receive(clientSide, through(full)))
    check("level state reaches the client", clientLevel.net.score == 7 and clientLevel.finished
        and clientLevel.finished.outcome == "win")
    print(string.format("      world: full snapshot %d bytes", fullBytes))
end

-- ── Claims (core/level/claims.lua) ───────────────────────────────────────
local claims = require("core.level.claims")
do
    local function firstOf(level, typeName)
        for _, entity in ipairs(level.enemies) do
            if entity.typeName == typeName then return entity end
        end
    end
    -- A client (remoteWorld) stomps a dodon: shown at once, claimed.
    local clientLevel = Level.load("example", { seed = 3 })
    clientLevel.remoteWorld = true
    local me = clientLevel:addPlayer(playerModule.new(0, 0))
    local dodon = firstOf(clientLevel, "dodon")
    local id = dodon.id
    me.x, me.y, me.vy = dodon.x, dodon.y - dodon.h / 2 - me.h / 2 - 1, 240
    me.prevY = me.y
    me.input = {}
    clientLevel:update(1 / 60, worldsync.CLIENT_STAGES)
    local noted = claims.take(clientLevel)
    local shown = false
    for _, event in ipairs(clientLevel:takeEvents()) do
        if event.type == "corpse" and event.id == id then shown = true end
    end
    check("a client's stomp is claimed and shown at once", #noted == 1 and noted[1].k == "stomp"
        and noted[1].id == id and clientLevel:get(id) == nil and shown and me.vy < 0)

    -- The host judges it with the dodon's own hook, from where it sees the player.
    local hostLevel = Level.load("example", { seed = 3 })
    local puppet = hostLevel:addPlayer(playersync.makePuppet(playerModule.new(dodon.x, dodon.y - 20)))
    check("the host accepts a claim that holds", claims.judge(hostLevel, puppet, { k = "stomp", id = id }))
    hostLevel:update(1 / 60)
    check("and the enemy dies on the host", hostLevel:get(id) == nil)
    check("a second claim on it is denied", not claims.judge(hostLevel, puppet, { k = "stomp", id = id }))
    local far = firstOf(hostLevel, "dodon")
    check("a claim from too far is denied", not claims.judge(hostLevel, puppet, { k = "kill", id = far.id, d = 1 }))
    check("a claim on a missing or wrong entity is denied", not claims.judge(hostLevel, puppet,
        { k = "grab", id = 99999 }) and not claims.judge(hostLevel, puppet, { k = "kickProp", id = far.id, d = 1 }))

    -- Denied: the client keeps its version until the snapshot at the verdict,
    -- then the host's (the enemy is back).
    local denyHost = Level.load("example", { seed = 3 })
    local hostSide, clientSide = worldsync.host(), worldsync.client()
    worldsync.addClient(hostSide, 2)
    local state = worldsync.capture(hostSide, denyHost)
    local message = worldsync.messageFor(hostSide, 2, state, 0)
    message.g, message.vt, message.cd = 1, {}, false
    local rebuilt = worldsync.receive(clientSide, message)
    local pending = { [id] = { expires = math.huge } }
    worldsync.settle(pending, rebuilt.n, 0)
    clientLevel:protect(worldsync.apply, clientLevel, rebuilt, pending)
    check("a claimed entity keeps the client's version while pending", clientLevel:get(id) == nil)
    pending[id]["until"] = rebuilt.n
    worldsync.settle(pending, rebuilt.n, 0)
    clientLevel:protect(worldsync.apply, clientLevel, rebuilt, pending)
    check("a denied claim is undone by the host's snapshot", clientLevel:get(id) ~= nil
        and clientLevel:get(id) == dodon)

    -- Kicking another machine's player is a claim on every machine; the
    -- host knocks the victim through its own machine.
    local kickLevel = Level.load("example", { seed = 3 })
    local kicker = kickLevel:addPlayer(playerModule.new(100, 240))
    local victim = kickLevel:addPlayer(playersync.makePuppet(playerModule.new(100 + 16, 240)))
    for _ = 1, 30 do kicker.input = {}; kickLevel:update(1 / 60) end
    victim.y = kicker.y
    claims.take(kickLevel)
    kicker.input = { kick = true }
    for _ = 1, 3 do kickLevel:update(1 / 60) end
    local kick = claims.take(kickLevel)[1]
    local ok, hit = claims.judge(kickLevel, kicker, kick or {})
    check("kicking a remote player becomes a claim the host accepts", kick and kick.k == "kickPlayer"
        and kick.id == victim.id and ok and hit == victim and victim.vx == 0)

    -- Head-bumping a brick from below on a client: the host judges with the
    -- player as the client saw itself (its puppet has no movingUp or prevY).
    local bumpLevel = Level.load("example", { seed = 3 })
    bumpLevel.remoteWorld = true
    local brick
    for _, block in ipairs(bumpLevel.blocks) do
        if block.typeName == "brick" then brick = block break end
    end
    local jumper = bumpLevel:addPlayer(playerModule.new(brick.x, brick.y + brick.h / 2 + 12 + 2))
    jumper.vy, jumper.jumping, jumper.input = -300, true, { jump = true }
    jumper.prevKeys.jump = true -- held, not a fresh press
    local bump
    for _ = 1, 6 do
        bumpLevel:update(1 / 60, worldsync.CLIENT_STAGES)
        for _, claim in ipairs(claims.take(bumpLevel)) do
            if claim.k == "touchBlock" then bump = claim end
        end
    end
    check("a client's head bump is claimed with its moment", bump and bump.id == brick.id and bump.at
        and bumpLevel:get(brick.id) == nil)
    local bumpHost = Level.load("example", { seed = 3 })
    local bumpPuppet = bumpHost:addPlayer(playersync.makePuppet(playerModule.new(brick.x, brick.y + 30)))
    local wire = protocol.decode(protocol.encode({ t = "claim", g = 1, c = 1, k = bump.k, id = bump.id, at = bump.at }),
        1024)
    check("the host accepts it though its own copy is not moving up", wire
        and claims.judge(bumpHost, bumpPuppet, wire, { x = brick.x, y = brick.y + 30 }))
    check("a moment far from where the host last heard of it is denied", not claims.judge(Level.load("example",
        { seed = 3 }), bumpPuppet, wire, { x = brick.x + 300, y = brick.y }))

    -- A puppet walking into a standing local player does not push it.
    local pushLevel = Level.load("example", { seed = 3 })
    local stander = pushLevel:addPlayer(playerModule.new(100, 240))
    local walkerIn = pushLevel:addPlayer(playersync.makePuppet(playerModule.new(60, 240)))
    for _ = 1, 30 do stander.input = {}; pushLevel:update(1 / 60) end
    walkerIn.y = stander.y
    local standX = stander.x
    for i = 1, 20 do
        walkerIn.x = 60 + i * 2 -- its owner walks it in (and on, into the local player)
        stander.input = {}
        pushLevel:update(1 / 60)
    end
    check("a puppet walking into a standing local player does not push it", stander.x == standX,
        string.format("%.2f -> %.2f", standX, stander.x))

    local blastEvent = { type = "explosion", x = 100, y = 100, radius = 30 }
    check("each machine checks its own player against explosions", claims.caughtBy(playerModule.new(120, 100),
        blastEvent) and not claims.caughtBy(playerModule.new(200, 100), blastEvent))
end

-- ── The gameplay scene as host, with a client over localhost ─────────────
do
    local gameplay = require("scenes.gameplay")
    gameplay.configure({ mode = "host", port = PORT + 1, bind = "127.0.0.1", level = "example" })
    gameplay.load()
    check("the scene hosts a session", gameplay.getNetwork() ~= nil)
    gameplay.setSource(1, { read = function() return { right = true } end })
    local got = { players = {}, setPlayer = {} }
    local client = assert(session.join("127.0.0.1:" .. (PORT + 1), {
        level = function() return true end,
        welcome = function(message) got.welcome = message end,
        restart = function() end,
        joined = function() end,
        left = function() end,
        players = function(message) got.players[#got.players + 1] = message end,
        setPlayer = function(message) got.setPlayer[#got.setPlayer + 1] = message end,
        world = function(message) got.world = message end,
        events = function() end,
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
    run(400, function() return got.welcome ~= nil and #got.setPlayer > 0 and got.world ~= nil end)
    local place = got.setPlayer[1]
    check("a late joiner is placed at the host's checkpoint", got.welcome and place and place.a == 1
        and place.sx == gameplay.getPlayer(1).spawnX, tostring(got.closed))

    check("a joined client gets the host's full world", got.world and got.world.base == 0
        and #got.world.ents > 0 and got.world.lvl ~= false)
    local level = gameplay.getLevel()
    local puppet
    for _, player in ipairs(level.players) do
        if player.id == got.welcome.you then puppet = player end
    end
    check("the client's player is a puppet on the host", puppet and puppet.remote and puppet.immovable)

    -- The client's player walks right: 20 states a second, authority 1.
    local mine = playerModule.new(place.x, place.y)
    local seq = 0
    local function sendAt(x, authority)
        seq = seq + 1
        mine.x = x
        client:sendState({ t = "state", g = got.welcome.generation, s = seq, a = authority,
            p = playersync.pack(mine), e = { "jump" }, k = 0 })
    end
    for i = 1, 10 do
        sendAt(place.x + i * 6, 1)
        run(3)
    end
    run(20, function() return math.abs(puppet.x - (place.x + 60)) < 8 end)
    check("the host's puppet follows the client's states", math.abs(puppet.x - (place.x + 60)) < 8,
        string.format("%.1f vs %.1f", puppet.x, place.x + 60))
    local hostEntry
    for _, message in ipairs(got.players) do
        for _, entry in ipairs(message.list) do
            if entry[1] == 1 then hostEntry = entry end
        end
    end
    check("the client gets the host player's state", hostEntry ~= nil
        and math.abs(playersync.unpack(hostEntry[3]).x - gameplay.getPlayer(1).x) < 30)

    -- A teleport is refused and corrected with a higher authority; states
    -- still stamped with the old one are then dropped.
    local before = puppet.x
    sendAt(place.x + 2000, 1)
    run(200, function() return #got.setPlayer >= 2 end)
    local correction = got.setPlayer[2]
    check("an impossible move is answered with a setPlayer", correction and correction.a == 2
        and math.abs(correction.x - before) < 8 and math.abs(puppet.x - before) < 8)
    sendAt(before + 4, 1)
    run(10)
    check("states from before the override are dropped", math.abs(puppet.x - before) < 8)
    sendAt(before + 4, 2)
    run(10)
    check("states that obey the override are accepted", math.abs(puppet.x - (before + 4)) < 4)

    -- A state from another level generation is dropped.
    mine.x = before + 40
    local wrongGeneration = { t = "state", g = got.welcome.generation + 1, s = seq + 1, a = 2,
        p = playersync.pack(mine), e = {}, k = 0 }
    seq = seq + 1
    client:sendState(wrongGeneration)
    run(10)
    check("states from another level generation are dropped", math.abs(puppet.x - (before + 4)) < 4)

    -- A host script moves the remote player once: its machine is told.
    local moved = false
    gameplay.getLevel():addStage("teleporter", function()
        if not moved then
            moved = true
            puppet.x, puppet.spawnX, puppet.spawnY = 500, 500, 100
        end
    end)
    local count = #got.setPlayer
    run(200, function() return #got.setPlayer > count end)
    local sent = got.setPlayer[count + 1]
    check("a host script moving a remote player sends a setPlayer", sent and sent.x == 500 and sent.sx == 500
        and sent.y == nil and sent.a == 3, sent and ("x %s y %s a %s"):format(sent.x, sent.y, sent.a))

    -- Claims over the session: the client's player stands on a dodon (as the
    -- host sees it) and claims the stomp; then claims it again.
    local verdicts = {}
    client.handler.verdict = function(message) verdicts[#verdicts + 1] = message end
    local target
    for _, enemy in ipairs(gameplay.getLevel().enemies) do
        if enemy.typeName == "dodon" then target = enemy break end
    end
    -- Walk there in legal steps (authority 3, after the script's setPlayer).
    local fromX = puppet.x
    for i = 1, 6 do
        sendAt(fromX + (target.x - fromX) * i / 6, 3)
        run(3)
    end
    run(10)
    client:sendClaim({ t = "claim", g = got.welcome.generation, c = 1, k = "stomp", id = target.id })
    client:sendClaim({ t = "claim", g = got.welcome.generation, c = 2, k = "stomp", id = target.id })
    run(200, function() return #verdicts >= 2 end)
    check("the host accepts a claim that holds and kills the enemy", verdicts[1] and verdicts[1].c == 1
        and verdicts[1].ok and verdicts[1].n > 0 and gameplay.getLevel():get(target.id) == nil)
    check("the same claim again is denied", verdicts[2] and verdicts[2].c == 2 and not verdicts[2].ok)

    client:close()
    run(60)
    check("the scene notices the client leaving", #gameplay.getLevel().players == 1)
    gameplay.closeNetwork()
    gameplay.configure({ mode = nil })
end
