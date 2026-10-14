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

-- ── Player state sync (core/net/playersync.lua) ──────────────────────────
local playersync = require("core.net.playersync")
do
    local player = playerModule.new(100.3, 50.06)
    player.vx, player.vy, player.facing, player.onGround, player.kickTime = 117.4, -360, -1, true, 0.1
    local p = playersync.pack(player)
    local back = playersync.unpack(p)
    check("a player's wire form is 8 integers", playersync.valid(p) and #p == 8)
    check("positions round to 1/8 px, velocities to 1/16 px per tick",
        math.abs(back.x - 100.3) <= 1 / 16 and math.abs(back.y - 50.06) <= 1 / 16
        and math.abs(back.vx - 117.4) <= 60 / 32 and back.vy == -360)
    check("flags and timers survive", back.facing == -1 and back.onGround and not back.jumping and not back.dead
        and back.kickAnimationTime == nil and math.abs(back.kickTime - 0.1) < 0.01)
    check("bad wire players are refused", not playersync.valid({ 1, 2, 3 })
        and not playersync.valid({ 1, 2, 3, 4, 99, 0, -1, 0 }) and not playersync.valid({ 0.5, 0, 0, 0, 0, 0, -1, 0 })
        and not playersync.valid({ 0, 0, 0, 0, 0, 0, -1, 0, 9 }))
    local function decodes(message)
        return protocol.decode(wire.encode(message), 1024) ~= nil
    end
    check("state messages are checked", decodes({ t = "state", g = 1, s = 5, a = 0, p = p, e = { "jump" } })
        and not decodes({ t = "state", g = 1, s = 5, a = 0, p = p, e = { "no spaces" } })
        and not decodes({ t = "state", g = 1, s = -1, a = 0, p = p, e = {} }))
    check("players messages are checked", decodes({ t = "players", g = 1, list = { { 1, 3, p, {} }, { 2, 9, p, {} } } })
        and not decodes({ t = "players", g = 1, list = { { 1, 3, p, {} }, { 1, 4, p, {} } } })
        and not decodes({ t = "players", g = 1, list = { { 7, 3, p, {} } } }))
    check("setPlayer messages are checked", decodes({ t = "setPlayer", g = 1, a = 1, x = 1, y = 2, vx = 0, vy = 0 })
        and decodes({ t = "setPlayer", g = 1, a = 1, x = 1, y = 2, vx = 0, vy = 0, sx = 1, sy = 2 })
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

    local walker = playersync.makePuppet(playerModule.new(0, 0))
    playersync.apply(walker, { x = 10, y = 0, vx = 60, vy = 0, facing = 1, onGround = true, jumping = false,
        dead = false, kickTime = 0, respawns = 0 })
    for _ = 1, 30 do playersync.advance(walker, 1 / 60) end
    check("a puppet keeps moving briefly between states, then waits", walker.x > 15 and walker.x < 17.5
        and walker.state == "run", string.format("%.2f %s", walker.x, walker.state))

    -- Owner override: newer authority only.
    local owned = playerModule.new(0, 0)
    local own = playersync.owner()
    check("an override moves the owner's player", playersync.override(own, owned,
        { a = 2, x = 50, y = 60, vx = 0, vy = 0, sx = 50, sy = 60 }) and owned.x == 50 and owned.spawnX == 50)
    check("an older override is ignored", not playersync.override(own, owned, { a = 1, x = 0, y = 0, vx = 0, vy = 0 })
        and owned.x == 50)
    check("states carry the authority they obey", playersync.nextState(own, owned).a == 2)
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
        snapshot = function() end,
        restart = function() end,
        joined = function() end,
        left = function() end,
        players = function(message) got.players[#got.players + 1] = message end,
        setPlayer = function(message) got.setPlayer[#got.setPlayer + 1] = message end,
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
    run(400, function() return got.welcome ~= nil and #got.setPlayer > 0 end)
    local place = got.setPlayer[1]
    check("a late joiner is placed at the host's checkpoint", got.welcome and place and place.a == 1
        and place.sx == gameplay.getPlayer(1).spawnX, tostring(got.closed))

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
            p = playersync.pack(mine), e = { "jump" } })
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
        p = playersync.pack(mine), e = {} }
    seq = seq + 1
    client:sendState(wrongGeneration)
    run(10)
    check("states from another level generation are dropped", math.abs(puppet.x - (before + 4)) < 4)

    client:close()
    run(60)
    check("the scene notices the client leaving", #gameplay.getLevel().players == 1)
    gameplay.closeNetwork()
    gameplay.configure({ mode = nil })
end
