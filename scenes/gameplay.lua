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
local session = require("core.net.session")
local inputsync = require("core.net.inputsync")
local statesync = require("core.net.statesync")
local fullstate = require("core.level.fullstate")
local script = require("core.script")
local watchdog = require("core.watchdog")

local gameplay = {}

-- Command line (testing shortcuts; players use Host online / Join online in
-- the menu): `--level <name>` picks the level (default "example"; a client
-- plays the host's); `--host` / `--join <ip[:port]>` start network play
-- directly over a LAN or 127.0.0.1, without the server;
-- `--net-lag <ms> --net-loss <percent>` make this machine's connection worse
-- for testing (core/net/session.lua); `--local-coop` turns on the deprecated
-- couch co-op. Internet play through a server (your own for testing):
-- `--host --online` opens a room on our server and shows its code;
-- `--code <6 digits>` joins one; `--server <host[:port]>` names the server;
-- `--relay-only` hides this machine's address behind the relay.
local LEVEL_NAME = "example"
local LOCAL_COOP = false
local NET_MODE, JOIN_ADDRESS = nil, nil -- "host" | "client" | nil
local NET_LAG, NET_LOSS = 0, 0          -- simulated extra round trip (s) and loss (fraction)
local ONLINE = nil                      -- { server, code, relayOnly } for internet play
local onlineOptions = { server = nil, relayOnly = false }
for i, value in ipairs(arg or {}) do
    if value == "--level" and arg[i + 1] then
        LEVEL_NAME = arg[i + 1]
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
local votes = {}            -- player id -> true: votes to restart
local countdown = nil       -- seconds left until the restart, while the vote passes
local outbox = {}           -- session messages for the other machines
local generation = 0        -- the level's (re)start number; messages from older ones are stale

local net = nil             -- the network session (core/net/session.lua), if any
local netStatus = nil       -- what to tell the player about the session ("connecting", a reason)
local states = nil          -- host: statesync.host(); client: statesync.client()
local inputs = nil          -- host: inputsync.host(); client: inputsync.client() (its own)
local remoteMasks = {}      -- client: id -> the input the host last used for that player
local predicting = false    -- client: has a host state and runs ahead of it
local margin = nil          -- client: how many ticks early its inputs reach the host (smoothed)
local presented = {}        -- client: tick -> event signatures already shown
local predicted = {}        -- client: tick -> its predicted state then (flat), for ticks the host sends
local SEND_EVERY = 3        -- host ticks between states (20 a second)
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
        statesync.reset(states) -- every client gets a full state of the new level
        inputsync.reset(inputs) -- tick numbers start again
    elseif NET_MODE == "client" then
        states, inputs = statesync.client(), inputsync.client()
        remoteMasks, predicting, margin, presented, predicted = {}, false, nil, {}, {}
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
    -- checkpoint (the host player's respawn point); its machine learns where
    -- from the host's state.
    welcome = function(id)
        remoteIds[id] = true
        local hostPlayer = slots[1].player
        spawn(hostPlayer.spawnX, hostPlayer.spawnY, id)
        inputsync.addPlayer(inputs, id)
        statesync.addClient(states, id) -- a full state at the next send
        return { seed = level.seed, generation = generation, players = sessionIds() }
    end,
    left = function(id)
        remoteIds[id] = nil
        inputsync.removePlayer(inputs, id)
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

-- Client: run one tick `t` of the level with this machine's input for it
-- and the others' last known inputs, and show what is new in it.
local function simulate(t, step)
    local names = level.actionNames
    for _, player in ipairs(level.players) do
        if player == slots[1].player then
            player.input = input.unpack(inputsync.maskAt(inputs, t), names)
        else
            player.input = input.unpack(remoteMasks[player.id] or 0, names)
        end
    end
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
-- machine predicted for tick h changes nothing; otherwise it replaces the
-- prediction for tick h and the ticks since are replayed with this
-- machine's inputs.
local function reconcile(state, h, flat)
    if predicting and predicted[h] and statesync.same(predicted[h], flat) then
        return -- predicted right
    end
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
        gameplay.restart(message.seed)
        netStatus = nil
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
        votes = {}
        for _, id in ipairs(message.vt) do
            votes[id] = true
        end
        countdown = message.cd or nil
        if predicting and message.ack > 0 then -- the host has this machine's inputs
            local early = message.ack - h -- how far ahead of the host they arrived
            margin = margin and margin + (early - margin) * 0.1 or early
        end
        reconcile(state, h, flat)
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
            level = { name = LEVEL_NAME, fingerprint = levelpack.fingerprint(level.root) },
            handler = hostHandler,
            rendezvous = ONLINE,
        })
        if not net then
            netStatus = "Could not host: " .. tostring(err)
        end
    elseif NET_MODE == "client" then
        local err
        net, err = session.join(JOIN_ADDRESS, clientHandler, { rendezvous = ONLINE })
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

-- Host, 20 times a second: save the level's state after this tick (under
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
local function hostTick(step)
    local t = tick + 1
    for _, player in ipairs(level.players) do
        if remoteIds[player.id] then
            player.input = input.unpack(inputsync.take(inputs, player.id, t), level.actionNames)
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
    if net and tick % SEND_EVERY == 0 then
        sendStates()
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

function gameplay.load()
    playerModule.load()
    slots = { { source = input.keyboard(1), id = 1 } }
    remoteIds = {}
    outbox = {}
    generation = 0
    states = NET_MODE == "host" and statesync.host() or nil
    inputs = NET_MODE == "host" and inputsync.host() or nil
    if NET_MODE == "client" then
        level = nil
    else
        hostRestart()
    end
    startNetwork()
end

-- Host of an internet room: its code (or what went wrong) on the status line.
local function showRoom()
    local code, state, reason = net:room()
    if state == "open" then
        if ONLINE.copied ~= code then
            ONLINE.copied = code -- once per room: ready to paste to friends
            pcall(love.system.setClipboardText, code)
        end
        netStatus = "Room code " .. code .. " (copied)" .. (ONLINE.relayOnly and " - relay only" or "")
    elseif state == "opening" then
        netStatus = "Opening a room..."
    elseif state == "failed" then
        netStatus = "Room: " .. tostring(reason)
    end
end

function gameplay.update(delta)
    if net then
        net:service()
        if NET_MODE == "host" and ONLINE and net.room then
            showRoom()
        end
    end
    if not playing() then
        return
    end
    local client = NET_MODE == "client"
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
function gameplay.configure(options)
    NET_MODE, JOIN_ADDRESS = options.mode, options.address
    ONLINE = options.online
    NET_PORT, NET_BIND = options.port, options.bind
    LEVEL_NAME = options.level or LEVEL_NAME
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
