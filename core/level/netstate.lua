-- Net state: what a snapshot carries for each player and entity, and the wire
-- form of events. Everything here is plain data (numbers, booleans, strings);
-- object references become ids. Fields not listed are host-only simulation
-- state or local view state. See NETWORKING.md (Net state vs view state).
local netstate = {}

-- Player: body, flags, and what the player view needs to pick a sprite frame.
-- `net` is the player's script state (player.net, plain data).
netstate.PLAYER_FIELDS = {
    "x", "y", "vx", "vy", "facing", "onGround", "jumping", "dead",
    "state", "animationTime", "idleTime", "kickAnimationTime", "kickTime", "held", "respawns", "net",
}

-- Entity (base): body and what Entity:draw needs, plus `spawnedType`: the type
-- name of an entity spawned at runtime (clients know placed ones from
-- level.json). A type adds its own fields with `Type.netFields = { "lit", ... }`
-- (plain data only).
netstate.ENTITY_FIELDS = {
    "spawnedType", "x", "y", "vx", "vy", "facing", "frameIndex", "rotation", "flash", "held",
}

-- ── Plain data ────────────────────────────────────────────────────────────
-- What may cross the wire: nil, booleans, finite numbers, strings, and tables
-- of those with string or number keys and no metatable. Scripts' net state,
-- messages and spawn placements must be plain.
netstate.MAX_PLAIN_DEPTH = 16
netstate.MAX_PLAIN_ITEMS = 4096

local function checkPlain(value, depth, budget, path)
    local kind = type(value)
    if kind == "nil" or kind == "boolean" or kind == "string" then
        return true
    elseif kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return false, path .. ": not a finite number"
        end
        return true
    elseif kind ~= "table" then
        return false, path .. ": a " .. kind .. " is not plain data"
    end
    if depth > netstate.MAX_PLAIN_DEPTH then
        return false, path .. ": nested too deep (or a cycle)"
    end
    if getmetatable(value) ~= nil then
        return false, path .. ": a table with a metatable is not plain data"
    end
    for key, inner in pairs(value) do
        budget.items = budget.items + 1
        if budget.items > netstate.MAX_PLAIN_ITEMS then
            return false, path .. ": too many values"
        end
        local keyKind = type(key)
        if keyKind ~= "string" and keyKind ~= "number" then
            return false, path .. ": keys must be strings or numbers"
        end
        local ok, err = checkPlain(inner, depth + 1, budget, path .. "." .. tostring(key))
        if not ok then
            return false, err
        end
    end
    return true
end

-- true, or false and where the problem is. `what` names the value in messages.
function netstate.isPlain(value, what)
    return checkPlain(value, 0, { items = 0 }, what or "value")
end

-- Error (at the caller's caller) unless value is plain data.
function netstate.checkPlain(value, what)
    local ok, err = netstate.isPlain(value, what)
    if not ok then
        error(err, 3)
    end
    return value
end

local function copyFields(target, source, fields)
    for _, field in ipairs(fields) do
        target[field] = source[field]
    end
end

function netstate.player(player)
    local state = { id = player.id }
    copyFields(state, player, netstate.PLAYER_FIELDS)
    -- What it carries: an entity id, or a player id (separate namespaces).
    local carried = player.carrying
    state.carrying = carried and not carried.isPlayer and carried.id or nil
    state.carryingPlayer = carried and carried.isPlayer and carried.id or nil
    return state
end

function netstate.entity(entity)
    local state = { id = entity.id }
    copyFields(state, entity, netstate.ENTITY_FIELDS)
    state.spawnedType = entity.spawned and entity.typeName or nil
    if entity.netFields then
        copyFields(state, entity, entity.netFields)
    end
    return state
end

-- What the camera follows, as plain data: "players"/"screens", a body as
-- { player = id } or { entity = id }, or false (fixed).
local function followRef(follow)
    if follow == "players" or follow == "screens" then
        return follow
    elseif type(follow) == "table" and follow.isPlayer then
        return { player = follow.id }
    elseif type(follow) == "table" and follow.id then
        return { entity = follow.id }
    end
    return false
end

-- Level-wide state: script state (level.net), the outcome once finished, the
-- gravity and the camera (both may be changed by scripts while it runs).
function netstate.level(level)
    local camera = level.camera or {}
    return {
        net = level.net,
        finished = level.finished,
        gravity = level.gravity,
        camera = { follow = followRef(camera.follow), x = camera.x, y = camera.y, zoom = camera.zoom },
    }
end

-- Full snapshot of a level after `tick`: players in join order, entities by id,
-- level state. Script state that is not plain data raises an error (the host
-- takes snapshots under level:protect, so that stops the level).
function netstate.snapshot(level, tick)
    local players, entities = {}, {}
    for _, player in ipairs(level.players) do
        netstate.checkPlain(player.net, "player " .. tostring(player.id) .. " net")
        players[#players + 1] = netstate.player(player)
    end
    for _, entity in pairs(level.byId) do
        entities[#entities + 1] = netstate.entity(entity)
    end
    table.sort(entities, function(a, b) return a.id < b.id end)
    local levelState = netstate.level(level)
    netstate.checkPlain(levelState, "level")
    return { tick = tick, players = players, entities = entities, level = levelState }
end

-- ── Compact form ──────────────────────────────────────────────────────────
-- For the wire, each record becomes a list in schema order: { id, field1,
-- field2, ... }, so no field names are sent. nil is written as false (both
-- mean "not set" for every net field) and read back as nil.
local function packRecord(record, fields, extras)
    local list = { record.id }
    for i, field in ipairs(fields) do
        local value = record[field]
        if value == nil then value = false end
        list[i + 1] = value
    end
    for i, field in ipairs(extras or {}) do
        local value = record[field]
        if value == nil then value = false end
        list[#fields + 1 + i] = value
    end
    return list
end

local function unpackRecord(list, fields, extras)
    local record = { id = list[1] }
    for i, field in ipairs(fields) do
        local value = list[i + 1]
        if value ~= false then record[field] = value end
    end
    for i, field in ipairs(extras or {}) do
        local value = list[#fields + 1 + i]
        if value ~= false then record[field] = value end
    end
    return record
end

local PLAYER_PACKED = {}
for _, field in ipairs(netstate.PLAYER_FIELDS) do
    PLAYER_PACKED[#PLAYER_PACKED + 1] = field
end
PLAYER_PACKED[#PLAYER_PACKED + 1] = "carrying"
PLAYER_PACKED[#PLAYER_PACKED + 1] = "carryingPlayer"

-- Pack a snapshot for core/wire.lua. `extrasFor(id)` returns an entity's
-- type netFields; both sides know them from the level package.
function netstate.pack(snapshot, extrasFor)
    local players, entities = {}, {}
    for i, player in ipairs(snapshot.players) do
        players[i] = packRecord(player, PLAYER_PACKED)
    end
    for i, entity in ipairs(snapshot.entities) do
        entities[i] = packRecord(entity, netstate.ENTITY_FIELDS, extrasFor and extrasFor(entity.id))
    end
    return { snapshot.tick, players, entities, snapshot.level or false }
end

function netstate.unpack(packed, extrasFor)
    local players, entities = {}, {}
    for i, list in ipairs(packed[2] or {}) do
        players[i] = unpackRecord(list, PLAYER_PACKED)
    end
    for i, list in ipairs(packed[3] or {}) do
        entities[i] = unpackRecord(list, netstate.ENTITY_FIELDS, extrasFor and extrasFor(list[1]))
    end
    return { tick = packed[1], players = players, entities = entities, level = packed[4] or nil }
end

-- Wire form of an event: everything except the local `entity` reference.
function netstate.event(event)
    local wire = {}
    for key, value in pairs(event) do
        if key ~= "entity" then
            wire[key] = value
        end
    end
    return wire
end

return netstate
