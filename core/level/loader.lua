-- Level loader: reads a level package and builds level data. A package is a
-- folder (`root`) holding level.json, entities/<type>.lua (entity type scripts),
-- scripts/<script>.lua (level scripts) and assets/. Roots are a level folder
-- in the save directory, "levels/<name>", a downloaded level,
-- "downloads/<id>" (core/levels.lua), or one the game ships with,
-- "builtin/<name>". Scripts run in the sandbox (core/script.lua) and see only
-- their own package's assets.
local json = require("core.json")
local script = require("core.script")
local mathx = require("core.mathx")
local watchdog = require("core.watchdog")
local input = require("core.input")
local Entity = require("core.level.entity")
local Prop = require("core.level.prop")

local loader = {}

local FORMAT = 1
local IMAGE_EXTENSIONS = { png = true, jpg = true, jpeg = true }

-- Names become path segments, so only plain identifiers are allowed.
local function checkName(kind, value, path)
    if type(value) ~= "string" or not value:match("^[%w_]+$") then
        error(("%s: invalid %s name %s"):format(path, kind, tostring(value)), 0)
    end
end

-- A package root, from a level name (levels/<name>) or a root path.
function loader.rootFor(nameOrRoot)
    if type(nameOrRoot) == "string" and nameOrRoot:match("^[%w_]+$") then
        return "levels/" .. nameOrRoot
    end
    if type(nameOrRoot) == "string"
        and (nameOrRoot:match("^levels/[%w_]+$") or nameOrRoot:match("^builtin/[%w_]+$")
            or nameOrRoot:match("^downloads/%x+$")) then
        return nameOrRoot
    end
    error("invalid level root: " .. tostring(nameOrRoot), 0)
end

-- Resolve an asset path a script asked for. Paths are package-relative
-- ("assets/box.png"); a path the package does not have may name the engine's
-- shared graphics ("assets/graphics/..."). Anything else is refused, so a
-- script can never read outside its package and the shared art.
function loader.resolveAsset(root, path, extensions)
    if type(path) ~= "string" or path:find("..", 1, true) or path:sub(1, 1) == "/"
        or not path:match("^[%w_%-/%.]+$") then
        error("invalid asset path: " .. tostring(path), 0)
    end
    local extension = path:match("%.(%w+)$")
    if not (extension and extensions[extension:lower()]) then
        error("unsupported asset type: " .. path, 0)
    end
    local packaged = root .. "/" .. path
    if love.filesystem.getInfo(packaged, "file") then
        return packaged
    end
    if path:match("^assets/graphics/") and love.filesystem.getInfo(path, "file") then
        return path
    end
    error("asset not found: " .. path, 0)
end

-- What every script of this package sees: read-only engine classes whose
-- loadImage resolves package-relative paths, and the level's seeded random.
local function injectedFor(root, random)
    local function loadImage(path)
        return Entity.loadImage(loader.resolveAsset(root, path, IMAGE_EXTENSIONS))
    end
    local function randomFn(m, n)
        return random:random(m, n)
    end
    return {
        Entity = script.readonly(Entity, { loadImage = loadImage }),
        Prop = script.readonly(Prop, { loadImage = loadImage }),
        random = randomFn,
    }
end

-- Load (once per level) the entity type script for `typeName` into `types`
-- and return it. Level:spawnEntity uses this for types first needed at runtime.
function loader.loadType(root, typeName, types, random)
    checkName("entity type", typeName, root)
    if not types[typeName] then
        local path = ("%s/entities/%s.lua"):format(root, typeName)
        local Type = script.load(path, injectedFor(root, random))
        if type(Type) ~= "table" then
            error(path .. ": an entity type script must return its type table", 0)
        end
        script.guardFunctions(Type, typeName)
        if Type.load then
            Type.load()
        end
        if Type.scriptDisabled then
            error(("%s: load failed: %s"):format(path, Type.scriptError), 0)
        end
        types[typeName] = Type
    end
    return types[typeName]
end

-- Run each level script listed in level.json; each returns its hooks table.
local function loadScripts(root, names, path, random)
    local scripts = {}
    for _, scriptName in ipairs(names or {}) do
        checkName("script", scriptName, path)
        local hooks = script.load(("%s/scripts/%s.lua"):format(root, scriptName), injectedFor(root, random))
        if type(hooks) ~= "table" then
            error(("%s: level script %s must return a table of hooks"):format(path, scriptName), 0)
        end
        scripts[#scripts + 1] = script.guardFunctions(hooks, scriptName)
    end
    return scripts
end

-- Load the tile images a static names in `tiles` ({ top, fill }: asset names in
-- <root>/assets/, .png or .jpg) as static.topImage / static.fillImage. Images
-- repeat, so one quad can tile a whole static.
local function loadTiles(root, statics, path)
    local images = {}
    local function image(assetName)
        checkName("tile", assetName, path)
        if not images[assetName] then
            local file = ("%s/assets/%s.png"):format(root, assetName)
            if not love.filesystem.getInfo(file, "file") then
                file = ("%s/assets/%s.jpg"):format(root, assetName)
            end
            local loaded = Entity.loadImage(file)
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

local LIST_FOR_KIND = {
    hazard = "hazards", block = "blocks", enemy = "enemies", prop = "props", trigger = "triggers",
}
loader.LIST_FOR_KIND = LIST_FOR_KIND

-- Create one entity of `Type` at (x, y) from a placement `def`. Sets the
-- engine-owned fields `kind` and `typeName` (the caller sets `id`). Returns the
-- entity and the name of its level list. `where` names the caller in errors.
function loader.newEntity(Type, typeName, x, y, def, where)
    local listName = LIST_FOR_KIND[Type.kind]
    if not listName then
        error(("%s: type %s has invalid kind %s"):format(where, typeName, tostring(Type.kind)), 0)
    end
    if type(x) ~= "number" or type(y) ~= "number" then
        error(("%s: %s needs a numeric x and y"):format(where, typeName), 0)
    end
    local entity = Type.new(x, y, def) -- def: the placement, for instance data
    if type(entity) ~= "table" then
        error(("%s: %s.new failed: %s"):format(where, typeName, tostring(Type.scriptError)), 0)
    end
    entity.kind = Type.kind
    entity.typeName = typeName
    return entity, listName
end

-- level.json "camera": { follow = "players" | "screens" | "fixed", zoom, x, y, clamp }.
local CAMERA_FOLLOW = { players = true, screens = true, fixed = true }

local function cameraFrom(def, spawn, path)
    def = def or {}
    if type(def) ~= "table" then
        error(path .. ": camera must be an object", 0)
    end
    local follow = def.follow or "players"
    if not CAMERA_FOLLOW[follow] then
        error(path .. ": camera.follow must be players, screens or fixed", 0)
    end
    local zoom = def.zoom or 1
    if type(zoom) ~= "number" or zoom < 0.25 or zoom > 4 then
        error(path .. ": camera.zoom must be a number from 0.25 to 4", 0)
    end
    return {
        follow = follow ~= "fixed" and follow or nil, -- nil: stay centered on (x, y)
        zoom = zoom,
        x = type(def.x) == "number" and def.x or spawn.x,
        y = type(def.y) == "number" and def.y or spawn.y,
        clamp = def.clamp ~= false, -- keep the view inside the level
    }
end

local function numberIn(value, low, high, name, path)
    if value == nil then
        return nil
    end
    if type(value) ~= "number" or value ~= value or value < low or value > high then
        error(("%s: %s must be a number from %s to %s"):format(path, name, low, high), 0)
    end
    return value
end

-- Load and build the level package `nameOrRoot` (see loader.rootFor).
-- options.seed seeds the level's random generator (default 1).
-- Returns plain level data:
-- { name, root, size, spawn, background, statics, hazards, blocks, enemies,
--   props, triggers, scripts, random, types, nextId, gravity, maxFall, actions,
--   camera }.
function loader.load(nameOrRoot, options)
    options = options or {}
    local root = loader.rootFor(nameOrRoot)
    local hash = root:match("^downloads/(%x+)$")
    if hash and watchdog.isBlocked(hash) then
        error("level blocked: it froze the game before (" .. hash .. ")", 0)
    end
    local path = root .. "/level.json"
    local text = love.filesystem.read(path)
    if not text then
        error("level not found: " .. path, 0)
    end
    local data = json.decode(text)
    if type(data) ~= "table" or data.format ~= FORMAT then
        error(("%s: unsupported format %s"):format(path, tostring(type(data) == "table" and data.format)), 0)
    end
    if type(data.spawn) ~= "table" or type(data.spawn.x) ~= "number" or type(data.spawn.y) ~= "number" then
        error(path .. ": spawn {x, y} is required", 0)
    end

    local random = mathx.newRandom(options.seed or 1)
    local types = {}
    local lists = { hazards = {}, blocks = {}, enemies = {}, props = {}, triggers = {} }
    local placements = data.entities or {}
    for index, def in ipairs(placements) do
        checkName("entity type", def.type, path)
        local Type = loader.loadType(root, def.type, types, random)
        local entity, listName = loader.newEntity(Type, def.type, def.x, def.y, def, path)
        -- Stable id: the placement's index in level.json, the same on every
        -- load and every machine. `id`, `kind` and `typeName` are reserved for
        -- the engine. Spawned entities continue after the placements.
        entity.id = index
        lists[listName][#lists[listName] + 1] = entity
    end
    local spawn = { x = data.spawn.x, y = data.spawn.y }

    return {
        name = root:match("([^/]+)$"),
        root = root,
        size = data.size,
        spawn = spawn,
        background = data.background,
        statics = loadTiles(root, data.static or {}, path),
        hazards = lists.hazards,
        blocks = lists.blocks,
        enemies = lists.enemies,
        props = lists.props,
        triggers = lists.triggers,
        scripts = loadScripts(root, data.scripts, path, random),
        random = random,
        types = types,                     -- type name -> type table, loaded so far
        nextId = #placements + 1,          -- id of the first spawned entity
        gravity = numberIn(data.gravity, -10000, 10000, "gravity", path),
        maxFall = numberIn(data.maxFall, 0, 100000, "maxFall", path),
        actions = input.parseActions(data.actions, path),
        camera = cameraFrom(data.camera, spawn, path),
    }
end

return loader
