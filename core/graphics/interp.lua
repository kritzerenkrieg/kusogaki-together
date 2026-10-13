-- Draw-time interpolation for the fixed timestep: bodies are drawn between
-- their position at the previous tick and the current one, so motion stays
-- smooth on displays faster or slower than the 60 Hz simulation.
-- Only drawing sees the blended position; the simulation never does.
local interp = {}

local previous = setmetatable({}, { __mode = "k" }) -- body -> { x, y } at the last tick
local moved = {}                                    -- bodies moved by apply(), for restore()

-- Teleports (respawn, pipes) are not blended: a jump this large snaps.
local SNAP_DISTANCE = 64

-- Call before each tick with every body that can move.
function interp.record(bodies)
    for _, body in ipairs(bodies) do
        local prev = previous[body]
        if prev then
            prev.x, prev.y = body.x, body.y
        else
            previous[body] = { x = body.x, y = body.y }
        end
    end
end

-- Move bodies to their blended draw position. Always pair with restore().
function interp.apply(bodies, alpha)
    for _, body in ipairs(bodies) do
        local prev = previous[body]
        if prev and math.abs(body.x - prev.x) + math.abs(body.y - prev.y) < SNAP_DISTANCE then
            moved[#moved + 1] = { body, body.x, body.y }
            body.x = prev.x + (body.x - prev.x) * alpha
            body.y = prev.y + (body.y - prev.y) * alpha
        end
    end
end

-- Put bodies back at their simulated position.
function interp.restore()
    for i = #moved, 1, -1 do
        local entry = moved[i]
        entry[1].x, entry[1].y = entry[2], entry[3]
        moved[i] = nil
    end
end

function interp.clear()
    previous = setmetatable({}, { __mode = "k" })
end

return interp
