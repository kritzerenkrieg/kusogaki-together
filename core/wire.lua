-- Binary encoding of plain data for network messages (snapshots, events,
-- input frames), using love.data.pack. Decoding treats input as untrusted: it
-- checks every length against the data and limits depth and item count, and
-- returns nil plus a message instead of raising.
--
-- Format: one tag byte per value, then its payload (little-endian):
--   0 nil   1 false   2 true
--   3 small integer 0..255 (1 byte)   4 integer (int32)   5 number (double)
--   6 string (uint32 length + bytes)
--   7 table (uint32 pair count, then key, value, key, value ...)
--   8 list  (uint32 count, then the values): a table whose keys are 1..n
-- Table keys come out sorted (numbers first, then strings), so the same data
-- always encodes to the same bytes. Lists are what keeps messages small:
-- core/level/netstate.lua packs snapshot records as lists in schema order.
local wire = {}

wire.MAX_DEPTH = 32
wire.MAX_ITEMS = 100000 -- values in one message
wire.MAX_STRING = 1024 * 1024

local pack, unpack = love.data.pack, love.data.unpack

local NIL, FALSE, TRUE, BYTE, INT, DOUBLE, STRING, TABLE, LIST = 0, 1, 2, 3, 4, 5, 6, 7, 8

local function keyOrder(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then
        return ta == "number"
    end
    return a < b
end

local encodeValue

local function encodeTable(t, depth, out)
    if depth > wire.MAX_DEPTH then
        error("wire: nested too deep (or a cycle)", 0)
    end
    local keys = {}
    local isList = true
    for key in pairs(t) do
        local kind = type(key)
        if kind ~= "string" and kind ~= "number" then
            error("wire: table keys must be strings or numbers", 0)
        end
        keys[#keys + 1] = key
        isList = isList and kind == "number"
    end
    if isList and #keys > 0 then
        for i = 1, #keys do
            if t[i] == nil then
                isList = false
                break
            end
        end
        if isList then
            out[#out + 1] = pack("string", "<BI4", LIST, #keys)
            for i = 1, #keys do
                encodeValue(t[i], depth + 1, out)
            end
            return
        end
    end
    table.sort(keys, keyOrder)
    out[#out + 1] = pack("string", "<BI4", TABLE, #keys)
    for _, key in ipairs(keys) do
        encodeValue(key, depth + 1, out)
        encodeValue(t[key], depth + 1, out)
    end
end

encodeValue = function(value, depth, out)
    local kind = type(value)
    if value == nil then
        out[#out + 1] = pack("string", "<B", NIL)
    elseif value == false then
        out[#out + 1] = pack("string", "<B", FALSE)
    elseif value == true then
        out[#out + 1] = pack("string", "<B", TRUE)
    elseif kind == "number" then
        if value == math.floor(value) and value >= 0 and value <= 255 then
            out[#out + 1] = pack("string", "<BB", BYTE, value)
        elseif value == math.floor(value) and value >= -2147483648 and value <= 2147483647 then
            out[#out + 1] = pack("string", "<Bi4", INT, value)
        else
            out[#out + 1] = pack("string", "<Bd", DOUBLE, value)
        end
    elseif kind == "string" then
        out[#out + 1] = pack("string", "<BI4", STRING, #value) .. value
    elseif kind == "table" then
        encodeTable(value, depth, out)
    else
        error("wire: cannot encode a " .. kind, 0)
    end
end

-- Encode plain data to a binary string.
function wire.encode(value)
    local out = {}
    encodeValue(value, 0, out)
    return table.concat(out)
end

-- ── Decoding ──────────────────────────────────────────────────────────────
local function decodeError(message, pos)
    error(("wire: %s at byte %d"):format(message, pos), 0)
end

local decodeValue

local function need(data, pos, size)
    if pos + size - 1 > #data then
        decodeError("truncated", pos)
    end
end

decodeValue = function(data, pos, depth, budget)
    budget.items = budget.items + 1
    if budget.items > wire.MAX_ITEMS then
        decodeError("too many values", pos)
    end
    need(data, pos, 1)
    local tag = data:byte(pos)
    pos = pos + 1
    if tag == NIL then
        return nil, pos
    elseif tag == FALSE then
        return false, pos
    elseif tag == TRUE then
        return true, pos
    elseif tag == BYTE then
        need(data, pos, 1)
        return data:byte(pos), pos + 1
    elseif tag == INT then
        need(data, pos, 4)
        return (unpack("<i4", data, pos)), pos + 4
    elseif tag == DOUBLE then
        need(data, pos, 8)
        return (unpack("<d", data, pos)), pos + 8
    elseif tag == STRING then
        need(data, pos, 4)
        local length = unpack("<I4", data, pos)
        pos = pos + 4
        if length > wire.MAX_STRING then
            decodeError("string too long", pos)
        end
        need(data, pos, length)
        return data:sub(pos, pos + length - 1), pos + length
    elseif tag == TABLE then
        if depth >= wire.MAX_DEPTH then
            decodeError("nested too deep", pos)
        end
        need(data, pos, 4)
        local count = unpack("<I4", data, pos)
        pos = pos + 4
        if count > wire.MAX_ITEMS then
            decodeError("table too large", pos)
        end
        local t = {}
        for _ = 1, count do
            local key, value
            key, pos = decodeValue(data, pos, depth + 1, budget)
            local kind = type(key)
            if (kind ~= "string" and kind ~= "number") or key ~= key then
                decodeError("bad table key", pos)
            end
            value, pos = decodeValue(data, pos, depth + 1, budget)
            t[key] = value
        end
        return t, pos
    elseif tag == LIST then
        if depth >= wire.MAX_DEPTH then
            decodeError("nested too deep", pos)
        end
        need(data, pos, 4)
        local count = unpack("<I4", data, pos)
        pos = pos + 4
        if count > wire.MAX_ITEMS then
            decodeError("list too large", pos)
        end
        local list = {}
        for i = 1, count do
            list[i], pos = decodeValue(data, pos, depth + 1, budget)
        end
        return list, pos
    end
    decodeError("unknown tag " .. tag, pos - 1)
end

-- Decode a binary string. Returns the value, or nil and an error message when
-- the data is malformed, truncated, has trailing bytes or breaks a limit.
function wire.decode(data)
    if type(data) ~= "string" then
        return nil, "wire: expected a string"
    end
    local ok, value, pos = pcall(decodeValue, data, 1, 0, { items = 0 })
    if not ok then
        return nil, value
    end
    if pos ~= #data + 1 then
        return nil, ("wire: trailing data at byte %d"):format(pos)
    end
    return value
end

return wire
