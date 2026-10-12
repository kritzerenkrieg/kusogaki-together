-- Enemy rules. See ARCHITECTURE.md (Level rules: enemies).
local physics = require("core.physics")
local fx = require("core.graphics.fx")
local render = require("core.graphics.render")
local audio = require("core.audio")
local playerConfig = require("core.player.config")
local blast = require("core.level.blast")

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

-- Each awake enemy sees its own solids and every player (for triggers and targeting).
function enemies.update(level, delta, players)
    for _, enemy in ipairs(level.enemies) do
        if not enemy.killedBy and not enemy.detonated and (enemy.held or wakeUp(enemy, players)) then
            enemy:update(delta, { statics = solidsFor(level, enemy), players = players })
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
    end
end

-- Remove dead and detonated enemies, leaving a corpse or an explosion.
function enemies.removeDead(level, players)
    for i = #level.enemies, 1, -1 do
        local enemy = level.enemies[i]
        if enemy.detonated then
            table.remove(level.enemies, i)
            blast.explode(level, enemy, players)
        elseif enemy.killedBy == "stomp" then
            table.remove(level.enemies, i)
            fx.flatten(enemy.x, enemy.y, enemy.w, enemy.h, enemy.image, enemy:region())
            audio.playSfx("hit.wav")
        elseif enemy.killedBy then
            table.remove(level.enemies, i)
            fx.throwAway(enemy.x, enemy.y, enemy.w, enemy.h, enemy.image, enemy:region(),
                enemy.kickVx, enemy.kickVy)
            if enemy.killedBy ~= "blast" then -- the explosion already has its sound
                audio.playSfx("hit.wav")
            end
        end
    end
end

return enemies
