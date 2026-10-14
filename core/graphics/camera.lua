local render = require("core.graphics.render")

-- The view onto the world: its top-left corner (x, y) in world px and its
-- zoom, set each frame from the level's camera state (camera.frame), plus
-- screen shake.
local camera = {
    x = 0, -- world x at the screen's left edge
    y = 0, -- world y at the screen's top edge
    zoom = 1,
    active = false,
    duration = 0,
    elapsed = 0,
    intensity = 0,
    ox = 0,
    oy = 0,
}

camera.MIN_ZOOM, camera.MAX_ZOOM = 0.25, 4

local function clamp(value, low, high)
    return math.min(math.max(value, low), high)
end

-- Midpoint of the players `include(player)` accepts, or nil when none does.
local function centerOf(level, include)
    local left, right, top, bottom
    for _, player in ipairs(level.players) do
        if include(player) then
            left = math.min(left or player.x, player.x)
            right = math.max(right or player.x, player.x)
            top = math.min(top or player.y, player.y)
            bottom = math.max(bottom or player.y, player.y)
        end
    end
    if left then
        return (left + right) / 2, (top + bottom) / 2
    end
    return nil
end

-- What "players" follows: the live local players; when they are all dead, the
-- live remote ones (watch the others); when everyone is dead, the local
-- players again. `locals` is a set of player ids played on this machine; nil
-- means every player is local (local co-op).
local function playersCenter(level, locals)
    local function isLocal(player)
        return locals == nil or locals[player.id] == true
    end
    local x, y = centerOf(level, function(player) return isLocal(player) and not player.dead end)
    if not x then
        x, y = centerOf(level, function(player) return not player.dead end)
    end
    if not x then
        x, y = centerOf(level, isLocal)
    end
    if not x then
        x, y = centerOf(level, function() return true end)
    end
    return x, y
end

-- Point the view for this frame from level.camera (scripts may change it):
--   follow  "players" (default): the midpoint of the live local players
--           (see playersCenter), both axes
--           "screens": the screen-sized cell holding that midpoint (flip-screen)
--           a body (player or entity): centered on it
--           nil: centered on (x, y)
--   zoom    0.25..4 (1 = one world px per canvas px)
--   clamp   false lets the view leave the level's rectangle
-- `locals`: the ids of the players this machine plays (nil: all of them).
function camera.frame(level, locals)
    local view = level.camera or {}
    local zoom = clamp(type(view.zoom) == "number" and view.zoom or 1, camera.MIN_ZOOM, camera.MAX_ZOOM)
    local viewW, viewH = render.width / zoom, render.height / zoom
    local follow = view.follow
    local cx, cy
    if follow == "players" or follow == "screens" then
        cx, cy = playersCenter(level, locals)
    elseif type(follow) == "table" and type(follow.x) == "number" and type(follow.y) == "number" then
        cx, cy = follow.x, follow.y
    end
    if not cx then
        cx = type(view.x) == "number" and view.x or level.spawn.x
        cy = type(view.y) == "number" and view.y or level.spawn.y
    end
    local left, top
    if follow == "screens" then
        left, top = math.floor(cx / viewW) * viewW, math.floor(cy / viewH) * viewH
    else
        left, top = cx - viewW / 2, cy - viewH / 2
    end
    if view.clamp ~= false then
        left = clamp(left, 0, math.max(0, level.width - viewW))
        top = clamp(top, 0, math.max(0, level.height - viewH))
    end
    camera.zoom = zoom
    camera.x = math.floor(left * zoom) / zoom -- whole canvas pixels
    camera.y = math.floor(top * zoom) / zoom
end

-- World position -> canvas position.
function camera.toScreen(x, y)
    return (x - camera.x) * camera.zoom, (y - camera.y) * camera.zoom
end

-- The world rectangle in view: x, y, w, h.
function camera.view()
    return camera.x, camera.y, render.width / camera.zoom, render.height / camera.zoom
end

-- World-space drawing between these two; screen-space (HUD) outside them.
function camera.pushWorld()
    love.graphics.push()
    love.graphics.scale(camera.zoom)
    love.graphics.translate(-camera.x, -camera.y)
end

function camera.popWorld()
    love.graphics.pop()
end

function camera.shake(duration, intensity)
    camera.active = true
    camera.duration = math.max(0, duration or 0.3)
    camera.elapsed = 0
    camera.intensity = intensity or 8
    camera.ox, camera.oy = 0, 0
end

function camera.getShakeOffset()
    return camera.ox, camera.oy
end

function camera.pushCamera()
    love.graphics.push()
    love.graphics.translate(camera.ox, camera.oy)
end

function camera.popCamera()
    love.graphics.pop()
end

function camera.update(dt)
    if camera.active then
        camera.elapsed = camera.elapsed + dt
        if camera.elapsed >= camera.duration then
            camera.active = false
            camera.ox, camera.oy = 0, 0
        else
            local env = 1 - camera.elapsed / camera.duration
            local amp = camera.intensity * env
            camera.ox = (love.math.random() * 2 - 1) * amp
            camera.oy = (love.math.random() * 2 - 1) * amp
        end
    end
end

return camera
