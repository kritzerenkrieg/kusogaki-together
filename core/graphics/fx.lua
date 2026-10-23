local render = require("core.graphics.render")
local camera = require("core.graphics.camera")
local mathx = require("core.mathx")
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
    fx.updateExplosions(dt)
    fx.updateCorpses(dt)
    fx.updateShots(dt)
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

local world -- the level effects belong to (its gravity), set by clearEffects

-- Spawn chips for a block centered at (x, y) with size w x h. `statics` is the
-- level's static list, which chips collide with while falling. `region` is the
-- part of the image to cut chips from (pixels); default is the whole image.
-- `power` scales the burst speed (default 1).
function fx.debris(x, y, w, h, image, statics, region, power)
    power = power or 1
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
                vx = (outward * DEBRIS_SPEED + (love.math.random() - 0.5) * 60) * power,
                vy = -DEBRIS_LIFT * (0.5 + love.math.random() * 0.5) * power,
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
            physics.fall(chip, world, dt)
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

-- Explosion: a block bursts into its own debris chips, the camera shakes, a
-- round fireball and shockwave expand, and a ball of voxels flies out. Fireball
-- and shockwave are drawn on a pixel grid, so the circles stay blocky. Heat
-- falls with distance from the blast and with age, cooling from white-hot
-- through orange and red to smoke; voxels are shaded as small cubes (light
-- top-left edge, dark bottom-right edge).
local EXPLOSION_VOXELS = 48
local EXPLOSION_LIFE = 0.8    -- seconds the blast lives
local EXPLOSION_FADE = 0.3    -- last part of the life spent fading out
local EXPLOSION_SPEED = 280   -- outward burst speed (px/s), varied per voxel
local EXPLOSION_DRAG = 4      -- per-second slowdown of voxels
local EXPLOSION_RISE = 60     -- upward drift of cooling smoke (px/s^2)
local EXPLOSION_RADIUS = 64   -- px over which voxel light falls off
local FIREBALL_RADIUS = 30    -- largest fireball radius (px)
local FIREBALL_GROW = 0.12    -- seconds for the fireball to reach full size
local FIREBALL_LIFE = 0.45    -- seconds until the fireball has shrunk away
local SHOCKWAVE_RADIUS = 60   -- radius the shockwave ring reaches (px)
local SHOCKWAVE_LIFE = 0.3    -- seconds the shockwave lives
local BLAST_CELL = 2          -- pixel grid for fireball and shockwave (px)

-- Hot to cold.
local VOXEL_PALETTE = {
    { 1.00, 0.98, 0.85 },
    { 1.00, 0.84, 0.30 },
    { 1.00, 0.52, 0.15 },
    { 0.72, 0.20, 0.10 },
    { 0.32, 0.29, 0.29 },
}

local explosions = {}

-- Blow up a block centered at (x, y) with size w x h; see fx.debris for the rest.
function fx.explosion(x, y, w, h, image, statics, region)
    fx.debris(x, y, w, h, image, statics, region, 1.6)
    camera.shake(0.4, 10)

    local voxels = {}
    for i = 1, EXPLOSION_VOXELS do
        local angle = love.math.random() * math.pi * 2
        local speed = EXPLOSION_SPEED * (0.25 + love.math.random() * 0.75)
        voxels[i] = {
            x = x + (love.math.random() - 0.5) * w * 0.5,
            y = y + (love.math.random() - 0.5) * h * 0.5,
            vx = math.cos(angle) * speed,
            vy = math.sin(angle) * speed,
            size = love.math.random(3, 6),
        }
    end
    explosions[#explosions + 1] = {
        x = x, y = y, w = w, h = h, voxels = voxels, life = 0,
        seed = love.math.random() * math.pi * 2, -- rotates the fireball's lobes
    }
end

function fx.updateExplosions(dt)
    for i = #explosions, 1, -1 do
        local blast = explosions[i]
        blast.life = blast.life + dt
        if blast.life >= EXPLOSION_LIFE then
            table.remove(explosions, i)
        else
            local drag = math.max(0, 1 - EXPLOSION_DRAG * dt)
            for _, voxel in ipairs(blast.voxels) do
                voxel.vx = voxel.vx * drag
                voxel.vy = voxel.vy * drag - EXPLOSION_RISE * dt
                voxel.x = voxel.x + voxel.vx * dt
                voxel.y = voxel.y + voxel.vy * dt
            end
        end
    end
end

-- Heat 1 (white-hot) .. 0 (smoke) from distance to the blast and age.
local function voxelColor(blast, voxel, age)
    local distance = math.sqrt((voxel.x - blast.x) ^ 2 + (voxel.y - blast.y) ^ 2)
    local heat = mathx.clamp(1 - age * 1.1 - distance / EXPLOSION_RADIUS * 0.5, 0, 1)
    local index = math.floor((1 - heat) * (#VOXEL_PALETTE - 1) + 0.5) + 1
    return VOXEL_PALETTE[index], heat
end

-- Call fn(cellX, cellY, distance, angle) for every grid cell whose center lies
-- within `radius` of (cx, cy). Cells sit on a world-aligned grid.
local function eachDiscCell(cx, cy, radius, fn)
    local startX = math.floor((cx - radius) / BLAST_CELL) * BLAST_CELL
    local startY = math.floor((cy - radius) / BLAST_CELL) * BLAST_CELL
    for cellY = startY, cy + radius, BLAST_CELL do
        for cellX = startX, cx + radius, BLAST_CELL do
            local dx = cellX + BLAST_CELL / 2 - cx
            local dy = cellY + BLAST_CELL / 2 - cy
            local distance = math.sqrt(dx * dx + dy * dy)
            if distance <= radius then
                fn(cellX, cellY, distance, math.atan2(dy, dx))
            end
        end
    end
end

-- Fireball radius: grows fast, then shrinks away as it burns out.
local function fireballRadius(life)
    if life < FIREBALL_GROW then
        local t = life / FIREBALL_GROW
        return FIREBALL_RADIUS * (1 - (1 - t) * (1 - t))
    end
    local t = mathx.clamp((life - FIREBALL_GROW) / (FIREBALL_LIFE - FIREBALL_GROW), 0, 1)
    return FIREBALL_RADIUS * (1 - t * t)
end

-- Edge wobble: the fireball's radius varies by angle, so it reads as a rough
-- radial burst rather than a perfect circle.
local FIREBALL_LOBES = 5
local FIREBALL_WOBBLE = 0.18  -- fraction of the radius the edge moves in and out

local function lobe(blast, angle)
    return 1 + FIREBALL_WOBBLE * math.sin(angle * FIREBALL_LOBES + blast.seed)
end

-- A rough disc banded by heat: white-hot core, cooler bands outward, all
-- cooling with age.
local function drawFireball(blast, age)
    local radius = fireballRadius(blast.life)
    if radius < 1 then
        return
    end
    -- Soft halo behind the ball.
    love.graphics.setBlendMode("add")
    eachDiscCell(blast.x, blast.y, radius * 1.5, function(cellX, cellY, distance)
        local glow = 1 - distance / (radius * 1.5)
        love.graphics.setColor(1, 0.6, 0.2, glow * 0.5 * (1 - age))
        love.graphics.rectangle("fill", cellX, cellY, BLAST_CELL, BLAST_CELL)
    end)
    love.graphics.setBlendMode("alpha")
    eachDiscCell(blast.x, blast.y, radius * (1 + FIREBALL_WOBBLE), function(cellX, cellY, distance, angle)
        local edge = radius * lobe(blast, angle)
        if distance > edge then
            return
        end
        local heat = mathx.clamp(1 - age * 1.4 - (distance / edge) * 0.7, 0, 1)
        local color = VOXEL_PALETTE[math.floor((1 - heat) * (#VOXEL_PALETTE - 1) + 0.5) + 1]
        love.graphics.setColor(color[1], color[2], color[3], 1)
        love.graphics.rectangle("fill", cellX, cellY, BLAST_CELL, BLAST_CELL)
    end)
end

-- An expanding ring, one cell thick, fading as it grows.
local function drawShockwave(blast)
    if blast.life >= SHOCKWAVE_LIFE then
        return
    end
    local t = blast.life / SHOCKWAVE_LIFE
    local ring = SHOCKWAVE_RADIUS * (1 - (1 - t) * (1 - t))
    love.graphics.setBlendMode("add")
    love.graphics.setColor(1, 0.9, 0.7, (1 - t) * 0.8)
    eachDiscCell(blast.x, blast.y, ring, function(cellX, cellY, distance)
        if distance >= ring - BLAST_CELL * 1.5 then
            love.graphics.rectangle("fill", cellX, cellY, BLAST_CELL, BLAST_CELL)
        end
    end)
    love.graphics.setBlendMode("alpha")
end

local function drawVoxel(x, y, size, color, alpha)
    local r, g, b = color[1], color[2], color[3]
    love.graphics.setColor(r, g, b, alpha)
    love.graphics.rectangle("fill", x, y, size, size)
    love.graphics.setColor(math.min(1, r * 1.3 + 0.1), math.min(1, g * 1.3 + 0.1), math.min(1, b * 1.3 + 0.1), alpha)
    love.graphics.rectangle("fill", x, y, size, 1)
    love.graphics.rectangle("fill", x, y, 1, size)
    love.graphics.setColor(r * 0.55, g * 0.55, b * 0.55, alpha)
    love.graphics.rectangle("fill", x, y + size - 1, size, 1)
    love.graphics.rectangle("fill", x + size - 1, y, 1, size)
end

-- Draw blasts in world space: shockwave, fireball, voxel glow, then the voxels.
function fx.drawExplosions()
    for _, blast in ipairs(explosions) do
        local age = blast.life / EXPLOSION_LIFE
        local alpha = mathx.clamp((EXPLOSION_LIFE - blast.life) / EXPLOSION_FADE, 0, 1)

        drawShockwave(blast)
        drawFireball(blast, age)

        love.graphics.setBlendMode("add")
        for _, voxel in ipairs(blast.voxels) do
            local color, heat = voxelColor(blast, voxel, age)
            if heat > 0 then
                local glow = voxel.size * 2
                love.graphics.setColor(color[1], color[2], color[3], heat * 0.35 * alpha)
                love.graphics.rectangle("fill", math.floor(voxel.x - glow / 2), math.floor(voxel.y - glow / 2), glow, glow)
            end
        end
        love.graphics.setBlendMode("alpha")

        for _, voxel in ipairs(blast.voxels) do
            local color = voxelColor(blast, voxel, age)
            local size = math.max(1, math.floor(voxel.size * (1 - age * 0.4) + 0.5))
            drawVoxel(math.floor(voxel.x - size / 2), math.floor(voxel.y - size / 2), size, color, alpha)
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
            physics.fall(corpse, world, dt)
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

-- Muzzle flash and bullet impact: a flash is a short burst of light in front
-- of a gun; sparks fly forward from it, and back from where a bullet hits.
local MUZZLE_LIFE = 0.09    -- seconds a flash lasts
local SPARK_GRAVITY = 420   -- px/s^2 on sparks
local flashes = {}
local sparks = {}

local function addSpark(x, y, vx, vy, life, size)
    sparks[#sparks + 1] = { x = x, y = y, vx = vx, vy = vy, life = 0, maxLife = life, size = size }
end

-- A flash at (x, y), the muzzle, firing toward dir (1 right, -1 left).
function fx.muzzleFlash(x, y, dir)
    dir = dir < 0 and -1 or 1
    flashes[#flashes + 1] = { x = x, y = y, dir = dir, life = 0, size = 0.85 + love.math.random() * 0.4 }
    for _ = 1, 4 do
        addSpark(x, y, dir * (110 + love.math.random() * 150), (love.math.random() - 0.5) * 110,
            0.12 + love.math.random() * 0.1, 1)
    end
end

-- A bullet that was flying toward dir stopped at (x, y).
function fx.bulletImpact(x, y, dir)
    dir = dir < 0 and -1 or 1
    for _ = 1, 7 do
        addSpark(x, y, -dir * (30 + love.math.random() * 130), -30 - love.math.random() * 120,
            0.2 + love.math.random() * 0.15, love.math.random() < 0.3 and 2 or 1)
    end
end

function fx.updateShots(dt)
    for i = #flashes, 1, -1 do
        flashes[i].life = flashes[i].life + dt
        if flashes[i].life >= MUZZLE_LIFE then
            table.remove(flashes, i)
        end
    end
    for i = #sparks, 1, -1 do
        local spark = sparks[i]
        spark.life = spark.life + dt
        if spark.life >= spark.maxLife then
            table.remove(sparks, i)
        else
            spark.vy = spark.vy + SPARK_GRAVITY * dt
            spark.x = spark.x + spark.vx * dt
            spark.y = spark.y + spark.vy * dt
        end
    end
end

-- Draw flashes and sparks in world space. A flash lights its surroundings: a
-- soft glow added over the picture (additive blending), brightest at the muzzle.
local GLOW_RADIUS = 38
local GLOW_STEPS = 7

function fx.drawShots()
    love.graphics.setBlendMode("add")
    for _, flash in ipairs(flashes) do
        local fade = 1 - flash.life / MUZZLE_LIFE
        local x, y = flash.x + flash.dir * 4, flash.y
        for step = GLOW_STEPS, 1, -1 do
            local radius = GLOW_RADIUS * flash.size * (0.5 + 0.5 * fade) * step / GLOW_STEPS
            love.graphics.setColor(1, 0.78, 0.38, 0.11 * fade)
            love.graphics.circle("fill", x, y, radius)
        end
        love.graphics.setColor(1, 0.95, 0.75, 0.9 * fade)
        love.graphics.circle("fill", flash.x, flash.y, 5 * flash.size * fade + 1)
    end
    love.graphics.setBlendMode("alpha")
    for _, flash in ipairs(flashes) do
        local fade = 1 - flash.life / MUZZLE_LIFE
        local k, d, x, y = flash.size * (0.6 + 0.4 * fade), flash.dir, flash.x, flash.y
        love.graphics.setColor(1, 0.95, 0.65, 0.9 * fade)
        love.graphics.polygon("fill", x, y - 2 * k, x + d * 11 * k, y, x, y + 2 * k)
        love.graphics.setColor(1, 1, 1, fade)
        love.graphics.circle("fill", x, y, 2 * k)
    end
    for _, spark in ipairs(sparks) do
        local fade = 1 - spark.life / spark.maxLife
        love.graphics.setColor(1, 0.85, 0.35, fade)
        love.graphics.rectangle("fill", spark.x - spark.size / 2, spark.y - spark.size / 2, spark.size, spark.size)
    end
end

-- Drop all debris, explosions and corpses, e.g. when the level is rebuilt.
-- `level` (optional) gives the gravity chips and corpses fall with.
function fx.clearEffects(level)
    world = level
    debris = {}
    explosions = {}
    corpses = {}
    flashes = {}
    sparks = {}
end

return fx
