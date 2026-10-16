-- Entity type script: "metal", a solid block that never breaks (the level's
-- metal tiles as an entity, for scripts that place one at runtime). Runs in
-- the sandbox; the base class Entity is injected by core/level/loader.lua.
local Metal = setmetatable({}, { __index = Entity })
Metal.__index = Metal

Metal.name = "metal"
Metal.kind = "block"
Metal.assetPath = "assets/metal.png"
Metal.w, Metal.h = 16, 16
Metal.image = nil

function Metal.load()
    if not Metal.image then
        Metal.image = Entity.loadImage(Metal.assetPath)
    end
    return Metal.image
end

function Metal.new(x, y)
    return Entity.new(Metal, x, y, {
        name = Metal.name,
        image = Metal.image,
        w = Metal.w,
        h = Metal.h,
    })
end

-- Hitting it from below or kicking it does nothing.
function Metal:onTouch(player)
    return false
end

function Metal:onKick(player)
    return false
end

return Metal
