-- Drawing for level and entity scripts. Scripts run sandboxed without `love`,
-- so this is the whole drawing surface they get: level scripts' drawBehind,
-- drawWorld (world space) and drawHud (screen space), entity draw(ui), and a
-- custom player controller's draw. In world space, coordinates are world px.
local render = require("core.graphics.render")
local camera = require("core.graphics.camera")
local text = require("core.text")

local ui = {}

-- Canvas size (screen space): width, height.
function ui.size()
    return render.width, render.height
end

-- The key the player has for `action` ("left", "right", "jump", "hold",
-- "kick", "restart"), as shown: "Z", "Left". Players can change them in
-- Options, so tutorials ask here instead of naming keys.
function ui.key(action)
    local key = type(action) == "string" and require("core.player.config").KEYS[action]
    if type(key) ~= "string" then
        return "?"
    end
    return #key == 1 and key:upper() or (key:sub(1, 1):upper() .. key:sub(2))
end

-- The world rectangle in view: x, y, w, h (world px).
function ui.view()
    return camera.view()
end

function ui.color(r, g, b, a)
    love.graphics.setColor(r, g, b, a or 1)
end

local function modeOf(mode)
    return mode == "line" and "line" or "fill"
end

-- mode: "fill" (default) or "line".
function ui.rect(x, y, w, h, mode)
    love.graphics.rectangle(modeOf(mode), x, y, w, h)
end

function ui.circle(x, y, radius, mode)
    love.graphics.circle(modeOf(mode), x, y, radius)
end

function ui.line(x1, y1, x2, y2, width)
    love.graphics.setLineWidth(width or 1)
    love.graphics.line(x1, y1, x2, y2)
end

-- An image the script loaded (Entity.loadImage), like love.graphics.draw.
function ui.image(image, x, y, rotation, sx, sy, ox, oy)
    love.graphics.draw(image, x, y, rotation or 0, sx or 1, sy or 1, ox or 0, oy or 0)
end

-- One frame of a sprite sheet (Entity.sliceFrames).
function ui.sprite(image, frame, x, y, rotation, sx, sy, ox, oy)
    love.graphics.draw(image, frame.quad, x, y, rotation or 0, sx or 1, sy or 1, ox or 0, oy or 0)
end

function ui.text(str, x, y, size)
    text.print(tostring(str), x, y, size)
end

function ui.textWidth(str, size)
    return text.getWidth(tostring(str), size)
end

return ui
