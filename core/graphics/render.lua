local render = {}

render.width = 640
render.height = 360

function render.fill(r, g, b, a)
    love.graphics.setColor(r or 0, g or 0, b or 0, a or 1)
    love.graphics.rectangle("fill", 0, 0, render.width, render.height)
end

function render.drawImage(image, x, y, alpha)
    local iw = image:getWidth()
    local ih = image:getHeight()

    local scale = math.max(render.width / iw, render.height / ih)
    local ox = (render.width - iw * scale) / 2 + (x or 0)
    local oy = (render.height - ih * scale) / 2 + (y or 0)

    love.graphics.setColor(1, 1, 1, alpha or 1)
    love.graphics.draw(image, ox, oy, 0, scale, scale)
end

function render.load()
    love.graphics.setDefaultFilter("nearest", "nearest", 0)
    render.canvas = love.graphics.newCanvas(render.width, render.height)
    render.canvas:setFilter("nearest", "nearest")

    local defaultFont = love.graphics.newFont(16, "mono")
    defaultFont:setFilter("nearest", "nearest")
    love.graphics.setFont(defaultFont)
    love.graphics.setBackgroundColor(0.08, 0.10, 0.15)
end

function render.beginFrame()
    love.graphics.setCanvas(render.canvas)
    love.graphics.clear(0.08, 0.10, 0.15, 1)
end

function render.present()
    love.graphics.setCanvas()
    love.graphics.clear(0, 0, 0, 1)

    local windowWidth, windowHeight = love.graphics.getDimensions()
    local scale = math.floor(math.min(windowWidth / render.width, windowHeight / render.height))
    scale = math.max(scale, 1)
    local drawWidth = render.width * scale
    local drawHeight = render.height * scale
    local offsetX = math.floor((windowWidth - drawWidth) / 2)
    local offsetY = math.floor((windowHeight - drawHeight) / 2)

    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(render.canvas, offsetX, offsetY, 0, scale, scale)
end

return render
