-- Entity type script: "trap", an invisible zone. The first player to walk
-- into it springs it: the entities it lists appear (spikes out of the ground,
-- dodons from the sky). With a `time`, spawned things that are still there go
-- away once nobody has been in the zone for that long, and the trap is armed
-- again; without one it springs once and they stay. The level script
-- (scripts/trolls.lua) runs the timer. Runs in the sandbox; the base class
-- Entity is injected by core/level/loader.lua.
--
-- Placement:
--   { "type": "trap", "x": 870, "y": 250, "w": 16, "h": 64,
--     "spawn": [ { "type": "spike", "x": 912, "y": 270 } ],
--     "time": 2 }                                         -- optional
local Trap = setmetatable({}, { __index = Entity })
Trap.__index = Trap

Trap.name = "trap"
Trap.kind = "trigger"

function Trap.new(x, y, def)
    def = def or {}
    local self = Entity.new(Trap, x, y, { name = Trap.name, w = def.w or 16, h = def.h or 64 })
    self.spawnList = def.spawn or {}
    self.time = def.time
    self.sprung = false
    self.timer = 0
    self.spawned = {} -- ids of what it spawned
    return self
end

function Trap:onTouch(player, level)
    self.timer = self.time or 0
    if self.sprung then
        return
    end
    self.sprung = true
    self.spawned = {}
    for i, what in ipairs(self.spawnList) do
        self.spawned[i] = level:spawnEntity(what.type, what.x, what.y).id
    end
    local first = self.spawned[1] and level:get(self.spawned[1])
    if first then
        first:playSfx("hit.wav")
    end
end

return Trap
