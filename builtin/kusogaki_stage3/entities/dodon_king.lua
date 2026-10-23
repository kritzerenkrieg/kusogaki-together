-- Entity type script: "dodon_king", the boss of kusogaki_stage3. A giant
-- dodon (its own sprite) with `maxHp` health. It walks toward the nearest player
-- and leaps at them every few seconds; at half health it gets faster (and the
-- level script rains dambos and lit fake boxes on the arena). It cannot be
-- stomped; kicks, thrown props and blasts (a thrown lit box!) each take one health, then it flashes and cannot be hurt for
-- `hurtTime` seconds. The first time its health runs out it only plays dead:
-- it lies on its back for `fakeDeathTime` seconds, harmless, then gets up with
-- `reviveHp`. The second time is for real. Touching it anywhere but the top
-- kills. Players cannot
-- pick it up. Runs in the sandbox; the base class Entity is injected by
-- core/level/loader.lua.
--
-- Placement:
--   { "type": "dodon_king", "x": 3520, "y": 256,
--     "arena": { "left": 3240, "right": 3810 },  -- it never walks out of this
--     "hp": 8 }                                   -- optional
local King = setmetatable({}, { __index = Entity })
King.__index = King

King.name = "dodon_king"
King.kind = "enemy"
King.assetPath = "assets/king.png" -- 2 walk frames of 48x48 side by side
King.w, King.h = 40, 44
King.frameSize = 48
King.maxHp = 8
King.speed = 45          -- walk speed (px/s)
King.angrySpeed = 75     -- at half health
King.jumpEvery = 2.2     -- seconds on the ground between leaps
King.angryJumpEvery = 1.4
King.jumpSpeed = -380    -- leap impulse (px/s)
King.leapSpeed = 110     -- sideways speed of a leap (px/s)
King.hurtTime = 1.0      -- seconds it cannot be hurt after a hit
King.frameTime = 0.2
King.fakeDeathTime = 2.5 -- seconds it plays dead
King.reviveHp = 4        -- health when it gets back up
King.netFields = { "hp", "hurt", "fakeDead" }
King.image = nil
King.frames = nil

function King.load()
    if not King.image then
        King.image = Entity.loadImage(King.assetPath)
        King.frames = Entity.sliceFrames(King.image, King.frameSize, King.frameSize)
    end
    return King.image
end

function King.new(x, y, def)
    def = def or {}
    local arena = def.arena or {}
    local self = Entity.new(King, x, y, {
        name = King.name,
        image = King.image,
        frames = King.frames,
        w = King.w,
        h = King.h,
    })
    self.maxHp = def.hp or King.maxHp
    self.hp = self.maxHp
    self.hurt = 0
    self.left = arena.left or (x - 300)
    self.right = arena.right or (x + 300)
    self.noGrab = true
    self.revived = false
    self.fakeDead = 0       -- seconds left playing dead
    self.jumpTimer = 0
    self.wasAirborne = false
    self.landed = false     -- true for the tick it lands from a leap (the level script reads it)
    self.animTime = 0
    return self
end

function King:angry()
    return self.hp <= self.maxHp / 2
end

-- Take one health (unless it was just hurt or is playing dead). The first
-- time health runs out it plays dead.
function King:hit()
    if self.hurt <= 0 and self.hp > 0 and self.fakeDead <= 0 then
        self.hp = self.hp - 1
        self.hurt = King.hurtTime
        self:playSfx("hit.wav")
        if self.hp == 0 and not self.revived then
            self.revived = true
            self.fakeDead = King.fakeDeathTime
        end
    end
end

-- Out of health for real (not playing dead).
function King:isDown()
    return self.hp <= 0 and self.fakeDead <= 0
end

local function nearestPlayer(self, players)
    local best, bestDistance = nil, math.huge
    for _, player in ipairs(players or {}) do
        local distance = math.abs(player.x - self.x)
        if not player.dead and not player.held and distance < bestDistance then
            best, bestDistance = player, distance
        end
    end
    return best
end

function King:update(delta, level)
    self.landed = false
    self.hurt = math.max(0, self.hurt - delta)
    if self.fakeDead > 0 then
        self.fakeDead = math.max(0, self.fakeDead - delta)
        self.rotation = math.pi -- on its back
        self.vx = 0
        if self.fakeDead == 0 then
            self.hp = King.reviveHp
            self.rotation = 0
            self.jumpTimer = King.jumpEvery -- gets up with a leap
            self:playSfx("hit.wav")
        end
        Entity.update(self, delta, level)
        return
    end
    local target = nearestPlayer(self, level.players)
    if target and math.abs(target.x - self.x) > 4 then
        self.facing = target.x > self.x and 1 or -1
    end
    if self.onGround then
        if self.wasAirborne then
            self.landed = true
            self.vx = 0
        end
        self.jumpTimer = self.jumpTimer + delta
        self.vx = target and self.facing * (self:angry() and King.angrySpeed or King.speed) or 0
        if target and self.jumpTimer >= (self:angry() and King.angryJumpEvery or King.jumpEvery) then
            self.jumpTimer = 0
            self.vy = King.jumpSpeed
            self.vx = self.facing * King.leapSpeed
        end
    end
    self.wasAirborne = not self.onGround
    Entity.update(self, delta, level)
    if self.x < self.left then
        self.x, self.vx = self.left, 0
    elseif self.x > self.right then
        self.x, self.vx = self.right, 0
    end
    self.animTime = self.animTime + delta * (self:angry() and 2 or 1)
    self.frameIndex = math.floor(self.animTime / King.frameTime) % #self.frames + 1
end

-- It cannot be stomped: landing on it is as deadly as touching it anywhere else
-- (only kicks, thrown props and blasts hurt it).
function King:onStomp(player)
    return false
end

-- Touching it kills (but not while it plays dead).
function King:onTouch(player)
    return self.fakeDead <= 0
end

function King:onKick(player)
    self:hit()
    return self:isDown()
end

function King:draw(ui)
    local frame = self.frames[self.frameIndex] or self.frames[1]
    local size = King.frameSize
    local footY = self.y + self.h / 2
    if self.hurt > 0 and math.floor(self.hurt * 12) % 2 == 0 then
        ui.color(1, 0.35, 0.35, 1)
    else
        ui.color(1, 1, 1, 1)
    end
    ui.sprite(self.image, frame, self.x, footY - size / 2, self.rotation, self.facing, 1, size / 2, size / 2)
end

return King
