-- Shared AABB physics for the platformer: world gravity, overlap tests and
-- per-axis movement resolution against static rectangles.
-- Bodies and statics are center-based: { x, y, w, h }.
--
-- Callers use require("core.physics"). The modules in this folder:
--   config     tuning constants
--   geometry   overlap tests, displaced rectangles, contact records
--   mass       mass from size, inverse mass
--   movement   sweeping a body by its velocity against statics
--   statics    exiting overlap with static geometry
--   oneway     props as one-way platforms for the player
--   impulse    contact velocity response and friction
--   collision  dynamic body pairs and the full collision pass
local config = require("core.physics.config")
local geometry = require("core.physics.geometry")
local mass = require("core.physics.mass")
local movement = require("core.physics.movement")
local staticContact = require("core.physics.statics")
local collision = require("core.physics.collision")

local physics = {}

physics.gravity = config.gravity
physics.maxFall = config.maxFall
physics.restitution = config.restitution
physics.restingSpeed = config.restingSpeed
physics.contactFriction = config.contactFriction

physics.massFromSize = mass.fromSize
physics.bodyMass = mass.ofBody

physics.overlaps = geometry.overlaps

physics.moveBody = movement.moveBody

physics.resolveBodyAgainstStatics = staticContact.resolveBodyAgainstStatics

physics.resolveBodyCollision = collision.resolveBodyCollision
physics.resolveBodyCollisions = collision.resolveBodyCollisions
physics.pushOut = collision.pushOut

-- Apply gravity to body.vy for `delta` seconds: the level's gravity
-- (level.gravity, default physics.gravity) times the body's own gravityScale
-- (default 1), capped at level.maxFall. A level with gravity 0 has none (space,
-- underwater); a body with gravityScale -1 falls upward (balloons).
function physics.fall(body, level, delta)
    local gravity = (level and level.gravity or config.gravity) * (body.gravityScale or 1)
    body.vy = math.min(body.vy + gravity * delta, level and level.maxFall or config.maxFall)
end

return physics
