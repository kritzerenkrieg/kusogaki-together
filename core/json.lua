-- Minimal JSON decoder: objects, arrays, strings, numbers, booleans, null.
-- Errors raise with the byte position of the problem.
local json = {}

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

local function decodeObject(str, pos)
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
        obj[key], pos = decodeValue(str, pos + 1)
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

local function decodeArray(str, pos)
    local arr = {}
    pos = skipSpace(str, pos + 1)
    if str:sub(pos, pos) == "]" then
        return arr, pos + 1
    end
    while true do
        arr[#arr + 1], pos = decodeValue(str, pos)
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

decodeValue = function(str, pos)
    pos = skipSpace(str, pos)
    local c = str:sub(pos, pos)
    if c == "{" then
        return decodeObject(str, pos)
    elseif c == "[" then
        return decodeArray(str, pos)
    elseif c == '"' then
        return decodeString(str, pos)
    elseif str:sub(pos, pos + 3) == "true" then
        return true, pos + 4
    elseif str:sub(pos, pos + 4) == "false" then
        return false, pos + 5
    elseif str:sub(pos, pos + 3) == "null" then
        return nil, pos + 4
    end
    local number = str:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    if not number then fail(str, pos, "unexpected character") end
    return tonumber(number), pos + #number
end

-- Decode a JSON document into Lua values.
function json.decode(str)
    local value, pos = decodeValue(str, 1)
    if skipSpace(str, pos) <= #str then
        fail(str, pos, "trailing content")
    end
    return value
end

return json
