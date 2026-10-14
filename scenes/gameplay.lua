-- Gameplay scene: loads a level and its local player, and runs it.
-- Each local player is a slot { source, id, player }: an input device
-- (core/input.lua), its player id and the player it drives. Slots survive
-- restarts; players do not (their respawn counts do).
--
-- One player per machine: multiplayer is network play. Local couch co-op
-- (more slots joined from keyboard layout 2 or gamepads) is deprecated and
-- frozen for a far-future return: off unless `--local-coop` is on the
-- command line, and not maintained beyond keeping it working. Gamepads are
-- deprecated with it: the one player plays on the keyboard.
--
-- Restarting is a vote: each player toggles their vote (R / E / gamepad Back).
-- While more than half of all players vote, a countdown runs and then the
-- level restarts; dropping to half or fewer cancels it.
--
-- Network play (Phase 2, NETWORKING.md): `--host` opens a session on this
-- machine; `--join <ip>` joins one. Without either, this machine plays alone
-- and is its own host. The host is the source of truth: it picks each
-- (re)start's seed and generation and announces them as a `restart` session
-- message (gameplay.takeOutbox); every machine, the host included, restarts
-- through gameplay.restart(seed). Player ids stay stable for the session, so
-- remote players keep theirs across restarts.
--
-- Player state (step 2, core/net/playersync.lua): each machine owns its own
-- player and sends its state 20 times a second; the host checks it and
-- forwards everyone's to everyone. Other machines' players are puppets here.
--
-- World (step 3, core/net/worldsync.lua): the host runs the world (every
-- rule, entity and level script) and sends each client snapshot deltas and
-- one-off events; a client runs only its own player's stages against that
-- world (level.remoteWorld) and draws. A host script that changes a remote
-- player sends that player's machine a setPlayer by itself.
local sceneEngine = require("core.scenes")
local fx = require("core.graphics.fx")
local camera = require("core.graphics.camera")
local hud = require("core.graphics.hud")
local playerModule = require("core.player")
local Level = require("core.level")
local audio = require("core.audio")
local input = require("core.input")
local fixedstep = require("core.fixedstep")
local interp = require("core.graphics.interp")
local present = require("core.graphics.present")
local render = require("core.graphics.render")
local text = require("core.text")
local loader = require("core.level.loader")
local netstate = require("core.level.netstate")
local levelpack = require("core.levelpack")
local session = require("core.net.session")
local playersync = require("core.net.playersync")
local worldsync = require("core.net.worldsync")
local claims = require("core.level.claims")
local script = require("core.script")
local watchdog = require("core.watchdog")

local gameplay = {}

-- Command line: `--level <name>` picks the level (default "example"; a client
-- plays the host's); `--host` / `--join <ip[:port]>` start network play;
-- `--local-coop` turns on the deprecated couch co-op.
local LEVEL_NAME = "example"
local LOCAL_COOP = false
local NET_MODE, JOIN_ADDRESS = nil, nil -- "host" | "client" | nil
for i, value in ipairs(arg or {}) do
    if value == "--level" and arg[i + 1] then
        LEVEL_NAME = arg[i + 1]
    elseif value == "--local-coop" then
        LOCAL_COOP = true
    elseif value == "--host" then
        NET_MODE = "host"
    elseif value == "--join" and arg[i + 1] then
        NET_MODE, JOIN_ADDRESS = "client", arg[i + 1]
    end
end

local level                         -- nil on a client until the host's welcome
local slots = {}                    -- local players in join order
local remoteIds = {}                -- id -> true: the session's players on other machines
local clock = fixedstep.new(1 / 60) -- the simulation runs in fixed 60 Hz ticks
local alpha = 0                     -- how far the frame sits between ticks (drawing)
local tick = 0                      -- ticks since the level was built

local RESTART_COUNTDOWN = 5 -- seconds from a passed restart vote to the restart
local votes = {}            -- player id -> true: votes to restart
local countdown = nil       -- seconds left until the restart, while the vote passes
local outbox = {}           -- session messages for the other machines
local generation = 0        -- the level's (re)start number; messages from older ones are stale

local net = nil             -- the network session (core/net/session.lua), if any
local netStatus = nil       -- what to tell the player about the session ("connecting", a reason)
local owner = playersync.owner() -- this machine's player: send sequence and authority
local remoteSync = {}       -- host: id -> playersync.remote(); client: id -> newest sequence
local hostSends = {}        -- host: reliable messages for one client { id, message } (setPlayer)
local world = nil           -- host: worldsync.host(); client: worldsync.client()
local worldEvents = {}      -- host: events for the clients since the last send
local pendingSet = {}       -- host: id -> changes a script made to that remote player
local pending = {}          -- client: entity id -> claim in flight (core/net/worldsync.lua settle)
local inflight = {}         -- client: claim number -> claim, until the host's verdict
local claimSeq = 0          -- client: claims sent this session
local NET_PORT, NET_BIND = nil, nil -- tests host on another port and address

local MAX_SEED = 2147483646 -- seeds are 1..MAX_SEED (the MINSTD generator's range)

-- Every player id in the session, sorted: local slots and remote players.
local function sessionIds()
    local ids = {}
    for _, slot in ipairs(slots) do
        ids[#ids + 1] = slot.id
    end
    for id in pairs(remoteIds) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    return ids
end

local function slotWithId(id)
    for _, slot in ipairs(slots) do
        if slot.id == id then
            return slot
        end
    end
    return nil
end

-- The lowest player id nobody in the session uses, or nil when full.
local function freeId()
    local used = {}
    for _, id in ipairs(sessionIds()) do
        used[id] = true
    end
    for id = 1, Level.MAX_PLAYERS do
        if not used[id] then
            return id
        end
    end
    return nil
end

-- Add a player with id `id` at (x, y); that point is also its respawn point.
-- Another machine's player is a puppet (core/net/playersync.lua).
local function spawn(x, y, id)
    local player = playerModule.new(x, y)
    if remoteIds[id] then
        playersync.makePuppet(player)
    end
    level:addPlayer(player, id)
    return player
end

-- Take a player out of the level (its machine left). Whatever it carried, or
-- whoever carried it, is let go.
local function removePlayer(player)
    if player.carrying then
        player.carrying.held = false
        player.carrying.heldBy = nil
        player.carrying = nil
    end
    if player.heldBy then
        player.heldBy.carrying = nil
        player.held, player.heldBy = false, nil
    end
    for i, other in ipairs(level.players) do
        if other == player then
            table.remove(level.players, i)
            break
        end
    end
    votes[player.id] = nil
end

local function playerWithId(id)
    for _, player in ipairs(level and level.players or {}) do
        if player.id == id then
            return player
        end
    end
    return nil
end

local function buildLevel(seed)
    -- The watchdog blames a freeze from here on (even while scripts load) on
    -- this level.
    local root = loader.rootFor(LEVEL_NAME)
    watchdog.enter(root)
    level = Level.load(root, { seed = seed })
    fx.clearEffects(level)
    for _, id in ipairs(sessionIds()) do
        local slot = slotWithId(id)
        local player = spawn(level.spawn.x, level.spawn.y, id)
        if slot then
            player.respawns = slot.player and slot.player.respawns or 0
            slot.player = player
        end
    end
    if NET_MODE == "host" then
        for _, record in pairs(remoteSync) do
            record.last, record.forward = nil, nil -- a new level: no previous position
        end
        worldsync.reset(world) -- every client gets a full snapshot of the new level
        worldEvents, pendingSet = {}, {}
    elseif NET_MODE == "client" then
        level.remoteWorld = true -- the host owns the world; this machine runs its player
        world, pending, inflight = worldsync.client(), {}, {}
    end
    votes, countdown = {}, nil
    tick = 0
    clock:reset()
    interp.clear()
    alpha = 0
end

-- The ids of the players this machine plays: every slot's player. Camera,
-- HUD, shake and full sound follow these; other players' events only get
-- positional sound. In local play that is every player.
local function localIds()
    local ids = {}
    for _, slot in ipairs(slots) do
        ids[slot.id] = true
    end
    return ids
end

-- Rebuild the level from its package with the host's seed. The host calls it
-- after a passed vote; a client calls it on the host's restart message, so
-- the seed is checked like any network input. Returns false for a bad seed
-- (nothing changes).
function gameplay.restart(seed)
    if type(seed) ~= "number" or seed % 1 ~= 0 or seed < 1 or seed > MAX_SEED then
        return false
    end
    buildLevel(seed)
    return true
end

-- Host only: pick a fresh seed, announce it with the next generation, and
-- restart with it.
local function hostRestart()
    local seed = love.math.random(1, MAX_SEED)
    generation = generation + 1
    outbox[#outbox + 1] = { t = "restart", seed = seed, generation = generation, players = sessionIds() }
    gameplay.restart(seed)
end

-- The session messages queued for the other machines since the last call, in
-- order; the list is then empty. A host session sends them on the reliable
-- channel each frame.
function gameplay.takeOutbox()
    local list = outbox
    outbox = {}
    return list
end

local function sameDevice(a, b)
    return a.kind == b.kind and a.layout == b.layout and a.joystick == b.joystick
end

-- Deprecated (local couch co-op): only `--local-coop` key/gamepad presses and
-- tests call it. Join a new local player driven by `source`. It appears at
-- player 1's current respawn point (their last checkpoint). Returns the
-- player, or nil when the level is full or the device already plays.
function gameplay.join(source)
    local id = freeId()
    if not id or not level then
        return nil
    end
    for _, slot in ipairs(slots) do
        if sameDevice(slot.source, source) then
            return nil
        end
    end
    local first = slots[1].player
    local slot = { source = source, id = id, player = spawn(first.spawnX, first.spawnY, id) }
    slots[#slots + 1] = slot
    return slot.player
end

-- Every local player's respawn count back to 0 (called when the level is won).
function gameplay.resetRespawns()
    for _, slot in ipairs(slots) do
        slot.player.respawns = 0
    end
end

-- Toggle the restart vote of the player in slot `index`. A client sends it
-- to the host, which counts the votes.
function gameplay.toggleVote(index)
    local slot = slots[index]
    if slot then
        local id = slot.id
        votes[id] = not votes[id] or nil
        if NET_MODE == "client" and net then
            net:vote(votes[id] == true)
        end
    end
end

local function voteCount()
    local count = 0
    for _, id in ipairs(sessionIds()) do
        if votes[id] then
            count = count + 1
        end
    end
    return count
end

-- Each tick on the host: run the countdown while more than half of all
-- players vote.
local function updateVote(step)
    if voteCount() * 2 <= #sessionIds() then
        countdown = nil
        return
    end
    countdown = (countdown or RESTART_COUNTDOWN) - step
    if countdown <= 0 then
        hostRestart()
    end
end

local function slotIndexFor(source)
    for index, slot in ipairs(slots) do
        if sameDevice(slot.source, source) then
            return index
        end
    end
    return nil
end

-- Everything that moves between ticks, for draw interpolation.
local function movingBodies()
    local bodies = {}
    for _, player in ipairs(level.players) do
        bodies[#bodies + 1] = player
    end
    for _, list in ipairs({ level.enemies, level.props }) do
        for _, body in ipairs(list) do
            bodies[#bodies + 1] = body
        end
    end
    return bodies
end

-- ── Network play ──────────────────────────────────────────────────────────

-- Sounds for another machine's player events (they arrive with its state).
local function presentRemoteEvents(id, names, puppet)
    local list = {}
    for i, name in ipairs(names) do
        list[i] = { type = "player", name = name, player = id, x = puppet.x, y = puppet.y }
    end
    level:protect(present.all, list, level, localIds())
end

-- Host: a kick claim hit `victim`: its own machine applies the knock.
local function knock(victim, direction)
    if not victim.remote then
        claims.knock(victim, direction)
        return
    end
    local record = remoteSync[victim.id]
    if record then
        local message = playersync.overrideMessage(record, {
            vx = direction * playerModule.CONFIG.playerKickPush,
            vy = playerModule.CONFIG.playerKickLift,
            kb = playerModule.CONFIG.knockbackTime,
        })
        message.g = generation
        hostSends[#hostSends + 1] = { id = victim.id, message = message }
    end
end

-- This step's claims: a client sends them (its world changes stay pending
-- until the host's verdict); the host judges its own player's kicks on other
-- machines' players.
local function handleClaims()
    local list = claims.take(level)
    if not net then
        return
    end
    for _, claim in ipairs(list) do
        if NET_MODE == "client" then
            claimSeq = claimSeq + 1
            inflight[claimSeq] = claim
            if claim.k ~= "kickPlayer" then
                pending[claim.id] = { expires = love.timer.getTime() + 3 }
            end
            local vx = claim.vx and math.max(-playersync.MAX_COORD, math.min(playersync.MAX_COORD, claim.vx))
            local vy = claim.vy and math.max(-playersync.MAX_COORD, math.min(playersync.MAX_COORD, claim.vy))
            net:sendClaim({ t = "claim", g = generation, c = claimSeq, k = claim.k, id = claim.id,
                d = claim.d and (claim.d < 0 and -1 or 1), vx = vx, vy = vy })
        elseif claim.k == "kickPlayer" then
            local ok, victim, direction = claims.judge(level, claim.player, claim)
            if ok and victim then
                knock(victim, direction)
            end
        end
    end
end

-- The host's side of the session (core/net/session.lua handler).
local hostHandler = {
    accept = function()
        local id = freeId()
        if not id or not level then
            return nil, "session is full"
        end
        return id
    end,
    -- A client finished the handshake: its player joins at the host's latest
    -- checkpoint (the host player's respawn point).
    welcome = function(id)
        remoteIds[id] = true
        remoteSync[id] = playersync.remote()
        local hostPlayer = slots[1].player
        local x, y = hostPlayer.spawnX, hostPlayer.spawnY
        spawn(x, y, id)
        -- Its machine builds the level at the start; move it to the checkpoint
        -- (sent after the welcome, on the same reliable channel).
        local place = playersync.place(remoteSync[id], x, y)
        place.g = generation
        hostSends[#hostSends + 1] = { id = id, message = place }
        worldsync.addClient(world, id) -- a full snapshot at the next send
        return { seed = level.seed, generation = generation, players = sessionIds() }
    end,
    left = function(id)
        remoteIds[id] = nil
        remoteSync[id] = nil
        pendingSet[id] = nil
        worldsync.removeClient(world, id)
        local player = playerWithId(id)
        if player then
            removePlayer(player)
        end
    end,
    vote = function(id, on)
        if remoteIds[id] then
            votes[id] = on or nil
        end
    end,
    -- A client's claim: judged with the same entity hooks the rules use, and
    -- answered with the snapshot number that will show the outcome.
    claim = function(id, message)
        local puppet = playerWithId(id)
        local ok, victim, direction = false, nil, nil
        if message.g == generation and puppet and puppet.remote then
            level:protect(function()
                ok, victim, direction = claims.judge(level, puppet, message)
            end)
        end
        hostSends[#hostSends + 1] = { id = id, message = { t = "verdict", g = message.g, c = message.c,
            ok = ok == true, n = world.n + 1 } }
        if ok and victim then
            knock(victim, direction)
        end
    end,
    -- A client's player state: newest wins; the referee refuses the clearly
    -- impossible and puts the player back with a setPlayer.
    state = function(id, message)
        local puppet, record = playerWithId(id), remoteSync[id]
        if message.g ~= generation or not puppet or not record then
            return -- from another level generation, or a player not in this level
        end
        if message.s > record.seq then
            worldsync.acknowledge(world, id, message.k) -- the newest world snapshot it has
        end
        local result = playersync.receive(record, message, puppet, level, love.timer.getTime())
        if result == "refused" then
            local correction = playersync.correction(record, puppet)
            correction.g = generation
            hostSends[#hostSends + 1] = { id = id, message = correction }
        elseif result == "ok" then
            presentRemoteEvents(id, message.e, puppet)
        end
    end,
}

-- The client's side of the session.
local pendingLevel -- the level name the host announced, until its welcome
local clientHandler = {
    -- The host plays `name`: this machine must have the same files.
    level = function(name, fingerprint)
        local root = "levels/" .. name
        if not love.filesystem.getInfo(root .. "/level.json", "file") then
            return false, "you do not have the host's level " .. name
        end
        if levelpack.fingerprint(root) ~= fingerprint then
            return false, "your copy of level " .. name .. " differs from the host's"
        end
        pendingLevel = name
        return true
    end,
    welcome = function(message)
        LEVEL_NAME = pendingLevel
        slots[1].id = message.you
        remoteIds = {}
        for _, id in ipairs(message.players) do
            if id ~= message.you then
                remoteIds[id] = true
            end
        end
        generation = message.generation
        owner, remoteSync = playersync.owner(), {}
        gameplay.restart(message.seed)
        netStatus = nil
    end,
    -- The host's world: a snapshot delta (or a full one). Newer ones are
    -- applied to the level; the restart votes come with it.
    world = function(message)
        if message.g ~= generation or not level then
            return
        end
        local state = worldsync.receive(world, message)
        if state then
            worldsync.settle(pending, state.n, love.timer.getTime())
            level:protect(worldsync.apply, level, state, pending)
            votes = {}
            for _, id in ipairs(message.vt) do
                votes[id] = true
            end
            countdown = message.cd or nil
        end
    end,
    -- One-off happenings in the host's world: debris, explosions, corpses,
    -- sounds and level scripts' messages.
    events = function(message)
        if message.g ~= generation or not level then
            return
        end
        local list = {}
        local own = slots[1].player
        for _, event in ipairs(message.list) do
            if event.type == "explosion" and claims.caughtBy(own, event) then
                own:die() -- this machine decides its own player's death
            end
            if worldsync.FORWARD_EVENTS[event.type] then
                list[#list + 1] = worldsync.localEvent(level, event)
            end
        end
        level:protect(present.all, list, level, localIds())
    end,
    -- The host's answer to a claim: the claimed entity follows the host again
    -- from snapshot n on (a denied claim is undone by it). A denied grab drops
    -- what this machine's player holds.
    verdict = function(message)
        local claim = inflight[message.c]
        inflight[message.c] = nil
        if message.g ~= generation or not claim or not level then
            return
        end
        if pending[claim.id] then
            pending[claim.id]["until"] = message.n
        end
        local own = slots[1].player
        if not message.ok and claim.k == "grab" and own.carrying and own.carrying.id == claim.id then
            own.carrying.held = false
            own.carrying = nil
        end
    end,
    restart = function(message)
        if message.generation <= generation then
            return -- stale
        end
        generation = message.generation
        remoteIds = {}
        for _, id in ipairs(message.players) do
            if id ~= slots[1].id then
                remoteIds[id] = true
            end
        end
        gameplay.restart(message.seed)
    end,
    joined = function(id)
        if id ~= slots[1].id and not remoteIds[id] and level then
            remoteIds[id] = true
            remoteSync[id] = nil -- a new player: its sequence starts again
            spawn(level.spawn.x, level.spawn.y, id) -- placed by its first state
        end
    end,
    -- The other players' states, forwarded by the host: newest wins per player.
    players = function(message)
        if message.g ~= generation or not level then
            return
        end
        for _, entry in ipairs(message.list) do
            local id = entry[1]
            local puppet = id ~= slots[1].id and playerWithId(id)
            if puppet and puppet.remote and playersync.accept(remoteSync, entry, puppet) then
                presentRemoteEvents(id, entry[4], puppet)
            end
        end
    end,
    -- The host overrides this machine's player (late join at a checkpoint, a
    -- refused move).
    setPlayer = function(message)
        if message.g == generation and level then
            playersync.override(owner, slots[1].player, message)
        end
    end,
    left = function(id)
        remoteIds[id] = nil
        remoteSync[id] = nil
        local player = playerWithId(id)
        if player then
            removePlayer(player)
        end
    end,
    closed = function(reason)
        netStatus = "Disconnected: " .. tostring(reason)
    end,
}

local function startNetwork()
    if NET_MODE == "host" then
        local err
        net, err = session.host({
            port = NET_PORT,
            bind = NET_BIND,
            level = { name = LEVEL_NAME, fingerprint = levelpack.fingerprint(level.root) },
            handler = hostHandler,
        })
        if not net then
            netStatus = "Could not host: " .. tostring(err)
        end
    elseif NET_MODE == "client" then
        local err
        net, err = session.join(JOIN_ADDRESS, clientHandler)
        netStatus = net and ("Connecting to " .. JOIN_ADDRESS .. "...") or ("Could not join: " .. tostring(err))
    end
end

-- End network play (going to the main menu ends the session).
function gameplay.closeNetwork()
    if net then
        net:close()
        net = nil
    end
end

local function flushOutbox()
    for _, message in ipairs(gameplay.takeOutbox()) do
        net:broadcast(message)
    end
end

local function voteList()
    local list = {}
    for _, id in ipairs(sessionIds()) do
        if votes[id] then
            list[#list + 1] = id
        end
    end
    return list
end

-- The host's world to every client: capture a snapshot (under script limits:
-- script state that is not plain data stops the level), then a delta or full
-- snapshot per client, then the events since the last send.
local function sendWorld()
    local state
    local ok, err = script.protect(function()
        state = worldsync.capture(world, level)
    end)
    if not ok then
        level:fault(err)
        return
    end
    for id in pairs(world.clients) do
        local message, full = worldsync.messageFor(world, id, state, love.timer.getTime())
        if message then
            message.g, message.vt, message.cd = generation, voteList(), countdown or false
            net:sendTo(id, message, not full)
        end
    end
    if #worldEvents > 0 then
        net:broadcast({ t = "events", g = generation, list = worldEvents })
        worldEvents = {}
    end
end

-- 20 times a second: a client sends its player's state (and the newest world
-- snapshot it has) to the host; the host sends every player's newest state to
-- the clients (its own, and the clients' it accepted since the last send),
-- the setPlayers its scripts caused, and the world.
local function sendNetwork()
    local own = playersync.nextState(owner, slots[1].player)
    if NET_MODE == "client" then
        net:sendState({ t = "state", g = generation, s = own.s, a = own.a, p = own.p, e = own.e,
            k = worldsync.ack(world) })
        return
    end
    flushOutbox() -- a restart goes out before the new level's world
    local list = { { slots[1].id, own.s, own.p, own.e } }
    for id, record in pairs(remoteSync) do
        if record.forward then
            list[#list + 1] = { id, record.forward.s, record.forward.p, record.forward.e }
            record.forward = nil
        end
    end
    net:broadcastState({ t = "players", g = generation, list = list })
    for id, pending in pairs(pendingSet) do
        if remoteSync[id] then
            local message = playersync.overrideMessage(remoteSync[id], pending)
            message.g = generation
            hostSends[#hostSends + 1] = { id = id, message = message }
        end
    end
    pendingSet = {}
    sendWorld()
end

-- Is this machine playing a level right now (a client waits for its welcome)?
local function playing()
    return level ~= nil and not (NET_MODE == "client" and (not net or net.stage ~= "joined"))
end

-- ── Scene ─────────────────────────────────────────────────────────────────

function gameplay.load()
    playerModule.load()
    slots = { { source = input.keyboard(1), id = 1 } }
    remoteIds = {}
    outbox = {}
    generation = 0
    owner, remoteSync, hostSends = playersync.owner(), {}, {}
    world = NET_MODE == "host" and worldsync.host() or nil
    if NET_MODE == "client" then
        level = nil
    else
        hostRestart()
    end
    startNetwork()
end

function gameplay.update(delta)
    if net then
        net:service()
    end
    if not playing() then
        return
    end
    alpha = clock:advance(delta, function(step)
        for _, slot in ipairs(slots) do
            slot.player.input = slot.source.read(level.actions)
        end
        interp.record(movingBodies())
        local seen = {} -- host: remote players before the step (did a script move one?)
        for _, player in ipairs(level.players) do
            if player.remote then
                playersync.advance(player, step, level)
                seen[player] = NET_MODE == "host" and playersync.watch(player) or nil
            end
        end
        local client = NET_MODE == "client"
        if client then
            worldsync.advance(level, step)
        end
        local wasFinished = level.finished
        level:update(step, client and worldsync.CLIENT_STAGES or nil)
        tick = tick + 1
        for player, before in pairs(seen) do
            pendingSet[player.id] = playersync.changes(pendingSet[player.id], before, player)
        end
        level:protect(handleClaims)
        local events = level:takeEvents()
        playersync.noteEvents(owner, events, slots[1].id)
        if NET_MODE == "host" and net then
            for _, event in ipairs(events) do
                if worldsync.FORWARD_EVENTS[event.type] and #worldEvents < 256 then
                    worldEvents[#worldEvents + 1] = netstate.event(event)
                end
            end
        end
        level:protect(present.all, events, level, localIds())
        if not wasFinished and level.finished and level.finished.outcome == "win" then
            gameplay.resetRespawns()
        end
        if NET_MODE ~= "client" then
            updateVote(step)
        end
        if net and tick % playersync.SEND_EVERY == 0 then
            sendNetwork()
        end
    end)
    if NET_MODE == "host" and net then
        flushOutbox()
        for _, send in ipairs(hostSends) do
            net:sendTo(send.id, send.message)
        end
        hostSends = {}
    end
end

function gameplay.keypressed(key)
    if key == "escape" then
        gameplay.closeNetwork()
        fx.toScene("menu", 0.5, { ease = "smoothstep" })
    elseif not playing() then
        return
    elseif input.layoutForKey(key, "restart") then
        gameplay.toggleVote(slotIndexFor(input.keyboard(input.layoutForKey(key, "restart"))))
    elseif LOCAL_COOP then
        local layout = input.layoutForKey(key, "jump")
        if layout then
            gameplay.join(input.keyboard(layout))
        end
    end
end

-- Gamepads are deprecated for now: they only work with `--local-coop`, as
-- joined couch co-op players. The single player plays on the keyboard.
function gameplay.gamepadpressed(joystick, button)
    if not LOCAL_COOP or not playing() then
        return
    end
    if button == input.GAMEPAD_RESTART then
        gameplay.toggleVote(slotIndexFor(input.gamepad(joystick)))
    elseif button == "a" or button == "start" then
        gameplay.join(input.gamepad(joystick))
    end
end

local worldPushed = false -- camera.pushWorld is active (popped even after a failure)

-- Everything the level draws. It runs under script limits (level:protect):
-- entities, events and level scripts may run script code while drawing.
local function drawLevel()
    interp.apply(movingBodies(), alpha)
    camera.frame(level, localIds())
    level:drawBackground()
    camera.pushWorld()
    worldPushed = true
    level:draw()
    fx.drawDebris()
    fx.drawCorpses()
    level:drawPlayers()
    fx.drawExplosions()
    level:drawWorld()
    camera.popWorld()
    worldPushed = false
    level:drawHud()
    hud.draw(level.players, LOCAL_COOP and #slots < Level.MAX_PLAYERS, localIds())
end

-- A full-screen message over the level: a title, a line of detail, and the
-- keys that still work.
local function drawBanner(title, detail, color, keys)
    love.graphics.setColor(0, 0, 0, 0.75)
    love.graphics.rectangle("fill", 0, 0, render.width, render.height)
    love.graphics.setColor(color[1], color[2], color[3], 1)
    text.printf(title, 0, render.height / 2 - 40, render.width, "center", 16)
    love.graphics.setColor(1, 1, 1, 0.85)
    if detail then
        text.printf(detail, 24, render.height / 2 - 12, render.width - 48, "center", 10)
    end
    text.printf(keys or "R vote restart   ESC menu", 0, render.height / 2 + 30, render.width, "center", 10)
end

local OUTCOME_TITLES = { win = "LEVEL CLEAR", lose = "GAME OVER" }

-- Shown once a script stopped the level (Level:fault), or a gamemode ended it
-- (Level:finish).
local function drawStopped()
    if level.faulted then
        local reason = level.faulted:match("^[^\n]*"):sub(1, 140)
        drawBanner("THIS LEVEL STOPPED", reason, { 1, 0.85, 0.4 })
    else
        local finished = level.finished
        local title = OUTCOME_TITLES[finished.outcome] or finished.outcome:upper()
        drawBanner(title, finished.message, finished.outcome == "lose" and { 1, 0.45, 0.4 } or { 0.55, 1, 0.6 })
    end
end

-- A one-line session notice at the top of the screen.
local function drawNetStatus()
    love.graphics.setColor(0, 0, 0, 0.7)
    love.graphics.rectangle("fill", 0, 0, render.width, 18)
    love.graphics.setColor(1, 0.85, 0.4, 1)
    text.printf(netStatus, 8, 4, render.width - 16, "left", 10)
    love.graphics.setColor(1, 1, 1, 1)
end

function gameplay.draw()
    if not playing() then
        love.graphics.clear(0, 0, 0, 1)
        drawBanner(netStatus and netStatus:match("^Disconnected") and "DISCONNECTED" or "NETWORK PLAY",
            netStatus or "", { 1, 0.85, 0.4 }, "ESC menu")
        return
    end
    level:protect(drawLevel)
    if worldPushed then
        camera.popWorld()
        worldPushed = false
    end
    interp.restore()
    love.graphics.setShader()
    if level.faulted or level.finished then
        drawStopped()
    end
    hud.drawVote(level.players, votes, countdown)
    if netStatus then
        drawNetStatus()
    end
end

-- Exposed for automated smoke tests and debugging.
function gameplay.getPlayer(index)
    local slot = slots[index or 1]
    return slot and slot.player
end

function gameplay.getLevel()
    return level
end

function gameplay.getGeneration()
    return generation
end

-- Tests: play as "host" or "client" (address) without a command line, on
-- another port and bind address. Takes effect at the next gameplay.load.
function gameplay.configure(options)
    NET_MODE, JOIN_ADDRESS = options.mode, options.address
    NET_PORT, NET_BIND = options.port, options.bind
    LEVEL_NAME = options.level or LEVEL_NAME
end

function gameplay.getNetwork()
    return net
end

-- Replace a slot's input source (tests drive players with scripted sources).
function gameplay.setSource(index, source)
    slots[index].source = source
end

sceneEngine.register("gameplay", {
    enter = function()
        audio.playMusic("playground.wav")
        if level then
            watchdog.enter(level.root)
        end
    end,
    exit = function()
        gameplay.closeNetwork()
        watchdog.leave()
    end,
    update = gameplay.update,
    keypressed = gameplay.keypressed,
    gamepadpressed = gameplay.gamepadpressed,
    draw = gameplay.draw,
})

return gameplay
