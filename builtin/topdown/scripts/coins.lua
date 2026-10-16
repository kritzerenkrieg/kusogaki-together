-- Level script: a top-down coin race. Shows what a level can change:
-- - zero gravity (level.json "gravity": 0) and a camera that follows the
--   players on both axes, zoomed in (level.json "camera");
-- - custom input actions up, down and dash (level.json "actions");
-- - its own player controller (8-way walking and a dash) instead of the
--   platformer;
-- - coins spawned while the level runs (level:spawnEntity);
-- - an extra simulation stage ("magnet": coins drift toward a close player);
-- - a win condition (level:finish), script state synced to clients
--   (level.net, player.net) and messages for popups (level:send).
local game = {}

local GOAL = 10           -- coins to win
local MAX_COINS = 6       -- coins on the field at once
local SPAWN_EVERY = 0.8   -- seconds between new coins
local SPEED = 110         -- walking speed (px/s)
local DASH_SPEED = 280
local DASH_TIME = 0.15
local DASH_COOLDOWN = 0.6
local MAGNET_RADIUS = 36
local MAGNET_SPEED = 70
local POPUP_TICKS = 45

-- ── Player controller ─────────────────────────────────────────────────────
local Walker = {}

function Walker.update(player, delta, level)
    local input = player.input or {}
    local dx = (input.right and 1 or 0) - (input.left and 1 or 0)
    local dy = (input.down and 1 or 0) - (input.up and 1 or 0)
    if dx ~= 0 and dy ~= 0 then
        dx, dy = dx * 0.7071, dy * 0.7071
    end
    player.dashTime = math.max(0, (player.dashTime or 0) - delta)
    player.dashCooldown = math.max(0, (player.dashCooldown or 0) - delta)
    if player.pressed.dash and player.dashCooldown == 0 and (dx ~= 0 or dy ~= 0) then
        player.dashTime, player.dashCooldown = DASH_TIME, DASH_COOLDOWN
        player.dashX, player.dashY = dx, dy
    end
    if player.dashTime > 0 then
        player.vx, player.vy = player.dashX * DASH_SPEED, player.dashY * DASH_SPEED
    else
        player.vx, player.vy = dx * SPEED, dy * SPEED
    end
    if dx ~= 0 then
        player.facing = dx > 0 and 1 or -1
    end
    Entity.move(player, delta, level) -- move and stop at walls
    player.onGround = true            -- the platformer sprite then shows idle/run
    player:animate(delta)
end

-- ── Coins ─────────────────────────────────────────────────────────────────
local spawnTimer = 0

local function blocked(level, x, y, size)
    for _, static in ipairs(level.statics) do
        if math.abs(x - static.x) < (size + static.w) / 2 and math.abs(y - static.y) < (size + static.h) / 2 then
            return true
        end
    end
    return false
end

local function coinCount(level)
    local count = 0
    for _, trigger in ipairs(level.triggers) do
        if trigger.typeName == "coin" then
            count = count + 1
        end
    end
    return count
end

local function spawnCoin(level)
    for _ = 1, 8 do
        local x, y = random(32, level.width - 32), random(32, level.height - 32)
        if not blocked(level, x, y, 24) then
            level:spawnEntity("coin", x, y)
            return
        end
    end
end

-- Stage: coins near a live player drift toward them.
local function magnet(level, delta)
    for _, coin in ipairs(level.triggers) do
        if coin.typeName == "coin" then
            for _, player in ipairs(level.players) do
                local dx, dy = player.x - coin.x, player.y - coin.y
                local distance = math.sqrt(dx * dx + dy * dy)
                if not player.dead and distance > 0 and distance < MAGNET_RADIUS then
                    coin.x = coin.x + dx / distance * MAGNET_SPEED * delta
                    coin.y = coin.y + dy / distance * MAGNET_SPEED * delta
                    break
                end
            end
        end
    end
end

-- ── Hooks ─────────────────────────────────────────────────────────────────
function game.load(level)
    level.playerController = Walker
    level:addStage("magnet", magnet, { before = "triggers" })
    level.net.goal = GOAL
    level.net.tick = 0
end

function game.playerJoined(player)
    player.net.score = 0
end

function game.update(delta, level)
    level.net.tick = level.net.tick + 1
    spawnTimer = spawnTimer - delta
    if spawnTimer <= 0 and coinCount(level) < MAX_COINS then
        spawnCoin(level)
        spawnTimer = SPAWN_EVERY
    end
end

-- Presentation (runs on every machine): "+1" popups from coin messages.
local popups = {}

function game.message(name, data, level)
    if name == "coin" then
        popups[#popups + 1] = { x = data.x, y = data.y, born = level.net.tick }
    end
end

function game.drawBehind(ui, level)
    local x, y, w, h = ui.view()
    ui.color(1, 1, 1, 0.04)
    local cell = 32
    for gx = math.floor(x / cell) * cell, x + w, cell do
        ui.line(gx, y, gx, y + h)
    end
    for gy = math.floor(y / cell) * cell, y + h, cell do
        ui.line(x, gy, x + w, gy)
    end
end

function game.drawWorld(ui, level)
    for i = #popups, 1, -1 do
        local popup = popups[i]
        local age = level.net.tick - popup.born
        if age > POPUP_TICKS then
            table.remove(popups, i)
        else
            ui.color(1, 0.95, 0.5, 1 - age / POPUP_TICKS)
            ui.text("+1", popup.x - 4, popup.y - 12 - age * 0.3, 8)
        end
    end
end

function game.drawHud(ui, level)
    local width, height = ui.size()
    ui.color(0, 0, 0, 0.45)
    ui.rect(0, height - 26, width, 26)
    local parts = {}
    for _, player in ipairs(level.players) do
        parts[#parts + 1] = ("P%d %d"):format(player.id, player.net.score or 0)
    end
    ui.color(0.92, 0.94, 0.98, 1)
    ui.text(table.concat(parts, "   ") .. ("      first to %d"):format(GOAL), 8, height - 20, 10)
    local hint = "ARROWS move   V dash"
    ui.text(hint, width - ui.textWidth(hint, 10) - 8, height - 20, 10)
end

return game
