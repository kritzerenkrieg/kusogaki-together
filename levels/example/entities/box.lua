-- Entity type script: "box", a carryable prop. Runs in the sandbox; the base
-- classes Entity and Prop are injected by core/level.lua.
local Box = setmetatable({}, { __index = Prop })
Box.__index = Box

Box.name = "box"
Box.kind = "prop" -- "prop": dynamic body; "hazard": static solid that hurts
Box.assetPath = "levels/example/assets/box.png"
Box.w, Box.h = 16, 16 -- collision size (px), owned by the type
Box.image = nil

function Box.load()
    if not Box.image then
        Box.image = Entity.loadImage(Box.assetPath)
    end
    return Box.image
end

function Box.new(x, y)
    return Prop.create(Box, x, y, {
        name = Box.name,
        image = Box.image,
        w = Box.w,
        h = Box.h,
    })
end

return Box
