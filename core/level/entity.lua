-- Base class for entities defined by an individual level.
-- Shared collider, mass, movement and rendering live here.
local physics = require("core.physics")
local audio = require("core.audio")

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
    self.rotation = 0            -- draw rotation (radians); the collider stays axis-aligned
    self.flash = 0               -- 0..1: white silhouette drawn over the sprite

    return self
end

function Entity:update(delta, level)
    if self.held then
        return
    end

    delta = math.min(delta, 1 / 30)
    self.vy = math.min(self.vy + physics.gravity * delta, physics.maxFall)
    self:move(delta, level)
end

-- Move by velocity against level.statics, without gravity (for flyers).
-- Afterwards self.contacts holds every static that blocked the move.
function Entity:move(delta, level)
    physics.moveBody(self, level.statics, math.min(delta, 1 / 30))
end

-- True when something in level.statics lies just past this body's front edge
-- (in direction dir) and just below its feet: a walker can step on without falling.
function Entity:groundAhead(level, dir)
    local probe = { x = self.x + dir * (self.w / 2 + 2), y = self.y + self.h / 2 + 2, w = 2, h = 2 }
    for _, solid in ipairs(level.statics) do
        if physics.overlaps(probe, solid) then
            return true
        end
    end
    return false
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

-- Play a sound effect from assets/audio/sfx. Entity scripts have no audio
-- access of their own, so they go through this; only plain "name.wav" is allowed.
function Entity:playSfx(name)
    if type(name) == "string" and name:match("^[%w_]+%.wav$") then
        audio.playSfx(name)
    end
end

-- Draws a sprite's shape in the current color, ignoring its own colors.
local silhouetteShader
local function silhouette()
    silhouetteShader = silhouetteShader or love.graphics.newShader([[
        vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screen) {
            return vec4(color.rgb, color.a * Texel(tex, uv).a);
        }
    ]])
    return silhouetteShader
end

-- The sprite (current frame, if any) in the current color.
local function drawSprite(self)
    if self.frames then
        local f = self.frames[self.frameIndex]
        love.graphics.draw(self.image, f.quad, self.x, self.y, self.rotation,
            self.facing, 1, f.w / 2, f.h / 2)
    else
        love.graphics.draw(self.image, self.x, self.y, self.rotation, 1, 1,
            self.image:getWidth() / 2, self.image:getHeight() / 2)
    end
end

function Entity:draw()
    if not self.image then
        return
    end
    love.graphics.setColor(1, 1, 1, 1)
    drawSprite(self)
    if self.flash > 0 then
        love.graphics.setShader(silhouette())
        love.graphics.setColor(1, 1, 1, math.min(self.flash, 1))
        drawSprite(self)
        love.graphics.setShader()
    end
end

return Entity