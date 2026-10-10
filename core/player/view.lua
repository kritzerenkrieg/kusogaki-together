-- Player drawing: sprite-sheet frame selection, grab hint and kick hitbox.
local config = require("core.player.config")
local controller = require("core.player.controller")

local ANIM = config.ANIM
local SPRITE_PATH = "assets/graphics/entities/kusogaki.png"
local SPRITE_FRAME_SIZE = 32

local view = {}
local spriteSheet

function view.load()
    spriteSheet = love.graphics.newImage(SPRITE_PATH)
    spriteSheet:setFilter("nearest", "nearest")
end

local function getSpriteQuad(column, row)
    return love.graphics.newQuad(
        (column - 1) * SPRITE_FRAME_SIZE,
        (row - 1) * SPRITE_FRAME_SIZE,
        SPRITE_FRAME_SIZE,
        SPRITE_FRAME_SIZE,
        spriteSheet:getDimensions()
    )
end

-- Sprite-sheet (column, row) for the player's current state.
local function frameFor(self)
    if self.dead then
        return 2, 3 -- death pose
    elseif self.kickAnimationTime and self.state == "kick" then
        return math.min(2, math.floor(self.kickAnimationTime / ANIM.frame) + 1), 4
    elseif self.state == "rise" or self.state == "fall" then
        return self.carrying and 4 or 1, self.carrying and 2 or 3
    elseif self.state == "run" then
        return (math.floor(self.animationTime / ANIM.frame) % 3) + 2, self.carrying and 2 or 1
    elseif self.state == "idle" and self.carrying then
        return 1, 2
    elseif self.state == "idle" and self.idleTime >= ANIM.longIdle then
        return math.min(4, 3 + math.floor((self.idleTime - ANIM.longIdle) / ANIM.frame)), 3
    end
    return 1, 1
end

function view.draw(self)
    -- Highlight a grabbable prop (C hold preview)
    if self.hovered then
        local p = self.hovered
        love.graphics.setColor(1, 1, 1, 0.7)
        love.graphics.setLineWidth(1)
        love.graphics.rectangle("line", p.x - p.w / 2 - 2, p.y - p.h / 2 - 2, p.w + 4, p.h + 4)
    end

    -- Active kick hitbox
    if self.kickTime > 0 then
        local kb = controller.kickBox(self)
        love.graphics.setColor(1, 0.92, 0.45, 0.5)
        love.graphics.rectangle("fill", kb.x - kb.w / 2, kb.y - kb.h / 2, kb.w, kb.h)
    end

    if not spriteSheet then
        view.load()
    end

    local column, row = frameFor(self)
    local scaleX = self.facing < 0 and -1 or 1
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(
        spriteSheet,
        getSpriteQuad(column, row),
        self.x,
        self.y + self.h / 2 - SPRITE_FRAME_SIZE,
        0,
        scaleX,
        1,
        SPRITE_FRAME_SIZE / 2,
        0
    )
end

return view
