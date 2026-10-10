-- Carrying props: grab (C), drop, throw (X while carrying), and keeping the held
-- prop at the player's hand. A held prop has no physics of its own.
local physics = require("core.physics")
local config = require("core.player.config")
local state = require("core.player.state")

local CONFIG = config.CONFIG
local HAND_OVERLAP = 4 -- px the held prop overlaps the player's facing edge

local carry = {}

-- Box used to find grabbable props in front of the player.
function carry.grabBox(self)
    return {
        x = self.x + self.facing * CONFIG.grabForward,
        y = self.y - 4,
        w = CONFIG.grabRange,
        h = CONFIG.grabRange,
    }
end

-- Nearest loose prop overlapping the grab box, or nil.
local function findGrabbable(self, world)
    local box = carry.grabBox(self)
    local best, bestDist = nil, math.huge
    for _, prop in ipairs(world.props) do
        if not prop.held and physics.overlaps(box, prop) then
            local dx, dy = prop.x - self.x, prop.y - self.y
            local dist = dx * dx + dy * dy
            if dist < bestDist then
                best, bestDist = prop, dist
            end
        end
    end
    return best
end

-- Carried prop's box when the player is at (x, y) with the given overlap.
local function carriedBox(self, x, y, overlap)
    local prop = self.carrying
    return {
        x = x + self.facing * (self.w / 2 + prop.w / 2 - overlap),
        y = y,
        w = prop.w,
        h = prop.h,
    }
end

-- True when the box overlaps no solid.
local function boxClear(box, solids)
    for _, solid in ipairs(solids) do
        if physics.overlaps(box, solid) then
            return false
        end
    end
    return true
end

-- Release the carried prop with the given velocity. The prop is first moved
-- out to touch the player (no overlap), so releasing cannot shove the player,
-- unless that spot is blocked by a solid.
local function release(self, vx, vy, solids)
    local prop = self.carrying
    if not prop then
        return
    end
    local free = carriedBox(self, self.x, self.y, 0)
    if boxClear(free, solids) then
        prop.x, prop.y = free.x, free.y
    end
    prop.held = false
    prop.vx, prop.vy = vx, vy
    self.carrying = nil
end

-- Grab on press (when not carrying) and drop on release.
function carry.update(self, edges, world)
    if edges.holdPressed and not self.carrying then
        local target = findGrabbable(self, world)
        if target then
            self.carrying = target
            target.held = true
            target.vx, target.vy = 0, 0
            state.emit(self, "grab")
        end
    end
    if edges.holdReleased and self.carrying then
        release(self, self.facing * 30, 0, world.solids) -- gentle drop
        state.emit(self, "drop")
    end
end

-- Throw the carried prop. Returns the thrown prop.
function carry.throw(self, vx, vy, solids)
    local thrown = self.carrying
    release(self, vx, vy, solids)
    return thrown
end

-- Glue the carried prop to the player's hands.
function carry.attach(self)
    local prop = self.carrying
    if not prop then
        return
    end
    local box = carriedBox(self, self.x, self.y, HAND_OVERLAP)
    prop.x, prop.y = box.x, box.y
    prop.vx, prop.vy = 0, 0
end

-- Prop to highlight as a grab hint, or nil.
function carry.hover(self, world)
    return not self.carrying and findGrabbable(self, world) or nil
end

return carry
