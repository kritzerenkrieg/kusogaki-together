-- Trigger rules. See ARCHITECTURE.md (Level rules: triggers).
local physics = require("core.physics")

local triggers = {}

-- Each live player overlapping a trigger calls trigger:onTouch(player), every
-- step while they overlap. Triggers are never solid.
function triggers.touch(level, players)
    for _, trigger in ipairs(level.triggers) do
        for _, player in ipairs(players) do
            if not player.dead and physics.overlaps(player, trigger) and trigger.onTouch then
                trigger:onTouch(player)
            end
        end
    end
end

return triggers
