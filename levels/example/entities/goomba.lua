-- Entity type script: "goomba", a walking enemy. Runs in the sandbox; the base
-- class Entity is injected by core/level/loader.lua.
local Goomba = setmetatable({}, { __index = Entity })
Goomba.__index = Goomba

Goomba.name = "goomba"
Goomba.kind = "enemy" -- walks on statics, props and other enemies; stomp or kick to kill it, touch to die
Goomba.assetPath = "levels/example/assets/dodon.png" -- 2 walk frames side by side
Goomba.w, Goomba.h = 16, 16 -- one frame of the sheet
Goomba.speed = 40           -- walk speed (px/s)
Goomba.frameTime = 0.2      -- seconds per walk frame
Goomba.glide = 300          -- how fast launch speed eases back to walking (px/s^2)
Goomba.image = nil
Goomba.frames = nil

function Goomba.load()
    if not Goomba.image then
        Goomba.image = Entity.loadImage(Goomba.assetPath)
        Goomba.frames = Entity.sliceFrames(Goomba.image, Goomba.w, Goomba.h)
    end
    return Goomba.image
end

function Goomba.new(x, y)
    local self = Entity.new(Goomba, x, y, {
        name = Goomba.name,
        image = Goomba.image,
        frames = Goomba.frames,
        w = Goomba.w,
        h = Goomba.h,
    })
    self.dir = 1          -- walking direction: 1 right, -1 left
    self.animTime = 0     -- drives the walk animation
    return self
end

-- Reverse direction.
function Goomba:turn()
    self.dir = -self.dir
end

-- Walk, turn around when blocked by a static, prop or enemy, and advance the
-- walk frame. `level.statics` is what this enemy collides with (the level passes
-- statics plus the other solid bodies). Airborne (thrown or falling) it keeps
-- its launch speed; on the ground that speed eases back to the walk speed.
function Goomba:update(delta, level)
    if self.held then
        self.dir = self.facing -- carried: face where the player faces
    else
        -- Walk speed is eased toward, not snapped to, so a throw keeps its momentum.
        if self.onGround then
            local target = self.dir * Goomba.speed
            local step = Goomba.glide * delta
            if self.vx < target then
                self.vx = math.min(self.vx + step, target)
            else
                self.vx = math.max(self.vx - step, target)
            end
        end
        Entity.update(self, delta, level)
        if self.blockedX then
            self:turn()
        end
        self.facing = self.dir
    end
    self.animTime = self.animTime + delta
    self.frameIndex = math.floor(self.animTime / Goomba.frameTime) % #self.frames + 1
end

-- Landing on it kills it (the player then bounces). It squashes flat.
function Goomba:onStomp(player)
    return true
end

-- Touching it from the side or below kills the player.
function Goomba:onTouch(player)
    return true
end

-- A kick kills it; it is thrown away, spinning.
function Goomba:onKick(player)
    return true
end

return Goomba
