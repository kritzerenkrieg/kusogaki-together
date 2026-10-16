-- Level script: the timers of the trolls (entities/hidden_block.lua and
-- entities/trap.lua). A hidden block's metal block goes away REVEAL_TIME
-- seconds after it showed itself; a timed trap takes back what it spawned once
-- its time runs out, and arms again.
local trolls = {}

local REVEAL_TIME = 2

local function remove(level, id)
    local entity = id and level:get(id)
    if entity then
        level:removeEntity(entity)
    end
end

function trolls.update(delta, level)
    for i = #level.triggers, 1, -1 do
        local trigger = level.triggers[i]
        if trigger.typeName == "hidden_block" and trigger.blockId then
            trigger.revealTime = (trigger.revealTime or 0) + delta
            if trigger.revealTime >= REVEAL_TIME then
                remove(level, trigger.blockId)
                level:removeEntity(trigger)
            end
        elseif trigger.typeName == "trap" and trigger.sprung and trigger.time then
            trigger.timer = trigger.timer - delta
            if trigger.timer <= 0 then
                for _, id in ipairs(trigger.spawned) do
                    remove(level, id)
                end
                trigger.spawned = {}
                trigger.sprung = false
            end
        end
    end
end

return trolls
