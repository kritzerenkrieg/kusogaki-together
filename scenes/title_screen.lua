local render = require("core.graphics.render")
local text = require("core.text")
local mathx = require("core.math")
local sceneEngine = require("core.scenes")

local titleScreen = {}
local backgroundPath = "assets/graphics/ui/title/bg.png"
local titlePath = "assets/graphics/ui/title/title.png"

-- ---- Title screen (main menu) state ----
local selectedOption = 1
local options = {
    { imagePath = "assets/graphics/ui/title/play.png" },
    { imagePath = "assets/graphics/ui/title/option.png" },
    { imagePath = "assets/graphics/ui/title/exit.png" },
}

-- ---- Intro (developer / engine) splash timeline ----
local INTRO_PHASES = {
    { name = "devfade",  dur = 1.0 }, -- dark background fades in, revealing "OM IT STUDIO"
    { name = "devhold",  dur = 3.0 }, -- hold "OM IT STUDIO"
    { name = "engine",   dur = 3.0 }, -- "Made with Love2D"
    { name = "whiteout", dur = 1.0 }, -- white fade out
    { name = "bg",       dur = 2.0 }, -- bg.png fades in from white
    { name = "overlay",  dur = 1.0 }, -- dark overlay 50% fades in
    { name = "title",    dur = 3.0 }, -- title.png fades in, rising up
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

-- (clamp01 / fill / drawImage helpers now live in core/graphics.lua)

local function drawCentered(w, label, y, size, alpha)
    love.graphics.setColor(1, 1, 1, alpha or 1)
    text.printf(label, 0, y, w, "center", size)
end

function titleScreen.load()
    bgImage = love.graphics.newImage(backgroundPath)
    titleImage = love.graphics.newImage(titlePath)
    bgImage:setFilter("nearest", "nearest")
    titleImage:setFilter("nearest", "nearest")

    for _, option in ipairs(options) do
        option.image = love.graphics.newImage(option.imagePath)
        option.image:setFilter("nearest", "nearest")
    end
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
    local phaseEase = 0
    for i = 1, #INTRO_PHASES do
        local localT = elapsed - INTRO_START[i]
        if localT <= INTRO_PHASES[i].dur then
            phaseIndex = i
            local phaseRatio = localT / INTRO_PHASES[i].dur
            phaseEase = mathx.easings.smoothstep(phaseRatio)
            if INTRO_PHASES[i].name == "whiteout" then
                phaseEase = mathx.easings.easeout(phaseRatio)
            end
            t = phaseEase
            break
        end
    end
    if not phaseIndex then
        phaseIndex, t = #INTRO_PHASES, 1
    end

    local name = INTRO_PHASES[phaseIndex].name

    if name == "devfade" then
        render.fill(0, 0, 0, 1)
        drawCentered(w, "OM IT STUDIO", h / 2 - 16, 32, t)
    elseif name == "devhold" then
        render.fill(0, 0, 0, 1)
        drawCentered(w, "OM IT STUDIO", h / 2 - 16, 32, 1)
    elseif name == "engine" then
        render.fill(0, 0, 0, 1)
        drawCentered(w, "Made with Love2D", h / 2 - 16, 32, t)
    elseif name == "whiteout" then
        render.fill(0, 0, 0, 1)
        drawCentered(w, "Made with Love2D", h / 2 - 16, 32, 1 - t)
        render.fill(1, 1, 1, t)
    elseif name == "bg" then
        render.fill(1, 1, 1, 1)
        render.drawImage(bgImage, 0, 0, t)
    elseif name == "overlay" then
        render.drawImage(bgImage, 0, 0, 1)
        render.fill(0, 0, 0, 0.5 * t)
    elseif name == "title" then
        render.drawImage(bgImage, 0, 0, 1)
        render.fill(0, 0, 0, 0.5)
        render.drawImage(titleImage, 0, (1 - t) * 24, t)
    end
end

-- SECOND PART - the actual title screen (main menu).
function titleScreen.title_splash(canvasWidth, canvasHeight)
    render.drawImage(bgImage, 0, 0, 1)
    render.drawImage(titleImage, 0, 0, 1)

    for index, option in ipairs(options) do
        local y = 182 + (index - 1) * 58
        local isSelected = index == selectedOption
        local scale = 1
        local rotation = 0

        if isSelected then
            local time = love.timer.getTime()
            scale = 1.04 + math.sin(time * 6) * 0.035
            rotation = math.sin(time * 5) * 0.055
        end

        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.draw(
            option.image,
            canvasWidth / 2,
            y,
            rotation,
            scale,
            scale,
            option.image:getWidth() / 2,
            option.image:getHeight() / 2
        )
    end

    love.graphics.setColor(0, 0, 0, 1)
    text.print(
        "CONTROLS: Use arrow keys to navigate, ENTER to select, Z to confirm, X to cancel, C for functions.",
        30, canvasHeight - 18, 10
    )
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
    elseif key == "return" or key == "space" then
        return selectedOption == 1 and "gameplay" or "exit"
    end
end

sceneEngine.register("menu", {
    keypressed = function(key)
        local nextScene = titleScreen.keypressed(key)
        if nextScene == "exit" then
            love.event.quit()
        elseif nextScene then
            local fx = require("core.graphics.fx")
            fx.toScene(nextScene, 0.5, { ease = "smoothstep" })
        end
    end,
    draw = function()
        titleScreen.title_splash(render.width, render.height)
    end
})

sceneEngine.register("intro_splash", {
    keypressed = function(key)
        titleScreen.intro_skip()
        return "menu"
    end,
    draw = function()
        if titleScreen.intro_splash(render.width, render.height) then
            sceneEngine.switch("menu")
        end
    end
})

return titleScreen
