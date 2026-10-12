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

-- Cut a horizontal sprite sheet into frames of frameW x frameH. Each frame is
-- { quad, x, y, w, h } with its position in the sheet.
function Entity.sliceFrames(image, frameW, frameH)
    local iw, ih = image:getDimensions()
    local frames = {}
    for x = 0, iw - frameW, frameW do
        frames[#frames + 1] = {
            quad = love.graphics.newQuad(x, 0, frameW, frameH, iw, ih),
            x = x, y = 0, w = frameW, h = frameH,
        }
    end
    return frames
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
    self.frames = options.frames -- optional sprite-sheet frames (see sliceFrames)
    self.frameIndex = 1          -- frame to draw while frames are in use
    self.facing = 1              -- -1 mirrors the sprite horizontally

    return self
end

function Entity:update(delta, level)
    if self.held then
        return
    end

    delta = math.min(delta, 1 / 30)
    self.vy = math.min(self.vy + physics.gravity * delta, physics.maxFall)
    physics.moveBody(self, level.statics, delta)
end

-- Sheet rectangle (pixels) of what is currently drawn, for debris to cut from.
function Entity:region()
    if not self.image then
        return nil
    end
    if self.frames then
        local f = self.frames[self.frameIndex]
        return { x = f.x, y = f.y, w = f.w, h = f.h }
    end
    return { x = 0, y = 0, w = self.image:getWidth(), h = self.image:getHeight() }
end

function Entity:draw()
    if self.frames then
        local f = self.frames[self.frameIndex]
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.draw(self.image, f.quad, self.x, self.y, 0,
            self.facing, 1, f.w / 2, f.h / 2)
        return
    end
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