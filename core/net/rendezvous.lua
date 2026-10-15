-- The game's side of our rendezvous and relay server (`server/`,
-- NETWORKING.md Connectivity): open a room and learn who wants in (host),
-- or join one by its code and learn where to connect (client). Play stays
-- peer to peer; the server only introduces the machines and relays when
-- punching fails.
--
-- Control messages go over a luasocket UDP socket, one line "KG1 <verb> ..."
-- per datagram, resent until answered. Probes go over the game's own ENet
-- socket (a connect attempt carrying the probe token, reset unanswered), so
-- the server sees that socket's public address. Both sides call update(now)
-- every frame; it never blocks and returns what to do next:
--   host:   { address, data } connect attempts to punch (to a client or the relay)
--   client: { address, data } addresses to try connecting to
local socket = require("socket")

local rendezvous = {}

rendezvous.PORT = 26968
rendezvous.FALLBACK_SECONDS = 3 -- direct attempts before asking for the relay

local MAGIC = "KG1 "
local RESEND = 0.5         -- s between resends of an unanswered request
local POLL = 0.25          -- s between a host's polls
local PROBE_EVERY = 10     -- s between a host's probes (keeps its router mapping)
local PROBE_RESET = 1      -- s a probe attempt lives
local SERVER_SILENT = 6    -- s without any answer before giving up
local CHANNELS = 3

-- "host[:port]" -> ip, port (resolving a name once), or nil and a reason.
function rendezvous.resolve(text)
    if type(text) ~= "string" then
        return nil, "no server address"
    end
    local name, port = text:match("^([%w%.%-]+):(%d+)$")
    if not name then
        name, port = text:match("^([%w%.%-]+)$"), rendezvous.PORT
    end
    port = tonumber(port)
    if not name or not port or port < 1 or port > 65535 then
        return nil, "invalid server address: " .. text
    end
    local ip = name:match("^%d+%.%d+%.%d+%.%d+$") and name or socket.dns.toip(name)
    if not ip then
        return nil, "could not find the server " .. name
    end
    return ip, port
end

local Base = {}
Base.__index = Base

local function open(options)
    local ip, port = rendezvous.resolve(options.server)
    if not ip then
        return nil, port
    end
    local udp = socket.udp()
    if not udp or not udp:setpeername(ip, port) then
        return nil, "could not open a socket to the server"
    end
    udp:settimeout(0)
    local enetPort = tonumber(tostring(options.enet:get_socket_address()):match(":(%d+)$"))
    local lanIp = udp:getsockname()
    local self = setmetatable({
        udp = udp,
        enet = options.enet,
        serverIp = ip,
        server = ip .. ":" .. port,
        protocol = options.protocol,
        relayOnly = options.relayOnly and "1" or "0",
        lan = (lanIp and lanIp ~= "0.0.0.0" and enetPort) and (lanIp .. ":" .. enetPort) or "-",
        probeToken = love.math.random(1, 2 ^ 31 - 1),
        probes = {},     -- { peer, at }
        lastProbe = -math.huge,
        lastSent = -math.huge,
        lastHeard = nil, -- set at the first update
        state = nil,
        error = nil,
    }, options.class)
    return self
end

function Base:send(text)
    self.udp:send(MAGIC .. text)
end

-- Every reply waiting, as lists of lines split into fields.
function Base:replies()
    local list = {}
    while true do
        local data = self.udp:receive()
        if not data then
            break
        end
        if data:sub(1, #MAGIC) == MAGIC then
            local lines = {}
            for line in (data:sub(#MAGIC + 1) .. "\n"):gmatch("([^\n]*)\n") do
                local fields = {}
                for field in line:gmatch("%S+") do
                    fields[#fields + 1] = field
                end
                lines[#lines + 1] = fields
            end
            list[#list + 1] = lines
        end
    end
    return list
end

-- A connect attempt from the game socket to the server: it learns this
-- machine's public address from it. Never answered; reset after a moment.
function Base:probe(now)
    self.lastProbe = now
    local ok, peer = pcall(self.enet.connect, self.enet, self.server, CHANNELS, self.probeToken)
    if ok and peer then
        self.probes[#self.probes + 1] = { peer = peer, at = now }
    end
end

function Base:resetProbes(now, all)
    for i = #self.probes, 1, -1 do
        local probe = self.probes[i]
        if all or now - probe.at > PROBE_RESET then
            pcall(probe.peer.reset, probe.peer)
            table.remove(self.probes, i)
        end
    end
end

-- Due to (re)send a request?
function Base:due(now, every)
    if now - self.lastSent >= every then
        self.lastSent = now
        return true
    end
    return false
end

function Base:fail(reason)
    self.state, self.error = "failed", reason
end

function Base:silent(now)
    self.lastHeard = self.lastHeard or now
    return now - self.lastHeard > SERVER_SILENT
end

function Base:closeSocket(now)
    self:resetProbes(now or 0, true)
    if self.udp then
        self.udp:close()
        self.udp = nil
    end
end

-- ── Host ──────────────────────────────────────────────────────────────────

local Host = setmetatable({}, Base)
Host.__index = Host

-- options: server ("host[:port]"), protocol, relayOnly, enet (the session's
-- lua-enet host). Returns the room (state "opening", then "open" with
-- `code`; "failed" with `error`), or nil and a reason.
function rendezvous.host(options)
    local self, err = open(setmetatable({ class = Host }, { __index = options }))
    if not self then
        return nil, err
    end
    self.state = "opening"
    self.punched = {} -- "<id> join" / "<id> relay" -> true
    return self
end

function Host:update(now)
    local actions = {}
    if not self.udp then
        return actions
    end
    self:resetProbes(now)
    if now - self.lastProbe >= PROBE_EVERY then
        self:probe(now)
    end
    for _, lines in ipairs(self:replies()) do
        local head = lines[1]
        self.lastHeard = now
        if head[1] == "room" and self.state == "opening" then
            self.code, self.secret, self.state = head[2], head[3], "open"
        elseif head[1] == "hosted" then
            for i = 2, #lines do
                local line = lines[i]
                local key = (line[2] or "") .. " " .. (line[1] or "")
                if not self.punched[key] then
                    if line[1] == "join" and line[3] then
                        self.punched[key] = true
                        actions[#actions + 1] = { address = line[3], data = 0 }
                        if line[4] and line[4] ~= "-" and line[4] ~= line[3] then
                            actions[#actions + 1] = { address = line[4], data = 0 }
                        end
                    elseif line[1] == "relay" and tonumber(line[3]) and tonumber(line[4]) then
                        self.punched[key] = true
                        actions[#actions + 1] = { address = self.serverIp .. ":" .. line[3], data = tonumber(line[4]) }
                    end
                end
            end
        elseif head[1] == "error" then
            self:fail(table.concat(head, " ", 2))
        end
    end
    if self.state == "opening" then
        if self:due(now, RESEND) then
            self:send(("open %d %d %s %s"):format(self.protocol, self.probeToken, self.lan, self.relayOnly))
        end
    elseif self.state == "open" and self:due(now, POLL) then
        self:send(("poll %s %s"):format(self.code, self.secret))
    end
    if self.state ~= "failed" and self:silent(now) then
        self:fail(self.state == "opening" and "could not reach the server" or "lost the server")
    end
    return actions
end

-- Close the room (the server forgets it at once).
function Host:close()
    if self.udp and self.code then
        self:send(("close %s %s"):format(self.code, self.secret))
    end
    self:closeSocket()
    self.state = "closed"
end

-- ── Client ────────────────────────────────────────────────────────────────

local Client = setmetatable({}, Base)
Client.__index = Client

-- options: server, code, protocol, relayOnly, enet. State: "joining" ->
-- "waiting" -> "direct" (trying the host's addresses; the relay after
-- FALLBACK_SECONDS) or "relayed" -> "done" once connected; "failed" with
-- `error`.
function rendezvous.join(options)
    if type(options.code) ~= "string" or not options.code:match("^%d%d%d%d%d%d$") then
        return nil, "a room code is 6 digits"
    end
    local self, err = open(setmetatable({ class = Client }, { __index = options }))
    if not self then
        return nil, err
    end
    self.code = options.code
    self.state = "joining"
    return self
end

-- connected: the session has a connection (stop and tell the server).
function Client:update(now, connected)
    local actions = {}
    if not self.udp then
        return actions
    end
    self:resetProbes(now)
    if connected then
        if self.id then
            self:send(("done %s %s"):format(self.id, self.secret))
        end
        self.state = "done"
        self:closeSocket(now)
        return actions
    end
    for _, lines in ipairs(self:replies()) do
        local head = lines[1]
        self.lastHeard = now
        if head[1] == "joining" and self.state == "joining" then
            self.id, self.secret, self.state = head[2], head[3], "waiting"
            self.lastSent = -math.huge
        elseif head[1] == "direct" and self.state == "waiting" then
            self.state, self.directAt = "direct", now
            actions[#actions + 1] = { address = head[2], data = 0 }
            if head[3] and head[3] ~= "-" and head[3] ~= head[2] then
                actions[#actions + 1] = { address = head[3], data = 0 }
            end
        elseif head[1] == "relay" and (self.state == "waiting" or self.state == "direct")
            and tonumber(head[2]) and tonumber(head[3]) then
            self.state = "relayed"
            actions[#actions + 1] = { address = self.serverIp .. ":" .. head[2], data = tonumber(head[3]) }
        elseif head[1] == "error" then
            self:fail(table.concat(head, " ", 2))
        end
    end
    if self.state == "joining" then
        if now - self.lastProbe >= RESEND * 2 then
            self:probe(now)
        end
        if self:due(now, RESEND) then
            self:send(("join %s %d %d %s %s"):format(self.code, self.protocol, self.probeToken, self.lan, self.relayOnly))
        end
    elseif self.state == "waiting" then
        if now - self.lastProbe >= RESEND * 2 then
            self:probe(now) -- in case the first was lost
        end
        if self:due(now, POLL) then
            self:send(("status %s %s"):format(self.id, self.secret))
        end
    elseif self.state == "direct" and now - self.directAt >= rendezvous.FALLBACK_SECONDS then
        if self:due(now, RESEND) then
            self:send(("relay %s %s"):format(self.id, self.secret))
        end
    else
        self.lastHeard = now -- connecting: the server has nothing more to say
    end
    if self.state ~= "failed" and self:silent(now) then
        self:fail("could not reach the server")
    end
    return actions
end

-- Waiting for the server (more addresses may come)?
function Client:pending()
    return self.state == "joining" or self.state == "waiting" or self.state == "direct"
end

function Client:close()
    self:closeSocket()
    if self.state ~= "failed" then
        self.state = "closed"
    end
end

return rendezvous
