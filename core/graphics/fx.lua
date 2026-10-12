local render = require("core.graphics.render")
local camera = require("core.graphics.camera")
local mathx = require("core.math")
local physics = require("core.physics")

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
    fx.updateDebris(dt)
    fx.updateCorpses(dt)
end

-- Draw the current transition overlay across the screen if it is visible.
function fx.drawTransition()
    if transition.active or transition.alpha > 0 then
        local c = transition.color
        love.graphics.setColor(c[1], c[2], c[3], c[4] * transition.alpha)
        love.graphics.rectangle("fill", 0, 0, render.width, render.height)
    end
end

-- Debris: a destroyed block breaks into square chips cut from its image. Chips
-- fly outward, fall against the statics, spin, and fade out.
local DEBRIS_GRID = 4      -- chips per side (16 chips for a 16 px block)
local DEBRIS_LIFE = 0.9    -- seconds a chip lives
local DEBRIS_FADE = 0.3    -- last part of the life spent fading out
local DEBRIS_SPEED = 140   -- outward burst speed (px/s)
local DEBRIS_LIFT = 180    -- upward burst speed (px/s), varied per chip

local debris = {}

-- Spawn chips for a block centered at (x, y) with size w x h. `statics` is the
-- level's static list, which chips collide with while falling. `region` is the
-- part of the image to cut chips from (pixels); default is the whole image.
function fx.debris(x, y, w, h, image, statics, region)
    local chipW, chipH = w / DEBRIS_GRID, h / DEBRIS_GRID
    local imageW, imageH = 0, 0
    if image then
        imageW, imageH = image:getDimensions()
    end
    region = region or { x = 0, y = 0, w = imageW, h = imageH }

    for row = 0, DEBRIS_GRID - 1 do
        for col = 0, DEBRIS_GRID - 1 do
            local cx = x - w / 2 + (col + 0.5) * chipW
            local cy = y - h / 2 + (row + 0.5) * chipH
            local outward = (cx - x) / (w / 2) -- -1 (left edge) .. 1 (right edge)
            local chip = {
                x = cx, y = cy, w = chipW, h = chipH,
                vx = outward * DEBRIS_SPEED + (love.math.random() - 0.5) * 60,
                vy = -DEBRIS_LIFT * (0.5 + love.math.random() * 0.5),
                rotation = 0,
                spin = (love.math.random() - 0.5) * 14,
                life = 0,
                statics = statics,
                image = image,
            }
            if image then
                chip.quad = love.graphics.newQuad(
                    region.x + col * region.w / DEBRIS_GRID,
                    region.y + row * region.h / DEBRIS_GRID,
                    region.w / DEBRIS_GRID, region.h / DEBRIS_GRID,
                    imageW, imageH
                )
            end
            debris[#debris + 1] = chip
        end
    end
end

-- Advance every chip: gravity, collision with statics, spin, and expiry.
function fx.updateDebris(dt)
    for i = #debris, 1, -1 do
        local chip = debris[i]
        chip.life = chip.life + dt
        if chip.life >= DEBRIS_LIFE then
            table.remove(debris, i)
        else
            chip.vy = math.min(chip.vy + physics.gravity * dt, physics.maxFall)
            physics.moveBody(chip, chip.statics, dt)
            if chip.onGround then
                chip.vx = mathx.approach(chip.vx, 0, 400 * dt)
                chip.spin = chip.spin * (1 - 6 * dt)
            end
            chip.rotation = chip.rotation + chip.spin * dt
        end
    end
end

-- Draw the live chips in world space, fading out near the end of their life.
function fx.drawDebris()
    for _, chip in ipairs(debris) do
        local alpha = mathx.clamp((DEBRIS_LIFE - chip.life) / DEBRIS_FADE, 0, 1)
        love.graphics.setColor(1, 1, 1, alpha)
        if chip.image then
            love.graphics.draw(chip.image, chip.quad, chip.x, chip.y, chip.rotation,
                1, 1, chip.w / 2, chip.h / 2)
        else
            love.graphics.setColor(0.86, 0.52, 0.24, alpha)
            love.graphics.rectangle("fill", chip.x - chip.w / 2, chip.y - chip.h / 2, chip.w, chip.h)
        end
    end
end

-- Enemy corpses: a stomped enemy is flattened at once and fades; a kicked one is thrown
-- away, spinning, and falls off screen.
local SQUASH_HOLD = 0.35   -- seconds the flattened enemy stays down
local SQUASH_FADE = 0.2    -- seconds fading out
local SQUASH_HEIGHT = 0.25 -- height left when flat, as a fraction
local FLAT_LIFE = SQUASH_HOLD + SQUASH_FADE
local THROW_LIFE = 1.6     -- seconds a thrown corpse lives
local THROW_FADE = 0.4     -- last part of the throw spent fading out
local THROW_SPIN = 12      -- spin speed (rad/s)

local corpses = {}

-- Quad for `region` (pixels) of `image`, or nil without an image.
local function regionQuad(image, region)
    if not image then
        return nil
    end
    local imageW, imageH = image:getDimensions()
    return love.graphics.newQuad(region.x, region.y, region.w, region.h, imageW, imageH)
end

-- Squash a stomped enemy flat at (x, y) with its feet staying where they were.
function fx.flatten(x, y, w, h, image, region)
    corpses[#corpses + 1] = {
        kind = "flatten", x = x, y = y, w = w, h = h,
        image = image, quad = regionQuad(image, region), life = 0,
    }
end

-- Throw a kicked enemy away from (x, y) with the given launch velocity.
function fx.throwAway(x, y, w, h, image, region, vx, vy)
    corpses[#corpses + 1] = {
        kind = "throw", x = x, y = y, w = w, h = h,
        image = image, quad = regionQuad(image, region), life = 0,
        vx = vx or 0, vy = vy or 0,
        rotation = 0,
        spin = (vx and vx < 0 and -THROW_SPIN or THROW_SPIN),
    }
end

-- Advance corpses: thrown ones fly under gravity and spin; all expire.
function fx.updateCorpses(dt)
    for i = #corpses, 1, -1 do
        local corpse = corpses[i]
        corpse.life = corpse.life + dt
        if corpse.kind == "flatten" then
            if corpse.life >= FLAT_LIFE then
                table.remove(corpses, i)
            end
        elseif corpse.life >= THROW_LIFE then
            table.remove(corpses, i)
        else
            corpse.vy = math.min(corpse.vy + physics.gravity * dt, physics.maxFall)
            corpse.x = corpse.x + corpse.vx * dt
            corpse.y = corpse.y + corpse.vy * dt
            corpse.rotation = corpse.rotation + corpse.spin * dt
        end
    end
end

-- Draw corpses in world space.
function fx.drawCorpses()
    for _, corpse in ipairs(corpses) do
        if corpse.kind == "flatten" then
            local alpha = mathx.clamp((FLAT_LIFE - corpse.life) / SQUASH_FADE, 0, 1)
            local bottom = corpse.y + corpse.h / 2
            love.graphics.setColor(1, 1, 1, alpha)
            love.graphics.draw(corpse.image, corpse.quad, corpse.x,
                bottom - corpse.h * SQUASH_HEIGHT / 2, 0, 1, SQUASH_HEIGHT,
                corpse.w / 2, corpse.h / 2)
        else
            local alpha = mathx.clamp((THROW_LIFE - corpse.life) / THROW_FADE, 0, 1)
            love.graphics.setColor(1, 1, 1, alpha)
            love.graphics.draw(corpse.image, corpse.quad, corpse.x, corpse.y, corpse.rotation,
                1, 1, corpse.w / 2, corpse.h / 2)
        end
    end
end

-- Drop all debris and corpses, e.g. when the level is rebuilt.
function fx.clearEffects()
    debris = {}
    corpses = {}
end

return fx
