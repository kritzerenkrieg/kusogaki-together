-- Level loader: reads levels/<name>/level.json, runs the level's entity scripts
-- (levels/<name>/entities/<type>.lua) in the sandbox, and builds level data.
local json = require("core.json")
local script = require("core.script")
local Entity = require("core.level.entity")
local Prop = require("core.level.prop")

local loader = {}

local FORMAT = 1

-- Names become path segments, so only plain identifiers are allowed.
local function checkName(kind, value, path)
    if type(value) ~= "string" or not value:match("^[%w_]+$") then
        error(("%s: invalid %s name %s"):format(path, kind, tostring(value)), 0)
    end
end

-- Load (once per level load) the entity type script for `typeName`.
local function loadType(levelName, typeName, types)
    if not types[typeName] then
        local path = ("levels/%s/entities/%s.lua"):format(levelName, typeName)
        local Type = script.load(path, { Entity = Entity, Prop = Prop })
        Type.load()
        types[typeName] = Type
    end
    return types[typeName]
end

-- Load and build the level named `name`. Returns plain level data:
-- { name, spawn, background, statics, hazards, blocks, enemies, props }.
function loader.load(name)
    checkName("level", name, "level")
    local path = ("levels/%s/level.json"):format(name)
    local text = love.filesystem.read(path)
    if not text then
        error("level not found: " .. path, 0)
    end
    local data = json.decode(text)
    if data.format ~= FORMAT then
        error(("%s: unsupported format %s"):format(path, tostring(data.format)), 0)
    end

    local types = {}
    local hazards, blocks, enemies, props = {}, {}, {}, {}
    for _, def in ipairs(data.entities or {}) do
        checkName("entity type", def.type, path)
        local Type = loadType(name, def.type, types)
        local entity = Type.new(def.x, def.y)
        if Type.kind == "hazard" then
            hazards[#hazards + 1] = entity
        elseif Type.kind == "block" then
            blocks[#blocks + 1] = entity
        elseif Type.kind == "enemy" then
            enemies[#enemies + 1] = entity
        elseif Type.kind == "prop" then
            props[#props + 1] = entity
        else
            error(("%s: type %s has invalid kind %s"):format(path, def.type, tostring(Type.kind)), 0)
        end
    end

    return {
        name = name,
        spawn = { x = data.spawn.x, y = data.spawn.y },
        background = data.background,
        statics = data.static or {},
        hazards = hazards,
        blocks = blocks,
        enemies = enemies,
        props = props,
    }
end

return loader
