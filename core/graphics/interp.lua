-- Draw-time interpolation for the fixed timestep: bodies are drawn between
-- their position at the previous tick and the current one, so motion stays
-- smooth on displays faster or slower than the 60 Hz simulation.
-- Only drawing sees the blended position; the simulation never does.
local interp = {}

local previous = setmetatable({}, { __mode = "k" }) -- body -> { x, y } at the last tick
local moved = {}                                    -- bodies moved by apply(), for restore()
local offsets = setmetatable({}, { __mode = "k" })  -- body -> { x, y } still to glide (corrections)

-- How much of a correction is left after each tick: exp(-1/6), a 100 ms
-- time constant at 60 ticks a second.
interp.CORRECTION_KEEP = 0.846
-- A correction this large (px) snaps instead: the body really jumped (a
-- respawn). Larger than SNAP_DISTANCE: a late remote input at a high ping
-- can move a runner ~100 px.
interp.CORRECTION_SNAP = 160

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

-- Move bodies to their blended draw position, plus what is left of a
-- correction. Always pair with restore().
function interp.apply(bodies, alpha)
    for _, body in ipairs(bodies) do
        local x, y = body.x, body.y
        local prev = previous[body]
        if prev and math.abs(body.x - prev.x) + math.abs(body.y - prev.y) < SNAP_DISTANCE then
            x = prev.x + (body.x - prev.x) * alpha
            y = prev.y + (body.y - prev.y) * alpha
        end
        local offset = offsets[body]
        if offset then
            x, y = x + offset.x, y + offset.y
        end
        if x ~= body.x or y ~= body.y then
            moved[#moved + 1] = { body, body.x, body.y }
            body.x, body.y = x, y
        end
    end
end

-- A correction (network play: the host's state replaced a prediction) moved
-- `body` from (fromX, fromY) to where it is now: keep drawing it from where
-- it was and glide to the new place over the next ticks. A jump as large as
-- a teleport just snaps.
function interp.correct(body, fromX, fromY)
    local dx, dy = fromX - body.x, fromY - body.y
    if math.abs(dx) + math.abs(dy) < 0.01 then
        return
    end
    local offset = offsets[body] or { x = 0, y = 0 }
    offset.x, offset.y = offset.x + dx, offset.y + dy
    offsets[body] = math.abs(offset.x) + math.abs(offset.y) < interp.CORRECTION_SNAP and offset or nil
    local prev = previous[body]
    if prev then -- blend between ticks without the jump; the offset carries it
        prev.x, prev.y = prev.x - dx, prev.y - dy
    end
end

-- Each tick: what is left of every correction shrinks.
function interp.decay()
    for body, offset in pairs(offsets) do
        offset.x, offset.y = offset.x * interp.CORRECTION_KEEP, offset.y * interp.CORRECTION_KEEP
        if math.abs(offset.x) + math.abs(offset.y) < 0.05 then
            offsets[body] = nil
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
    offsets = setmetatable({}, { __mode = "k" })
end

return interp
