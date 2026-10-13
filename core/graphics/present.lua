-- Presentation of simulation events (core/level/events.lua): effects, sound
-- and camera shake. The simulation never calls these itself.
local fx = require("core.graphics.fx")
local audio = require("core.audio")
local feedback = require("core.player.feedback")

local present = {}

local function region(event)
    return event.entity and event.entity:region()
end

local function image(event)
    return event.entity and event.entity.image
end

local HANDLERS = {
    -- A block or detonating body exploded.
    explosion = function(event, level)
        fx.explosion(event.x, event.y, event.w, event.h, image(event), level.statics, region(event))
        audio.playSfx("debris.wav")
    end,
    -- A block broke into pieces.
    debris = function(event, level)
        fx.debris(event.x, event.y, event.w, event.h, image(event), level.statics, region(event))
        audio.playSfx("debris.wav")
    end,
    -- An enemy died: squashed by a stomp, or thrown away by a kick, hit or blast.
    corpse = function(event)
        if event.cause == "stomp" then
            fx.flatten(event.x, event.y, event.w, event.h, image(event), region(event))
        else
            fx.throwAway(event.x, event.y, event.w, event.h, image(event), region(event), event.vx, event.vy)
        end
        if event.cause ~= "blast" then -- a blast already has its explosion sound
            audio.playSfx("hit.wav")
        end
    end,
    -- An entity script asked for a sound (Entity:playSfx): the package's own
    -- assets/<name> first, else the engine's sound effects.
    sfx = function(event, level)
        -- Same rule as Entity:playSfx: scripts can also put events in the queue.
        local extension = type(event.name) == "string" and event.name:match("^[%w_]+%.(%w+)$")
        if not (extension == "wav" or extension == "ogg" or extension == "mp3") then
            return
        end
        local packaged = level.root and (level.root .. "/assets/" .. event.name)
        if packaged and love.filesystem.getInfo(packaged, "file") then
            audio.playSfxFile(packaged)
        else
            audio.playSfx(event.name)
        end
    end,
    -- Something happened to a player (jump, death, kick...): sound and shake.
    player = function(event)
        feedback.onEvent(event.name)
    end,
    -- Bookkeeping for network play; nothing to show.
    removed = function() end,
}

function present.event(event, level)
    local handler = HANDLERS[event.type]
    if handler then
        handler(event, level)
    end
end

function present.all(list, level)
    for _, event in ipairs(list) do
        present.event(event, level)
    end
end

return present
