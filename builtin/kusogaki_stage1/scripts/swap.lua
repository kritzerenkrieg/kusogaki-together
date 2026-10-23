-- Level script: the bricks over the spike pit swap places with the spikes.
-- The first time a player touches one of those bricks, every brick there turns
-- into a spike and every spike into metal, so the floor of the pit becomes
-- solid metal and the row above becomes spikes. It stays swapped until the
-- level restarts.
local swap = {}

local AREA = { left = 2256, right = 2464, top = 246, bottom = 278 } -- the bricks (y 254) and spikes (y 270)

local function inArea(entity)
    return entity.x > AREA.left and entity.x < AREA.right and entity.y > AREA.top and entity.y < AREA.bottom
end

local function touching(player, entity)
    return not player.dead
        and math.abs(player.x - entity.x) <= (player.w + entity.w) / 2 + 1
        and math.abs(player.y - entity.y) <= (player.h + entity.h) / 2 + 1
end

function swap.load(level)
    local net = level.net
    net.swapped = false
    net.swapBricks, net.swapSpikes = {}, {}
    for _, block in ipairs(level.blocks) do
        if block.typeName == "brick" and inArea(block) then
            net.swapBricks[#net.swapBricks + 1] = block.id
        end
    end
    for _, hazard in ipairs(level.hazards) do
        if hazard.typeName == "spike" and inArea(hazard) then
            net.swapSpikes[#net.swapSpikes + 1] = hazard.id
        end
    end
end

-- Turn each one into the other type, in place. A brick broken earlier is gone,
-- so the spike under it has no brick above it and simply becomes metal.
local function replace(level, ids, typeName)
    local spawned = {}
    for _, id in ipairs(ids) do
        local entity = level:get(id)
        if entity and not entity.removed then
            local x, y = entity.x, entity.y
            level:removeEntity(entity)
            spawned[#spawned + 1] = level:spawnEntity(typeName, x, y)
        end
    end
    return spawned
end

function swap.update(delta, level)
    local net = level.net
    if net.swapped then
        return
    end
    for _, id in ipairs(net.swapBricks) do
        local brick = level:get(id)
        if brick and not brick.removed then
            for _, player in ipairs(level.players) do
                if touching(player, brick) then
                    net.swapped = true
                    local bricks, spikes = net.swapBricks, net.swapSpikes
                    replace(level, spikes, "metal")
                    local newSpikes = replace(level, bricks, "spike")
                    if newSpikes[1] then
                        newSpikes[1]:playSfx("hit.wav")
                    end
                    return
                end
            end
        end
    end
end

return swap
