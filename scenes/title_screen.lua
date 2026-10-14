-- Title screen in the style of Cave Story: a plain dark screen with the game's
-- name, a short text menu with a walking kusogaki as the cursor, the version
-- in the corner and the studio at the bottom. Behind it kusogakis, dodons and
-- dokans run left and right along the bottom of the screen.
local render = require("core.graphics.render")
local text = require("core.text")
local mathx = require("core.mathx")
local sceneEngine = require("core.scenes")
local audio = require("core.audio")
local version = require("core.version")
local playerConfig = require("core.player.config")

local TITLE_MUSIC = "kusogaki.wav"

local SPRITES = {
    kusogaki = "assets/graphics/entities/kusogaki.png", -- 32x32 frames, walk cycle on row 1
    dodon = "assets/graphics/entities/dodon.png",       -- 16x16 frames, 2 walk frames
    dokan = "assets/graphics/entities/dokan.png",       -- 16x24, nose up
}

local BACKGROUND = { 0.125, 0.125, 0.125 }
local TEXT_COLOR = { 1, 1, 1 }
local DIM_COLOR = { 0.55, 0.55, 0.6 }

local titleScreen = {}

local images = {}
local quads = { kusogaki = {}, dodon = {} }

-- ---- Menu ----
local selectedOption = 1
local options = {
    { label = "Play" },
    { label = "Options" },
    { label = "Exit" },
}

local MENU_X = 288            -- left edge of the option labels
local MENU_TOP = 172          -- first option's center
local MENU_SPACING = 24
local MENU_SIZE = 16
local CURSOR_GAP = 6          -- between the cursor kusogaki and its label
local WALK_FRAME = playerConfig.ANIM.frame
local FADE_IN = 0.6           -- seconds the menu takes to fade in from black

local menuTime = 0            -- seconds since the menu was entered

-- ---- Intro (developer / engine) splash timeline ----
local INTRO_PHASES = {
    { name = "devfade",  dur = 1.0 }, -- "OM IT STUDIO" fades in
    { name = "devhold",  dur = 3.0 }, -- hold "OM IT STUDIO"
    { name = "engine",   dur = 3.0 }, -- "Made with Love2D"
    { name = "fadeout",  dur = 1.0 }, -- the text fades to black, then the menu
}

local INTRO_START = {}
local TOTAL_INTRO = 0
for i, phase in ipairs(INTRO_PHASES) do
    INTRO_START[i] = TOTAL_INTRO
    TOTAL_INTRO = TOTAL_INTRO + phase.dur
end

local intro = {
    active = false,
    base = 0,
}

-- ---- Background parade ----
-- Lanes are ground lines (feet y), back to front; farther lanes are dimmer.
local LANES = {
    { y = 296, alpha = 0.45 },
    { y = 316, alpha = 0.7 },
    { y = 336, alpha = 1 },
}
local MARGIN = 40             -- px off screen where actors appear and leave
local actors = {}
local spawnTimer = 0

local function newActor(kind, lane, dir, x, speed)
    return {
        kind = kind,
        lane = lane,
        dir = dir,
        x = x,
        speed = speed,
        time = love.math.random() * 2, -- animation phase
        tint = playerConfig.TINTS[love.math.random(#playerConfig.TINTS)],
    }
end

-- Something runs onto the screen from one side: a kusogaki, a pack of
-- dodons, a dokan, or a kusogaki with a dokan right behind it.
local function spawnGroup()
    local lane = love.math.random(#LANES)
    local dir = love.math.random() < 0.5 and 1 or -1
    local startX = dir > 0 and -MARGIN or render.width + MARGIN
    local roll = love.math.random()
    if roll < 0.4 then
        actors[#actors + 1] = newActor("kusogaki", lane, dir, startX, love.math.random(90, 130))
    elseif roll < 0.7 then
        for i = 0, love.math.random(1, 3) - 1 do
            actors[#actors + 1] = newActor("dodon", lane, dir, startX - dir * i * 22, 40)
        end
    elseif roll < 0.85 then
        actors[#actors + 1] = newActor("dokan", lane, dir, startX, love.math.random(180, 240))
    else
        local speed = love.math.random(130, 150)
        actors[#actors + 1] = newActor("kusogaki", lane, dir, startX, speed)
        actors[#actors + 1] = newActor("dokan", lane, dir, startX - dir * 56, speed)
    end
end

local function updateParade(delta)
    spawnTimer = spawnTimer - delta
    if spawnTimer <= 0 then
        spawnGroup()
        spawnTimer = 0.5 + love.math.random() * 0.9
    end
    for i = #actors, 1, -1 do
        local actor = actors[i]
        actor.x = actor.x + actor.dir * actor.speed * delta
        actor.time = actor.time + delta
        if actor.x < -MARGIN * 2 or actor.x > render.width + MARGIN * 2 then
            table.remove(actors, i)
        end
    end
end

-- Fill the screen with a parade already under way.
local function warmUpParade()
    actors, spawnTimer = {}, 0
    for _ = 1, 10 * 30 do
        updateParade(1 / 30)
    end
end

-- One kusogaki walk-cycle frame (2, 3, 4, 1, like the player) at its feet.
local function drawKusogaki(x, feetY, dir, time)
    local column = (math.floor(time / WALK_FRAME) + 1) % 4 + 1
    love.graphics.draw(images.kusogaki, quads.kusogaki[column], math.floor(x), feetY, 0, dir, 1, 16, 32)
end

local function drawActor(actor)
    local lane = LANES[actor.lane]
    if actor.kind == "kusogaki" then
        local tint = actor.tint
        love.graphics.setColor(tint[1], tint[2], tint[3], lane.alpha)
        drawKusogaki(actor.x, lane.y, actor.dir, actor.time * actor.speed / 100)
    elseif actor.kind == "dodon" then
        love.graphics.setColor(1, 1, 1, lane.alpha)
        local frame = math.floor(actor.time / 0.2) % 2 + 1
        love.graphics.draw(images.dodon, quads.dodon[frame], math.floor(actor.x), lane.y, 0, actor.dir, 1, 8, 16)
    else -- dokan: flies nose first, a little above the ground, bobbing
        love.graphics.setColor(1, 1, 1, lane.alpha)
        local y = lane.y - 14 + math.sin(actor.time * 9) * 1.5
        love.graphics.draw(images.dokan, math.floor(actor.x), math.floor(y), actor.dir * math.pi / 2, 1, 1, 8, 12)
    end
end

local function drawParade()
    for laneIndex = 1, #LANES do
        for _, actor in ipairs(actors) do
            if actor.lane == laneIndex then
                drawActor(actor)
            end
        end
    end
end

-- ---- Drawing helpers ----

local function setColor(color, alpha)
    love.graphics.setColor(color[1], color[2], color[3], alpha or 1)
end

-- Text with a 1px drop shadow, so it reads over the parade.
local function shadowed(label, x, y, width, align, size, color, alpha)
    love.graphics.setColor(0, 0, 0, (alpha or 1) * 0.8)
    text.printf(label, x + 1, y + 1, width, align, size)
    setColor(color, alpha)
    text.printf(label, x, y, width, align, size)
end

local function drawCentered(w, label, y, size, alpha)
    love.graphics.setColor(1, 1, 1, alpha or 1)
    text.printf(label, 0, y, w, "center", size)
end

local function loadImage(path)
    local image = love.graphics.newImage(path)
    image:setFilter("nearest", "nearest")
    return image
end

function titleScreen.load()
    for name, path in pairs(SPRITES) do
        images[name] = loadImage(path)
    end
    for column = 1, 4 do
        quads.kusogaki[column] = love.graphics.newQuad((column - 1) * 32, 0, 32, 32, images.kusogaki:getDimensions())
    end
    for frame = 1, 2 do
        quads.dodon[frame] = love.graphics.newQuad((frame - 1) * 16, 0, 16, 16, images.dodon:getDimensions())
    end
    warmUpParade()
end

-- Skip the intro outright (the developer/engine splash is skippable).
function titleScreen.intro_skip()
    if intro.active then
        intro.base = love.timer.getTime() - TOTAL_INTRO - 1
    end
end

-- FIRST PART - skippable developer / engine splash (placeholder).
local drawIntroFrame
function titleScreen.intro_splash(canvasWidth, canvasHeight)
    if not intro.active then
        intro.active = true
        intro.base = love.timer.getTime()
    end

    local elapsed = love.timer.getTime() - intro.base
    drawIntroFrame(canvasWidth, canvasHeight, elapsed)

    return elapsed >= TOTAL_INTRO
end

drawIntroFrame = function(w, h, elapsed)
    local phaseIndex, t
    for i = 1, #INTRO_PHASES do
        local localT = elapsed - INTRO_START[i]
        if localT <= INTRO_PHASES[i].dur then
            phaseIndex = i
            t = mathx.easings.smoothstep(localT / INTRO_PHASES[i].dur)
            break
        end
    end
    if not phaseIndex then
        phaseIndex, t = #INTRO_PHASES, 1
    end

    local name = INTRO_PHASES[phaseIndex].name
    render.fill(0, 0, 0, 1)
    if name == "devfade" then
        drawCentered(w, "OM IT STUDIO", h / 2 - 16, 32, t)
    elseif name == "devhold" then
        drawCentered(w, "OM IT STUDIO", h / 2 - 16, 32, 1)
    elseif name == "engine" then
        drawCentered(w, "Made with Love2D", h / 2 - 16, 32, t)
    elseif name == "fadeout" then
        drawCentered(w, "Made with Love2D", h / 2 - 16, 32, 1 - t)
    end
end

-- ---- Menu ----

local function optionY(index)
    return MENU_TOP + (index - 1) * MENU_SPACING
end

-- Index of the option under canvas point (x, y), or nil: its label, and the
-- cursor's place in front of it.
local function optionAt(x, y)
    for index, option in ipairs(options) do
        local width = text.getWidth(option.label, MENU_SIZE)
        if x >= MENU_X - 32 - CURSOR_GAP and x <= MENU_X + width and math.abs(y - optionY(index)) <= MENU_SPACING / 2 then
            return index
        end
    end
    return nil
end

local function drawTitle(w)
    shadowed("KUSOGAKI", 0, 52, w, "center", 48, TEXT_COLOR)
    shadowed("Together", 0, 108, w / 2 + 132, "right", 16, DIM_COLOR)
end

local function drawMenu()
    for index, option in ipairs(options) do
        local y = optionY(index)
        local selected = index == selectedOption
        shadowed(option.label, MENU_X, y - MENU_SIZE / 2 - 2, 200, "left", MENU_SIZE,
            selected and TEXT_COLOR or DIM_COLOR)
        if selected then
            love.graphics.setColor(1, 1, 1, 1)
            drawKusogaki(MENU_X - CURSOR_GAP - 16, y + 12, 1, menuTime)
        end
    end
end

-- SECOND PART - the actual title screen (main menu).
function titleScreen.title_splash(canvasWidth, canvasHeight)
    render.fill(BACKGROUND[1], BACKGROUND[2], BACKGROUND[3], 1)
    drawParade()
    drawTitle(canvasWidth)
    drawMenu()
    shadowed("Version " .. version.GAME, 6, 4, canvasWidth, "left", 10, DIM_COLOR)
    shadowed("2026 OM IT STUDIO", 0, canvasHeight - 14, canvasWidth, "center", 10, DIM_COLOR)
    if menuTime < FADE_IN then
        render.fill(0, 0, 0, 1 - menuTime / FADE_IN)
    end
    love.graphics.setColor(1, 1, 1, 1)
end

function titleScreen.update(delta)
    menuTime = menuTime + delta
    updateParade(delta)
end

-- Scene for the selected option: play, nothing yet (options), or exit.
local function activate()
    if selectedOption == 1 then
        return "gameplay"
    elseif selectedOption == #options then
        return "exit"
    end
    return nil -- options screen not built yet
end

-- Hovering an option selects it.
function titleScreen.mousemoved(x, y)
    selectedOption = optionAt(x, y) or selectedOption
end

-- Left-click on an option activates it; returns the next scene to enter.
function titleScreen.mousepressed(x, y, button)
    local index = button == 1 and optionAt(x, y)
    if index then
        selectedOption = index
        return activate()
    end
end

-- Menu navigation; returns the next scene to enter.
function titleScreen.keypressed(key)
    if key == "up" then
        selectedOption = selectedOption - 1
        if selectedOption < 1 then
            selectedOption = #options
        end
    elseif key == "down" then
        selectedOption = selectedOption + 1
        if selectedOption > #options then
            selectedOption = 1
        end
    elseif key == "return" or key == "space" or key == "z" then
        return activate()
    end
end

-- Leave the menu for `nextScene` (from a key or a click).
local function goTo(nextScene)
    if nextScene == "exit" then
        love.event.quit()
    elseif nextScene then
        local fx = require("core.graphics.fx")
        fx.toScene(nextScene, 0.5, { ease = "smoothstep" })
    end
end

sceneEngine.register("menu", {
    enter = function()
        audio.playMusic(TITLE_MUSIC)
        menuTime = FADE_IN -- shown at once; only the intro's end fades it in
    end,
    update = titleScreen.update,
    keypressed = function(key)
        goTo(titleScreen.keypressed(key))
    end,
    mousemoved = titleScreen.mousemoved,
    mousepressed = function(x, y, button)
        goTo(titleScreen.mousepressed(x, y, button))
    end,
    draw = function()
        titleScreen.title_splash(render.width, render.height)
    end
})

sceneEngine.register("intro_splash", {
    enter = function()
        audio.playMusic(TITLE_MUSIC)
    end,
    keypressed = function(key)
        titleScreen.intro_skip()
        return "menu"
    end,
    mousepressed = function()
        titleScreen.intro_skip()
        return "menu"
    end,
    draw = function()
        if titleScreen.intro_splash(render.width, render.height) then
            sceneEngine.switch("menu")
            menuTime = 0
        end
    end
})

return titleScreen
