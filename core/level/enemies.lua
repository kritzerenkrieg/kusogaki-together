-- Enemy rules. See ARCHITECTURE.md (Level rules: enemies).
local physics = require("core.physics")
local fx = require("core.graphics.fx")
local playerConfig = require("core.player.config")

local enemies = {}

local THROWN_KILL_SPEED = 64 -- px/s; a prop faster than this kills an enemy it hits

local function isLive(enemy)
    return not enemy.killedBy and not enemy.held
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

function enemies.update(level, delta)
    for _, enemy in ipairs(level.enemies) do
        if not enemy.killedBy then
            enemy:update(delta, { statics = solidsFor(level, enemy) })
        end
    end
end

-- True when the player's feet were at or above the enemy's top last frame.
local function wasAbove(player, enemy)
    return player.prevY + player.h / 2 <= enemy.y - enemy.h / 2 + 2
end

function enemies.touchPlayer(level, player)
    for i = #level.enemies, 1, -1 do
        local enemy = level.enemies[i]
        if isLive(enemy) and not player.dead and physics.overlaps(player, enemy) then
            if player.falling and wasAbove(player, enemy) and enemy:onStomp(player) then
                enemy.killedBy = "stomp"
                player:bounce()
            elseif player.kickGrace <= 0 and enemy:onTouch(player) then
                player:die()
            end
        end
        if enemy.killedBy == "stomp" then
            table.remove(level.enemies, i)
            fx.flatten(enemy.x, enemy.y, enemy.w, enemy.h, enemy.image, enemy:region())
        elseif enemy.killedBy then
            table.remove(level.enemies, i)
            fx.throwAway(enemy.x, enemy.y, enemy.w, enemy.h, enemy.image, enemy:region(),
                enemy.kickVx, enemy.kickVy)
        end
    end
end

return enemies
