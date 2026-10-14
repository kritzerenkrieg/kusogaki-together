-- Mass for bodies. A body's mass comes from its collider area unless it sets its
-- own density; static bodies have infinite mass and never move from impulses.
local mass = {}

-- Use collider/image area as mass. A larger image therefore carries more
-- momentum and is harder to push around than a smaller one.
function mass.fromSize(width, height, density)
    return math.max(1, (width or 1) * (height or 1) * (density or 1))
end

-- Mass of a body, computed once and cached on it. An `immovable` body (a
-- puppet: another machine's player in network play) is infinite mass too.
function mass.ofBody(body)
    if body.static or body.immovable then
        return math.huge
    end
    body.mass = body.mass or mass.fromSize(body.w, body.h, body.density)
    return body.mass
end

-- Inverse mass used by impulses and separation: zero for infinite mass.
function mass.inverse(body)
    local value = mass.ofBody(body)
    return value == math.huge and 0 or 1 / value
end

return mass
