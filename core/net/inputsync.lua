-- Inputs to the host (hybrid rollback, NETWORKING.md). A client sends its
-- player's input frame for every tick it simulates, as a bit mask
-- (core/input.lua pack), ahead of the host: each message repeats the last few
-- ticks, so a lost one costs nothing. The host uses each player's input at
-- its tick; when one has not arrived it repeats that player's last input
-- (the client's prediction is then corrected by the host's state).
--
-- input message: { g, n, f }: f = masks for ticks n - #f + 1 .. n.
--
-- The host also forwards every player's inputs to the other clients each
-- tick (ahead message, inputsync.forward): what it used up to its tick and
-- what it already has for the ticks after. Clients run ahead of the host, so
-- they learn others' inputs about a round trip after they were pressed
-- instead of waiting for the host's state.
local inputsync = {}

inputsync.REDUNDANCY = 8  -- ticks each input message repeats (133 ms of loss)
inputsync.KEEP = 240      -- ticks of own inputs a client keeps (4 s) for replays
inputsync.TARGET_LEAD = 4 -- ticks early a client's inputs should reach the host (frame jitter)
inputsync.FORWARD = 32    -- at most this many ticks of one player per ahead message

-- ── Client ────────────────────────────────────────────────────────────────

function inputsync.client()
    return { frames = {} }
end

-- This machine's input mask for tick t.
function inputsync.record(client, t, mask)
    client.frames[t] = mask
    client.frames[t - inputsync.KEEP] = nil
end

-- The mask used for tick t (the nearest earlier one when missing).
function inputsync.maskAt(client, t)
    for tick = t, t - 16, -1 do
        if client.frames[tick] then
            return client.frames[tick]
        end
    end
    return 0
end

-- The input message for the ticks up to t.
function inputsync.message(client, t)
    local masks = {}
    for tick = t - inputsync.REDUNDANCY + 1, t do
        if client.frames[tick] then
            masks[#masks + 1] = client.frames[tick]
        elseif #masks > 0 then
            masks[#masks + 1] = masks[#masks]
        end
    end
    return { t = "input", n = t, f = masks }
end

-- ── Host ──────────────────────────────────────────────────────────────────

function inputsync.host()
    return { players = {} }
end

function inputsync.addPlayer(host, id)
    host.players[id] = { frames = {}, newest = 0, last = 0, used = {} }
end

function inputsync.removePlayer(host, id)
    host.players[id] = nil
end

-- A new level: tick numbers start again.
function inputsync.reset(host)
    for _, player in pairs(host.players) do
        player.frames, player.newest, player.last, player.lastTick, player.used = {}, 0, 0, 0, {}
    end
end

-- An input message from player `id`. Inputs for ticks the host already ran
-- are too late for their tick, but the newest of them still becomes the input
-- the host repeats until the next one arrives.
function inputsync.receive(host, id, message, hostTick)
    local player = host.players[id]
    if not player then
        return
    end
    local first = message.n - #message.f + 1
    for i, mask in ipairs(message.f) do
        local tick = first + i - 1
        if tick > hostTick and tick <= hostTick + 600 then
            player.frames[tick] = mask
        elseif tick <= hostTick and tick > (player.lastTick or 0) then
            player.last, player.lastTick = mask, tick
        end
    end
    if message.n > player.newest then
        player.newest = message.n
    end
end

-- The mask player `id` uses at tick t: its own, or its last one again.
function inputsync.take(host, id, t)
    local player = host.players[id]
    if not player then
        return 0
    end
    local mask = player.frames[t]
    if mask then
        player.last, player.lastTick = mask, t
    end
    player.frames[t] = nil
    player.frames[t - 600] = nil
    inputsync.played(host, id, t, player.last)
    return player.last
end

-- Player `id` played `mask` at host tick t (the host's own players say so
-- themselves; take does it for clients).
function inputsync.played(host, id, t, mask)
    local player = host.players[id]
    if not player then
        inputsync.addPlayer(host, id)
        player = host.players[id]
    end
    player.used[t] = mask
    player.used[t - inputsync.FORWARD] = nil
end

-- Player `id`'s inputs to forward after host tick `hostTick`, to a client
-- that was last sent the ones up to tick `sent`: masks for ticks
-- n - #f + 1 .. n, the ones the host used and then the ones it has for its
-- next ticks (exactly what it will use), repeating the last 8 already sent
-- in case a message was lost. Returns n, f, or nil when nothing is known.
function inputsync.forward(host, id, hostTick, sent)
    local player = host.players[id]
    if not player or not player.used[hostTick] then
        return nil
    end
    local n = hostTick
    while player.frames[n + 1] and n < hostTick + inputsync.FORWARD do
        n = n + 1
    end
    local f = {}
    for t = math.max(n - inputsync.FORWARD + 1, sent - inputsync.REDUNDANCY + 1), n do
        local mask = t <= hostTick and player.used[t] or player.frames[t]
        if mask then
            f[#f + 1] = mask
        else
            f = {} -- a gap (just joined): only the ticks after it
        end
    end
    return n, f
end

-- The newest input tick the host has from player `id`.
function inputsync.newest(host, id)
    local player = host.players[id]
    return player and player.newest or 0
end

function inputsync.validMasks(list, maxLength)
    if type(list) ~= "table" or #list > (maxLength or inputsync.REDUNDANCY) or next(list, #list > 0 and #list or nil) ~= nil then
        return false
    end
    for _, mask in ipairs(list) do
        if type(mask) ~= "number" or mask % 1 ~= 0 or mask < 0 or mask >= 2 ^ 24 then
            return false
        end
    end
    return true
end

return inputsync
