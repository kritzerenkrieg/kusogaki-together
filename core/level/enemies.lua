-- Enemy rules. See ARCHITECTURE.md (Level rules: enemies).
local physics = require("core.physics")
local render = require("core.graphics.render")
local events = require("core.level.events")
local playerConfig = require("core.player.config")
local blast = require("core.level.blast")
local claims = require("core.level.claims")

local enemies = {}

local THROWN_KILL_SPEED = 64 -- px/s; a prop faster than this kills an enemy it hits
local WAKE_DISTANCE = render.width -- px; an enemy starts updating once a player is a screen width away (horizontally)

local function isLive(enemy)
    return not enemy.killedBy and not enemy.held and not enemy.detonated
end

-- Statics, loose props and other live enemies. A prop overlapping the enemy is
-- left out, or it would snap the enemy to one of its faces.
local function solidsFor(level, enemy)
    local solids = {}
    for _, static in ipairs(level.statics) do
        solids[#solids + 1] = static
    end
    for _, prop in ipairs(level.props) do
        if not prop.held and not physics.overlaps(prop, enemy) then
            solids[#solids + 1] = prop
        end
    end
    for _, other in ipairs(level.enemies) do
        if other ~= enemy and isLive(other) then
            solids[#solids + 1] = other
        end
    end
    return solids
end

function enemies.resolvePropHits(level)
    for _, enemy in ipairs(level.enemies) do
        if isLive(enemy) then
            for _, prop in ipairs(level.props) do
                local speed = math.max(math.abs(prop.vx), math.abs(prop.vy))
                if not prop.held and speed > THROWN_KILL_SPEED and physics.overlaps(enemy, prop) then
                    enemy.killedBy = "kick"
                    enemy.kickVx = prop.vx
                    enemy.kickVy = playerConfig.CONFIG.kickLift
                    break
                end
            end
        end
    end
end

function enemies.pushOutProps(level)
    for _, enemy in ipairs(level.enemies) do
        if isLive(enemy) then
            for _, prop in ipairs(level.props) do
                if not prop.held then
                    physics.pushOut(prop, enemy, level.statics)
                end
            end
        end
    end
end

-- Asleep until a live player comes within WAKE_DISTANCE; then awake for good.
local function wakeUp(enemy, players)
    if not enemy.awake then
        for _, player in ipairs(players) do
            if not player.dead and math.abs(player.x - enemy.x) <= WAKE_DISTANCE then
                enemy.awake = true
                break
            end
        end
    end
    return enemy.awake
end

-- Each awake enemy gets the level with its own `statics` (statics, loose props
-- and other live enemies); every other field reads through to the level.
function enemies.update(level, delta, players)
    local view = { __index = level }
    for _, enemy in ipairs(level.enemies) do
        if not enemy.killedBy and not enemy.detonated and (enemy.held or wakeUp(enemy, players)) then
            enemy:update(delta, setmetatable({ statics = solidsFor(level, enemy) }, view))
        end
    end
end

-- True when the player's feet were at or above the enemy's top last frame.
local function wasAbove(player, enemy)
    return player.prevY + player.h / 2 <= enemy.y - enemy.h / 2 + 2
end

-- Players in join order: once one stomps an enemy, it is no longer live, so a
-- second player touching it in the same step is safe.
function enemies.touchPlayers(level, players)
    for i = #level.enemies, 1, -1 do
        local enemy = level.enemies[i]
        for _, player in ipairs(players) do
            if isLive(enemy) and not player.dead and physics.overlaps(player, enemy) then
                if player.falling and wasAbove(player, enemy) and enemy:onStomp(player) then
                    enemy.killedBy = "stomp"
                    player:bounce()
                    claims.note(level, { k = "stomp", id = enemy.id, player = player })
                elseif player.kickGrace <= 0 and enemy:onTouch(player) then
                    player:die()
                end
            end
        end
    end
end

-- Remove dead and detonated enemies, reporting a "corpse" or an explosion.
function enemies.removeDead(level, players)
    for i = #level.enemies, 1, -1 do
        local enemy = level.enemies[i]
        if enemy.detonated then
            level:removeEntity(enemy)
            blast.explode(level, enemy, players)
        elseif enemy.killedBy then
            level:removeEntity(enemy)
            events.entity("corpse", enemy, { cause = enemy.killedBy, vx = enemy.kickVx, vy = enemy.kickVy })
        end
    end
end

return enemies
