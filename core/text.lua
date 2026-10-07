local text = {}

local fonts = {}

local function getFont(size)
    local key = size or 16
    if not fonts[key] then
        fonts[key] = love.graphics.newFont(key, "mono")
        fonts[key]:setFilter("nearest", "nearest")
    end
    return fonts[key]
end

function text.print(t, x, y, size)
    love.graphics.setFont(getFont(size))
    love.graphics.print(t, x, y)
end

function text.printf(t, x, y, width, align, size)
    love.graphics.setFont(getFont(size))
    love.graphics.printf(t, x, y, width, align)
end

function text.getWidth(t, size)
    return getFont(size):getWidth(t)
end

return text