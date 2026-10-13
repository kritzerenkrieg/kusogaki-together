-- Headless physics checks; no LÖVE needed. Run from the project root:
--   lua tests/physics_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local physics = require("core.physics")

local failures = 0
local function check(name, condition, detail)
    if condition then
        print("ok    " .. name)
    else
        failures = failures + 1
        print("FAIL  " .. name .. (detail and (" (" .. detail .. ")") or ""))
    end
end

local DT = 1 / 60

-- Same order as gameplay: gravity + move per body, then pairwise resolution.
local function step(bodies, statics, frames)
    for _ = 1, frames do
        for _, body in ipairs(bodies) do
            body.vy = math.min(body.vy + physics.gravity * DT, physics.maxFall)
            physics.moveBody(body, statics, DT)
        end
        physics.resolveBodyCollisions(bodies, statics)
    end
end

local function body(x, y, w, h, extra)
    local b = { x = x, y = y, w = w, h = h, vx = 0, vy = 0, onGround = false }
    for key, value in pairs(extra or {}) do
        b[key] = value
    end
    return b
end

-- Ground top is at y = 342; the left wall's inner face is at x = 0.
local FLOOR = { x = 320, y = 354, w = 656, h = 24 }
local WALL_LEFT = { x = -8, y = 180, w = 16, h = 400 }

-- Overlap ------------------------------------------------------------------
check("touching edges do not overlap",
    not physics.overlaps({ x = 0, y = 0, w = 10, h = 10 }, { x = 10, y = 0, w = 10, h = 10 }))
check("real overlap is detected",
    physics.overlaps({ x = 0, y = 0, w = 10, h = 10 }, { x = 5, y = 0, w = 10, h = 10 }))

-- Landing ------------------------------------------------------------------
do
    local box = body(100, 200, 16, 16)
    step({ box }, { FLOOR }, 120)
    check("box lands and rests on the floor",
        box.onGround and math.abs(box.y - (342 - 8)) < 0.01, tostring(box.y))
end

-- Stack against a wall must stay still and aligned --------------------------
do
    local stack, statics = {}, { FLOOR, WALL_LEFT }
    for i = 0, 3 do
        stack[#stack + 1] = body(8, 334 - 16 * i, 16, 16)
    end
    step(stack, statics, 240)

    local before = {}
    for i, b in ipairs(stack) do
        before[i] = { x = b.x, y = b.y }
    end
    step(stack, statics, 120)

    local drift, shear = 0, 0
    for i, b in ipairs(stack) do
        drift = math.max(drift, math.abs(b.x - before[i].x), math.abs(b.y - before[i].y))
        shear = math.max(shear, math.abs(b.x - 8))
    end
    check("4-box stack against the wall is still", drift < 0.05, ("drift %.3f"):format(drift))
    check("4-box stack against the wall is not sheared", shear < 0.05, ("shear %.3f"):format(shear))
end

-- Box landing on a player wedged against the wall ----------------------------
do
    local player = body(6, 330, 12, 24, { isPlayer = true })
    local box = body(6, 300, 16, 16)
    step({ player, box }, { FLOOR, WALL_LEFT }, 120)
    check("wedged player is not pushed out of place", math.abs(player.x - 6) < 0.05,
        ("x %.3f"):format(player.x))
    check("wedged player is not sunk into the floor", player.y <= 330 + 0.05,
        ("y %.3f"):format(player.y))
    check("box comes to rest on the player", box.y < 311, ("y %.3f"):format(box.y))
end

local function overlapsAnyStatic(b, statics)
    for _, s in ipairs(statics) do
        if physics.overlaps(b, s) then
            return true
        end
    end
    return false
end

-- Box inside box, hugging floor and wall ------------------------------------
-- Two boxes at the same spot used to be shoved sideways out of the level or
-- into the floor. They must end up free of statics and near where they started.
do
    local statics = { FLOOR, WALL_LEFT }
    local a, b = body(8, 334, 16, 16), body(8, 334, 16, 16)
    step({ a, b }, statics, 120)
    check("coincident boxes at the wall leave no static overlap",
        not overlapsAnyStatic(a, statics) and not overlapsAnyStatic(b, statics))
    check("coincident boxes at the wall stay in the level",
        a.x > -1 and b.x > -1 and a.x < 40 and b.x < 40,
        ("x %.2f %.2f"):format(a.x, b.x))
end

-- Box dropped into a box on the floor: the upper box is lifted, not ejected.
do
    local statics = { FLOOR, WALL_LEFT }
    local lower, upper = body(100, 334, 16, 16), body(100, 318, 16, 16)
    step({ lower, upper }, statics, 120)
    check("box inside a box on the floor leaves no static overlap",
        not overlapsAnyStatic(lower, statics) and not overlapsAnyStatic(upper, statics))
    check("box inside a box on the floor is not thrown sideways",
        math.abs(upper.x - 100) < 1, ("x %.2f"):format(upper.x))
end

-- A static never pushes a body downward ------------------------------------
-- A body under a ceiling leaves sideways, not down.
do
    local ceiling = { x = 100, y = 92, w = 40, h = 12 }
    local bodyUnder = body(100, 100, 16, 16)
    physics.resolveBodyAgainstStatics(bodyUnder, { ceiling })
    check("body under a ceiling is not pushed down",
        bodyUnder.y <= 100 + 0.01, ("y %.3f"):format(bodyUnder.y))
    check("body under a ceiling leaves sideways and clears it",
        not overlapsAnyStatic(bodyUnder, { ceiling }), ("x %.3f"):format(bodyUnder.x))
end

-- Players against players ---------------------------------------------------
-- Like `step`, but records prevY as the player update does (one-way landing
-- needs it).
local function stepPlayers(bodies, statics, frames)
    for _ = 1, frames do
        for _, b in ipairs(bodies) do
            b.prevY = b.y
            b.vy = math.min(b.vy + physics.gravity * DT, physics.maxFall)
            physics.moveBody(b, statics, DT)
        end
        physics.resolveBodyCollisions(bodies, statics)
    end
end

-- A player dropped onto another player stands on their head.
do
    local lower = body(200, 330, 12, 24, { isPlayer = true })
    local upper = body(200, 280, 12, 24, { isPlayer = true })
    stepPlayers({ lower, upper }, { FLOOR }, 120)
    check("player lands on another player's head", math.abs(upper.y - 306) < 0.5,
        ("y %.2f"):format(upper.y))
    check("player on a head is grounded", upper.onGround == true)
    check("player under a player stays on the floor", math.abs(lower.y - 330) < 0.05,
        ("y %.2f"):format(lower.y))
    -- The same with the join order reversed (pair order must not matter).
    local lower2 = body(200, 330, 12, 24, { isPlayer = true })
    local upper2 = body(200, 280, 12, 24, { isPlayer = true })
    stepPlayers({ upper2, lower2 }, { FLOOR }, 120)
    check("head landing does not depend on pair order", math.abs(upper2.y - upper.y) < 0.05,
        ("y %.2f vs %.2f"):format(upper2.y, upper.y))
end

-- Two players walking into each other share the push and end up apart.
do
    local a = body(200, 330, 12, 24, { isPlayer = true })
    local b = body(209, 330, 12, 24, { isPlayer = true })
    stepPlayers({ a, b }, { FLOOR }, 1)
    check("overlapping players are separated", b.x - a.x >= 12 - 0.01,
        ("gap %.2f"):format(b.x - a.x))
    check("overlapping players share the push",
        math.abs((a.x - 200) + (b.x - 209)) < 0.05, ("moved %.2f %.2f"):format(a.x - 200, b.x - 209))
end

print(failures == 0 and "all physics checks passed" or (failures .. " physics check(s) failed"))
os.exit(failures == 0 and 0 or 1)
