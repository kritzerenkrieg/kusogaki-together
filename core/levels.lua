-- The levels on this machine, all in the save directory (never inside the
-- game): levels/<name>/ are the player's own (the game's built-in levels
-- are copied there, see levels.seed), downloads/<id>/ the ones downloaded
-- from the level repository (core/levelpack.lua). Each has a fingerprint, its
-- package id; rooms name a level by it, so players find the host's level
-- whatever its folder is called.
local json = require("core.json")
local levelpack = require("core.levelpack")

local levels = {}

levels.BUILTIN = "builtin"           -- inside the game: the levels it ships with
levels.LOCAL = "levels"              -- the player's levels (save directory)
levels.SEED_FILE = "seeded_levels.json"

local catalog = nil -- the list, until levels.refresh
local fingerprints = {} -- root -> fingerprint

local function isLevel(root)
    return love.filesystem.getInfo(root .. "/level.json", "file") ~= nil
end

-- Copy the files of level folder `from` to `to`.
local function copyTree(from, to)
    love.filesystem.createDirectory(to)
    for _, name in ipairs(love.filesystem.getDirectoryItems(from)) do
        local info = love.filesystem.getInfo(from .. "/" .. name)
        if info and info.type == "directory" then
            copyTree(from .. "/" .. name, to .. "/" .. name)
        elseif info and info.type == "file" then
            love.filesystem.write(to .. "/" .. name, love.filesystem.read(from .. "/" .. name))
        end
    end
end

local function readSeeded()
    local text = love.filesystem.getInfo(levels.SEED_FILE, "file") and love.filesystem.read(levels.SEED_FILE)
    local ok, seeded = pcall(json.decode, text or "{}")
    return ok and type(seeded) == "table" and seeded or {}
end

-- Copy the built-in levels into levels/ (once at startup): a missing one is
-- copied, and one the player did not change since it was copied is replaced
-- by a newer built-in version. A level the player changed is left alone.
function levels.seed()
    local seeded, changed = readSeeded(), false
    for _, name in ipairs(love.filesystem.getDirectoryItems(levels.BUILTIN)) do
        local from, to = levels.BUILTIN .. "/" .. name, levels.LOCAL .. "/" .. name
        if name:match("^[%w_]+$") and isLevel(from) then
            local builtin = levelpack.fingerprint(from)
            local present = isLevel(to) and levelpack.fingerprint(to) or nil
            if present ~= builtin and (present == nil or present == seeded[name]) then
                levelpack.removeTree(to)
                copyTree(from, to)
            end
            if seeded[name] ~= builtin and (present == nil or present == seeded[name] or present == builtin) then
                seeded[name], changed = builtin, true
            end
        end
    end
    if changed then
        love.filesystem.write(levels.SEED_FILE, json.encode(seeded))
    end
    catalog = nil
end

local function fingerprintOf(root)
    if not fingerprints[root] then
        fingerprints[root] = levelpack.fingerprint(root)
    end
    return fingerprints[root]
end

-- A level's name for lists and rooms: its level.json `name` (letters,
-- digits and _, as rooms and the room list carry it), else `fallback`.
local function nameOf(root, fallback)
    local ok, data = pcall(json.decode, love.filesystem.read(root .. "/level.json") or "")
    if ok and type(data) == "table" and type(data.name) == "string" and data.name:match("^[%w_]+$")
        and #data.name <= 32 then
        return data.name
    end
    return fallback
end

-- Every level on this machine, sorted by name: { root, name, id, downloaded }.
-- Kept until levels.refresh.
function levels.list()
    if catalog then
        return catalog
    end
    catalog = {}
    for _, name in ipairs(love.filesystem.getDirectoryItems(levels.LOCAL)) do
        local root = levels.LOCAL .. "/" .. name
        if name:match("^[%w_]+$") and isLevel(root) then
            catalog[#catalog + 1] = { root = root, name = nameOf(root, name), id = fingerprintOf(root) }
        end
    end
    for _, id in ipairs(love.filesystem.getDirectoryItems(levelpack.DOWNLOADS)) do
        local root = levelpack.DOWNLOADS .. "/" .. id
        if levelpack.isId(id) and isLevel(root) then
            catalog[#catalog + 1] = { root = root, name = nameOf(root, "level_" .. id:sub(1, 8)), id = id, downloaded = true }
        end
    end
    table.sort(catalog, function(a, b)
        if a.name:lower() ~= b.name:lower() then
            return a.name:lower() < b.name:lower()
        end
        return a.root < b.root
    end)
    return catalog
end

-- Look again (the player may have changed files): a fresh list and fresh
-- fingerprints.
function levels.refresh()
    catalog, fingerprints = nil, {}
end

-- The level with package id `id`, or nil.
function levels.byId(id)
    for _, entry in ipairs(levels.list()) do
        if entry.id == id then
            return entry
        end
    end
    return nil
end

function levels.byRoot(root)
    for _, entry in ipairs(levels.list()) do
        if entry.root == root then
            return entry
        end
    end
    return nil
end

-- Install a downloaded package (levelpack.install); the list then has it.
function levels.install(id, package)
    local root, err = levelpack.install(id, package)
    catalog = nil
    return root, err
end

-- Delete a downloaded level.
function levels.remove(root)
    if root:match("^" .. levelpack.DOWNLOADS .. "/%x+$") then
        levelpack.removeTree(root)
        catalog = nil
        return true
    end
    return false
end

return levels
