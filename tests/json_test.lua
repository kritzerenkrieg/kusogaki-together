-- JSON checks; no LÖVE needed. Run from the project root:
--   lua tests/json_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local json = require("core.json")

local failures = 0
local function check(name, condition, detail)
    if condition then
        print("ok    " .. name)
    else
        failures = failures + 1
        print("FAIL  " .. name .. (detail and (" (" .. tostring(detail) .. ")") or ""))
    end
end

local function deepEqual(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do
        if not deepEqual(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

-- Round trips
do
    local data = {
        name = "level", format = 1, size = { w = 3392, h = 360 },
        list = { 1, 2.5, -3, "four", true, false },
        nested = { a = { b = { c = "deep" } } },
        text = 'quote " backslash \\ newline \n tab \t',
    }
    local text = json.encode(data)
    check("round trip keeps the data", deepEqual(json.decode(text), data), text)
    check("same data, same text (sorted keys)", json.encode(json.decode(text)) == text)
    check("integers have no decimals", json.encode({ 3392 }) == "[3392]", json.encode({ 3392 }))
    check("fractions keep full precision", json.decode(json.encode(0.1)) == 0.1)
end

-- null
do
    local arr = json.decode("[1, null, 3]")
    check("null keeps its place in arrays", #arr == 3 and arr[2] == json.null and arr[3] == 3)
    local obj = json.decode('{"a": 1, "b": null}')
    check("null object values are left out", obj.a == 1 and obj.b == nil)
    check("top-level null is nil", json.decode("null") == nil)
    check("json.null encodes as null", json.encode({ 1, json.null, 3 }) == "[1,null,3]")
    check("json.null is read-only", not pcall(function() json.null.x = 1 end))
end

-- Limits and errors
do
    local deep = string.rep("[", json.MAX_DEPTH + 1) .. string.rep("]", json.MAX_DEPTH + 1)
    local ok, err = pcall(json.decode, deep)
    check("decoding stops at MAX_DEPTH", not ok and tostring(err):find("too deep"), err)
    local fine = string.rep("[", json.MAX_DEPTH) .. string.rep("]", json.MAX_DEPTH)
    check("MAX_DEPTH itself is fine", pcall(json.decode, fine))

    local cycle = {}
    cycle.self = cycle
    ok, err = pcall(json.encode, cycle)
    check("a cycle is refused", not ok and tostring(err):find("too deep"), err)
    check("NaN is refused", not pcall(json.encode, 0 / 0))
    check("functions are refused", not pcall(json.encode, { f = print }))
    check("mixed keys are refused", not pcall(json.encode, { 1, x = 2 }))
    check("trailing content is refused", not pcall(json.decode, "[1] x"))
    check("non-strings are refused", not pcall(json.decode, nil))
end

-- The bundled level survives a round trip.
do
    local file = io.open("levels/example/level.json")
    local data = json.decode(file:read("*a"))
    file:close()
    check("level.json round trips", deepEqual(json.decode(json.encode(data)), data))
end

print(failures == 0 and "all json checks passed" or (failures .. " json check(s) failed"))
os.exit(failures == 0 and 0 or 1)
