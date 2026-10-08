-- Base class for entities defined by an individual level.
-- Shared collider, mass, movement and rendering live here.
local physics = require("core.physics")

local Entity = {}
Entity.__index = Entity

function Entity.loadImage(path)
    local image = love.graphics.newImage(path)
    image:setFilter("nearest", "nearest")
    return image
end

function Entity.new(class, x, y, options)
    options = options or {}
    local image = options.image
    local self = setmetatable({}, class or Entity)

    self.x, self.y = x or 0, y or 0
    self.image = image
    self.w = options.w or (image and image:getWidth()) or 16
    self.h = options.h or (image and image:getHeight()) or 16
    self.mass = physics.massFromSize(self.w, self.h, options.density)
    self.vx, self.vy = 0, 0
    self.onGround = false
    self.held = false
    self.name = options.name or "entity"

    return self
end

function Entity:update(delta, world)
    if self.held then
        return
    end

    delta = math.min(delta, 1 / 30)
    self.vy = math.min(self.vy + physics.gravity * delta, physics.maxFall)
    physics.moveBody(self, world.solids, delta)
end

function Entity:draw()
    if self.image then
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.draw(
            self.image,
            self.x,
            self.y,
            0,
            1,
            1,
            self.image:getWidth() / 2,
            self.image:getHeight() / 2
        )
    end
end

return Entity