-- World sync (Phase 2 step 3, NETWORKING.md Host → clients). The host runs
-- the world: every rule, entity and level script. 20 times a second it
-- captures the synced state (entities, level state, players' `net`) as a
-- numbered snapshot and sends each client the changes since the snapshot
-- that client last acknowledged (in its `state` messages), or a full
-- snapshot when it has none the host still remembers. A hash of the whole
-- state travels with each one: a client whose rebuilt state does not match
-- asks for a full snapshot (acknowledges 0). Modders write none of this: the
-- engine finds what scripts changed by comparing snapshots.
--
-- A client runs only its own player's stages (CLIENT_STAGES) against the
-- world it was sent, and draws. Bodies are shown 100 ms behind the host,
-- blended between snapshots (core/net/smooth.lua).
--
-- world message: { g, n, base, ents, gone, lvl, pl, vt, cd, hash }
--   n     snapshot number;  base  the acknowledged one it is a delta to (0: full)
--   ents  entity records (core/level/netstate.lua wire lists) new or changed
--   gone  ids of entities removed since base
--   lvl   level state, or false when unchanged since base
--   pl    { id, net } of players whose script state changed since base
--   vt    restart votes (player ids); cd: countdown seconds, or false
--   hash  16 hex digits of the md5 of the whole state
local wire = require("core.wire")
local netstate = require("core.level.netstate")
local loader = require("core.level.loader")
local smooth = require("core.net.smooth")

local worldsync = {}

worldsync.HISTORY = 32       -- snapshots remembered (1.6 s at 20 Hz)
worldsync.FULL_EVERY = 1     -- s between full snapshots to a client that has no usable base
worldsync.EXTRAPOLATE = 0.1  -- s a body this machine moved (a claim) keeps moving
worldsync.INTERVAL = 3 / 60  -- s of host time between snapshots

-- What a client's own step runs: its player against the world it was sent.
-- Deaths by hazards, enemies and falling out are decided by the victim's
-- machine (NETWORKING.md, Interactions between owners); what it does to the
-- world (stomps, kicks, breaking blocks, carrying) becomes claims
-- (core/level/claims.lua), shown at once by the "claims" stage.
worldsync.CLIENT_STAGES = {
    input = true, players = true, collisions = true, hazards = true, breakBlocks = true, enemyTouch = true,
    bounds = true, claims = true, playerAnimation = true,
}

-- One-off events the host forwards on the reliable channel. Player events
-- travel with player states; spawns and removals with snapshots.
worldsync.FORWARD_EVENTS = { explosion = true, debris = true, corpse = true, sfx = true, message = true }

local GRID = 8 -- positions and velocities snap to 1/8 (OPEN_DECISION D2)

local function snap(value)
    if type(value) ~= "number" then
        return value
    end
    return math.floor(value * GRID + 0.5) / GRID
end

local function hashOf(entities, lvl, players)
    local ids = {}
    for id in pairs(entities) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    local list = {}
    for i, id in ipairs(ids) do
        list[i] = entities[id]
    end
    local playerIds = {}
    for id in pairs(players) do
        playerIds[#playerIds + 1] = id
    end
    table.sort(playerIds)
    local playerList = {}
    for i, id in ipairs(playerIds) do
        playerList[i] = { id, players[id] }
    end
    local bytes = wire.encode({ list, lvl or false, playerList })
    return love.data.encode("string", "hex", love.data.hash("md5", bytes)):sub(1, 16)
end

local function key(value)
    return wire.encode(value)
end

-- ── Host ──────────────────────────────────────────────────────────────────

function worldsync.host()
    return { n = 0, history = {}, clients = {} }
end

-- A new level (restart): forget every snapshot; every client gets a full one.
function worldsync.reset(host)
    host.history = {}
    for _, client in pairs(host.clients) do
        client.ack, client.lastFull = 0, -math.huge
    end
end

function worldsync.addClient(host, id)
    host.clients[id] = { ack = 0, lastFull = -math.huge }
end

function worldsync.removeClient(host, id)
    host.clients[id] = nil
end

-- A client acknowledged snapshot `n` (0: it needs a full one).
function worldsync.acknowledge(host, id, n)
    local client = host.clients[id]
    if client and (n == 0 or n > client.ack) then
        client.ack = n
    end
end

-- Capture the level's synced state as the next snapshot. Raises when script
-- state is not plain data (call it under script limits).
function worldsync.capture(host, level)
    local snapshot = netstate.snapshot(level, 0)
    local entities, keys = {}, {}
    for _, record in ipairs(snapshot.entities) do
        for _, field in ipairs({ "x", "y", "vx", "vy" }) do
            record[field] = snap(record[field])
        end
        local entity = level:get(record.id)
        local list = netstate.packEntity(record, entity and entity.netFields)
        entities[record.id], keys[record.id] = list, key(list)
    end
    local players, playerKeys = {}, {}
    for _, player in ipairs(snapshot.players) do
        players[player.id] = player.net or {}
        playerKeys[player.id] = key(players[player.id])
    end
    host.n = host.n + 1
    local state = {
        n = host.n, entities = entities, keys = keys, lvl = snapshot.level, lvlKey = key(snapshot.level),
        players = players, playerKeys = playerKeys,
    }
    state.hash = hashOf(entities, state.lvl, players)
    host.history[state.n] = state
    host.history[state.n - worldsync.HISTORY] = nil
    return state
end

-- The world message for client `id` from snapshot `state`: a delta against
-- the snapshot it acknowledged, else a full one (at most once per
-- FULL_EVERY s), else nil (a full one is on its way). Second result: true
-- for a full snapshot (send it reliably).
function worldsync.messageFor(host, id, state, now)
    local client = host.clients[id]
    if not client then
        return nil
    end
    local base = client.ack > 0 and host.history[client.ack] or nil
    if not base then
        if now - client.lastFull < worldsync.FULL_EVERY then
            return nil
        end
        client.lastFull = now
    end
    local ents, gone, pl = {}, {}, {}
    for entityId, list in pairs(state.entities) do
        if not base or base.keys[entityId] ~= state.keys[entityId] then
            ents[#ents + 1] = list
        end
    end
    table.sort(ents, function(a, b) return a[1] < b[1] end)
    if base then
        for entityId in pairs(base.entities) do
            if not state.entities[entityId] then
                gone[#gone + 1] = entityId
            end
        end
        table.sort(gone)
    end
    for playerId, net in pairs(state.players) do
        if not base or base.playerKeys[playerId] ~= state.playerKeys[playerId] then
            pl[#pl + 1] = { playerId, net }
        end
    end
    table.sort(pl, function(a, b) return a[1] < b[1] end)
    local lvl = (not base or base.lvlKey ~= state.lvlKey) and state.lvl or false
    return {
        t = "world", n = state.n, base = base and base.n or 0, ents = ents, gone = gone, lvl = lvl, pl = pl,
        hash = state.hash,
    }, base == nil
end

-- ── Client ────────────────────────────────────────────────────────────────

function worldsync.client()
    return { history = {}, newest = 0, needFull = false, clock = smooth.clock() }
end

-- The snapshot number to acknowledge in the next state message.
function worldsync.ack(client)
    return client.needFull and 0 or client.newest
end

-- Rebuild the state a world message describes. Returns it (and keeps it as
-- a base for later deltas), or nil and why: older than what we have, a base
-- we no longer have, or a hash mismatch (then a full snapshot is requested).
function worldsync.receive(client, message)
    if message.n <= client.newest then
        return nil, "old"
    end
    local base
    if message.base == 0 then
        base = { entities = {}, lvl = false, players = {} }
    else
        base = client.history[message.base]
        if not base then
            return nil, "no base"
        end
    end
    local entities, players = {}, {}
    for id, list in pairs(base.entities) do
        entities[id] = list
    end
    for _, id in ipairs(message.gone) do
        entities[id] = nil
    end
    for _, list in ipairs(message.ents) do
        entities[list[1]] = list
    end
    for id, net in pairs(base.players) do
        players[id] = net
    end
    for _, entry in ipairs(message.pl) do
        players[entry[1]] = entry[2]
    end
    local lvl = message.lvl or base.lvl
    if hashOf(entities, lvl, players) ~= message.hash then
        client.needFull = true
        return nil, "hash"
    end
    local state = { n = message.n, entities = entities, lvl = lvl, players = players }
    client.history[state.n] = state
    for n in pairs(client.history) do
        if n <= state.n - worldsync.HISTORY then
            client.history[n] = nil
        end
    end
    client.newest, client.needFull = state.n, false
    return state
end

-- Create an entity the host spawned, with the host's id, without events.
local function create(level, typeName, id, x, y, def)
    local Type = loader.loadType(level.root, typeName, level.types, level.random)
    local entity, listName = loader.newEntity(Type, typeName, x, y, def or {}, "spawn")
    entity.id = id
    entity.spawned = true
    entity.spawnDef = def
    local list = level[listName]
    list[#list + 1] = entity
    if entity.kind == "hazard" or entity.kind == "block" then
        level.statics[#level.statics + 1] = entity
    end
    level.byId[id] = entity
    return entity
end

local function extrasOf(level, list)
    local entity = level:get(list[1])
    if entity then
        return entity.netFields
    end
    local typeName = list[2]
    if type(typeName) == "string" then
        local Type = loader.loadType(level.root, typeName, level.types, level.random)
        return Type.netFields
    end
    return nil
end

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local SKIP = { spawnedType = true, spawnDef = true }

local function resolveFollow(level, follow)
    if type(follow) ~= "table" then
        return follow == false and "fixed" or follow
    end
    if follow.player then
        for _, player in ipairs(level.players) do
            if player.id == follow.player then
                return player
            end
        end
    elseif follow.entity then
        return level:get(follow.entity)
    end
    return "players"
end

-- Put back an entity a claim took out here (the host denied it).
local function restore(level, entity)
    local list = level[loader.LIST_FOR_KIND[entity.kind]]
    list[#list + 1] = entity
    if entity.kind == "hazard" or entity.kind == "block" then
        level.statics[#level.statics + 1] = entity
    end
    level.byId[entity.id] = entity
    entity.removed, entity.brokenBy = nil, nil
end

-- Claims in flight (`pending`: entity id -> { until = snapshot number or
-- nil, expires = time }): the claimed entity keeps this machine's version
-- until a snapshot at or after the host's verdict arrives (or 3 s pass).
function worldsync.settle(pending, n, now)
    for id, entry in pairs(pending) do
        if (entry["until"] and n >= entry["until"]) or now > entry.expires then
            pending[id] = nil
        end
    end
end

-- Make the level match a rebuilt state: entities created, updated, restored
-- and removed, level state and players' `net` set. Run under script limits
-- (creating a spawned entity runs its type's script). Entities with a claim
-- in flight (`pending`) and bodies a player carries keep this machine's
-- version. Entities taken out go to `level.graveyard` (id -> entity), so a
-- late event can still show them. With `clock` (a client's) and our time
-- `now`, positions go to each body's smoothing track (worldsync.advance shows
-- them); without, they are set at once.
function worldsync.apply(level, state, pending, clock, now)
    pending = pending or {}
    local time = state.n * worldsync.INTERVAL
    if clock then
        smooth.heard(clock, time, now)
    end
    level.graveyard = level.graveyard or {}
    local carried = {}
    for _, player in ipairs(level.players) do
        if player.carrying then
            carried[player.carrying] = true
        end
    end
    for id, list in pairs(state.entities) do
        local record = netstate.unpackEntity(list, extrasOf(level, list))
        local entity = level:get(id)
        if not entity and not pending[id] and not record.spawnedType and level.graveyard[id] then
            entity = level.graveyard[id] -- a claim here took it out; the host kept it
            level.graveyard[id] = nil
            restore(level, entity)
        end
        if pending[id] or (entity and carried[entity]) then
            if entity then
                entity.track = nil -- this machine's version stands for now; smoothing restarts after
            end
            goto continue
        end
        local spawnedType = entity and entity.spawned and entity.typeName or nil
        if entity and spawnedType ~= record.spawnedType then
            level:removeEntity(entity) -- a different body under this id here: replace it
            entity = nil
        end
        if not entity and record.spawnedType and finite(record.x) and finite(record.y) then
            entity = create(level, record.spawnedType, id, record.x, record.y, record.spawnDef)
        end
        if entity and finite(record.x) and finite(record.y) then
            local shownX, shownY = entity.x, entity.y
            for _, field in ipairs(netstate.ENTITY_FIELDS) do
                if not SKIP[field] then
                    entity[field] = record[field]
                end
            end
            for _, field in ipairs(entity.netFields or {}) do
                entity[field] = record[field]
            end
            entity.vx, entity.vy = entity.vx or 0, entity.vy or 0
            entity.facing = entity.facing or 1
            entity.killedBy, entity.detonated = nil, nil -- the host decides who is dead
            entity.syncAge = 0
            if clock then
                local fresh = entity.track == nil
                entity.track = entity.track or smooth.track()
                smooth.push(entity.track, time, { x = entity.x, y = entity.y, vx = entity.vx, vy = entity.vy })
                if not fresh then
                    entity.x, entity.y = shownX, shownY -- moved by worldsync.advance
                end
            end
            if entity.kind == "prop" then
                entity.immovable = true -- the host moves props; this machine claims kicks
            end
        end
        ::continue::
    end
    local gone = {}
    for id, entity in pairs(level.byId) do
        if not state.entities[id] and not pending[id] then
            gone[#gone + 1] = entity
        end
    end
    for _, entity in ipairs(gone) do
        level:removeEntity(entity)
        level.graveyard[entity.id] = entity
    end
    for _, player in ipairs(level.players) do
        if player.carrying and player.carrying.removed then
            player.carrying = nil -- the host took it out of the level
        end
    end
    local lvl = state.lvl
    if type(lvl) == "table" then
        level.net = type(lvl.net) == "table" and lvl.net or {}
        level.finished = lvl.finished
        if type(lvl.faulted) == "string" and not level.faulted then
            level.faulted = lvl.faulted
        end
        level.gravity = finite(lvl.gravity) and lvl.gravity or level.gravity
        local camera = type(lvl.camera) == "table" and lvl.camera or {}
        level.camera.follow = resolveFollow(level, camera.follow) or level.camera.follow
        level.camera.x, level.camera.y, level.camera.zoom = camera.x, camera.y, camera.zoom or level.camera.zoom
    end
    for _, player in ipairs(level.players) do
        local net = state.players[player.id]
        if type(net) == "table" then
            player.net = net
        end
    end
end

-- One client tick of the world at our time `now`: bodies shown 100 ms behind
-- the host, blended between snapshots. A body this machine moved itself (a
-- kicked prop, while its claim is pending) keeps its velocity for a short
-- while instead.
function worldsync.advance(level, delta, clock, now)
    local time = clock and smooth.showTime(clock, now)
    for _, list in ipairs({ level.enemies, level.props, level.blocks, level.hazards }) do
        for _, body in ipairs(list) do
            if body.held then
                body.track = nil
            elseif body.track and time then
                local x, y, sample = smooth.sample(body.track, time)
                if x then
                    body.x, body.y, body.vx, body.vy = x, y, sample.vx, sample.vy
                    smooth.forget(body.track, time)
                end
            elseif list == level.enemies or list == level.props then
                body.syncAge = (body.syncAge or 0) + delta
                if body.syncAge <= worldsync.EXTRAPOLATE then
                    body.x = body.x + (body.vx or 0) * delta
                    body.y = body.y + (body.vy or 0) * delta
                end
            end
        end
    end
end

-- A forwarded event as the client shows it: `entity` looked up by id here
-- (or among bodies taken out). Nil when this machine already showed it (its
-- own claim).
function worldsync.localEvent(level, event)
    if event.id then
        if level.shown and level.shown[event.id] and event.type ~= "sfx" and event.type ~= "message" then
            return nil
        end
        event.entity = level:get(event.id) or (level.graveyard and level.graveyard[event.id]) or nil
    end
    return event
end

return worldsync
