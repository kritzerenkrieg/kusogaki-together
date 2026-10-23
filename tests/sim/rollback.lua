-- Hybrid rollback groundwork: saving and restoring a level's whole state
-- (core/level/fullstate.lua). Replaying the same inputs from a restored
-- state must give exactly the same states, in the same level and in another
-- copy of it (what a client does with the host's state).
local helpers = require("tests.sim.helpers")
local check = helpers.check
local Level = require("core.level")
local playerModule = require("core.player")
local fullstate = require("core.level.fullstate")
local wire = require("core.wire")

local function hash(level)
    return love.data.encode("string", "hex", love.data.hash("md5", wire.encode(fullstate.capture(level))))
end

-- Busy scripted inputs: running both ways, jumping, kicking, grabbing.
local function inputFor(id, t)
    local right = (t + id * 37) % 200 < 150
    return {
        right = right, left = not right,
        jump = (t + id * 11) % 45 < 12,
        kick = (t + id * 7) % 60 < 3,
        hold = (t + id * 13) % 120 < 40,
    }
end

local function newLevel()
    local level = Level.load("kusogaki_stage1", { seed = 7 })
    for i = 1, 3 do
        level:addPlayer(playerModule.new(level.spawn.x + i * 20, level.spawn.y))
    end
    return level
end

local function run(level, from, to, hashes)
    local removed = 0
    for t = from, to do
        for _, player in ipairs(level.players) do
            player.input = inputFor(player.id, t)
        end
        level:update(1 / 60)
        for _, event in ipairs(level:takeEvents()) do
            if event.type == "removed" then removed = removed + 1 end
        end
        if hashes and t % 50 == 0 then
            hashes[#hashes + 1] = hash(level)
        end
    end
    return removed
end

do
    local level = newLevel()
    run(level, 1, 300)
    local saved = fullstate.capture(level)
    local savedBytes = #wire.encode(saved)
    local first = {}
    local removed = run(level, 301, 900, first)
    check("the replayed stretch changes the world (removals, deaths)", removed > 0, removed)

    fullstate.restore(level, wire.decode(wire.encode(saved))) -- as it would arrive
    check("restoring gives the saved state back", hash(level) == love.data.encode("string", "hex",
        love.data.hash("md5", wire.encode(saved))))
    local again = {}
    run(level, 301, 900, again)
    local same = #again == #first
    for i = 1, #first do same = same and first[i] == again[i] end
    check("replaying the same inputs from a restored state gives the same states", same)

    -- Another copy of the level (a client's), put into the saved state.
    local other = newLevel()
    run(other, 1, 40) -- somewhere else entirely
    fullstate.restore(other, wire.decode(wire.encode(saved)))
    local elsewhere = {}
    run(other, 301, 900, elsewhere)
    same = #elsewhere == #first
    for i = 1, #first do same = same and first[i] == elsewhere[i] end
    check("another copy of the level restored to it replays the same states", same)

    -- The seeded random generator rewinds too.
    local rolled = newLevel()
    local beforeRolls = fullstate.capture(rolled)
    local firstRolls = { rolled.random:random(1000), rolled.random:random(1000) }
    fullstate.restore(rolled, beforeRolls)
    check("the random generator rewinds with the level", rolled.random:random(1000) == firstRolls[1]
        and rolled.random:random(1000) == firstRolls[2])

    -- Rewinding across a spawn: the spawned entity is rebuilt and removed as needed.
    local spawner = newLevel()
    run(spawner, 1, 100)
    local beforeSpawn = fullstate.capture(spawner)
    spawner:spawnEntity("brick", 400, 100)
    local spawnedId = spawner.nextId - 1
    local afterSpawn = fullstate.capture(spawner)
    fullstate.restore(spawner, beforeSpawn)
    check("rewinding before a spawn removes the spawned entity", spawner:get(spawnedId) == nil
        and spawner.nextId == spawnedId)
    local fresh = newLevel()
    fullstate.restore(fresh, afterSpawn)
    check("restoring a state with a spawned entity builds it", fresh:get(spawnedId) ~= nil
        and fresh:get(spawnedId).typeName == "brick")
    print(string.format("      full state: %d bytes (3 players, %d entities)", savedBytes, #level.enemies
        + #level.props + #level.blocks + #level.hazards + #level.triggers))
end

-- Corrections glide: a body moved by a host state is drawn from where it
-- was, and reaches its new place over about 100 ms; a respawn-sized jump snaps.
do
    local interp = require("core.graphics.interp")
    interp.clear()
    local body = { x = 100, y = 50 }
    interp.record({ body })
    body.x = 130 -- the host's state put it here
    interp.correct(body, 100, 50)
    interp.apply({ body }, 0)
    local drawnAt = body.x
    interp.restore()
    for _ = 1, 12 do interp.decay() end
    interp.record({ body })
    interp.apply({ body }, 0)
    local later = body.x
    interp.restore()
    check("a corrected body is drawn from where it was, then glides", drawnAt == 100 and later > 125 and later < 130,
        string.format("%.1f then %.1f", drawnAt, later))
    local jumper = { x = 0, y = 0 }
    interp.record({ jumper })
    jumper.x = 500
    interp.correct(jumper, 0, 0)
    interp.apply({ jumper }, 0)
    check("a correction as large as a respawn snaps", jumper.x == 500)
    interp.restore()
    interp.clear()
end
