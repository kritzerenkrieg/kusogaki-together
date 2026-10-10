-- Entity type script: "spike", a static hazard. Runs in the sandbox; the base
-- class Entity is injected by core/level.lua.
local Spike = setmetatable({}, { __index = Entity })
Spike.__index = Spike

Spike.name = "spike"
Spike.kind = "hazard" -- "prop": dynamic body; "hazard": static solid that hurts
Spike.assetPath = "assets/graphics/entities/spike.png"
Spike.w, Spike.h = 16, 16 -- collision size (px), owned by the type
Spike.image = nil

function Spike.load()
    if not Spike.image then
        Spike.image = Entity.loadImage(Spike.assetPath)
    end
    return Spike.image
end

function Spike.new(x, y)
    return Entity.new(Spike, x, y, {
        name = Spike.name,
        image = Spike.image,
        w = Spike.w,
        h = Spike.h,
    })
end

-- Called by the scene while the player touches this hazard.
function Spike:onTouch(player)
    player:die()
end

return Spike
