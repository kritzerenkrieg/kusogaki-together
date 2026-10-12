local render = require("core.graphics.render")

local camera = {
    x = 0, -- world x at the screen's left edge (follow)
    active = false,
    duration = 0,
    elapsed = 0,
    intensity = 0,
    ox = 0,
    oy = 0,
}

-- Center `targetX` on screen, clamped so the view stays inside [0, worldWidth].
function camera.follow(targetX, worldWidth)
    local maxX = math.max(0, worldWidth - render.width)
    camera.x = math.floor(math.min(math.max(targetX - render.width / 2, 0), maxX))
end

-- World-space drawing between these two; screen-space (HUD) outside them.
function camera.pushWorld()
    love.graphics.push()
    love.graphics.translate(-camera.x, 0)
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
