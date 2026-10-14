-- Explosions in a level. See ARCHITECTURE.md (Level rules: blasts).
local events = require("core.level.events")
local playerConfig = require("core.player.config")

local blast = {}

-- Distance from (x, y) to the nearest point of body's box.
local function distanceToBox(x, y, body)
    local dx = math.max(math.abs(x - body.x) - body.w / 2, 0)
    local dy = math.max(math.abs(y - body.y) - body.h / 2, 0)
    return math.sqrt(dx * dx + dy * dy)
end

-- Blow up `source` (an enemy or prop with blastRadius), reporting an
-- "explosion" event. Players and other live
-- enemies inside the radius die; enemies are thrown away from the blast.
function blast.explode(level, source, players)
    local radius = source.blastRadius or 0
    events.entity("explosion", source, { radius = radius }) -- clients check their own player
    for _, player in ipairs(players) do
        if not player.dead and distanceToBox(source.x, source.y, player) <= radius then
            player:die()
        end
    end
    for _, enemy in ipairs(level.enemies) do
        if enemy ~= source and not enemy.killedBy and not enemy.held and not enemy.detonated
            and distanceToBox(source.x, source.y, enemy) <= radius then
            enemy.killedBy = "blast"
            enemy.kickVx = (enemy.x < source.x and -1 or 1) * playerConfig.CONFIG.enemyKickPush
            enemy.kickVy = playerConfig.CONFIG.enemyKickLift
        end
    end
end

return blast
