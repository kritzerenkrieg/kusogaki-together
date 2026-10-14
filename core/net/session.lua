-- Network sessions over ENet: the host side (accepts up to 4 clients, runs the
-- join handshake, sends session messages) and the client side (connects,
-- answers the handshake, receives what the host sends). Game logic stays in
-- the caller: both sides report through a handler table and never touch the
-- level themselves. See core/net/protocol.lua for the messages and
-- NETWORKING.md (Session flow, Source of truth).
--
-- Both sides call `service()` once per frame; it handles everything that
-- arrived and returns at once.
local enet = require("enet")
local protocol = require("core.net.protocol")
local version = require("core.version")

local session = {}

local MAX_CLIENTS = protocol.MAX_PLAYERS - 1
local TIMEOUT_MS = 5000      -- a peer silent this long is dropped (OPEN_DECISION C3)
local HANDSHAKE_SECONDS = 5  -- a client must finish the handshake within this
local MAX_STATES = 60        -- player states a client may send per second (20 expected)

local function now()
    return love.timer.getTime()
end

-- ENet drops a peer after it stops acknowledging for TIMEOUT_MS.
local function setTimeout(peer)
    peer:timeout(32, TIMEOUT_MS, TIMEOUT_MS)
end

local function send(peer, message, channel)
    local flag = channel == protocol.STATE and "unsequenced" or "reliable"
    peer:send(protocol.encode(message), channel, flag)
end

-- ── Host ──────────────────────────────────────────────────────────────────

local Host = {}
Host.__index = Host

-- Open a session. options:
--   port      UDP port (default protocol.PORT); bind address options.bind (default "*")
--   level     { name, fingerprint } of the level being played
--   handler   the game's side:
--     accept()            -> a free player id, or nil and a reason (session full)
--     welcome(id)         -> { seed, generation, players } once that client is in
--     snapshot()          -> { generation, data } full snapshot, or nil
--     left(id)            a joined client left or timed out
--     vote(id, on)        a joined client's player toggled its restart vote
--     state(id, message)  a joined client's player state (core/net/playersync.lua)
-- Returns the host, or nil and an error (port in use).
function session.host(options)
    local address = (options.bind or "*") .. ":" .. (options.port or protocol.PORT)
    local ok, enetHost = pcall(enet.host_create, address, MAX_CLIENTS + 2, protocol.CHANNELS)
    if not ok or not enetHost then
        return nil, "could not open port " .. (options.port or protocol.PORT)
    end
    return setmetatable({
        enet = enetHost,
        level = options.level,
        handler = options.handler,
        game = version.GAME, -- versions this host plays (fixed when it opens)
        protocol = version.PROTOCOL,
        peers = {}, -- peer index -> { peer, stage = "hello" | "ready" | "joined", id, since, states }
    }, Host)
end

-- Refuse a peer with a reason and let it go.
local function refuse(entry, reason)
    if entry.peer:state() == "connected" then
        send(entry.peer, { t = "reject", reason = reason:sub(1, protocol.MAX_REASON) }, protocol.RELIABLE)
    end
    entry.peer:disconnect_later()
    entry.stage = "refused"
end

local function hostReceive(self, entry, data)
    local message, err = protocol.decode(data, protocol.MAX_CLIENT_MESSAGE)
    if not message then
        refuse(entry, "bad message: " .. err)
        return
    end
    if entry.stage == "hello" and message.t == "hello" then
        if message.protocol ~= self.protocol or message.game ~= self.game then
            refuse(entry, ("version mismatch: host runs %s, you run %s"):format(self.game, message.game))
            return
        end
        entry.stage = "ready"
        send(entry.peer, { t = "level", name = self.level.name, fingerprint = self.level.fingerprint },
            protocol.RELIABLE)
    elseif entry.stage == "ready" and message.t == "ready" then
        if message.fingerprint ~= self.level.fingerprint then
            refuse(entry, "your copy of level " .. self.level.name .. " differs from the host's")
            return
        end
        local id, reason = self.handler.accept()
        if not id then
            refuse(entry, reason or "session is full")
            return
        end
        entry.id, entry.stage = id, "joined"
        local info = self.handler.welcome(id)
        send(entry.peer, { t = "welcome", you = id, seed = info.seed, generation = info.generation,
            players = info.players }, protocol.RELIABLE)
        local full = self.handler.snapshot()
        if full then
            send(entry.peer, { t = "snapshot", generation = full.generation, data = full.data }, protocol.BULK)
        end
        self:broadcast({ t = "joined", id = id }, id)
    elseif entry.stage == "joined" and message.t == "vote" then
        self.handler.vote(entry.id, message.on)
    elseif entry.stage == "joined" and message.t == "state" then
        -- At most MAX_STATES a second; extras are dropped (newest wins anyway).
        local second = math.floor(now())
        if entry.second ~= second then
            entry.second, entry.states = second, 0
        end
        entry.states = entry.states + 1
        if entry.states <= MAX_STATES then
            self.handler.state(entry.id, message)
        end
    elseif message.t == "reject" then
        entry.peer:disconnect_later()
        entry.stage = "refused"
    else
        refuse(entry, "unexpected message " .. message.t)
    end
end

local function hostDisconnected(self, index)
    local entry = self.peers[index]
    self.peers[index] = nil
    if entry and entry.stage == "joined" then
        self.handler.left(entry.id)
        self:broadcast({ t = "left", id = entry.id })
    end
end

function Host:service()
    while self.enet do
        local ok, event = pcall(self.enet.service, self.enet, 0)
        if not ok or not event then
            break
        end
        local index = event.peer:index()
        if event.type == "connect" then
            setTimeout(event.peer)
            self.peers[index] = { peer = event.peer, stage = "hello", since = now() }
        elseif event.type == "receive" then
            local entry = self.peers[index]
            if entry and entry.stage ~= "refused" then
                hostReceive(self, entry, event.data)
            end
        elseif event.type == "disconnect" then
            hostDisconnected(self, index)
        end
    end
    for _, entry in pairs(self.peers) do -- empty once closed
        if (entry.stage == "hello" or entry.stage == "ready") and now() - entry.since > HANDSHAKE_SECONDS then
            refuse(entry, "handshake took too long")
        end
    end
end

-- Send a session message to every joined client (except player `exceptId`).
function Host:broadcast(message, exceptId)
    for _, entry in pairs(self.peers) do
        if entry.stage == "joined" and entry.id ~= exceptId then
            send(entry.peer, message, protocol.RELIABLE)
        end
    end
end

-- Send unreliable state (players) to every joined client: newest wins, so a
-- lost one is simply replaced by the next.
function Host:broadcastState(message)
    for _, entry in pairs(self.peers) do
        if entry.stage == "joined" then
            send(entry.peer, message, protocol.STATE)
        end
    end
end

-- Send a session message to the client playing player `id` (reliable).
function Host:sendTo(id, message)
    for _, entry in pairs(self.peers) do
        if entry.stage == "joined" and entry.id == id then
            send(entry.peer, message, protocol.RELIABLE)
            return true
        end
    end
    return false
end

-- The ids of the joined clients.
function Host:clientIds()
    local ids = {}
    for _, entry in pairs(self.peers) do
        if entry.stage == "joined" then
            ids[#ids + 1] = entry.id
        end
    end
    table.sort(ids)
    return ids
end

-- End the session: every client is told and disconnected.
function Host:close()
    if not self.enet then
        return
    end
    for _, entry in pairs(self.peers) do
        if entry.peer:state() == "connected" then
            send(entry.peer, { t = "reject", reason = "the host ended the session" }, protocol.RELIABLE)
            entry.peer:disconnect_later()
        end
    end
    self.enet:flush()
    self.enet:destroy()
    self.enet = nil
    self.peers = {}
end

-- ── Client ────────────────────────────────────────────────────────────────

local Client = {}
Client.__index = Client

-- Connect to a host. `address` is "ip" or "ip:port". handler:
--   level(name, fingerprint) -> true when this machine has that level (else
--                               false and a reason)
--   welcome(message)           joined: { you, seed, generation, players }
--   snapshot(message)          { generation, data }
--   restart(message)           { seed, generation, players }
--   joined(id), left(id)       another player came or went
--   players(message)           the other players' states { g, list }
--   setPlayer(message)         the host overrides this machine's player
--   closed(reason)             the session ended (refused, host gone, timeout)
-- Returns the client, or nil and an error.
function session.join(address, handler)
    local target = protocol.address(address)
    if not target then
        return nil, "invalid address: " .. tostring(address)
    end
    local enetHost = enet.host_create(nil, 1, protocol.CHANNELS)
    if not enetHost then
        return nil, "could not open a network socket"
    end
    local ok, peer = pcall(enetHost.connect, enetHost, target, protocol.CHANNELS)
    if not ok or not peer then
        enetHost:destroy()
        return nil, "could not reach " .. target
    end
    setTimeout(peer)
    return setmetatable({
        enet = enetHost,
        peer = peer,
        handler = handler,
        stage = "connecting", -- "connecting" | "hello" | "ready" | "joined" | "closed"
        since = now(),
        reason = nil,
    }, Client)
end

local function clientClose(self, reason)
    if self.stage == "closed" then
        return
    end
    self.stage = "closed"
    self.reason = self.reason or reason
    if self.peer:state() ~= "disconnected" then
        self.peer:disconnect_later()
    end
    self.handler.closed(self.reason)
end

local CLIENT_EXPECTS = {
    hello = { level = true },
    ready = { welcome = true },
    joined = { snapshot = true, restart = true, joined = true, left = true, players = true, setPlayer = true },
}

local function clientReceive(self, data)
    local message, err = protocol.decode(data, protocol.MAX_HOST_MESSAGE)
    if not message then
        clientClose(self, "the host sent a bad message: " .. err)
        return
    end
    if message.t == "reject" then
        self.reason = message.reason
        clientClose(self, message.reason)
        return
    end
    if not (CLIENT_EXPECTS[self.stage] or {})[message.t] then
        clientClose(self, "the host sent an unexpected message: " .. message.t)
        return
    end
    if message.t == "level" then
        local ok, reason = self.handler.level(message.name, message.fingerprint)
        if not ok then
            send(self.peer, { t = "reject", reason = reason or "level not available" }, protocol.RELIABLE)
            clientClose(self, reason or "level not available")
            return
        end
        self.stage = "ready"
        send(self.peer, { t = "ready", fingerprint = message.fingerprint }, protocol.RELIABLE)
    elseif message.t == "welcome" then
        self.stage = "joined"
        self.handler.welcome(message)
    elseif message.t == "joined" or message.t == "left" then
        self.handler[message.t](message.id)
    else
        self.handler[message.t](message) -- snapshot, restart, players, setPlayer
    end
end

function Client:service()
    while self.enet and self.stage ~= "closed" do
        local ok, event = pcall(self.enet.service, self.enet, 0)
        if not ok or not event then
            break
        end
        if event.type == "connect" then
            self.stage = "hello"
            send(self.peer, { t = "hello", protocol = version.PROTOCOL, game = version.GAME }, protocol.RELIABLE)
        elseif event.type == "receive" then
            clientReceive(self, event.data)
        elseif event.type == "disconnect" then
            clientClose(self, self.stage == "connecting" and "could not connect to the host"
                or "lost the connection to the host")
        end
    end
    if self.stage ~= "joined" and self.stage ~= "closed" and now() - self.since > HANDSHAKE_SECONDS + 1 then
        clientClose(self, "could not connect to the host")
    end
end

-- Tell the host this player's restart vote.
function Client:vote(on)
    if self.stage == "joined" then
        send(self.peer, { t = "vote", on = on == true }, protocol.RELIABLE)
    end
end

-- Send this machine's player state { g, s, a, p, e } (unreliable).
function Client:sendState(message)
    if self.stage == "joined" then
        send(self.peer, message, protocol.STATE)
    end
end

-- Leave the session.
function Client:close()
    if not self.enet then
        return
    end
    if self.stage ~= "closed" then
        self.stage = "closed"
        self.peer:disconnect_now()
    end
    self.enet:flush()
    self.enet:destroy()
    self.enet = nil
end

return session
