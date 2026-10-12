-- Geometry for center-based AABBs { x, y, w, h }: overlap tests, displaced
-- rectangles, push-out axis, and the contact record that gameplay rules read.
local geometry = {}

-- Overlap test between two center-based AABBs; touching edges do not count.
function geometry.overlaps(a, b)
    return math.abs(a.x - b.x) * 2 < (a.w + b.w)
        and math.abs(a.y - b.y) * 2 < (a.h + b.h)
end

-- True when the body overlaps at least one static.
function geometry.overlapsAny(body, statics)
    for _, static in ipairs(statics) do
        if geometry.overlaps(body, static) then
            return true
        end
    end
    return false
end

-- Same size as body, displaced by (dx, dy). Used to test a proposed position.
function geometry.movedRect(body, dx, dy)
    return { x = body.x + dx, y = body.y + dy, w = body.w, h = body.h }
end

-- Push-out axis from the center offset, not from which overlap is smaller. Each
-- offset is scaled by the summed half-sizes on that axis, so the axis where the
-- centers are further apart relative to the bodies wins. A box shoved sideways
-- into a spike (centers level) always leaves horizontally; a box resting on
-- another (centers stacked) always leaves vertically. Returns true for horizontal.
function geometry.pushesHorizontally(a, b)
    local nx = (a.x - b.x) / ((a.w + b.w) / 2)
    local ny = (a.y - b.y) / ((a.h + b.h) / 2)
    return math.abs(nx) > math.abs(ny)
end

-- Record that body was blocked by static this frame. Contacts come from the
-- physics itself, so gameplay rules (hazards) react to real collisions instead
-- of a separate zone around the static. body.contacts is a set: static -> true.
function geometry.noteContact(body, static)
    body.contacts = body.contacts or {}
    body.contacts[static] = true
end

return geometry
