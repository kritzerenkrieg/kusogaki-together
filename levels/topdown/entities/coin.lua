-- Entity type script: "coin", a pickup for the top-down coin race
-- (scripts/coins.lua). A trigger: a player touching it scores a point and it
-- leaves the level. It has no image; it draws itself with `ui`.
local Coin = setmetatable({}, { __index = Entity })
Coin.__index = Coin

Coin.name = "coin"
Coin.kind = "trigger"
Coin.w, Coin.h = 10, 10

function Coin.new(x, y)
    return Entity.new(Coin, x, y, { name = Coin.name, w = Coin.w, h = Coin.h })
end

-- Score for the player, tell every machine (a "+1" popup), and leave.
function Coin:onTouch(player, level)
    player.net.score = (player.net.score or 0) + 1
    level:send("coin", { player = player.id, x = self.x, y = self.y, score = player.net.score })
    level:removeEntity(self)
    if player.net.score >= level.net.goal then
        level:finish("win", ("Player %d collected %d coins!"):format(player.id, player.net.score))
    end
end

function Coin:draw(ui)
    ui.color(0.95, 0.75, 0.15, 1)
    ui.circle(self.x, self.y, self.w / 2)
    ui.color(1, 0.95, 0.6, 1)
    ui.circle(self.x - 1.5, self.y - 1.5, 1.5)
end

return Coin
