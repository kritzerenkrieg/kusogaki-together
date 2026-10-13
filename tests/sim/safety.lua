-- Misbehaving levels: script faults stop the level, the reachability audit,
-- and the watchdog.
local Level = require("core.level")
local playerModule = require("core.player")
local present = require("core.graphics.present")
local helpers = require("tests.sim.helpers")
local check = helpers.check
local stub = helpers.stub
local inputAt = helpers.inputAt
local topdownInput = helpers.topdownInput
local run = helpers.run

-- ── A misbehaving script stops its level, not the game ───────────────────
do
    local script = require("core.script")
    -- Script-made functions, as a level script could create and store them.
    local evil = script.run([[
        return {
            spin = function() while true do end end,
            trap = setmetatable({}, { __index = function() while true do end end }),
        }
    ]], "levels/example/scripts/evil_test.lua")

    local level = Level.load("example")
    level:addPlayer(playerModule.new(level.spawn.x, level.spawn.y))
    level.props[1].update = evil.spin -- stored on an entity: no guard around it
    local started = os.clock()
    local ok = level:update(1 / 60)
    check("a runaway stored function faults the level", not ok and tostring(level.faulted):find("instructions"),
        level.faulted)
    check("... quickly", os.clock() - started < 5, os.clock() - started)
    check("a faulted level stops updating", level:update(1 / 60) == false)

    local level2 = Level.load("example")
    level2:addPlayer(playerModule.new(level2.spawn.x, level2.spawn.y))
    level2:update(1 / 60)
    level2:takeEvents()
    table.insert(level2.events, { type = "explosion", x = 0, y = 0, w = 1, h = 1, entity = evil.trap })
    table.insert(level2.events, { type = "sfx", name = "../../../conf.lua" })
    level2:protect(present.all, level2:takeEvents(), level2)
    check("a fake event with a runaway entity faults the level",
        tostring(level2.faulted):find("instructions"), level2.faulted)

    local level3 = Level.load("example")
    level3:addPlayer(playerModule.new(level3.spawn.x, level3.spawn.y))
    table.insert(level3.events, { type = "sfx", name = "../../../conf.lua" })
    level3:protect(present.all, level3:takeEvents(), level3)
    check("an sfx event with a bad name is ignored", not level3.faulted, level3.faulted)
end

-- ── What scripts can reach ────────────────────────────────────────────────
-- Walks everything a script could get to from what it is given (its entities,
-- the level, players, the injected Entity/Prop views, ui), the way a script
-- could: table fields, metatables it may read, and lookups through protected
-- metatables. Fails on engine modules, dangerous built-ins and functions from
-- modules scripts must never reach.
for _, case in ipairs({ { "example", inputAt }, { "topdown", topdownInput } }) do
    local script = require("core.script")
    local loader = require("core.level.loader")
    local level = Level.load(case[1])
    level:addPlayer(playerModule.new(level.spawn.x, level.spawn.y))
    for tick = 1, 300 do
        level.players[1].input = case[2](tick, 1)
        level:update(1 / 60)
        level:takeEvents()
    end
    local checkAll = check
    local function check(name, ...) -- names say which level failed
        return checkAll(case[1] .. ": " .. name, ...)
    end

    local stubMeta = getmetatable(stub)
    local obtainable, functions, seen = {}, {}, {}
    local walk

    local function walkThrough(t) -- values readable through a protected __index
        if seen[t] then return end
        seen[t] = true
        for key, value in pairs(t) do
            walk(key)
            walk(value)
        end
        local mt = debug.getmetatable(t)
        if type(mt) == "table" and type(rawget(mt, "__index")) == "table" then
            walkThrough(rawget(mt, "__index"))
        end
    end

    walk = function(value)
        local kind = type(value)
        if kind == "function" then
            functions[value] = true
        elseif kind == "table" then
            if obtainable[value] or debug.getmetatable(value) == stubMeta then return end
            obtainable[value] = true
            local target = script.viewTarget(value)
            if target then -- a read-only view: its contents, never the real table
                for _, source in ipairs({ target.overrides or {}, target.real }) do
                    for key, inner in pairs(source) do
                        walk(key)
                        if type(inner) == "table" then
                            walk(script.readonly(inner))
                        else
                            walk(inner)
                        end
                    end
                end
                return
            end
            for key, inner in pairs(value) do
                walk(key)
                walk(inner)
            end
            local mt = debug.getmetatable(value) -- the real one, even when protected
            if mt ~= nil then
                if rawget(mt, "__metatable") == nil then
                    walk(mt)
                else
                    for _, field in ipairs({ "__index", "__newindex", "__call" }) do
                        local handler = rawget(mt, field)
                        if type(handler) == "table" then walkThrough(handler) else walk(handler) end
                    end
                end
            end
        end
    end

    local injected = {
        script.readonly(require("core.level.entity")),
        script.readonly(require("core.level.prop")),
        script.readonly(require("core.level.ui")),
    }
    walk(level)
    for _, view in ipairs(injected) do walk(view) end

    -- 1. No engine module, global or library table can be obtained.
    local forbiddenTables = { [_G] = "_G", [love] = "love", [package] = "package", [debug] = "debug",
        [os] = "os", [io] = "io", [string] = "string", [math] = "math", [table] = "table" }
    for name, module in pairs(package.loaded) do
        if type(module) == "table" and not forbiddenTables[module] then
            forbiddenTables[module] = "module " .. name
        end
    end
    -- Engine classes outside package.loaded too: any table a script can obtain
    -- that holds engine functions (other than sandbox wrappers) is a class or
    -- module it could change for everyone.
    local function engineFunctionIn(t)
        for key, inner in pairs(t) do
            if type(inner) == "function" then
                local info = debug.getinfo(inner, "S")
                local file = info.source:gsub("^@", "")
                if info.what ~= "C" and not file:match("^levels/") and file ~= "core/script.lua" then
                    return tostring(key) .. " from " .. file
                end
            end
        end
    end
    -- The level's stage entries hold engine rule functions on purpose: they
    -- are this level's own tables (scripts reorder and replace them), and
    -- the shared-data check below makes sure no other level sees them.
    local levelOwned = {}
    for _, stage in ipairs(level.stages) do
        levelOwned[stage] = true
    end
    local leaked = {}
    for t in pairs(obtainable) do
        if forbiddenTables[t] then
            leaked[#leaked + 1] = forbiddenTables[t]
        elseif not script.viewTarget(t) and not levelOwned[t] then
            local found = engineFunctionIn(t)
            if found then leaked[#leaked + 1] = "a table with " .. found end
        end
    end
    table.sort(leaked)
    check("scripts cannot obtain engine modules or libraries", #leaked == 0, table.concat(leaked, ", "))

    -- Engine data shared across levels (reachable from any loaded module):
    -- a script that could change it would change later levels too.
    local shared, sharedSeen = {}, {}
    local function collect(t, path)
        if sharedSeen[t] then return end
        sharedSeen[t] = true
        shared[t] = path
        for key, inner in pairs(t) do
            if type(inner) == "table" then collect(inner, path .. "." .. tostring(key)) end
        end
        local mt = debug.getmetatable(t)
        if type(mt) == "table" then collect(mt, path .. "<meta>") end
    end
    for name, module in pairs(package.loaded) do
        if type(module) == "table" and not name:match("^levels") then collect(module, name) end
    end
    local sharedLeaks = {}
    for t in pairs(obtainable) do
        if shared[t] and not script.viewTarget(t) and not forbiddenTables[t] then
            sharedLeaks[#sharedLeaks + 1] = shared[t]
        end
    end
    table.sort(sharedLeaks)
    check("scripts cannot obtain engine data shared across levels", #sharedLeaks == 0,
        table.concat(sharedLeaks, ", "))

    -- 2. Built-in (C) functions: only the safe library functions.
    local safeC = {}
    for _, lib in ipairs({ math, string, table }) do
        for _, fn in pairs(lib) do safeC[fn] = true end
    end
    for _, name in ipairs({ "assert", "error", "ipairs", "next", "pairs", "rawequal", "rawget", "rawset",
        "select", "setmetatable", "tonumber", "tostring", "type", "unpack", "getmetatable", "pcall" }) do
        safeC[_G[name]] = true
    end
    local unsafeC = {}
    -- 3. Lua functions: only from modules meant to be reachable.
    local ALLOWED_SOURCES = {
        ["core/level/entity.lua"] = true, ["core/level/prop.lua"] = true, ["core/level/init.lua"] = true,
        ["core/level/ui.lua"] = true, ["core/level/loader.lua"] = true, ["core/level/stages.lua"] = true, ["core/mathx.lua"] = true,
        ["core/script.lua"] = true, ["core/player/init.lua"] = true, ["core/player/view.lua"] = true,
        ["core/player/state.lua"] = true, ["core/player/controller.lua"] = true, ["core/player/carry.lua"] = true,
    }
    local sources, badSources = {}, {}
    for fn in pairs(functions) do
        local info = debug.getinfo(fn, "S")
        if info.what == "C" then
            if not safeC[fn] then unsafeC[#unsafeC + 1] = tostring(fn) end
        else
            local file = info.source:gsub("^@", "")
            if not file:match("^levels/") then
                sources[file] = true
                if not ALLOWED_SOURCES[file] then badSources[#badSources + 1] = file end
            end
        end
    end
    check("reachable built-ins are only safe library functions", #unsafeC == 0, table.concat(unsafeC, ", "))
    table.sort(badSources)
    check("reachable engine functions come only from allowed modules", #badSources == 0,
        table.concat(badSources, ", "))
    local list = {}
    for file in pairs(sources) do list[#list + 1] = file end
    table.sort(list)
    print("      reachable engine code: " .. table.concat(list, ", "))
    local count = 0
    for _ in pairs(functions) do count = count + 1 end
    print(("      %d functions, %d tables reachable from scripts"):format(count, (function()
        local n = 0 for _ in pairs(obtainable) do n = n + 1 end return n end)()))
end

-- ── Watchdog: a frozen level ends the game and is blocked next time ──────
do
    local watchdog = require("core.watchdog")
    local levelpack = require("core.levelpack")
    watchdog.REPORT_FILE = "test_watchdog_report.json"
    watchdog.BLOCK_FILE = "test_blocked_levels.json"
    love.filesystem.remove(watchdog.REPORT_FILE)
    love.filesystem.remove(watchdog.BLOCK_FILE)
    local out = love.thread.getChannel("watchdog_out")
    out:clear()
    watchdog.start({ timeout = 0.3, exitOnFreeze = false })
    local hash = string.rep("ab", 32)
    local root = "online/" .. hash

    -- Wait `seconds`, beating every 50 ms when `beating`.
    local function wait(seconds, beating)
        local stop = love.timer.getTime() + seconds
        while love.timer.getTime() < stop do
            if beating then watchdog.beat() end
            love.timer.sleep(0.05)
        end
    end

    watchdog.enter(root)
    wait(0.8, true)
    check("a running level that keeps beating is left alone", out:getCount() == 0, watchdog.error())
    watchdog.leave()
    wait(0.8, false)
    check("no level running: a pause is not a freeze", out:getCount() == 0)
    watchdog.enter(root)
    wait(0.9, false)
    check("a frozen level is reported", out:pop() == "fired:" .. root, watchdog.error())
    check("... in the save directory", love.filesystem.getInfo(watchdog.REPORT_FILE) ~= nil)

    local report = watchdog.readReport() -- what the next launch does
    check("the next launch reads the report", report and report.root == root and report.blocked == true)
    check("... and blocks the downloaded level", watchdog.isBlocked(hash))
    check("the report is read only once", watchdog.readReport() == nil)
    local ok, err = pcall(Level.load, root)
    check("a blocked level is refused by the loader", not ok and tostring(err):find("blocked"), err)
    local mounted, mountErr = levelpack.mount("anything.zip", hash)
    check("a blocked package is refused before mounting", mounted == nil and tostring(mountErr):find("blocked"),
        mountErr)

    watchdog.enter("levels/example")
    wait(0.9, false)
    out:pop()
    local localReport = watchdog.readReport()
    check("a frozen bundled level is reported but not blocked", localReport and localReport.root == "levels/example"
        and not localReport.blocked)
    watchdog.stop()
    love.filesystem.remove(watchdog.REPORT_FILE)
    love.filesystem.remove(watchdog.BLOCK_FILE)
end
