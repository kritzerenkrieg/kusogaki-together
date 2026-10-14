-- Gameplay HUD: each local player's state in the corner, markers at the screen
-- edge for every player outside the view (local or remote), and a join hint. Level-specific overlays
-- (e.g. the example level's controls tutorial) are level scripts, not part of
-- the HUD.
local text = require("core.text")
local camera = require("core.graphics.camera")
local render = require("core.graphics.render")
local config = require("core.player.config")

local hud = {}

local JOIN_HINT = "JOIN: J or gamepad A"
local MARKER = 6 -- px, half the edge marker's height

local function setTint(player, alpha)
    local tint = config.TINTS[player.id] or config.TINTS[1]
    love.graphics.setColor(tint[1], tint[2], tint[3], alpha)
end

-- A small arrow on the left or right screen edge, at the player's height.
local function drawEdgeMarker(player)
    local screenX, screenY = camera.toScreen(player.x, player.y)
    local y = math.min(math.max(screenY, MARKER), render.height - MARKER)
    setTint(player, 0.9)
    if screenX < 0 then
        love.graphics.polygon("fill", 2, y, 10, y - MARKER, 10, y + MARKER)
    elseif screenX > render.width then
        local x = render.width - 2
        love.graphics.polygon("fill", x, y, x - 8, y - MARKER, x - 8, y + MARKER)
    end
end

-- players: the level's players in join order; canJoin: show the join hint;
-- locals: the ids of the players this machine plays (nil: all of them).
function hud.draw(players, canJoin, locals)
    local row = 0
    for _, player in ipairs(players) do
        if locals == nil or locals[player.id] then
            local carried = player.carrying
            local carry = carried and (carried.isPlayer and ("P" .. carried.id) or carried.name) or "-"
            setTint(player, 0.85)
            text.print(("P%d %s  CARRY: %s"):format(player.id, player.state:upper(), carry), 8, 8 + row * 12, 10)
            row = row + 1
        end
        if not player.dead then
            drawEdgeMarker(player)
        end
    end
    if canJoin then
        love.graphics.setColor(1, 1, 1, 0.6)
        text.print(JOIN_HINT, render.width - text.getWidth(JOIN_HINT, 10) - 8, 8, 10)
    end
end

-- The restart vote: each player's tag, lit when they voted, and the countdown
-- once the vote passes. Nothing while nobody votes.
function hud.drawVote(players, votes, countdown)
    local count = 0
    for _, player in ipairs(players) do
        count = count + (votes[player.id] and 1 or 0)
    end
    if count == 0 then
        return
    end
    local y = render.height - 48
    local label = ("RESTART %d/%d"):format(count, #players)
    local tagWidth = text.getWidth("P0", 10) + 8
    local x = render.width / 2 - (text.getWidth(label, 10) + 8 + tagWidth * #players) / 2
    love.graphics.setColor(1, 1, 1, 0.9)
    text.print(label, x, y, 10)
    x = x + text.getWidth(label, 10) + 8
    for _, player in ipairs(players) do
        setTint(player, votes[player.id] and 1 or 0.25)
        text.print("P" .. player.id, x, y, 10)
        x = x + tagWidth
    end
    if countdown then
        love.graphics.setColor(1, 0.9, 0.4, 1)
        text.printf(("RESTARTING IN %d"):format(math.ceil(countdown)), 0, y - 24, render.width, "center", 16)
    end
end

return hud
