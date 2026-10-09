-- Platformer player controller.
--
-- Bindings: Z = jump, X = kick (throws the carried prop), C = hold (grab & carry).
-- Movement uses the arrow keys. Bodies are center-based AABBs { x, y, w, h }.
local mathx = require("core.math")
local physics = require("core.physics")

local player = {}

local SPRITE_PATH = "assets/graphics/entities/kusogaki.png"
local SPRITE_FRAME_SIZE = 32
local ANIMATION_FRAME_DURATION = 0.2
local KICK_ANIMATION_DURATION = ANIMATION_FRAME_DURATION * 2
local LONG_IDLE_DELAY = 5
local spriteSheet

player.KEYS = {
    left  = "left",
    right = "right",
    jump  = "z",
    kick  = "c",
    hold  = "x",
}

player.CONFIG = {
    moveSpeed      = 160,  -- max horizontal speed (px/s)
    groundAccel    = 1400,
    groundFriction = 1600,
    airAccel       = 900,
    airFriction    = 200,
    jumpVelocity   = -460, -- initial jump impulse (px/s)
    jumpCut        = 0.45, -- velocity multiplier when Z is released early
    coyoteTime     = 0.09, -- grace period to jump after leaving a ledge
    jumpBuffer     = 0.10, -- grace period for pressing Z just before landing
    kickDuration   = 0.16, -- how long the kick hitbox stays active (s)
    kickCooldown   = 0.30, -- minimum time between kicks (s)
    kickReach      = 20,   -- hitbox width in front of the player
    kickHeight     = 20,   -- hitbox height
    kickPush       = 260,  -- horizontal impulse applied to kicked props
    kickLift       = -90,  -- vertical impulse applied to kicked props
    throwSpeed     = 260,  -- forward speed of a thrown prop
    throwArc       = -140, -- upward speed of a thrown prop
    grabForward    = 20,   -- distance in front of the player for the grab box
    grabRange      = 30,   -- size of the grab search box
}

function player.load()
    spriteSheet = love.graphics.newImage(SPRITE_PATH)
    spriteSheet:setFilter("nearest", "nearest")
end

local function getSpriteQuad(column, row)
    return love.graphics.newQuad(
        (column - 1) * SPRITE_FRAME_SIZE,
        (row - 1) * SPRITE_FRAME_SIZE,
        SPRITE_FRAME_SIZE,
        SPRITE_FRAME_SIZE,
        spriteSheet:getDimensions()
    )
end

-- Create a player at the given center position.
function player.new(x, y)
    local self = setmetatable({}, { __index = player })
    self.x, self.y = x or 0, y or 0
    self.w, self.h = 16, 26
    self.mass = physics.massFromSize(self.w, self.h)
    self.isPlayer = true
    self.vx, self.vy = 0, 0
    self.facing = 1
    self.onGround = false
    self.state = "idle"
    self.animationTime = 0
    self.idleTime = 0
    self.kickAnimationTime = nil
    self.deadAnimationTime = nil
    self.carrying = nil   -- prop currently held (C)
    self.hovered = nil    -- grabbable prop highlighted in front of the player
    self.coyote = 0
    self.jumpBuffer = 0
    self.kickTime = 0
    self.kickCooldown = 0
    self.kickHits = {}    -- props already hit by the current kick
    self.prevKeys = { jump = false, kick = false, hold = false }
    self.input = nil      -- optional { isDown = function(key) } adapter (tests)
    self.onEvent = nil    -- optional callback(name, player) for scene feedback
    return self
end

-- Play the single-frame death pose for one animation interval.
function player:playDead()
    self.deadAnimationTime = ANIMATION_FRAME_DURATION
end

-- Read a key through the injected adapter, falling back to the real keyboard.
local function isDown(self, key)
    if self.input then
        return self.input.isDown(key) == true
    end
    return love.keyboard.isDown(key)
end

local function emit(self, name)
    if self.onEvent then
        self.onEvent(name, self)
    end
end

-- Box used to find grabbable props in front of the player.
function player:getGrabBox()
    local cfg = player.CONFIG
    return {
        x = self.x + self.facing * cfg.grabForward,
        y = self.y - 4,
        w = cfg.grabRange,
        h = cfg.grabRange,
    }
end

-- Active kick hitbox (only meaningful while self.kickTime > 0).
function player:getKickBox()
    local cfg = player.CONFIG
    return {
        x = self.x + self.facing * (self.w / 2 + cfg.kickReach / 2),
        y = self.y + 2,
        w = cfg.kickReach,
        h = cfg.kickHeight,
    }
end

-- Nearest loose prop overlapping the grab box, or nil.
local function findGrabbable(self, world)
    local box = self:getGrabBox()
    local best, bestDist = nil, math.huge
    for _, prop in ipairs(world.props) do
        if not prop.held and physics.overlaps(box, prop) then
            local dx, dy = prop.x - self.x, prop.y - self.y
            local dist = dx * dx + dy * dy
            if dist < bestDist then
                best, bestDist = prop, dist
            end
        end
    end
    return best
end

-- Glue the carried prop to the player's hands.
local function attachCarried(self)
    local prop = self.carrying
    if not prop then
        return
    end
    prop.x = self.x + self.facing * (self.w / 2 + prop.w / 2 - 2)
    prop.y = self.y
    prop.vx, prop.vy = 0, 0
end

-- Release the carried prop with the given velocity.
local function releaseCarried(self, vx, vy)
    local prop = self.carrying
    if not prop then
        return
    end
    prop.held = false
    prop.vx, prop.vy = vx, vy
    self.carrying = nil
end

-- Reconcile the displayed movement state after dynamic-body collisions run.
function player:refreshAnimationState()
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

function player:update(delta, world)

    self.prevY = self.y
    local cfg = player.CONFIG
    local keys = player.KEYS
    delta = math.min(delta, 1 / 30) -- clamp long frames to avoid tunneling

    -- Edge-detected input -------------------------------------------------
    local jumpDown = isDown(self, keys.jump)
    local kickDown = isDown(self, keys.kick)
    local holdDown = isDown(self, keys.hold)
    local jumpPressed  = jumpDown and not self.prevKeys.jump
    local jumpReleased = not jumpDown and self.prevKeys.jump
    local kickPressed  = kickDown and not self.prevKeys.kick
    local holdPressed  = holdDown and not self.prevKeys.hold
    local holdReleased = not holdDown and self.prevKeys.hold
    self.prevKeys.jump = jumpDown
    self.prevKeys.kick = kickDown
    self.prevKeys.hold = holdDown

    -- Timers --------------------------------------------------------------
    self.coyote = math.max(0, self.coyote - delta)
    self.jumpBuffer = math.max(0, self.jumpBuffer - delta)
    self.kickCooldown = math.max(0, self.kickCooldown - delta)
    self.kickTime = math.max(0, self.kickTime - delta)
    if self.kickAnimationTime then
        self.kickAnimationTime = self.kickAnimationTime + delta
        if self.kickAnimationTime >= KICK_ANIMATION_DURATION then
            self.kickAnimationTime = nil
        end
    end
    if self.deadAnimationTime then
        self.deadAnimationTime = math.max(0, self.deadAnimationTime - delta)
        if self.deadAnimationTime == 0 then
            self.deadAnimationTime = nil
        end
    end

    -- Horizontal movement (arrows) ----------------------------------------
    local move = 0
    if isDown(self, keys.left) then move = move - 1 end
    if isDown(self, keys.right) then move = move + 1 end

    if move ~= 0 then
        self.facing = move
        local accel = self.onGround and cfg.groundAccel or cfg.airAccel
        self.vx = mathx.approach(self.vx, move * cfg.moveSpeed, accel * delta)
    else
        local friction = self.onGround and cfg.groundFriction or cfg.airFriction
        self.vx = mathx.approach(self.vx, 0, friction * delta)
    end

    -- Jump (Z): buffered press + coyote time + variable height -------------
    if jumpPressed then
        self.jumpBuffer = cfg.jumpBuffer
    end
    if self.jumpBuffer > 0 and (self.onGround or self.coyote > 0) then
        self.vy = cfg.jumpVelocity
        self.onGround = false
        self.coyote = 0
        self.jumpBuffer = 0
        emit(self, "jump")
    end
    if jumpReleased and self.vy < 0 then
        self.vy = self.vy * cfg.jumpCut -- release early = shorter hop
    end

    -- Hold (C): press to grab, release to drop -----------------------------
    if holdPressed and not self.carrying then
        local target = findGrabbable(self, world)
        if target then
            self.carrying = target
            target.held = true
            target.vx, target.vy = 0, 0
            emit(self, "grab")
        end
    end
    if holdReleased and self.carrying then
        releaseCarried(self, self.facing * 30, 0) -- gentle drop
        emit(self, "drop")
    end

    -- Kick (X): melee attack, or throw the carried prop --------------------
    if kickPressed and self.kickCooldown <= 0 then
        self.kickCooldown = cfg.kickCooldown
        self.kickTime = cfg.kickDuration
        self.kickAnimationTime = 0
        self.idleTime = 0
        self.kickHits = {}
        if self.carrying then
            local thrown = self.carrying
            releaseCarried(self, self.facing * cfg.throwSpeed + self.vx * 0.5, cfg.throwArc)
            self.kickHits[thrown] = true -- never kick the prop we just threw
            emit(self, "throw")
        else
            emit(self, "kick")
        end
    end

    -- Gravity + world collision -------------------------------------------
    self.vy = math.min(self.vy + physics.gravity * delta, physics.maxFall)

    local wasGrounded = self.onGround
    local fallSpeed = self.vy
    physics.moveBody(self, world.solids, delta)
    if self.onGround then
        self.coyote = cfg.coyoteTime
        if not wasGrounded and fallSpeed > 260 then
            emit(self, "land")
        end
    end

    -- Kick hitbox vs loose props -------------------------------------------
    if self.kickTime > 0 then
        local box = self:getKickBox()
        for _, prop in ipairs(world.props) do
            if not prop.held and not self.kickHits[prop] and physics.overlaps(box, prop) then
                self.kickHits[prop] = true
                prop.vx = self.facing * cfg.kickPush
                prop.vy = cfg.kickLift
                prop.onGround = false
                emit(self, "kickHit")
            end
        end
    end

    -- Keep the carried prop glued after moving -----------------------------
    attachCarried(self)

    -- Grabbable highlight for the draw hint --------------------------------
    self.hovered = not self.carrying and findGrabbable(self, world) or nil

    -- Animation state -------------------------------------------------------
    local moving = math.abs(self.vx) > 10
    self:refreshAnimationState()

    if self.onGround and not moving then
        self.idleTime = self.idleTime + delta
    else
        self.idleTime = 0
    end

    if self.state == "run"
        or (self.state == "idle" and self.idleTime >= LONG_IDLE_DELAY) then
        self.animationTime = self.animationTime + delta
    else
        self.animationTime = 0
    end
end

function player:draw()
    -- Highlight a grabbable prop (C hold preview)
    if self.hovered then
        local p = self.hovered
        love.graphics.setColor(1, 1, 1, 0.7)
        love.graphics.setLineWidth(1)
        love.graphics.rectangle("line", p.x - p.w / 2 - 2, p.y - p.h / 2 - 2, p.w + 4, p.h + 4)
    end

    -- Active kick hitbox
    if self.kickTime > 0 then
        local kb = self:getKickBox()
        love.graphics.setColor(1, 0.92, 0.45, 0.5)
        love.graphics.rectangle("fill", kb.x - kb.w / 2, kb.y - kb.h / 2, kb.w, kb.h)
    end

    if not spriteSheet then
        player.load()
    end

    local column, row = 1, 1
    if self.deadAnimationTime then
        column, row = 2, 3
    elseif self.kickAnimationTime and self.state == "kick" then
        row = 4
        column = math.min(2, math.floor(self.kickAnimationTime / ANIMATION_FRAME_DURATION) + 1)
    elseif self.state == "rise" or self.state == "fall" then
        if self.carrying then
            column, row = 4, 2
        else
            column, row = 1, 3
        end
    elseif self.state == "run" then
        row = self.carrying and 2 or 1
        column = (math.floor(self.animationTime / ANIMATION_FRAME_DURATION) % 3) + 2
    elseif self.state == "idle" and self.carrying then
        column, row = 1, 2
    elseif self.state == "idle" and self.idleTime >= LONG_IDLE_DELAY then
        row = 3
        column = math.min(4, 3 + math.floor((self.idleTime - LONG_IDLE_DELAY) / ANIMATION_FRAME_DURATION))
    end

    local quad = getSpriteQuad(column, row)
    local scaleX = self.facing < 0 and -1 or 1
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(
        spriteSheet,
        quad,
        self.x,
        self.y + self.h / 2 - SPRITE_FRAME_SIZE,
        0,
        scaleX,
        1,
        SPRITE_FRAME_SIZE / 2,
        0
    )
end

return player