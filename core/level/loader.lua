-- Level loader: reads levels/<name>/level.json, runs the level's entity scripts
-- (levels/<name>/entities/<type>.lua) and level scripts
-- (levels/<name>/scripts/<script>.lua) in the sandbox, and builds level data.
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

-- Run each level script listed in level.json; each returns its hooks table.
local function loadScripts(levelName, names, path)
    local scripts = {}
    for _, scriptName in ipairs(names or {}) do
        checkName("script", scriptName, path)
        scripts[#scripts + 1] = script.load(("levels/%s/scripts/%s.lua"):format(levelName, scriptName))
    end
    return scripts
end

-- Load the tile images a static names in `tiles` ({ top, fill }: asset names in
-- levels/<name>/assets/) as static.topImage / static.fillImage. Images repeat,
-- so one quad can tile a whole static.
local function loadTiles(levelName, statics, path)
    local images = {}
    local function image(assetName)
        checkName("tile", assetName, path)
        if not images[assetName] then
            local loaded = Entity.loadImage(("levels/%s/assets/%s.png"):format(levelName, assetName))
            loaded:setWrap("repeat", "repeat")
            images[assetName] = loaded
        end
        return images[assetName]
    end
    for _, static in ipairs(statics) do
        if static.tiles then
            static.topImage = static.tiles.top and image(static.tiles.top)
            static.fillImage = static.tiles.fill and image(static.tiles.fill)
        end
    end
    return statics
end

-- Load and build the level named `name`. Returns plain level data:
-- { name, size, spawn, background, statics, hazards, blocks, enemies, props,
--   triggers, scripts }.
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
    local hazards, blocks, enemies, props, triggers = {}, {}, {}, {}, {}
    for _, def in ipairs(data.entities or {}) do
        checkName("entity type", def.type, path)
        local Type = loadType(name, def.type, types)
        local entity = Type.new(def.x, def.y, def) -- def: the placement, for instance data
        if Type.kind == "hazard" then
            hazards[#hazards + 1] = entity
        elseif Type.kind == "block" then
            blocks[#blocks + 1] = entity
        elseif Type.kind == "enemy" then
            enemies[#enemies + 1] = entity
        elseif Type.kind == "prop" then
            props[#props + 1] = entity
        elseif Type.kind == "trigger" then
            triggers[#triggers + 1] = entity
        else
            error(("%s: type %s has invalid kind %s"):format(path, def.type, tostring(Type.kind)), 0)
        end
    end

    return {
        name = name,
        size = data.size,
        spawn = { x = data.spawn.x, y = data.spawn.y },
        background = data.background,
        statics = loadTiles(name, data.static or {}, path),
        hazards = hazards,
        blocks = blocks,
        enemies = enemies,
        props = props,
        triggers = triggers,
        scripts = loadScripts(name, data.scripts, path),
    }
end

return loader
