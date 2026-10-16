-- Level script: the gap after the second checkpoint. It looks like a gap to
-- jump, but an invisible bridge (a clear static in level.json) spans it. A
-- player who jumps over it rises into ZONE, and spikes pop up where the jump
-- lands; they sink back once nobody has been in the zone for UP_TIME seconds.
-- A player who walks across on the bridge stays under the zone.
local bridge = {}

local ZONE = { x = 1920, y = 170, w = 64, h = 80 } -- over the gap, above a standing player's head
local SPIKE_XS = { 1992, 2008, 2024 }   -- the landing ground past the gap
local SPIKE_Y = 270
local UP_TIME = 1.5

local function inZone(player)
    return not player.dead
        and math.abs(player.x - (ZONE.x + ZONE.w / 2)) < (ZONE.w + player.w) / 2
        and math.abs(player.y - (ZONE.y + ZONE.h / 2)) < (ZONE.h + player.h) / 2
end

function bridge.load(level)
    level.net.bridgeSpikes = nil -- ids of the spikes while they are up
    level.net.bridgeTime = 0
end

function bridge.update(delta, level)
    local net = level.net
    local jumped = false
    for _, player in ipairs(level.players) do
        if inZone(player) then
            jumped = true
        end
    end
    if jumped then
        if not net.bridgeSpikes then
            net.bridgeSpikes = {}
            for i, x in ipairs(SPIKE_XS) do
                local spike = level:spawnEntity("spike", x, SPIKE_Y)
                net.bridgeSpikes[i] = spike.id
            end
            level:get(net.bridgeSpikes[1]):playSfx("hit.wav")
        end
        net.bridgeTime = UP_TIME
    elseif net.bridgeSpikes then
        net.bridgeTime = net.bridgeTime - delta
        if net.bridgeTime <= 0 then
            for _, id in ipairs(net.bridgeSpikes) do
                local spike = level:get(id)
                if spike then
                    level:removeEntity(spike)
                end
            end
            net.bridgeSpikes = nil
        end
    end
end

return bridge
