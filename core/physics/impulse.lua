-- Velocity response at a contact: a bounce or a settle along the contact normal,
-- and tangential friction between stacked bodies.
local config = require("core.physics.config")

local impulse = {}

-- Impulse along the contact normal. A slow contact settles (the upper body's
-- speed is clamped to the support's, so gravity cannot relaunch the stack);
-- a fast one bounces with restitution.
function impulse.resolveVelocity(a, b, normalX, normalY, restitution, inverseA, inverseB, inverseMassTotal)
    local relativeVelocity = (b.vx - a.vx) * normalX + (b.vy - a.vy) * normalY
    if relativeVelocity >= 0 then
        return -- already separating
    end
    if normalY ~= 0 and math.abs(relativeVelocity) <= config.restingSpeed then
        if normalY < 0 then
            b.vy = math.min(b.vy, a.vy) -- b is the upper body
        else
            a.vy = math.min(a.vy, b.vy) -- a is the upper body
        end
    else
        local bounce = restitution or config.restitution
        local magnitude = -(1 + bounce) * relativeVelocity / inverseMassTotal
        a.vx = a.vx - magnitude * normalX * inverseA
        a.vy = a.vy - magnitude * normalY * inverseA
        b.vx = b.vx + magnitude * normalX * inverseB
        b.vy = b.vy + magnitude * normalY * inverseB
    end
end

-- Dampen relative sideways motion on a vertical contact so boxes rest on one
-- another instead of skating apart. Not applied to the player: a player walking
-- on a prop must not drag it along. A body held sideways by a static this frame
-- (blockedX) counts as not moving sideways, and its speed is not changed here,
-- so a push that a static stopped cannot be carried up the stack.
function impulse.applyFriction(a, b, normalY, inverseA, inverseB, inverseMassTotal)
    if normalY == 0 or a.isPlayer or b.isPlayer then
        return
    end
    local aVx = a.blockedX and 0 or a.vx
    local bVx = b.blockedX and 0 or b.vx
    local frictionImpulse = (bVx - aVx) * config.contactFriction / inverseMassTotal
    if not a.blockedX then
        a.vx = a.vx + frictionImpulse * inverseA
    end
    if not b.blockedX then
        b.vx = b.vx - frictionImpulse * inverseB
    end
end

return impulse
