local render = require("core.graphics.render")
local camera = require("core.graphics.camera")
local mathx = require("core.math")

local fx = {}
local transition = {
    active = false,
    mode = "fade",
    direction = "out",
    duration = 0,
    half = 0,
    elapsed = 0,
    alpha = 0,
    color = { 0, 0, 0, 1 },
    ease = mathx.easings.smoothstep,
    target = nil,
    switched = false,
    callback = nil,
    manager = nil,
}

local defaultManager = nil

-- Resolve a named easing function; fall back to smoothstep if unavailable.
local function getEase(name)
    return mathx.easings[name] or mathx.easings.smoothstep
end

-- Route a scene change through the configured manager or the default scene switcher.
local function doSceneSwitch(name, manager)
    if manager then
        manager(name)
    elseif defaultManager then
        defaultManager(name)
    else
        local sceneEngine = require("core.scenes")
        if sceneEngine and sceneEngine.switch then
            sceneEngine.switch(name)
        end
    end
end

-- Cleanly finish a transition and invoke its completion callback.
local function finishTransition()
    local callback = transition.callback
    transition.active = false
    transition.alpha = 0
    transition.mode = "fade"
    transition.target = nil
    transition.switched = false
    transition.callback = nil
    transition.manager = nil
    if callback then callback() end
end

-- Start a fade transition in the requested direction with optional timing and color.
local function startFade(direction, duration, color, ease, callback)
    if transition.active then
        return false
    end

    duration = duration or 0.3
    color = color or { 0, 0, 0, 1 }
    transition.color = { color[1] or 0, color[2] or 0, color[3] or 0, color[4] or 1 }

    if duration <= 0 then
        transition.alpha = direction == "out" and 1 or 0
        if callback then callback() end
        return true
    end

    transition.active = true
    transition.mode = "fade"
    transition.direction = direction
    transition.duration = duration
    transition.elapsed = 0
    transition.alpha = direction == "out" and 0 or 1
    transition.ease = ease or mathx.easings.smoothstep
    transition.callback = callback
    return true
end

-- Register the function used to switch scenes when no scene manager is passed.
function fx.setSceneManager(fn)
    defaultManager = fn
end

-- Fade to black over the given duration.
function fx.fadeOut(duration, color, callback)
    return startFade("out", duration, color, mathx.easings.smoothstep, callback)
end

-- Fade from black to the active scene over the given duration.
function fx.fadeIn(duration, color, callback)
    return startFade("in", duration, color, mathx.easings.smoothstep, callback)
end

-- Briefly flash a color while easing out for emphasis.
function fx.flash(duration, color, callback)
    return startFade("in", duration, color, mathx.easings.easeout, callback)
end

-- Transition to a new scene by fading out, switching scenes, then fading back in.
function fx.toScene(sceneName, duration, options)
    if transition.active then
        return false
    end

    options = options or {}
    duration = duration or 0.5
    local half = math.max(0, duration / 2)
    local color = options.color or { 0, 0, 0, 1 }

    if half <= 0 then
        doSceneSwitch(sceneName, options.manager)
        if options.callback then options.callback() end
        return true
    end

    transition.active = true
    transition.mode = "scene"
    transition.direction = "out"
    transition.half = half
    transition.elapsed = 0
    transition.alpha = 0
    transition.switched = false
    transition.color = { color[1] or 0, color[2] or 0, color[3] or 0, color[4] or 1 }
    transition.ease = getEase(options.ease)
    transition.target = sceneName
    transition.manager = options.manager
    transition.callback = options.callback
    return true
end

-- Return whether a transition or scene switch is currently in progress.
function fx.isTransitioning()
    return transition.active
end

-- Clear the current transition state without running a callback.
function fx.resetTransition()
    transition.active = false
    transition.alpha = 0
    transition.mode = "fade"
    transition.target = nil
    transition.switched = false
    transition.callback = nil
    transition.manager = nil
end

-- Advance the transition animation and switch scenes at the midpoint when needed.
function fx.update(dt)
    if transition.active then
        transition.elapsed = transition.elapsed + dt

        if transition.mode == "scene" then
            if not transition.switched then
                local t = mathx.clamp(transition.elapsed / transition.half, 0, 1)
                transition.alpha = transition.ease(t)
                if t >= 1 then
                    transition.switched = true
                    transition.elapsed = 0
                    doSceneSwitch(transition.target, transition.manager)
                    if transition.callback then transition.callback() end
                end
            else
                local t = mathx.clamp(transition.elapsed / transition.half, 0, 1)
                transition.alpha = 1 - transition.ease(t)
                if t >= 1 then
                    finishTransition()
                end
            end
        else
            local t = mathx.clamp(transition.elapsed / transition.duration, 0, 1)
            if transition.direction == "out" then
                transition.alpha = transition.ease(t)
            else
                transition.alpha = 1 - transition.ease(t)
            end
            if t >= 1 then
                finishTransition()
            end
        end
    end

    camera.update(dt)
end

-- Draw the current transition overlay across the screen if it is visible.
function fx.drawTransition()
    if transition.active or transition.alpha > 0 then
        local c = transition.color
        love.graphics.setColor(c[1], c[2], c[3], c[4] * transition.alpha)
        love.graphics.rectangle("fill", 0, 0, render.width, render.height)
    end
end

return fx
