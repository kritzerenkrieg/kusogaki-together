-- Player state sync (Phase 2 step 2, NETWORKING.md Source of truth). Each
-- machine owns its own player's movement and sends it as absolute state,
-- newest wins; the host checks it (referee), forwards it to everyone, and
-- overrides an owner with `setPlayer` and a higher authority number.
--
-- On every machine the other machines' players are puppets: not simulated
-- here (no controller, no rule changes them), solid but immovable, and placed
-- by the newest state received. Between states a puppet keeps moving at its
-- last velocity for a short while (dead reckoning); step 5 replaces that with
-- interpolation.
--
-- Wire form of a player (`p`): a list of 8 integers
--   { x, y, vx, vy, flags, kickTime, kickAnimationTime, respawns }
-- positions in 1/8 px, velocities in 1/16 px per tick (60 Hz), timers in
-- ticks (kickAnimationTime -1 = none), flags: 1 facing right, 2 on ground,
-- 4 jumping, 8 dead. The displayed state (idle, run...) is derived from these
-- on each machine.
local state = require("core.player.state")

local playersync = {}

playersync.SEND_EVERY = 3        -- ticks between sends: 20 Hz (OPEN_DECISION D1)
playersync.EXTRAPOLATE = 0.1     -- s a puppet keeps moving without a new state
playersync.MAX_SPEED = 1500      -- px/s; faster is clearly impossible (referee)
playersync.MAX_EVENTS = 8        -- player events (sounds) carried per message
playersync.MAX_COORD = 2 ^ 24    -- 1/8 px: about +-2 million px
playersync.MAX_SEQ = 2 ^ 31

local POSITION, VELOCITY = 8, 16 / 60 -- wire units per px, per px/s
local TICK = 60
local FACING, GROUND, JUMPING, DEAD = 1, 2, 4, 8
local MAX_VELOCITY = 32767
local MAX_TIMER = 600

local function round(value)
    return math.floor(value + 0.5)
end

local function isInt(value, low, high)
    return type(value) == "number" and value % 1 == 0 and value >= low and value <= high
end

local function flag(flags, bit)
    return math.floor(flags / bit) % 2 == 1
end

local function clamp(value, low, high)
    return math.min(math.max(value, low), high)
end

-- ── Wire form ─────────────────────────────────────────────────────────────

function playersync.pack(player)
    local flags = (player.facing >= 0 and FACING or 0) + (player.onGround and GROUND or 0)
        + (player.jumping and JUMPING or 0) + (player.dead and DEAD or 0)
    return {
        clamp(round(player.x * POSITION), -playersync.MAX_COORD, playersync.MAX_COORD),
        clamp(round(player.y * POSITION), -playersync.MAX_COORD, playersync.MAX_COORD),
        clamp(round(player.vx * VELOCITY), -MAX_VELOCITY, MAX_VELOCITY),
        clamp(round(player.vy * VELOCITY), -MAX_VELOCITY, MAX_VELOCITY),
        flags,
        clamp(round((player.kickTime or 0) * TICK), 0, MAX_TIMER),
        player.kickAnimationTime and clamp(round(player.kickAnimationTime * TICK), 0, MAX_TIMER) or -1,
        clamp(player.respawns or 0, 0, 65535),
    }
end

-- Is `p` a well-formed wire player? (Untrusted input.)
function playersync.valid(p)
    return type(p) == "table" and #p == 8 and next(p, 8) == nil
        and isInt(p[1], -playersync.MAX_COORD, playersync.MAX_COORD)
        and isInt(p[2], -playersync.MAX_COORD, playersync.MAX_COORD)
        and isInt(p[3], -MAX_VELOCITY, MAX_VELOCITY) and isInt(p[4], -MAX_VELOCITY, MAX_VELOCITY)
        and isInt(p[5], 0, 15) and isInt(p[6], 0, MAX_TIMER) and isInt(p[7], -1, MAX_TIMER)
        and isInt(p[8], 0, 65535)
end

-- Wire player -> fields ({ x, y, vx, vy, facing, onGround, jumping, dead,
-- kickTime, kickAnimationTime, respawns }). `p` must be valid.
function playersync.unpack(p)
    return {
        x = p[1] / POSITION,
        y = p[2] / POSITION,
        vx = p[3] / VELOCITY,
        vy = p[4] / VELOCITY,
        facing = flag(p[5], FACING) and 1 or -1,
        onGround = flag(p[5], GROUND),
        jumping = flag(p[5], JUMPING),
        dead = flag(p[5], DEAD),
        kickTime = p[6] / TICK,
        kickAnimationTime = p[7] >= 0 and p[7] / TICK or nil,
        respawns = p[8],
    }
end

-- Player event names that travel with a state (only sounds use them).
function playersync.validEvents(list)
    if type(list) ~= "table" or #list > playersync.MAX_EVENTS or next(list, #list > 0 and #list or nil) ~= nil then
        return false
    end
    for _, name in ipairs(list) do
        if type(name) ~= "string" or #name > 16 or not name:match("^%a+$") then
            return false
        end
    end
    return true
end

-- ── Puppets ───────────────────────────────────────────────────────────────

-- Make `player` a puppet: another machine plays it.
function playersync.makePuppet(player)
    player.remote = true    -- played on another machine; rules here leave it alone
    player.immovable = true -- solid, but bodies here never push it
    player.contacts = {}
    player.syncAge = math.huge -- no state yet: stands still
    return player
end

-- Let go of whatever the player carries, or whoever carries it.
local function releaseCarry(player)
    if player.carrying then
        player.carrying.held = false
        player.carrying.heldBy = nil
        player.carrying = nil
    end
    if player.heldBy then
        player.heldBy.carrying = nil
        player.held, player.heldBy = false, nil
    end
end

-- Place a puppet at a received state.
function playersync.apply(player, fields)
    if fields.dead and not player.dead then
        releaseCarry(player)
    end
    for key, value in pairs(fields) do
        player[key] = value
    end
    player.kickAnimationTime = fields.kickAnimationTime -- nil clears it
    player.prevY = player.y
    player.syncAge = 0
end

-- One tick of a puppet: keep moving at its last velocity for a short while,
-- run its timers, and pick the displayed state and animation clocks.
function playersync.advance(player, delta)
    player.prevY = player.y
    player.syncAge = player.syncAge + delta
    if player.syncAge <= playersync.EXTRAPOLATE then
        player.x = player.x + player.vx * delta
        player.y = player.y + player.vy * delta
    end
    player.kickTime = math.max(0, player.kickTime - delta)
    if player.kickAnimationTime then
        player.kickAnimationTime = player.kickAnimationTime + delta
    end
    state.animate(player, delta)
end

-- ── Owner (this machine's own player) ────────────────────────────────────

-- What an owner keeps: its send sequence, the authority it obeys, and the
-- event names since its last send. Kept for the whole session.
function playersync.owner()
    return { seq = 0, authority = 0, events = {} }
end

-- Note this machine's player's events (from level:takeEvents) for the next send.
function playersync.noteEvents(owner, events, id)
    for _, event in ipairs(events) do
        if event.type == "player" and event.player == id and #owner.events < playersync.MAX_EVENTS
            and type(event.name) == "string" and #event.name <= 16 and event.name:match("^%a+$") then
            owner.events[#owner.events + 1] = event.name
        end
    end
end

-- Next state of the owner's player: { s, a, p, e } (the caller adds t and g).
function playersync.nextState(owner, player)
    owner.seq = owner.seq + 1
    local entry = { s = owner.seq, a = owner.authority, p = playersync.pack(player), e = owner.events }
    owner.events = {}
    return entry
end

-- The host overrides this machine's player: a setPlayer message with the
-- fields it changes (position, velocity, respawn point). Obeyed at once;
-- later states carry its authority number.
function playersync.override(owner, player, message)
    if message.a <= owner.authority then
        return false -- an older override
    end
    owner.authority = message.a
    player.x, player.y = message.x or player.x, message.y or player.y
    player.vx, player.vy = message.vx or player.vx, message.vy or player.vy
    player.prevY = player.y
    if message.sx and message.sy then
        player:setSpawn(message.sx, message.sy)
    end
    return true
end

-- ── Host: another machine's player ───────────────────────────────────────

-- What the host keeps per remote player: newest sequence, the authority it
-- demands, the last accepted state (referee), and what to forward next.
function playersync.remote()
    return { seq = 0, authority = 0, last = nil, lastTime = 0, forward = nil }
end

local function near(fields, x, y, reach)
    return math.abs(fields.x - x) <= reach and math.abs(fields.y - y) <= reach
end

-- The referee: true when a state is possible, else false and why. It only
-- refuses the clearly impossible (NETWORKING.md, The host is the referee).
function playersync.possible(level, puppet, last, fields, seconds)
    if fields.x < -256 or fields.x > level.width + 256 or fields.y < -4096 or fields.y > level.height + 4096 then
        return false, "outside the level"
    end
    if math.abs(fields.vx) > playersync.MAX_SPEED or math.abs(fields.vy) > playersync.MAX_SPEED then
        return false, "too fast"
    end
    local reach = playersync.MAX_SPEED * seconds + 48
    if not last or (last.dead and not fields.dead) -- first state, or a respawn
        or near(fields, last.x, last.y, reach)
        or near(fields, puppet.x, puppet.y, reach) then -- a host script moved it
        return true
    end
    return false, "moved too far"
end

-- A state message from the owner of `puppet`. Returns "ok" (applied; the
-- record's `forward` holds it for the others), "stale" (dropped: older than
-- what we have, or from before an override) or "refused" (impossible: the
-- caller sends playersync.correction).
function playersync.receive(record, message, puppet, level, now)
    if message.a < record.authority or message.s <= record.seq then
        return "stale"
    end
    record.seq = message.s
    local fields = playersync.unpack(message.p)
    local seconds = math.max(now - record.lastTime, playersync.SEND_EVERY / TICK)
    if not playersync.possible(level, puppet, record.last, fields, seconds) then
        return "refused"
    end
    playersync.apply(puppet, fields)
    record.last, record.lastTime = fields, now
    local events = record.forward and record.forward.e or {}
    for _, name in ipairs(message.e) do
        if #events < playersync.MAX_EVENTS then events[#events + 1] = name end
    end
    record.forward = { s = message.s, p = message.p, e = events }
    return "ok"
end

-- The setPlayer that puts a refused owner back where the host has it (the
-- last accepted state). Raises the authority the host demands.
function playersync.correction(record, puppet)
    record.authority = record.authority + 1
    local at = record.last or puppet
    return { t = "setPlayer", a = record.authority, x = at.x, y = at.y, vx = 0, vy = 0 }
end

-- What a host script may change on a remote player; the host sends any
-- change to its owner (OPEN_DECISION A4).
local WATCHED = { "x", "y", "vx", "vy", "spawnX", "spawnY" }

-- The watched fields of a puppet, before the host's step.
function playersync.watch(puppet)
    local seen = {}
    for _, field in ipairs(WATCHED) do
        seen[field] = puppet[field]
    end
    return seen
end

-- After the host's step: merge what changed since `seen` into `pending` (a
-- setPlayer being built for the next send; nil when nothing changed yet).
-- Returns the updated pending table.
function playersync.changes(pending, seen, puppet)
    local SHORT = { x = "x", y = "y", vx = "vx", vy = "vy", spawnX = "sx", spawnY = "sy" }
    for _, field in ipairs(WATCHED) do
        if puppet[field] ~= seen[field] then
            pending = pending or {}
            if field == "spawnX" or field == "spawnY" then
                pending.sx, pending.sy = puppet.spawnX, puppet.spawnY
            else
                pending[SHORT[field]] = puppet[field]
            end
        end
    end
    return pending
end

-- Turn pending changes into a setPlayer with the next authority.
function playersync.overrideMessage(record, pending)
    record.authority = record.authority + 1
    pending.t, pending.a = "setPlayer", record.authority
    return pending
end

-- A setPlayer the host sends on its own (late join at a checkpoint):
-- position and respawn point.
function playersync.place(record, x, y)
    record.authority = record.authority + 1
    record.last = nil
    return { t = "setPlayer", a = record.authority, x = x, y = y, vx = 0, vy = 0, sx = x, sy = y }
end

-- ── Clients: the host's forwarded states ─────────────────────────────────

-- Apply one forwarded entry { id, s, p, e } to `puppet` if it is newer than
-- the last one for that player (`seen`: id -> sequence). Returns true when
-- applied.
function playersync.accept(seen, entry, puppet)
    local id, seq = entry[1], entry[2]
    if seq <= (seen[id] or 0) then
        return false
    end
    seen[id] = seq
    playersync.apply(puppet, playersync.unpack(entry[3]))
    return true
end

return playersync
