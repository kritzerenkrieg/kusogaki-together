# Kusogaki Together: public server

The server side of Kusogaki Together, kept in the game's repository but separate from the game: its own Go module (`kusogaki-together/server`), its own tests, its own deployment. The game never imports it; the two talk only over the network.

**The game stays peer to peer.** No server here ever runs a level. The host is always a player's machine, which simulates the game for everyone (`../NETWORKING.md`, Netcode). This server only helps machines find each other, relays packets when they cannot reach each other directly, and (later) stores levels.

Last updated: 2026-10-15.

---

## Modules

| Module | What it does | Phase | Status |
|---|---|---|---|
| [`lobby/`](lobby/README.md) | Rooms with 6-digit codes, the public room list, the control channel, probes (public address discovery), introductions for hole punching. | 3 (codes), 5 (public list) | **Built** (codes) |
| [`relay/`](relay/README.md) | Copies datagrams between a client and a host that could not connect directly, or whose host chose Relay only. | 3 | **Built** |
| [`repository/`](repository/README.md) | Accounts, level uploads (validation, asset normalization, headless load test), storage and download. | 4 | Design only |
| `cmd/kusogaki-server/` | The binary: one UDP port for the lobby, a port range for the relay. | 3 | **Built** |

Deployment: [`DEPLOYMENT.md`](DEPLOYMENT.md).

```text
server/
  README.md               this file
  DEPLOYMENT.md           running it on a VPS
  go.mod                  module kusogaki-together/server (Go 1.24, standard library only)
  cmd/kusogaki-server/    main.go: flags, the UDP loop, sweeping expired state
  lobby/                  lobby.go (rooms, control channel, probes), lobby_test.go, README.md
  relay/                  relay.go (port pairs, rate caps), enet.go (reading ENet connect packets),
                          relay_test.go, README.md
  repository/             README.md (Phase 4 design)
```

---

## Running it

```sh
cd server
go run ./cmd/kusogaki-server -addr :26968 -relay-ports 27000-27999
```

| Flag | Default | Meaning |
|---|---|---|
| `-addr` | `:26968` | UDP address for the lobby: control messages and probes share it |
| `-relay-ports` | `27000-27999` | UDP port range for relay pairs; two ports per relayed player |

In the game, set **Server** in Multiplayer to this machine's address (`host` or `host:port`; the port defaults to 26968). For a test on one PC: `127.0.0.1`.

## Tests

```sh
cd server && go vet ./... && go test -race ./...
```

`sh tests/run.sh` (from the repository root) also runs them, then builds the binary, starts it on `127.0.0.1:26988` and runs the game's online checks against it (`tests/sim/online.lua`: rooms, joining by code, direct, relay only, fallback to the relay, wrong code, other protocol, closed room, the lobby screen).

---

## Rules for everything in here

- **Never runs the game** and never sees game state: the relay copies datagrams without reading them (except ENet connect packets, for their token).
- **Logs no IP addresses.** Logs say what happened to rooms ("room 123456 opened", "relay 27000/27001 for room 123456"), never who. Addresses live in memory only while a room is open (`../PRIVACY.md`).
- **Everything that arrives is untrusted:** fixed message shapes, length limits, rate limits per address, tokens for every relay end.
- **Small and boring:** standard library only, one binary, no database until the repository needs one.
- **Versioned on the wire:** control messages start with `KG1`; a change that older games cannot read gets `KG2`. The game's own protocol number travels in `open` and `join`, and the lobby refuses a join whose protocol differs from the room's.

## How it fits with the game's docs

| Topic | Where |
|---|---|
| Netcode, sessions, what the host sends | `../NETWORKING.md` |
| How the game talks to the lobby and relay | `../NETWORKING.md` Connectivity, `../core/net/rendezvous.lua` |
| Decisions (rendezvous + relay, codes, room list, no encryption, Relay only) | `../OPEN_DECISION.md` |
| Progress | `../DEVELOPMENT_PHASE.md` |
| What the server sees about players | `../PRIVACY.md` |
