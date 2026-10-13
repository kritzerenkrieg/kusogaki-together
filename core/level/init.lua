-- A running level: its bodies by role, one simulation step, and drawing.
-- See ARCHITECTURE.md (Level) for the step order and the rules modules.
local physics = require("core.physics")
local loader = require("core.level.loader")
local view = require("core.level.view")
local enemies = require("core.level.enemies")
local blocks = require("core.level.blocks")
local bounds = require("core.level.bounds")
local props = require("core.level.props")
local triggers = require("core.level.triggers")
local render = require("core.graphics.render")
local ui = require("core.level.ui")
local script = require("core.script")
local events = require("core.level.events")

local Level = {}
-- Scripts get levels, so the class must not be reachable from one: a separate,
-- protected metatable (with `Level.__index = Level`, `level.__index` would
-- hand out the class itself).
local LEVEL_META = { __index = Level, __metatable = false }

-- Load a level package and build it, ready to run. `nameOrRoot` is a bundled
-- level name ("example") or a package root (see loader.rootFor); options.seed
-- seeds the level's random generator (the host picks it; default 1).
function Level.load(nameOrRoot, options)
    local data = loader.load(nameOrRoot, options)
    local self = setmetatable({}, LEVEL_META)
    self.name = data.name
    self.root = data.root     -- package root: assets and package sounds live here
    self.random = data.random -- seeded generator; scripts get it as `random`
    local size = data.size or {}
    self.width = size.w or render.width   -- world size (px); the camera stays inside it
    self.height = size.h or render.height -- falling below this is falling out
    self.spawn = data.spawn
    self.background = data.background
    self.geometry = data.statics -- plain rectangles, drawn by view
    self.statics = {}
    for _, list in ipairs({ data.statics, data.hazards, data.blocks }) do
        for _, static in ipairs(list) do
            self.statics[#self.statics + 1] = static
        end
    end
    self.hazards = data.hazards
    self.blocks = data.blocks
    self.enemies = data.enemies
    self.props = data.props
    self.triggers = data.triggers -- non-solid; react to players overlapping them
    self.scripts = data.scripts
    self.players = {} -- in join order; see Level:addPlayer
    self.byId = {}    -- entity id -> entity, for every entity still in the level
    self.events = {}  -- events reported since the last takeEvents()
    for _, list in ipairs({ self.hazards, self.blocks, self.enemies, self.props, self.triggers }) do
        for _, entity in ipairs(list) do
            self.byId[entity.id] = entity
        end
    end
    return self
end

-- The entity with this id, or nil once it has left the level. Entity ids and
-- player ids are separate: entities are numbered by placement, players 1..5.
function Level:get(id)
    return self.byId[id]
end

Level.MAX_PLAYERS = 5

-- Add a player to the level. Its id is its join slot (1..MAX_PLAYERS).
function Level:addPlayer(player)
    assert(#self.players < Level.MAX_PLAYERS, "level is full")
    self.players[#self.players + 1] = player
    player.id = #self.players
    return player
end

local LIST_FOR_KIND = {
    hazard = "hazards", block = "blocks", enemy = "enemies", prop = "props", trigger = "triggers",
}

local function removeFrom(list, item)
    for i, other in ipairs(list) do
        if other == item then
            table.remove(list, i)
            return
        end
    end
end

-- Take an entity out of the level for good: out of its kind's list (and
-- statics, for hazards and blocks) and out of byId. It is marked `removed`.
-- Lists are changed in place, so every holder of them sees the change.
function Level:removeEntity(entity)
    removeFrom(self[LIST_FOR_KIND[entity.kind]], entity)
    if entity.kind == "hazard" or entity.kind == "block" then
        removeFrom(self.statics, entity)
    end
    self.byId[entity.id] = nil
    entity.removed = true
    events.emit({ type = "removed", id = entity.id })
end

-- The events reported since the last call, in order; the list is then empty.
function Level:takeEvents()
    local list = self.events
    self.events = {}
    return list
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

local function step(self, delta)
    local players = self.players
    for _, player in ipairs(players) do
        player:update(delta, self)
    end

    enemies.resolvePropHits(self)
    enemies.pushOutProps(self)
    enemies.update(self, delta, players)
    for _, prop in ipairs(self.props) do
        prop:update(delta, self)
    end
    blocks.animate(self, delta)

    physics.resolveBodyCollisions(dynamicBodies(self), self.statics)

    triggers.touch(self, players)
    blocks.touchHazards(self, players)
    blocks.breakTouched(self, players)
    enemies.touchPlayers(self, players)
    props.removeDetonated(self, players)
    enemies.removeDead(self, players)
    bounds.removeFallen(self, players)
    for _, player in ipairs(players) do
        player:refreshAnimationState()
    end

    for _, hooks in ipairs(self.scripts) do
        if hooks.update then
            hooks.update(delta)
        end
    end
end

-- Stop the level for good: a script (or the engine) failed in a way that
-- cannot be pinned on one script, so the level state can no longer be
-- trusted. The scene shows `faulted` and offers a restart.
function Level:fault(message)
    if not self.faulted then
        self.faulted = tostring(message)
        print("level stopped: " .. self.faulted)
    end
end

-- Run fn(...) under script limits (see script.protect); a failure faults the
-- level. Returns false once the level is faulted.
function Level:protect(fn, ...)
    if self.faulted then
        return false
    end
    local ok, err = script.protect(fn, ...)
    if not ok then
        self:fault(err)
    end
    return ok
end

-- One simulation step. Each player reads its own `input` frame, set by the
-- scene before the step. Returns false (and does nothing) once faulted.
function Level:update(delta)
    if self.faulted then
        return false
    end
    events.begin(self.events)
    local ok = self:protect(step, self, delta)
    events.finish()
    return ok
end

-- Level scripts draw through a read-only view of the ui module.
local uiView = script.readonly(ui)

-- Level scripts' screen-space overlays, drawn over the world.
function Level:drawHud()
    for _, hooks in ipairs(self.scripts) do
        if hooks.drawHud then
            hooks.drawHud(uiView)
        end
    end
end

-- Screen space, behind the world.
function Level:drawBackground()
    view.drawBackground(self.background)
end

-- World space (inside camera.pushWorld).
function Level:draw()
    view.drawGeometry(self.geometry)
    for _, list in ipairs({ self.triggers, self.hazards, self.blocks, self.enemies, self.props }) do
        for _, entity in ipairs(list) do
            entity:draw()
        end
    end
end

return Level
