# Deployment

How to run the public server (`kusogaki-server`: lobby + relay) on a VPS. Phase 3 needs only this one binary; the repository (Phase 4) will add a database, object storage and HTTPS (below).

Last updated: 2026-10-15. **Deployed** on 2026-10-15 at `103.150.92.215` (Ubuntu 22.04, x86-64; a shared VPS that also runs other services, so steps 2 and 3 only added to it): systemd unit and `kusogaki` user as below, ufw rules `26968/udp` and `27000:27999/udp` added. No domain yet.

---

## What it needs

| | Phase 3 (lobby + relay) |
|---|---|
| Machine | 1 vCPU, 512 MB RAM is plenty; any Linux x86-64 or arm64 |
| Network | a **public IPv4 address** (no NAT in front of the server), IPv6 not needed (`../OPEN_DECISION.md`, F8) |
| Traffic | lobby: a few hundred bytes per join; relay: about 15 KB/s each way per relayed player (`relay/README.md`). 100 relayed players at once ≈ 1.5 MB/s ≈ 12 Mbit/s each way |
| Ports (UDP, inbound) | `26968` (lobby) and `27000-27999` (relay pairs) |
| Disk | the binary (~3 MB) and logs |
| Region | one, close to most players (`../OPEN_DECISION.md`, F4) |

No database, no TLS certificate and no domain name are required for Phase 3; a domain is still nicer for players to type and lets the server move without changing everyone's setting.

## 1. Build

On any machine with Go 1.24 (cross-compiling; the binary is static, standard library only):

```sh
cd server
go test ./...
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o kusogaki-server ./cmd/kusogaki-server
# arm64 VPS: GOARCH=arm64
```

## 2. Install

On the VPS, as root:

```sh
useradd --system --no-create-home --shell /usr/sbin/nologin kusogaki
install -o root -g root -m 0755 kusogaki-server /usr/local/bin/kusogaki-server
```

`/etc/systemd/system/kusogaki-server.service`:

```ini
[Unit]
Description=Kusogaki Together lobby and relay
After=network-online.target
Wants=network-online.target

[Service]
User=kusogaki
ExecStart=/usr/local/bin/kusogaki-server -addr :26968 -relay-ports 27000-27999
Restart=always
RestartSec=2
# Hardening: no files to write, no privileges, ports above 1024
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_UNIX
MemoryMax=256M
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
```

```sh
systemctl daemon-reload
systemctl enable --now kusogaki-server
systemctl status kusogaki-server
```

`LimitNOFILE`: every relay pair holds two sockets; 1000 ports = 1000 sockets plus the lobby's.

## 3. Firewall

Open only what the server uses (plus SSH). With `ufw`:

```sh
ufw allow OpenSSH
ufw allow 26968/udp
ufw allow 27000:27999/udp
ufw enable
```

The VPS provider's own firewall (security group) needs the same UDP rules.

## 4. Name (optional)

Point an `A` record (for example `play.<your domain>`) at the VPS's IPv4 address. Players type that name in **Server**; the game resolves it once when connecting.

## 5. Check it

From your own machine:

1. Multiplayer with Server set to the VPS, then Create room; the waiting room shows the room ID.
2. Multiplayer from a machine on **another network** (a phone hotspot is the easiest): the room is in the list; join it.
3. Try again with a room created with **Relay only** on (the list says "relayed").
4. On the VPS: `journalctl -u kusogaki-server -f` shows "room … opened", "relay … for room …", "room … closed".

Before that, from any machine with LÖVE: `KUSOGAKI_SERVER=<vps address> love . --sim-test` runs the online checks against the deployed server (rooms, codes, direct, relay only, fallback to the relay). Both test sides run on that one machine, so their direct path is the LAN; it proves the server is reachable and the relay ports are open, not hole punching.

That is also the Phase 3 internet test (`../DEVELOPMENT_PHASE.md`): hole punching cannot be tested inside one LAN.

## Updating

```sh
install -m 0755 kusogaki-server /usr/local/bin/kusogaki-server
systemctl restart kusogaki-server
```

A restart forgets every room and closes every relay pair: hosts see "Room: lost the server", games connected directly keep playing, and relayed games are cut. Restart when few people play. When the control messages change incompatibly, the version in them goes from `KG1` to `KG2`; run the old and new servers side by side on different ports until old games are gone.

## Logs and privacy

- The server logs to stderr; systemd keeps it in the journal. It never logs IP addresses (`README.md`, Rules), only room codes and relay ports.
- Keep the journal short: `journalctl --vacuum-time=7d`, or set `MaxRetentionSec=7day` in `/etc/systemd/journald.conf`.
- `../PRIVACY.md` names the provider and region of this server: fill those in when it is deployed.

## Watching it

- `systemctl status kusogaki-server` (running, memory).
- The provider's bandwidth graph: relay traffic is the only thing that grows with players.
- If the relay range fills up, joins that need the relay get "the relay is full, try again later": widen `-relay-ports` (and the firewall rule).

---

## Later: the repository (Phase 4)

`repository/README.md` will need, on top of the above:

| What | Why |
|---|---|
| HTTPS (a domain and a certificate, for example from Let's Encrypt via a reverse proxy such as Caddy) | accounts and uploads; the game uses `lua-https` |
| Postgres | accounts, levels, versions, ratings, reports |
| S3-compatible object storage | level packages (`levels/<sha256>.zip`) |
| A sandboxed container runner | the headless load test of every upload (no network, CPU/memory/time limits) |
| Backups | Postgres and the bucket |

The lobby and relay can stay on their own small VPS; the repository can grow separately.
