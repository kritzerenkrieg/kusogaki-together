-- Gameplay HUD: player state in the corner. Level-specific overlays (e.g. the
-- example level's controls tutorial) are level scripts, not part of the HUD.
local text = require("core.text")

local hud = {}

function hud.draw(player)
    local carry = player.carrying and player.carrying.name or "-"
    love.graphics.setColor(1, 1, 1, 0.85)
    text.print(("STATE: %s   CARRY: %s"):format(player.state, carry), 8, 8, 10)
end

return hud
