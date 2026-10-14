-- The gameplay scene: fixed-step update, interpolated draw, joining, and the
-- stopped-level screen.
local helpers = require("tests.sim.helpers")
local check = helpers.check
local UNEVEN = helpers.UNEVEN

-- ── The gameplay scene: fixed-step update + interpolated draw ────────────
do
    local gameplay = require("scenes.gameplay")
    local walkRight = { read = function() return { right = true } end }
    gameplay.load()
    local loaded = gameplay.takeOutbox()
    check("the host announces the first seed", #loaded == 1 and loaded[1].t == "restart"
        and loaded[1].seed == gameplay.getLevel().seed)
    gameplay.setSource(1, walkRight)
    local second = gameplay.join({ kind = "test", read = function() return { right = true, jump = true } end })
    local again = gameplay.join({ kind = "test", read = walkRight.read })
    check("a device joins once", second ~= nil and again == nil)
    local player = gameplay.getPlayer(1)
    local ok, err = pcall(function()
        for frame = 1, 240 do
            gameplay.update(UNEVEN[(frame - 1) % #UNEVEN + 1])
            local x, y = player.x, player.y
            gameplay.draw()
            assert(player.x == x and player.y == y, "draw left the player at its blended position")
        end
    end)
    check("gameplay scene updates and draws", ok, tostring(err))
    check("gameplay scene moves both players", player.x > 100 and second.x > 100,
        string.format("%.0f %.0f", player.x, second.x))
    check("joined player gets id 2", second.id == 2)

    local level = gameplay.getLevel()
    level:fault("test: a script stopped the level")
    local drawn = pcall(gameplay.draw)
    check("a stopped level draws its message instead of crashing", drawn)
    local function tick(seconds)
        for _ = 1, math.floor(seconds * 60 + 0.5) do
            gameplay.update(1 / 60)
        end
    end

    -- Restart vote: more than half of the 2 players must vote.
    gameplay.getPlayer(1).respawns, gameplay.getPlayer(2).respawns = 3, 1
    gameplay.toggleVote(1)
    tick(6)
    check("half the players is not enough to restart", gameplay.getLevel() == level)
    gameplay.toggleVote(2)
    tick(4)
    check("a passed vote waits for the countdown", gameplay.getLevel() == level)
    gameplay.toggleVote(2)
    tick(2)
    gameplay.toggleVote(2)
    tick(4.5)
    check("withdrawing a vote cancels the countdown", gameplay.getLevel() == level)
    check("the vote draws", pcall(gameplay.draw))
    tick(0.6)
    check("restarting a stopped level gives a working level", not gameplay.getLevel().faulted
        and gameplay.getLevel() ~= level)
    local sent = gameplay.takeOutbox()
    check("a passed vote sends restart{seed} with the new level's seed", #sent == 1
        and sent[1].t == "restart" and sent[1].seed == gameplay.getLevel().seed)
    check("the outbox empties once taken", #gameplay.takeOutbox() == 0)
    check("a restart keeps the respawn counts",
        gameplay.getPlayer(1).respawns == 3 and gameplay.getPlayer(2).respawns == 1)
    level = gameplay.getLevel()
    tick(6)
    check("votes are cleared by the restart", gameplay.getLevel() == level)

    level:addStage("win", function(level) level:finish("win", "test") end) -- wins happen inside a step
    tick(1 / 60)
    check("winning resets the respawn counts",
        gameplay.getPlayer(1).respawns == 0 and gameplay.getPlayer(2).respawns == 0)

    -- A client restarts on the host's seed: same seed, same generator.
    local before = gameplay.getLevel()
    check("bad restart seeds are refused", gameplay.restart(0) == false and gameplay.restart(1.5) == false
        and gameplay.restart("7") == false and gameplay.restart(2 ^ 31) == false
        and gameplay.getLevel() == before)
    check("restart(seed) rebuilds with that seed", gameplay.restart(12345) and gameplay.getLevel() ~= before
        and gameplay.getLevel().seed == 12345)
    local first = gameplay.getLevel().random:random(1, 1000000)
    gameplay.restart(12345)
    check("the same seed gives the same random numbers", gameplay.getLevel().random:random(1, 1000000) == first)
    check("a client-side restart sends nothing", #gameplay.takeOutbox() == 0)
end
