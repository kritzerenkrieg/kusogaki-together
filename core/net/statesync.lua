-- Host state to clients (hybrid rollback, NETWORKING.md). 20 times a second
-- the host saves its level's whole state (core/level/fullstate.lua) after
-- tick h and sends each client what changed since the state that client
-- last acknowledged, field by field, or the whole state when it has none the
-- host still remembers. A hash of the whole state travels with it: a client
-- whose rebuilt state does not match asks for a full one (acknowledges 0).
--
-- A state is flattened to keys -> values: "p.<id>.<field>" for players,
-- "e.<id>.<field>" for entities, "s.<name>" for the rest (random generator,
-- list orders, statics, level state). Values are plain data.
--
-- snap message: { g, h, base, set, del, hash, ack, inp, vt, cd }
--   h     the host tick the state is after;  base  the acknowledged h (0: full)
--   set   { key, value } changed since base;  del  keys gone since base
--   ack   the newest input tick the host has from this client
--   inp   { id, mask } the input each player used at tick h (to predict them)
--   vt    restart votes;  cd  countdown seconds or false
local wire = require("core.wire")

local statesync = {}

statesync.HISTORY = 40     -- states remembered (2 s at 20 Hz)
statesync.FULL_EVERY = 1   -- s between full states to a client without a usable base

-- ── Flat form ─────────────────────────────────────────────────────────────

function statesync.flatten(state)
    local flat = {}
    for id, fields in pairs(state.players) do
        for field, value in pairs(fields) do
            flat["p." .. id .. "." .. field] = value
        end
    end
    for id, fields in pairs(state.entities) do
        for field, value in pairs(fields) do
            flat["e." .. id .. "." .. field] = value
        end
    end
    for key, value in pairs(state) do
        if key ~= "players" and key ~= "entities" then
            flat["s." .. key] = value
        end
    end
    return flat
end

function statesync.unflatten(flat)
    local state = { players = {}, entities = {} }
    for key, value in pairs(flat) do
        local kind, id, field = key:match("^([pe])%.(%d+)%.(.+)$")
        if kind then
            local group = kind == "p" and state.players or state.entities
            id = tonumber(id)
            group[id] = group[id] or {}
            group[id][field] = value
        else
            local name = key:match("^s%.(.+)$")
            if name then
                state[name] = value
            end
        end
    end
    return state
end

-- Encoded value per key, and the hash of the whole (keys sorted).
local function encodeAll(flat)
    local encoded, keys = {}, {}
    for key, value in pairs(flat) do
        encoded[key] = wire.encode(value)
        keys[#keys + 1] = key
    end
    table.sort(keys)
    local parts = {}
    for i, key in ipairs(keys) do
        parts[i] = key .. "\0" .. encoded[key]
    end
    local hash = love.data.encode("string", "hex", love.data.hash("md5", table.concat(parts, "\0"))):sub(1, 16)
    return encoded, hash
end

function statesync.hashOf(flat)
    local _, hash = encodeAll(flat)
    return hash
end

-- The hash from already encoded values and their sorted keys.
local function hashSorted(keys, encoded)
    local parts = {}
    for i, key in ipairs(keys) do
        parts[i] = key .. "\0" .. encoded[key]
    end
    return love.data.encode("string", "hex", love.data.hash("md5", table.concat(parts, "\0"))):sub(1, 16)
end

local function sameValue(a, b)
    if a == b then
        return true
    end
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    for key, value in pairs(a) do
        if not sameValue(value, b[key]) then
            return false
        end
    end
    for key in pairs(b) do
        if a[key] == nil then
            return false
        end
    end
    return true
end
statesync.sameValue = sameValue

-- Do two flat states hold exactly the same values?
function statesync.same(a, b)
    return sameValue(a, b)
end

-- ── Host ──────────────────────────────────────────────────────────────────

function statesync.host()
    return { history = {}, clients = {} }
end

-- A new level: forget every state; every client gets a full one.
function statesync.reset(host)
    host.history = {}
    for _, client in pairs(host.clients) do
        client.ack, client.lastFull = 0, -math.huge
    end
end

function statesync.addClient(host, id)
    host.clients[id] = { ack = 0, lastFull = -math.huge }
end

function statesync.removeClient(host, id)
    host.clients[id] = nil
end

-- Client `id` has the state after host tick `h` (0: it needs a full one).
function statesync.acknowledge(host, id, h)
    local client = host.clients[id]
    if client and (h == 0 or h > client.ack) then
        client.ack = h
    end
end

-- Remember the state after tick `h` (a fullstate.capture).
function statesync.record(host, h, state)
    local flat = statesync.flatten(state)
    local encoded, hash = encodeAll(flat)
    local entry = { h = h, flat = flat, encoded = encoded, hash = hash }
    host.history[h] = entry
    for old in pairs(host.history) do
        if old <= h - statesync.HISTORY * 3 then
            host.history[old] = nil
        end
    end
    return entry
end

-- The state message for client `id` from `entry` (statesync.record): a delta
-- against the state it acknowledged, else a full one (at most once per
-- FULL_EVERY s), else nil. Second result: true for a full state (send it
-- reliably). The caller adds g, ack, inp, vt, cd.
function statesync.messageFor(host, id, entry, now)
    local client = host.clients[id]
    if not client then
        return nil
    end
    local base = client.ack > 0 and host.history[client.ack] or nil
    if not base then
        if now - client.lastFull < statesync.FULL_EVERY then
            return nil
        end
        client.lastFull = now
    end
    local set, del = {}, {}
    for key, value in pairs(entry.flat) do
        if not base or base.encoded[key] ~= entry.encoded[key] then
            set[#set + 1] = { key, value }
        end
    end
    if base then
        for key in pairs(base.flat) do
            if entry.flat[key] == nil then
                del[#del + 1] = key
            end
        end
    end
    table.sort(set, function(a, b) return a[1] < b[1] end)
    table.sort(del)
    return { t = "snap", h = entry.h, base = base and base.h or 0, set = set, del = del, hash = entry.hash },
        base == nil
end

-- ── Client ────────────────────────────────────────────────────────────────

function statesync.client()
    return { history = {}, newest = 0, needFull = false }
end

-- The host tick to acknowledge.
function statesync.ack(client)
    return client.needFull and 0 or client.newest
end

-- Rebuild the state a message describes. Returns the state (for
-- fullstate.restore), its tick and its flat form, or nil and why: older than
-- what we have, a base we no longer have, or a hash mismatch (a full state
-- is then asked for). Only the values that changed are encoded again.
function statesync.receive(client, message)
    if message.h <= client.newest then
        return nil, "old"
    end
    local base
    if message.base == 0 then
        base = { flat = {}, encoded = {}, keys = {} }
    else
        base = client.history[message.base]
        if not base then
            return nil, "no base"
        end
    end
    local flat, encoded = {}, {}
    for key, value in pairs(base.flat) do
        flat[key], encoded[key] = value, base.encoded[key]
    end
    local keysChanged = #message.del > 0
    for _, key in ipairs(message.del) do
        flat[key], encoded[key] = nil, nil
    end
    for _, entry in ipairs(message.set) do
        local key = entry[1]
        if flat[key] == nil then
            keysChanged = true
        end
        flat[key], encoded[key] = entry[2], wire.encode(entry[2])
    end
    local keys = base.keys
    if keysChanged or message.base == 0 then
        keys = {}
        for key in pairs(flat) do
            keys[#keys + 1] = key
        end
        table.sort(keys)
    end
    if hashSorted(keys, encoded) ~= message.hash then
        client.needFull = true
        return nil, "hash"
    end
    client.history[message.h] = { flat = flat, encoded = encoded, keys = keys }
    for h in pairs(client.history) do
        if h <= message.h - statesync.HISTORY * 3 then
            client.history[h] = nil
        end
    end
    client.newest, client.needFull = message.h, false
    return statesync.unflatten(flat), message.h, flat
end

return statesync
