-- Entity type script: "checkpoint", a flagpole that saves where a player
-- respawns. Touching it raises the flag (once, with a sound) and sets that
-- player's respawn point; restarting the level (R) still starts from the level
-- spawn. Runs in the sandbox; the base class Entity is injected by
-- core/level/loader.lua.
local Checkpoint = setmetatable({}, { __index = Entity })
Checkpoint.__index = Checkpoint

Checkpoint.name = "checkpoint"
Checkpoint.kind = "trigger"  -- not solid; reacts to players walking through it
Checkpoint.assetPath = "assets/graphics/entities/checkpoint.png" -- 2 frames: 1 flag down, 2 flag up
Checkpoint.w, Checkpoint.h = 16, 32 -- one frame; place it with its bottom on the ground
Checkpoint.image = nil
Checkpoint.frames = nil

function Checkpoint.load()
    if not Checkpoint.image then
        Checkpoint.image = Entity.loadImage(Checkpoint.assetPath)
        Checkpoint.frames = Entity.sliceFrames(Checkpoint.image, Checkpoint.w, Checkpoint.h)
    end
    return Checkpoint.image
end

function Checkpoint.new(x, y)
    local self = Entity.new(Checkpoint, x, y, {
        name = Checkpoint.name,
        image = Checkpoint.image,
        frames = Checkpoint.frames,
        w = Checkpoint.w,
        h = Checkpoint.h,
    })
    self.raised = false
    return self
end

-- The player respawns standing at the pole, feet on the checkpoint's bottom.
function Checkpoint:onTouch(player)
    player:setSpawn(self.x, self.y + self.h / 2 - player.h / 2)
    if not self.raised then
        self.raised = true
        self.frameIndex = 2
        self:playSfx("checkpoint.wav")
    end
end

return Checkpoint
