-- Props as one-way platforms for the player: the player lands on a prop's top
-- face when falling onto it, and never snaps into a spot occupied by another body.
local geometry = require("core.physics.geometry")

local oneway = {}

-- True when the position the player would be snapped to on top of a platform
-- is not occupied by another body. On a vertically stacked pair the lower
-- box's top plane lies inside the upper box; snapping the player there would
-- wedge them between the boxes with onGround stuck true (standing on an
-- "invisible" floor at the seam), so the snap must only fire on a free spot.
local function landingIsClear(player, platform, platformTop, bodies)
    if not bodies then
        return true
    end
    local landing = {
        x = player.x,
        y = platformTop - player.h / 2,
        w = player.w,
        h = player.h,
    }
    for _, other in ipairs(bodies) do
        if other ~= player and other ~= platform and not other.held
            and geometry.overlaps(landing, other) then
            return false
        end
    end
    return true
end

-- Rule: props act as one-way platforms for the player. Returns the pair as
-- (player, other) when exactly one of a/b is the player, otherwise nil.
function oneway.playerPair(a, b)
    if a.isPlayer and not b.isPlayer then
        return a, b
    elseif b.isPlayer and not a.isPlayer then
        return b, a
    end
    return nil
end

-- Rule: on descent, a player whose feet cross a prop's top lands on it. Only the
-- player's vertical position is resolved, so walking across a box top cannot push
-- the supporting box or its neighboring stack sideways. Returns true when handled.
function oneway.tryLanding(player, platform, bodies)
    local previousPlayerBottom = (player.prevY or player.y) + player.h / 2
    local playerBottom = player.y + player.h / 2
    local platformTop = platform.y - platform.h / 2
    if player.vy >= platform.vy
        and previousPlayerBottom <= platformTop
        and playerBottom >= platformTop
        and landingIsClear(player, platform, platformTop, bodies) then
        player.y = platformTop - player.h / 2
        player.vy = math.min(player.vy, platform.vy)
        player.onGround = true
        return true
    end
    return false
end

return oneway
