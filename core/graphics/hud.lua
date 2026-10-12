-- Gameplay HUD: control hints along the bottom, player state in the corner.
local render = require("core.graphics.render")
local text = require("core.text")

local hud = {}

function hud.draw(player)
    love.graphics.setColor(0, 0, 0, 0.45)
    love.graphics.rectangle("fill", 0, render.height - 26, render.width, 26)

    love.graphics.setColor(0.92, 0.94, 0.98, 1)
    text.print(
        "ARROWS move   Z jump   X kick / throw   C hold (grab & carry)   ESC menu   R restart",
        8, render.height - 20, 10
    )

    local carry = player.carrying and player.carrying.name or "-"
    love.graphics.setColor(1, 1, 1, 0.85)
    text.print(("STATE: %s   CARRY: %s"):format(player.state, carry), 8, 8, 10)
end

return hud
