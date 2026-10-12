-- Entity type script: "fake_brick", a trap that looks exactly like a brick.
-- Runs in the sandbox; the base class Entity is injected by core/level/loader.lua.
local FakeBrick = setmetatable({}, { __index = Entity })
FakeBrick.__index = FakeBrick

FakeBrick.name = "fake_brick"
FakeBrick.kind = "block"
FakeBrick.explosive = true -- breaking it explodes and kills the player
FakeBrick.assetPath = "levels/example/assets/brick.png"
FakeBrick.w, FakeBrick.h = 16, 16
FakeBrick.image = nil

function FakeBrick.load()
    if not FakeBrick.image then
        FakeBrick.image = Entity.loadImage(FakeBrick.assetPath)
    end
    return FakeBrick.image
end

function FakeBrick.new(x, y)
    return Entity.new(FakeBrick, x, y, {
        name = FakeBrick.name,
        image = FakeBrick.image,
        w = FakeBrick.w,
        h = FakeBrick.h,
    })
end

-- Any contact sets it off: landing on it, walking into it, or hitting it.
function FakeBrick:onTouch(player)
    return true
end

function FakeBrick:onKick(player)
    return true
end

return FakeBrick
