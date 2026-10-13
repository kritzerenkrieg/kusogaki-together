-- Minimal JSON: decode and encode objects, arrays, strings, numbers, booleans
-- and null. Errors raise with the byte position of the problem.
-- null: inside arrays it decodes to json.null (so arrays keep their length
-- and order); as an object value the key is left out; a top-level null is nil.
local json = {}

-- Stands for null inside decoded arrays; json.encode writes it as null.
json.null = setmetatable({}, { __tostring = function() return "null" end, __newindex = function()
    error("json.null is read-only", 2)
end })

json.MAX_DEPTH = 64 -- nesting allowed when decoding (untrusted input)

local ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function fail(str, pos, message)
    error(("json: %s at byte %d"):format(message, pos), 0)
end

local function skipSpace(str, pos)
    return str:find("[^ \t\r\n]", pos) or #str + 1
end

local function decodeString(str, pos)
    local out, i = {}, pos + 1
    while true do
        local c = str:sub(i, i)
        if c == "" then
            fail(str, pos, "unterminated string")
        elseif c == '"' then
            return table.concat(out), i + 1
        elseif c == "\\" then
            local e = str:sub(i + 1, i + 1)
            if e == "u" then
                local code = tonumber(str:sub(i + 2, i + 5), 16)
                if not code then fail(str, i, "bad unicode escape") end
                out[#out + 1] = code < 128 and string.char(code) or "?"
                i = i + 6
            elseif ESCAPES[e] then
                out[#out + 1] = ESCAPES[e]
                i = i + 2
            else
                fail(str, i, "bad escape")
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
end

local decodeValue

local function decodeObject(str, pos, depth)
    local obj = {}
    pos = skipSpace(str, pos + 1)
    if str:sub(pos, pos) == "}" then
        return obj, pos + 1
    end
    while true do
        if str:sub(pos, pos) ~= '"' then fail(str, pos, "expected key") end
        local key
        key, pos = decodeString(str, pos)
        pos = skipSpace(str, pos)
        if str:sub(pos, pos) ~= ":" then fail(str, pos, "expected ':'") end
        local value
        value, pos = decodeValue(str, pos + 1, depth)
        if value ~= json.null then
            obj[key] = value
        end
        pos = skipSpace(str, pos)
        local delimiter = str:sub(pos, pos)
        pos = skipSpace(str, pos + 1)
        if delimiter == "}" then
            return obj, pos
        elseif delimiter ~= "," then
            fail(str, pos - 1, "expected ',' or '}'")
        end
    end
end

local function decodeArray(str, pos, depth)
    local arr = {}
    pos = skipSpace(str, pos + 1)
    if str:sub(pos, pos) == "]" then
        return arr, pos + 1
    end
    while true do
        arr[#arr + 1], pos = decodeValue(str, pos, depth)
        pos = skipSpace(str, pos)
        local delimiter = str:sub(pos, pos)
        pos = skipSpace(str, pos + 1)
        if delimiter == "]" then
            return arr, pos
        elseif delimiter ~= "," then
            fail(str, pos - 1, "expected ',' or ']'")
        end
    end
end

decodeValue = function(str, pos, depth)
    pos = skipSpace(str, pos)
    local c = str:sub(pos, pos)
    if c == "{" or c == "[" then
        if depth >= json.MAX_DEPTH then
            fail(str, pos, "nested too deep")
        end
        if c == "{" then
            return decodeObject(str, pos, depth + 1)
        end
        return decodeArray(str, pos, depth + 1)
    elseif c == '"' then
        return decodeString(str, pos)
    elseif str:sub(pos, pos + 3) == "true" then
        return true, pos + 4
    elseif str:sub(pos, pos + 4) == "false" then
        return false, pos + 5
    elseif str:sub(pos, pos + 3) == "null" then
        return json.null, pos + 4
    end
    local number = str:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    if not number then fail(str, pos, "unexpected character") end
    return tonumber(number), pos + #number
end

-- Decode a JSON document into Lua values.
function json.decode(str)
    if type(str) ~= "string" then
        error("json: expected a string", 0)
    end
    local value, pos = decodeValue(str, 1, 0)
    if skipSpace(str, pos) <= #str then
        fail(str, pos, "trailing content")
    end
    if value == json.null then
        return nil
    end
    return value
end

-- ── Encoding ──────────────────────────────────────────────────────────────
local ENCODE_ESCAPES = {
    ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function encodeString(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return ENCODE_ESCAPES[c] or ("\\u%04x"):format(c:byte())
    end) .. '"'
end

-- A table is an array when its keys are exactly 1..n (an empty table is an
-- object unless it is json.null).
local function arrayLength(t)
    local count = 0
    for key in pairs(t) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
            return nil
        end
        count = count + 1
    end
    for i = 1, count do
        if t[i] == nil then
            return nil
        end
    end
    return count > 0 and count or nil
end

local encodeValue

local function encodeTable(t, depth, out)
    if depth > json.MAX_DEPTH then
        error("json: nested too deep (or a cycle)", 0)
    end
    local length = arrayLength(t)
    if length then
        out[#out + 1] = "["
        for i = 1, length do
            if i > 1 then out[#out + 1] = "," end
            encodeValue(t[i], depth + 1, out)
        end
        out[#out + 1] = "]"
        return
    end
    -- Objects: string keys only, sorted, so the same data always encodes the same.
    local keys = {}
    for key in pairs(t) do
        if type(key) ~= "string" then
            error("json: object keys must be strings (got " .. type(key) .. ")", 0)
        end
        keys[#keys + 1] = key
    end
    table.sort(keys)
    out[#out + 1] = "{"
    for i, key in ipairs(keys) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = encodeString(key)
        out[#out + 1] = ":"
        encodeValue(t[key], depth + 1, out)
    end
    out[#out + 1] = "}"
end

encodeValue = function(value, depth, out)
    local kind = type(value)
    if value == nil or value == json.null then
        out[#out + 1] = "null"
    elseif kind == "boolean" then
        out[#out + 1] = tostring(value)
    elseif kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            error("json: cannot encode " .. tostring(value), 0)
        end
        if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
            out[#out + 1] = ("%d"):format(value)
        else
            out[#out + 1] = ("%.17g"):format(value)
        end
    elseif kind == "string" then
        out[#out + 1] = encodeString(value)
    elseif kind == "table" then
        encodeTable(value, depth, out)
    else
        error("json: cannot encode a " .. kind, 0)
    end
end

-- Encode plain Lua data (tables, strings, numbers, booleans, json.null) as
-- JSON text. Object keys come out sorted.
function json.encode(value)
    local out = {}
    encodeValue(value, 0, out)
    return table.concat(out)
end

return json
