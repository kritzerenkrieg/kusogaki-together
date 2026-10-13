-- Net state: what a snapshot carries for each player and entity, and the wire
-- form of events. Everything here is plain data (numbers, booleans, strings);
-- object references become ids. Fields not listed are host-only simulation
-- state or local view state. See NETWORKING.md (Net state vs view state).
local netstate = {}

-- Player: body, flags, and what the player view needs to pick a sprite frame.
netstate.PLAYER_FIELDS = {
    "x", "y", "vx", "vy", "facing", "onGround", "jumping", "dead",
    "state", "animationTime", "idleTime", "kickAnimationTime", "kickTime",
}

-- Entity (base): body and what Entity:draw needs. A type adds its own fields
-- with `Type.netFields = { "lit", ... }` (plain values only).
netstate.ENTITY_FIELDS = {
    "x", "y", "vx", "vy", "facing", "frameIndex", "rotation", "flash", "held",
}

local function copyFields(target, source, fields)
    for _, field in ipairs(fields) do
        target[field] = source[field]
    end
end

function netstate.player(player)
    local state = { id = player.id }
    copyFields(state, player, netstate.PLAYER_FIELDS)
    state.carrying = player.carrying and player.carrying.id -- entity id
    return state
end

function netstate.entity(entity)
    local state = { id = entity.id }
    copyFields(state, entity, netstate.ENTITY_FIELDS)
    if entity.netFields then
        copyFields(state, entity, entity.netFields)
    end
    return state
end

-- Full snapshot of a level after `tick`: players in join order, entities by id.
function netstate.snapshot(level, tick)
    local players, entities = {}, {}
    for _, player in ipairs(level.players) do
        players[#players + 1] = netstate.player(player)
    end
    for _, entity in pairs(level.byId) do
        entities[#entities + 1] = netstate.entity(entity)
    end
    table.sort(entities, function(a, b) return a.id < b.id end)
    return { tick = tick, players = players, entities = entities }
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
    return { snapshot.tick, players, entities }
end

function netstate.unpack(packed, extrasFor)
    local players, entities = {}, {}
    for i, list in ipairs(packed[2] or {}) do
        players[i] = unpackRecord(list, PLAYER_PACKED)
    end
    for i, list in ipairs(packed[3] or {}) do
        entities[i] = unpackRecord(list, netstate.ENTITY_FIELDS, extrasFor and extrasFor(list[1]))
    end
    return { tick = packed[1], players = players, entities = entities }
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
