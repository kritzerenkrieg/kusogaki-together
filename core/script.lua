-- Runs mod Lua scripts (entity types, level scripts) in a restricted
-- environment. See TECHNICAL.md (Sandbox) for the rules; each one has a test in
-- tests/sandbox_test.lua. Lua environments are a guardrail, not a security
-- boundary: fully untrusted code still belongs in a separate process.
--
-- What a script gets:
-- - whitelisted globals only (no os, io, require, load*, dofile, debug, ffi,
--   package, getfenv/setfenv, coroutine, collectgarbage);
-- - copies of math (without random/randomseed), string and table, so changing
--   them never reaches the engine;
-- - injected engine values (e.g. Entity, Prop) as read-only views;
-- - `random`, the level's seeded generator, when the loader provides one.
-- Scripts also receive live game objects (their entities, the level, players)
-- and may change them: that is the design (see TECHNICAL.md).
--
-- Limits (see "Limits" below) stop runaway scripts two ways:
-- - script.guard wraps the functions a script defines at load; an error or a
--   blown limit there disables that script and the game goes on;
-- - script.protect runs a whole engine phase (a simulation step, drawing,
--   presenting events) with limits on any script code that runs inside it,
--   including functions a script stored somewhere at runtime and metamethods
--   on tables it touched. A failure there stops the phase with an error the
--   caller turns into a stopped level instead of a crash.
local script = {}

-- ── Limits ────────────────────────────────────────────────────────────────
script.HOOK_EVERY = 20             -- instructions between checks inside guarded calls
script.PHASE_HOOK_EVERY = 1000     -- ... elsewhere in a protected phase (cheap backstop)
script.MAX_INSTRUCTIONS = 2000000  -- script instructions per call / per phase
script.MAX_MEMORY_KB = 64 * 1024   -- heap growth allowed per call / per phase
script.MAX_STRING = 16 * 1024 * 1024 -- largest string rep/gsub/concat may build
script.MAX_PATTERN_SUBJECT = 256 * 1024 -- longest string a script may search
script.MAX_PATTERN_REPEATS = 8     -- quantifiers (* + - ?) in a script's pattern
script.LIMIT_ERROR = "script limit exceeded"

-- Captured at load, before any script runs.
local sethook, getinfo = debug.sethook, debug.getinfo
local gccount = function() return collectgarbage("count") end
local rawPcall, rawXpcall, rawUnpack, rawError = pcall, xpcall, unpack, error
local traceback = debug.traceback

local SAFE_GLOBALS = {
    "assert", "error", "ipairs", "next", "pairs", "rawequal", "rawget", "rawset",
    "select", "setmetatable", "tonumber", "tostring", "type", "unpack",
}

local scriptSources = {} -- "@<chunk name>" of every loaded script -> true

-- ── Read-only views ───────────────────────────────────────────────────────
-- A view reads through to the real table (tables inside come back as views
-- too) and refuses writes. Functions are shared as they are.
local views = setmetatable({}, { __mode = "k" })
local viewTargets = setmetatable({}, { __mode = "k" }) -- view -> { real, overrides }

local function readonly(real, overrides)
    if not overrides and views[real] then
        return views[real]
    end
    local view = setmetatable({}, {
        __index = function(_, key)
            local value = overrides and overrides[key]
            if value == nil then
                value = real[key]
            end
            if type(value) == "table" then
                return readonly(value)
            end
            return value
        end,
        __newindex = function(_, key)
            rawError("read-only engine table (tried to set " .. tostring(key) .. ")", 2)
        end,
        __metatable = false,
    })
    if not overrides then
        views[real] = view
    end
    viewTargets[view] = { real = real, overrides = overrides }
    return view
end
script.readonly = readonly

-- The real table (and overrides) behind a view, for the reachability audit.
function script.viewTarget(view)
    return viewTargets[view]
end

-- ── The limit hook ────────────────────────────────────────────────────────
local depth = 0           -- nesting of guarded calls (script -> engine -> script)
local callFires, callMemory = 0, 0
local phaseActive = false -- inside script.protect
local phaseFires, phaseMemory = 0, 0

local function limitError(what)
    rawError(script.LIMIT_ERROR .. ": " .. what, 2)
end

local function limitHook()
    if depth > 0 then
        callFires = callFires + 1
        if callFires * script.HOOK_EVERY > script.MAX_INSTRUCTIONS then
            limitError("too many instructions")
        end
        if gccount() - callMemory > script.MAX_MEMORY_KB then
            limitError("too much memory")
        end
    elseif phaseActive then
        -- Outside a guarded call: count only script code (engine code is
        -- trusted), recognised by the chunk it was loaded from.
        local info = getinfo(2, "S")
        if info and scriptSources[info.source] then
            phaseFires = phaseFires + 1
            if phaseFires * script.PHASE_HOOK_EVERY > script.MAX_INSTRUCTIONS then
                limitError("too many instructions in " .. info.source:sub(2))
            end
        end
        if gccount() - phaseMemory > script.MAX_MEMORY_KB then
            limitError("too much memory")
        end
    end
end

local function isLimitError(err)
    return type(err) == "string" and err:find(script.LIMIT_ERROR, 1, true) ~= nil
end

-- True while script code may be running (a guarded call), for the string
-- function limits below.
function script.inScript()
    return depth > 0
end

-- ── Guarded calls ─────────────────────────────────────────────────────────
-- Wrap fn so every call runs under the limits. A call that errors (or blows a
-- limit) disables `owner` (the script's type or hook table): later calls return
-- nil without running. `owner.scriptError` keeps the message.
function script.guard(fn, owner, label)
    return function(...)
        if owner.scriptDisabled then
            return nil
        end
        local outermost = depth == 0
        if outermost then
            callFires, callMemory = 0, gccount()
            sethook(limitHook, "", script.HOOK_EVERY)
        end
        depth = depth + 1
        local results = { rawPcall(fn, ...) }
        depth = depth - 1
        if outermost then
            if phaseActive then
                sethook(limitHook, "", script.PHASE_HOOK_EVERY)
            else
                sethook()
            end
        end
        if not results[1] then
            rawset(owner, "scriptDisabled", true)
            rawset(owner, "scriptError", tostring(results[2]))
            if depth > 0 then
                rawError(results[2], 0) -- let the outermost call stop too
            end
            print(("script disabled: %s: %s"):format(label or "?", tostring(results[2])))
            return nil
        end
        return rawUnpack(results, 2, table.maxn(results))
    end
end

-- Guard every function stored directly in `t` (a type or hooks table).
function script.guardFunctions(t, label)
    for key, value in pairs(t) do
        if type(value) == "function" then
            rawset(t, key, script.guard(value, t, label .. "." .. tostring(key)))
        end
    end
    return t
end

-- Run fn(...) as one engine phase with limits on any script code inside it.
-- Returns true plus fn's results, or false and an error message (with a
-- traceback for engine errors). Nested calls just run fn.
function script.protect(fn, ...)
    local args, count = { ... }, select("#", ...)
    local function run()
        return fn(rawUnpack(args, 1, count))
    end
    if phaseActive then
        return rawPcall(run)
    end
    phaseActive = true
    phaseFires, phaseMemory = 0, gccount()
    sethook(limitHook, "", script.PHASE_HOOK_EVERY)
    local results = { rawXpcall(run, function(err)
        if isLimitError(err) then
            return err
        end
        return traceback(tostring(err), 2)
    end) }
    sethook()
    phaseActive = false
    return rawUnpack(results, 1, table.maxn(results))
end

-- ── String and table limits ───────────────────────────────────────────────
-- Built-in C functions run as one step, so the hook cannot stop them: a huge
-- string.rep, or a pattern that backtracks for minutes, would freeze the game.
-- These limits live in the global string/table libraries, so they also apply
-- to method calls like ("x"):rep(n) (a string's methods are the global string
-- library). Size caps apply everywhere (the engine never needs 16 MB strings);
-- pattern limits apply only while script code runs.
local stringRep, stringGsub, stringFind = string.rep, string.gsub, string.find
local stringMatch, stringGmatch, tableConcat = string.match, string.gmatch, table.concat

local function tooLarge(name)
    rawError(name .. ": result too large", 3)
end

-- Count the quantifiers in a Lua pattern, skipping escapes and [sets].
local function patternRepeats(pattern)
    local count, i, n = 0, 1, #pattern
    while i <= n do
        local c = pattern:sub(i, i)
        if c == "%" then
            i = i + 2
        elseif c == "[" then
            i = i + 1
            if pattern:sub(i, i) == "^" then i = i + 1 end
            if pattern:sub(i, i) == "]" then i = i + 1 end
            while i <= n and pattern:sub(i, i) ~= "]" do
                if pattern:sub(i, i) == "%" then i = i + 1 end
                i = i + 1
            end
            i = i + 1
        else
            if c == "*" or c == "+" or c == "-" or c == "?" then
                count = count + 1
            end
            i = i + 1
        end
    end
    return count
end

local function checkPattern(name, subject, pattern, plain)
    if depth == 0 or plain then
        return
    end
    if type(subject) == "string" and #subject > script.MAX_PATTERN_SUBJECT then
        rawError(name .. ": string too long to search", 3)
    end
    if type(pattern) == "string" and patternRepeats(pattern) > script.MAX_PATTERN_REPEATS then
        rawError(name .. ": pattern too complex", 3)
    end
end

string.rep = function(s, n, sep)
    if type(n) == "number" and n > 0 then
        local size = #tostring(s) * n + (sep and #tostring(sep) * (n - 1) or 0)
        if size > script.MAX_STRING then tooLarge("string.rep") end
    end
    return stringRep(s, n, sep)
end

string.find = function(s, pattern, init, plain)
    checkPattern("string.find", s, pattern, plain)
    return stringFind(s, pattern, init, plain)
end

string.match = function(s, pattern, init)
    checkPattern("string.match", s, pattern)
    return stringMatch(s, pattern, init)
end

string.gmatch = function(s, pattern)
    checkPattern("string.gmatch", s, pattern)
    return stringGmatch(s, pattern)
end

string.gsub = function(s, pattern, repl, n)
    checkPattern("string.gsub", s, pattern)
    if type(s) == "string" and type(repl) == "string" then
        -- Upper bound: every position (and the end) replaced once.
        if #s + (#s + 1) * #repl > script.MAX_STRING then tooLarge("string.gsub") end
    end
    return stringGsub(s, pattern, repl, n)
end

table.concat = function(list, sep, i, j)
    if depth > 0 and type(list) == "table" then
        local size, first, last = 0, i or 1, j or #list
        for k = first, last do
            local value = list[k]
            size = size + ((type(value) == "string" or type(value) == "number") and #tostring(value) or 0)
        end
        size = size + (sep and #tostring(sep) * math.max(0, last - first) or 0)
        if size > script.MAX_STRING then tooLarge("table.concat") end
    end
    return tableConcat(list, sep, i, j)
end

-- ── Environment ───────────────────────────────────────────────────────────
local function copy(t, except)
    local out = {}
    for key, value in pairs(t) do
        if not (except and except[key]) then
            out[key] = value
        end
    end
    return out
end

local function newEnvironment(injected)
    local env = {
        math = copy(math, { random = true, randomseed = true }),
        string = copy(string, { dump = true }),
        table = copy(table),
    }
    for _, name in ipairs(SAFE_GLOBALS) do
        env[name] = _G[name]
    end
    -- Only tables' metatables: a string's metatable is the engine's string
    -- library, and engine classes protect theirs with __metatable.
    env.getmetatable = function(value)
        if type(value) == "table" then
            return getmetatable(value)
        end
        return nil
    end
    -- pcall may not swallow a limit error, or a runaway loop could catch it
    -- and keep going.
    env.pcall = function(fn, ...)
        local results = { rawPcall(fn, ...) }
        if not results[1] and isLimitError(results[2]) then
            rawError(results[2], 0)
        end
        return rawUnpack(results, 1, table.maxn(results))
    end
    for name, value in pairs(injected or {}) do
        env[name] = value
    end
    return env
end

-- Run script source text in a fresh sandbox and return what it returns.
-- `chunkName` names it in error messages. Running the chunk itself is guarded
-- too, but errors there are raised: a script that cannot load fails the load.
function script.run(source, chunkName, injected)
    if type(source) ~= "string" then
        rawError("script source must be text: " .. tostring(chunkName), 0)
    end
    if source:byte(1) == 27 then -- Lua and LuaJIT bytecode start with ESC
        rawError("bytecode rejected: " .. tostring(chunkName), 0)
    end
    local chunk, err = loadstring(source, "@" .. tostring(chunkName))
    if not chunk then
        rawError(err, 0)
    end
    scriptSources["@" .. tostring(chunkName)] = true
    -- LuaJIT skips count hooks in compiled code, so scripts run interpreted
    -- (this covers every function defined inside the chunk).
    if jit then
        jit.off(chunk, true)
    end
    setfenv(chunk, newEnvironment(injected))
    local status = {}
    local result = script.guard(chunk, status, chunkName)()
    if status.scriptDisabled then
        rawError(status.scriptError, 0)
    end
    return result
end

-- Load and run the script at `path` (love.filesystem).
function script.load(path, injected)
    local source = love.filesystem.read(path)
    if not source then
        rawError("script not found: " .. path, 0)
    end
    return script.run(source, path, injected)
end

return script
