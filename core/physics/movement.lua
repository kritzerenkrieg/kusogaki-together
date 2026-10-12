-- Moving a body by its velocity and stopping it at statics, one axis at a time.
local geometry = require("core.physics.geometry")

local movement = {}

-- One small movement step. Keeping this separate lets moveBody use several
-- substeps at high velocity, which prevents a body from tunneling through a
-- thin platform or another object between frames.
local function moveBodyStep(body, statics, delta)
    body.x = body.x + body.vx * delta
    for _, static in ipairs(statics) do
        if geometry.overlaps(body, static) then
            geometry.noteContact(body, static)
            if body.vx > 0 then
                body.x = static.x - static.w / 2 - body.w / 2 -- hit left face
            elseif body.vx < 0 then
                body.x = static.x + static.w / 2 + body.w / 2 -- hit right face
            elseif body.x < static.x then
                body.x = static.x - static.w / 2 - body.w / 2
            else
                body.x = static.x + static.w / 2 + body.w / 2
            end
            body.vx = 0
            body.blockedX = true
        end
    end

    body.onGround = false
    body.y = body.y + body.vy * delta
    for _, static in ipairs(statics) do
        if geometry.overlaps(body, static) then
            geometry.noteContact(body, static)
            if body.vy >= 0 then
                body.y = static.y - static.h / 2 - body.h / 2 -- landed on top
                body.vy = 0
                body.onGround = true
            else
                body.y = static.y + static.h / 2 + body.h / 2 -- bumped a ceiling
                body.vy = 0
            end
        end
    end
end

-- Move body by its velocity for delta seconds, resolving collisions against
-- statics one axis at a time. High-speed bodies use smaller substeps instead
-- of being corrected from deep inside a collider after they have passed it.
function movement.moveBody(body, statics, delta)
    body.prevX, body.prevY = body.x, body.y
    body.contacts = {}
    body.blockedX = false
    local smallestSide = math.max(1, math.min(body.w, body.h))
    local travel = math.max(math.abs(body.vx), math.abs(body.vy)) * delta
    local steps = math.min(8, math.max(1, math.ceil(travel / (smallestSide * 0.5))))
    local stepDelta = delta / steps

    for _ = 1, steps do
        moveBodyStep(body, statics, stepDelta)
    end
end

return movement
