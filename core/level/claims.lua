-- Optimistic claims (Phase 2 step 4, NETWORKING.md Interactions between
-- owners). On a network client (`level.remoteWorld`) the host owns the world,
-- so when this machine's player changes it (stomps or kicks an enemy, breaks
-- a block, kicks a prop, grabs, throws or drops something) the rules note a
-- claim here. The client shows the result at once (the "claims" stage) and
-- the scene sends the claim; the host judges it with the same entity hooks
-- (claims.judge) and answers. Until that answer shows up in a snapshot the
-- claimed entity keeps the client's version; a denied claim is then undone
-- by the host's snapshot. The claimer's own movement (a bounce) is never
-- undone.
--
-- Kicking another machine's player is a claim on every machine, the host
-- included: the victim's machine applies the knock to its own player.
--
-- A claim: { k = kind, id = entity id (or player id for kickPlayer), d =
-- facing (-1/1), vx, vy (throws), at = the claimer's moment (claims.moment),
-- player = the claiming player (local only) }.
local events = require("core.level.events")
local playerConfig = require("core.player.config")

local CONFIG = playerConfig.CONFIG
local claims = {}

claims.KINDS = {
    stomp = true, kill = true, kickBlock = true, touchBlock = true, kickProp = true,
    grab = true, throw = true, drop = true, kickPlayer = true,
}
claims.MAX_PER_STEP = 16
claims.REACH = 96   -- px between the claimer (as the host sees it) and the target
claims.MAX_THROW = 800 -- px/s

local MOVING_UP, FALLING, JUMPING, FACING_RIGHT = 1, 2, 4, 8

-- The claimer's moment: what entity hooks look at, as the claimer saw it
-- ({ x, y, prevY, vx, vy, flags }). The host judges with it: its own copy of
-- the claimer is a little late and not simulated (no movingUp, no prevY).
function claims.moment(player)
    local flags = (player.movingUp and MOVING_UP or 0) + (player.falling and FALLING or 0)
        + (player.jumping and JUMPING or 0) + ((player.facing or 1) >= 0 and FACING_RIGHT or 0)
    return { player.x, player.y, player.prevY or player.y, player.vx or 0, player.vy or 0, flags }
end

function claims.validMoment(at)
    if type(at) ~= "table" or #at ~= 6 or next(at, 6) ~= nil then
        return false
    end
    for i = 1, 5 do
        local value = at[i]
        if type(value) ~= "number" or value ~= value or math.abs(value) > 2 ^ 24 then
            return false
        end
    end
    return type(at[6]) == "number" and at[6] % 1 == 0 and at[6] >= 0 and at[6] <= 15
end

-- The player as the claimer saw itself: reads through to `player`, with the
-- moment's position, motion and flags. What a hook writes on it is dropped.
local function asSeen(player, at)
    local function flag(bit) return math.floor(at[6] / bit) % 2 == 1 end
    return setmetatable({
        x = at[1], y = at[2], prevY = at[3], vx = at[4], vy = at[5],
        movingUp = flag(MOVING_UP), falling = flag(FALLING), jumping = flag(JUMPING),
        facing = flag(FACING_RIGHT) and 1 or -1,
    }, { __index = player })
end

-- A rule changed the world for this machine's player: note the claim.
-- Everything but kickPlayer only needs a claim on a network client.
function claims.note(level, claim)
    if not level.remoteWorld and claim.k ~= "kickPlayer" then
        return
    end
    if claim.player then
        claim.at = claims.moment(claim.player)
    end
    level.claims = level.claims or {}
    if #level.claims < claims.MAX_PER_STEP then
        level.claims[#level.claims + 1] = claim
    end
end

-- The claims noted since the last call; the list is then empty.
function claims.take(level)
    local list = level.claims or {}
    level.claims = {}
    return list
end

-- Take an entity out of a client's level for now; `graveyard` keeps it so a
-- denied claim (or a late event) can bring it back.
local function hide(level, entity)
    level:removeEntity(entity)
    level.graveyard = level.graveyard or {}
    level.graveyard[entity.id] = entity
    level.shown = level.shown or {}
    level.shown[entity.id] = true -- its corpse/debris is shown; skip the host's event for it
end

-- The "claims" stage (clients only): show this step's claims at once.
function claims.predict(level)
    if not level.remoteWorld then
        return
    end
    for _, claim in ipairs(level.claims or {}) do
        local entity = claim.k ~= "kickPlayer" and level:get(claim.id) or nil
        if entity and (claim.k == "stomp" or claim.k == "kill") then
            events.entity("corpse", entity, { cause = entity.killedBy, vx = entity.kickVx, vy = entity.kickVy })
            hide(level, entity)
        elseif entity and (claim.k == "kickBlock" or claim.k == "touchBlock") then
            events.entity(entity.explosive and "explosion" or "debris", entity)
            hide(level, entity)
            if entity.explosive and claim.player then
                claim.player:die() -- an explosive block kills whoever broke it
            end
        end
    end
end

-- Is `player` inside the blast of an explosion event (with a radius)? Each
-- machine checks its own player against the host's explosions.
function claims.caughtBy(player, event)
    if player.dead or type(event.radius) ~= "number" or type(event.x) ~= "number" or type(event.y) ~= "number" then
        return false
    end
    local dx = math.max(math.abs(event.x - player.x) - player.w / 2, 0)
    local dy = math.max(math.abs(event.y - player.y) - player.h / 2, 0)
    return math.sqrt(dx * dx + dy * dy) <= event.radius
end

-- Knock a player back from a kick facing `direction` (never lethal).
function claims.knock(player, direction)
    player.vx = direction * CONFIG.playerKickPush
    player.vy = CONFIG.playerKickLift
    player.onGround = false
    player.knockback = CONFIG.knockbackTime
end

local function near(a, b)
    return math.abs(a.x - b.x) <= claims.REACH and math.abs(a.y - b.y) <= claims.REACH
end

local function liveEnemy(entity)
    return entity and entity.kind == "enemy" and not entity.killedBy and not entity.held
        and not entity.detonated and not entity.removed
end

local function clamp(value, limit)
    return math.max(-limit, math.min(limit, tonumber(value) or 0))
end

local function direction(claim)
    return (claim.d or 1) < 0 and -1 or 1
end

-- The host judges a claim by `player` (a puppet, or its own player for
-- kickPlayer). `newest` is where the host last heard the claimer was (its
-- newest state; default: where it is shown). The claim's moment must be near
-- that; the entity hooks then run with the player as the claimer saw itself
-- (the same hooks the rules use). Returns true when it holds (the world is
-- changed; the next steps show it), plus for kickPlayer the victim and the
-- knock direction.
function claims.judge(level, player, claim, newest)
    newest = newest or player
    if player.dead then
        return false
    end
    local at = newest
    if claim.at then
        if not claims.validMoment(claim.at) then
            return false
        end
        at = { x = claim.at[1], y = claim.at[2] }
        if not near(at, newest) then
            return false -- not where the host last heard it was
        end
    end
    local seen = claim.at and asSeen(player, claim.at) or player
    if claim.k == "kickPlayer" then
        for _, victim in ipairs(level.players) do
            if victim.id == claim.id and victim ~= player and not victim.dead and not victim.held
                and near(at, victim) then
                return true, victim, direction(claim)
            end
        end
        return false
    end
    local entity = level:get(claim.id)
    if not entity or not near(at, entity) then
        return false
    end
    local k = claim.k
    if k == "stomp" and liveEnemy(entity) then
        if entity.onStomp and entity:onStomp(seen) then
            entity.killedBy = "stomp"
            return true
        end
    elseif k == "kill" and liveEnemy(entity) then
        if entity.onKick and entity:onKick(seen) then
            entity.killedBy = "kick"
            entity.kickVx = direction(claim) * CONFIG.enemyKickPush
            entity.kickVy = CONFIG.enemyKickLift
            return true
        end
    elseif (k == "kickBlock" or k == "touchBlock") and entity.kind == "block" and not entity.brokenBy then
        local broke
        if k == "kickBlock" then
            broke = entity.onKick and entity:onKick(seen)
        else
            broke = entity.onTouch and entity:onTouch(seen)
        end
        if broke then
            entity.brokenBy = player
            return true
        end
    elseif k == "kickProp" and entity.kind == "prop" and not entity.held then
        entity.vx = direction(claim) * CONFIG.kickPush
        entity.vy = CONFIG.kickLift
        entity.onGround = false
        return true
    elseif k == "grab" and not player.carrying and not entity.held
        and (entity.kind == "prop" or liveEnemy(entity)) then
        player.carrying = entity
        entity.held = true
        entity.vx, entity.vy = 0, 0
        return true
    elseif (k == "throw" or k == "drop") and player.carrying == entity then
        entity.held = false
        entity.vx, entity.vy = clamp(claim.vx, claims.MAX_THROW), clamp(claim.vy, claims.MAX_THROW)
        player.carrying = nil
        return true
    end
    return false
end

return claims
