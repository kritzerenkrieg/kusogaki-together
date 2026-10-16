-- Level script: the Dodon King fight (entities/dodon_king.lua).
-- - Its armor: thrown props and blasts kill an enemy outright; for the king
--   they take one health instead (a stage before "enemyDeaths").
-- - At half health, each landing from a leap sends a dodon in (at most
--   MAX_MINIONS at once).
-- - Its health bar at the top once it is awake (its title changes once it
--   got back up from playing dead), and the respawn counter.
-- - Beating it wins the level, a moment after it falls.
local boss = {}

local MAX_MINIONS = 3
local WIN_DELAY = 1.5 -- seconds from the king's fall to the win
local BAR_WIDTH = 240

local function king(level)
    local entity = level:get(level.net.kingId)
    return entity and not entity.removed and entity or nil
end

local function armor(level)
    local entity = king(level)
    if entity and entity.killedBy and not entity:isDown() then
        local cause = entity.killedBy
        entity.killedBy = nil
        entity:hit()
        if entity:isDown() then
            entity.killedBy = cause
        end
    end
end

local function minionCount(level)
    local count = 0
    for _, enemy in ipairs(level.enemies) do
        if enemy.minion and not enemy.killedBy then
            count = count + 1
        end
    end
    return count
end

function boss.load(level)
    local net = level.net
    for _, enemy in ipairs(level.enemies) do
        if enemy.typeName == "dodon_king" then
            net.kingId = enemy.id
            net.kingHp, net.kingMaxHp = enemy.hp, enemy.maxHp
        end
    end
    net.kingAwake = false
    net.downTime = nil -- seconds since the king fell
    level:addStage("kingArmor", armor, { before = "enemyDeaths" })
end

function boss.update(delta, level)
    local net = level.net
    local entity = king(level)
    if entity then
        net.kingHp = entity.hp
        net.kingRevived = entity.revived and entity.fakeDead <= 0
        net.kingAwake = net.kingAwake or entity.awake == true
        if entity.landed and entity:angry() and minionCount(level) < MAX_MINIONS then
            local side = random(0, 1) == 0 and -1 or 1
            local x = math.max(entity.left, math.min(entity.right, entity.x + side * 40))
            local minion = level:spawnEntity("dodon", x, entity.y + entity.h / 2 - 8)
            minion.minion = true
            minion.dir = side
        end
    elseif net.kingId then
        net.kingHp = 0
        net.downTime = (net.downTime or 0) + delta
        if net.downTime >= WIN_DELAY and not level.finished then
            local respawns = 0
            for _, player in ipairs(level.players) do
                respawns = respawns + player.respawns
            end
            level:finish("win", ("The Dodon King is down! %d respawns"):format(respawns))
        end
    end
end

function boss.drawHud(ui, level)
    local net = level.net
    local width = ui.size()
    if net.kingAwake and net.kingMaxHp then
        local x, y = width / 2 - BAR_WIDTH / 2, 22
        local title = net.kingRevived and "DODON KING (NOT DEAD YET)" or "DODON KING"
        ui.color(1, 0.85, 0.3, 1)
        ui.text(title, width / 2 - ui.textWidth(title, 10) / 2, 8, 10)
        ui.color(0, 0, 0, 0.6)
        ui.rect(x - 2, y - 2, BAR_WIDTH + 4, 12)
        ui.color(0.35, 0.08, 0.1, 1)
        ui.rect(x, y, BAR_WIDTH, 8)
        ui.color(0.9, 0.2, 0.25, 1)
        ui.rect(x, y, BAR_WIDTH * math.max(net.kingHp or 0, 0) / net.kingMaxHp, 8)
        ui.color(1, 1, 1, 0.8)
        ui.rect(x - 2, y - 2, BAR_WIDTH + 4, 12, "line")
    end
    local parts = { "RESPAWNS" }
    for _, player in ipairs(level.players) do
        parts[#parts + 1] = ("P%d %d"):format(player.id, player.respawns or 0)
    end
    local line = table.concat(parts, "  ")
    ui.color(0.92, 0.94, 0.98, 0.9)
    ui.text(line, 8, 8, 10)
end

return boss
