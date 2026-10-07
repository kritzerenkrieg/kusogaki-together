local controls = {}
local mathx = require("core.math")

function controls.update(scene, player, delta, width, height)
    if scene ~= "gameplay" then
        return
    end

    local horizontal = 0
    local vertical = 0

    if love.keyboard.isDown("left") then horizontal = horizontal - 1 end
    if love.keyboard.isDown("right") then horizontal = horizontal + 1 end
    if love.keyboard.isDown("up") then vertical = vertical - 1 end
    if love.keyboard.isDown("down") then vertical = vertical + 1 end

    player.x = mathx.clamp(player.x + horizontal * player.speed * delta, player.size / 2, width - player.size / 2)
    player.y = mathx.clamp(player.y + vertical * player.speed * delta, player.size / 2, height - player.size / 2)
end

function controls.keypressed(scene, key, titleScreen, intro)
    if scene == "menu" then
        local nextScene = titleScreen.keypressed(key)
        if nextScene == "intro" then
            return "intro"
        elseif nextScene == "exit" then
            love.event.quit()
        end
    elseif scene == "intro" then
        local nextScene = intro.keypressed(key)
        if nextScene == "gameplay" then
            return "gameplay"
        end
    end

    return scene
end

return controls
