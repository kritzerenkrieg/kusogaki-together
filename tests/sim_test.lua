-- Headless simulation checks on a real level: the fixed timestep and
-- determinism (same inputs -> same state). Needs LÖVE for the filesystem and
-- image decoding, but no window. Run from the project root:
--   love2d . --sim-test
-- Graphics and audio are disabled (conf.lua), so they are stubbed below.

local failures = 0
local function check(name, condition, detail)
    if condition then
        print("ok    " .. name)
    else
        failures = failures + 1
        print("FAIL  " .. name .. (detail and (" (" .. detail .. ")") or ""))
    end
end

-- ── Stubs: anything called on them does nothing and returns another stub ──
local stub
stub = setmetatable({}, {
    __index = function()
        return function()
            return stub
        end
    end,
})

local function stubImage(path)
    local data = love.image.newImageData(path) -- real size, for frame slicing
    local w, h = data:getDimensions()
    return setmetatable({
        getDimensions = function() return w, h end,
        getWidth = function() return w end,
        getHeight = function() return h end,
    }, getmetatable(stub))
end

local stubFont = setmetatable({ getWidth = function() return 0 end }, getmetatable(stub))
love.graphics = setmetatable({
    newImage = stubImage,
    newFont = function() return stubFont end,
}, getmetatable(stub))
love.audio = stub

local fixedstep = require("core.fixedstep")
local Level = require("core.level")
local playerModule = require("core.player")
local fx = require("core.graphics.fx")
local present = require("core.graphics.present")
local netstate = require("core.level.netstate")

playerModule.load()

-- ── fixedstep on its own ──────────────────────────────────────────────────
do
    local clock = fixedstep.new(1 / 60, 5)
    local ticks = 0
    local alpha = clock:advance(1 / 120, function() ticks = ticks + 1 end)
    check("half a step runs no tick", ticks == 0 and math.abs(alpha - 0.5) < 1e-9, ticks .. " " .. alpha)
    clock:advance(1 / 120, function() ticks = ticks + 1 end)
    check("two half steps run one tick", ticks == 1, tostring(ticks))
    ticks = 0
    alpha = clock:advance(1, function() ticks = ticks + 1 end)
    check("a 1 s hitch runs maxSteps and drops the rest", ticks == 5 and alpha == 0, ticks .. " " .. alpha)
end

-- ── Scripted input frames, by tick: a deterministic run through the level ──
-- Each player gets the same pattern, shifted in time, so they spread out,
-- bump into each other and stand on heads.
local function inputAt(tick, playerIndex)
    local t = tick + (playerIndex - 1) * 23
    return {
        right = (t % 400) < 330,                   -- mostly walk right
        left = (t % 400) >= 360,                   -- and back a little
        jump = (t % 47) < 14,                      -- hop, held for a varied height
        kick = (t % 90) == 30,
        hold = (t % 160) >= 80 and (t % 160) < 140,
    }
end

local function fmt(value)
    if type(value) == "number" then
        return string.format("%.17g", value)
    end
    return tostring(value)
end

local ENTITY_LISTS = { "hazards", "blocks", "enemies", "props", "triggers" }

-- Problems with entity ids: byId must hold exactly the entities still in the
-- lists, and everything that left must be marked removed. Returns a list of
-- messages (empty when fine).
local function idProblems(level, everyEntity)
    local problems = {}
    local listed = {}
    for _, listName in ipairs(ENTITY_LISTS) do
        for _, entity in ipairs(level[listName]) do
            if listed[entity.id] then
                problems[#problems + 1] = "duplicate id " .. tostring(entity.id)
            end
            listed[entity.id] = true
            if level:get(entity.id) ~= entity then
                problems[#problems + 1] = "listed entity missing from byId: " .. tostring(entity.id)
            end
        end
    end
    for id, entity in pairs(everyEntity) do
        if listed[id] then
            if entity.removed then
                problems[#problems + 1] = "listed entity marked removed: " .. id
            end
        elseif not entity.removed or level:get(id) ~= nil then
            problems[#problems + 1] = "entity left the lists but is not cleanly removed: " .. id
        end
    end
    return problems
end

local PLAYER_FIELDS = { "id", "x", "y", "vx", "vy", "facing", "onGround", "jumping", "dead", "kickTime" }
local BODY_FIELDS = { "id", "name", "x", "y", "vx", "vy", "onGround", "held", "awake", "detonated" }

-- Everything the simulation decides, as one string.
local function stateString(level)
    local parts = {}
    for _, player in ipairs(level.players) do
        for _, field in ipairs(PLAYER_FIELDS) do
            parts[#parts + 1] = fmt(player[field])
        end
        parts[#parts + 1] = player.carrying and player.carrying.name or "-"
    end
    for _, listName in ipairs({ "enemies", "props", "blocks", "hazards", "triggers", "statics" }) do
        local list = level[listName]
        parts[#parts + 1] = listName .. "#" .. #list
        if listName ~= "statics" then
            for _, body in ipairs(list) do
                for _, field in ipairs(BODY_FIELDS) do
                    parts[#parts + 1] = fmt(body[field])
                end
            end
        end
    end
    return table.concat(parts, ",")
end

-- Deterministic text form of plain data (keys sorted). Fails on anything that
-- is not plain: functions, userdata, or tables used as values where only
-- lists/records of plain values are allowed.
local function plain(value, path)
    local kind = type(value)
    if kind == "number" then
        return string.format("%.17g", value)
    elseif kind == "string" or kind == "boolean" or kind == "nil" then
        return tostring(value)
    elseif kind == "table" then
        local keys = {}
        for key in pairs(value) do
            keys[#keys + 1] = key
        end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local parts = {}
        for _, key in ipairs(keys) do
            parts[#parts + 1] = tostring(key) .. "=" .. plain(value[key], path .. "." .. tostring(key))
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    error("not plain data at " .. path .. " (" .. kind .. ")", 0)
end

-- Run `ticks` simulation ticks with `playerCount` players, feeding frames of
-- the given lengths (cycled) through the fixed-step clock, as the game loop does.
local function run(ticks, frameDeltas, playerCount, root)
    local level = Level.load(root or "example")
    fx.clearEffects()
    for _ = 1, playerCount or 1 do
        level:addPlayer(playerModule.new(level.spawn.x, level.spawn.y))
    end

    local everyEntity = {}
    for id, entity in pairs(level.byId) do
        everyEntity[id] = entity
    end

    local clock = fixedstep.new(1 / 60, 1000)
    local stats = { maxX = 0, deaths = 0, enemiesStart = #level.enemies, headStands = 0, eventTypes = {} }
    local eventLog = {}
    local frame = 0
    while clock.tick < ticks do
        frame = frame + 1
        local delta = frameDeltas[(frame - 1) % #frameDeltas + 1]
        clock:advance(delta, function(step, tick)
            if tick > ticks then
                return
            end
            local wasDead = {}
            for i, player in ipairs(level.players) do
                player.input = inputAt(tick, i)
                wasDead[i] = player.dead
            end
            level:update(step)
            local list = level:takeEvents()
            present.all(list, level)
            for _, event in ipairs(list) do
                eventLog[#eventLog + 1] = tick .. ":" .. plain(netstate.event(event), "event")
                stats.eventTypes[event.type] = (stats.eventTypes[event.type] or 0) + 1
            end
            fx.update(step)
            for i, player in ipairs(level.players) do
                stats.maxX = math.max(stats.maxX, player.x)
                if player.dead and not wasDead[i] then
                    stats.deaths = stats.deaths + 1
                end
                for _, other in ipairs(level.players) do
                    if other ~= player and not player.dead and not other.dead and player.onGround
                        and math.abs(player.x - other.x) < player.w
                        and math.abs((player.y + player.h / 2) - (other.y - other.h / 2)) < 0.5 then
                        stats.headStands = stats.headStands + 1
                    end
                end
            end
        end)
    end
    stats.enemiesLeft = #level.enemies
    stats.idProblems = idProblems(level, everyEntity)
    local removed = 0
    for _, entity in pairs(everyEntity) do
        if entity.removed then removed = removed + 1 end
    end
    stats.removed = removed
    local snapshot = plain(netstate.snapshot(level, ticks), "snapshot")
    stats.snapshotBytes = #snapshot
    return stateString(level) .. "|" .. snapshot .. "|" .. table.concat(eventLog, ";"), stats
end

-- ── Entity ids at load ────────────────────────────────────────────────────
do
    local json = require("core.json")
    local placements = json.decode(love.filesystem.read("levels/example/level.json")).entities
    local a, b = Level.load("example"), Level.load("example")
    local sameIds, matchTypes = true, true
    for index = 1, #placements do
        local entityA, entityB = a:get(index), b:get(index)
        if not entityA or not entityB or entityA.name ~= entityB.name or entityA.x ~= entityB.x
            or entityA.y ~= entityB.y then
            sameIds = false
        end
        if not entityA or entityA.x ~= placements[index].x then
            matchTypes = false
        end
    end
    check("every placement gets its index as id", matchTypes and a:get(#placements + 1) == nil)
    check("ids are the same on every load", sameIds)
    check("ids are consistent at load", #idProblems(a, a.byId) == 0)
end

local TICKS = 60 * 40 -- 40 s of play
local EVEN = { 1 / 60 }
local UNEVEN = { 1 / 144, 1 / 30, 0.004, 1 / 90, 0.05, 1 / 60, 0.021 }

local function showDifference(a, b)
    for i = 1, math.max(#a, #b) do
        if a:sub(i, i) ~= b:sub(i, i) then
            print("      first difference near: " .. a:sub(math.max(1, i - 60), i + 60))
            print("                       vs: " .. b:sub(math.max(1, i - 60), i + 60))
            return
        end
    end
end

for _, playerCount in ipairs({ 1, 3, 5 }) do
    local label = playerCount .. (playerCount == 1 and " player" or " players")
    local started = os.clock()
    local first, stats = run(TICKS, EVEN, playerCount)
    local msPerTick = (os.clock() - started) * 1000 / TICKS
    local second = run(TICKS, EVEN, playerCount)
    local uneven = run(TICKS, UNEVEN, playerCount)
    print(string.format("      %s: furthest x %.0f, deaths %d, enemies %d -> %d, head stands %d, %.3f ms/tick",
        label, stats.maxX, stats.deaths, stats.enemiesStart, stats.enemiesLeft, stats.headStands, msPerTick))
    check(label .. ": the scripted run gets somewhere", stats.maxX > 600, string.format("%.0f", stats.maxX))
    check(label .. ": same inputs, same state (two runs)", first == second)
    check(label .. ": frame timing does not change the simulation", first == uneven)
    if playerCount > 1 then
        check(label .. ": players stand on each other", stats.headStands > 0)
    end
    local types = {}
    for name, count in pairs(stats.eventTypes) do
        types[#types + 1] = name .. " " .. count
    end
    table.sort(types)
    print("      events: " .. table.concat(types, ", ") .. string.format("; final snapshot ~%d bytes as text", stats.snapshotBytes))
    check(label .. ": every removal is reported", stats.eventTypes.removed == stats.removed)
    check(label .. ": players report events", (stats.eventTypes.player or 0) > 0)
    check(label .. ": ids stay consistent (" .. stats.removed .. " entities removed)",
        #stats.idProblems == 0 and stats.removed > 0, table.concat(stats.idProblems, "; "))
    if first ~= second then showDifference(first, second) end
    if first ~= uneven then showDifference(first, uneven) end
end

-- ── Wire format: snapshots and events survive encoding exactly ──────────
do
    local wire = require("core.wire")
    local level = Level.load("example")
    level:addPlayer(playerModule.new(level.spawn.x, level.spawn.y))
    level:addPlayer(playerModule.new(level.spawn.x + 20, level.spawn.y))
    local list = {}
    for tick = 1, 600 do
        for i, player in ipairs(level.players) do
            player.input = inputAt(tick, i)
        end
        level:update(1 / 60)
        for _, event in ipairs(level:takeEvents()) do
            list[#list + 1] = netstate.event(event)
        end
    end
    local snapshot = netstate.snapshot(level, 600)
    local extrasFor = function(id) return level:get(id) and level:get(id).netFields end
    -- nil and false both mean "not set" on the wire (changes s in place)
    local function settled(s)
        for _, list in ipairs({ s.players, s.entities }) do
            for _, record in ipairs(list) do
                for key, value in pairs(record) do
                    if value == false then record[key] = nil end
                end
            end
        end
        return plain(s, "s")
    end
    local generic = wire.encode(snapshot)
    check("generic data survives the wire format", plain(wire.decode(generic), "g") == plain(snapshot, "g"))
    local bytes = wire.encode(netstate.pack(snapshot, extrasFor))
    local decoded = wire.decode(bytes)
    check("a snapshot survives packing and the wire format",
        decoded and settled(netstate.unpack(decoded, extrasFor)) == settled(snapshot))
    check("the same snapshot encodes to the same bytes",
        wire.encode(netstate.pack(netstate.unpack(decoded, extrasFor), extrasFor)) == bytes)
    check("packed snapshots are smaller than generic ones", #bytes < #generic / 2,
        #bytes .. " vs " .. #generic)
    local eventBytes = wire.encode(list)
    check("events survive the wire format", plain(wire.decode(eventBytes), "e") == plain(list, "e"))
    print(string.format("      wire: snapshot %d bytes packed (%d generic; %d entities, %d players), %d events %d bytes",
        #bytes, #generic, #snapshot.entities, #snapshot.players, #list, #eventBytes))

    local truncated = bytes:sub(1, #bytes - 3)
    check("truncated data is rejected", wire.decode(truncated) == nil)
    check("trailing data is rejected", wire.decode(bytes .. "\0") == nil)
    check("an unknown tag is rejected", wire.decode("\9") == nil)
    check("a huge declared length is rejected", wire.decode("\6\255\255\255\127") == nil)
    local deep = string.rep("\7\1\0\0\0\3\1", wire.MAX_DEPTH + 1) .. "\0"
    check("deep nesting is rejected", wire.decode(deep) == nil)
    local _, err = wire.decode(123)
    check("non-strings are rejected", err ~= nil)
end

-- ── Asset paths a script may load ────────────────────────────────────────
do
    local loader = require("core.level.loader")
    local IMAGES = { png = true, jpg = true, jpeg = true }
    local function resolves(path)
        local ok, result = pcall(loader.resolveAsset, "levels/example", path, IMAGES)
        return ok and result
    end
    check("package assets resolve inside the package", resolves("assets/box.png") == "levels/example/assets/box.png")
    check("shared engine graphics resolve", resolves("assets/graphics/entities/spike.png") == "assets/graphics/entities/spike.png")
    check("parent paths are refused", not resolves("../example/assets/box.png") and not resolves("assets/../level.json"))
    check("absolute paths are refused", not resolves("/etc/passwd"))
    check("other file types are refused", not resolves("entities/box.lua"))
    check("missing assets are refused", not resolves("assets/nope.png"))
    check("engine files outside shared graphics are refused", not resolves("assets/audio/sfx/hit.png"))
    check("bundled names and roots map to roots", loader.rootFor("example") == "levels/example"
        and loader.rootFor("online/" .. string.rep("a", 64)) == "online/" .. string.rep("a", 64)
        and not pcall(loader.rootFor, "levels/../x") and not pcall(loader.rootFor, "../x"))
end

-- ── Seeded level random ──────────────────────────────────────────────────
do
    local a, b = Level.load("example", { seed = 7 }), Level.load("example", { seed = 7 })
    local c = Level.load("example", { seed = 8 })
    local x, y, z = a.random:random(), b.random:random(), c.random:random()
    check("a level's random follows its seed", x == y and x ~= z)
end

-- ── Downloaded packages: a zipped copy of the example level ──────────────
do
    local levelpack = require("core.levelpack")
    local zipName = "test_example_pack.zip"
    local zipPath = love.filesystem.getSaveDirectory() .. "/" .. zipName
    love.filesystem.createDirectory("") -- make sure the save directory exists
    local made = os.execute(("python3 -c %q %q %q"):format(
        "import os,sys,zipfile; "
            .. "src,dst=sys.argv[1],sys.argv[2]; "
            .. "z=zipfile.ZipFile(dst,'w'); "
            .. "[z.write(os.path.join(d,f),os.path.relpath(os.path.join(d,f),src)) for d,_,fs in os.walk(src) for f in fs]; "
            .. "z.close()",
        love.filesystem.getSource() .. "/levels/example", zipPath))
    if made ~= 0 and made ~= true then
        print("skip  packaged level checks (python3 is needed to build the test zip)")
    else
        local hash = levelpack.hashFile(zipName)
        local root, err = levelpack.mount(zipName, string.rep("0", 64))
        check("a package with the wrong hash is refused", root == nil and tostring(err):find("mismatch"), err)
        root, err = levelpack.mount(zipName, hash)
        check("a package mounts at online/<sha256>", root == "online/" .. hash, err)
        if root then
            check("a package does not shadow bundled levels", not love.filesystem.getInfo("levels/" .. hash))
            local bundled = run(600, EVEN, 2)
            local packaged = run(600, EVEN, 2, root)
            check("the packaged level plays exactly like the bundled one", bundled == packaged)
            levelpack.unmount(hash)
            check("unmounting removes the package", not love.filesystem.getInfo(root .. "/level.json"))
        end
        love.filesystem.remove(zipName)
    end
end

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
do
    local script = require("core.script")
    local loader = require("core.level.loader")
    local level = Level.load("example")
    level:addPlayer(playerModule.new(level.spawn.x, level.spawn.y))
    for tick = 1, 300 do
        level.players[1].input = inputAt(tick, 1)
        level:update(1 / 60)
        level:takeEvents()
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
    local leaked = {}
    for t in pairs(obtainable) do
        if forbiddenTables[t] then
            leaked[#leaked + 1] = forbiddenTables[t]
        elseif not script.viewTarget(t) then
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
        ["core/level/ui.lua"] = true, ["core/level/loader.lua"] = true, ["core/mathx.lua"] = true,
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

-- ── The gameplay scene: fixed-step update + interpolated draw ────────────
do
    local gameplay = require("scenes.gameplay")
    local walkRight = { read = function() return { right = true } end }
    gameplay.load()
    gameplay.setSource(1, walkRight)
    local second = gameplay.join({ kind = "test", read = function() return { right = true, jump = true } end })
    local again = gameplay.join({ kind = "test", read = walkRight.read })
    check("a device joins once", second ~= nil and again == nil)
    local player = gameplay.getPlayer(1)
    local ok, err = pcall(function()
        for frame = 1, 240 do
            gameplay.update(UNEVEN[(frame - 1) % #UNEVEN + 1])
            local x, y = player.x, player.y
            gameplay.draw()
            assert(player.x == x and player.y == y, "draw left the player at its blended position")
        end
    end)
    check("gameplay scene updates and draws", ok, tostring(err))
    check("gameplay scene moves both players", player.x > 100 and second.x > 100,
        string.format("%.0f %.0f", player.x, second.x))
    check("joined player gets id 2", second.id == 2)

    local level = gameplay.getLevel()
    level:fault("test: a script stopped the level")
    local drawn = pcall(gameplay.draw)
    check("a stopped level draws its message instead of crashing", drawn)
    gameplay.keypressed("r")
    check("restarting a stopped level gives a working level", not gameplay.getLevel().faulted
        and gameplay.getLevel() ~= level)
end

print(failures == 0 and "all sim checks passed" or (failures .. " sim check(s) failed"))
love.event.quit(failures == 0 and 0 or 1)
