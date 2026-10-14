-- Network messages: constants, encoding and validation. Every message is a
-- plain table with a type `t`, encoded with core/wire.lua. Everything that
-- arrives is untrusted: protocol.decode checks size, shape and every field,
-- and returns nil plus a reason instead of raising. See NETWORKING.md
-- (Session flow).
--
-- Join handshake (channel RELIABLE):
--   client -> host  hello  { protocol, game }       versions
--   host -> client  level  { name, fingerprint }    the level to load
--   client -> host  ready  { fingerprint }          "I have that level"
--   host -> client  welcome { you, seed, generation, players }
-- then the host's world arrives as a full world message (below).
-- Either side may answer with reject { reason } and disconnect.
-- Session messages afterwards: restart, joined, left (host -> clients);
-- vote (client -> host: its player's restart vote).
--
-- Hybrid rollback (NETWORKING.md), every message stamped with the level
-- generation g:
--   client -> host  input { g, n, f }   input masks for ticks n-#f+1..n, 60 a
--                                       second (channel STATE; core/net/inputsync.lua)
--   host -> client  snap { g, h, base, set, del, hash, ack, inp, vt, cd }
--                   the host's state after tick h, a delta against the one the
--                   client acknowledged (STATE) or full (base 0, RELIABLE);
--                   core/net/statesync.lua
-- A client acknowledges states in its input messages (k).
local wire = require("core.wire")
local inputsync = require("core.net.inputsync")

local protocol = {}

protocol.PORT = 26967
protocol.CHANNELS = 3
protocol.STATE, protocol.RELIABLE, protocol.BULK = 0, 1, 2 -- ENet channels
protocol.MAX_CLIENT_MESSAGE = 1024        -- bytes; clients only send small messages
protocol.MAX_HOST_MESSAGE = 1024 * 1024   -- bytes; a full world snapshot fits easily
protocol.MAX_PLAYERS = 5
protocol.MAX_SEED = 2147483646
protocol.MAX_REASON = 200

local function isInt(value, low, high)
    return type(value) == "number" and value % 1 == 0 and value >= low and value <= high
end

local function isText(value, maxLength)
    return type(value) == "string" and #value <= maxLength
end

local function isFingerprint(value)
    return type(value) == "string" and #value == 64 and value:match("^%x+$") ~= nil
end

local function isPlayerList(value)
    if type(value) ~= "table" or #value > protocol.MAX_PLAYERS then
        return false
    end
    local seen = {}
    for key, id in pairs(value) do
        if not isInt(key, 1, #value) or not isInt(id, 1, protocol.MAX_PLAYERS) or seen[id] then
            return false
        end
        seen[id] = true
    end
    return true
end

local isGeneration = function(value) return isInt(value, 0, 2 ^ 31) end
local isSeq = function(value) return isInt(value, 0, 2 ^ 31) end

local function isList(value, maxLength)
    return type(value) == "table" and #value <= maxLength and next(value, #value > 0 and #value or nil) == nil
end

local MAX_KEYS = 100000

-- snap.set: { key, value } pairs; values are plain by construction
-- (core/wire.lua decodes nothing else).
local function isSets(value)
    if not isList(value, MAX_KEYS) then
        return false
    end
    for _, entry in ipairs(value) do
        if type(entry) ~= "table" or type(entry[1]) ~= "string" or #entry[1] > 96 then
            return false
        end
    end
    return true
end

local function isKeys(value)
    if not isList(value, MAX_KEYS) then
        return false
    end
    for _, key in ipairs(value) do
        if type(key) ~= "string" or #key > 96 then
            return false
        end
    end
    return true
end

local function isInputs(value)
    if not isList(value, protocol.MAX_PLAYERS) then
        return false
    end
    for _, entry in ipairs(value) do
        if type(entry) ~= "table" or not isInt(entry[1], 1, protocol.MAX_PLAYERS)
            or not isInt(entry[2], 0, 2 ^ 24 - 1) then
            return false
        end
    end
    return true
end

local function isIdList(value)
    if not isList(value, protocol.MAX_PLAYERS) then
        return false
    end
    for _, id in ipairs(value) do
        if not isInt(id, 1, protocol.MAX_PLAYERS) then
            return false
        end
    end
    return true
end

-- Field checks per message type. Messages a side does not expect are refused
-- by the session, not here.
local SHAPES = {
    hello = { protocol = function(v) return isInt(v, 0, 65535) end, game = function(v) return isText(v, 32) end },
    level = { name = function(v) return isText(v, 64) and v:match("^[%w_]+$") ~= nil end, fingerprint = isFingerprint },
    ready = { fingerprint = isFingerprint },
    reject = { reason = function(v) return isText(v, protocol.MAX_REASON) end },
    welcome = {
        you = function(v) return isInt(v, 1, protocol.MAX_PLAYERS) end,
        seed = function(v) return isInt(v, 1, protocol.MAX_SEED) end,
        generation = isGeneration,
        players = isPlayerList,
    },
    restart = {
        seed = function(v) return isInt(v, 1, protocol.MAX_SEED) end,
        generation = isGeneration,
        players = isPlayerList,
    },
    joined = { id = function(v) return isInt(v, 1, protocol.MAX_PLAYERS) end },
    vote = { on = function(v) return type(v) == "boolean" end },
    left = { id = function(v) return isInt(v, 1, protocol.MAX_PLAYERS) end },
    input = { g = isGeneration, n = isSeq, f = inputsync.validMasks, k = isSeq },
    snap = {
        g = isGeneration, h = isSeq, base = isSeq, set = isSets, del = isKeys,
        hash = function(v) return type(v) == "string" and #v == 16 and v:match("^%x+$") ~= nil end,
        ack = isSeq, inp = isInputs, vt = isIdList,
        cd = function(v) return v == false or (type(v) == "number" and v >= 0 and v <= 60) end,
    },
}

-- Encode a message; raises on a malformed one (that is an engine bug).
function protocol.encode(message)
    local ok, reason = protocol.check(message)
    assert(ok, reason)
    return wire.encode(message)
end

-- Is `message` a well-formed message? Returns true, or false and a reason.
function protocol.check(message)
    if type(message) ~= "table" then
        return false, "message is not a table"
    end
    local shape = SHAPES[message.t]
    if not shape then
        return false, "unknown message type " .. tostring(message.t)
    end
    for key in pairs(message) do
        if key ~= "t" and not shape[key] then
            return false, ("%s: unexpected field %s"):format(message.t, tostring(key))
        end
    end
    for key, valid in pairs(shape) do
        if not valid(message[key]) then
            return false, ("%s: bad field %s"):format(message.t, key)
        end
    end
    return true
end

-- Decode untrusted bytes (at most `maxSize`). Returns the message, or nil
-- and a reason.
function protocol.decode(data, maxSize)
    if type(data) ~= "string" then
        return nil, "no data"
    end
    if #data > maxSize then
        return nil, "message too large"
    end
    local message, err = wire.decode(data)
    if message == nil then
        return nil, err or "undecodable message"
    end
    local ok, reason = protocol.check(message)
    if not ok then
        return nil, reason
    end
    return message
end

-- "ip", "ip:port" or "host:port" -> "host:port" for ENet. Nil for anything
-- else.
function protocol.address(text)
    if type(text) ~= "string" or #text > 255 then
        return nil
    end
    local host, port = text:match("^([%w%.%-]+):(%d+)$")
    if not host then
        host, port = text:match("^([%w%.%-]+)$"), protocol.PORT
    end
    port = tonumber(port)
    if not host or not port or port < 1 or port > 65535 then
        return nil
    end
    return host .. ":" .. port
end

return protocol
