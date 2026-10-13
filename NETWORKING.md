# Networking

Online play: the level repository, the public lobby and peer-to-peer sessions. This is the design; most of it is not implemented yet (see Roadmap). The engine and code rules are in `ARCHITECTURE.md`; the engine vision and the sandbox are in `TECHNICAL.md`.

Sessions hold up to **5 players** (1 host + 4 clients).

---

## Overview

```text
                   ┌──────────────── Backend (Go) ─────────────────┐
                   │ accounts · level repository · lobby (HTTPS)   │
                   │ UDP rendezvous (NAT punch) · UDP relay        │
                   │ Postgres (metadata) · S3 (level packages)     │
                   └──────▲──────────────────▲─────────────────────┘
               HTTPS/UDP  │                  │  HTTPS/UDP
                   ┌──────┴──────┐  ENet  ┌──┴──────────┐
                   │    Host     │◄──────►│  Client x4  │
                   │ full sim    │  UDP   │ inputs out  │
                   │ 60 Hz       │        │ snapshots in│
                   └─────────────┘        └─────────────┘
```

- **The backend** handles accounts, level packages, room listing, NAT traversal and relay. It never simulates gameplay.
- **The host** is the player who opened the room. It runs physics, rules, AI and all gameplay Lua at a fixed 60 Hz, and is the only authority on game state.
- **Clients** send inputs, predict their own player's movement, and draw everyone else from the host's snapshots.

### What gets synced

Nothing is synced by copying memory. Clients never receive Lua tables, closures or script state. The host sends only:
- **Snapshots:** a fixed, declared *net state* per body (position, velocity, a few flags).
- **Events:** one-off happenings (explosion here, this block broke, play this sound).

Gameplay Lua runs only on the host, so hidden script state (locals, upvalues) never needs syncing. Anything a client must see has to be a declared net field.

Lockstep and rollback (every peer runs the same simulation) are rejected. LuaJIT floats, `math.sin`/`math.atan2` and order-dependent pair resolution (`core/physics/collision.lua`) are not guaranteed bit-identical across machines, so peers would drift.

---

## Engine prerequisites

These must land before any networking code. Each is useful on its own, and together they also give local co-op.

### Fixed timestep (done)
- `scenes/gameplay.lua` runs `Level:update(1/60)` through `core/fixedstep.lua`: as many ticks as the elapsed time needs, at most 5 per frame.
- Drawing blends moving bodies between the last two ticks (`core/graphics/interp.lua`).
- `tests/sim_test.lua` (`love2d . --sim-test`) checks that the same inputs give the same state, and that frame timing doesn't change the simulation.
- Today raw `delta` reaches:
  - prop friction (`core/level/prop.lua`);
  - entity timers in `dodon`, `dokan` and `fake_box`;
  - `blocks.animate`;
  - level scripts.
- Only the player and `Entity:update` clamp it, to 1/30.

### N players (done for local play)
- `Level` has a `players` list; `level:addPlayer(player)` assigns ids 1–5 in join order. `level:update(dt)` steps every player; each reads its own `input` frame.
- Every rule loops over `players` in join order: hazards, block breaking (mark, then remove), enemy touches and stomps, triggers, blasts and falling out.
- **Physics:** players are solid to each other and stand on each other's heads (`oneway.playerPair` makes the higher one land); a sideways push is shared by mass.
- **Local co-op works:** up to 5 players on one machine (keyboard layouts and gamepads, `core/input.lua`). The camera follows the group; the HUD shows every player and edge arrows for those off screen.
- **Left for network play:** camera, HUD and shake/sound must follow the *local* player only; remote players' events get positional sound only.
- **Checkpoints** are per player (`player:setSpawn`). The flag and sound stay shared (first touch).

### Input frames (done)
- Frames are `{ left, right, jump, kick, hold }`, held state only; `core/player/controller.lua` reads `player.input` and nothing else.
- `core/input.lua` makes frames from keyboard layouts and gamepads. On the wire a frame is a tick number plus a 5-bit mask.
- Edge detection (`prevKeys`) stays inside the player, so a frame never carries "pressed" events.

### Stable IDs (done)
- **Entities:** `id` = the placement's index in `level.json` `entities`, set by the loader, so it is the same on every load and every machine. `id` and `kind` are reserved for the engine.
- **Players:** ids 1–5 in join order. Player ids and entity ids are separate namespaces; a message always says which one it means.
- **Static geometry** never changes, so it has no ids.
- `level.byId` holds every entity still in the level; `level:get(id)` looks one up.
- **Removal:** all removals go through `level:removeEntity(entity)`. It takes the entity out of its list (and `statics`), out of `byId`, and marks it `removed = true`. It is the one place that will emit the `removed` event.
- **References:** the simulation keeps object references (`player.carrying`, `block.brokenBy`, `kickHits`). The net schema writes them as ids when building a snapshot or event. `kickHits` is host-only and never sent.
- `tests/sim_test.lua` checks that ids match placements, stay the same across loads, and that `byId` matches the lists after full runs with 1–5 players.

### Net state vs view state (done)
`core/level/netstate.lua` lists what a snapshot sends. Anything not listed is host-only simulation state (enemy AI timers, `kickHits`, `contacts`) or local view state (`tileCache`, images).

| Kind | Net fields |
|---|---|
| player | `id, x, y, vx, vy, facing, onGround, jumping, dead`, `carrying` (entity id), and for the sprite: `state, animationTime, idleTime, kickAnimationTime, kickTime` |
| entity (base) | `id, x, y, vx, vy, facing, frameIndex, rotation, flash, held` |
| entity type extras | declared by the type script: `Type.netFields = { "lit" }` (plain values only); none needed in the example level yet |

- `netstate.snapshot(level, tick)` builds a full snapshot: players in join order, entities sorted by id.
- **Entity drawing is state-driven:** no type script overrides `draw`, so clients draw bodies with the base `Entity:draw` from net fields.
- `tests/sim_test.lua` checks that snapshots and events are plain data, and includes both in the determinism comparison. A full snapshot of the example level is ~5.6 KB as debug text; the binary form will be much smaller.
- **Host migration** would also need the host-only fields; that is a later phase.

### Event bus (done)
- Rules report events (`core/level/events.lua`) instead of calling `fx`, `audio` and `camera`; `core/graphics/present.lua` shows them after each tick. The event list is in `ARCHITECTURE.md` (Events).
- Local play presents events at once. In network play the host also sends them (`netstate.event`) on the reliable channel; a client resolves `id` to its own copy of the entity for images.
- Debris, corpses and explosion particles are cosmetic and stay local. Each machine randomizes them with `love.math.random`, as now.
- Still to add for network play: `restart{seed}` and positional sound for remote players' events.

### Seeded RNG (done)
- `mathx.newRandom(seed)` (`core/mathx.lua`) is a plain-Lua Lehmer generator (MINSTD, 48271): exact in doubles, so every machine and both interpreters produce the same numbers. `tests/sandbox_test.lua` checks it against the MINSTD reference value.
- Each level has one, `level.random`, seeded by `Level.load(root, { seed })`. Scripts get it as `random(m, n)`; their `math` copy has no `random`/`randomseed`.
- The scene picks a new seed per (re)start; in network play the host picks it and sends it in `restart`. `getState`/`setState` let a snapshot carry the generator for host migration later.
- Cosmetic effects (debris, shake) keep `love.math.random`; they stay local.

### Sandbox hardening (done)
- Read-only engine views, per-script library copies, instruction and memory limits on every script call, disable-on-error, and package-relative asset paths. Details and known gaps are in `TECHNICAL.md` (Sandbox); one check per rule in `tests/sandbox_test.lua`.

### Serialization (done)
- **`core/json.lua`** encodes and decodes, sorts object keys (same data, same text), limits nesting to 64, and keeps `null` in arrays as `json.null`.
- **`core/wire.lua`** is the binary format for net messages (`love.data.pack`): tagged values, compact lists, sorted keys, and a decoder that treats input as untrusted (length checks, depth and size limits, returns nil and an error instead of raising).
- **`netstate.pack`/`unpack`** turn a snapshot into lists in schema order, so field names are not sent: the example level's full snapshot (70 entities, 2 players) is 2.2 KB packed vs 8.8 KB generic. Delta snapshots and quantized positions (Phase 2) will cut this further. Events still use the generic form (they are few).

### Package loading (done)
- `core/level/loader.lua` loads from a package root: `levels/<name>` (bundled) or `online/<sha256>` (downloaded). Every path in a package, including tiles, scripts and assets, is relative to the root.
- `core/levelpack.lua` checks a downloaded zip's sha256, then mounts it read-only at `online/<sha256>` with `love.filesystem.mount`. Downloads never use the `levels/` prefix, so they cannot shadow bundled levels (LÖVE searches the save directory first).
- `tests/sim_test.lua` zips the example level, mounts it, checks that a wrong hash is refused, and checks that the packaged level plays exactly like the bundled one.

**Phase 0 is complete.** Run every suite with `sh tests/run.sh`.

---

## Level repository

### Package
```text
<level>.zip
├── level.json        format, spawn, size, background, static, entities, scripts
├── meta.json         name, author, format version, engine version, description, tags
├── entities/*.lua
├── scripts/*.lua
└── assets/           images, sounds, music
```

### Asset formats
Uploads may use common media types. The server normalizes them so every client gets something LÖVE 11.5 can load (verified: LÖVE 11.5 decodes png, jpg, wav, ogg and mp3; it does not decode gif or webp).

| Upload | Stored as | Notes |
|---|---|---|
| `png` | `png` | decode check |
| `jpg` / `jpeg` | `jpg` | decode check |
| `webp` | `png` | transcoded (Go `golang.org/x/image/webp`) |
| `gif`, single frame | `png` | transcoded |
| `gif`, animated | `png` spritesheet + `<name>.anim.json` | frames laid out horizontally; sidecar has frame count, frame size and per-frame delays, read by `Entity` animation |
| `wav`, `ogg`, `mp3` | unchanged | decode check, duration/size caps |

- The file type comes from the magic bytes and must match the extension.
- After normalization the server rewrites references in `level.json` and the scripts' asset names to the stored names. The package hash covers the normalized package, and the original upload is kept for re-processing.
- **Limits** (initial values, tune later):

| What | Limit |
|---|---|
| Package | 16 MB |
| Image | 2048×2048 px |
| GIF | 64 frames |
| Sound effect | 10 s |
| Music | 4 min / 10 MB per file |
| Lua | 200 KB total |

### Upload pipeline (`POST /levels`)
1. **Auth and rate limit.**
2. **Zip safety:**
   - total and per-file size caps, and a compression-ratio cap (zip bombs);
   - no absolute paths or `..`;
   - a file whitelist by folder.
3. **Validation:**
   - `level.json` against a JSON schema; names match `^[%w_]+$`, as the loader already requires.
   - Lua is text only (reject `\27Lua` bytecode) and within size limits.
4. **Asset normalization** (see the table above).
5. **Headless load test:**
   - runs in a container with no network and CPU/memory/time limits;
   - LÖVE with the hardened sandbox loads the level and steps 600 ticks with no input;
   - any error or limit hit rejects the upload with the message.
6. **Storage:**
   - the package goes to S3 at `levels/<sha256>.zip`;
   - a new immutable `level_versions` row goes into Postgres.

### Data (Postgres)
- `users(id, name, device_token_hash, created_at, banned)`
- `levels(id, author_id, title, description, tags, status, created_at)`, where status is listed, unlisted or hidden
- `level_versions(id, level_id, version, sha256, size, engine_version, created_at)`, immutable
- `ratings(user_id, level_id, value)`, `play_stats(level_id, plays, clears)`, `reports(id, level_id, user_id, reason, created_at, resolved)`

### API
- `GET /levels?q=&tag=&sort=` lists levels, `GET /levels/{id}` gives details and versions, `GET /levels/{id}/versions/{v}/download` redirects to the package.
- `POST /levels`, `POST /levels/{id}/versions`, `PATCH /levels/{id}` (title, description, tags, unlist).
- `POST /levels/{id}/rate`, `POST /levels/{id}/report`.

### Client side
- Downloads go to the save directory (`online/<sha256>.zip`). The client verifies them with `love.data.hash("sha256", …)` before mounting.
- Only levels with a verified hash from the repository are playable online.

### Moderation
- Reports past a threshold auto-hide a level until an admin reviews it.
- Authors can unlist. Versions are never edited, only superseded.

---

## Public lobby

- `POST /rooms` creates a room. It holds:
  - level id + version + sha256;
  - max players (2–5);
  - public or private (private rooms get a 6-character join code);
  - a display name.
- `GET /rooms` lists public rooms that aren't full, with level title, players and region/ping hint.
- `POST /rooms/{id}/join` (or `/rooms/join/{code}`) returns a session token plus what's needed for connectivity (below).
- **Liveness:**
  - The host heartbeats every 5 s with its player count. A room disappears after 15 s without a heartbeat.
  - Clients poll room state while waiting. LÖVE has no WebSocket, and polling is enough at lobby rates.
- **Before connecting:**
  - The client downloads and verifies the level.
  - The host checks the level hash and engine version in the ENet connect handshake, and rejects mismatches with a reason.

### HTTPS
- LÖVE 11.5 ships `socket` (luasocket) but no TLS module: `ssl` and `https` are not available.
- **Options:**
  - Bundle the native `lua-https` module (from the LÖVE project) per platform.
  - Move to LÖVE 12, which includes it.
- Plain HTTP is allowed only against a localhost dev server.
- Backend calls run off the main loop, in a `love.thread`, so the game never stalls on the network.

---

## Connectivity

1. **Hole punching:**
   1. On join, host and client each send a UDP packet with the session token to the rendezvous server, which records each one's public `ip:port`.
   2. The server sends each side the other's endpoint (public, plus LAN address for same-network play).
   3. Both sides send ENet connect attempts to each other for ~3 s.
2. **Relay fallback:**
   - If no direct connection is made, both connect to the backend UDP relay, which forwards datagrams by session token.
   - Relay use is shown in the room UI.
3. **ENet** (bundled with LÖVE 11 as `require "enet"`) with three channels:
   - `0` unreliable, sequenced: input frames and snapshots.
   - `1` reliable: events, join/leave, chat, restart.
   - `2` reliable: initial full state on join.

---

## Netcode

### Client → host
- One input frame per tick. Each packet carries the last ~8 frames, so a lost packet costs nothing.
- **Host side:**
  - The host keeps a 1–2 tick buffer per client.
  - If a frame is missing when needed, the client's last frame is repeated.
  - The host validates frames (tick range, rate). Anything else is ignored.

### Host → client
- Snapshots at 30 Hz on channel 0. Each snapshot is a delta against the last snapshot that client acked. A full snapshot is sent on join or after a long gap.
- Bodies are addressed by ID. `removed` comes as an event, so a missing body in a delta just means "unchanged".
- **Rough size:**
  - full snapshot: 5 players + ~150 bodies × ~20 B ≈ 3 KB;
  - typical delta: a few hundred bytes;
  - host upload stays well under 100 KB/s for 4 clients.

### Client presentation
- **Remote players and bodies** are drawn ~100 ms behind, interpolated between snapshots.
- **Own player is predicted:**
  - The client runs `player:update` locally against statics and the latest snapshot's props, and keeps its input history.
  - On each snapshot it rewinds to the acked tick and replays the unacked inputs.
  - Small errors (a few px) are smoothed; large ones snap.
- **The rule: clients predict movement, the host decides consequences.**
  - Kills, stomps, grabs, block breaks, detonations and checkpoints are applied only when the host's snapshot and events say so.
  - The client may play the local pose (kick swing, jump) at once.

### Session flow
- **Join:** full snapshot on channel 2, then deltas.
- **Late join:** allowed. The new player spawns at the level spawn.
- **Leave:** that player is removed for everyone. Anything it carried is dropped.
- **Restart:** the host only. It broadcasts `restart{seed}`; everyone rebuilds the level from the package and the host resends a full snapshot.
- **Host leaves:** in v1 the session ends with a message. Host migration comes later. It needs every simulation field in the net schema so a client can resume from the last full snapshot.

### Who runs what
| | Host | Client |
|---|---|---|
| physics, rules, enemies | yes | own player only (prediction) |
| entity type scripts | full | view mode: `load()` for images, base `draw` |
| level scripts | full | `drawHud` only, from net state the script declares |
| fx (debris, particles, shake, sounds) | from events | from events |

---

## Security and trust

- **Uploaded Lua runs on every host.** The sandbox is a guardrail, not a security boundary (`TECHNICAL.md`). So:
  - server-side checks plus the load test reject obvious abuse;
  - only hash-verified repository levels run online;
  - per-call instruction and memory limits stop runaway scripts;
  - running scripts in a separate process with no filesystem or network access is the long-term goal.
- **The host is trusted by its peers** (co-op), so there's no anti-cheat beyond host-side input validation.
- **Rate limits:** uploads, room creation, joins and reports are rate-limited per account and IP.
- **Accounts:** guest device tokens at first, stored hashed. OAuth can be added later.

---

## Roadmap

| Phase | Scope | Done when |
|---|---|---|
| 0 (done) | Engine prerequisites: fixed step, N players, input frames, IDs, net schema, events, seeded RNG, sandbox hardening, JSON encoder, package-root loader | The game plays the same at a fixed 60 Hz; a headless test feeds the same inputs twice and gets the same state hash |
| 1 | Local co-op, 2–5 players | Every level rule works with N players: stomps, carrying, throwing at each other, per-player checkpoints, blasts |
| 2 | LAN netcode, direct IP | 5 instances on one PC or a LAN play cleanly; still playable at 150 ms and 5% loss (emulated) |
| 3 | Backend: accounts + level repository | Upload → validate/normalize → browse → download → play an uploaded level, including gif/webp/mp3 assets |
| 4 | Lobby + NAT punching + relay | Two players on different home networks find each other in the public list and play |
| 5 | Polish | Host migration, reconnect, moderation tools, replays from recorded inputs |
