-- Players on each other: kicks knock back, grabs carry, kicks throw. A carried
-- player cannot get away on their own. None of it is lethal.
local Level = require("core.level")
local playerModule = require("core.player")
local netstate = require("core.level.netstate")
local helpers = require("tests.sim.helpers")
local check = helpers.check

-- Two (or three) players standing side by side on the example level's ground,
-- player 1 on the left, facing right.
local function setup(count)
    local level = Level.load("kusogaki_stage1")
    for i = 1, count or 2 do
        level:addPlayer(playerModule.new(90 + (i - 1) * 18, 250))
    end
    for _ = 1, 40 do
        level:update(1 / 60)
    end
    level:takeEvents()
    return level
end

-- Run ticks with the given frames ({ [playerIndex] = frame }); a frame is held
-- for every tick.
local function step(level, frames, ticks)
    for _ = 1, ticks or 1 do
        for i, player in ipairs(level.players) do
            player.input = frames[i] or {}
        end
        level:update(1 / 60)
    end
end

do
    local level = setup()
    local p1, p2 = level.players[1], level.players[2]
    check("players stand side by side", p1.onGround and p2.onGround and p2.x - p1.x > 12,
        ("%.1f %.1f"):format(p1.x, p2.x))
    local startX = p2.x
    step(level, { { kick = true } })
    check("a kick knocks the other player back", p2.vx > 0 and p2.knockback > 0 and not p2.dead)
    step(level, {}, 40)
    check("... it is not lethal and moves them away", not p2.dead and p2.x > startX + 10,
        ("%.1f -> %.1f"):format(startX, p2.x))
end

do
    local level = setup()
    local p1, p2 = level.players[1], level.players[2]
    step(level, { { hold = true } })
    check("a player grabs another player", p1.carrying == p2 and p2.held and p2.heldBy == p1)
    local snapshot = netstate.snapshot(level, 1)
    check("snapshots say which player is carried", snapshot.players[1].carryingPlayer == 2
        and snapshot.players[1].carrying == nil and snapshot.players[2].held == true)
    step(level, { { hold = true, left = true } }, 20) -- away from the level's boxes
    check("a carried player moves with the carrier", p2.held and math.abs(p2.x - p1.x) < 20 and p1.x < 80,
        ("%.1f %.1f"):format(p1.x, p2.x))
    step(level, { { hold = true }, { jump = true, left = true, kick = true } }, 30)
    check("a carried player cannot get away", p2.held and p1.carrying == p2)
    step(level, { {}, {} })
    check("letting go of grab drops them", not p2.held and p1.carrying == nil)

    step(level, { {}, {} }, 40)
    p1.facing = p2.x > p1.x and 1 or -1
    step(level, { { hold = true } })
    check("... and they can be grabbed again", p1.carrying == p2)
    step(level, { { hold = true, kick = true } })
    check("kicking while carrying throws the player", not p2.held and p1.carrying == nil
        and math.abs(p2.vx) > 100 and p2.knockback > 0)
    step(level, {}, 60)
    check("... and the throw is not lethal", not p2.dead)
end

do
    local level = setup()
    local p1, p2 = level.players[1], level.players[2]
    step(level, { { hold = true } })
    p1:die()
    check("a carrier who dies lets go", not p2.held and p2.heldBy == nil and p1.carrying == nil)

    local level2 = setup()
    local q1, q2 = level2.players[1], level2.players[2]
    step(level2, { { hold = true } })
    q2:die()
    check("a carried player who dies leaves the carrier's hands", q1.carrying == nil and not q2.held)
end

do
    local level = setup(3)
    local p1, p2, p3 = level.players[1], level.players[2], level.players[3]
    step(level, { { hold = true } })
    p3.facing = -1
    step(level, { { hold = true }, {}, { hold = true } })
    check("no carry chains: a carrier or a carried player cannot be grabbed",
        p1.carrying == p2 and p3.carrying == nil)
    step(level, { { hold = true }, { kick = true, hold = true } }, 10)
    check("a carried player can neither kick nor grab", p2.carrying == nil and p2.kickTime == 0)
end
