if SIM_TEST then
    require("tests.sim_test") -- exits when done; see conf.lua
    return
end

local render = require("core.graphics.render")
local camera = require("core.graphics.camera")
local fx = require("core.graphics.fx")
local sceneEngine = require("core.scenes")
local gameplay = require("scenes.gameplay")
local watchdog = require("core.watchdog")
local text = require("core.text")

require("scenes.title_screen")
require("scenes.lobby")
require("scenes.room")
require("scenes.levels")
local options = require("scenes.options")
local levels = require("core.levels")

local NOTICE_SECONDS = 10
local noticeTime = 0 -- seconds left showing why the last run was closed

function love.load()
    watchdog.start()
    if watchdog.lastReport then
        noticeTime = NOTICE_SECONDS
    end
    render.load()
    options.load()
    levels.seed() -- the built-in levels into the save directory's levels/

    local titleScreen = require("scenes.title_screen")
    titleScreen.load()
    pcall(gameplay.load) -- ready for the command line's shortcuts; a broken level waits for the menu

    fx.setSceneManager(function(name)
        sceneEngine.switch(name)
    end)

    sceneEngine.start("menu")
end

function love.update(delta)
    watchdog.beat()
    noticeTime = math.max(0, noticeTime - delta)
    fx.update(delta)
    sceneEngine.update(delta)
end

function love.keypressed(key)
    sceneEngine.keypressed(key)
end

function love.textinput(t)
    sceneEngine.textinput(t)
end

function love.gamepadpressed(joystick, button)
    sceneEngine.gamepadpressed(joystick, button)
end

function love.mousemoved(x, y)
    sceneEngine.mousemoved(render.toCanvas(x, y))
end

function love.mousepressed(x, y, button)
    local canvasX, canvasY = render.toCanvas(x, y)
    sceneEngine.mousepressed(canvasX, canvasY, button)
end

-- Why the previous run ended: a level froze the game (core/watchdog.lua).
local function drawNotice()
    local report = watchdog.lastReport
    local message = ("The game was closed last time: level %s stopped responding."):format(report.root)
    if report.blocked then
        message = message .. " It is now blocked."
    end
    love.graphics.setColor(0, 0, 0, 0.8)
    love.graphics.rectangle("fill", 0, render.height - 34, render.width, 34)
    love.graphics.setColor(1, 0.85, 0.4, math.min(1, noticeTime))
    text.printf(message, 8, render.height - 28, render.width - 16, "left", 10)
    love.graphics.setColor(1, 1, 1, 1)
end

function love.draw()
    render.beginFrame()
    camera.pushCamera()
    sceneEngine.draw()
    camera.popCamera()
    fx.drawTransition()
    if noticeTime > 0 then
        drawNotice()
    end
    render.present()
end