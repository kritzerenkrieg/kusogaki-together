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
-- and is its own host.
--
-- Rooms (Multiplayer in the menu, scenes/lobby.lua and scenes/room.lua): a
-- session starts in the waiting room. The host picks the level and starts a
-- countdown; at its end every player in the room plays that level. When the
-- level is over the host takes everyone back to the room. With drop-in on, a
-- player who joins while a level is played joins it at the host's last
-- checkpoint; otherwise the room is closed to joins until it is back in the
-- waiting room. The host sends the room's state to every player on each
-- change (protocol `room`) and to the server's room list with its polls.
-- `--host` from the command line skips the waiting room: it plays at once,
-- with drop-in. The host is the source of truth: it picks each
-- (re)start's seed and generation and announces them as a `restart` session
-- message (gameplay.takeOutbox); every machine, the host included, restarts
-- through gameplay.restart(seed). Player ids stay stable for the session, so
-- remote players keep theirs across restarts.
--
-- Hybrid rollback: clients send their inputs every tick
-- (core/net/inputsync.lua); the host simulates every player and the world
-- and sends its whole state 20 times a second (core/net/statesync.lua,
-- core/level/fullstate.lua). A client runs ahead of the host, predicting
-- with its own inputs and the others' last known ones; when a host state
-- arrives it restores it and replays its inputs since. Effects and sounds
-- play once per tick and event, not again in a replay.
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
local levelpack = require("core.levelpack")
local levels = require("core.levels")
local repo = require("core.net.repo")
local session = require("core.net.session")
local inputsync = require("core.net.inputsync")
local statesync = require("core.net.statesync")
local fullstate = require("core.level.fullstate")
local script = require("core.script")
local watchdog = require("core.watchdog")
local rendezvous = require("core.net.rendezvous")
local protocol = require("core.net.protocol")

local gameplay = {}

-- Command line (testing shortcuts; players use Multiplayer in the menu):
-- `--level <name>` picks the level (levels/<name> in the save directory,
-- default "kusogaki_stage1"; a client plays the host's); `--host` / `--join <ip[:port]>` start network play
-- directly over a LAN or 127.0.0.1, without the server;
-- `--net-lag <ms> --net-loss <percent>` make this machine's connection worse
-- for testing (core/net/session.lua); `--local-coop` turns on the deprecated
-- couch co-op. Internet play through a server (your own for testing):
-- `--host --online` opens a room on our server and shows its code;
-- `--code <6 digits>` joins one; `--server <host[:port]>` names the server;
-- `--relay-only` (host) relays every client of the room.
local LEVEL_ROOT = "levels/kusogaki_stage1" -- the level played (or the room's level)
local LOCAL_COOP = false
local NET_MODE, JOIN_ADDRESS = nil, nil -- "host" | "client" | nil
local NET_LAG, NET_LOSS = 0, 0          -- simulated extra round trip (s) and loss (fraction)
local ONLINE = nil                      -- { server, code, relayOnly } for internet play
local onlineOptions = { server = nil, relayOnly = false }
for i, value in ipairs(arg or {}) do
    if value == "--level" and arg[i + 1] then
        local ok, root = pcall(loader.rootFor, arg[i + 1])
        LEVEL_ROOT = ok and root or LEVEL_ROOT
    elseif value == "--local-coop" then
        LOCAL_COOP = true
    elseif value == "--host" then
        NET_MODE = "host"
    elseif value == "--join" and arg[i + 1] then
        NET_MODE, JOIN_ADDRESS = "client", arg[i + 1]
    elseif value == "--net-lag" and tonumber(arg[i + 1]) then
        NET_LAG = tonumber(arg[i + 1]) / 1000
    elseif value == "--net-loss" and tonumber(arg[i + 1]) then
        NET_LOSS = tonumber(arg[i + 1]) / 100
    elseif value == "--online" then
        ONLINE = onlineOptions
    elseif value == "--code" and arg[i + 1] then
        NET_MODE, ONLINE = "client", onlineOptions
        onlineOptions.code = arg[i + 1]
    elseif value == "--server" and arg[i + 1] then
        onlineOptions.server = arg[i + 1]
    elseif value == "--relay-only" then
        onlineOptions.relayOnly = true
    end
end
session.emulate(NET_LAG, NET_LOSS)

local level                         -- nil on a client until the host's welcome
local slots = {}                    -- local players in join order
local remoteIds = {}                -- id -> true: the session's players on other machines
local clock = fixedstep.new(1 / 60) -- the simulation runs in fixed 60 Hz ticks
local alpha = 0                     -- how far the frame sits between ticks (drawing)
local tick = 0                      -- ticks since the level was built

local RESTART_COUNTDOWN = 5 -- seconds from a passed restart vote to the restart
local DEFAULT_MUSIC = "playground.flac" -- for levels without "music"
local VICTORY_SOUND = "victory.wav"
local votes = {}            -- player id -> true: votes to restart
local countdown = nil       -- seconds left until the restart, while the vote passes
local outbox = {}           -- session messages for the other machines
local generation = 0        -- the level's (re)start number; messages from older ones are stale

local net = nil             -- the network session (core/net/session.lua), if any
local netStatus = nil       -- what to tell the player about the session ("connecting", a reason)
local states = nil          -- host: statesync.host(); client: statesync.client()
local inputs = nil          -- host: inputsync.host(); client: inputsync.client() (its own)
local remoteMasks = {}      -- client: id -> the input the host used for that player at its state's tick
local remoteFrames = {}     -- client: id -> tick -> that player's input, forwarded by the host (ahead)
local usedRemote = {}       -- client: tick -> id -> the input it predicted for that player then
local wrongFrom = nil       -- client: the first tick predicted with an input now known to be wrong
local forwarded = {}        -- host: client id -> player id -> the newest input tick sent to it
local predicting = false    -- client: has a host state and runs ahead of it
local margin = nil          -- client: how many ticks early its inputs reach the host (smoothed)
local presented = {}        -- client: tick -> event signatures already shown
local predicted = {}        -- client: tick -> its predicted state then (flat), for ticks the host sends
local SEND_EVERY = 3        -- host ticks between states (20 a second; G3)
local MARGIN_KEEP = 0.9 ^ (SEND_EVERY / 3) -- margin smoothing per state: the same per second at any rate
local NET_PORT, NET_BIND = nil, nil -- tests host on another port and address

local MAX_SEED = 2147483646 -- seeds are 1..MAX_SEED (the MINSTD generator's range)

-- The room (network play). On the host: its settings, the players in it and
-- their names; on a client: the host's last `room` message.
local ROOM_COUNTDOWN = 3    -- seconds from Start to the level
local PLAYER_NAME = "Player"
local room = nil            -- client: the host's room message; host: built by roomMessage()
local roomSettings = { name = "Room", dropIn = true, public = true }
local members = {}          -- host: player id -> { name, has } for everyone in the room (itself too)
local roomState = "waiting" -- host: "waiting" | "countdown" | "playing"
local roomCountdown = nil   -- host: seconds left, while counting down
local roomDirty = true      -- host: the room changed since it was last sent
local sentHas = nil         -- client: the "has" fingerprint last sent (for the room's level)
local fingerprints = {}     -- level root -> its fingerprint ("" when missing), per session
local download = nil        -- client: { id, request, err } getting the room's level from the server
local onServer = nil        -- host: { id, request, result } whether the room's level is on the server

-- The fingerprint (package id) of the level at `root`, or "" without one.
local function fingerprintOf(root)
    if fingerprints[root] == nil then
        fingerprints[root] = love.filesystem.getInfo(root .. "/level.json", "file")
            and levelpack.fingerprint(root) or ""
    end
    return fingerprints[root]
end

-- A level's name for the room and the room list.
local function levelTitle(root)
    local entry = levels.byRoot(root)
    return entry and entry.name or (root:match("[^/]+$") or "level"):sub(1, 32)
end

-- Switch to `name` unless it is already the scene (the room and the level
-- follow what the host does).
local function showScene(name)
    if sceneEngine.current ~= name then
        sceneEngine.switch(name)
    end
end

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
    for id in pairs(members) do
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
local function spawn(x, y, id)
    local player = playerModule.new(x, y)
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
    local root = loader.rootFor(LEVEL_ROOT)
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
        statesync.reset(states) -- every client gets a full state of the new level
        inputsync.reset(inputs) -- tick numbers start again
        forwarded = {}
    elseif NET_MODE == "client" then
        states, inputs = statesync.client(), inputsync.client()
        remoteMasks, predicting, margin, presented, predicted = {}, false, nil, {}, {}
        remoteFrames, usedRemote, wrongFrom = {}, {}, nil
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
-- restart with it. Only players in the level hear it (not those still in the
-- room, waiting to drop in).
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

-- An event's identity within its tick, so a replay shows only what is new.
local function signature(event)
    return ("%s:%s:%s:%s"):format(event.type, tostring(event.id), tostring(event.player), tostring(event.name))
end

-- Show a tick's events, except those already shown for that tick (a replay
-- produces most of them again).
local function presentOnce(t, events)
    local seen = presented[t]
    if not seen then
        seen = {}
        presented[t] = seen
        presented[t - 240] = nil
    end
    local fresh = {}
    for _, event in ipairs(events) do
        local key = signature(event)
        if not seen[key] then
            seen[key] = true
            fresh[#fresh + 1] = event
        end
    end
    level:protect(present.all, fresh, level, localIds())
end

-- ── The room (host) ───────────────────────────────────────────────────────

-- The levels this machine has (core/levels.lua): its own and downloaded ones.
function gameplay.levels()
    return levels.list()
end

-- The room as every player sees it (protocol `room`).
local function roomMessage()
    local players = {}
    local ids = {}
    for id in pairs(members) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    local fp = fingerprintOf(LEVEL_ROOT)
    for _, id in ipairs(ids) do
        players[#players + 1] = { id = id, name = members[id].name, has = members[id].has == fp }
    end
    local code = net and net.room and net:room() or nil
    return {
        t = "room", name = roomSettings.name, code = code or "", level = levelTitle(LEVEL_ROOT), fp = fp,
        st = roomState, cd = roomCountdown and math.ceil(roomCountdown) or 0,
        di = roomSettings.dropIn, pub = roomSettings.public, relay = ONLINE and ONLINE.relayOnly == true or false,
        players = players,
    }
end

-- Put player `id` (a client in the room) into the level being played, at
-- `x, y`; its machine learns everything else from the host's states.
local function addToLevel(id, x, y)
    remoteIds[id] = true
    spawn(x, y, id)
    inputsync.addPlayer(inputs, id)
    statesync.addClient(states, id) -- a full state at the next send
end

-- The countdown is over: everyone in the room plays the room's level.
local function hostStart()
    roomState, roomCountdown, roomDirty = "playing", nil, true
    local fp = fingerprintOf(LEVEL_ROOT)
    for id, member in pairs(members) do
        if id ~= slots[1].id and member.has == fp then
            remoteIds[id] = true
            inputsync.addPlayer(inputs, id)
            statesync.addClient(states, id)
        end
    end
    local seed = love.math.random(1, MAX_SEED)
    generation = generation + 1
    for id in pairs(remoteIds) do
        net:sendTo(id, { t = "start", level = levelTitle(LEVEL_ROOT), fp = fp, seed = seed, generation = generation,
            players = sessionIds() })
    end
    gameplay.restart(seed)
    showScene("gameplay")
end

-- Host: everyone back to the waiting room (the level is over).
function gameplay.backToRoom()
    if NET_MODE ~= "host" or not net or roomState ~= "playing" then
        return false
    end
    generation = generation + 1
    for id in pairs(remoteIds) do
        net:sendTo(id, { t = "toroom", generation = generation })
        inputsync.removePlayer(inputs, id)
        statesync.removeClient(states, id)
    end
    remoteIds, votes, countdown = {}, {}, nil
    level = nil
    roomState, roomDirty = "waiting", true
    showScene("room")
    return true
end

-- Host: does everyone in the room have the room's level?
local function everyoneHasLevel()
    local fp = fingerprintOf(LEVEL_ROOT)
    for _, member in pairs(members) do
        if member.has ~= fp then
            return false
        end
    end
    return fp ~= ""
end

-- Host actions from the waiting room: "level" (step through the levels by
-- `step`), "dropIn", "public", "start", "cancel". Returns false and a
-- reason when it cannot be done.
function gameplay.roomAction(action, step)
    if NET_MODE ~= "host" or not net or roomState == "playing" then
        return false, "only the host can do that"
    end
    if action == "level" then
        local list = gameplay.levels()
        local index = 0
        for i, entry in ipairs(list) do
            if entry.root == LEVEL_ROOT then index = i end
        end
        local entry = list[(index - 1 + (step or 1)) % math.max(#list, 1) + 1]
        LEVEL_ROOT = entry and entry.root or LEVEL_ROOT
        roomState, roomCountdown = "waiting", nil
    elseif action == "dropIn" then
        roomSettings.dropIn = not roomSettings.dropIn
    elseif action == "public" then
        roomSettings.public = not roomSettings.public
    elseif action == "start" then
        if not everyoneHasLevel() then
            return false, "everyone needs the level first"
        end
        roomState, roomCountdown = "countdown", ROOM_COUNTDOWN
    elseif action == "cancel" then
        roomState, roomCountdown = "waiting", nil
    end
    roomDirty = true
    return true
end

-- Host, every frame: the countdown, and the room sent to everyone and to the
-- server's list when it changed.
local function updateRoom(delta)
    if roomState == "countdown" then
        local before = math.ceil(roomCountdown)
        roomCountdown = roomCountdown - delta
        if not everyoneHasLevel() then
            roomState, roomCountdown, roomDirty = "waiting", nil, true
        elseif roomCountdown <= 0 then
            hostStart()
        elseif math.ceil(roomCountdown) ~= before then
            roomDirty = true
        end
    end
    if room and net.room and room.code ~= (net:room() or "") then
        roomDirty = true -- the server gave the room its code
    end
    if roomDirty then
        roomDirty = false
        room = roomMessage()
        net:broadcast(room)
        local count = 0
        for _ in pairs(members) do count = count + 1 end
        net:setRoomInfo({ players = count, playing = roomState == "playing", dropIn = roomSettings.dropIn,
            public = roomSettings.public, level = levelTitle(LEVEL_ROOT), name = roomSettings.name })
    end
end

-- The host's side of the session (core/net/session.lua handler).
local hostHandler = {
    accept = function()
        local id = freeId()
        if not id then
            return nil, "the room is full"
        end
        if roomState == "playing" and not roomSettings.dropIn then
            return nil, "the game has already started"
        end
        return id
    end,
    -- A client is in the room. It says which levels it has (has); while a
    -- level is played it joins it from there (drop-in).
    welcome = function(id, name)
        name = rendezvous.cleanName(name, protocol.MAX_NAME)
        members[id] = { name = name ~= "" and name or ("Player " .. id), has = nil }
        roomDirty = true
    end,
    -- Its copy of the room's level. While a level is played: in it joins at
    -- the host's latest checkpoint (the host player's respawn point), or is
    -- let go when it does not have it.
    has = function(id, fp)
        local member = members[id]
        if not member then
            return
        end
        member.has, roomDirty = fp, true
        if roomState ~= "playing" or remoteIds[id] or not level then
            return
        end
        if fp ~= fingerprintOf(LEVEL_ROOT) then
            net:kick(id, "you do not have the host's level " .. levelTitle(LEVEL_ROOT))
            return
        end
        local hostPlayer = slots[1].player
        addToLevel(id, hostPlayer.spawnX, hostPlayer.spawnY)
        net:sendTo(id, { t = "start", level = levelTitle(LEVEL_ROOT), fp = fp, seed = level.seed, generation = generation,
            players = sessionIds() })
        for other in pairs(remoteIds) do
            if other ~= id then
                net:sendTo(other, { t = "joined", id = id })
            end
        end
    end,
    left = function(id)
        if members[id] then
            members[id], roomDirty = nil, true
        end
        remoteIds[id] = nil
        inputsync.removePlayer(inputs, id)
        forwarded[id] = nil
        statesync.removeClient(states, id)
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
    -- A client's inputs (and the newest host state it has).
    input = function(id, message)
        if message.g == generation then
            inputsync.receive(inputs, id, message, tick)
            statesync.acknowledge(states, id, message.k)
        end
    end,
}

-- Client: the input player `id` most likely has at tick t: the one the host
-- forwarded for it, else the newest known before it.
local function remoteMaskAt(id, t)
    local frames = remoteFrames[id]
    if frames then
        for u = t, math.max(statesync.newest(states) + 1, t - 120), -1 do
            if frames[u] then
                return frames[u]
            end
        end
    end
    return remoteMasks[id] or 0
end

-- Client: run one tick `t` of the level with this machine's input for it
-- and the others' known or last known inputs, and show what is new in it.
local function simulate(t, step)
    local names = level.actionNames
    local used = {}
    for _, player in ipairs(level.players) do
        if player == slots[1].player then
            player.input = input.unpack(inputsync.maskAt(inputs, t), names)
        else
            used[player.id] = remoteMaskAt(player.id, t)
            player.input = input.unpack(used[player.id], names)
        end
    end
    usedRemote[t], usedRemote[t - 120] = used, nil
    level:update(step)
    tick = t
    presentOnce(t, level:takeEvents())
    if t % SEND_EVERY == 0 then -- the host sends its state after these ticks: remember ours
        local ok, state = pcall(fullstate.capture, level)
        predicted[t] = ok and statesync.flatten(state) or nil
        predicted[t - 120] = nil
    end
end

-- Client: a host state after tick h. The first one starts prediction a
-- round trip and a little ahead of it. A later one that matches what this
-- machine predicted for tick h changes nothing, unless a forwarded input
-- showed a later tick was predicted wrong; otherwise it replaces the
-- prediction for tick h and the ticks since are replayed with this
-- machine's inputs and the others' known ones.
local function reconcile(state, h, flat)
    if wrongFrom and wrongFrom <= h then
        wrongFrom = nil -- the host's state already has it right
    end
    if predicting and not wrongFrom and predicted[h] and statesync.same(predicted[h], flat) then
        return -- predicted right
    end
    wrongFrom = nil
    local now = tick
    local before = {}
    for _, body in ipairs(movingBodies()) do
        before[body] = { body.x, body.y }
    end
    local ok = level:protect(fullstate.restore, level, state)
    if not ok then
        return
    end
    tick = h
    local target
    if not predicting then
        -- A round trip ahead plus the cushion, so its inputs reach the host in
        -- time; the lead control (clientRate) fine-tunes it. ENet's first
        -- round-trip estimates run high, hence the cap.
        target = h + math.ceil(math.min(net:roundTrip(), 0.5) * 60) + inputsync.TARGET_LEAD
        predicting = true
    else
        target = math.max(now, h)
    end
    for t = h + 1, target do
        simulate(t, clock.step)
    end
    for _, body in ipairs(movingBodies()) do
        local was = before[body]
        if was then
            interp.correct(body, was[1], was[2]) -- glide from the prediction to the host's truth
        end
    end
end

-- Client: tell the host whether this machine has the room's level. In an
-- internet room a missing level is downloaded from the server first; the
-- host hears once that is done (or failed). Called every frame.
local function clientHasLevel()
    if not room or not net then
        return
    end
    local id, has = room.fp, ""
    if levelpack.isId(id) and levels.byId(id) then
        has = id
    elseif ONLINE and levelpack.isId(id) then
        if not download or download.id ~= id then
            download = { id = id, request = repo.download(ONLINE.server, id) }
        end
        local done = download.request:poll()
        if done == nil then
            return -- still downloading
        end
        has = done and levels.byId(id) and id or ""
    end
    if sentHas ~= has then
        sentHas = has
        net:has(has)
    end
end

-- Host of an internet room: is the room's level on the server (players
-- without it get it from there)? Asked once per level; a downloaded level
-- came from there.
local function checkOnServer()
    local id = fingerprintOf(LEVEL_ROOT)
    if not ONLINE or not levelpack.isId(id) or (onServer and onServer.id == id and onServer.result ~= nil) then
        return
    end
    local entry = levels.byRoot(LEVEL_ROOT)
    if entry and entry.downloaded then
        onServer = { id = id, result = true }
        return
    end
    if not onServer or onServer.id ~= id then
        onServer = { id = id, request = repo.info(ONLINE.server, id) }
    end
    local done, err = onServer.request:poll()
    if done ~= nil then
        onServer.result, onServer.err = done, err
    end
end

-- What the waiting room says about the room's level on this machine: a
-- client getting it from the server (or failing to), a host whose level is
-- not on the server. Returns the text and whether it is a warning, or nil.
function gameplay.levelStatus()
    if NET_MODE == "client" and room and download and download.id == room.fp then
        local done, err = download.request:poll()
        if done == nil then
            return "Downloading the level " .. tostring(room.level) .. "...", false
        elseif not done then
            return "Could not get the level: " .. tostring(err), true
        end
    elseif NET_MODE == "host" and onServer and onServer.id == fingerprintOf(LEVEL_ROOT) and onServer.result == false then
        if onServer.err == "not on the server" then
            return "This level is not on the server, so players without it cannot get it. "
                .. "Upload it from Singleplayer (U).", true
        end
        return "Could not ask the server about this level: " .. tostring(onServer.err), true
    end
    return nil
end

-- The client's side of the session.
local clientHandler = {
    -- In the room, with player id `you`.
    welcome = function(message)
        slots[1].id = message.you
        netStatus = nil
    end,
    -- The room changed: tell the host whether this machine has its level,
    -- after getting it from the server when it does not.
    room = function(message)
        room = message
        clientHasLevel()
    end,
    -- Play a level (everyone at the end of the countdown, or this machine
    -- dropping in): the same files as the host's, or leave.
    start = function(message)
        local entry = levels.byId(message.fp)
        if not entry then
            netStatus = "Disconnected: you do not have the level " .. tostring(message.level)
            net:close()
            return
        end
        LEVEL_ROOT = entry.root
        remoteIds = {}
        for _, id in ipairs(message.players) do
            if id ~= slots[1].id then
                remoteIds[id] = true
            end
        end
        generation = message.generation
        gameplay.restart(message.seed)
        showScene("gameplay")
    end,
    toroom = function(message)
        if message.generation <= generation then
            return -- stale
        end
        generation = message.generation
        remoteIds, votes, countdown = {}, {}, nil
        level = nil
        showScene("room")
    end,
    -- The host's state after its tick h: restore it and replay since.
    snap = function(message)
        if message.g ~= generation or not level then
            return
        end
        local state, h, flat = statesync.receive(states, message)
        if not state then
            return
        end
        for _, entry in ipairs(message.inp) do
            remoteMasks[entry[1]] = entry[2]
        end
        for _, frames in pairs(remoteFrames) do
            for t in pairs(frames) do
                if t <= h then
                    frames[t] = nil
                end
            end
        end
        votes = {}
        for _, id in ipairs(message.vt) do
            votes[id] = true
        end
        countdown = message.cd or nil
        if predicting and message.ack > 0 then -- the host has this machine's inputs
            local early = message.ack - h -- how far ahead of the host they arrived
            margin = margin and early + (margin - early) * MARGIN_KEEP or early
        end
        reconcile(state, h, flat)
    end,
    -- The others' inputs, forwarded by the host every tick. Any that differs
    -- from what this machine predicted for a tick it already ran marks a
    -- replay (gameplay.update), from the host's newest state.
    ahead = function(message)
        if message.g ~= generation or not level then
            return
        end
        local since = statesync.newest(states)
        for _, entry in ipairs(message.p) do
            local id, n, f = entry[1], entry[2], entry[3]
            if id ~= slots[1].id and remoteIds[id] then
                local frames = remoteFrames[id] or {}
                remoteFrames[id] = frames
                local first = n - #f + 1
                for i, mask in ipairs(f) do
                    if first + i - 1 > since then
                        frames[first + i - 1] = mask
                    end
                end
                for t = math.max(first, since + 1), tick do
                    local used = usedRemote[t]
                    if used and used[id] ~= nil and used[id] ~= remoteMaskAt(id, t) then
                        wrongFrom = math.min(wrongFrom or t, t)
                        break
                    end
                end
            end
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
            spawn(level.spawn.x, level.spawn.y, id) -- placed by the host's next state
        end
    end,
    left = function(id)
        remoteIds[id] = nil
        remoteMasks[id] = nil
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
            handler = hostHandler,
            rendezvous = ONLINE,
        })
        if not net then
            netStatus = "Could not host: " .. tostring(err)
        end
    elseif NET_MODE == "client" then
        local err
        net, err = session.join(JOIN_ADDRESS, clientHandler, { rendezvous = ONLINE, name = PLAYER_NAME })
        local target = ONLINE and ("room " .. tostring(ONLINE.code)) or JOIN_ADDRESS
        netStatus = net and ("Connecting to " .. target .. "...") or ("Could not join: " .. tostring(err))
    end
end

-- End network play (going to the main menu ends the session).
function gameplay.closeNetwork()
    if net then
        net:close()
        net = nil
    end
    room = nil
end

local function flushOutbox()
    for _, message in ipairs(gameplay.takeOutbox()) do
        for id in pairs(remoteIds) do
            net:sendTo(id, message)
        end
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

-- Host, after every SEND_EVERY ticks: save the level's state (under
-- script limits: script state that is not plain data stops the level) and
-- send each client its delta, with the inputs every player used.
local function sendStates()
    flushOutbox() -- a restart goes out before the new level's state
    local state
    local ok, err = script.protect(function()
        state = fullstate.capture(level)
    end)
    if not ok then
        level:fault(err)
        return
    end
    local entry = statesync.record(states, tick, state)
    local used = {}
    for _, player in ipairs(level.players) do
        used[#used + 1] = { player.id, input.pack(player.input, level.actionNames) }
    end
    for id in pairs(states.clients) do
        local message, full = statesync.messageFor(states, id, entry, love.timer.getTime())
        if message then
            message.g, message.ack, message.inp = generation, inputsync.newest(inputs, id), used
            message.vt, message.cd = voteList(), countdown or false
            net:sendTo(id, message, not full)
        end
    end
end

-- Host: one tick, every player with the input it has for that tick.
-- Host, every tick: each client gets the other players' inputs, what the
-- host used up to this tick and what it has for its next ones.
local function sendAhead()
    for id in pairs(states.clients) do
        local sent = forwarded[id] or {}
        forwarded[id] = sent
        local list = {}
        for _, player in ipairs(level.players) do
            if player.id ~= id then
                local n, f = inputsync.forward(inputs, player.id, tick, sent[player.id] or 0)
                if n then
                    list[#list + 1] = { player.id, n, f }
                    sent[player.id] = n
                end
            end
        end
        if #list > 0 then
            net:sendTo(id, { t = "ahead", g = generation, p = list }, true)
        end
    end
end

local function hostTick(step)
    local t = tick + 1
    for _, player in ipairs(level.players) do
        if remoteIds[player.id] then
            player.input = input.unpack(inputsync.take(inputs, player.id, t), level.actionNames)
        elseif net then
            inputsync.played(inputs, player.id, t, input.pack(player.input, level.actionNames))
        end
    end
    local wasFinished = level.finished
    level:update(step)
    tick = t
    level:protect(present.all, level:takeEvents(), level, localIds())
    if not wasFinished and level.finished and level.finished.outcome == "win" then
        gameplay.resetRespawns()
    end
    updateVote(step)
    if net then
        sendAhead()
        if tick % SEND_EVERY == 0 then
            sendStates()
        end
    end
end

-- Client: one tick ahead, with this machine's input recorded and sent.
local function clientTick(step)
    local t = tick + 1
    local mask = input.pack(slots[1].source.read(level.actions), level.actionNames)
    inputsync.record(inputs, t, mask)
    interp.decay()
    simulate(t, step)
    local message = inputsync.message(inputs, t)
    message.g, message.k = generation, statesync.ack(states)
    net:sendInput(message)
end

-- Client: how fast to run, so its inputs reach the host about TARGET_LEAD
-- ticks early: a little faster when they arrive late, slower when early.
local function clientRate()
    if not margin then
        return 1
    end
    local error = inputsync.TARGET_LEAD - margin
    if math.abs(error) < 1 then
        return 1
    end
    -- Gentle: the measurement is a round trip old, so pushing harder overshoots.
    return 1 + math.max(-0.25, math.min(0.25, error * 0.015))
end

-- Is this machine playing a level right now (a client waits for its welcome
-- and the host's first state)?
local function playing()
    if NET_MODE == "client" then
        return level ~= nil and net ~= nil and net.stage == "joined" and predicting
    end
    return level ~= nil
end

-- ── Scene ─────────────────────────────────────────────────────────────────

-- Start this machine's play as configured: alone, hosting (in the waiting
-- room, or playing at once with `--host`), or joining.
function gameplay.load()
    playerModule.load()
    slots = { { source = input.keyboard(1), id = 1 } }
    remoteIds = {}
    outbox = {}
    generation = 0
    room, sentHas, fingerprints, download, onServer = nil, nil, {}, nil, nil
    levels.refresh()
    if not levels.byRoot(LEVEL_ROOT) and levels.list()[1] then
        LEVEL_ROOT = levels.list()[1].root -- the level played last is gone
    end
    members = { [1] = { name = PLAYER_NAME } }
    members[1].has = fingerprintOf(LEVEL_ROOT)
    roomCountdown, roomDirty = nil, true
    states = NET_MODE == "host" and statesync.host() or nil
    inputs = NET_MODE == "host" and inputsync.host() or nil
    if NET_MODE == "client" or (NET_MODE == "host" and roomSettings.waiting) then
        level = nil
        roomState = "waiting"
    else
        roomState = "playing"
        hostRestart()
    end
    startNetwork()
end

-- Host of an internet room: what went wrong with it on the status line (the
-- waiting room shows its code).
local function showRoom()
    local _, state, reason = net:room()
    if state == "opening" then
        netStatus = "Opening a room..."
    elseif state == "failed" then
        netStatus = "Room: " .. tostring(reason)
    else
        netStatus = nil
    end
end

-- The victory sound, once per won level (on hosts and clients alike: each
-- sees `finished` in its own copy of the level).
local cheeredLevel = nil
local function cheer()
    if level and level.finished and level.finished.outcome == "win" and cheeredLevel ~= level then
        cheeredLevel = level
        audio.playSfx(VICTORY_SOUND)
    end
end

function gameplay.update(delta)
    if net then
        net:service()
        if NET_MODE == "host" and net.enet then
            members[1].has = fingerprintOf(LEVEL_ROOT)
            updateRoom(delta)
            checkOnServer()
            if ONLINE and net.room then
                showRoom()
            end
        end
    end
    if NET_MODE == "client" and net then
        clientHasLevel()
    end
    if not playing() then
        return
    end
    local client = NET_MODE == "client"
    if client and wrongFrom then -- a forwarded input showed a wrong prediction
        local state, h, flat = statesync.latest(states)
        if state then
            reconcile(state, h, flat)
        end
        wrongFrom = nil
    end
    alpha = clock:advance(client and delta * clientRate() or delta, function(step)
        interp.record(movingBodies())
        if client then
            clientTick(step)
        else
            local names = level.actionNames
            for _, slot in ipairs(slots) do
                -- Through the mask, as clients see it: their predicted copy of
                -- this player then holds exactly the same input table.
                slot.player.input = input.unpack(input.pack(slot.source.read(level.actions), names), names)
            end
            hostTick(step)
        end
    end)
    if NET_MODE == "host" and net then
        flushOutbox()
    end
    cheer()
end

function gameplay.keypressed(key)
    if key == "escape" then
        gameplay.closeNetwork()
        fx.toScene("menu", 0.5, { ease = "smoothstep" })
    elseif not playing() then
        return
    elseif (key == "return" or key == "kpenter") and (level.finished or level.faulted) then
        gameplay.backToRoom()
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
    fx.drawShots()
    level:drawWorld()
    camera.popWorld()
    worldPushed = false
    level:drawHud()
    hud.draw(level.players, LOCAL_COOP and #slots < Level.MAX_PLAYERS, localIds(), not level.hud)
end

-- A full-screen message over the level: a title, a line of detail, and the
-- keys that still work.
-- The restart vote key as shown (it can be changed in Options).
local function restartKey()
    return require("scenes.options").keyName(input.KEYBOARD_LAYOUTS[1].restart)
end

local function drawBanner(title, detail, color, keys)
    love.graphics.setColor(0, 0, 0, 0.75)
    love.graphics.rectangle("fill", 0, 0, render.width, render.height)
    love.graphics.setColor(color[1], color[2], color[3], 1)
    text.printf(title, 0, render.height / 2 - 40, render.width, "center", 16)
    love.graphics.setColor(1, 1, 1, 0.85)
    if detail then
        text.printf(detail, 24, render.height / 2 - 12, render.width - 48, "center", 10)
    end
    text.printf(keys or (restartKey() .. " vote restart   ESC menu"), 0, render.height / 2 + 30, render.width, "center", 10)
end

local OUTCOME_TITLES = { win = "LEVEL CLEAR", lose = "GAME OVER" }

-- The keys under a finished level's banner: in a room the host takes
-- everyone back to it.
local function stoppedKeys()
    if NET_MODE == "host" and net then
        return "ENTER back to the room   " .. restartKey() .. " vote restart   ESC leave"
    elseif NET_MODE == "client" then
        return "The host can go back to the room   " .. restartKey() .. " vote restart   ESC leave"
    end
    return nil
end

-- Shown once a script stopped the level (Level:fault), or a gamemode ended it
-- (Level:finish).
local function drawStopped()
    if level.faulted then
        local reason = level.faulted:match("^[^\n]*"):sub(1, 140)
        drawBanner("THIS LEVEL STOPPED", reason, { 1, 0.85, 0.4 }, stoppedKeys())
    else
        local finished = level.finished
        local title = OUTCOME_TITLES[finished.outcome] or finished.outcome:upper()
        drawBanner(title, finished.message, finished.outcome == "lose" and { 1, 0.45, 0.4 } or { 0.55, 1, 0.6 },
            stoppedKeys())
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

-- Client: how many ticks early its inputs reach the host (smoothed), or nil.
function gameplay.getInputMargin()
    return margin
end

-- Ticks run in the current level (on a client: the tick it has predicted to).
function gameplay.getTick()
    return tick
end

function gameplay.getGeneration()
    return generation
end

-- Tests: play as "host" or "client" (address) without a command line, on
-- another port and bind address. Takes effect at the next gameplay.load.
-- options.online = { server, code, relayOnly } for internet play.
-- options.room = { name, dropIn, public } opens the host's waiting room
-- (without it a host plays at once); options.name is this player's name.
function gameplay.configure(options)
    NET_MODE, JOIN_ADDRESS = options.mode, options.address
    ONLINE = options.online
    NET_PORT, NET_BIND = options.port, options.bind
    LEVEL_ROOT = options.level and loader.rootFor(options.level) or LEVEL_ROOT
    PLAYER_NAME = options.name or PLAYER_NAME
    local settings = options.room
    roomSettings = {
        name = settings and settings.name or "Room",
        dropIn = not settings or settings.dropIn ~= false,
        public = not settings or settings.public ~= false,
        waiting = settings ~= nil,
    }
end

-- The waiting room for scenes/room.lua: the room's state (protocol `room`
-- fields, nil until a client heard from the host), whether this machine
-- hosts, its own player id, and what to tell the player (connecting,
-- disconnected).
function gameplay.getRoom()
    return room, NET_MODE == "host", slots[1] and slots[1].id, netStatus
end

function gameplay.getNetwork()
    return net
end

-- "host", "client" or nil (this machine alone).
function gameplay.getMode()
    return NET_MODE
end

-- Replace a slot's input source (tests drive players with scripted sources).
function gameplay.setSource(index, source)
    slots[index].source = source
end

-- The level's music (level.json "music") when the game has that track, else
-- the default.
function gameplay.musicFor(level)
    local name = level and level.music
    if name and love.filesystem.getInfo(audio.musicPath .. "/" .. name, "file") then
        return name
    end
    return DEFAULT_MUSIC
end

sceneEngine.register("gameplay", {
    enter = function()
        audio.playMusic(gameplay.musicFor(level))
        if level then
            watchdog.enter(level.root)
        end
    end,
    exit = function()
        watchdog.leave() -- the session lives on into the room; the menu closes it
    end,
    update = gameplay.update,
    keypressed = gameplay.keypressed,
    gamepadpressed = gameplay.gamepadpressed,
    draw = gameplay.draw,
})

return gameplay
