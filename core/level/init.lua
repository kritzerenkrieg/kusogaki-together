-- A running level: its bodies by role, one simulation step, and drawing.
-- See ARCHITECTURE.md (Level) for the step order and the rules modules.
local physics = require("core.physics")
local loader = require("core.level.loader")
local view = require("core.level.view")
local render = require("core.graphics.render")
local ui = require("core.level.ui")
local script = require("core.script")
local events = require("core.level.events")
local netstate = require("core.level.netstate")
local stages = require("core.level.stages")
local input = require("core.input")

local Level = {}
-- Scripts get levels, so the class must not be reachable from one: a separate,
-- protected metatable (with `Level.__index = Level`, `level.__index` would
-- hand out the class itself).
local LEVEL_META = { __index = Level, __metatable = false }

Level.MAX_PLAYERS = 5

local callHooks = stages.callHooks

-- Stage list helpers (see core/level/stages.lua).
Level.findStage = stages.find
Level.addStage = stages.add
Level.removeStage = stages.remove
Level.replaceStage = stages.replace

-- ── Loading ───────────────────────────────────────────────────────────────

-- Load a level package and build it, ready to run. `nameOrRoot` is a bundled
-- level name ("kusogaki_stage1") or a package root (see loader.rootFor); options.seed
-- seeds the level's random generator (the host picks it; default 1).
function Level.load(nameOrRoot, options)
    local data = loader.load(nameOrRoot, options)
    local self = setmetatable({}, LEVEL_META)
    self.name = data.name
    self.root = data.root     -- package root: assets and package sounds live here
    self.random = data.random -- seeded generator; scripts get it as `random`
    self.seed = options and options.seed or 1 -- what seeded it (the host picks it)
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
    self.everyEntity = {} -- entity id -> entity, also after it left (core/level/fullstate.lua revives it)
    for _, list in ipairs({ self.hazards, self.blocks, self.enemies, self.props, self.triggers }) do
        for _, entity in ipairs(list) do
            self.byId[entity.id] = entity
            self.everyEntity[entity.id] = entity
        end
    end

    -- What scripts can change to reshape the game (ARCHITECTURE.md, Level):
    self.types = data.types     -- entity types loaded so far (Level:spawnEntity loads more)
    self.nextId = data.nextId   -- id of the next spawned entity
    self.gravity = data.gravity or physics.gravity -- px/s^2; 0 floats everything
    self.maxFall = data.maxFall or physics.maxFall
    self.actions = data.actions -- custom input actions (core/input.lua)
    self.actionNames = input.names(data.actions)
    self.camera = data.camera   -- { follow, zoom, x, y, clamp }; see camera.frame
    self.music = data.music     -- the game's track to play (nil: the default)
    self.hud = data.hud         -- true: each local player's state line in the corner
    self.stages = stages.defaults()
    self.playerController = nil -- custom controller for every player (nil: platformer)
    self.net = {}               -- level script state synced to clients (plain data)
    self.finished = nil         -- { outcome, message } once Level:finish was called

    callHooks(self, "load", self)
    for _, hooks in ipairs(self.scripts) do
        if hooks.scriptDisabled then
            error(("level script failed in load: %s"):format(hooks.scriptError), 0)
        end
    end
    return self
end

-- The entity with this id, or nil once it has left the level. Entity ids and
-- player ids are separate: entities are numbered by placement, players 1..5.
function Level:get(id)
    return self.byId[id]
end

-- Add a player to the level with id `id` (1..MAX_PLAYERS, unused), or the
-- lowest free id. In network play the session keeps ids stable across
-- restarts and leaves, so ids can have gaps; `players` stays in join order.
-- Level scripts' playerJoined(player, level) hooks run (under script limits).
function Level:addPlayer(player, id)
    assert(#self.players < Level.MAX_PLAYERS, "level is full")
    local used = {}
    for _, other in ipairs(self.players) do
        used[other.id] = true
    end
    if id == nil then
        id = 1
        while used[id] do
            id = id + 1
        end
    end
    assert(type(id) == "number" and id % 1 == 0 and id >= 1 and id <= Level.MAX_PLAYERS and not used[id],
        "invalid or used player id")
    self.players[#self.players + 1] = player
    player.id = id
    self:protect(callHooks, self, "playerJoined", player, self)
    return player
end

-- Add an entity of type `typeName` (entities/<typeName>.lua in this package)
-- at (x, y) while the level runs. `def` is its placement ({ ... } fields the
-- type reads in new; plain data). Spawned entities get ids after the
-- placements', in spawn order: in network play only the host spawns, and
-- clients learn about it from the "spawned" event and snapshots. Returns the
-- entity.
function Level:spawnEntity(typeName, x, y, def)
    def = def or {}
    netstate.checkPlain(def, "spawn placement")
    local Type = loader.loadType(self.root, typeName, self.types, self.random)
    local entity, listName = loader.newEntity(Type, typeName, x, y, def, "spawn")
    entity.id = self.nextId
    entity.spawned = true
    entity.spawnDef = def
    self.nextId = self.nextId + 1
    local list = self[listName]
    list[#list + 1] = entity
    if entity.kind == "hazard" or entity.kind == "block" then
        self.statics[#self.statics + 1] = entity
    end
    self.byId[entity.id] = entity
    self.everyEntity[entity.id] = entity
    events.emit({ type = "spawned", id = entity.id, typeName = typeName, x = x, y = y, def = def })
    return entity
end

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
    removeFrom(self[loader.LIST_FOR_KIND[entity.kind]], entity)
    if entity.kind == "hazard" or entity.kind == "block" then
        removeFrom(self.statics, entity)
    end
    self.byId[entity.id] = nil
    entity.removed = true
    events.emit({ type = "removed", id = entity.id })
end

-- End the level with an outcome ("win", "lose" or any short word a gamemode
-- uses) and an optional message. The simulation stops; the scene shows the
-- result and offers a restart. Reported as a "finish" event.
function Level:finish(outcome, message)
    if self.finished then
        return
    end
    outcome = type(outcome) == "string" and outcome:sub(1, 24) or "win"
    message = message ~= nil and tostring(message):sub(1, 200) or nil
    self.finished = { outcome = outcome, message = message }
    events.emit({ type = "finish", outcome = outcome, message = message })
end

-- Send a message from the simulation to every machine's presentation: level
-- scripts' message(name, data, level) hooks receive it after the step, here
-- and (in network play) on every client. `data` must be plain data. Use it for
-- one-off things clients should show (a score popup, a round starting).
function Level:send(name, data)
    if type(name) ~= "string" or not name:match("^[%w_%.%-]+$") or #name > 64 then
        error("message name must be a short plain word", 2)
    end
    netstate.checkPlain(data, "message " .. name)
    events.emit({ type = "message", name = name, data = data })
end

-- Hand a message to level scripts (event presentation calls this).
function Level:deliver(name, data)
    callHooks(self, "message", name, data, self)
end

-- The events reported since the last call, in order; the list is then empty.
function Level:takeEvents()
    local list = self.events
    self.events = {}
    return list
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
-- scene before the step. Returns false (and does nothing) once faulted or
-- finished.
function Level:update(delta)
    if self.faulted or self.finished then
        return false
    end
    events.begin(self.events)
    local ok = self:protect(stages.run, self, delta)
    events.finish()
    return ok
end

-- Level scripts and entities draw through a read-only view of the ui module.
local uiView = script.readonly(ui)

-- Screen space, behind the world.
function Level:drawBackground()
    view.drawBackground(self.background)
end

-- World space (inside camera.pushWorld): level scripts' drawBehind(ui, level),
-- geometry, then entities (entity:draw(ui)).
function Level:draw()
    callHooks(self, "drawBehind", uiView, self)
    view.drawGeometry(self.geometry)
    for _, list in ipairs({ self.triggers, self.hazards, self.blocks, self.enemies, self.props }) do
        for _, entity in ipairs(list) do
            entity:draw(uiView)
        end
    end
end

-- World space: the players, player 1 on top. A controller with a draw
-- function draws its players (controller.draw(player, ui, level)).
function Level:drawPlayers()
    for i = #self.players, 1, -1 do
        local player = self.players[i]
        local controller = stages.controllerOf(self, player)
        if controller and controller.draw then
            controller.draw(player, uiView, self)
        else
            player:draw()
        end
    end
end

-- World space, over everything else: level scripts' drawWorld(ui, level).
function Level:drawWorld()
    callHooks(self, "drawWorld", uiView, self)
end

-- Screen space, over the world: level scripts' drawHud(ui, level).
function Level:drawHud()
    callHooks(self, "drawHud", uiView, self)
end

return Level
