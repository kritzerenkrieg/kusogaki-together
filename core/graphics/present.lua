-- Presentation of simulation events (core/level/events.lua): effects, sound
-- and camera shake. The simulation never calls these itself.
local fx = require("core.graphics.fx")
local audio = require("core.audio")
local feedback = require("core.player.feedback")
local camera = require("core.graphics.camera")

local present = {}

local function region(event)
    return event.entity and event.entity:region()
end

local function image(event)
    return event.entity and event.entity.image
end

local HEARING = 1 -- view widths past the view's edge where remote sounds fade out

-- Volume and pan for a sound at world x, from the current view: full volume
-- inside it, fading to silence HEARING view widths beyond its edge; panned
-- toward the side it came from.
function present.soundAt(x)
    local left, _, width = camera.view()
    local offset = (x - (left + width / 2)) / (width / 2) -- -1..1 across the view
    local pan = math.min(math.max(offset, -1), 1)
    local outside = math.max(0, math.abs(offset) - 1) / (2 * HEARING)
    return { volume = math.max(0, 1 - outside), pan = pan }
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
    -- Something happened to a player (jump, death, kick...): sound and shake
    -- for a local player, positional sound only for a remote one.
    player = function(event, _, locals)
        local remote = nil
        if locals and not locals[event.player] then
            -- Scripts can put events in the queue too: x may be anything.
            remote = type(event.x) == "number" and present.soundAt(event.x) or { volume = 0, pan = 0 }
        end
        feedback.onEvent(event.name, remote)
    end,
    -- A level script's message (Level:send): its message hooks show it.
    message = function(event, level)
        level:deliver(event.name, event.data)
    end,
    -- Bookkeeping for network play; nothing to show here (the scene draws a
    -- finished level's result itself).
    removed = function() end,
    spawned = function() end,
    finish = function() end,
}

-- `locals`: the ids of the players this machine plays (nil: all of them).
function present.event(event, level, locals)
    local handler = HANDLERS[event.type]
    if handler then
        handler(event, level, locals)
    end
end

function present.all(list, level, locals)
    for _, event in ipairs(list) do
        present.event(event, level, locals)
    end
end

return present
