-- Player state: fields, timers, death/respawn transitions and the displayed
-- movement state.
local physics = require("core.physics")
local config = require("core.player.config")

local CONFIG, ANIM = config.CONFIG, config.ANIM
local state = {}

-- Set the initial fields. Position and size must already be set on `self`.
function state.init(self)
    self.onGround = false
    self.state = "idle"
    self.animationTime = 0
    self.idleTime = 0
    self.kickAnimationTime = nil
    self.dead = false     -- true from death until respawn
    self.deadTime = 0     -- seconds since death
    self.spawnX, self.spawnY = self.x, self.y
    self.carrying = nil   -- prop currently held (C)
    self.hovered = nil    -- grabbable prop highlighted in front of the player
    self.coyote = 0
    self.jumpBuffer = 0
    self.kickTime = 0
    self.kickCooldown = 0
    self.kickHits = {}    -- props already hit by the current kick
    self.prevKeys = { jump = false, kick = false, hold = false }
end

-- Notify the scene (camera shake, sound) of a gameplay event.
function state.emit(self, name)
    if self.onEvent then
        self.onEvent(name, self)
    end
end

-- Count down the action timers.
function state.tick(self, delta)
    self.coyote = math.max(0, self.coyote - delta)
    self.jumpBuffer = math.max(0, self.jumpBuffer - delta)
    self.kickCooldown = math.max(0, self.kickCooldown - delta)
    self.kickTime = math.max(0, self.kickTime - delta)
    if self.kickAnimationTime then
        self.kickAnimationTime = self.kickAnimationTime + delta
        if self.kickAnimationTime >= ANIM.kick then
            self.kickAnimationTime = nil
        end
    end
end

-- Mario-style death: drop any carried prop, pop up in the death pose, and fall
-- through the level with no input or collision until respawn.
function state.die(self)
    if self.dead then
        return
    end
    if self.carrying then
        self.carrying.held = false
        self.carrying = nil
    end
    self.dead = true
    self.deadTime = 0
    self.vx = 0
    self.vy = CONFIG.deathJump
    self.kickTime = 0
    self.kickAnimationTime = nil
    self.hovered = nil
    state.emit(self, "death")
end

function state.respawn(self)
    self.dead = false
    self.deadTime = 0
    self.x, self.y = self.spawnX, self.spawnY
    self.vx, self.vy = 0, 0
    self.facing = 1
    self.onGround = false
    state.emit(self, "respawn")
end

-- Movement while dead: gravity only, then respawn after the delay.
function state.updateDead(self, delta)
    self.deadTime = self.deadTime + delta
    self.vy = math.min(self.vy + physics.gravity * delta, physics.maxFall)
    self.y = self.y + self.vy * delta
    if self.deadTime >= CONFIG.respawnDelay then
        state.respawn(self)
    end
end

-- Pick the displayed movement state from the current physics state.
function state.refresh(self)
    local moving = math.abs(self.vx) > 10
    if self.kickTime > 0 or (self.kickAnimationTime and self.onGround and not moving) then
        self.state = "kick"
    elseif not self.onGround then
        self.state = self.vy < 0 and "rise" or "fall"
    elseif moving then
        self.state = "run"
    else
        self.state = "idle"
    end
end

-- Update the idle and run clocks used by the sprite animation.
function state.animate(self, delta)
    local moving = math.abs(self.vx) > 10
    state.refresh(self)

    if self.onGround and not moving then
        self.idleTime = self.idleTime + delta
    else
        self.idleTime = 0
    end

    if self.state == "run"
        or (self.state == "idle" and self.idleTime >= ANIM.longIdle) then
        self.animationTime = self.animationTime + delta
    else
        self.animationTime = 0
    end
end

return state
