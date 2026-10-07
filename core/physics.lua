-- Shared AABB physics for the platformer: world gravity, overlap tests and
-- per-axis movement resolution against solid rectangles.
-- Bodies and solids are center-based: { x, y, w, h }.
local physics = {}

physics.gravity = 1500  -- px/s^2 pulling bodies down
physics.maxFall = 420   -- terminal fall speed (px/s)

-- Overlap test between two center-based AABBs; touching edges do not count.
function physics.overlaps(a, b)
    return math.abs(a.x - b.x) * 2 < (a.w + b.w)
        and math.abs(a.y - b.y) * 2 < (a.h + b.h)
end

-- Move body by its velocity for delta seconds, resolving collisions against
-- solids one axis at a time. Contact side is decided by motion direction
-- (which face the body crossed), not by comparing centers — thin floors
-- would otherwise be misread as ceilings. Sets body.onGround when resting
-- on a solid and zeroes the matching velocity component on contact.
function physics.moveBody(body, solids, delta)
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

return physics