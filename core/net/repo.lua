-- The level repository on our server (server/repository), over plain HTTP
-- on the server's port (the same number as the lobby's UDP port). Every call
-- returns a request at once; request:poll() is nil until it is done, then
-- true and the result, or false and an error. Each request runs in its own
-- thread (core/net/http_thread.lua).
--   repo.list(server, page)       -> { page, pages, levels = { { id, name, author, size, uploaded } } }
--   repo.info(server, id)         -> one such level, or false and "not on the server"
--   repo.download(server, id)     -> root of the installed level (core/levels.lua)
--   repo.upload(server, root, author) -> the level's id
-- Downloads are checked against their id (sha256), so a level cannot be
-- swapped on the way; the list itself is not protected (no HTTPS yet).
local json = require("core.json")
local levelpack = require("core.levelpack")
local levels = require("core.levels")
local rendezvous = require("core.net.rendezvous")

local repo = {}

repo.TIMEOUT = 15 -- seconds a request may stall
local MAX_REPLY = levelpack.MAX_SIZE + 4096

local nextChannel = 0

-- "host[:port]" -> "http://host:port", or nil and a reason.
function repo.baseUrl(server)
    if type(server) ~= "string" or server == "" then
        return nil, "no server set"
    end
    local name, port = server:match("^([%w%.%-]+):(%d+)$")
    if not name then
        name, port = server:match("^([%w%.%-]+)$"), rendezvous.PORT
    end
    if not name or not tonumber(port) or tonumber(port) < 1 or tonumber(port) > 65535 then
        return nil, "bad server address: " .. server
    end
    return ("http://%s:%d"):format(name, tonumber(port))
end

local Request = {}
Request.__index = Request

-- A request that failed before it was sent.
local function failed(err)
    return setmetatable({ result = { false, err } }, Request)
end

local function send(server, method, path, body, author, finish)
    local base, err = repo.baseUrl(server)
    if not base then
        return failed(err)
    end
    nextChannel = nextChannel + 1
    local channelName = "repo_" .. nextChannel
    local channel = love.thread.getChannel(channelName)
    channel:clear()
    local thread = love.thread.newThread("core/net/http_thread.lua")
    thread:start(base .. path, method, body or false, "application/octet-stream", author or false, channelName,
        repo.TIMEOUT, MAX_REPLY)
    return setmetatable({ channel = channel, thread = thread, finish = finish }, Request)
end

-- The error a server reply carries ({"error": ...}), or a plain one.
local function replyError(reply)
    local ok, data = pcall(json.decode, reply.body or "")
    if ok and type(data) == "table" and type(data.error) == "string" then
        return data.error:sub(1, 120)
    end
    return "the server answered " .. tostring(reply.status)
end

-- nil while running; then true and the result, or false and an error.
function Request:poll()
    if not self.result then
        local reply = self.channel:pop()
        if not reply then
            local threadError = self.thread:getError()
            if threadError then
                self.result = { false, threadError }
            end
            return nil
        end
        if reply.error then
            self.result = { false, "could not reach the server (" .. reply.error .. ")" }
        else
            self.result = { self.finish(reply) }
        end
    end
    return unpack(self.result, 1, 2)
end

-- Wait for the result (tests).
function Request:wait()
    while self:poll() == nil do
        love.timer.sleep(0.01)
    end
    return self:poll()
end

local function decode(reply)
    local ok, data = pcall(json.decode, reply.body or "")
    if ok and type(data) == "table" then
        return data
    end
    return nil
end

-- A level entry from the server, checked (it is shown and used as a path).
local function cleanEntry(entry)
    if type(entry) ~= "table" or not levelpack.isId(entry.id) then
        return nil
    end
    local function clean(value, size)
        return type(value) == "string" and (value:gsub("[^\32-\126]", "")):sub(1, size) or ""
    end
    return {
        id = entry.id, name = clean(entry.name, 32), author = clean(entry.author, 16),
        size = tonumber(entry.size) or 0, uploaded = tonumber(entry.uploaded) or 0,
    }
end

function repo.list(server, page)
    return send(server, "GET", "/levels?page=" .. math.max(1, math.floor(tonumber(page) or 1)), nil, nil,
        function(reply)
            local data = reply.status == 200 and decode(reply)
            if not data or type(data.levels) ~= "table" then
                return false, reply.status == 200 and "the server sent a bad list" or replyError(reply)
            end
            local list = {}
            for _, entry in ipairs(data.levels) do
                list[#list + 1] = cleanEntry(entry)
            end
            return true, { page = tonumber(data.page) or 1, pages = math.max(1, tonumber(data.pages) or 1),
                levels = list }
        end)
end

function repo.info(server, id)
    if not levelpack.isId(id) then
        return failed("invalid level id")
    end
    return send(server, "GET", "/levels/" .. id .. "/info", nil, nil, function(reply)
        if reply.status == 404 then
            return false, "not on the server"
        end
        local entry = reply.status == 200 and cleanEntry(decode(reply))
        if not entry then
            return false, replyError(reply)
        end
        return true, entry
    end)
end

function repo.download(server, id)
    if not levelpack.isId(id) then
        return failed("invalid level id")
    end
    return send(server, "GET", "/levels/" .. id, nil, nil, function(reply)
        if reply.status == 404 then
            return false, "the level is not on the server"
        elseif reply.status ~= 200 then
            return false, replyError(reply)
        end
        local root, err = levels.install(id, reply.body)
        if not root then
            return false, err
        end
        return true, root
    end)
end

function repo.upload(server, root, author)
    local package = levelpack.pack(root)
    if #package > levelpack.MAX_SIZE then
        return failed("the level is too big to upload (16 MB at most)")
    end
    local files, err = levelpack.unpack(package) -- the server's rules, checked here first
    if not files then
        return failed(err)
    end
    local id = levelpack.sha256(package)
    return send(server, "POST", "/levels", package, rendezvous.cleanName(author, 16), function(reply)
        local data = decode(reply)
        if (reply.status == 200 or reply.status == 201) and data and data.id == id then
            return true, id
        end
        return false, replyError(reply)
    end)
end

return repo
