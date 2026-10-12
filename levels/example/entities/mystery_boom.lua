-- Entity type script: "mystery_boom", a "?" block that is a trap; it behaves
-- exactly like fake_brick.
-- Runs in the sandbox; the base class Entity is injected by core/level/loader.lua.
local MysteryBoom = setmetatable({}, { __index = Entity })
MysteryBoom.__index = MysteryBoom

MysteryBoom.name = "mystery_boom"
MysteryBoom.kind = "block"
MysteryBoom.explosive = true -- breaking it explodes and kills the player
MysteryBoom.assetPath = "levels/example/assets/mystery.png" -- 3 frames: 1-2 idle loop, 3 triggered (unused)
MysteryBoom.w, MysteryBoom.h = 16, 16 -- one frame of the sheet
MysteryBoom.idleFrames = 2            -- frames 1..idleFrames loop while idle
MysteryBoom.frameTime = 0.3           -- seconds per idle frame
MysteryBoom.image = nil
MysteryBoom.frames = nil

function MysteryBoom.load()
    if not MysteryBoom.image then
        MysteryBoom.image = Entity.loadImage(MysteryBoom.assetPath)
        MysteryBoom.frames = Entity.sliceFrames(MysteryBoom.image, MysteryBoom.w, MysteryBoom.h)
    end
    return MysteryBoom.image
end

function MysteryBoom.new(x, y)
    local self = Entity.new(MysteryBoom, x, y, {
        name = MysteryBoom.name,
        image = MysteryBoom.image,
        frames = MysteryBoom.frames,
        w = MysteryBoom.w,
        h = MysteryBoom.h,
    })
    self.animTime = 0 -- every block starts at 0, so they all shimmer in sync
    return self
end

-- Idle shimmer between frames 1 and 2.
function MysteryBoom:animate(delta)
    self.animTime = self.animTime + delta
    self.frameIndex = math.floor(self.animTime / MysteryBoom.frameTime) % MysteryBoom.idleFrames + 1
end

-- Any contact sets it off: landing on it, walking into it, or hitting it.
function MysteryBoom:onTouch(player)
    return true
end

function MysteryBoom:onKick(player)
    return true
end

return MysteryBoom
