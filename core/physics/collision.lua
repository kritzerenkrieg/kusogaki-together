-- Dynamic body collision: resolves overlapping pairs of bodies, then settles
-- every body against statics.
local geometry = require("core.physics.geometry")
local mass = require("core.physics.mass")
local impulse = require("core.physics.impulse")
local oneway = require("core.physics.oneway")
local staticContact = require("core.physics.statics")

local collision = {}

-- Contact normal and penetration depth for an overlapping pair. The axis comes
-- from the center offset (see geometry.pushesHorizontally), so stacked bodies
-- resolve vertically and side-by-side bodies resolve horizontally, regardless of
-- which overlap is numerically smaller.
local function contactNormal(a, b, dx, dy, overlapX, overlapY)
    if geometry.pushesHorizontally(a, b) then
        return dx >= 0 and 1 or -1, 0, overlapX
    end
    return 0, dy >= 0 and 1 or -1, overlapY
end

-- Rule: a body whose corrected position would sit inside a static gets no share
-- of the correction, so the other body takes all of it. Of two free bodies, the
-- player absorbs the correction, so the prop's motion is not dragged by walking.
-- Returns the separation weight for a and b (inverse masses, zero = not moved).
local function separationShares(a, b, normalX, normalY, penetration, inverseA, inverseB, statics)
    local sepA, sepB = inverseA, inverseB
    if statics then
        if geometry.overlapsAny(geometry.movedRect(a, -normalX * penetration, -normalY * penetration), statics) then
            sepA = 0
        end
        if geometry.overlapsAny(geometry.movedRect(b, normalX * penetration, normalY * penetration), statics) then
            sepB = 0
        end
    end
    if sepA > 0 and sepB > 0 then
        if a.isPlayer then
            sepB = 0
        elseif b.isPlayer then
            sepA = 0
        end
    end
    return sepA, sepB
end

-- Set onGround on the body standing on top. A player only counts as grounded
-- when their feet sit at the other body's top face; a contact in the middle of
-- the body (wedged against a stack seam) must not read as standing.
local function updateGrounding(a, b, normalY, player, platformTop)
    local playerBottom = player and player.y + player.h / 2
    if normalY > 0 and (not player or playerBottom <= platformTop + 0.5) then
        a.onGround = true
    end
    if normalY < 0 then
        b.onGround = true
    end
end

-- Resolve one dynamic AABB against another using minimum translation and a
-- one-dimensional impulse along the shallowest penetration axis. Bodies may
-- optionally provide a mass; otherwise their mass is derived from w * h.
-- Static bodies are not moved and behave as infinite-mass objects. Held bodies
-- are skipped: the player owns their position while carrying them.
function collision.resolveBodyCollision(a, b, restitution, bodies, statics)
    if a.held or b.held or not geometry.overlaps(a, b) then
        return false
    end

    local dx, dy = b.x - a.x, b.y - a.y
    local player, platform = oneway.playerPair(a, b)
    if player and oneway.tryLanding(player, platform, bodies) then
        return true
    end

    local overlapX = (a.w + b.w) / 2 - math.abs(dx)
    local overlapY = (a.h + b.h) / 2 - math.abs(dy)
    if overlapX <= 0 or overlapY <= 0 then
        return false
    end

    local normalX, normalY, penetration = contactNormal(a, b, dx, dy, overlapX, overlapY)
    local inverseA, inverseB = mass.inverse(a), mass.inverse(b)
    local inverseMassTotal = inverseA + inverseB
    if inverseMassTotal == 0 then
        return false
    end

    -- Separate the bodies so they cannot remain interpenetrating. If neither
    -- body can take the correction without entering a static, it is skipped.
    local sepA, sepB = separationShares(a, b, normalX, normalY, penetration,
        inverseA, inverseB, statics)
    local sepTotal = sepA + sepB
    if sepTotal > 0 then
        local correctionA = penetration * sepA / sepTotal
        local correctionB = penetration * sepB / sepTotal
        a.x = a.x - normalX * correctionA
        a.y = a.y - normalY * correctionA
        b.x = b.x + normalX * correctionB
        b.y = b.y + normalY * correctionB
    end

    impulse.resolveVelocity(a, b, normalX, normalY, restitution, inverseA, inverseB, inverseMassTotal)
    impulse.applyFriction(a, b, normalY, inverseA, inverseB, inverseMassTotal)
    updateGrounding(a, b, normalY, player, platform and (platform.y - platform.h / 2))
    return true
end

-- Move `mover` out of `fixed`; `fixed` never moves. See ARCHITECTURE.md
-- (Physics rules: push-out). Returns false when nothing moved.
function collision.pushOut(mover, fixed, statics)
    if not geometry.overlaps(mover, fixed) then
        return false
    end
    local side = mover.x >= fixed.x and 1 or -1
    local sideX = fixed.x + side * (fixed.w + mover.w) / 2
    local otherX = fixed.x - side * (fixed.w + mover.w) / 2
    local topY = fixed.y - (fixed.h + mover.h) / 2
    local exits
    if geometry.pushesHorizontally(mover, fixed) then
        exits = {
            { x = sideX, y = mover.y, axis = "x" },
            { x = mover.x, y = topY, axis = "y" },
            { x = otherX, y = mover.y, axis = "x" },
        }
    else
        exits = {
            { x = mover.x, y = topY, axis = "y" },
            { x = sideX, y = mover.y, axis = "x" },
            { x = otherX, y = mover.y, axis = "x" },
        }
    end
    for _, exit in ipairs(exits) do
        local probe = { x = exit.x, y = exit.y, w = mover.w, h = mover.h }
        if not (statics and geometry.overlapsAny(probe, statics)) then
            mover.x, mover.y = exit.x, exit.y
            if exit.axis == "y" then
                mover.vy = math.min(mover.vy, fixed.vy or 0)
                mover.onGround = true
            elseif (exit.x - fixed.x) * (mover.vx - (fixed.vx or 0)) < 0 then
                mover.vx = fixed.vx or 0
            end
            return true
        end
    end
    return false
end

-- Resolve every dynamic body pair once, then settle against statics.
function collision.resolveBodyCollisions(bodies, statics, restitution, iterations)
    -- Dense box clusters need more than a few passes for contact corrections
    -- to propagate through the whole stack instead of depending on pair order.
    iterations = iterations or 8
    for _ = 1, iterations do
        for i = 1, #bodies - 1 do
            for j = i + 1, #bodies do
                collision.resolveBodyCollision(bodies[i], bodies[j], restitution, bodies, statics)
            end
        end

        if statics then
            for _, body in ipairs(bodies) do
                staticContact.resolveBodyAgainstStatics(body, statics)
            end
        end
    end
end

return collision
