local render = require("core.graphics.render")
local camera = require("core.graphics.camera")
local fx = require("core.graphics.fx")
local sceneEngine = require("core.scenes")
local gameplay = require("scenes.gameplay")

require("scenes.title_screen")

function love.load()
    render.load()

    local titleScreen = require("scenes.title_screen")
    titleScreen.load()
    gameplay.load()

    fx.setSceneManager(function(name)
        sceneEngine.switch(name)
    end)

    sceneEngine.start("menu")
end

function love.update(delta)
    fx.update(delta)
    sceneEngine.update(delta)
end

function love.keypressed(key)
    sceneEngine.keypressed(key)
end

function love.draw()
    render.beginFrame()
    camera.pushCamera()
    sceneEngine.draw()
    camera.popCamera()
    fx.drawTransition()
    render.present()
end