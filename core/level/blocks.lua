-- Hazard and block rules. See ARCHITECTURE.md (Level rules: hazards and blocks).
local fx = require("core.graphics.fx")
local audio = require("core.audio")

local blocks = {}

-- Static entities never get update() (Entity:update would apply gravity); a
-- type that animates defines animate(delta) instead.
function blocks.animate(level, delta)
    for _, list in ipairs({ level.hazards, level.blocks }) do
        for _, entity in ipairs(list) do
            if entity.animate then
                entity:animate(delta)
            end
        end
    end
end

function blocks.touchHazards(level, player)
    for _, hazard in ipairs(level.hazards) do
        if not player.dead and player.contacts and player.contacts[hazard] then
            hazard:onTouch(player)
        end
    end
end

-- Backwards, so removing one does not skip the next. `brokenBy` is the player
-- who broke the block (kick or touch); an explosive block kills only them.
function blocks.breakTouched(level, player)
    for i = #level.blocks, 1, -1 do
        local block = level.blocks[i]
        if not block.brokenBy and not player.dead and player.contacts
            and player.contacts[block] and block:onTouch(player) then
            block.brokenBy = player
        end
        if block.brokenBy then
            table.remove(level.blocks, i)
            level:removeStatic(block)
            if block.explosive then
                fx.explosion(block.x, block.y, block.w, block.h, block.image, level.statics, block:region())
                block.brokenBy:die()
            else
                fx.debris(block.x, block.y, block.w, block.h, block.image, level.statics, block:region())
            end
            audio.playSfx("debris.wav")
        end
    end
end

return blocks
