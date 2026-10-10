-- Headless physics checks; no LÖVE needed. Run from the project root:
--   lua tests/physics_test.lua
package.path = "./?.lua;" .. package.path
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
local function step(bodies, solids, frames)
    for _ = 1, frames do
        for _, body in ipairs(bodies) do
            body.vy = math.min(body.vy + physics.gravity * DT, physics.maxFall)
            physics.moveBody(body, solids, DT)
        end
        physics.resolveBodyCollisions(bodies, solids)
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
    local stack, solids = {}, { FLOOR, WALL_LEFT }
    for i = 0, 3 do
        stack[#stack + 1] = body(8, 334 - 16 * i, 16, 16)
    end
    step(stack, solids, 240)

    local before = {}
    for i, b in ipairs(stack) do
        before[i] = { x = b.x, y = b.y }
    end
    step(stack, solids, 120)

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

print(failures == 0 and "all physics checks passed" or (failures .. " physics check(s) failed"))
os.exit(failures == 0 and 0 or 1)
