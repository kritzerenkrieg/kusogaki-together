-- Falling out of the level. See ARCHITECTURE.md (Level rules: bounds).
local bounds = {}

local MARGIN = 32 -- px below the level's bottom edge that counts as fallen out

local function fellOut(level, body)
    return body.y - body.h / 2 > level.height + MARGIN
end

local function removeFallen(level, list)
    for i = #list, 1, -1 do
        local body = list[i]
        if not body.held and fellOut(level, body) then
            level:removeEntity(body)
        end
    end
end

-- Players who fall into a pit die; props and enemies that fall out are removed.
function bounds.removeFallen(level, players)
    for _, player in ipairs(players) do
        if not player.dead and fellOut(level, player) then
            player:die()
        end
    end
    removeFallen(level, level.props)
    removeFallen(level, level.enemies)
end

return bounds
