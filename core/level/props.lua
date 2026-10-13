-- Prop rules. See ARCHITECTURE.md (Level rules: props).
local blast = require("core.level.blast")

local props = {}

-- A prop that sets `detonated` (e.g. fake_box) is removed and explodes. A
-- player still holding it lets go first.
function props.removeDetonated(level, players)
    for i = #level.props, 1, -1 do
        local prop = level.props[i]
        if prop.detonated then
            level:removeEntity(prop)
            for _, player in ipairs(players) do
                if player.carrying == prop then
                    player.carrying = nil
                end
            end
            prop.held = false
            blast.explode(level, prop, players)
        end
    end
end

return props
