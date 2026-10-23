-- Entity type script: "dokan", a precision missile. It hovers at its spawn
-- until a player enters its trigger zone, then instantly flies straight to its
-- target point and explodes there (or on whatever it hits first). Runs in the
-- sandbox; the base class Entity is injected by core/level/loader.lua.
--
-- Placement:
--   { "type": "dokan", "x": 330, "y": 40,
--     "target": { "x": 370, "y": 330 },              -- required
--     "trigger": { "radius": 40, "x": 370, "y": 330 }, -- x/y default to target
--                                                      radius 0: never fires (a pickup)
--     "blast": 20,                                     -- optional kill radius
--     "speed": 600 }                                   -- optional flight speed (px/s)
local Dokan = setmetatable({}, { __index = Entity })
Dokan.__index = Dokan

Dokan.name = "dokan"
Dokan.kind = "enemy" -- stomp, kick or hit it with a prop to kill it; grab it to throw it back
Dokan.assetPath = "assets/dokan.png"
Dokan.w, Dokan.h = 14, 14   -- collider; the 16x24 sprite rotates around it
Dokan.speed = 300           -- flight speed (px/s), from the moment it launches
Dokan.triggerRadius = 48    -- default trigger radius (px)
Dokan.blastRadius = 32      -- default kill radius around the explosion (px)
Dokan.armSpeed = 100        -- released faster than this (px/s) it is a live projectile
Dokan.image = nil

function Dokan.load()
    if not Dokan.image then
        Dokan.image = Entity.loadImage(Dokan.assetPath)
    end
    return Dokan.image
end

function Dokan.new(x, y, def)
    def = def or {}
    if type(def.target) ~= "table" or not def.target.x or not def.target.y then
        error("dokan at " .. tostring(x) .. "," .. tostring(y) .. " needs a target { x, y }", 0)
    end
    local trigger = def.trigger or {}
    local self = Entity.new(Dokan, x, y, {
        name = Dokan.name,
        image = Dokan.image,
        w = Dokan.w,
        h = Dokan.h,
    })
    self.homeY = y
    self.targetX, self.targetY = def.target.x, def.target.y
    self.triggerX = trigger.x or self.targetX
    self.triggerY = trigger.y or self.targetY
    self.triggerRadius = trigger.radius or Dokan.triggerRadius
    self.blastRadius = def.blast or Dokan.blastRadius
    self.speed = def.speed or Dokan.speed
    -- idle -> flying. Grabbed: carried, then thrown (live) or dud (dropped).
    self.state = "idle"
    self.timer = 0
    return self
end

local function playerInTrigger(self, players)
    for _, player in ipairs(players or {}) do
        local dx, dy = player.x - self.triggerX, player.y - self.triggerY
        if not player.dead and dx * dx + dy * dy <= self.triggerRadius * self.triggerRadius then
            return true
        end
    end
    return false
end

-- Nose angle toward the target (the sprite's top is its nose).
local function aimAngle(self)
    return math.atan2(self.targetY - self.y, self.targetX - self.x) + math.pi / 2
end

function Dokan:update(delta, level)
    self.timer = self.timer + delta

    if self.held then
        self.state = "carried"
        self.rotation = self.facing * math.pi / 2 -- nose forward
        return
    end

    if self.state == "carried" then -- just released: thrown or merely dropped?
        local armed = math.abs(self.vx) + math.abs(self.vy) > Dokan.armSpeed
        self.state = armed and "thrown" or "dud"
    end

    if self.state == "thrown" then
        Entity.update(self, delta, level)
        self.rotation = math.atan2(self.vy, self.vx) + math.pi / 2
        if next(self.contacts) then
            self.detonated = true -- first wall, prop or enemy it hits
        end
        return
    end

    if self.state == "dud" then
        Entity.update(self, delta, level) -- falls like any thrown body
        if self.onGround then
            self.vx = self.vx * math.max(0, 1 - 8 * delta)
        end
        return
    end

    if self.state == "idle" then
        self.y = self.homeY + math.sin(self.timer * 3) * 2 -- hover bob
        if playerInTrigger(self, level.players) then
            self.state = "flying" -- launches this same frame, no lock-on delay
        end
    end
    if self.state == "flying" then
        local dx, dy = self.targetX - self.x, self.targetY - self.y
        local distance = math.sqrt(dx * dx + dy * dy)
        self.rotation = aimAngle(self)
        if distance <= self.speed * delta then
            self.x, self.y = self.targetX, self.targetY
            self.detonated = true
            return
        end
        self.vx, self.vy = dx / distance * self.speed, dy / distance * self.speed
        self:move(delta, level)
        if next(self.contacts) then
            self.detonated = true -- hit a wall, prop or enemy on the way
        end
    end
end

-- Touching an armed missile (hovering, flying or thrown) sets it off; a dud is harmless.
function Dokan:onTouch(player)
    if self.state ~= "dud" then
        self.detonated = true
    end
    return false
end

function Dokan:onStomp(player)
    return true
end

function Dokan:onKick(player)
    return true
end

return Dokan
