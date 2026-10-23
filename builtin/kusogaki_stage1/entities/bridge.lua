-- Entity type script: "bridge", an invisible solid block of any size (the
-- placement's w and h). Nothing is drawn; players and enemies stand on it.
-- Runs in the sandbox; the base class Entity is injected by
-- core/level/loader.lua.
--
-- Placement: { "type": "bridge", "x": 1952, "y": 286, "w": 64, "h": 16 }
local Bridge = setmetatable({}, { __index = Entity })
Bridge.__index = Bridge

Bridge.name = "bridge"
Bridge.kind = "block"

function Bridge.new(x, y, def)
    def = def or {}
    return Entity.new(Bridge, x, y, {
        name = Bridge.name,
        w = def.w or 16,
        h = def.h or 16,
    })
end

-- It never breaks.
function Bridge:onTouch(player)
    return false
end

function Bridge:onKick(player)
    return false
end

return Bridge
