-- Screen-space drawing for level scripts. Scripts run sandboxed without `love`,
-- so this is the whole drawing surface they get (passed to drawHud).
local render = require("core.graphics.render")
local text = require("core.text")

local ui = {}

function ui.size()
    return render.width, render.height
end

function ui.color(r, g, b, a)
    love.graphics.setColor(r, g, b, a or 1)
end

function ui.rect(x, y, w, h)
    love.graphics.rectangle("fill", x, y, w, h)
end

function ui.text(str, x, y, size)
    text.print(tostring(str), x, y, size)
end

function ui.textWidth(str, size)
    return text.getWidth(tostring(str), size)
end

return ui
