-- Gameplay scene: loads a level, wires the player mechanic (Z jump / X kick /
-- C hold) and runs the world update and HUD.
local render = require("core.graphics.render")
local physics = require("core.physics")
local text = require("core.text")
local sceneEngine = require("core.scenes")
local fx = require("core.graphics.fx")
local camera = require("core.graphics.camera")
local playerModule = require("core.player")
local levelLoader = require("core.level")

local gameplay = {}

local LEVEL_NAME = "example"
local HAZARD_TOUCH = 1 -- px around a hazard that still counts as touching it

local level
local world = { solids = {}, props = {}, hazards = {} }
local player

local function buildLevel()
    level = levelLoader.load(LEVEL_NAME)

    -- Hazards are solid: props and the player collide with them like any body.
    world.solids = {}
    for _, solid in ipairs(level.solids) do
        world.solids[#world.solids + 1] = solid
    end
    for _, hazard in ipairs(level.hazards) do
        world.solids[#world.solids + 1] = hazard
    end
    world.hazards = level.hazards
    world.props = level.props

    player = playerModule.new(level.spawn.x, level.spawn.y)
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

function gameplay.load()
    playerModule.load()
    buildLevel()
end

function gameplay.update(delta)
    player:update(delta, world)
    for _, prop in ipairs(world.props) do
        prop:update(delta, world)
    end

    -- Hazards are solid, so the player stops flush against them. Test a box
    -- grown by HAZARD_TOUCH px so flush contact counts as touching.
    for _, hazard in ipairs(world.hazards) do
        local touch = {
            x = hazard.x,
            y = hazard.y,
            w = hazard.w + HAZARD_TOUCH * 2,
            h = hazard.h + HAZARD_TOUCH * 2,
        }
        if physics.overlaps(player, touch) then
            hazard:onTouch(player)
        end
    end

    -- All dynamic objects collide with one another after their individual
    -- movement. Their mass comes from collider/image area, so larger objects
    -- transfer more momentum into smaller objects. A dead player has no collision.
    local bodies = {}
    if not player.dead then
        bodies[1] = player
    end
    for _, prop in ipairs(world.props) do
        bodies[#bodies + 1] = prop
    end
    physics.resolveBodyCollisions(bodies, world.solids)
    player:refreshAnimationState()
end

function gameplay.keypressed(key)
    if key == "escape" then
        fx.toScene("menu", 0.5, { ease = "smoothstep" })
    elseif key == "r" then
        buildLevel()
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

    local carry = player.carrying and player.carrying.name or "-"
    love.graphics.setColor(1, 1, 1, 0.85)
    text.print(("STATE: %s   CARRY: %s"):format(player.state, carry), 8, 8, 10)
end

function gameplay.draw()
    levelLoader.draw(level)
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
