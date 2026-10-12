-- Entity type script: "brick", a static block the player can break from below.
-- Runs in the sandbox; the base class Entity is injected by core/level/loader.lua.
local Brick = setmetatable({}, { __index = Entity })
Brick.__index = Brick

Brick.name = "brick"
Brick.kind = "block" -- static like a hazard, but touching it is not fatal
Brick.assetPath = "levels/example/assets/brick.png"
Brick.w, Brick.h = 16, 16 -- collision size (px), owned by the type
Brick.image = nil

function Brick.load()
    if not Brick.image then
        Brick.image = Entity.loadImage(Brick.assetPath)
    end
    return Brick.image
end

function Brick.new(x, y)
    return Entity.new(Brick, x, y, {
        name = Brick.name,
        image = Brick.image,
        w = Brick.w,
        h = Brick.h,
    })
end

-- Called by the scene while the player touches this block. Returns true to
-- break it: only a player rising into the underside breaks it, not a landing.
function Brick:onTouch(player)
    local underside = self.y + self.h / 2
    local wasBelow = player.prevY - player.h / 2 >= underside - 1
    return player.movingUp and wasBelow
end

-- Called when the player's kick hitbox reaches this block. A kick always breaks it.
function Brick:onKick(player)
    return true
end

return Brick
