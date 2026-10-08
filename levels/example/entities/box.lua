-- Concrete example prop: the named "box" entity.
-- The type identity and its asset are intentionally defined together here.
local Entity = require("levels.example.entities.entity")
local Prop = require("levels.example.entities.prop")

local Box = setmetatable({}, { __index = Prop })
Box.__index = Box

Box.name = "box"
Box.assetPath = "levels/example/assets/box.png"
Box.image = nil

function Box.load()
    if not Box.image then
        Box.image = Entity.loadImage(Box.assetPath)
    end
    return Box.image
end

function Box.new(x, y, options)
    options = options or {}
    options.name = Box.name
    options.image = options.image or Box.image
    return Prop.create(Box, x, y, options)
end

return Box