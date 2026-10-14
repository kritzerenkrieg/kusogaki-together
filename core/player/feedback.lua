-- Sound and camera feedback for player events (called by core/graphics/present.lua).
-- A local player's events get full feedback; a remote player's (network play)
-- only their sound, at the volume and pan of where it happened.
local audio = require("core.audio")
local camera = require("core.graphics.camera")

local feedback = {}

local SOUNDS = { jump = "jump.wav", stomp = "jump.wav", death = "dead.wav" }
local SHAKES = { -- duration (s), intensity (px)
    kickHit = { 0.15, 6 },
    kick = { 0.12, 4 },
    throw = { 0.12, 4 },
    land = { 0.08, 2 },
}

-- `remote`: nil for a local player's event, else { volume, pan } for a remote
-- player's.
function feedback.onEvent(name, remote)
    local sound = SOUNDS[name]
    if sound then
        if remote then
            if remote.volume > 0 then
                audio.playSfx(sound, remote.volume, remote.pan)
            end
        else
            audio.playSfx(sound)
        end
    end
    local shake = SHAKES[name]
    if shake and not remote then
        camera.shake(shake[1], shake[2])
    end
end

return feedback
