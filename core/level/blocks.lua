-- Hazard and block rules. See ARCHITECTURE.md (Level rules: hazards and blocks).
local events = require("core.level.events")
local claims = require("core.level.claims")

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

local function touches(player, static)
    return not player.dead and player.contacts and player.contacts[static]
end

function blocks.touchHazards(level, players)
    for _, hazard in ipairs(level.hazards) do
        for _, player in ipairs(players) do
            if touches(player, hazard) then
                hazard:onTouch(player)
            end
        end
    end
end

-- `brokenBy` is the player who broke the block (kick or touch); an explosive
-- block kills only them. When several players touch it in one step, the first
-- in join order breaks it. Marked first, then removed backwards, so removing
-- one does not skip the next.
function blocks.breakTouched(level, players)
    for _, block in ipairs(level.blocks) do
        for _, player in ipairs(players) do
            if not block.brokenBy and touches(player, block) and block:onTouch(player) then
                block.brokenBy = player
                claims.note(level, { k = "touchBlock", id = block.id, player = player })
            end
        end
    end
    if level.remoteWorld then
        return -- a client: the claims stage shows it, the host breaks it
    end
    for i = #level.blocks, 1, -1 do
        local block = level.blocks[i]
        if block.brokenBy then
            level:removeEntity(block)
            if block.explosive then
                events.entity("explosion", block)
                if not block.brokenBy.remote then -- a remote breaker died on its own machine
                    block.brokenBy:die()
                end
            else
                events.entity("debris", block)
            end
        end
    end
end

return blocks
