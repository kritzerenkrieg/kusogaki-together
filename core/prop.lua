-- Carryable physics prop (potion, herb, crate...).
-- Center-based AABB body; while held, the player drives its transform and
-- physics is suspended (see player.attachCarried).
local physics = require("core.physics")
local mathx = require("core.math")

local prop = {}

prop.CONFIG = {
    friction     = 900, -- ground friction while sliding (px/s^2)
    restVelocity = 6,   -- snap to rest below this speed (px/s)
}

-- Create a prop at the given center position with optional styling.
function prop.new(x, y, options)
    options = options or {}
    local self = setmetatable({}, { __index = prop })
    self.x, self.y = x or 0, y or 0
    self.w = options.w or 16
    self.h = options.h or 16
    self.vx, self.vy = 0, 0
    self.onGround = false
    self.held = false
    self.label = options.label or "prop"
    self.color = options.color or { 0.86, 0.52, 0.24 }
    return self
end

function prop:update(delta, world)
    if self.held then
        return -- the player positions a held prop
    end

    delta = math.min(delta, 1 / 30)
    self.vy = math.min(self.vy + physics.gravity * delta, physics.maxFall)
    physics.moveBody(self, world.solids, delta)

    if self.onGround then
        self.vx = mathx.approach(self.vx, 0, prop.CONFIG.friction * delta)
        if math.abs(self.vx) < prop.CONFIG.restVelocity then
            self.vx = 0
        end
    end
end

-- Placeholder rendering: solid rounded square with a light label stripe.
function prop:draw()
    local left, top = self.x - self.w / 2, self.y - self.h / 2
    love.graphics.setColor(self.color)
    love.graphics.rectangle("fill", left, top, self.w, self.h, 3, 3)
    love.graphics.setColor(1, 1, 1, 0.35)
    love.graphics.rectangle("fill", left + 2, top + 2, self.w - 4, 3)
end

return prop