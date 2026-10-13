-- Entity type script: "dodon", a walking enemy. Runs in the sandbox; the base
-- class Entity is injected by core/level/loader.lua.
local Dodon = setmetatable({}, { __index = Entity })
Dodon.__index = Dodon

Dodon.name = "dodon"
Dodon.kind = "enemy" -- walks on statics, props and other enemies; stomp or kick to kill it, touch to die
Dodon.assetPath = "assets/dodon.png" -- 2 walk frames side by side
Dodon.w, Dodon.h = 16, 16 -- one frame of the sheet
Dodon.speed = 40           -- walk speed (px/s)
Dodon.frameTime = 0.2      -- seconds per walk frame
Dodon.glide = 300          -- how fast launch speed eases back to walking (px/s^2)
Dodon.image = nil
Dodon.frames = nil

function Dodon.load()
    if not Dodon.image then
        Dodon.image = Entity.loadImage(Dodon.assetPath)
        Dodon.frames = Entity.sliceFrames(Dodon.image, Dodon.w, Dodon.h)
    end
    return Dodon.image
end

function Dodon.new(x, y)
    local self = Entity.new(Dodon, x, y, {
        name = Dodon.name,
        image = Dodon.image,
        frames = Dodon.frames,
        w = Dodon.w,
        h = Dodon.h,
    })
    self.dir = 1          -- walking direction: 1 right, -1 left
    self.animTime = 0     -- drives the walk animation
    return self
end

-- Reverse direction.
function Dodon:turn()
    self.dir = -self.dir
end

-- Walk, turn around when blocked by a static, prop or enemy or at a ledge, and
-- advance the walk frame. `level.statics` is what this enemy collides with (the level passes
-- statics plus the other solid bodies). Airborne (thrown or falling) it keeps
-- its launch speed; on the ground that speed eases back to the walk speed.
function Dodon:update(delta, level)
    if self.held then
        self.dir = self.facing -- carried: face where the player faces
    else
        -- Walk speed is eased toward, not snapped to, so a throw keeps its momentum.
        if self.onGround then
            local target = self.dir * Dodon.speed
            local step = Dodon.glide * delta
            if self.vx < target then
                self.vx = math.min(self.vx + step, target)
            else
                self.vx = math.max(self.vx - step, target)
            end
        end
        Entity.update(self, delta, level)
        if self.blockedX then
            self:turn()
        elseif self.onGround and not self:groundAhead(level, self.dir) then
            self:turn() -- ledge ahead: never walk off
        end
        self.facing = self.dir
    end
    self.animTime = self.animTime + delta
    self.frameIndex = math.floor(self.animTime / Dodon.frameTime) % #self.frames + 1
end

-- Landing on it kills it (the player then bounces). It squashes flat.
function Dodon:onStomp(player)
    return true
end

-- Touching it from the side or below kills the player.
function Dodon:onTouch(player)
    return true
end

-- A kick kills it; it is thrown away, spinning.
function Dodon:onKick(player)
    return true
end

return Dodon
