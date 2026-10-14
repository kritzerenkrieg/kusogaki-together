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
--   host -> client  snapshot { generation, data }   full snapshot (channel BULK)
-- Either side may answer with reject { reason } and disconnect.
-- Session messages afterwards: restart, joined, left (host -> clients);
-- vote (client -> host: its player's restart vote).
--
-- Player state (core/net/playersync.lua), every message stamped with the
-- level generation g:
--   client -> host  state { g, s, a, p, e }   own player (channel STATE, 20 Hz)
--   host -> client  players { g, list }        { id, s, p, e } per player (STATE)
--   host -> client  setPlayer { g, a, x, y, vx, vy, sx?, sy? }  override (RELIABLE)
local wire = require("core.wire")
local playersync = require("core.net.playersync")

local protocol = {}

protocol.PORT = 26967
protocol.CHANNELS = 3
protocol.STATE, protocol.RELIABLE, protocol.BULK = 0, 1, 2 -- ENet channels
protocol.MAX_CLIENT_MESSAGE = 1024        -- bytes; clients only send small messages
protocol.MAX_HOST_MESSAGE = 256 * 1024    -- bytes; a full snapshot fits easily
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
local isSeq = function(value) return isInt(value, 0, playersync.MAX_SEQ) end

local function isCoordinate(value)
    return type(value) == "number" and value == value and math.abs(value) <= playersync.MAX_COORD
end

local function isOptionalCoordinate(value)
    return value == nil or isCoordinate(value)
end

-- players.list: at most MAX_PLAYERS entries { id, s, p, e }, ids unique.
local function isPlayerStates(value)
    if type(value) ~= "table" or #value > protocol.MAX_PLAYERS or next(value, #value > 0 and #value or nil) ~= nil then
        return false
    end
    local seen = {}
    for _, entry in ipairs(value) do
        if type(entry) ~= "table" or #entry ~= 4 or next(entry, 4) ~= nil
            or not isInt(entry[1], 1, protocol.MAX_PLAYERS) or seen[entry[1]]
            or not isSeq(entry[2]) or not playersync.valid(entry[3]) or not playersync.validEvents(entry[4]) then
            return false
        end
        seen[entry[1]] = true
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
    snapshot = { generation = isGeneration, data = function(v) return type(v) == "table" end },
    restart = {
        seed = function(v) return isInt(v, 1, protocol.MAX_SEED) end,
        generation = isGeneration,
        players = isPlayerList,
    },
    joined = { id = function(v) return isInt(v, 1, protocol.MAX_PLAYERS) end },
    vote = { on = function(v) return type(v) == "boolean" end },
    left = { id = function(v) return isInt(v, 1, protocol.MAX_PLAYERS) end },
    state = { g = isGeneration, s = isSeq, a = isSeq, p = playersync.valid, e = playersync.validEvents },
    players = { g = isGeneration, list = isPlayerStates },
    setPlayer = {
        g = isGeneration, a = isSeq,
        x = isCoordinate, y = isCoordinate, vx = isCoordinate, vy = isCoordinate,
        sx = isOptionalCoordinate, sy = isOptionalCoordinate,
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
