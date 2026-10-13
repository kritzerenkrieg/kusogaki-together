-- Fixed timestep, entity ids, and determinism: the same inputs give the same
-- state with 1, 3 and 5 players, whatever the frame timing.
local fixedstep = require("core.fixedstep")
local Level = require("core.level")
local helpers = require("tests.sim.helpers")
local check = helpers.check
local idProblems = helpers.idProblems
local run = helpers.run
local showDifference = helpers.showDifference
local TICKS = helpers.TICKS
local EVEN = helpers.EVEN
local UNEVEN = helpers.UNEVEN

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
