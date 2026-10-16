-- Level packages: one level's files as a single string, the form levels are
-- uploaded to and downloaded from the level repository on our server
-- (server/repository). A package lists the level's files in byte order of
-- their paths, each as `path \0 size \0 contents`; its id (the level's
-- fingerprint) is the sha256 of that string, so the same files give the same
-- id on every machine and on the server. Only the files a level may have
-- count (FILE RULES below, the same on the server); anything else in a level
-- folder is left out.
-- Downloaded levels are unpacked into the save directory at
-- downloads/<id>/ (levelpack.install); the loader takes that root like a
-- level folder "levels/<name>" (core/level/loader.lua).
local watchdog = require("core.watchdog")

local levelpack = {}

levelpack.MAX_SIZE = 16 * 1024 * 1024 -- a whole package
levelpack.MAX_FILES = 256
levelpack.MAX_LUA = 200 * 1024        -- every script together
levelpack.DOWNLOADS = "downloads"

-- FILE RULES: level.json, entities/<name>.lua, scripts/<name>.lua, and
-- assets/... images and sounds. Path parts are letters, digits, _ - and .,
-- never start with a dot (no hidden files, no ..), at most 4 deep and 100
-- characters long.
local ASSET_EXTENSIONS = { png = true, jpg = true, jpeg = true, wav = true, ogg = true, mp3 = true }

function levelpack.allowed(path)
    if type(path) ~= "string" or #path > 100 or path:find("//", 1, true) then
        return false
    end
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if not part:match("^[%w_%-][%w_%-%.]*$") then
            return false
        end
        parts[#parts + 1] = part
    end
    if #parts == 0 or #parts > 4 or path:sub(1, 1) == "/" or path:sub(-1) == "/" then
        return false
    end
    if path == "level.json" then
        return true
    end
    if #parts == 2 and (parts[1] == "entities" or parts[1] == "scripts") then
        return parts[2]:match("^[%w_]+%.lua$") ~= nil
    end
    if parts[1] == "assets" and #parts >= 2 then
        local extension = parts[#parts]:match("%.(%w+)$")
        return extension ~= nil and ASSET_EXTENSIONS[extension:lower()] == true
    end
    return false
end

local function sha256Hex(data)
    return love.data.encode("string", "hex", love.data.hash("sha256", data))
end
levelpack.sha256 = sha256Hex

-- Is `id` a package id (64 lowercase hex digits)?
function levelpack.isId(id)
    return type(id) == "string" and #id == 64 and id:match("^[0-9a-f]+$") ~= nil
end

-- The package of the level folder `root`, and the paths left out of it.
function levelpack.pack(root)
    local files, skipped = {}, {}
    local function walk(dir, prefix)
        for _, name in ipairs(love.filesystem.getDirectoryItems(dir)) do
            local path, relative = dir .. "/" .. name, prefix .. name
            local info = love.filesystem.getInfo(path)
            if info and info.type == "directory" then
                walk(path, relative .. "/")
            elseif info and info.type == "file" then
                if levelpack.allowed(relative) then
                    files[#files + 1] = relative
                else
                    skipped[#skipped + 1] = relative
                end
            end
        end
    end
    walk(root, "")
    table.sort(files)
    local parts = {}
    for _, relative in ipairs(files) do
        local data = love.filesystem.read(root .. "/" .. relative) or ""
        parts[#parts + 1] = relative .. "\0" .. #data .. "\0" .. data
    end
    return table.concat(parts), skipped
end

-- Fingerprint (package id) of a level root, the same on every machine with
-- the same files. A download's folder is named after its id (checked when it
-- was installed).
function levelpack.fingerprint(root)
    local id = root:match("^" .. levelpack.DOWNLOADS .. "/(%x+)$")
    if id then
        return id:lower()
    end
    return sha256Hex((levelpack.pack(root)))
end

-- The files in a package: a list of { path, data } in package order, or nil
-- and what is wrong with it. Checks every rule the server checks.
function levelpack.unpack(package)
    if type(package) ~= "string" or #package > levelpack.MAX_SIZE then
        return nil, "the package is too big"
    end
    local files, at, lua, last = {}, 1, 0, nil
    while at <= #package do
        local pathEnd = package:find("\0", at, true)
        local sizeEnd = pathEnd and package:find("\0", pathEnd + 1, true)
        if not sizeEnd then
            return nil, "the package is cut short"
        end
        local path, size = package:sub(at, pathEnd - 1), package:sub(pathEnd + 1, sizeEnd - 1)
        if not levelpack.allowed(path) then
            return nil, "a level may not have the file " .. path
        end
        if last and path <= last then
            return nil, "the package's files are out of order"
        end
        if not size:match("^%d+$") or #size > 9 or size ~= tostring(tonumber(size))
            or sizeEnd + tonumber(size) > #package then
            return nil, "the package is cut short"
        end
        local data = package:sub(sizeEnd + 1, sizeEnd + tonumber(size))
        if path:match("%.lua$") then
            if data:sub(1, 1) == "\27" then
                return nil, "compiled Lua is not allowed: " .. path
            end
            lua = lua + #data
        end
        files[#files + 1] = { path = path, data = data }
        if #files > levelpack.MAX_FILES then
            return nil, "a level has at most " .. levelpack.MAX_FILES .. " files"
        end
        last, at = path, sizeEnd + tonumber(size) + 1
    end
    if lua > levelpack.MAX_LUA then
        return nil, "the scripts are too big"
    end
    for _, file in ipairs(files) do
        if file.path == "level.json" then
            return files
        end
    end
    return nil, "the package has no level.json"
end

-- Delete a file or a folder with everything in it (in the save directory).
function levelpack.removeTree(path)
    local info = love.filesystem.getInfo(path)
    if info and info.type == "directory" then
        for _, name in ipairs(love.filesystem.getDirectoryItems(path)) do
            levelpack.removeTree(path .. "/" .. name)
        end
    end
    love.filesystem.remove(path)
end

-- Unpack a downloaded package into downloads/<id>/ after checking that it
-- is the package `id`. Returns the level's root, or nil and an error. A
-- level the watchdog blocked is refused. level.json is written last: a
-- download cut short has none and is not a level.
function levelpack.install(id, package)
    if not levelpack.isId(id) then
        return nil, "invalid level id"
    end
    if watchdog.isBlocked(id) then
        return nil, "level blocked: it froze the game before"
    end
    if type(package) ~= "string" or sha256Hex(package) ~= id then
        return nil, "the download does not match the level's id"
    end
    local files, err = levelpack.unpack(package)
    if not files then
        return nil, err
    end
    local root = levelpack.DOWNLOADS .. "/" .. id
    levelpack.removeTree(root)
    local levelJson
    for _, file in ipairs(files) do
        if file.path == "level.json" then
            levelJson = file
        else
            local folder = (root .. "/" .. file.path):match("^(.*)/[^/]+$")
            love.filesystem.createDirectory(folder)
            if not love.filesystem.write(root .. "/" .. file.path, file.data) then
                levelpack.removeTree(root)
                return nil, "could not save " .. file.path
            end
        end
    end
    love.filesystem.createDirectory(root)
    if not love.filesystem.write(root .. "/level.json", levelJson.data) then
        levelpack.removeTree(root)
        return nil, "could not save level.json"
    end
    return root
end

return levelpack
