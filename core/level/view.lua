-- Drawing the level's static art: background and static geometry (tiled or plain).
local render = require("core.graphics.render")

local view = {}

function view.drawBackground(background)
    love.graphics.setColor(background.sky)
    love.graphics.rectangle("fill", 0, 0, render.width, render.height)
end

-- Repeating quad of w x h over `image` (its wrap mode is "repeat"), or nil.
local function tiledQuad(image, w, h)
    if not image or h <= 0 then
        return nil
    end
    return love.graphics.newQuad(0, 0, w, h, image:getWidth(), image:getHeight())
end

-- Seed from the static's placement, so a level always looks the same (and the
-- same for every player).
local function staticSeed(static)
    return math.abs(math.floor(static.x * 7919 + static.y * 104729 + static.w * 31 + static.h)) + 1
end

-- Fill tiles in random orientations: each full tile gets one of 4 rotations
-- (2 if the tile is not square), optionally mirrored. Partial tiles at the
-- right and bottom edges stay unrotated and cropped, so nothing spills outside.
local function randomFillBatch(image, w, h, seed)
    local tw, th = image:getDimensions()
    local turns = tw == th and 4 or 2
    local rng = love.math.newRandomGenerator(seed)
    local batch = love.graphics.newSpriteBatch(image, math.ceil(w / tw) * math.ceil(h / th))
    local full = love.graphics.newQuad(0, 0, tw, th, tw, th)
    for y = 0, h - 1, th do
        for x = 0, w - 1, tw do
            local cw, ch = math.min(tw, w - x), math.min(th, h - y)
            if cw == tw and ch == th then
                local rotation = rng:random(0, turns - 1) * (2 * math.pi / turns)
                local mirror = rng:random(0, 1) == 0 and 1 or -1
                batch:add(full, x + tw / 2, y + th / 2, rotation, mirror, 1, tw / 2, th / 2)
            else
                batch:add(love.graphics.newQuad(0, 0, cw, ch, tw, th), x, y)
            end
        end
    end
    return batch
end

-- A tiled static: one row of the top tile, the fill tile below it (in random
-- orientations with tiles.randomFill). Built on first draw, kept on the static.
local function drawTiles(static, left, top)
    local topH = static.topImage and math.min(static.h, static.topImage:getHeight()) or 0
    local fillH = static.h - topH
    if not static.tileCache then
        local cache = { top = tiledQuad(static.topImage, static.w, topH) }
        if static.fillImage and fillH > 0 and static.tiles.randomFill then
            cache.fillBatch = randomFillBatch(static.fillImage, static.w, fillH, staticSeed(static))
        else
            cache.fill = tiledQuad(static.fillImage, static.w, fillH)
        end
        static.tileCache = cache
    end
    local cache = static.tileCache
    love.graphics.setColor(1, 1, 1, 1)
    if cache.top then
        love.graphics.draw(static.topImage, cache.top, left, top)
    end
    if cache.fillBatch then
        love.graphics.draw(cache.fillBatch, left, top + topH)
    elseif cache.fill then
        love.graphics.draw(static.fillImage, cache.fill, left, top + topH)
    end
end

-- Statics from level.json: tiled when they name tiles, otherwise a colored
-- rectangle (walls have no top highlight).
function view.drawGeometry(geometry)
    for _, static in ipairs(geometry) do
        local left, top = static.x - static.w / 2, static.y - static.h / 2
        if static.topImage or static.fillImage then
            drawTiles(static, left, top)
        else
            love.graphics.setColor(static.color)
            love.graphics.rectangle("fill", left, top, static.w, static.h)
            if not static.wall then
                love.graphics.setColor(1, 1, 1, 0.12)
                love.graphics.rectangle("fill", left, top, static.w, 3)
            end
        end
    end
end

return view
