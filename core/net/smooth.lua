-- Smoothing of bodies another machine moves (Phase 2 step 5, NETWORKING.md
-- Client presentation). Updates arrive 20 times a second with jitter, so a
-- body is shown DELAY behind its sender, blended between the two updates
-- around that moment: movement looks steady even when a packet is late or
-- lost.
--
-- Times are the sender's: an owner's sequence number or a world snapshot
-- number times the send interval (both count fixed ticks). A clock per
-- sender maps them to this machine's time, from the quickest delivery seen
-- (it creeps upward slowly when the delay grows).
local smooth = {}

smooth.DELAY = 0.1        -- s behind the sender (OPEN_DECISION D3)
smooth.EXTRAPOLATE = 0.1  -- s a body keeps moving past its newest update
smooth.SNAP = 64          -- px between two updates that is a teleport, not movement
smooth.KEEP = 20          -- updates kept per body
smooth.CREEP = 0.02       -- how fast a clock follows a growing delay

-- ── Clocks ────────────────────────────────────────────────────────────────

function smooth.clock()
    return { offset = nil }
end

-- An update stamped `remote` (sender's seconds) arrived at `now` (ours).
function smooth.heard(clock, remote, now)
    local offset = now - remote
    if not clock.offset or offset < clock.offset then
        clock.offset = offset
    else
        clock.offset = clock.offset + (offset - clock.offset) * smooth.CREEP
    end
end

-- The sender's time to show at our `now`.
function smooth.showTime(clock, now)
    return now - (clock.offset or now) - smooth.DELAY
end

-- ── Per-body tracks ───────────────────────────────────────────────────────

function smooth.track()
    return { samples = {} }
end

-- Add an update at sender time `time` with `values` (x, y, vx, vy and any
-- other fields). Older or repeated ones are ignored.
function smooth.push(track, time, values)
    local samples = track.samples
    local last = samples[#samples]
    if last and time <= last.time then
        return false
    end
    values.time = time
    samples[#samples + 1] = values
    if #samples > smooth.KEEP then
        table.remove(samples, 1)
    end
    return true
end

-- Where the body is at sender time `time`: x, y, and the update in force
-- then (its other fields). Nil when there is no update yet.
function smooth.sample(track, time)
    local samples = track.samples
    local count = #samples
    if count == 0 then
        return nil
    end
    if time <= samples[1].time then
        return samples[1].x, samples[1].y, samples[1]
    end
    for i = count - 1, 1, -1 do
        local a, b = samples[i], samples[i + 1]
        if time >= a.time then
            if time >= b.time then
                break
            end
            if math.abs(b.x - a.x) + math.abs(b.y - a.y) > smooth.SNAP then
                return a.x, a.y, a -- a teleport (respawn, pipe): no sliding across the map
            end
            local t = (time - a.time) / (b.time - a.time)
            return a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a
        end
    end
    -- Past the newest update: keep its velocity for a short while.
    local newest = samples[count]
    local ahead = math.min(time - newest.time, smooth.EXTRAPOLATE)
    return newest.x + (newest.vx or 0) * ahead, newest.y + (newest.vy or 0) * ahead, newest
end

-- Drop updates older than the one in force at `time` (keeping it).
function smooth.forget(track, time)
    local samples = track.samples
    while #samples > 2 and samples[2].time <= time do
        table.remove(samples, 1)
    end
end

return smooth
