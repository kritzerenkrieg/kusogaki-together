-- Network sessions over ENet: the host side (accepts up to 4 clients, runs the
-- join handshake, sends session messages) and the client side (connects,
-- answers the handshake, receives what the host sends). Game logic stays in
-- the caller: both sides report through a handler table and never touch the
-- level themselves. See core/net/protocol.lua for the messages and
-- NETWORKING.md (Session flow, Source of truth).
--
-- Both sides call `service()` once per frame; it handles everything that
-- arrived and returns at once.
--
-- Internet play (Phase 3): with `rendezvous` options the host opens a room
-- on our server and punches toward each client the server announces; a
-- client joins by room code and tries every address the server gives (the
-- host's public and LAN addresses, later the relay), keeping the first
-- connection. Connections nobody asked for (made by punching) are reset.
-- See core/net/rendezvous.lua and NETWORKING.md (Connectivity).
local enet = require("enet")
local protocol = require("core.net.protocol")
local rendezvous = require("core.net.rendezvous")
local version = require("core.version")

local session = {}

local MAX_CLIENTS = protocol.MAX_PLAYERS - 1
local TIMEOUT_MS = 5000      -- a peer silent this long is dropped (OPEN_DECISION C3)
local HANDSHAKE_SECONDS = 5  -- a client must finish the handshake within this
local MAX_INPUTS = 120       -- input messages a client may send per second (60 expected)
local SPARE_PEERS = 16       -- ENet peers for probes and punches

local function now()
    return love.timer.getTime()
end

-- ENet drops a peer after it stops acknowledging for TIMEOUT_MS.
local function setTimeout(peer)
    peer:timeout(32, TIMEOUT_MS, TIMEOUT_MS)
end

-- ── Bad network simulator (`--net-lag <ms> --net-loss <%>`) ─────────────
-- Adds `lag` seconds of round trip to this machine's connection (half on
-- the way out, half on the way in) and loses `loss` of its unreliable
-- messages both ways; a reliable message is never lost, but with chance
-- `loss` it is late by another round trip (ENet resending it), still in order.
local emulation = { lag = 0, loss = 0 }
local outbox = {} -- { peer, data, channel, flag, due }, in due order per peer
local lastDue = setmetatable({}, { __mode = "k" }) -- peer -> due of its last reliable message

function session.emulate(lagSeconds, lossFraction)
    emulation.lag = math.max(0, lagSeconds or 0)
    emulation.loss = math.min(math.max(lossFraction or 0, 0), 1)
end

local function emulating()
    return emulation.lag > 0 or emulation.loss > 0
end

local function lost()
    return emulation.loss > 0 and love.math.random() < emulation.loss
end

local function rawSend(peer, data, channel, flag)
    pcall(peer.send, peer, data, channel, flag) -- a peer gone meanwhile is fine
end

-- Send what is due (all of it when `all`).
local function flushOutbox(all)
    local waiting = {}
    for _, entry in ipairs(outbox) do
        if all or entry.due <= now() then
            rawSend(entry.peer, entry.data, entry.channel, entry.flag)
        else
            waiting[#waiting + 1] = entry
        end
    end
    outbox = waiting
end

local function send(peer, message, channel)
    local flag = channel == protocol.STATE and "unsequenced" or "reliable"
    local data = protocol.encode(message)
    if not emulating() then
        peer:send(data, channel, flag)
        return
    end
    local due = now() + emulation.lag / 2
    if flag == "unsequenced" then
        if lost() then
            return
        end
    else
        if lost() then
            due = due + math.max(emulation.lag, 0.05) -- resent after a round trip
        end
        due = math.max(due, lastDue[peer] or 0) -- reliable stays in order
        lastDue[peer] = due
    end
    outbox[#outbox + 1] = { peer = peer, data = data, channel = channel, flag = flag, due = due }
end

-- The next ENet event for `self` (a Host or Client), through the simulator.
local function nextEvent(self)
    if not emulating() and #self.inbox == 0 then
        local ok, event = pcall(self.enet.service, self.enet, 0)
        return ok and event or nil
    end
    while true do
        local ok, event = pcall(self.enet.service, self.enet, 0)
        if not ok or not event then
            break
        end
        if not (event.type == "receive" and event.channel == protocol.STATE and lost()) then
            self.inbox[#self.inbox + 1] = { event = event, due = now() + emulation.lag / 2 }
        end
    end
    local first = self.inbox[1]
    if first and first.due <= now() then
        table.remove(self.inbox, 1)
        return first.event
    end
    return nil
end

-- ── Host ──────────────────────────────────────────────────────────────────

local Host = {}
Host.__index = Host

-- Open a session. options:
--   port      UDP port (default protocol.PORT); bind address options.bind (default "*")
--   rendezvous  { server = "host[:port]", relayOnly } to open an internet room
--             (its code: host:room(); its listing: host:setRoomInfo())
--   handler   the game's side:
--     accept()            -> a free player id, or nil and a reason (session
--                            full, game started)
--     welcome(id, name)   that client is in the room (it got its id)
--     has(id, fp)         its fingerprint of the room's level ("" without it)
--     left(id)            a joined client left or timed out
--     vote(id, on)        a joined client's player toggled its restart vote
--     input(id, message)  a joined client's inputs (core/net/inputsync.lua)
-- Returns the host, or nil and an error (port in use).
function session.host(options)
    local address = (options.bind or "*") .. ":" .. (options.port or protocol.PORT)
    local ok, enetHost = pcall(enet.host_create, address, MAX_CLIENTS + SPARE_PEERS, protocol.CHANNELS)
    if not ok or not enetHost then
        return nil, "could not open port " .. (options.port or protocol.PORT)
    end
    local room
    if options.rendezvous then
        local err
        room, err = rendezvous.host({
            server = options.rendezvous.server, relayOnly = options.rendezvous.relayOnly,
            protocol = version.PROTOCOL, enet = enetHost,
        })
        if not room then
            enetHost:destroy()
            return nil, err
        end
    end
    return setmetatable({
        enet = enetHost,
        rendezvous = room,
        punches = {}, -- peer index -> true: connect attempts that only open this machine's router
        handler = options.handler,
        game = version.GAME, -- versions this host plays (fixed when it opens)
        protocol = version.PROTOCOL,
        peers = {}, -- peer index -> { peer, stage = "hello" | "joined" | "refused", id, since }
        inbox = {}, -- events held back by the bad network simulator
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
        local id, reason = self.handler.accept()
        if not id then
            refuse(entry, reason or "session is full")
            return
        end
        entry.id, entry.stage = id, "joined"
        send(entry.peer, { t = "welcome", you = id }, protocol.RELIABLE)
        self.handler.welcome(id, message.name)
    elseif entry.stage == "joined" and message.t == "has" then
        self.handler.has(entry.id, message.fp)
    elseif entry.stage == "joined" and message.t == "vote" then
        self.handler.vote(entry.id, message.on)
    elseif entry.stage == "joined" and message.t == "input" then
        -- At most MAX_INPUTS a second; extras are dropped (each repeats the last ticks).
        local second = math.floor(now())
        if entry.second ~= second then
            entry.second, entry.inputs = second, 0
        end
        entry.inputs = entry.inputs + 1
        if entry.inputs <= MAX_INPUTS then
            self.handler.input(entry.id, message)
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

-- A connect attempt toward `address` that only opens this machine's router
-- for the packets coming back (hole punching); `data` is a relay token.
function Host:punch(address, data)
    local ok, peer = pcall(self.enet.connect, self.enet, address, protocol.CHANNELS, data)
    if ok and peer then
        setTimeout(peer)
        self.punches[peer:index()] = true
    end
end

function Host:service()
    flushOutbox()
    if self.rendezvous then
        for _, action in ipairs(self.rendezvous:update(now())) do
            self:punch(action.address, action.data)
        end
    end
    while self.enet do
        local event = nextEvent(self)
        if not event then
            break
        end
        local index = event.peer:index()
        if self.punches[index] then
            -- A punch that connected (the other side answered it) or gave up:
            -- not a client. The client's own connection arrives separately.
            if event.type ~= "receive" then
                self.punches[index] = nil
                if event.type == "connect" then
                    event.peer:reset()
                end
            end
        elseif event.type == "connect" then
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
        if entry.stage == "hello" and now() - entry.since > HANDSHAKE_SECONDS then
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

-- Send a message to the client playing player `id`: reliable, or unreliable
-- state when `unreliable` is true.
function Host:sendTo(id, message, unreliable)
    for _, entry in pairs(self.peers) do
        if entry.stage == "joined" and entry.id == id then
            send(entry.peer, message, unreliable and protocol.STATE or protocol.RELIABLE)
            return true
        end
    end
    return false
end

-- Refuse the client playing player `id` with a reason and let it go.
function Host:kick(id, reason)
    for _, entry in pairs(self.peers) do
        if entry.stage == "joined" and entry.id == id then
            refuse(entry, reason)
            self.handler.left(id)
            self:broadcast({ t = "left", id = id })
            return true
        end
    end
    return false
end

-- What the server's room list shows about this room (rendezvous Host:setInfo).
function Host:setRoomInfo(info)
    if self.rendezvous then
        self.rendezvous:setInfo(info)
    end
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

-- The internet room: its code (nil until the server gave one) and state
-- ("opening" | "open" | "failed" with a reason), or nil without one.
function Host:room()
    local room = self.rendezvous
    if not room then
        return nil
    end
    return room.code, room.state, room.error
end

-- End the session: every client is told and disconnected.
function Host:close()
    if not self.enet then
        return
    end
    if self.rendezvous then
        self.rendezvous:close()
    end
    for _, entry in pairs(self.peers) do
        if entry.peer:state() == "connected" then
            send(entry.peer, { t = "reject", reason = "the host ended the session" }, protocol.RELIABLE)
            entry.peer:disconnect_later()
        end
    end
    flushOutbox(true)
    self.enet:flush()
    self.enet:destroy()
    self.enet = nil
    self.peers = {}
end

-- ── Client ────────────────────────────────────────────────────────────────

local Client = {}
Client.__index = Client

-- Connect to a host. `address` is "ip" or "ip:port", or nil with
-- options.rendezvous = { server, code } to join an internet room.
-- options.name is the player's name. handler:
--   welcome(message)           in the room: { you }
--   room(message)              the waiting room's state (core/net/protocol.lua)
--   start(message)             play a level: { level, fp, seed, generation, players }
--   toroom(message)            back to the waiting room
--   restart(message)           { seed, generation, players }
--   joined(id), left(id)       another player came or went
--   snap(message)              the host's state (core/net/statesync.lua)
--   ahead(message)             the others' inputs (optional; inputsync.forward)
--   closed(reason)             the session ended (refused, host gone, timeout)
-- Returns the client, or nil and an error.
function session.join(address, handler, options)
    options = options or {}
    local target
    if not options.rendezvous then
        target = protocol.address(address)
        if not target then
            return nil, "invalid address: " .. tostring(address)
        end
    end
    local enetHost = enet.host_create(nil, SPARE_PEERS, protocol.CHANNELS)
    if not enetHost then
        return nil, "could not open a network socket"
    end
    local self = setmetatable({
        enet = enetHost,
        peer = nil,      -- the connection to the host, once one is made
        attempts = {},   -- peer index -> peer: connections being tried
        handler = handler,
        name = options.name or "",
        stage = "connecting", -- "connecting" | "hello" | "joined" | "closed"
        inbox = {},
        since = now(),
        reason = nil,
    }, Client)
    if options.rendezvous then
        local err
        self.rendezvous, err = rendezvous.join({
            server = options.rendezvous.server, code = options.rendezvous.code,
            protocol = version.PROTOCOL, enet = enetHost,
        })
        if not self.rendezvous then
            enetHost:destroy()
            return nil, err
        end
    elseif not self:try(target, 0) then
        enetHost:destroy()
        return nil, "could not reach " .. target
    end
    return self
end

-- Try connecting to `address` as well (`data`: a relay token).
function Client:try(address, data)
    local ok, peer = pcall(self.enet.connect, self.enet, address, protocol.CHANNELS, data)
    if not ok or not peer then
        return false
    end
    setTimeout(peer)
    self.attempts[peer:index()] = peer
    self.since = now()
    return true
end

local function clientClose(self, reason)
    if self.stage == "closed" then
        return
    end
    self.stage = "closed"
    self.reason = self.reason or reason
    if self.peer and self.peer:state() ~= "disconnected" then
        self.peer:disconnect_later()
    end
    for _, peer in pairs(self.attempts) do
        pcall(peer.reset, peer)
    end
    self.attempts = {}
    if self.rendezvous then
        self.rendezvous:close()
    end
    self.handler.closed(self.reason)
end

local CLIENT_EXPECTS = {
    hello = { welcome = true },
    joined = { room = true, start = true, toroom = true, restart = true, joined = true, left = true,
        snap = true, ahead = true },
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
    if message.t == "welcome" then
        self.stage = "joined"
        self.handler.welcome(message)
    elseif message.t == "joined" or message.t == "left" then
        self.handler[message.t](message.id)
    elseif self.handler[message.t] then
        self.handler[message.t](message) -- room, start, toroom, restart, snap, ahead
    end
end

-- Still waiting for the server to say where to connect?
function Client:waiting()
    return self.rendezvous ~= nil and self.rendezvous:pending()
end

function Client:service()
    flushOutbox()
    local room = self.rendezvous
    if room and self.stage ~= "closed" then
        for _, action in ipairs(room:update(now(), self.peer ~= nil)) do
            self:try(action.address, action.data)
        end
        if room.state == "failed" then
            clientClose(self, room.error)
        elseif room.state == "done" then
            self.rendezvous = nil
        end
    end
    while self.enet and self.stage ~= "closed" do
        local event = nextEvent(self)
        if not event then
            break
        end
        local index = event.peer:index()
        if not self.peer then
            if event.type == "connect" and self.attempts[index] then
                -- The first connection wins; the other attempts stop.
                self.peer, self.attempts[index] = event.peer, nil
                for _, peer in pairs(self.attempts) do
                    pcall(peer.reset, peer)
                end
                self.attempts = {}
                self.stage, self.since = "hello", now()
                send(self.peer, { t = "hello", protocol = version.PROTOCOL, game = version.GAME, name = self.name },
                    protocol.RELIABLE)
            elseif event.type == "connect" then
                event.peer:reset() -- the host's punch got through: not our connection
            elseif event.type == "disconnect" and self.attempts[index] then
                self.attempts[index] = nil
                if next(self.attempts) == nil and not self:waiting() then
                    clientClose(self, "could not connect to the host")
                end
            end
        elseif index == self.peer:index() then
            if event.type == "receive" then
                clientReceive(self, event.data)
            elseif event.type == "disconnect" then
                clientClose(self, "lost the connection to the host")
            end
        elseif event.type == "connect" then
            event.peer:reset()
        end
    end
    if self.stage ~= "joined" and self.stage ~= "closed" and not self:waiting()
        and now() - self.since > HANDSHAKE_SECONDS + 1 then
        clientClose(self, "could not connect to the host")
    end
end

-- Tell the host the fingerprint of this machine's copy of the room's level
-- ("" without one).
function Client:has(fp)
    if self.stage == "joined" then
        send(self.peer, { t = "has", fp = fp }, protocol.RELIABLE)
    end
end

-- Tell the host this player's restart vote.
function Client:vote(on)
    if self.stage == "joined" then
        send(self.peer, { t = "vote", on = on == true }, protocol.RELIABLE)
    end
end

-- Send this machine's inputs { g, n, f, k } (unreliable; each repeats the
-- last ticks).
function Client:sendInput(message)
    if self.stage == "joined" then
        send(self.peer, message, protocol.STATE)
    end
end

-- Round trip to the host in seconds (ENet's estimate).
function Client:roundTrip()
    if not self.peer then
        return 0.1 + emulation.lag
    end
    local ok, ms = pcall(self.peer.round_trip_time, self.peer)
    return (ok and tonumber(ms) or 100) / 1000 + emulation.lag
end

-- Leave the session.
function Client:close()
    if not self.enet then
        return
    end
    flushOutbox(true)
    if self.stage ~= "closed" then
        self.stage = "closed"
        if self.peer then
            self.peer:disconnect_now()
        end
        for _, peer in pairs(self.attempts) do
            pcall(peer.reset, peer)
        end
    end
    if self.rendezvous then
        self.rendezvous:close()
        self.rendezvous = nil
    end
    self.enet:flush()
    self.enet:destroy()
    self.enet = nil
end

return session
