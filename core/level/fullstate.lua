-- The whole state of a running level as plain data, and putting a level back
-- into a saved state (hybrid rollback, NETWORKING.md). The host sends it to
-- clients; a client restores the host's state and replays its newer inputs.
--
-- Nobody lists fields: every field of every player and entity is saved when
-- it is plain data (numbers, strings, booleans, and tables of those), and
-- references to players and entities are saved as their ids, also as table
-- keys (`kickHits[prop]`). Functions, images and tables that hold anything
-- else (sprite frames) are not state: they are left alone. What a script keeps
-- in its own local variables cannot be saved; MODDING.md asks scripts to keep
-- changing state on objects.
--
-- State: { rng, nextId, gravity, maxFall, net, finished, camera,
--          players = { [id] = fields }, order = { list name -> ids },
--          statics = { "g<index>" or entity id ... }, entities = { [id] = fields } }
local loader = require("core.level.loader")

local fullstate = {}

local MAX_DEPTH = 8
local SKIP = {} -- marker: not state

-- Fields that are never saved or restored: identity, per-step scratch and
-- presentation.
local FIXED = {
    id = true, kind = true, typeName = true, isPlayer = true, contacts = true, removed = true,
    controller = true, image = true, frames = true, graveyardShown = true,
}

local function refOf(value)
    if type(value) ~= "table" or type(value.id) ~= "number" then
        return nil
    end
    if value.isPlayer then
        return "$p", value.id
    elseif value.kind and getmetatable(value) ~= nil then
        return "$e", value.id
    end
    return nil
end

local copy

local function copyKey(key)
    local kind = type(key)
    if kind == "string" or kind == "number" then
        return key
    end
    local tag, id = refOf(key)
    if tag then
        return tag .. ":" .. id
    end
    return SKIP
end

copy = function(value, depth)
    local kind = type(value)
    if kind == "number" or kind == "string" or kind == "boolean" then
        return value
    elseif kind ~= "table" then
        return SKIP
    end
    local tag, id = refOf(value)
    if tag then
        return { [tag] = id }
    end
    if getmetatable(value) ~= nil or depth > MAX_DEPTH then
        return SKIP
    end
    local out = {}
    for key, inner in pairs(value) do
        local k, v = copyKey(key), copy(inner, depth + 1)
        if k == SKIP or v == SKIP then
            return SKIP
        end
        out[k] = v
    end
    return out
end

-- The saved fields of one object.
local function fieldsOf(object)
    local fields = {}
    for key, value in pairs(object) do
        if type(key) == "string" and not FIXED[key] then
            local saved = copy(value, 0)
            if saved ~= SKIP then
                fields[key] = saved
            end
        end
    end
    return fields
end

local LISTS = { "hazards", "blocks", "enemies", "props", "triggers" }
fullstate.LISTS = LISTS

-- Save the level's whole state.
function fullstate.capture(level)
    local players, entities, order = {}, {}, {}
    for _, player in ipairs(level.players) do
        players[player.id] = fieldsOf(player)
    end
    for _, name in ipairs(LISTS) do
        local ids = {}
        for i, entity in ipairs(level[name]) do
            ids[i] = entity.id
            local fields = fieldsOf(entity)
            fields.typeName = entity.typeName -- to rebuild a spawned one elsewhere
            entities[entity.id] = fields
        end
        order[name] = ids
    end
    local geometryIndex = level.geometryIndex
    if not geometryIndex then
        geometryIndex = {}
        for i, rect in ipairs(level.geometry) do
            geometryIndex[rect] = i
        end
        level.geometryIndex = geometryIndex
    end
    local statics = {}
    for i, static in ipairs(level.statics) do
        statics[i] = geometryIndex[static] and ("g" .. geometryIndex[static]) or static.id
    end
    local camera = fieldsOf(level.camera)
    return {
        rng = level.random:getState(),
        nextId = level.nextId,
        gravity = level.gravity,
        maxFall = level.maxFall,
        net = copy(level.net, 0) ~= SKIP and copy(level.net, 0) or {},
        finished = level.finished and { outcome = level.finished.outcome, message = level.finished.message } or false,
        camera = camera,
        players = players,
        entities = entities,
        order = order,
        statics = statics,
    }
end

-- ── Restore ───────────────────────────────────────────────────────────────

local function playerById(level, id)
    for _, player in ipairs(level.players) do
        if player.id == id then
            return player
        end
    end
    return nil
end

local resolve

local function resolveKey(level, key)
    if type(key) == "string" then
        local tag, id = key:match("^(%$[ep]):(%d+)$")
        if tag then
            return tag == "$p" and playerById(level, tonumber(id)) or level.everyEntity[tonumber(id)]
        end
    end
    return key
end

resolve = function(level, value)
    if type(value) ~= "table" then
        return value
    end
    if value["$p"] then
        return playerById(level, value["$p"])
    elseif value["$e"] then
        return level.everyEntity[value["$e"]]
    end
    local out = {}
    for key, inner in pairs(value) do
        local k = resolveKey(level, key)
        if k ~= nil then
            out[k] = resolve(level, inner)
        end
    end
    return out
end

-- Set an object's saved fields; a saved-kind field it has now but the state
-- lacks is cleared (it was set after the save).
local function setFields(level, object, fields)
    for key, value in pairs(object) do
        if type(key) == "string" and not FIXED[key] and fields[key] == nil and copy(value, 0) ~= SKIP then
            object[key] = nil
        end
    end
    for key, value in pairs(fields) do
        if key ~= "typeName" then
            object[key] = resolve(level, value)
        end
    end
end

-- Find or make the entity with this id (one the host spawned that this
-- machine never had: built from its type and placement).
local function entityFor(level, id, fields)
    local entity = level.everyEntity[id]
    if entity then
        return entity
    end
    if not fields.spawned or type(fields.typeName) ~= "string" then
        return nil
    end
    local Type = loader.loadType(level.root, fields.typeName, level.types, level.random)
    local def = type(fields.spawnDef) == "table" and fields.spawnDef or {}
    entity = loader.newEntity(Type, fields.typeName, fields.x or 0, fields.y or 0, def, "restore")
    entity.id = id
    level.everyEntity[id] = entity
    return entity
end

-- Put the level into a saved state (players stay the level's own: who is in
-- the session is not part of it). Creating an entity the host spawned runs
-- its type's script: call it under script limits.
function fullstate.restore(level, state)
    level.random:setState(state.rng)
    level.nextId = state.nextId
    level.gravity, level.maxFall = state.gravity, state.maxFall
    level.net = resolve(level, state.net)
    level.finished = state.finished or nil
    setFields(level, level.camera, state.camera)
    -- Entities: lists rebuilt in the saved order, objects reused.
    local present = {}
    for _, name in ipairs(LISTS) do
        local list = {}
        for _, id in ipairs(state.order[name] or {}) do
            local entity = entityFor(level, id, state.entities[id] or {})
            if entity then
                list[#list + 1] = entity
                present[id] = entity
            end
        end
        -- Replace the contents in place: rules and scripts hold these lists.
        local live = level[name]
        for i = #live, 1, -1 do live[i] = nil end
        for i, entity in ipairs(list) do live[i] = entity end
    end
    for id, entity in pairs(level.byId) do
        if not present[id] then
            entity.removed = true
            level.byId[id] = nil
        end
    end
    for id, entity in pairs(present) do
        level.byId[id] = entity
        entity.removed = nil
    end
    local statics = level.statics
    for i = #statics, 1, -1 do statics[i] = nil end
    for _, ref in ipairs(state.statics) do
        local static
        if type(ref) == "string" then
            static = level.geometry[tonumber(ref:sub(2))]
        else
            static = present[ref]
        end
        if static then
            statics[#statics + 1] = static
        end
    end
    -- Fields last, so references between objects resolve to restored ones.
    for id, entity in pairs(present) do
        setFields(level, entity, state.entities[id])
    end
    for _, player in ipairs(level.players) do
        local fields = state.players[player.id]
        if fields then
            setFields(level, player, fields)
        end
    end
    level.events = {}
end

return fullstate
