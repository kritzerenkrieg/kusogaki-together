-- Drawing the level's static art: background and plain static geometry.
local render = require("core.graphics.render")

local view = {}

function view.drawBackground(background)
    love.graphics.setColor(background.sky)
    love.graphics.rectangle("fill", 0, 0, render.width, render.height)
    love.graphics.setColor(background.band.color)
    love.graphics.rectangle("fill", 0, background.band.y, render.width, background.band.h)
end

-- Plain rectangles from level.json; walls have no top highlight.
function view.drawGeometry(geometry)
    for _, static in ipairs(geometry) do
        local left, top = static.x - static.w / 2, static.y - static.h / 2
        love.graphics.setColor(static.color)
        love.graphics.rectangle("fill", left, top, static.w, static.h)
        if not static.wall then
            love.graphics.setColor(1, 1, 1, 0.12)
            love.graphics.rectangle("fill", left, top, static.w, 3)
        end
    end
end

return view
