-- Level script: the Dodon King fight (entities/dodon_king.lua).
-- - Its armor: thrown props and blasts kill an enemy outright; for the king
--   they take one health instead (a stage before "enemyDeaths").
-- - It cannot be stomped (entities/dodon_king.lua), so players have to kick
--   it, throw props at it or blow it up.
-- - At half health a dambo drops from the sky, far from the king, every
--   DAMBO_EVERY seconds (at most MAX_MINIONS at once).
-- - Its fake box skill: every BOX_EVERY seconds (less when angry) a lit fake
--   box falls next to the nearest player. Thrown back at the king, its blast
--   takes one health.
-- - Its health bar at the top once it is awake (its title changes once it
--   got back up from playing dead), and the respawn counter.
-- - Beating it wins the level, a moment after it falls.
local boss = {}

local MAX_MINIONS = 3
local DAMBO_EVERY = 4 -- seconds between dambos once it is angry
local BOX_EVERY = 3 -- seconds between lit boxes
local ANGRY_BOX_EVERY = 2
local BOX_FUSE = 2.5
local SKY = 320 -- px above the ground that things fall from
local FAR = 120 -- a dambo lands at least this far from the king
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

local function nearestPlayer(level, entity)
    local best, bestDistance
    for _, player in ipairs(level.players) do
        local distance = math.abs(player.x - entity.x)
        if not player.dead and (not best or distance < bestDistance) then
            best, bestDistance = player, distance
        end
    end
    return best
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
    net.damboTimer, net.boxTimer = 0, BOX_EVERY
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
        if entity.awake and entity.fakeDead <= 0 then
            if entity:angry() then
                net.damboTimer = net.damboTimer + delta
                if net.damboTimer >= DAMBO_EVERY and minionCount(level) < MAX_MINIONS then
                    net.damboTimer = 0
                    local room = entity.x - entity.left > entity.right - entity.x
                    local x = room and random(entity.left + 20, math.floor(entity.x - FAR)) or random(math.ceil(entity.x + FAR), entity.right - 20)
                    local minion = level:spawnEntity("dambo", x, entity.y - SKY)
                    minion.minion = true
                end
            end
            net.boxTimer = net.boxTimer - delta
            if net.boxTimer <= 0 then
                net.boxTimer = entity:angry() and ANGRY_BOX_EVERY or BOX_EVERY
                local target = nearestPlayer(level, entity)
                if target then
                    local side = entity.x < target.x and -1 or 1 -- lands between the player and the king
                    level:spawnEntity("fake_box", target.x + side * 40, target.y - SKY, { lit = true, fuse = BOX_FUSE })
                end
            end
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
