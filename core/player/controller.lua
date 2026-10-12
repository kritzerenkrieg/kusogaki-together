-- Player controls: arrow-key movement, Z jump, X kick (or throw while carrying).
local mathx = require("core.math")
local config = require("core.player.config")
local state = require("core.player.state")
local carry = require("core.player.carry")
local physics = require("core.physics")

local CONFIG, KEYS = config.CONFIG, config.KEYS
local controller = {}

-- Read a key through the injected adapter, falling back to the real keyboard.
local function isDown(self, key)
    if self.input then
        return self.input.isDown(key) == true
    end
    return love.keyboard.isDown(key)
end

-- Key state for this frame: pressed/released edges for jump, kick and hold.
function controller.readKeys(self)
    local jumpDown = isDown(self, KEYS.jump)
    local kickDown = isDown(self, KEYS.kick)
    local holdDown = isDown(self, KEYS.hold)
    local prev = self.prevKeys
    local edges = {
        jumpPressed  = jumpDown and not prev.jump,
        jumpReleased = not jumpDown and prev.jump,
        kickPressed  = kickDown and not prev.kick,
        holdPressed  = holdDown and not prev.hold,
        holdReleased = not holdDown and prev.hold,
    }
    prev.jump, prev.kick, prev.hold = jumpDown, kickDown, holdDown
    return edges
end

-- Horizontal movement from the arrow keys, with acceleration and friction.
function controller.horizontal(self, delta)
    local move = 0
    if isDown(self, KEYS.left) then move = move - 1 end
    if isDown(self, KEYS.right) then move = move + 1 end

    if move ~= 0 then
        self.facing = move
        local accel = self.onGround and CONFIG.groundAccel or CONFIG.airAccel
        self.vx = mathx.approach(self.vx, move * CONFIG.moveSpeed, accel * delta)
    else
        local friction = self.onGround and CONFIG.groundFriction or CONFIG.airFriction
        self.vx = mathx.approach(self.vx, 0, friction * delta)
    end
end

-- Jump with input buffering and coyote time, plus variable height.
function controller.jump(self, edges)
    if edges.jumpPressed then
        self.jumpBuffer = CONFIG.jumpBuffer
    end
    if self.jumpBuffer > 0 and (self.onGround or self.coyote > 0) then
        self.vy = CONFIG.jumpVelocity
        self.onGround = false
        self.jumping = true
        self.coyote = 0
        self.jumpBuffer = 0
        state.emit(self, "jump")
    end
    if edges.jumpReleased and self.vy < 0 then
        self.vy = self.vy * CONFIG.jumpCut -- release early = shorter hop
    end
end

-- Start a kick, or throw the carried prop instead.
function controller.kickStart(self, edges, level)
    if not (edges.kickPressed and self.kickCooldown <= 0) then
        return
    end
    self.kickCooldown = CONFIG.kickCooldown
    self.kickGrace = CONFIG.kickGrace
    self.kickTime = CONFIG.kickDuration
    self.kickAnimationTime = 0
    self.idleTime = 0
    self.kickHits = {}
    if self.carrying then
        local thrown = carry.throw(self,
            self.facing * CONFIG.throwSpeed + self.vx * 0.5, CONFIG.throwArc, level.statics)
        self.kickHits[thrown] = true -- never kick the prop we just threw
        state.emit(self, "throw")
    else
        state.emit(self, "kick")
    end
end

-- Launch the player upward as a full jump (used after stomping an enemy).
function controller.bounce(self)
    self.vy = CONFIG.jumpVelocity
    self.onGround = false
    self.jumping = true
    self.coyote = 0
    state.emit(self, "stomp")
end

-- Kick hitbox in front of the player (only meaningful while kickTime > 0).
function controller.kickBox(self)
    return {
        x = self.x + self.facing * (self.w / 2 + CONFIG.kickReach / 2),
        y = self.y + 2,
        w = CONFIG.kickReach,
        h = CONFIG.kickHeight,
    }
end

-- Push props that the active kick hitbox overlaps, and break blocks it hits,
-- once per kick.
function controller.kickHits(self, level)
    if self.kickTime <= 0 then
        return
    end
    local box = controller.kickBox(self)
    for _, prop in ipairs(level.props) do
        if not prop.held and not self.kickHits[prop] and physics.overlaps(box, prop) then
            self.kickHits[prop] = true
            prop.vx = self.facing * CONFIG.kickPush
            prop.vy = CONFIG.kickLift
            prop.onGround = false
            state.emit(self, "kickHit")
        end
    end
    for _, block in ipairs(level.blocks) do
        if not self.kickHits[block] and physics.overlaps(box, block) then
            self.kickHits[block] = true
            if block:onKick(self) then
                block.brokenBy = self
            end
        end
    end
    for _, enemy in ipairs(level.enemies) do
        if not enemy.held and not self.kickHits[enemy] and physics.overlaps(box, enemy) then
            self.kickHits[enemy] = true
            if enemy:onKick(self) then
                enemy.killedBy = "kick"
                enemy.kickVx = self.facing * CONFIG.enemyKickPush
                enemy.kickVy = CONFIG.enemyKickLift
            end
        end
    end
end

return controller
