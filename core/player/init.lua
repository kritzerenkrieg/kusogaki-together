-- Platformer player: a physics body driven by the controller, with carrying,
-- death/respawn and drawing. Modules live beside this file in core/player/.
-- Bodies are center-based AABBs { x, y, w, h }.
local physics = require("core.physics")
local config = require("core.player.config")
local state = require("core.player.state")
local controller = require("core.player.controller")
local carry = require("core.player.carry")
local view = require("core.player.view")

local CONFIG = config.CONFIG

local player = {}
player.KEYS = config.KEYS
player.CONFIG = CONFIG
player.load = view.load

-- Create a player at the given center position.
-- Collision size comes from player.CONFIG.width / player.CONFIG.height.
function player.new(x, y)
    local self = setmetatable({}, { __index = player })
    self.x, self.y = x or 0, y or 0
    self.w, self.h = CONFIG.width, CONFIG.height
    self.mass = physics.massFromSize(self.w, self.h)
    self.isPlayer = true
    self.vx, self.vy = 0, 0
    self.facing = 1
    state.init(self)
    self.input = nil      -- optional { isDown = function(key) } adapter (tests)
    self.onEvent = nil    -- optional callback(name, player) for scene feedback
    return self
end

function player:die()
    state.die(self)
end

function player:respawn()
    state.respawn(self)
end

-- Re-derive the displayed state after dynamic-body collisions run.
function player:refreshAnimationState()
    state.refresh(self)
end

function player:update(delta, world)
    self.prevY = self.y
    delta = math.min(delta, 1 / 30) -- clamp long frames to avoid tunneling

    if self.dead then
        state.updateDead(self, delta)
        return
    end

    local edges = controller.readKeys(self)
    state.tick(self, delta)
    controller.horizontal(self, delta)
    controller.jump(self, edges)
    carry.update(self, edges, world)
    controller.kickStart(self, edges, world)

    -- Gravity + world collision
    self.vy = math.min(self.vy + physics.gravity * delta, physics.maxFall)
    local wasGrounded = self.onGround
    local fallSpeed = self.vy
    physics.moveBody(self, world.solids, delta)
    if self.onGround then
        self.coyote = CONFIG.coyoteTime
        if not wasGrounded and fallSpeed > 260 then
            state.emit(self, "land")
        end
    end

    controller.kickHits(self, world)
    carry.attach(self)
    self.hovered = carry.hover(self, world)
    state.animate(self, delta)
end

function player:draw()
    view.draw(self)
end

return player
