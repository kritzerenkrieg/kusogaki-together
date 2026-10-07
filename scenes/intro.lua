local intro = {}
local render = require("core.graphics.render")
local text = require("core.text")
local sceneEngine = require("core.scenes")

function intro.keypressed(key)
    if key == "return" or key == "space" then
        return "gameplay"
    end
end

function intro.draw(canvasWidth)
    love.graphics.setColor(0.95, 0.76, 0.32)
    text.printf("The Guild Awaits", 0, 100, canvasWidth, "center")
    love.graphics.setColor(0.78, 0.82, 0.90)
    text.printf("Your first alchemical day begins now.", 0, 160, canvasWidth, "center")
    text.printf("Press ENTER to enter the guild.", 0, 230, canvasWidth, "center")
end

sceneEngine.register("intro", {
    keypressed = function(key)
        local nextScene = intro.keypressed(key)
        if nextScene then
            local fx = require("core.graphics.fx")
            fx.toScene(nextScene, 0.5, { color = { 0, 0, 0, 1 } })
        end
    end,
    draw = function()
        intro.draw(render.width)
    end
})

return intro
