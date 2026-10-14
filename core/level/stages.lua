-- The simulation step as data: `level.stages` is a list of
-- { name, run(level, delta) } run in order each tick. Each level gets its own
-- fresh list (stages.defaults), so level scripts may add, remove, replace or
-- reorder stages to change the rules (Level:addStage and friends) without
-- touching any other level. See ARCHITECTURE.md (Step order) and MODDING.md
-- (Stages).
local physics = require("core.physics")
local enemies = require("core.level.enemies")
local blocks = require("core.level.blocks")
local bounds = require("core.level.bounds")
local props = require("core.level.props")
local triggers = require("core.level.triggers")

local stages = {}

-- Call hook `name` of every level script that has it, in level.json order.
function stages.callHooks(level, name, ...)
    for _, hooks in ipairs(level.scripts) do
        local hook = hooks[name]
        if hook then
            hook(...)
        end
    end
end

-- The controller driving `player`: its own, else the level's, else nil (the
-- built-in platformer: player:update and player:draw). A controller may define
-- update, draw or both; the platformer does the part it leaves out.
function stages.controllerOf(level, player)
    return player.controller or level.playerController
end

local function customUpdate(level, player)
    local controller = stages.controllerOf(level, player)
    return controller and controller.update and controller or nil
end

-- Input edges: player.pressed[action] / player.released[action] for this tick.
local NO_INPUT = {}
local function readInput(level)
    for _, player in ipairs(level.players) do
        local now, before = player.input or NO_INPUT, player.lastInput or NO_INPUT
        local pressed, released = {}, {}
        for _, name in ipairs(level.actionNames) do
            local down, wasDown = now[name] == true, before[name] == true
            pressed[name] = down and not wasDown
            released[name] = wasDown and not down
        end
        player.pressed, player.released = pressed, released
        player.lastInput = player.input
    end
end

-- Players this machine simulates: all but puppets (`remote`: another
-- machine plays them, core/net/playersync.lua). Rules that change a player
-- (deaths, stomps, falling out) run on its owner's machine only; rules that
-- only read players (enemies waking, triggers) see everyone.
function stages.simulated(level)
    local list = {}
    for _, player in ipairs(level.players) do
        if not player.remote then
            list[#list + 1] = player
        end
    end
    return list
end
local simulated = stages.simulated

local function updatePlayers(level, delta)
    for _, player in ipairs(simulated(level)) do
        local controller = customUpdate(level, player)
        if controller then
            controller.update(player, delta, level)
        else
            player:update(delta, level)
        end
    end
end

-- Live players first (in join order), then props: pair resolution order is
-- part of the simulation, so it must not depend on anything else.
local function dynamicBodies(self)
    local bodies = {}
    for _, player in ipairs(self.players) do
        if not player.dead then
            bodies[#bodies + 1] = player
        end
    end
    for _, prop in ipairs(self.props) do
        bodies[#bodies + 1] = prop
    end
    return bodies
end

local function updateProps(level, delta)
    for _, prop in ipairs(level.props) do
        prop:update(delta, level)
    end
end

local function refreshPlayers(level)
    for _, player in ipairs(simulated(level)) do
        if not customUpdate(level, player) then
            player:refreshAnimationState()
        end
    end
end

local function runScripts(level, delta)
    stages.callHooks(level, "update", delta, level)
end

-- The built-in rules, in order. Each entry becomes a fresh table per level.
local DEFAULT_STAGES = {
    { "input", readInput },
    { "players", updatePlayers },
    { "propHits", function(level) enemies.resolvePropHits(level) end },
    { "propPushOut", function(level) enemies.pushOutProps(level) end },
    { "enemies", function(level, delta) enemies.update(level, delta, level.players) end },
    { "props", updateProps },
    { "animateBlocks", function(level, delta) blocks.animate(level, delta) end },
    { "collisions", function(level) physics.resolveBodyCollisions(dynamicBodies(level), level.statics) end },
    { "triggers", function(level) triggers.touch(level, level.players) end },
    { "hazards", function(level) blocks.touchHazards(level, simulated(level)) end },
    { "breakBlocks", function(level) blocks.breakTouched(level, simulated(level)) end },
    { "enemyTouch", function(level) enemies.touchPlayers(level, simulated(level)) end },
    { "detonations", function(level) props.removeDetonated(level, simulated(level)) end },
    { "enemyDeaths", function(level) enemies.removeDead(level, simulated(level)) end },
    { "bounds", function(level) bounds.removeFallen(level, simulated(level)) end },
    { "playerAnimation", refreshPlayers },
    { "scripts", runScripts },
}

-- A fresh stage list for a new level.
function stages.defaults()
    local stages = {}
    for i, entry in ipairs(DEFAULT_STAGES) do
        stages[i] = { name = entry[1], run = entry[2] }
    end
    return stages
end

-- Index and entry of the stage called `name`, or nil.
function stages.find(level, name)
    for i, stage in ipairs(level.stages) do
        if stage.name == name then
            return i, stage
        end
    end
    return nil
end

local function checkStage(name, run)
    if type(name) ~= "string" or type(run) ~= "function" then
        error("a stage needs a name and a run(level, delta) function", 3)
    end
end

-- Add a stage. `where` = { before = "name" } or { after = "name" }; default:
-- the end of the step. Returns the new stage entry.
function stages.add(level, name, run, where)
    checkStage(name, run)
    local stage = { name = name, run = run }
    local position = #level.stages + 1
    if where and (where.before or where.after) then
        local index = stages.find(level, where.before or where.after)
        if not index then
            error("no stage called " .. tostring(where.before or where.after), 2)
        end
        position = where.before and index or index + 1
    end
    table.insert(level.stages, position, stage)
    return stage
end

-- Remove the stage called `name`; returns its entry (nil if there was none).
function stages.remove(level, name)
    local index, stage = stages.find(level, name)
    if index then
        table.remove(level.stages, index)
    end
    return stage
end

-- Swap the run function of stage `name`; returns the previous one, so a
-- script can wrap a built-in rule.
function stages.replace(level, name, run)
    checkStage(name, run)
    local _, stage = stages.find(level, name)
    if not stage then
        error("no stage called " .. tostring(name), 2)
    end
    local previous = stage.run
    stage.run = run
    return previous
end

-- One step: every stage in order (a copy of the list, so a stage may change
-- it safely), or only those named in the set `only`. Finishing the level ends
-- the step.
function stages.run(level, delta, only)
    local list = {}
    for _, stage in ipairs(level.stages) do
        if not only or only[stage.name] then
            list[#list + 1] = stage
        end
    end
    for _, stage in ipairs(list) do
        stage.run(level, delta)
        if level.finished then
            return
        end
    end
end

return stages
