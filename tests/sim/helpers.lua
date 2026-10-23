-- Shared setup for the simulation checks (tests/sim_test.lua): graphics and
-- audio stubs, the check counter, scripted inputs and the level runner.
local helpers = { failures = 0 }

function helpers.check(name, condition, detail)
    if condition then
        print("ok    " .. name)
    else
        helpers.failures = helpers.failures + 1
        print("FAIL  " .. name .. (detail and (" (" .. tostring(detail) .. ")") or ""))
    end
end
local check = helpers.check

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

-- Top-down level (levels/topdown): walk the eight directions in turn, dash now and then.
local function topdownInput(tick, playerIndex)
    local t = tick + (playerIndex - 1) * 37
    local direction = math.floor(t / 40) % 8 -- eight directions in turn
    return {
        right = direction <= 1 or direction == 7,
        down = direction >= 1 and direction <= 3,
        left = direction >= 3 and direction <= 5,
        up = direction >= 5,
        dash = (t % 70) < 3,
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

local PLAYER_FIELDS = { "id", "x", "y", "vx", "vy", "facing", "onGround", "jumping", "dead", "kickTime", "held" }
local BODY_FIELDS = { "id", "name", "x", "y", "vx", "vy", "onGround", "held", "awake", "detonated" }

-- Everything the simulation decides, as one string.
local function stateString(level)
    local parts = {}
    for _, player in ipairs(level.players) do
        for _, field in ipairs(PLAYER_FIELDS) do
            parts[#parts + 1] = fmt(player[field])
        end
        local carried = player.carrying
        parts[#parts + 1] = carried and (carried.isPlayer and ("P" .. carried.id) or carried.name) or "-"
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
-- `inputs(tick, playerIndex)` gives the frames (default inputAt).
local function run(ticks, frameDeltas, playerCount, root, inputs)
    inputs = inputs or inputAt
    local level = Level.load(root or "kusogaki_stage1")
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
                player.input = inputs(tick, i)
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

helpers.stub = stub
helpers.inputAt = inputAt
helpers.topdownInput = topdownInput
helpers.fmt = fmt
helpers.idProblems = idProblems
helpers.stateString = stateString
helpers.plain = plain
helpers.run = run
helpers.showDifference = showDifference
helpers.TICKS = TICKS
helpers.EVEN = EVEN
helpers.UNEVEN = UNEVEN

return helpers
