-- Entity type script: "fake_box", a bomb that looks exactly like a box. Grabbing
-- it lights the fuse: it beeps faster and faster, flashing white on each beep,
-- and explodes after `fuse` seconds, held or not. Runs in the sandbox; the base
-- classes Entity and Prop are injected by core/level/loader.lua.
local FakeBox = setmetatable({}, { __index = Prop })
FakeBox.__index = FakeBox

FakeBox.name = "box" -- shown as a plain box (e.g. the HUD's CARRY), to keep the secret
FakeBox.kind = "prop"
FakeBox.assetPath = "assets/box.png"
FakeBox.w, FakeBox.h = 16, 16
FakeBox.fuse = 3            -- seconds from the first grab to the explosion
FakeBox.firstBeep = 0.5     -- seconds between beeps when the fuse is lit
FakeBox.lastBeep = 0.08     -- seconds between beeps just before it blows
FakeBox.flashTime = 0.06    -- seconds each white flash takes to fade
FakeBox.blastRadius = 24    -- kill radius (px); the holder is always inside it
FakeBox.image = nil

function FakeBox.load()
    if not FakeBox.image then
        FakeBox.image = Entity.loadImage(FakeBox.assetPath)
    end
    return FakeBox.image
end

function FakeBox.new(x, y)
    local self = Prop.create(FakeBox, x, y, {
        name = FakeBox.name,
        image = FakeBox.image,
        w = FakeBox.w,
        h = FakeBox.h,
    })
    self.lit = false
    self.fuseTime = 0
    self.nextBeep = 0
    self.blastRadius = FakeBox.blastRadius
    return self
end

function FakeBox:update(delta, level)
    if self.held then
        self.lit = true -- once grabbed, there is no going back
    end
    if self.lit then
        self.fuseTime = self.fuseTime + delta
        self.flash = math.max(0, self.flash - delta / FakeBox.flashTime)
        if self.fuseTime >= self.nextBeep then
            self:playSfx("beep.wav")
            self.flash = 1
            local progress = math.min(self.fuseTime / FakeBox.fuse, 1)
            self.nextBeep = self.fuseTime + FakeBox.firstBeep
                + (FakeBox.lastBeep - FakeBox.firstBeep) * progress
        end
        if self.fuseTime >= FakeBox.fuse then
            self.detonated = true
        end
    end
    Prop.update(self, delta, level)
end

return FakeBox
