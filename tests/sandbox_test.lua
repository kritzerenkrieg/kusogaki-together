-- Sandbox checks: one test script per blocked capability (TECHNICAL.md,
-- Sandbox), plus the limits and the seeded random generator. No LÖVE needed.
-- Run from the project root under both interpreters:
--   luajit tests/sandbox_test.lua
--   lua tests/sandbox_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local script = require("core.script")
local mathx = require("core.mathx")

local failures = 0
local function check(name, condition, detail)
    if condition then
        print("ok    " .. name)
    else
        failures = failures + 1
        print("FAIL  " .. name .. (detail and (" (" .. tostring(detail) .. ")") or ""))
    end
end

-- Quieter: guarded calls print when they disable a script.
local realPrint = print
local function quietly(fn)
    print = function() end
    local results = { pcall(fn) }
    print = realPrint
    return unpack(results)
end

-- Run source in the sandbox; returns ok, result-or-error.
local function run(source, injected)
    return quietly(function() return script.run(source, "test", injected) end)
end

-- ── Blocked globals ───────────────────────────────────────────────────────
for _, name in ipairs({ "os", "io", "require", "dofile", "loadfile", "load", "loadstring",
    "debug", "package", "getfenv", "setfenv", "coroutine", "collectgarbage", "jit", "ffi",
    "module", "newproxy", "print", "_G" }) do
    local ok, value = run("return " .. name)
    check("no " .. name, ok and value == nil, tostring(value))
end

do
    local ok, err = run(string.dump(function() return 1 end))
    check("bytecode is rejected", not ok and tostring(err):find("bytecode"), err)
end

-- ── Libraries are copies ──────────────────────────────────────────────────
do
    local ok, value = run("return math.random")
    check("no math.random", ok and value == nil)
    ok, value = run("return math.randomseed")
    check("no math.randomseed", ok and value == nil)
    ok, value = run("return math.floor(2.5)")
    check("math works", ok and value == 2)
    local floor = math.floor
    run("math.floor = nil; string.upper = nil; table.insert = nil")
    check("changing math/string/table stays in the sandbox",
        math.floor == floor and string.upper ~= nil and table.insert ~= nil)
    ok, value = run("return string.dump")
    check("no string.dump", ok and value == nil)
end

do
    local ok, value = run("return getmetatable('')")
    check("a string's metatable (the engine string library) is hidden", ok and value == nil)
    ok, value = run("local t = setmetatable({}, { x = 1 }); return getmetatable(t).x")
    check("scripts still see their own metatables", ok and value == 1)
end

do
    local ok, err = run("return string.rep('x', 1e9)")
    check("string.rep is capped", not ok and tostring(err):find("too large"), err)
end

-- ── Read-only engine classes ──────────────────────────────────────────────
do
    local Engine = { CONFIG = { friction = 900 }, value = 1 }
    function Engine.get() return Engine.value end
    local view = script.readonly(Engine, { extra = "override" })
    local injected = { Engine = view }

    local ok, err = run("Engine.value = 2", injected)
    check("engine class fields cannot be set", not ok and Engine.value == 1, err)
    ok, err = run("Engine.CONFIG.friction = 0", injected)
    check("nested engine tables cannot be set", not ok and Engine.CONFIG.friction == 900, err)
    ok, err = run("Engine.get = function() return 99 end", injected)
    check("engine functions cannot be replaced", not ok and Engine.get() == 1, err)
    ok, err = run("setmetatable(Engine, nil)", injected)
    check("a view's metatable is protected", not ok, err)
    ok, err = run("return getmetatable(Engine)", injected)
    check("a view hides its metatable", ok and err == false)
    local value
    ok, value = run("return Engine.get() + Engine.CONFIG.friction", injected)
    check("views read through to the engine", ok and value == 901, value)
    ok, value = run("return Engine.extra", injected)
    check("views can override fields (bound helpers)", ok and value == "override")
    ok, value = run([[
        local Mine = setmetatable({}, { __index = Engine })
        Mine.__index = Mine
        Mine.value = 5
        return Mine.value + Engine.value
    ]], injected)
    check("scripts subclass views as before", ok and value == 6, value)
end

do
    local Class = {}
    Class.__index = Class
    Class.__metatable = false
    local instance = setmetatable({}, Class)
    local ok, value = run("return getmetatable(obj)", { obj = instance })
    check("protected engine instances hide their class", ok and value == false)
end

-- ── Limits ────────────────────────────────────────────────────────────────
do
    local started = os.clock()
    local ok, err = quietly(function() return script.run("while true do end", "loop") end)
    check("an endless loop is stopped", not ok and tostring(err):find("instructions"), err)
    check("... quickly", os.clock() - started < 5, os.clock() - started)
end

do
    local ok, err = quietly(function()
        return script.run("local t = {} for i = 1, 1e9 do t[i] = string.rep('x', 100000) .. i end", "memory")
    end)
    check("runaway memory is stopped", not ok and tostring(err):find("memory"), err)
    collectgarbage()
end

do
    local ok, err = quietly(function()
        return script.run([[
            while true do
                pcall(function() while true do end end)
            end
        ]], "catcher")
    end)
    check("pcall cannot swallow a limit", not ok and tostring(err):find("instructions"), err)
end

do
    local ok, Type = run([[
        local T = {}
        T.calls = 0
        function T.update() T.calls = T.calls + 1; if T.calls == 2 then error("boom") end; return "ran" end
        function T.spin() while true do end end
        return T
    ]])
    check("a type script loads", ok and type(Type) == "table")
    script.guardFunctions(Type, "T")
    local first = Type.update()
    local second, third
    quietly(function()
        second = Type.update()
        third = Type.update()
    end)
    check("a guarded call runs normally", first == "ran")
    check("an error disables the script instead of crashing", second == nil and Type.scriptDisabled == true)
    check("a disabled script no longer runs", third == nil and Type.calls == 2, Type.calls)
    check("the error is kept", tostring(Type.scriptError):find("boom"), Type.scriptError)

    local ok2, Spinner = run("local S = {} function S.spin() while true do end end return S")
    script.guardFunctions(Spinner, "S")
    local result
    quietly(function() result = Spinner.spin() end)
    check("a runaway call later in the game disables only that script",
        ok2 and result == nil and Spinner.scriptDisabled == true)
end

do
    local ok = pcall(function()
        for _ = 1, 1e6 do end -- engine code after a limit still runs freely
    end)
    check("limits are off outside script calls", ok)
end

-- ── C functions: sizes and patterns ───────────────────────────────────────
-- Built-in functions run as one step, so the hook cannot interrupt them;
-- these limits stop them before they start.
do
    local ok, err = run("return ('x'):rep(1e9)")
    check("string methods are capped too", not ok and tostring(err):find("too large"), err)
    ok, err = run("return ('x'):rep(65536):gsub('.', ('y'):rep(1000))")
    check("gsub cannot blow up a string", not ok and tostring(err):find("too large"), err)
    ok, err = run("local t = {} for i = 1, 1000 do t[i] = i end return table.concat(t, ('x'):rep(100000))")
    check("table.concat cannot blow up a string", not ok and tostring(err):find("too large"), err)

    local started = os.clock()
    ok, err = run("return ('a'):rep(40):find(('a*'):rep(40) .. 'b')")
    check("a backtracking pattern is refused", not ok and tostring(err):find("too complex"), err)
    check("... before it runs", os.clock() - started < 1, os.clock() - started)
    ok, err = run("return ('a'):rep(300000):find('b')")
    check("searching a huge string is refused", not ok and tostring(err):find("too long"), err)
    ok, err = run("return ('a'):rep(300000):find(('a*'):rep(20), 1, true)")
    check("plain find is allowed (no pattern)", ok, err)
    ok, err = run("return ('key=value'):match('^(%w+)=(%w+)$')")
    check("ordinary patterns still work", ok and err == "key", err)
    check("engine code keeps full patterns",
        ("aaaa"):find(("a?"):rep(10) .. "a") ~= nil and #("x"):rep(1000) == 1000)
end

do
    local ok, err = quietly(function()
        return script.run("local s = 'x' for i = 1, 40 do s = s .. s end return #s", "doubling")
    end)
    check("a doubling string is stopped", not ok and tostring(err):find("memory"), err)
    collectgarbage()
end

-- ── Script code outside guarded calls ─────────────────────────────────────
-- Scripts can store functions where the engine later calls them (an entity's
-- draw, an event, a metatable on a table they were given). script.protect
-- limits any script code in an engine phase.
do
    local ok, parts = run([[
        local spin = function() while true do end end
        local trap = setmetatable({}, { __index = function() while true do end end })
        return { spin = spin, trap = trap }
    ]])
    check("a script hands out its functions", ok and type(parts) == "table")

    local started = os.clock()
    local ok2, err = script.protect(function() parts.spin() end)
    check("a stored runaway function is stopped in a protected phase",
        not ok2 and tostring(err):find("instructions"), err)
    check("... quickly", os.clock() - started < 5, os.clock() - started)

    local ok3, err3 = script.protect(function() return parts.trap.anything end)
    check("a runaway metamethod is stopped in a protected phase",
        not ok3 and tostring(err3):find("instructions"), err3)

    local ok4, value = script.protect(function(a, b) return a + b end, 2, 3)
    check("a protected phase returns its results", ok4 and value == 5)
    local ok5, err5 = script.protect(function() error("engine bug") end)
    check("an engine error in a phase is reported with a traceback",
        not ok5 and tostring(err5):find("engine bug") and tostring(err5):find("traceback"), err5)
    local started2 = os.clock()
    local ok6 = pcall(function() for _ = 1, 3e7 do end end)
    check("engine code outside phases runs at full speed", ok6 and os.clock() - started2 < 2)
end

-- ── Seeded random ─────────────────────────────────────────────────────────
do
    -- Known answer for MINSTD (multiplier 48271) from seed 1: the 10000th
    -- state is 399268537 (the C++ std::minstd_rand reference value).
    local rng = mathx.newRandom(1)
    for _ = 1, 10000 do
        rng:random()
    end
    check("seeded random matches the MINSTD reference", rng:getState() == 399268537, rng:getState())

    local a, b = mathx.newRandom("room-42"), mathx.newRandom("room-42")
    local same, inRange = true, true
    for _ = 1, 1000 do
        local x, y = a:random(3, 9), b:random(3, 9)
        same = same and x == y
        inRange = inRange and x >= 3 and x <= 9 and x == math.floor(x)
    end
    check("same seed, same numbers", same)
    check("random(m, n) stays in [m, n]", inRange)

    local saved = a:getState()
    local next1 = a:random()
    a:setState(saved)
    check("getState/setState resumes exactly", a:random() == next1)

    local unitOk = true
    for _ = 1, 1000 do
        local u = a:random()
        unitOk = unitOk and u >= 0 and u < 1
    end
    check("random() stays in [0, 1)", unitOk)

    local ok, value = run("return random(1, 6)", { random = function(m, n) return a:random(m, n) end })
    check("scripts get the level's random as random(m, n)", ok and value >= 1 and value <= 6, value)
end

print(failures == 0 and "all sandbox checks passed" or (failures .. " sandbox check(s) failed"))
os.exit(failures == 0 and 0 or 1)
