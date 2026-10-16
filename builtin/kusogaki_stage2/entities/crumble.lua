-- Entity type script: "crumble", a block that shakes once a player touches it
-- and falls apart `Crumble.delay` seconds later. The level script
-- (scripts/parkour.lua) takes it away when the fuse runs out and puts it back
-- later. Runs in the sandbox; the base class Entity is injected by
-- core/level/loader.lua.
local Crumble = setmetatable({}, { __index = Entity })
Crumble.__index = Crumble

Crumble.name = "crumble"
Crumble.kind = "block"
Crumble.assetPath = "assets/green.png"
Crumble.w, Crumble.h = 16, 16
Crumble.delay = 0.35 -- seconds from the first touch to falling apart
Crumble.netFields = { "fuse" } -- clients draw the shake
Crumble.image = nil

function Crumble.load()
    if not Crumble.image then
        Crumble.image = Entity.loadImage(Crumble.assetPath)
    end
    return Crumble.image
end

function Crumble.new(x, y)
    local self = Entity.new(Crumble, x, y, {
        name = Crumble.name,
        image = Crumble.image,
        w = Crumble.w,
        h = Crumble.h,
    })
    self.fuse = nil -- seconds left once touched
    return self
end

function Crumble:animate(delta)
    if self.fuse then
        self.fuse = math.max(0, self.fuse - delta)
    end
end

-- Any touch lights the fuse; it never breaks on the spot.
function Crumble:onTouch(player)
    if not self.fuse then
        self.fuse = Crumble.delay
    end
    return false
end

function Crumble:onKick(player)
    return false
end

function Crumble:draw(ui)
    local shake = self.fuse and math.sin(self.fuse * 70) * 1.5 or 0
    ui.color(1, 1, 1, 1)
    ui.image(self.image, self.x - self.w / 2 + shake, self.y - self.h / 2)
end

return Crumble
