-- Gameplay scene: loads a level and its local players, and runs them.
-- Each player is a slot { source, player }: an input device (core/input.lua)
-- and the player it drives. Slots survive restarts; players do not.
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

local gameplay = {}

local LEVEL_NAME = "example"

local level
local slots = {}                    -- local players in join order
local clock = fixedstep.new(1 / 60) -- the simulation runs in fixed 60 Hz ticks
local alpha = 0                     -- how far the frame sits between ticks (drawing)

-- Add a player for a slot at (x, y); that point is also its respawn point.
local function spawn(x, y)
    local player = playerModule.new(x, y)
    level:addPlayer(player)
    return player
end

-- Midpoint of the live players (all players when everyone is dead).
local function followPlayers()
    local left, right
    for _, slot in ipairs(slots) do
        local player = slot.player
        if not player.dead then
            left = math.min(left or player.x, player.x)
            right = math.max(right or player.x, player.x)
        end
    end
    if not left then
        left, right = slots[1].player.x, slots[1].player.x
    end
    camera.follow((left + right) / 2, level.width)
end

local function buildLevel()
    -- A fresh seed per (re)start; in network play the host picks it.
    level = Level.load(LEVEL_NAME, { seed = love.math.random(1, 2147483646) })
    fx.clearEffects()
    for _, slot in ipairs(slots) do
        slot.player = spawn(level.spawn.x, level.spawn.y)
    end
    clock:reset()
    interp.clear()
    alpha = 0
    followPlayers()
end

local function sameDevice(a, b)
    return a.kind == b.kind and a.layout == b.layout and a.joystick == b.joystick
end

-- Join a new local player driven by `source`. It appears at player 1's current
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
    buildLevel()
end

function gameplay.update(delta)
    alpha = clock:advance(delta, function(step)
        for _, slot in ipairs(slots) do
            slot.player.input = slot.source.read()
        end
        interp.record(movingBodies())
        level:update(step)
        level:protect(present.all, level:takeEvents(), level)
    end)
end

function gameplay.keypressed(key)
    if key == "escape" then
        fx.toScene("menu", 0.5, { ease = "smoothstep" })
    elseif key == "r" then
        buildLevel()
    else
        local layout = input.layoutForJoinKey(key)
        if layout then
            gameplay.join(input.keyboard(layout))
        end
    end
end

function gameplay.gamepadpressed(joystick, button)
    if button == "a" or button == "start" then
        gameplay.join(input.gamepad(joystick))
    end
end

local worldPushed = false -- camera.pushWorld is active (popped even after a failure)

-- Everything the level draws. It runs under script limits (level:protect):
-- entities, events and level scripts may run script code while drawing.
local function drawLevel()
    interp.apply(movingBodies(), alpha)
    followPlayers()
    level:drawBackground()
    camera.pushWorld()
    worldPushed = true
    level:draw()
    fx.drawDebris()
    fx.drawCorpses()
    for i = #slots, 1, -1 do -- player 1 on top
        slots[i].player:draw()
    end
    fx.drawExplosions()
    camera.popWorld()
    worldPushed = false
    level:drawHud()
    hud.draw(level.players, #slots < Level.MAX_PLAYERS)
end

-- Shown once a script stopped the level (see Level:fault).
local function drawStopped()
    love.graphics.setColor(0, 0, 0, 0.75)
    love.graphics.rectangle("fill", 0, 0, render.width, render.height)
    love.graphics.setColor(1, 0.85, 0.4, 1)
    text.printf("THIS LEVEL STOPPED", 0, render.height / 2 - 40, render.width, "center", 16)
    love.graphics.setColor(1, 1, 1, 0.85)
    local reason = level.faulted:match("^[^\n]*"):sub(1, 140)
    text.printf(reason, 24, render.height / 2 - 12, render.width - 48, "center", 10)
    text.printf("R restart   ESC menu", 0, render.height / 2 + 30, render.width, "center", 10)
end

function gameplay.draw()
    level:protect(drawLevel)
    if worldPushed then
        camera.popWorld()
        worldPushed = false
    end
    interp.restore()
    love.graphics.setShader()
    if level.faulted then
        drawStopped()
    end
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
    end,
    update = gameplay.update,
    keypressed = gameplay.keypressed,
    gamepadpressed = gameplay.gamepadpressed,
    draw = gameplay.draw,
})

return gameplay
