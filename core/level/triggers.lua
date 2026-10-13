-- Trigger rules. See ARCHITECTURE.md (Level rules: triggers).
local physics = require("core.physics")

local triggers = {}

-- Each live player overlapping a trigger calls trigger:onTouch(player, level),
-- every step while they overlap. Triggers are never solid. The list is copied
-- first, so onTouch may remove its trigger (a pickup) or spawn new ones.
function triggers.touch(level, players)
    local list = {}
    for i, trigger in ipairs(level.triggers) do
        list[i] = trigger
    end
    for _, trigger in ipairs(list) do
        for _, player in ipairs(players) do
            if not trigger.removed and not player.dead and physics.overlaps(player, trigger)
                and trigger.onTouch then
                trigger:onTouch(player, level)
            end
        end
    end
end

return triggers
