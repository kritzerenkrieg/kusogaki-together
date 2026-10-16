-- One HTTP request, in its own thread (core/net/http.lua): luasocket blocks,
-- the game must not. Pushes { status, body } or { error } to the request's
-- channel. A reply longer than `maxBytes` is cut off with an error.
local url, method, body, contentType, author, channelName, timeout, maxBytes = ...
local http = require("socket.http")
local ltn12 = require("ltn12")
local channel = love.thread.getChannel(channelName)
body, author = body or nil, author or nil -- false: none

http.TIMEOUT = timeout
local chunks, size = {}, 0
local function sink(chunk, err)
    if chunk then
        size = size + #chunk
        if size > maxBytes then
            return nil, "the reply is too big"
        end
        chunks[#chunks + 1] = chunk
    end
    return 1, err
end
local headers = { ["user-agent"] = "kusogaki-together" }
if body then
    headers["content-type"] = contentType
    headers["content-length"] = tostring(#body)
end
if author then
    headers["x-author"] = author
end
local ok, status = http.request({
    url = url, method = method, headers = headers, sink = sink,
    source = body and ltn12.source.string(body) or nil,
})
if ok and type(status) == "number" then
    channel:push({ status = status, body = table.concat(chunks) })
else
    channel:push({ error = tostring(status) })
end
