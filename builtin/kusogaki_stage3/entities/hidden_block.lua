-- Entity type script: "hidden_block", an invisible block in the air. A player
-- jumping up into it bonks their head: a metal block appears there and the
-- player drops. It works once; the level script (scripts/trolls.lua) takes the
-- metal block away again REVEAL_TIME seconds later. Runs in the sandbox; the
-- base class Entity is injected by core/level/loader.lua.
local Hidden = setmetatable({}, { __index = Entity })
Hidden.__index = Hidden

Hidden.name = "hidden_block"
Hidden.kind = "trigger" -- not solid until it shows itself
Hidden.w, Hidden.h = 16, 16
Hidden.bonkSpeed = 60 -- px/s the player drops away at

function Hidden.new(x, y)
    local self = Entity.new(Hidden, x, y, { name = Hidden.name, w = Hidden.w, h = Hidden.h })
    self.blockId = nil -- the metal block, once it showed itself
    return self
end

function Hidden:onTouch(player, level)
    local rising = player.vy < 0 and player.y > self.y -- coming up from below
    if self.blockId or not rising then
        return
    end
    self.blockId = level:spawnEntity("metal", self.x, self.y).id
    player.y = self.y + self.h / 2 + player.h / 2
    player.vy = Hidden.bonkSpeed
    self:playSfx("hit.wav")
end

return Hidden
