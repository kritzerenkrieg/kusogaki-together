-- Gameplay scene: hosts the platformer room, wires the player mechanic
-- (Z jump / X kick / C hold) and draws placeholder level art.
local render = require("core.graphics.render")
local text = require("core.text")
local sceneEngine = require("core.scenes")
local fx = require("core.graphics.fx")
local camera = require("core.graphics.camera")
local playerModule = require("core.player")
local propModule = require("core.prop")

local gameplay = {}

-- Level geometry: center-based rectangles --------------------------------
local LEVEL_SOLID = {
    { x = 320, y = 354, w = 656, h = 24, color = { 0.32, 0.27, 0.22 } }, -- ground
    { x = -8,  y = 180, w = 16,  h = 400, color = { 0.22, 0.28, 0.38 }, wall = true },
    { x = 648, y = 180, w = 16,  h = 400, color = { 0.22, 0.28, 0.38 }, wall = true },
    { x = 150, y = 291, w = 96,  h = 12, color = { 0.55, 0.58, 0.66 } }, -- platform A
    { x = 310, y = 246, w = 112, h = 12, color = { 0.55, 0.58, 0.66 } }, -- platform B
    { x = 470, y = 291, w = 96,  h = 12, color = { 0.55, 0.58, 0.66 } }, -- platform C
    { x = 585, y = 232, w = 76,  h = 12, color = { 0.55, 0.58, 0.66 } }, -- ledge
}

local LEVEL_PROPS = {
    { x = 150, y = 277, label = "salt",    color = { 0.42, 0.72, 0.85 } },
    { x = 205, y = 334, label = "potion",  color = { 0.86, 0.52, 0.24 } },
    { x = 300, y = 232, label = "reagent", color = { 0.72, 0.50, 0.86 } },
    { x = 430, y = 334, label = "herb",    color = { 0.55, 0.78, 0.35 } },
    { x = 575, y = 334, label = "bloom",   color = { 0.88, 0.45, 0.62 } },
}

local world = { solids = LEVEL_SOLID, props = {} }
local player

local function buildLevel()
    world.props = {}
    for _, def in ipairs(LEVEL_PROPS) do
        world.props[#world.props + 1] = propModule.new(def.x, def.y, {
            label = def.label,
            color = def.color,
        })
    end

    player = playerModule.new(70, 300)
    player.onEvent = function(name)
        if name == "kickHit" then
            camera.shake(0.15, 6)
        elseif name == "kick" or name == "throw" then
            camera.shake(0.12, 4)
        elseif name == "land" then
            camera.shake(0.08, 2)
        end
    end
end

buildLevel()

function gameplay.update(delta)
    player:update(delta, world)
    for _, prop in ipairs(world.props) do
        prop:update(delta, world)
    end
end

function gameplay.keypressed(key)
    if key == "escape" then
        fx.toScene("menu", 0.5, { ease = "smoothstep" })
    elseif key == "r" then
        buildLevel()
    end
end

local function drawBackground()
    -- Sky
    love.graphics.setColor(0.44, 0.62, 0.83)
    love.graphics.rectangle("fill", 0, 0, render.width, render.height)
    -- Distant hall band
    love.graphics.setColor(0.38, 0.53, 0.70)
    love.graphics.rectangle("fill", 0, 200, render.width, 142)
end

local function drawSolids()
    for _, solid in ipairs(world.solids) do
        local left, top = solid.x - solid.w / 2, solid.y - solid.h / 2
        love.graphics.setColor(solid.color)
        love.graphics.rectangle("fill", left, top, solid.w, solid.h)
        if not solid.wall then
            love.graphics.setColor(1, 1, 1, 0.12)
            love.graphics.rectangle("fill", left, top, solid.w, 3)
        end
    end
end

local function drawHud()
    love.graphics.setColor(0, 0, 0, 0.45)
    love.graphics.rectangle("fill", 0, render.height - 26, render.width, 26)

    love.graphics.setColor(0.92, 0.94, 0.98, 1)
    text.print(
        "ARROWS move   Z jump   X kick / throw   C hold (grab & carry)   ESC menu   R restart",
        8, render.height - 20, 10
    )

    local carry = player.carrying and player.carrying.label or "-"
    love.graphics.setColor(1, 1, 1, 0.85)
    text.print(("STATE: %s   CARRY: %s"):format(player.state, carry), 8, 8, 10)
end

function gameplay.draw()
    drawBackground()
    drawSolids()
    for _, prop in ipairs(world.props) do
        prop:draw()
    end
    player:draw()
    drawHud()
end

-- Exposed for automated smoke tests and debugging.
function gameplay.getPlayer()
    return player
end

sceneEngine.register("gameplay", {
    update = gameplay.update,
    keypressed = gameplay.keypressed,
    draw = gameplay.draw,
})

return gameplay