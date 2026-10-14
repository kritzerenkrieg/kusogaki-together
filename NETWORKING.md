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

Nothing is synced by copying memory. Clients never receive Lua tables, closures or script state. What travels:
- **Player state, from each owner:** its player's declared net fields (position, velocity, pose, a few flags), ~20–30 times a second, unreliable. The host forwards them to the other machines.
- **World snapshots, from the host:** the declared *net state* of every entity and the level (enemies, blocks, props, `level.net`).
- **Events, from the host:** one-off happenings (explosion here, this block broke, an enemy died, play this sound), reliable and in order.
- **Claims, from owners:** what a player did to something it does not own ("I stomped enemy 12", "my kick hit player 3"). The host checks each claim and answers with events.

World Lua (entity and level scripts) runs only on the host, so its hidden state (locals, upvalues) never needs syncing. Anything a client must see has to be a declared net field.

Lockstep and rollback (every peer runs the same simulation) are rejected. LuaJIT floats, `math.sin`/`math.atan2` and order-dependent pair resolution (`core/physics/collision.lua`) are not guaranteed bit-identical across machines, so peers would drift. Owner-driven movement avoids the problem for players: nobody re-simulates someone else's player, they just draw the owner's numbers.

### Source of truth

**The main goal: no desync and no broken session.** We cannot trust sync to work perfectly: packets get lost, reordered and delayed, and two machines can drift even from the same inputs. So every piece of state has exactly one owner, every message can be lost or late without lasting harm, and every machine converges on the owners' numbers.

| State | Owner (the truth) | How it travels |
|---|---|---|
| a player's position, velocity, pose | **that player's machine** | unreliable, newest wins |
| enemies, blocks, props, items, scripts, score, win/lose | **host** | world snapshots, unreliable, newest wins |
| one-off happenings (block broke, enemy died) | **host** | events, reliable, in order |
| who is in the session, level, seed, restarts, votes | **host** | reliable |

- **One owner per piece of state.** Nobody else writes it. A machine that wants to change something it does not own sends a claim; the owner (for the world: the host) decides.
- **Absolute state, newest wins.** Player state and snapshots carry the full value, not a change, plus a sequence number. A lost update is simply replaced by the next one; an update older than the newest one received is dropped. Missed data catches up by itself, so plain movement cannot stay out of sync.
- **The host can override a player.** When the host must move someone (respawn, restart, a script teleport, being carried) it sends a reliable `setPlayer` with an **authority number** that goes up each time. The owner applies it and stamps its next updates with that number; the host ignores player updates stamped with an older one. This is the host's "ACK": in normal play it just takes the newest position; it only answers when it overrides. It stops the classic bug where a player snaps back to where they were before a respawn.
- **Host scripts moving a player (decided).** After each step the host checks whether a script changed a player's position or velocity; if so it sends that player's machine a `setPlayer` automatically, at most at the send rate. This is for one-off moves (teleport, launch, respawn). Continuous effects (wind, conveyors, gravity zones) are written as synced level state that each owner's controller applies to its own player, so they stay smooth (`MODDING.md`, Online play).
- **Level generation.** Every level (re)start gets a generation number (with `restart{seed}`). Every message carries it; anything from an older generation is dropped, so nothing from a previous run leaks into the new one.
- **The host is the referee.** It overrides only the clearly impossible (far past the fastest legal speed, inside solid walls, a dead player moving) and answers those with a `setPlayer` rather than accepting them; anything merely odd is accepted. It checks claims the same way (is that enemy alive, was the player close enough).
- **Detect, don't hope.** World snapshots carry the host tick and a cheap hash of the world state; a client whose world does not match asks for a full snapshot. The host also sends a full snapshot on join, on restart, after a long gap and periodically.
- **Everything from the wire is untrusted input.** The host validates every client message (rates, sizes, ranges, authority and generation numbers); clients validate the host's too (`core/wire.lua` is safe for untrusted bytes; `gameplay.restart(seed)` refuses a bad seed).
- **Same path for host and clients.** The host restarts through the same `gameplay.restart(seed)` a client calls on `restart{seed}`, and the host's own player goes through the same owner path as everyone else's.
- **Presentation may differ; state may not.** Effects, debris, shake and sounds are local and may look different on each machine. Nothing that affects play may come from them.
- **Cost of owner-driven movement:** a modified game could fly or teleport its own player. Co-op with friends accepts that; the referee checks reject the obviously impossible.

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
- `core/input.lua` makes frames from keyboard layouts and gamepads. On the wire a frame is a tick number plus a bit mask in `level.actionNames` order (`input.pack` / `input.unpack`); both sides know the names from the package. With owner-driven movement (Netcode) frames stay on the owner's machine and are not sent.
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
   - Relay use is shown in the room UI.
   - **Decided:** our own rendezvous + relay. Rejected: Epic Online Services P2P, Steam networking, UPnP, and VPN tools (Tailscale, ZeroTier, Hamachi). Players never set up port forwarding.
3. **Room codes (Phase 3):** a short code of digits only, read out or pasted to a friend; no accounts needed.
4. **Port:** the game listens on UDP **26967** by default.
5. **ENet** (bundled with LÖVE 11 as `require "enet"`) with three channels:
   - `0` unreliable, sequenced: player state updates and world snapshots.
   - `1` reliable: events, claims, `setPlayer`/`impulse`, join/leave, chat, votes, restart.
   - `2` reliable: initial full state on join.

---

## Netcode

### Budget: small and fast
Network load stays as small as possible; speed beats completeness.
- **No session logging or recording.** Gameplay sessions are not logged, recorded or replayed; nothing is sent or stored just to keep a history.
- **Only what another machine needs to draw or decide.** Declared net fields only; deltas carry changed fields only; positions and velocities quantized; no names on the wire (`netstate.pack` order).
- **Newest state, not history.** Unreliable updates are never resent; a lost one is replaced by the next. Only events, claims and session messages are reliable, and they stay few and small.
- **Low, fixed rates.** Player states and world snapshots at **20 Hz** to start (30 Hz if it looks choppy), not every 60 Hz tick; the world hash is a few bytes.
- **Quantized values.** Positions in 1/8 px, velocities in 1/16 px per tick.
- **Small packets.** Each packet fits one UDP datagram (well under the ~1200-byte safe MTU); a full snapshot that does not fit is split, never sent as one huge packet.

### Owner → host (each machine's own player)
- The owner runs its player's controller every tick (the platformer, or a level's custom controller script, in the sandbox) against the world as it sees it: statics, plus enemies, props and other players as last received.
- 20 times a second it sends that player's net fields with a sequence number, the authority number it last applied and the level generation. Unreliable: a lost packet is replaced by the next one.
- The host keeps only the newest valid update per player, runs the referee checks, and forwards it.

### Host → clients (the world)
- **Built (`core/net/worldsync.lua`, step 3).** Modders write no netcode: the host runs every level script and the engine finds what changed by comparing snapshots.
- World snapshots at 20 Hz: `world{g, n, base, ents, gone, lvl, pl, vt, cd, hash}`. Each is a delta against the snapshot that client acknowledged (`k` in its `state`): changed or new entity records, ids of removed ones, the level state if it changed, players' `net` that changed, plus restart votes and countdown. Deltas go on channel 0 (unreliable); a full snapshot (`base` 0) goes reliable, on join, after a restart, and when the client's base is too old (32 snapshots) or its hash did not match; at most one a second per client.
- **Drift detection:** every world message carries a hash (md5, 16 hex digits) of the whole state; the client rebuilds the state, checks the hash, and on a mismatch acknowledges 0 to get a full snapshot. This replaces periodic full snapshots.
- Positions and velocities of entities are snapped to 1/8 before sending, so the hash matches exactly on both sides.
- Bodies are addressed by ID; a missing body in a delta means "unchanged", removals are listed in `gone`.
- One-off events (`events{g, list}`: debris, explosion, corpse, sfx, message) go reliable and in order; the client looks entities up by id, also among bodies a snapshot just removed.
- **Measured (example level):** full snapshot about 2.4 KB, a quiet delta about 150 bytes.
- **Rough size (planned):**
  - full snapshot: 5 players + ~150 bodies × ~20 B ≈ 3 KB;
  - typical delta: a few hundred bytes;
  - host upload stays well under 100 KB/s for 4 clients.

### Interactions between owners
Movement is easy; the hard part is anything where a player meets something it does not own.

**Built (step 4):** `core/level/claims.lua`, `claim{g, c, k, id, d, vx, vy}` → `verdict{g, c, ok, n}`; see `DEVELOPMENT_PHASE.md` for the details.

**Claims are optimistic (decided).** A machine that claims something never waits for the host: it shows the result at once and carries on. The host's answer comes later and either confirms it (nothing changes) or denies it. On a denial the claimer corrects itself:
- the world (enemies, blocks, props, other players) goes back to what the host's next snapshot and events say;
- its own player's movement from the claim (a bounce, a jump off a stomp) is never undone, so nobody gets yanked around.

Rules (decided):
- **Death by enemy, hazard or falling out:** the victim's machine decides, from what it sees, reports it, and respawns itself at its checkpoint. This favours the victim, who sees others slightly late.
- **Stomping an enemy:** the stomper bounces and shows the enemy squashed at once, and claims "stomped enemy N"; the host checks it, kills the enemy and sends the event. Two stomps on one enemy: the first claim wins; the second player still keeps its bounce.
- **Kicking or bumping blocks and props:** shown at once, claimed; the host decides and sends the result.
- **Kicking another player:** the kicker claims the hit; the host checks it and sends the victim's machine an `impulse`, which the victim applies to its own player.
- **Explosions hitting players:** each machine checks its own player against the host's explosion event and applies its own death or knockback.
- **Grabbing and throwing props:** the carrier picks the prop up at once and draws it in hand with no lag; the grab is a claim and the host attaches the prop. The throw is a claim with the velocity.
- **Checkpoints:** the owner sets its own spawn point at once and claims the touch; the host raises the flag and records that player's spawn point.
- **Win / goal zone:** the host decides from the player positions it receives.
- **Players collide but do not push.** Each machine treats other players as solid, immovable bodies at their last known position: walking into someone stops you, nobody slides, and you can stand on heads (may look slightly floaty under lag). Kicks are the way to shove someone (`impulse`).
  - **Never stuck on a stale position:** lag can leave two players overlapping, or one wedged between a wall and another player who has already moved. The owner only moves its own player out of the overlap; if it cannot (a wall in the way), the two pass through each other until they are apart.
  - Replaces today's shared sideways push (`ARCHITECTURE.md`, Physics rules); changed when Phase 2 builds player collision.
  - Rejected: a real shared push. It needs the host to simulate every player (input delay or prediction with rewind), which rubber-bands under lag and costs the most to build.
- **Carrying a player:** built right after the base netcode is stable (late in Phase 2). The carrier shows the other player in its hands at once and claims the grab; the host hands ownership of the carried player to the carrier (`setPlayer` to the carried machine) and back on drop or throw (a new `setPlayer` with the throw velocity). Edge cases:
  - the carrier leaves or dies: the carried player drops where it is and gets control back;
  - both grab each other: the first claim wins;
  - a late release: the carried player keeps following the carrier; the host resends until the carried machine confirms;
  - a restart: nobody starts carried.

### Client presentation
- **Own player:** drawn from local simulation, no delay.
- **Remote players and world bodies** are drawn ~100 ms behind, interpolated between received updates, so the movement looks smooth despite the lower send rate and jitter. Built: `core/net/smooth.lua` (sender-time clocks, teleports not slid across, 0.1 s of moving on past the newest update); remote players on the host too.
- **Testing a bad connection:** `--net-lag <ms> --net-loss <percent>` on any machine adds that round trip and loses that share of unreliable messages both ways (`session.emulate`).

### Open questions
Tracked in `OPEN_DECISION.md`.

### Session flow
- **Hosting and joining (Phase 2):** `love2d . --host` opens a session; `love2d . --join <ip>` joins one. Room codes replace typing an IP in Phase 3.
- **Levels (Phase 2):** bundled levels only. On connect the host checks the level's sha256 and the game version, and refuses a mismatch with a message.
- **Join (built, `core/net/session.lua`):** `hello{protocol, game}` → the host answers `level{name, fingerprint}` (a refused version gets `reject{reason}`) → the client checks it has the same files and answers `ready{fingerprint}` → the host checks it again and sends `welcome{you, seed, generation, players}` and tells the others `joined{id}`; the next world message to the new client is a full snapshot (reliable, after the welcome). A client must finish within 5 s. The new player's machine becomes its owner.
- **Fingerprint:** a bundled level's is the sha256 of its files (sorted paths, sizes, contents; `levelpack.fingerprint`), a downloaded one's is its package hash.
- **Player ids** stay stable for the session: a remote player keeps its id across restarts; a free id is reused only after its player left.
- **Late join:** allowed. The new player spawns at the host's latest checkpoint (the host player's current spawn point), sent as a `setPlayer` right after the welcome (built).
- **Player state (built, `core/net/playersync.lua`):** every 3 ticks (20 Hz) a client sends `state{g, s, a, p, e}` on channel 0 (unsequenced): generation, sequence, the authority it obeys, its player as 8 integers (position in 1/8 px, velocity in 1/16 px per tick, flags, kick timers, respawns) and up to 8 player event names (for remote sounds; a lost one is just a missed sound). The host drops a state from another generation, with an older authority or an older sequence, and refuses the clearly impossible (outside the level, faster than 1500 px/s, further from the last accepted state than that speed allows, except a respawn) with `setPlayer{g, a, x, y, vx, vy}` back to the last accepted state and the next authority. Every 3 ticks the host sends `players{g, list}` to every client: its own player and each client's state accepted since the last send, as `{id, s, p, e}`; clients keep the newest per player. At most 60 states a second are taken from one client.
- **Leave or time out:** that player is removed for everyone. Anything it carried is dropped. A peer that stops answering for **5 s** is dropped with a clear message, instead of the session hanging. If the host stops answering, every client returns to the menu with a message.
- **Main menu ends the session.** There is no in-game menu that keeps the game running: going to the main menu (ESC) leaves the session. The host going to the main menu ends the session for everyone.
- **Restart:** decided by a vote (more than half of all players in the session, then a 5 s countdown; a player joining during the countdown does not cancel it; `scenes/gameplay.lua`). Votes are toggled by clients over the reliable channel (`vote{on}`); the host counts them, runs the countdown and broadcasts `restart{seed, generation, players}` (`gameplay.takeOutbox`); clients drop a restart whose generation is not newer than theirs; everyone, the host included, rebuilds the level through `gameplay.restart(seed)` and the host resends a full snapshot.
- **Host leaves:** in v1 the session ends with a message. Host migration comes later. It needs every world field in the net schema so a client can resume from the last full snapshot.

### Who runs what
| | Host | Client |
|---|---|---|
| own player (movement, controller, pose) | yes | yes |
| other players | draws owners' updates | draws owners' updates |
| world physics, rules, enemies | yes | no (draws snapshots) |
| entity type scripts | full | view mode: `load()` for images, base `draw` |
| level scripts | full | draw hooks (`drawBehind`, `drawWorld`, `drawHud`) and `message`, from synced state only |
| `player.net` (script state on a player) | owns it (level scripts run here) | receives it |
| player controllers (custom) | for its own player | for its own player (sandboxed), plus `draw` |
| fx (debris, particles, shake, sounds) | from events | from events |

---

## Security and trust

- **Uploaded Lua runs on every host.** The sandbox is a guardrail, not a security boundary (`TECHNICAL.md`). So:
  - server-side checks plus the load test reject obvious abuse;
  - only hash-verified repository levels run online;
  - per-call instruction and memory limits stop runaway scripts;
  - running scripts in a separate process with no filesystem or network access is the long-term goal.
- **The host is trusted by its peers** (co-op), so there's no anti-cheat beyond host-side validation. Each machine owns its player's movement, so a modified game can move its own player freely; the host's referee checks reject the obviously impossible.
- **A level's custom controller script runs on every machine** (for that machine's own player), under the same sandbox and limits as on the host.
- **Rate limits:** uploads, room creation, joins and reports are rate-limited per account and IP.
- **Accounts:** guest device tokens at first, stored hashed. OAuth can be added later.

---

## Roadmap

| Phase | Scope | Done when |
|---|---|---|
| 0 (done) | Engine prerequisites: fixed step, N players, input frames, IDs, net schema, events, seeded RNG, sandbox hardening, JSON encoder, package-root loader | The game plays the same at a fixed 60 Hz; a headless test feeds the same inputs twice and gets the same state hash |
| 1 (done) | Local co-op, 2–5 players (couch co-op now deprecated: one player per machine) | Every level rule works with N players: stomps, carrying, throwing at each other, per-player checkpoints, blasts |
| 2 | LAN netcode, direct IP: owner-driven player movement, host-owned world. Tested on one PC and a LAN (no port forwarding needed there). | 5 instances on one PC or a LAN play cleanly; still playable at 150 ms and 5% loss (emulated); no lasting desync or broken session |
| 3 | Plug-and-play internet play: UDP rendezvous (NAT hole punching) + relay fallback, joined by a short room code. No accounts, no public list. | Two players on different home networks connect with a room code, with no router setup; relay fallback works when punching fails |
| 4 | Backend: accounts + level repository | Upload → validate/normalize → browse → download → play an uploaded level, including gif/webp/mp3 assets |
| 5 | Public lobby (room list, accounts) on top of Phase 3's connectivity | Two strangers find each other in the public list and play |
| 6 | Polish | Host migration, reconnect, moderation tools |
