-- Hazard and block rules. See ARCHITECTURE.md (Level rules: hazards and blocks).
local fx = require("core.graphics.fx")
local audio = require("core.audio")

local blocks = {}

function blocks.touchHazards(level, player)
    for _, hazard in ipairs(level.hazards) do
        if not player.dead and player.contacts and player.contacts[hazard] then
            hazard:onTouch(player)
        end
    end
end

-- Backwards, so removing one does not skip the next.
function blocks.breakTouched(level, player)
    for i = #level.blocks, 1, -1 do
        local block = level.blocks[i]
        local touched = not player.dead and player.contacts and player.contacts[block] and block:onTouch(player)
        if block.broken or touched then
            table.remove(level.blocks, i)
            level:removeStatic(block)
            fx.debris(block.x, block.y, block.w, block.h, block.image, level.statics)
            audio.playSfx("debris.wav")
        end
    end
end

return blocks
