-- Entity type script: "bullet", a rifle shot. It flies straight along `dir`
-- and kills the player it touches. The level script (scripts/guns.lua) moves
-- it, and takes it away when it hits a wall or has flown too long. Runs in the
-- sandbox; the base class Entity is injected by core/level/loader.lua.
--
-- Placement (spawned by a dambo's rifle):
--   { "dir": 1 }                                         -- 1 right, -1 left
local Bullet = setmetatable({}, { __index = Entity })
Bullet.__index = Bullet

Bullet.name = "bullet"
Bullet.kind = "trigger"
Bullet.w, Bullet.h = 8, 3
Bullet.speed = 260 -- px/s
Bullet.life = 1.8  -- seconds in the air

function Bullet.new(x, y, def)
    local self = Entity.new(Bullet, x, y, { name = Bullet.name, w = Bullet.w, h = Bullet.h })
    self.dir = (def and def.dir == -1) and -1 or 1
    self.age = 0
    return self
end

function Bullet:onTouch(player, level)
    player:die()
    self:bulletImpact(self.dir)
    level:removeEntity(self)
end

-- A tracer: a fading streak behind a bright slug.
function Bullet:draw(ui)
    local d = self.dir
    local x, y = self.x, self.y
    for i = 1, 3 do
        ui.color(1, 0.8, 0.3, 0.45 - i * 0.12)
        ui.rect(d > 0 and x - 4 - i * 4 or x + 4 + (i - 1) * 4, y - 1, 4, 2)
    end
    ui.color(1, 0.85, 0.35, 1)
    ui.rect(x - 4, y - 1.5, 8, 3)
    ui.color(1, 1, 0.9, 1)
    ui.rect(d > 0 and x or x - 4, y - 0.5, 4, 1)
end

return Bullet
