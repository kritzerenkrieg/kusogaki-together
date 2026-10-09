-- Shared AABB physics for the platformer: world gravity, overlap tests and
-- per-axis movement resolution against solid rectangles.
-- Bodies and solids are center-based: { x, y, w, h }.
local physics = {}

physics.gravity = 1500  -- px/s^2 pulling bodies down
physics.maxFall = 420   -- terminal fall speed (px/s)
physics.restitution = 0.35 -- bounciness for dynamic body collisions
physics.restingSpeed = 70 -- vertical speed below this settles instead of bouncing
physics.contactFriction = 0.35 -- tangential damping while resting on another body

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
    local smallestSide = math.max(1, math.min(body.w, body.h))
    local travel = math.max(math.abs(body.vx), math.abs(body.vy)) * delta
    local steps = math.min(8, math.max(1, math.ceil(travel / (smallestSide * 0.5))))
    local stepDelta = delta / steps

    for _ = 1, steps do
        moveBodyStep(body, solids, stepDelta)
    end
end

-- Remove overlap with static level solids without applying a bounce. This is
-- used after dynamic collisions because a pair correction can otherwise push
-- one body slightly into the floor or a wall.
function physics.resolveBodyAgainstSolids(body, solids)
    for _, solid in ipairs(solids) do
        if physics.overlaps(body, solid) then
            local dx = body.x - solid.x
            local dy = body.y - solid.y
            local overlapX = (body.w + solid.w) / 2 - math.abs(dx)
            local overlapY = (body.h + solid.h) / 2 - math.abs(dy)

            if overlapX < overlapY then
                local direction = dx >= 0 and 1 or -1
                body.x = body.x + direction * overlapX
                body.vx = 0
            else
                local direction = dy >= 0 and 1 or -1
                body.y = body.y + direction * overlapY
                body.vy = 0
                if direction < 0 then
                    body.onGround = true
                end
            end
        end
    end
end

-- Resolve one dynamic AABB against another using minimum translation and a
-- one-dimensional impulse along the shallowest penetration axis. Bodies may
-- optionally provide a mass; otherwise their mass is derived from w * h.
-- Static bodies are not moved and behave as infinite-mass objects.
function physics.resolveBodyCollision(a, b, restitution)
    if a.held or b.held or not physics.overlaps(a, b) then
        return false
    end

    local dx = b.x - a.x
    local dy = b.y - a.y
    local player, platform
    if a.isPlayer and not b.isPlayer then
        player, platform = a, b
    elseif b.isPlayer and not a.isPlayer then
        player, platform = b, a
    end

    -- Props act as one-way platforms for the player. On descent, resolve only
    -- the player's vertical position so walking across a box top cannot push
    -- the supporting box or its neighboring stack sideways.
    local previousPlayerBottom = player and (player.prevY or player.y) + player.h / 2
    local playerBottom = player and player.y + player.h / 2
    local platformTop = platform and platform.y - platform.h / 2
    if player and player.vy >= platform.vy
        and previousPlayerBottom <= platformTop
        and playerBottom >= platformTop then
        player.y = platformTop - player.h / 2
        player.vy = math.min(player.vy, platform.vy)
        player.onGround = true
        return true
    end

    local overlapX = (a.w + b.w) / 2 - math.abs(dx)
    local overlapY = (a.h + b.h) / 2 - math.abs(dy)
    if overlapX <= 0 or overlapY <= 0 then
        return false
    end

    local normalX, normalY, penetration
    if overlapX < overlapY then
        normalX = dx >= 0 and 1 or -1
        normalY = 0
        penetration = overlapX
    else
        normalX = 0
        normalY = dy >= 0 and 1 or -1
        penetration = overlapY
    end

    local massA = physics.bodyMass(a)
    local massB = physics.bodyMass(b)
    local inverseA = massA == math.huge and 0 or 1 / massA
    local inverseB = massB == math.huge and 0 or 1 / massB
    local inverseMassTotal = inverseA + inverseB
    if inverseMassTotal == 0 then
        return false
    end

    -- Separate the bodies so they cannot remain interpenetrating.
    local correctionA = penetration * inverseA / inverseMassTotal
    local correctionB = penetration * inverseB / inverseMassTotal
    a.x = a.x - normalX * correctionA
    a.y = a.y - normalY * correctionA
    b.x = b.x + normalX * correctionB
    b.y = b.y + normalY * correctionB

    -- Apply an impulse only when the bodies are moving toward one another.
    local relativeVelocity = (b.vx - a.vx) * normalX + (b.vy - a.vy) * normalY
    if relativeVelocity < 0 then
        if normalY ~= 0 and math.abs(relativeVelocity) <= physics.restingSpeed then
            -- A box gently falling onto another box is a resting contact, not
            -- a bounce. Match the upper body's vertical speed to the support
            -- body's speed so gravity cannot repeatedly launch the stack.
            if normalY < 0 then
                b.vy = math.min(b.vy, a.vy)
            else
                b.vy = math.max(b.vy, a.vy)
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

    -- A vertical contact has a surface tangent along X. Dampen relative
    -- horizontal motion so boxes can rest on one another instead of slowly
    -- skating apart from tiny collision corrections.
    -- The player is a special controller-driven body. Do not apply box-stack
    -- friction to a player standing on a prop, otherwise walking over the prop
    -- drags the prop along with the player's horizontal movement.
    if normalY ~= 0 and not (a.isPlayer or b.isPlayer) then
        local tangentVelocity = b.vx - a.vx
        local frictionImpulse = tangentVelocity * physics.contactFriction / inverseMassTotal
        a.vx = a.vx + frictionImpulse * inverseA
        b.vx = b.vx - frictionImpulse * inverseB
    end

    -- If b is below a, a is the body standing on top. If a is below b, b
    -- is the body standing on top.
    if normalY > 0 then a.onGround = true end
    if normalY < 0 then b.onGround = true end
    return true
end

-- Resolve every dynamic body pair once. Held bodies are ignored by the
-- resolver because the player owns their position while carrying them.
function physics.resolveBodyCollisions(bodies, solids, restitution, iterations)
    -- Dense box clusters need more than a few passes for contact corrections
    -- to propagate through the whole stack instead of depending on pair order.
    iterations = iterations or 8
    for _ = 1, iterations do
        for i = 1, #bodies - 1 do
            for j = i + 1, #bodies do
                physics.resolveBodyCollision(bodies[i], bodies[j], restitution)
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