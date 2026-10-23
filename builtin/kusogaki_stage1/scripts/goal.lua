-- Level script: the goal zone past the flag pole and the respawn counter HUD.
-- The level is won when every player in the game stands (alive) inside the
-- zone. The engine counts respawns (player.respawns), keeps them across
-- restarts and resets them on a win.
local goal = {}

local ZONE = { x = 3248, y = 150, w = 136, h = 128 } -- past the pole, down to the ground

local function inZone(player)
    return not player.dead
        and math.abs(player.x - (ZONE.x + ZONE.w / 2)) <= ZONE.w / 2
        and math.abs(player.y - (ZONE.y + ZONE.h / 2)) <= ZONE.h / 2
end

function goal.load(level)
    level.net.inZone = 0
end

function goal.update(delta, level)
    local inside, total = 0, 0
    for _, player in ipairs(level.players) do
        total = total + 1
        if inZone(player) then
            inside = inside + 1
        end
    end
    level.net.inZone = inside
    if total > 0 and inside == total then
        local respawns = 0
        for _, player in ipairs(level.players) do
            respawns = respawns + player.respawns
        end
        level:finish("win", ("Everyone made it! %d respawns"):format(respawns))
    end
end

function goal.drawBehind(ui, level)
    ui.color(1, 0.85, 0.3, 0.25)
    ui.rect(ZONE.x, ZONE.y, ZONE.w, ZONE.h)
    ui.color(1, 0.85, 0.3, 0.8)
    ui.rect(ZONE.x, ZONE.y, ZONE.w, ZONE.h, "line")
    ui.text("GOAL", ZONE.x + ZONE.w / 2 - ui.textWidth("GOAL", 10) / 2, ZONE.y + 6, 10)
end

function goal.drawHud(ui, level)
    local width = ui.size()
    local parts = { ("GOAL %d/%d    RESPAWNS"):format(level.net.inZone or 0, #level.players) }
    for _, player in ipairs(level.players) do
        parts[#parts + 1] = ("P%d %d"):format(player.id, player.respawns or 0)
    end
    local line = table.concat(parts, "  ")
    ui.color(0.92, 0.94, 0.98, 1)
    ui.text(line, width / 2 - ui.textWidth(line, 10) / 2, 8, 10)
end

return goal
