-- Gameplay scene: loads a level and a player, and runs them.
local sceneEngine = require("core.scenes")
local fx = require("core.graphics.fx")
local hud = require("core.graphics.hud")
local playerModule = require("core.player")
local feedback = require("core.player.feedback")
local Level = require("core.level")
local audio = require("core.audio")

local gameplay = {}

local LEVEL_NAME = "example"

local level
local player

local function buildLevel()
    level = Level.load(LEVEL_NAME)
    fx.clearEffects()

    player = playerModule.new(level.spawn.x, level.spawn.y)
    player.onEvent = feedback.onEvent
end

function gameplay.load()
    playerModule.load()
    buildLevel()
end

function gameplay.update(delta)
    level:update(delta, player)
end

function gameplay.keypressed(key)
    if key == "escape" then
        fx.toScene("menu", 0.5, { ease = "smoothstep" })
    elseif key == "r" then
        buildLevel()
    end
end

function gameplay.draw()
    level:draw()
    fx.drawDebris()
    fx.drawCorpses()
    player:draw()
    hud.draw(player)
end

-- Exposed for automated smoke tests and debugging.
function gameplay.getPlayer()
    return player
end

sceneEngine.register("gameplay", {
    enter = function()
        audio.playMusic("playground.wav")
    end,
    update = gameplay.update,
    keypressed = gameplay.keypressed,
    draw = gameplay.draw,
})

return gameplay
