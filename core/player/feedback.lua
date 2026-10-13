-- Sound and camera feedback for player events (called by core/graphics/present.lua).
local audio = require("core.audio")
local camera = require("core.graphics.camera")

local feedback = {}

function feedback.onEvent(name)
    if name == "jump" or name == "stomp" then
        audio.playSfx("jump.wav")
    elseif name == "death" then
        audio.playSfx("dead.wav")
    elseif name == "kickHit" then
        camera.shake(0.15, 6)
    elseif name == "kick" or name == "throw" then
        camera.shake(0.12, 4)
    elseif name == "land" then
        camera.shake(0.08, 2)
    end
end

return feedback
