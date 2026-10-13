-- Downloaded level packages: zip files in the save directory, checked against
-- their sha256 and mounted read-only at online/<sha256>. The loader takes that
-- root like a bundled "levels/<name>" (see core/level/loader.lua).
-- Packages never mount under levels/: LÖVE searches the save directory before
-- the game's own files, so that would let a download replace a bundled level.
local levelpack = {}

local mounted = {} -- sha256 -> save-directory path of the mounted zip

local function sha256Hex(data)
    return love.data.encode("string", "hex", love.data.hash("sha256", data))
end

-- sha256 (lowercase hex) of a file in the save directory, or nil and an error.
function levelpack.hashFile(path)
    local data = love.filesystem.read(path)
    if not data then
        return nil, "package not found: " .. tostring(path)
    end
    return sha256Hex(data)
end

-- Mount the zip at `path` (in the save directory) after checking that its
-- sha256 is `expectedHash`. Returns the package root ("online/<sha256>"), or
-- nil and an error message.
function levelpack.mount(path, expectedHash)
    if type(expectedHash) ~= "string" or not expectedHash:match("^%x+$") or #expectedHash ~= 64 then
        return nil, "invalid package hash"
    end
    expectedHash = expectedHash:lower()
    local root = "online/" .. expectedHash
    if mounted[expectedHash] then
        return root
    end
    local actual, err = levelpack.hashFile(path)
    if not actual then
        return nil, err
    end
    if actual ~= expectedHash then
        return nil, ("package hash mismatch: expected %s, got %s"):format(expectedHash, actual)
    end
    if not love.filesystem.mount(path, root, false) then
        return nil, "could not mount package: " .. path
    end
    if not love.filesystem.getInfo(root .. "/level.json", "file") then
        love.filesystem.unmount(path)
        return nil, "package has no level.json at its top level"
    end
    mounted[expectedHash] = path
    return root
end

function levelpack.unmount(expectedHash)
    local path = mounted[expectedHash]
    if path then
        love.filesystem.unmount(path)
        mounted[expectedHash] = nil
    end
end

return levelpack
