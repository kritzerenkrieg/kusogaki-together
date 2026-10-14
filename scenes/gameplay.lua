-- Gameplay scene: loads a level and its local player, and runs it.
-- Each player is a slot { source, player }: an input device (core/input.lua)
-- and the player it drives. Slots survive restarts; players do not (their
-- respawn counts do).
--
-- One player per machine: multiplayer is network play. Local couch co-op
-- (more slots joined from keyboard layout 2 or gamepads) is deprecated and
-- frozen for a far-future return: off unless `--local-coop` is on the
-- command line, and not maintained beyond keeping it working. Gamepads are
-- deprecated with it: the one player plays on the keyboard.
--
-- Restarting is a vote: each player toggles their vote (R / E / gamepad Back).
-- While more than half the players vote, a countdown runs and then the level
-- restarts; dropping below half cancels it.
--
-- This machine is the host (local play is always hosted). The host is the
-- source of truth: it picks each (re)start's seed and announces it as a
-- `restart{seed}` session message (gameplay.takeOutbox); every machine,
-- the host included, restarts through gameplay.restart(seed). See
-- NETWORKING.md (Source of truth).
local sceneEngine = require("core.scenes")
local fx = require("core.graphics.fx")
local camera = require("core.graphics.camera")
local hud = require("core.graphics.hud")
local playerModule = require("core.player")
local Level = require("core.level")
local audio = require("core.audio")
local input = require("core.input")
local fixedstep = require("core.fixedstep")
local interp = require("core.graphics.interp")
local present = require("core.graphics.present")
local render = require("core.graphics.render")
local text = require("core.text")
local loader = require("core.level.loader")
local watchdog = require("core.watchdog")

local gameplay = {}

-- The level to play: "example", or `--level <name>` on the command line
-- (e.g. `love2d . --level topdown`).
local LEVEL_NAME = "example"
local LOCAL_COOP = false -- deprecated couch co-op (see the top of this file)
for i, value in ipairs(arg or {}) do
    if value == "--level" and arg[i + 1] then
        LEVEL_NAME = arg[i + 1]
    elseif value == "--local-coop" then
        LOCAL_COOP = true
    end
end

local level
local slots = {}                    -- local players in join order
local clock = fixedstep.new(1 / 60) -- the simulation runs in fixed 60 Hz ticks
local alpha = 0                     -- how far the frame sits between ticks (drawing)

local RESTART_COUNTDOWN = 5 -- seconds from a passed restart vote to the restart
local votes = {}            -- player id -> true: votes to restart
local countdown = nil       -- seconds left until the restart, while the vote passes
local outbox = {}           -- session messages for the other machines (network play)

local MAX_SEED = 2147483646 -- seeds are 1..MAX_SEED (the MINSTD generator's range)

-- Add a player for a slot at (x, y); that point is also its respawn point.
local function spawn(x, y)
    local player = playerModule.new(x, y)
    level:addPlayer(player)
    return player
end

local function buildLevel(seed)
    -- The watchdog blames a freeze from here on (even while scripts load) on
    -- this level.
    local root = loader.rootFor(LEVEL_NAME)
    watchdog.enter(root)
    level = Level.load(root, { seed = seed })
    fx.clearEffects(level)
    for _, slot in ipairs(slots) do
        local respawns = slot.player and slot.player.respawns or 0
        slot.player = spawn(level.spawn.x, level.spawn.y)
        slot.player.respawns = respawns
    end
    votes, countdown = {}, nil
    clock:reset()
    interp.clear()
    alpha = 0
end

-- The ids of the players this machine plays: every slot's player. Camera,
-- HUD, shake and full sound follow these; other players' events only get
-- positional sound. In local play that is every player.
local function localIds()
    local ids = {}
    for _, slot in ipairs(slots) do
        ids[slot.player.id] = true
    end
    return ids
end

-- Rebuild the level from its package with the host's seed. The host calls it
-- after a passed vote; a client will call it on the host's restart{seed}
-- message, so the seed is checked like any network input. Returns false for a
-- bad seed (nothing changes).
function gameplay.restart(seed)
    if type(seed) ~= "number" or seed % 1 ~= 0 or seed < 1 or seed > MAX_SEED then
        return false
    end
    buildLevel(seed)
    return true
end

-- Host only: pick a fresh seed, announce it, and restart with it.
local function hostRestart()
    local seed = love.math.random(1, MAX_SEED)
    outbox[#outbox + 1] = { type = "restart", seed = seed }
    gameplay.restart(seed)
end

-- The session messages queued for the other machines since the last call, in
-- order; the list is then empty. Network play sends them on the reliable
-- channel.
function gameplay.takeOutbox()
    local list = outbox
    outbox = {}
    return list
end

local function sameDevice(a, b)
    return a.kind == b.kind and a.layout == b.layout and a.joystick == b.joystick
end

-- Deprecated (local couch co-op): only `--local-coop` key/gamepad presses and
-- tests call it. Join a new local player driven by `source`. It appears at player 1's current
-- respawn point (their last checkpoint). Returns the player, or nil when the
-- level is full or the device already plays.
function gameplay.join(source)
    if #slots >= Level.MAX_PLAYERS then
        return nil
    end
    for _, slot in ipairs(slots) do
        if sameDevice(slot.source, source) then
            return nil
        end
    end
    local first = slots[1].player
    local slot = { source = source, player = spawn(first.spawnX, first.spawnY) }
    slots[#slots + 1] = slot
    return slot.player
end

-- Every player's respawn count back to 0 (called when the level is won).
function gameplay.resetRespawns()
    for _, slot in ipairs(slots) do
        slot.player.respawns = 0
    end
end

-- Toggle the restart vote of the player in slot `index`.
function gameplay.toggleVote(index)
    local slot = slots[index]
    if slot then
        local id = slot.player.id
        votes[id] = not votes[id] or nil
    end
end

local function voteCount()
    local count = 0
    for _, slot in ipairs(slots) do
        if votes[slot.player.id] then
            count = count + 1
        end
    end
    return count
end

-- Each tick: run the countdown while more than half the players vote.
local function updateVote(step)
    if voteCount() * 2 <= #slots then
        countdown = nil
        return
    end
    countdown = (countdown or RESTART_COUNTDOWN) - step
    if countdown <= 0 then
        hostRestart()
    end
end

local function slotIndexFor(source)
    for index, slot in ipairs(slots) do
        if sameDevice(slot.source, source) then
            return index
        end
    end
    return nil
end

-- Everything that moves between ticks, for draw interpolation.
local function movingBodies()
    local bodies = {}
    for _, slot in ipairs(slots) do
        bodies[#bodies + 1] = slot.player
    end
    for _, list in ipairs({ level.enemies, level.props }) do
        for _, body in ipairs(list) do
            bodies[#bodies + 1] = body
        end
    end
    return bodies
end

function gameplay.load()
    playerModule.load()
    slots = { { source = input.keyboard(1) } }
    outbox = {}
    hostRestart()
end

function gameplay.update(delta)
    alpha = clock:advance(delta, function(step)
        for _, slot in ipairs(slots) do
            slot.player.input = slot.source.read(level.actions)
        end
        interp.record(movingBodies())
        local wasFinished = level.finished
        level:update(step)
        level:protect(present.all, level:takeEvents(), level, localIds())
        if not wasFinished and level.finished and level.finished.outcome == "win" then
            gameplay.resetRespawns()
        end
        updateVote(step)
    end)
end

function gameplay.keypressed(key)
    if key == "escape" then
        fx.toScene("menu", 0.5, { ease = "smoothstep" })
    elseif input.layoutForKey(key, "restart") then
        gameplay.toggleVote(slotIndexFor(input.keyboard(input.layoutForKey(key, "restart"))))
    elseif LOCAL_COOP then
        local layout = input.layoutForKey(key, "jump")
        if layout then
            gameplay.join(input.keyboard(layout))
        end
    end
end

-- Gamepads are deprecated for now: they only work with `--local-coop`, as
-- joined couch co-op players. The single player plays on the keyboard.
function gameplay.gamepadpressed(joystick, button)
    if not LOCAL_COOP then
        return
    end
    if button == input.GAMEPAD_RESTART then
        gameplay.toggleVote(slotIndexFor(input.gamepad(joystick)))
    elseif button == "a" or button == "start" then
        gameplay.join(input.gamepad(joystick))
    end
end

local worldPushed = false -- camera.pushWorld is active (popped even after a failure)

-- Everything the level draws. It runs under script limits (level:protect):
-- entities, events and level scripts may run script code while drawing.
local function drawLevel()
    interp.apply(movingBodies(), alpha)
    camera.frame(level, localIds())
    level:drawBackground()
    camera.pushWorld()
    worldPushed = true
    level:draw()
    fx.drawDebris()
    fx.drawCorpses()
    level:drawPlayers()
    fx.drawExplosions()
    level:drawWorld()
    camera.popWorld()
    worldPushed = false
    level:drawHud()
    hud.draw(level.players, LOCAL_COOP and #slots < Level.MAX_PLAYERS, localIds())
end

-- A full-screen message over the level: a title, a line of detail, and the
-- restart/menu keys.
local function drawBanner(title, detail, color)
    love.graphics.setColor(0, 0, 0, 0.75)
    love.graphics.rectangle("fill", 0, 0, render.width, render.height)
    love.graphics.setColor(color[1], color[2], color[3], 1)
    text.printf(title, 0, render.height / 2 - 40, render.width, "center", 16)
    love.graphics.setColor(1, 1, 1, 0.85)
    if detail then
        text.printf(detail, 24, render.height / 2 - 12, render.width - 48, "center", 10)
    end
    text.printf("R / E / BACK vote restart   ESC menu", 0, render.height / 2 + 30, render.width, "center", 10)
end

local OUTCOME_TITLES = { win = "LEVEL CLEAR", lose = "GAME OVER" }

-- Shown once a script stopped the level (Level:fault), or a gamemode ended it
-- (Level:finish).
local function drawStopped()
    if level.faulted then
        local reason = level.faulted:match("^[^\n]*"):sub(1, 140)
        drawBanner("THIS LEVEL STOPPED", reason, { 1, 0.85, 0.4 })
    else
        local finished = level.finished
        local title = OUTCOME_TITLES[finished.outcome] or finished.outcome:upper()
        drawBanner(title, finished.message, finished.outcome == "lose" and { 1, 0.45, 0.4 } or { 0.55, 1, 0.6 })
    end
end

function gameplay.draw()
    level:protect(drawLevel)
    if worldPushed then
        camera.popWorld()
        worldPushed = false
    end
    interp.restore()
    love.graphics.setShader()
    if level.faulted or level.finished then
        drawStopped()
    end
    hud.drawVote(level.players, votes, countdown)
end

-- Exposed for automated smoke tests and debugging.
function gameplay.getPlayer(index)
    local slot = slots[index or 1]
    return slot and slot.player
end

function gameplay.getLevel()
    return level
end

-- Replace a slot's input source (tests drive players with scripted sources).
function gameplay.setSource(index, source)
    slots[index].source = source
end

sceneEngine.register("gameplay", {
    enter = function()
        audio.playMusic("playground.wav")
        watchdog.enter(level.root)
    end,
    exit = function()
        watchdog.leave()
    end,
    update = gameplay.update,
    keypressed = gameplay.keypressed,
    gamepadpressed = gameplay.gamepadpressed,
    draw = gameplay.draw,
})

return gameplay
