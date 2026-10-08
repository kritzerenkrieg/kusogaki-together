-- Prop entity type.
-- Hierarchy: Entity -> Prop -> Box (and future concrete prop types).
local mathx = require("core.math")
local Entity = require("levels.example.entities.entity")

local Prop = setmetatable({}, { __index = Entity })
Prop.__index = Prop

Prop.CONFIG = {
    friction = 900,
    restVelocity = 6,
}

function Prop.create(class, x, y, options)
    options = options or {}
    local self = Entity.new(class or Prop, x, y, options)
    self.name = options.name or "prop"
    self.label = options.label or self.name
    self.color = options.color or { 0.86, 0.52, 0.24 }
    return self
end

function Prop.new(x, y, options)
    return Prop.create(Prop, x, y, options)
end

function Prop:update(delta, world)
    Entity.update(self, delta, world)

    if self.held then return end

    if self.onGround then
        self.vx = mathx.approach(self.vx, 0, Prop.CONFIG.friction * delta)
        if math.abs(self.vx) < Prop.CONFIG.restVelocity then
            self.vx = 0
        end
    end
end

function Prop:draw()
    if self.image then
        Entity.draw(self)
        return
    end

    -- Safe fallback for class-level tests before the image is loaded.
    local left, top = self.x - self.w / 2, self.y - self.h / 2
    love.graphics.setColor(self.color)
    love.graphics.rectangle("fill", left, top, self.w, self.h, 3, 3)
end

return Prop