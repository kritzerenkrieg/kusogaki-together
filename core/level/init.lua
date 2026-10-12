-- A running level: its bodies by role, one simulation step, and drawing.
-- See ARCHITECTURE.md (Level) for the step order and the rules modules.
local physics = require("core.physics")
local loader = require("core.level.loader")
local view = require("core.level.view")
local enemies = require("core.level.enemies")
local blocks = require("core.level.blocks")

local Level = {}
Level.__index = Level

-- Load levels/<name>/ and build it, ready to run.
function Level.load(name)
    local data = loader.load(name)
    local self = setmetatable({}, Level)
    self.name = data.name
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
    return self
end

-- Remove in place, so every holder of level.statics sees the change.
function Level:removeStatic(static)
    for i, other in ipairs(self.statics) do
        if other == static then
            table.remove(self.statics, i)
            return
        end
    end
end

local function dynamicBodies(self, player)
    local bodies = {}
    if not player.dead then
        bodies[1] = player
    end
    for _, prop in ipairs(self.props) do
        bodies[#bodies + 1] = prop
    end
    return bodies
end

function Level:update(delta, player)
    player:update(delta, self)

    enemies.resolvePropHits(self)
    enemies.pushOutProps(self)
    enemies.update(self, delta)
    for _, prop in ipairs(self.props) do
        prop:update(delta, self)
    end

    physics.resolveBodyCollisions(dynamicBodies(self, player), self.statics)

    blocks.touchHazards(self, player)
    blocks.breakTouched(self, player)
    enemies.touchPlayer(self, player)
    player:refreshAnimationState()
end

function Level:draw()
    view.drawBackground(self.background)
    view.drawGeometry(self.geometry)
    for _, list in ipairs({ self.hazards, self.blocks, self.enemies, self.props }) do
        for _, entity in ipairs(list) do
            entity:draw()
        end
    end
end

return Level
