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
                   │ world sim   │  UDP   │ own player  │
                   │ + own player│        │ state out,  │
                   │ 60 Hz       │        │ world in    │
                   └─────────────┘        └─────────────┘
```

- **The backend** handles accounts, level packages, room listing, NAT traversal and relay. It never simulates gameplay.
- **The host** is the player who opened the room. It runs the world at a fixed 60 Hz (enemies, blocks, props, level and entity scripts, outcomes) and owns the session. It is also the referee and relay for player movement.
- **Every machine (host included) owns its own player's movement.** It simulates that player locally with no input delay and sends the result (position, velocity, pose) to the host, which forwards it to everyone else.

### What gets synced

**Hybrid rollback (decided 2026-10-14).** Nothing is synced by copying memory, and nobody declares fields. What travels:
- **Inputs, from each client:** its player's input frame for every tick, as a bit mask, each message repeating the last 8 ticks; unreliable, 60 a second.
- **The host's state, to each client:** the level's whole state after a host tick (every plain field of every player and entity, list orders, the random generator, level state; `core/level/fullstate.lua`), as a delta against the state that client acknowledged; 20 a second, with the inputs every player used.
- **Session messages:** join, restart, votes, leaving; reliable.

Every machine runs the same simulation code. The host's simulation is the only truth; a client's is a prediction it corrects whenever the host's state arrives. Script code runs everywhere (the client predicts with it too); what a script keeps in its own local variables is not saved or sent, so changing state belongs on objects (`MODDING.md`).

Rejected: **full rollback** (GGPO: inputs only, every machine authoritative). LuaJIT floats, `math.sin` and friends and mods are not guaranteed bit-identical across platforms, and any difference would split the session for good. With the host's state always winning, a difference is just corrected. Also replaced: the owner-driven model built first (each machine moving its own player, puppets, `setPlayer` overrides, claims), because interactions between players (pushing, kicks, carrying) could not resolve the same way on every screen.

### Source of truth

**The main goal: no desync and no broken session.** Packets get lost, reordered and delayed, so every message can be lost or late without lasting harm, and every machine converges on the host's state.

| State | The truth | How it travels |
|---|---|---|
| everything in the level: players, enemies, blocks, props, scripts' object state, score, win/lose | **host** (its simulation) | state deltas, 20 a second |
| what a player pressed | **that player's machine** | inputs, every tick, repeated |
| who is in the session, level, seed, restarts, votes | **host** | reliable |

- **One simulation decides.** The host simulates every player from their inputs. A client's own simulation is a prediction: it never decides anything another machine sees.
- **Late inputs.** The host uses each player's input at its tick; when it has none yet it repeats that player's last input, and the client's prediction is corrected by the next state. Clients run just far enough ahead that their inputs arrive about 4 ticks early (`inputsync.TARGET_LEAD`); each state tells a client how early its inputs arrived, and the client runs slightly faster or slower (at most ±25%) to keep that.
- **Corrections.** A client remembers what it predicted for every tick the host sends. A host state that matches changes nothing (the usual case). One that differs is restored and the client replays its own inputs since, with the others' inputs repeated; what moved is drawn gliding from its predicted place (`interp.correct`).
- **Level generation.** Every level (re)start gets a generation number (with `restart{seed}`). Every message carries it; anything from an older generation is dropped.
- **Detect, don't hope.** Every state carries a hash of the whole state; a client whose rebuilt state does not match acknowledges 0 and gets a full one.
- **Everything from the wire is untrusted input.** The host validates every client message (rates, sizes, ranges, generation numbers); input masks are only buttons, so a client cannot move its player anywhere the rules do not allow. Clients validate the host's messages too (`core/wire.lua` is safe for untrusted bytes; `gameplay.restart(seed)` refuses a bad seed).
- **Same path for host and clients.** The host restarts through the same `gameplay.restart(seed)` a client calls on `restart{seed}`; the host's own input goes through the same mask form as everyone else's.
- **Presentation may differ; state may not.** Effects, debris, shake and sounds are local; a client shows each tick's events once, not again in a replay. Nothing that affects play may come from them.

---

## Engine prerequisites

These must land before any networking code. Each is useful on its own, and together they also gave local co-op (now deprecated: one player per machine, see N players).

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
- **One player per machine.** Network play has exactly one local player on each machine (host and clients), so up to 5 machines in a session. Local couch co-op (up to 5 players on one machine via keyboard layouts and gamepads) still works behind `--local-coop`, but is **deprecated**: frozen, not extended, and left for a far-future return. Netcode does not need to handle several local players per machine.
- **Local players (done):** the scene passes the ids of the players this machine plays (`locals`, every slot in local play) to `camera.frame`, `hud.draw` and `present.all`. The camera's `"players"` follow uses the live local players, then the live remote ones (watch the others while dead); the HUD corner lists local players, edge markers show everyone; a local player's events get full sound and shake, a remote player's only sound, at the volume and pan of where it happened (`present.soundAt`).
- **Checkpoints** are per player (`player:setSpawn`). The flag and sound stay shared (first touch).

### Input frames (done)
- Frames are `{ left, right, jump, kick, hold }` plus the level's custom actions (`level.json` `"actions"`, at most 16), held state only. Controllers read `player.input` and nothing else.
- `core/input.lua` makes frames from keyboard layouts and gamepads. On the wire a frame is a tick number plus a bit mask in `level.actionNames` order (`input.pack` / `input.unpack`); both sides know the names from the package. Clients send these masks to the host (Netcode, Client → host).
- Edges (`player.pressed`, `player.released`, and the platformer's `prevKeys`) are computed by the simulation from consecutive frames, so a frame never carries "pressed" events.

### Stable IDs (done)
- **Entities:** `id` = the placement's index in `level.json` `entities`, set by the loader, so it is the same on every load and every machine. `id`, `kind` and `typeName` are reserved for the engine.
- **Spawned entities** (`level:spawnEntity`) get ids after the placements, in spawn order (`level.nextId`). Only the host spawns; clients learn of a spawn from the `spawned` event (id, type, position, placement) and from snapshots, which name a spawned entity's type (`spawnedType`).
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
| player | `id, x, y, vx, vy, facing, onGround, jumping, dead, held`, `carrying` (entity id) or `carryingPlayer` (player id), for the sprite `state, animationTime, idleTime, kickAnimationTime, kickTime`, and `net` (script state) |
| entity (base) | `id, spawnedType, x, y, vx, vy, facing, frameIndex, rotation, flash, held` |
| entity type extras | declared by the type script: `Type.netFields = { "lit" }` (plain values only); none needed in the example level yet |
| level | `net` (level script state), `finished`, `gravity`, `camera` (`follow` as `"players"`, `"screens"`, `{ player = id }`, `{ entity = id }` or false; `x, y, zoom`) |

- `netstate.snapshot(level, tick)` builds a full snapshot: players in join order, entities sorted by id, then the level state. Script state must be plain data (`netstate.isPlain`: no functions, metatables or cycles); otherwise `snapshot` raises, and the host takes snapshots under `level:protect`, so that stops the level instead of sending garbage.
- **Script messages:** `level:send(name, data)` reports a `message` event (data must be plain). Every machine's level scripts get it in their `message` hook during presentation: the way a script tells clients about one-off things (a score popup).
- **Entity drawing is state-driven:** clients draw bodies from net fields. A type may override `draw(ui)` (`levels/topdown`'s coin does), as long as it draws only from net fields.
- `tests/sim_test.lua` checks that snapshots and events are plain data, and includes both in the determinism comparison. A full snapshot of the example level is ~5.6 KB as debug text; the binary form will be much smaller.
- **Host migration** would also need the host-only fields; that is a later phase.

### Event bus (done)
- Rules report events (`core/level/events.lua`) instead of calling `fx`, `audio` and `camera`; `core/graphics/present.lua` shows them after each tick. The event list is in `ARCHITECTURE.md` (Events).
- Local play presents events at once. In network play the host also sends them (`netstate.event`) on the reliable channel; a client resolves `id` to its own copy of the entity for images.
- Debris, corpses and explosion particles are cosmetic and stay local. Each machine randomizes them with `love.math.random`, as now.
- `restart{seed}` (done): a session message, not a level event, since it replaces the level. The host queues it (`gameplay.takeOutbox`) and every machine restarts through `gameplay.restart(seed)`. Remote players' events get positional sound (see N players).

### Seeded RNG (done)
- `mathx.newRandom(seed)` (`core/mathx.lua`) is a plain-Lua Lehmer generator (MINSTD, 48271): exact in doubles, so every machine and both interpreters produce the same numbers. `tests/sandbox_test.lua` checks it against the MINSTD reference value.
- Each level has one, `level.random`, seeded by `Level.load(root, { seed })`. Scripts get it as `random(m, n)`; their `math` copy has no `random`/`randomseed`.
- The host picks a new seed per (re)start (`level.seed`) and sends it in `restart{seed}`; a joining client also needs it, since entity types may use `random` while loading. `getState`/`setState` let a snapshot carry the generator for host migration later.
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
  - public or private (private rooms get a numeric join code, digits only);
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
- **Decided: stay on LÖVE 11.5 and bundle the native `lua-https` module** (from the LÖVE project), built per platform and shipped with the game. LÖVE 12, which includes it, has no stable release and is long delayed. Needed from Phase 4 (accounts, repository); Phases 2–3 need no HTTPS.
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
   - Direct is tried for ~3 s (public and LAN addresses); then the relay takes over without asking. Relay use is shown in the room UI.
   - **Relay only (hide my IP):** a player option in the lobby. That player always goes through the relay, so the others never see its IP address (with peer to peer they can). Privacy notes: `PRIVACY.md`.
   - **Decided:** our own rendezvous + relay. Rejected: Epic Online Services P2P, Steam networking, UPnP, and VPN tools (Tailscale, ZeroTier, Hamachi). Players never set up port forwarding.
3. **Room codes (Phase 3):** 6 digits, read out or pasted to a friend; made when the host opens the room, gone when the host leaves; no accounts needed.
4. **IPv4 only.**
5. **Port:** the game listens on UDP **26967** by default.
6. **ENet** (bundled with LÖVE 11 as `require "enet"`) with three channels:
   - `0` unreliable, sequenced: player state updates and world snapshots.
   - `1` reliable: join/leave, votes, restart, full states.
   - `2` reliable: initial full state on join.

---

## Netcode

### Budget: small and fast
Network load stays as small as possible; speed beats completeness.
- **No session logging or recording.** Gameplay sessions are not logged, recorded or replayed; nothing is sent or stored just to keep a history.
- **Only what changed.** States are deltas against what the client acknowledged; inputs are bit masks.
- **Newest state, not history.** Unreliable updates are never resent; a lost one is replaced by the next. Only full states and session messages are reliable.
- **Low, fixed rates.** Host states at **20 Hz**; client inputs every tick but only a few bytes each (8 masks).
- **Exact values, compressed messages.** States are not quantized: a client restores the host's state and replays from it, so it must be the host's exact state (the hash covers every value). Instead, every message of 128 bytes or more travels LZ4-compressed when that is smaller (`core/net/protocol.lua`, Framing).
- **Small packets.** Each packet fits one UDP datagram (well under the ~1200-byte safe MTU); a full snapshot that does not fit is split, never sent as one huge packet.

### Client → host (inputs)
- Built: `core/net/inputsync.lua`. Every tick a client records its input mask and sends `input{g, n, f, k}`: masks for ticks n-7..n, and `k`, the newest host state it has (its acknowledgement).
- The host keeps each player's masks by tick and uses them at its own tick; one that arrives after its tick still becomes that player's latest input. At most 120 input messages a second are taken from one client.

### Host → clients (state)
- Built: `core/net/statesync.lua`, `core/level/fullstate.lua`. After every 3rd tick (20 a second) the host saves its level's whole state and sends each client `snap{g, h, base, set, del, hash, ack, inp, vt, cd}`: the fields changed since the state that client acknowledged (`base`), or all of them (`base` 0, reliable; on join, restart, a lost base or a hash mismatch; at most once a second), with the newest input tick it has from that client (`ack`), the input every player used at tick h (`inp`, to predict the others) and the restart votes.
- A state is a flat map of keys ("p.<id>.<field>", "e.<id>.<field>", "s.<name>") to plain values; references between objects are saved as ids.
- **Measured (example level, 2 players, protocol 7):** full state about 7.4 KB compressed (29 KB raw); a delta over 3 ticks about 650 B compressed (1.3 KB raw), so 10–11 KB/s per client: about 45 KB/s host upload for 4 clients, within the budget. A host that claims a raw size over the message limit is refused before anything is decompressed.

### Interactions
There is one simulation (the host's), so every interaction resolves the same way for everyone: stomps, kicks, explosions, blocks, props, grabbing and throwing, carrying players, checkpoints and the goal are the same rules as in local play. **Players push each other for real** (shared sideways push, as in local play). A client sees the result of its own actions at once (predicted) and other players' with the delay of their inputs; when a prediction was wrong the host's state corrects it.

Carrying another player online works through the same rules (tested by hand, 2026-10-15). A carried player's own machine predicts itself in the carrier's hands from the carrier's last known input; corrections glide as usual, and its own inputs do nothing while carried, as in local play.

### Client presentation
- **Own player:** predicted, no delay.
- **Other players and the world:** predicted with the others' last known inputs; corrections glide over about 100 ms (`interp.correct`, a correction over 160 px snaps).
- **Testing a bad connection:** `--net-lag <ms> --net-loss <percent>` on any machine adds that round trip and loses that share of unreliable messages both ways (`session.emulate`).

### Open questions
Tracked in `OPEN_DECISION.md`.

### Session flow
- **Hosting and joining (Phase 2):** `love2d . --host` opens a session; `love2d . --join <ip>` joins one. Room codes replace typing an IP in Phase 3.
- **Levels (Phase 2):** bundled levels only. On connect the host checks the level's sha256 and the game version, and refuses a mismatch with a message.
- **Join (built, `core/net/session.lua`):** `hello{protocol, game}` → the host answers `level{name, fingerprint}` (a refused version gets `reject{reason}`) → the client checks it has the same files and answers `ready{fingerprint}` → the host checks it again and sends `welcome{you, seed, generation, players}` and tells the others `joined{id}`; the next state to the new client is a full one (reliable, after the welcome), and the client starts predicting from it. A client must finish within 5 s.
- **Fingerprint:** a bundled level's is the sha256 of its files (sorted paths, sizes, contents; `levelpack.fingerprint`), a downloaded one's is its package hash.
- **Player ids** stay stable for the session: a remote player keeps its id across restarts; a free id is reused only after its player left.
- **Late join:** allowed. The new player spawns at the host's latest checkpoint (the host player's current spawn point); its machine learns where from the host's state.
- **Inputs and state (built):** see Netcode (Client → host, Host → clients).
- **Leave or time out:** that player is removed for everyone. Anything it carried is dropped. A peer that stops answering for **5 s** is dropped with a clear message, instead of the session hanging. If the host stops answering, every client returns to the menu with a message.
- **Main menu ends the session.** There is no in-game menu that keeps the game running: going to the main menu (ESC) leaves the session. The host going to the main menu ends the session for everyone.
- **Restart:** decided by a vote (more than half of all players in the session, then a 5 s countdown; a player joining during the countdown does not cancel it; `scenes/gameplay.lua`). Votes are toggled by clients over the reliable channel (`vote{on}`); the host counts them, runs the countdown and broadcasts `restart{seed, generation, players}` (`gameplay.takeOutbox`); clients drop a restart whose generation is not newer than theirs; everyone, the host included, rebuilds the level through `gameplay.restart(seed)` and the host resends a full snapshot.
- **Host leaves:** in v1 the session ends with a message. Host migration comes later. It needs every world field in the net schema so a client can resume from the last full snapshot.

### Who runs what
| | Host | Client |
|---|---|---|
| its own player | simulates it from its input (the truth) | predicts it from its input, at once |
| other players | simulates them from their inputs | predicts them from their last known inputs |
| world physics, rules, enemies, entity and level scripts | simulates (the truth) | predicts; replaced by the host's state |
| level scripts' draw hooks and `message` | yes | yes |
| fx (debris, particles, shake, sounds) | from its events | from its predicted events, once per tick |

---

## Security and trust

- **Uploaded Lua runs on every host.** The sandbox is a guardrail, not a security boundary (`TECHNICAL.md`). So:
  - server-side checks plus the load test reject obvious abuse;
  - only hash-verified repository levels run online;
  - per-call instruction and memory limits stop runaway scripts;
  - running scripts in a separate process with no filesystem or network access is the long-term goal.
- **The host is trusted by its peers** (co-op), so there's no anti-cheat beyond host-side validation. The host simulates every player from inputs, so a modified client can only send inputs; a modified host can do anything in its own room.
- **No encryption** of game traffic (decided 2026-10-15): only inputs and game state travel. Someone on the network path could read or tamper with one co-op game; nothing private is exposed. The room code and session token decide who joins; account credentials (Phase 4) go over HTTPS.
- **A level's custom controller script runs on every machine** (for that machine's own player), under the same sandbox and limits as on the host.
- **Rate limits:** uploads, room creation, joins and reports are rate-limited per account and IP.
- **Accounts:** guest device tokens at first, stored hashed. OAuth can be added later.

---

## Roadmap

| Phase | Scope | Done when |
|---|---|---|
| 0 (done) | Engine prerequisites: fixed step, N players, input frames, IDs, net schema, events, seeded RNG, sandbox hardening, JSON encoder, package-root loader | The game plays the same at a fixed 60 Hz; a headless test feeds the same inputs twice and gets the same state hash |
| 1 (done) | Local co-op, 2–5 players (couch co-op now deprecated: one player per machine) | Every level rule works with N players: stomps, carrying, throwing at each other, per-player checkpoints, blasts |
| 2 | LAN netcode, direct IP: hybrid rollback (inputs to the host, host states, client prediction). Tested on one PC and a LAN (no port forwarding needed there). | 5 instances on one PC or a LAN play cleanly; still playable at 150 ms and 5% loss (emulated); no lasting desync or broken session |
| 3 | Plug-and-play internet play: UDP rendezvous (NAT hole punching) + relay fallback, joined by a short room code. No accounts, no public list. | Two players on different home networks connect with a room code, with no router setup; relay fallback works when punching fails |
| 4 | Backend: accounts + level repository | Upload → validate/normalize → browse → download → play an uploaded level, including gif/webp/mp3 assets |
| 5 | Public lobby (room list, accounts) on top of Phase 3's connectivity | Two strangers find each other in the public list and play |
| 6 | Polish | Host migration, reconnect, moderation tools |
