-- Simulation events: one-off things that happened during a step (a block
-- broke, an enemy died, a player jumped). Rules report them here instead of
-- calling fx, audio or the camera; core/graphics/present.lua turns them into
-- effects and sound after the step. Network play will send the same events to
-- clients. See ARCHITECTURE.md (Events) and NETWORKING.md (Event bus).
--
-- Every event is a plain table with a `type`. Entity events carry `id` (the
-- entity id) plus `entity`, the object itself: `entity` is for local
-- presentation only and never goes on the wire (a client looks up its own
-- copy by `id`).
local events = {}

local queue -- the running level's event list, only during Level:update

-- Level:update brackets its step with these, so events emitted from deep
-- inside rules and scripts land in that level's list.
function events.begin(list)
    queue = list
end

function events.finish()
    queue = nil
end

-- Report an event. Outside a step (loading, drawing) it is dropped.
function events.emit(event)
    if queue then
        queue[#queue + 1] = event
    end
end

-- Event for something that happened to an entity: type, id, position and size.
function events.entity(eventType, entity, extra)
    local event = {
        type = eventType,
        id = entity.id,
        x = entity.x, y = entity.y, w = entity.w, h = entity.h,
        entity = entity,
    }
    for key, value in pairs(extra or {}) do
        event[key] = value
    end
    events.emit(event)
end

return events
