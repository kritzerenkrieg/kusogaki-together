-- What level scripts can change: input actions, stages, spawning, gravity,
-- finishing, the camera, and the top-down level that uses all of them.
local Level = require("core.level")
local playerModule = require("core.player")
local netstate = require("core.level.netstate")
local helpers = require("tests.sim.helpers")
local check = helpers.check
local topdownInput = helpers.topdownInput
local plain = helpers.plain
local run = helpers.run
local showDifference = helpers.showDifference
local EVEN = helpers.EVEN
local UNEVEN = helpers.UNEVEN

-- ── Custom input actions ──────────────────────────────────────────────────
do
    local input = require("core.input")
    local actions = input.parseActions({
        { name = "up", keys = { "up", "w" }, gamepad = { "dpup", "leftup" } },
        { name = "dash", keys = { "v" } },
    }, "test")
    local names = input.names(actions)
    check("custom actions follow the base ones", table.concat(names, ",") == "left,right,jump,kick,hold,up,dash")
    local frame = { left = true, jump = true, up = false, dash = true }
    local back = input.unpack(input.pack(frame, names), names)
    check("input frames pack into one number and back",
        back.left and back.jump and back.dash and not back.up and not back.right and input.pack(frame, names) == 69)
    for _, bad in ipairs({
        { { name = "jump" } }, { { name = "x y" } }, { { name = "a" }, { name = "a" } },
        { { name = "a", keys = { "notakey" } } }, { { name = "a", gamepad = { "turbo" } } },
    }) do
        local ok = pcall(input.parseActions, bad, "test")
        check("bad action declarations are refused (" .. tostring(bad[1].name) .. ")", not ok)
    end
    local keyboard = input.keyboard(2).read(actions)
    check("sources report custom actions", keyboard.up == false and keyboard.dash == false)
end

-- ── Stages, spawning, gravity, finish ─────────────────────────────────────
do
    local level = Level.load("example")
    level:addPlayer(playerModule.new(level.spawn.x, level.spawn.y))
    local names = {}
    for _, stage in ipairs(level.stages) do names[#names + 1] = stage.name end
    check("a step is a list of named stages", names[1] == "input" and names[#names] == "scripts", table.concat(names, ","))
    local order = {}
    level:addStage("mine", function() order[#order + 1] = "mine" end, { after = "collisions" })
    local previous = level:replaceStage("triggers", function(lvl, delta) order[#order + 1] = "triggers" end)
    level:update(1 / 60)
    check("added and replaced stages run in place", table.concat(order, ",") == "mine,triggers")
    check("replaceStage returns the built-in rule", type(previous) == "function")
    check("removeStage takes a stage out", level:removeStage("mine") and not level:findStage("mine"))
    check("unknown stages are an error", not pcall(level.addStage, level, "x", function() end, { before = "nope" }))
    local other = Level.load("example")
    check("stage lists are per level", other:findStage("triggers") and other.stages[1] ~= level.stages[1])

    local firstId = level.nextId
    local floating = level:spawnEntity("box", 300, 100)
    floating.gravityScale = 0
    local falling = level:spawnEntity("box", 340, 100)
    check("spawned entities get ids after the placements", floating.id == firstId and falling.id == firstId + 1
        and level:get(floating.id) == floating and floating.kind == "prop" and floating.typeName == "box")
    level:addStage("spawner", function(lvl) lvl:spawnEntity("box", 380, 60) end)
    level:update(1 / 60)
    level:removeStage("spawner")
    local reported = false
    for _, event in ipairs(level:takeEvents()) do
        reported = reported or (event.type == "spawned" and event.typeName == "box" and event.id == firstId + 2)
    end
    check("spawning during a step is reported", reported)
    for _ = 1, 60 do
        level:update(1 / 60)
    end
    check("gravityScale 0: a body floats", floating.y == 100, floating.y)
    check("level gravity pulls other bodies", falling.y > 150, falling.y)
    check("spawning an unknown type fails", not pcall(level.spawnEntity, level, "../evil", 0, 0))
    check("spawn placements must be plain data", not pcall(level.spawnEntity, level, "box", 0, 0, { f = print }))

    local zeroG = Level.load("example")
    zeroG.gravity = 0
    local player = zeroG:addPlayer(playerModule.new(500, 100))
    for _ = 1, 30 do zeroG:update(1 / 60) end
    check("a level with gravity 0: players do not fall", player.y == 100, player.y)

    level:send("hello", { n = 1 })
    check("messages outside a step are dropped", #level:takeEvents() == 0)
    check("message data must be plain", not pcall(level.send, level, "bad", { f = print }))
    level:addStage("ending", function(lvl) lvl:finish("lose", "out of time") end)
    level:update(1 / 60)
    local finished = level:takeEvents()
    check("finishing ends the level with an outcome", level.finished and level.finished.outcome == "lose"
        and finished[#finished].type == "finish" and finished[#finished].message == "out of time")
    check("a finished level stops updating", level:update(1 / 60) == false and not level.faulted)
end

-- ── Camera ────────────────────────────────────────────────────────────────
do
    local camera = require("core.graphics.camera")
    local level = Level.load("example")
    local player = level:addPlayer(playerModule.new(1000, 200))
    camera.frame(level)
    check("the camera follows the players (x) and stays inside the level (y)",
        camera.x == 680 and camera.y == 0 and camera.zoom == 1, camera.x .. " " .. camera.y)
    level.camera.zoom = 2
    camera.frame(level)
    check("zoom shrinks the view around the target", camera.x == 840 and camera.y == 110, camera.x .. " " .. camera.y)
    level.camera.follow = level.props[1]
    level.camera.zoom = 1
    camera.frame(level)
    check("the camera can follow any body", camera.x == 0)
    level.camera.follow = "screens"
    camera.frame(level)
    check("flip-screen mode snaps to screen cells", camera.x == 640, camera.x)
    level.camera.follow = nil
    level.camera.x, level.camera.y = 2000, 180
    camera.frame(level)
    check("a fixed camera stays on (x, y)", camera.x == 1680, camera.x)
    local sx = camera.toScreen(player.x, player.y)
    check("world to screen positions", sx == 1000 - 1680)
end

-- ── Local players: camera, sound and shake follow this machine's players ──
do
    local camera = require("core.graphics.camera")
    local present = require("core.graphics.present")
    local level = Level.load("example")
    local mine = level:addPlayer(playerModule.new(1000, 200))
    local other = level:addPlayer(playerModule.new(2000, 200))
    camera.frame(level, { [mine.id] = true })
    check("the camera follows only the local player", camera.x == 680, camera.x)
    mine.dead = true
    camera.frame(level, { [mine.id] = true })
    check("a dead local player watches the live remote ones", camera.x == 1680, camera.x)
    camera.frame(level)
    check("without a local set every player is local", camera.x == 1680, camera.x)

    camera.active = false
    present.event({ type = "player", name = "kick", player = other.id, x = other.x, y = other.y }, level,
        { [mine.id] = true })
    check("a remote player's kick does not shake this screen", not camera.active)
    present.event({ type = "player", name = "kick", player = mine.id, x = mine.x, y = mine.y }, level,
        { [mine.id] = true })
    check("a local player's kick shakes the screen", camera.active)
    camera.active = false

    camera.frame(level, { [other.id] = true }) -- view 1680..2320
    local near, far, left = present.soundAt(2000), present.soundAt(9000), present.soundAt(1100)
    check("remote sounds: full in view, silent far away, panned to their side",
        near.volume == 1 and near.pan == 0 and far.volume == 0 and left.volume < 1 and left.volume > 0
        and left.pan == -1, ("%s %s %s"):format(near.volume, far.volume, left.volume))
    check("a script's event with no position is silent, not a fault", pcall(present.event,
        { type = "player", name = "jump", player = other.id, x = "here" }, level, { [mine.id] = true }))
end

-- ── A different game: the top-down coin race (levels/topdown) ───────────

do
    local level = Level.load("topdown")
    check("level.json sets gravity, actions and camera",
        level.gravity == 0 and table.concat(level.actionNames, ","):find("up,down,dash") and level.camera.zoom == 1.5)
    check("the level script installed its controller and stage",
        level.playerController ~= nil and level:findStage("magnet") < level:findStage("triggers"))

    local first, stats = run(1800, EVEN, 3, "topdown", topdownInput)
    local second = run(1800, EVEN, 3, "topdown", topdownInput)
    local uneven = run(1800, UNEVEN, 3, "topdown", topdownInput)
    check("top-down: same inputs, same state", first == second)
    check("top-down: frame timing does not change the simulation", first == uneven)
    if first ~= uneven then showDifference(first, uneven) end
    print(("      top-down: events %s"):format((function()
        local list = {}
        for name, count in pairs(stats.eventTypes) do list[#list + 1] = name .. " " .. count end
        table.sort(list)
        return table.concat(list, ", ")
    end)()))
    check("top-down: coins are spawned and collected",
        (stats.eventTypes.spawned or 0) > 0 and (stats.eventTypes.message or 0) > 0)

    -- Run one by hand to look at players and the snapshot.
    local live = Level.load("topdown")
    for _ = 1, 3 do live:addPlayer(playerModule.new(live.spawn.x, live.spawn.y)) end
    local minY, maxY = math.huge, -math.huge
    local messages = 0
    for tick = 1, 1200 do
        for i, player in ipairs(live.players) do player.input = topdownInput(tick, i) end
        live:update(1 / 60)
        for _, event in ipairs(live:takeEvents()) do
            if event.type == "message" then messages = messages + 1 end
        end
        minY, maxY = math.min(minY, live.players[1].y), math.max(maxY, live.players[1].y)
    end
    local score = 0
    for _, player in ipairs(live.players) do score = score + (player.net.score or 0) end
    check("top-down: players walk up and down without falling", maxY - minY > 100 and maxY < live.height)
    check("top-down: the custom dash action is used", live.players[1].dashCooldown ~= nil)
    check("top-down: scores live in player.net", score > 0 and score == messages, score .. " " .. messages)
    local maxId = 0
    for id in pairs(live.byId) do maxId = math.max(maxId, id) end
    check("top-down: spawned coins have ids after the placements", maxId > 3)

    local wire = require("core.wire")
    local snapshot = netstate.snapshot(live, 1200)
    local back = netstate.unpack(wire.decode(wire.encode(netstate.pack(snapshot))))
    local settled = netstate.unpack(netstate.pack(snapshot)) -- false reads back as "not set"
    check("snapshots carry script state and spawned types", plain(back, "s") == plain(settled, "s")
        and back.level.net.goal == 10 and back.players[1].net.score ~= nil)
    local spawnedType = false
    for _, entity in ipairs(snapshot.entities) do
        if entity.id > 3 then spawnedType = entity.spawnedType == "coin" end
    end
    check("... spawned entities name their type", spawnedType)
    live.net.bad = print
    check("script state that is not plain data cannot be snapshotted", not pcall(netstate.snapshot, live, 1))
    live.net.bad = nil

    -- Drawing (graphics are stubbed): the hooks and the controller run.
    local drawn = live:protect(function()
        live:drawBackground()
        live:draw()
        live:drawPlayers()
        live:drawWorld()
        live:drawHud()
    end)
    check("top-down: the level draws", drawn, live.faulted)

    live.players[1].net.score = 9
    local coin = live:spawnEntity("coin", live.players[1].x, live.players[1].y)
    live.players[1].input = {}
    live:update(1 / 60)
    check("top-down: the tenth coin wins", live.finished and live.finished.outcome == "win" and coin.removed,
        live.finished and live.finished.message)
end

-- ── Example level: goal zone and respawn counter (levels/example/scripts/goal.lua)
do
    local level = Level.load("example")
    local p1 = level:addPlayer(playerModule.new(3128, 150)) -- top of the last stair
    local p2 = level:addPlayer(playerModule.new(3320, 260)) -- already in the zone
    local function step(frames)
        for _ = 1, frames do
            if level.finished then return end
            level:update(1 / 60)
        end
    end
    p1:die()
    step(150)
    check("a respawn is counted once", p1.respawns == 1 and p2.respawns == 0, p1.respawns)
    check("not won while a player is outside the zone", not level.finished and level.net.inZone == 1)
    p1.x, p1.y, p1.vx, p1.vy = 3300, 260, 0, 0 -- put the respawned player in the zone too
    p1.input, p2.input = {}, {}
    step(1)
    check("everyone alive in the zone wins", level.finished and level.finished.outcome == "win",
        level.finished and level.finished.message)
end
