-- Entity type script: "dambo", a rifleman. It stands still until a player is in
-- sight, then walks toward them when they are far and away from them when they
-- are close, keeping its distance, and fires once a second while the
-- player is in range and about level with it. It only sets `fire`; the level
-- script (scripts/guns.lua) spawns the bullet and the muzzle flash. Stomp or
-- kick it to kill it, touch it to die. Runs in the sandbox; the base class
-- Entity is injected by core/level/loader.lua.
local Dambo = setmetatable({}, { __index = Entity })
Dambo.__index = Dambo

Dambo.name = "dambo"
Dambo.kind = "enemy"
Dambo.assetPath = "assets/dambo.png" -- 2 walk frames side by side
Dambo.w, Dambo.h = 16, 16
Dambo.speed = 38        -- walk speed (px/s)
Dambo.frameTime = 0.2   -- seconds per walk frame
Dambo.glide = 300       -- how fast speed eases to the walk speed (px/s^2)
Dambo.sight = 260       -- sees players this far away (px)
Dambo.keepFar = 130     -- walks closer when the player is farther than this
Dambo.keepNear = 80     -- backs away when the player is nearer than this
Dambo.fireRange = 200   -- shoots at players within this distance (px)
Dambo.aimTolerance = 40 -- ... and this far above or below it (px)
Dambo.fireEvery = 1.0   -- seconds between shots
Dambo.windUp = 0.4      -- seconds from taking aim to the first shot
Dambo.image = nil
Dambo.frames = nil

function Dambo.load()
    if not Dambo.image then
        Dambo.image = Entity.loadImage(Dambo.assetPath)
        Dambo.frames = Entity.sliceFrames(Dambo.image, Dambo.w, Dambo.h)
    end
    return Dambo.image
end

function Dambo.new(x, y)
    local self = Entity.new(Dambo, x, y, {
        name = Dambo.name,
        image = Dambo.image,
        frames = Dambo.frames,
        w = Dambo.w,
        h = Dambo.h,
    })
    self.facing = -1
    self.animTime = 0
    self.cooldown = Dambo.windUp
    self.fire = false -- set when a shot is due; the level script takes it
    return self
end

-- Where the gun in the sprite points from.
function Dambo:muzzle()
    return self.x + self.facing * 10, self.y + 2
end

local function nearestPlayer(self, level)
    local best, bestDistance
    for _, player in ipairs(level.players or {}) do
        local distance = math.abs(player.x - self.x)
        if not player.dead and distance <= Dambo.sight and (not best or distance < bestDistance) then
            best, bestDistance = player, distance
        end
    end
    return best
end

function Dambo:update(delta, level)
    if self.held then
        self.facing = self.facing -- carried: the player turns it
    else
        local target = nearestPlayer(self, level)
        local want = 0 -- walking direction: -1, 0 or 1
        if target then
            local dx = target.x - self.x
            local distance = math.abs(dx)
            local toward = dx < 0 and -1 or 1
            self.facing = toward
            if distance > Dambo.keepFar then
                want = toward
            elseif distance < Dambo.keepNear then
                want = -toward
            end
            if self.onGround and want ~= 0 and (self.blockedX or not self:groundAhead(level, want)) then
                want = 0 -- never walks off a ledge or into a wall
            end
            if distance <= Dambo.fireRange and math.abs(target.y - self.y) <= Dambo.aimTolerance then
                self.cooldown = self.cooldown - delta
                if self.cooldown <= 0 then
                    self.fire = true
                    self.cooldown = Dambo.fireEvery
                end
            else
                self.cooldown = math.max(self.cooldown, Dambo.windUp)
            end
        end
        if self.onGround then
            local goal = want * Dambo.speed
            local step = Dambo.glide * delta
            if self.vx < goal then
                self.vx = math.min(self.vx + step, goal)
            else
                self.vx = math.max(self.vx - step, goal)
            end
        end
        Entity.update(self, delta, level)
        self.moving = want ~= 0
    end
    if self.moving then
        self.animTime = self.animTime + delta
        self.frameIndex = math.floor(self.animTime / Dambo.frameTime) % #self.frames + 1
    else
        self.frameIndex = 1
    end
end

function Dambo:onStomp(player)
    return true
end

function Dambo:onTouch(player)
    return true
end

function Dambo:onKick(player)
    return true
end

return Dambo
