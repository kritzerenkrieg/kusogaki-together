-- Shared AABB physics for the platformer: world gravity, overlap tests and
-- per-axis movement resolution against solid rectangles.
-- Bodies and solids are center-based: { x, y, w, h }.
local physics = {}

physics.gravity = 1500  -- px/s^2 pulling bodies down
physics.maxFall = 420   -- terminal fall speed (px/s)
physics.restitution = 0.35 -- bounciness for dynamic body collisions
physics.restingSpeed = 70 -- vertical speed below this settles instead of bouncing
physics.contactFriction = 0.35 -- tangential damping while resting on another body
physics.axisBias = 1 -- px: the horizontal MTV axis must be this much shallower
                     -- than the vertical one to win; near-ties resolve
                     -- vertically so sub-pixel offsets cannot shear a stacked
                     -- box sideways out of its stack

-- Use collider/image area as mass. A larger image therefore carries more
-- momentum and is harder to push around than a smaller one.
function physics.massFromSize(width, height, density)
    return math.max(1, (width or 1) * (height or 1) * (density or 1))
end

function physics.bodyMass(body)
    if body.static then
        return math.huge
    end
    body.mass = body.mass or physics.massFromSize(body.w, body.h, body.density)
    return body.mass
end

-- Overlap test between two center-based AABBs; touching edges do not count.
function physics.overlaps(a, b)
    return math.abs(a.x - b.x) * 2 < (a.w + b.w)
        and math.abs(a.y - b.y) * 2 < (a.h + b.h)
end

-- One small movement step. Keeping this separate lets moveBody use several
-- substeps at high velocity, which prevents a body from tunneling through a
-- thin platform or another object between frames.
local function moveBodyStep(body, solids, delta)
    body.x = body.x + body.vx * delta
    for _, solid in ipairs(solids) do
        if physics.overlaps(body, solid) then
            if body.vx > 0 then
                body.x = solid.x - solid.w / 2 - body.w / 2 -- hit left face
            elseif body.vx < 0 then
                body.x = solid.x + solid.w / 2 + body.w / 2 -- hit right face
            elseif body.x < solid.x then
                body.x = solid.x - solid.w / 2 - body.w / 2
            else
                body.x = solid.x + solid.w / 2 + body.w / 2
            end
            body.vx = 0
        end
    end

    body.onGround = false
    body.y = body.y + body.vy * delta
    for _, solid in ipairs(solids) do
        if physics.overlaps(body, solid) then
            if body.vy >= 0 then
                body.y = solid.y - solid.h / 2 - body.h / 2 -- landed on top
                body.vy = 0
                body.onGround = true
            else
                body.y = solid.y + solid.h / 2 + body.h / 2 -- bumped a ceiling
                body.vy = 0
            end
        end
    end
end

-- Move body by its velocity for delta seconds, resolving collisions against
-- solids one axis at a time. High-speed bodies use smaller substeps instead
-- of being corrected from deep inside a collider after they have passed it.
function physics.moveBody(body, solids, delta)
    body.prevX, body.prevY = body.x, body.y
    local smallestSide = math.max(1, math.min(body.w, body.h))
    local travel = math.max(math.abs(body.vx), math.abs(body.vy)) * delta
    local steps = math.min(8, math.max(1, math.ceil(travel / (smallestSide * 0.5))))
    local stepDelta = delta / steps

    for _ = 1, steps do
        moveBodyStep(body, solids, stepDelta)
    end
end

-- Side (-1 or +1) to push a body out of a solid along one axis. Prefer the side
-- the body came from: a body wedged past the solid's center would otherwise be
-- pushed back out the far side (e.g. out of the level through an edge wall).
local function escapeSign(prevCenter, bodyHalf, solidCenter, solidHalf, center)
    if prevCenter + bodyHalf <= solidCenter - solidHalf then
        return -1
    end
    if prevCenter - bodyHalf >= solidCenter + solidHalf then
        return 1
    end
    return center >= solidCenter and 1 or -1
end

-- True when the body overlaps at least one solid.
local function overlapsAny(body, solids)
    for _, solid in ipairs(solids) do
        if physics.overlaps(body, solid) then
            return true
        end
    end
    return false
end

-- Remove overlap with static level solids without applying a bounce. This is
-- used after dynamic collisions because a pair correction can otherwise push
-- one body slightly into the floor or a wall.
function physics.resolveBodyAgainstSolids(body, solids)
    if body.held then
        return -- a held body belongs to the player's collision, not its own
    end
    for _, solid in ipairs(solids) do
        if physics.overlaps(body, solid) then
            local dx = body.x - solid.x
            local dy = body.y - solid.y
            local overlapX = (body.w + solid.w) / 2 - math.abs(dx)
            local overlapY = (body.h + solid.h) / 2 - math.abs(dy)

            if overlapX < overlapY - physics.axisBias then
                local direction = escapeSign(body.prevX or body.x, body.w / 2,
                    solid.x, solid.w / 2, body.x)
                body.x = body.x + direction * overlapX
                body.vx = 0
            else
                local direction = escapeSign(body.prevY or body.y, body.h / 2,
                    solid.y, solid.h / 2, body.y)
                body.y = body.y + direction * overlapY
                body.vy = 0
                if direction < 0 then
                    body.onGround = true
                end
            end
        end
    end
end

-- True when the position the player would be snapped to on top of a platform
-- is not occupied by another body. On a vertically stacked pair the lower
-- box's top plane lies inside the upper box; snapping the player there would
-- wedge them between the boxes with onGround stuck true (standing on an
-- "invisible" floor at the seam), so the snap must only fire on a free spot.
local function landingIsClear(player, platform, platformTop, bodies)
    if not bodies then
        return true
    end
    local landing = {
        x = player.x,
        y = platformTop - player.h / 2,
        w = player.w,
        h = player.h,
    }
    for _, other in ipairs(bodies) do
        if other ~= player and other ~= platform and not other.held
            and physics.overlaps(landing, other) then
            return false
        end
    end
    return true
end

-- Rule: props act as one-way platforms for the player. Returns the pair as
-- (player, other) when exactly one of a/b is the player, otherwise nil.
local function playerPair(a, b)
    if a.isPlayer and not b.isPlayer then
        return a, b
    elseif b.isPlayer and not a.isPlayer then
        return b, a
    end
    return nil
end

-- Rule: on descent, a player whose feet cross a prop's top lands on it. Only the
-- player's vertical position is resolved, so walking across a box top cannot push
-- the supporting box or its neighboring stack sideways. Returns true when handled.
local function tryOneWayLanding(player, platform, bodies)
    local previousPlayerBottom = (player.prevY or player.y) + player.h / 2
    local playerBottom = player.y + player.h / 2
    local platformTop = platform.y - platform.h / 2
    if player.vy >= platform.vy
        and previousPlayerBottom <= platformTop
        and playerBottom >= platformTop
        and landingIsClear(player, platform, platformTop, bodies) then
        player.y = platformTop - player.h / 2
        player.vy = math.min(player.vy, platform.vy)
        player.onGround = true
        return true
    end
    return false
end

-- Minimum-translation normal and penetration depth for an overlapping pair.
-- A vertical overlap spanning the smaller body's full height means the contact
-- is at a stack seam: resolve vertically even when the horizontal axis is
-- marginally shallower, otherwise a sub-pixel offset shears the upper box
-- sideways out of its stack. The override only applies while the horizontal
-- overlap is substantial (the bodies really are stacked); an edge graze keeps
-- its shallow horizontal ejection.
local function contactNormal(a, b, dx, dy, overlapX, overlapY)
    local minHeight, minWidth = math.min(a.h, b.h), math.min(a.w, b.w)
    local horizontalWins = overlapX < overlapY - physics.axisBias
        and (overlapY < minHeight or overlapX < minWidth / 2)
    if horizontalWins then
        return dx >= 0 and 1 or -1, 0, overlapX
    end
    return 0, dy >= 0 and 1 or -1, overlapY
end

-- Rule: the positional correction goes to the prop, never to the player's
-- walking motion. The player normally absorbs it. If that would push the player
-- into a static solid (wedged between boxes at a wall), the prop takes it.
-- Returns the separation weight for a and b (inverse masses, zero = not moved).
local function separationShares(a, b, player, normalX, normalY, penetration, inverseA, inverseB, solids)
    if not player then
        return inverseA, inverseB
    end
    local playerSign = a.isPlayer and -1 or 1
    local pinned = false
    if solids then
        pinned = overlapsAny({
            x = player.x + playerSign * normalX * penetration,
            y = player.y + playerSign * normalY * penetration,
            w = player.w,
            h = player.h,
        }, solids)
    end

    -- Zero the share of whichever body should not move.
    local sepA, sepB = inverseA, inverseB
    local zeroPlayer = pinned
    if zeroPlayer == a.isPlayer then
        sepA = 0
    else
        sepB = 0
    end
    return sepA, sepB
end

-- Impulse along the contact normal. A slow contact settles (the upper body's
-- speed is clamped to the support's, so gravity cannot relaunch the stack);
-- a fast one bounces with restitution.
local function resolveVelocity(a, b, normalX, normalY, restitution, inverseA, inverseB, inverseMassTotal)
    local relativeVelocity = (b.vx - a.vx) * normalX + (b.vy - a.vy) * normalY
    if relativeVelocity >= 0 then
        return -- already separating
    end
    if normalY ~= 0 and math.abs(relativeVelocity) <= physics.restingSpeed then
        if normalY < 0 then
            b.vy = math.min(b.vy, a.vy) -- b is the upper body
        else
            a.vy = math.min(a.vy, b.vy) -- a is the upper body
        end
    else
        local bounce = restitution or physics.restitution
        local impulse = -(1 + bounce) * relativeVelocity / inverseMassTotal
        a.vx = a.vx - impulse * normalX * inverseA
        a.vy = a.vy - impulse * normalY * inverseA
        b.vx = b.vx + impulse * normalX * inverseB
        b.vy = b.vy + impulse * normalY * inverseB
    end
end

-- Dampen relative sideways motion on a vertical contact so boxes rest on one
-- another instead of skating apart. Not applied to the player: a player walking
-- on a prop must not drag it along.
local function applyFriction(a, b, normalY, inverseA, inverseB, inverseMassTotal)
    if normalY == 0 or a.isPlayer or b.isPlayer then
        return
    end
    local tangentVelocity = b.vx - a.vx
    local frictionImpulse = tangentVelocity * physics.contactFriction / inverseMassTotal
    a.vx = a.vx + frictionImpulse * inverseA
    b.vx = b.vx - frictionImpulse * inverseB
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

local function inverseMass(body)
    local mass = physics.bodyMass(body)
    return mass == math.huge and 0 or 1 / mass
end

-- Resolve one dynamic AABB against another using minimum translation and a
-- one-dimensional impulse along the shallowest penetration axis. Bodies may
-- optionally provide a mass; otherwise their mass is derived from w * h.
-- Static bodies are not moved and behave as infinite-mass objects. Held bodies
-- are skipped: the player owns their position while carrying them.
function physics.resolveBodyCollision(a, b, restitution, bodies, solids)
    if a.held or b.held or not physics.overlaps(a, b) then
        return false
    end

    local dx, dy = b.x - a.x, b.y - a.y
    local player, platform = playerPair(a, b)
    if player and tryOneWayLanding(player, platform, bodies) then
        return true
    end

    local overlapX = (a.w + b.w) / 2 - math.abs(dx)
    local overlapY = (a.h + b.h) / 2 - math.abs(dy)
    if overlapX <= 0 or overlapY <= 0 then
        return false
    end

    local normalX, normalY, penetration = contactNormal(a, b, dx, dy, overlapX, overlapY)
    local inverseA, inverseB = inverseMass(a), inverseMass(b)
    local inverseMassTotal = inverseA + inverseB
    if inverseMassTotal == 0 then
        return false
    end

    -- Separate the bodies so they cannot remain interpenetrating.
    local sepA, sepB = separationShares(a, b, player, normalX, normalY, penetration,
        inverseA, inverseB, solids)
    local sepTotal = sepA + sepB
    local correctionA = penetration * sepA / sepTotal
    local correctionB = penetration * sepB / sepTotal
    a.x = a.x - normalX * correctionA
    a.y = a.y - normalY * correctionA
    b.x = b.x + normalX * correctionB
    b.y = b.y + normalY * correctionB

    resolveVelocity(a, b, normalX, normalY, restitution, inverseA, inverseB, inverseMassTotal)
    applyFriction(a, b, normalY, inverseA, inverseB, inverseMassTotal)
    updateGrounding(a, b, normalY, player, platform and (platform.y - platform.h / 2))
    return true
end

-- Resolve every dynamic body pair once, then settle against solids.
function physics.resolveBodyCollisions(bodies, solids, restitution, iterations)
    -- Dense box clusters need more than a few passes for contact corrections
    -- to propagate through the whole stack instead of depending on pair order.
    iterations = iterations or 8
    for _ = 1, iterations do
        for i = 1, #bodies - 1 do
            for j = i + 1, #bodies do
                physics.resolveBodyCollision(bodies[i], bodies[j], restitution, bodies, solids)
            end
        end

        if solids then
            for _, body in ipairs(bodies) do
                physics.resolveBodyAgainstSolids(body, solids)
            end
        end
    end
end

return physics
