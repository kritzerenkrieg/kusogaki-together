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

-- Where this player respawns after dying (e.g. a checkpoint). Restarting the
-- level creates a new player, which starts back at the level's spawn.
function player:setSpawn(x, y)
    self.spawnX, self.spawnY = x, y
end

-- Bounce up off an enemy: a full jump without needing the jump key.
function player:bounce()
    controller.bounce(self)
end

function player:respawn()
    state.respawn(self)
end

-- Re-derive the displayed state after dynamic-body collisions run.
function player:refreshAnimationState()
    state.refresh(self)
end

function player:update(delta, level)
    self.prevY = self.y
    delta = math.min(delta, 1 / 30) -- clamp long frames to avoid tunneling
    -- Contacts describe this frame only. Clear them before any early return, so
    -- a hazard touched on the frame of death cannot kill the player again after
    -- respawn (the stale contact made every respawn die instantly).
    self.contacts = {}

    if self.dead then
        state.updateDead(self, delta)
        return
    end

    local edges = controller.readKeys(self)
    state.tick(self, delta)
    controller.horizontal(self, delta)
    controller.jump(self, edges)
    carry.update(self, edges, level)
    controller.kickStart(self, edges, level)

    -- Gravity + level collision
    self.vy = math.min(self.vy + physics.gravity * delta, physics.maxFall)
    local wasGrounded = self.onGround
    local fallSpeed = self.vy
    -- A jump that is still rising; blocks it bumps from below may break. Kicks
    -- and other pushes can also give upward speed, so they do not count.
    self.movingUp = self.jumping and self.vy < 0
    self.falling = self.vy > 0 -- coming down this frame; can stomp an enemy
    physics.moveBody(self, level.statics, delta)
    if self.onGround then
        self.jumping = false
        self.coyote = CONFIG.coyoteTime
        if not wasGrounded and fallSpeed > 260 then
            state.emit(self, "land")
        end
    end

    controller.kickHits(self, level)
    carry.attach(self)
    self.hovered = carry.hover(self, level)
    state.animate(self, delta)
end

function player:draw()
    view.draw(self)
end

return player
