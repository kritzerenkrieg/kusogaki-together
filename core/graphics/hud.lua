-- Gameplay HUD: each local player's state in the corner, markers at the screen
-- edge for players outside the view, and a join hint. Level-specific overlays
-- (e.g. the example level's controls tutorial) are level scripts, not part of
-- the HUD.
local text = require("core.text")
local camera = require("core.graphics.camera")
local render = require("core.graphics.render")
local config = require("core.player.config")

local hud = {}

local JOIN_HINT = "JOIN: I or gamepad A"
local MARKER = 6 -- px, half the edge marker's height

local function setTint(player, alpha)
    local tint = config.TINTS[player.id] or config.TINTS[1]
    love.graphics.setColor(tint[1], tint[2], tint[3], alpha)
end

-- A small arrow on the left or right screen edge, at the player's height.
local function drawEdgeMarker(player)
    local screenX = player.x - camera.x
    local y = math.min(math.max(player.y, MARKER), render.height - MARKER)
    setTint(player, 0.9)
    if screenX < 0 then
        love.graphics.polygon("fill", 2, y, 10, y - MARKER, 10, y + MARKER)
    elseif screenX > render.width then
        local x = render.width - 2
        love.graphics.polygon("fill", x, y, x - 8, y - MARKER, x - 8, y + MARKER)
    end
end

-- players: the level's players in join order; canJoin: show the join hint.
function hud.draw(players, canJoin)
    for i, player in ipairs(players) do
        local carry = player.carrying and player.carrying.name or "-"
        setTint(player, 0.85)
        text.print(("P%d %s  CARRY: %s"):format(player.id, player.state:upper(), carry), 8, 8 + (i - 1) * 12, 10)
        if not player.dead then
            drawEdgeMarker(player)
        end
    end
    if canJoin then
        love.graphics.setColor(1, 1, 1, 0.6)
        text.print(JOIN_HINT, render.width - text.getWidth(JOIN_HINT, 10) - 8, 8, 10)
    end
end

return hud
