-- Resolving a body that overlaps static level geometry (no bounce).
local geometry = require("core.physics.geometry")

local staticContact = {}

-- Candidate exits that move a body out of one static: onto its top face, or off
-- its left/right face. An exit is only offered on the side of the static the body
-- already sits on, so it never crosses the static, and there is no downward exit:
-- a static never pushes a body down. Side exits list the side the body came from
-- first, so ties keep it on that side.
local function staticExits(body, static)
    local exits = {}
    if body.y <= static.y then
        exits[#exits + 1] = { x = body.x, y = static.y - static.h / 2 - body.h / 2, axis = "y" }
    end

    local leftX = static.x - static.w / 2 - body.w / 2
    local rightX = static.x + static.w / 2 + body.w / 2
    local leftFirst = (body.prevX or body.x) <= static.x
    local leftOk, rightOk = body.x <= static.x, body.x >= static.x
    if leftFirst then
        if leftOk then exits[#exits + 1] = { x = leftX, y = body.y, axis = "x" } end
        if rightOk then exits[#exits + 1] = { x = rightX, y = body.y, axis = "x" } end
    else
        if rightOk then exits[#exits + 1] = { x = rightX, y = body.y, axis = "x" } end
        if leftOk then exits[#exits + 1] = { x = leftX, y = body.y, axis = "x" } end
    end
    return exits
end

-- The cheapest exit from one static that does not land the body in any static.
-- Returns nil when every exit is blocked; the body then stays where it is.
local function bestStaticExit(body, statics, static)
    local best, bestDistance
    for _, exit in ipairs(staticExits(body, static)) do
        local distance = (exit.x - body.x) ^ 2 + (exit.y - body.y) ^ 2
        local probe = { x = exit.x, y = exit.y, w = body.w, h = body.h }
        if (not best or distance < bestDistance) and not geometry.overlapsAny(probe, statics) then
            best, bestDistance = exit, distance
        end
    end
    return best
end

-- Remove overlap with static level geometry without applying a bounce. The body
-- takes the cheapest exit that clears the static without entering another one,
-- measured in pixels, so a wide static cannot throw a body sideways across the
-- level. Bodies are never pushed downward (see staticExits).
function staticContact.resolveBodyAgainstStatics(body, statics)
    if body.held or body.immovable then
        return -- a held body belongs to the player's collision; an immovable one to its owner
    end
    for _, static in ipairs(statics) do
        if geometry.overlaps(body, static) then
            geometry.noteContact(body, static)
            local exit = bestStaticExit(body, statics, static)
            if exit and exit.axis == "y" then
                body.y = exit.y
                body.vy = 0
                body.onGround = true
            elseif exit then
                body.x = exit.x
                body.vx = 0
                body.blockedX = true
            end
        end
    end
end

return staticContact
