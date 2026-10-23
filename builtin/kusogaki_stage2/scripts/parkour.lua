-- Level script: the crumbling blocks (entities/crumble.lua). One whose fuse
-- has run out falls apart; RETURN_TIME seconds later a new one takes its
-- place, so players who respawn can cross again.
local parkour = {}

local RETURN_TIME = 3

function parkour.load(level)
    level.net.crumbled = {} -- { x, y, time } of the blocks gone for now
end

function parkour.update(delta, level)
    local net = level.net
    for i = #level.blocks, 1, -1 do
        local block = level.blocks[i]
        if block.typeName == "crumble" and block.fuse == 0 then
            block:breakApart() -- debris chips and the sound
            level:removeEntity(block)
            net.crumbled[#net.crumbled + 1] = { x = block.x, y = block.y, time = RETURN_TIME }
        end
    end
    for i = #net.crumbled, 1, -1 do
        local gone = net.crumbled[i]
        gone.time = gone.time - delta
        if gone.time <= 0 then
            table.remove(net.crumbled, i)
            level:spawnEntity("crumble", gone.x, gone.y)
        end
    end
end

return parkour
