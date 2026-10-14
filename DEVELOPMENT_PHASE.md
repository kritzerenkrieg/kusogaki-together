# Development Phase

Where the online/modding work stands, what was decided, and what comes next. It's a handover note: read it first when picking the work up again. Undecided choices are tracked in `OPEN_DECISION.md`. Design details live in `NETWORKING.md` (online), `TECHNICAL.md` (engine and sandbox), `ARCHITECTURE.md` (code layout and rules) and `MODDING.md` (what level scripts can do).

Last updated: 2026-10-14 (Phase 1 complete; every decision for Phase 2 made, see `OPEN_DECISION.md`; Phase 2 steps 1–3, sessions, player state and the host's world over ENet, done).

---

## Decisions (made by the project owner)

| Topic | Decision |
|---|---|
| Source of truth | **Priority: no desync and no broken session.** We cannot trust sync to work perfectly, so every piece of state has exactly one owner: a player's movement belongs to its machine, everything else to the lobby host. Updates are absolute and newest-wins; the host overrides a player with a numbered `setPlayer`; level generations drop stale messages; world hashes detect drift. Details: `NETWORKING.md` (Source of truth). |
| Players per machine | **One player per machine (per host/client).** Multiplayer means network play. Local couch co-op is **deprecated**: frozen behind `--local-coop`, kept working by the existing tests but not extended, and left for a far-future return. New work (netcode, HUD, input, lobby) assumes one local player and must not add couch co-op complexity. |
| Gamepads | **Deprecated and parked.** The one player plays on keyboard layout 1. Gamepads work only with `--local-coop`; `level.json` actions may still list `gamepad` inputs (accepted, unused otherwise). Not to be discussed again until there is nothing else to do. |
| Network load | **Small and fast.** No gameplay session logging, recording or replays. Send only declared, changed, quantized fields at ~20–30 Hz; unreliable updates are never resent; packets fit one UDP datagram. Details: `NETWORKING.md` (Budget). |
| Online model | P2P (ENet/UDP) with a backend for accounts, level repository, lobby, NAT punching and relay. **Each machine owns its own player's movement** and sends its state (newest wins, missed updates catch up); **the host owns the world and the session** and is the referee and relay for player movement. No lockstep, no client prediction/rewind. Details: `NETWORKING.md` (Source of truth, Netcode). |
| Session size | Up to **5 players** (1 host + 4 clients). |
| Backend stack | **Go** + Postgres + S3-compatible storage. |
| Engine version | **Stay on LÖVE 11.5.** HTTPS (Phase 4) comes from the native `lua-https` module, bundled per platform. LÖVE 12 has no stable release and is long delayed; reconsider only if it ships. |
| Connectivity | Our own rendezvous (hole punching) + relay, digits-only room codes, UDP port **26967**. No Epic/Steam/UPnP/VPN tools; players never set up port forwarding. |
| User levels | Custom Lua in uploaded levels is **allowed**, behind a hardened sandbox. |
| Uploaded assets | png, jpg/jpeg, gif, webp, wav, ogg, mp3. The server converts webp and gif to png (LÖVE 11.5 can't decode them); animated gif becomes a spritesheet plus `<name>.anim.json`. |
| Script access | **Raw access, no API proxies.** Scripts get the real level, players and entities, Garry's Mod–style flexibility. Security relies on the sandbox, protected phases and the reachability audit, later on process isolation. |
| Goal | Players can bend the game into other genres (Garry's Mod–like). Flexibility comes from engine features exposed directly to scripts (step 3 below). |

---

## Done

### Phase 0: engine prerequisites (complete)
- **Fixed timestep:** 60 Hz via `core/fixedstep.lua`, with draw interpolation in `core/graphics/interp.lua`.
- **Up to 5 players:** `level.players`, `level:addPlayer`, every rule loops over all players, player-on-player physics (standing on heads, shared pushes). Local co-op (now deprecated, `--local-coop` only): keyboard layout 2 joins with J, gamepads with A/Start; per-player tints, HUD and edge markers.
- **Input frames:** `core/input.lua`. The simulation reads only `player.input = { left, right, jump, kick, hold }`.
- **Stable IDs:** entity `id` = its placement's index in `level.json`; `level.byId`, `level:get(id)`; every removal goes through `level:removeEntity`.
- **Event bus:** `core/level/events.lua` collects what happened; `core/graphics/present.lua` turns it into effects and sound. Rules never call fx, audio or camera.
- **Net state:** `core/level/netstate.lua` lists the snapshot fields; `pack`/`unpack` give a compact form (2.2 KB full snapshot of the example level).
- **Seeded random:** `core/math.lua` was renamed to `core/mathx.lua`. `mathx.newRandom(seed)` is a plain-Lua MINSTD generator; `level.random`; scripts get `random(m, n)` and no `math.random`.
- **Serialization:** `core/json.lua` encodes and decodes (`json.null`, depth limit); `core/wire.lua` is the binary format, safe for untrusted input.
- **Packages:** the loader takes a package root (`levels/<name>` or `online/<sha256>`); `core/levelpack.lua` checks the sha256 and mounts the zip. Script asset paths are package-relative (`"assets/box.png"`).
- **Sandbox:** see step 1 below.

### Publishing-safety plan, step 1: close the in-process sandbox gaps (done)
- **Size caps:** 16 MB on `string.rep`, `gsub` and `table.concat`, in the global libraries, so method calls are covered too.
- **Pattern limits** while scripts run: at most 8 quantifiers and 256 KB of subject.
- **Memory checks** every 20 instructions inside script calls.
- **Protected phases** (`script.protect` / `level:protect`): each step, draw and event presentation limits script code wherever it runs (stored functions, metamethods). A failure faults the level: a "This level stopped" screen with restart / ESC menu instead of a crash.
- **Reachability audit** in `tests/sim_test.lua`. It found and fixed two leaks:
  - `obj.__index` exposed engine classes (fixed with separate protected metatables: `LEVEL_META`, `RANDOM_META`, `ENTITY_META`, `PROP_META`, methods-only `PLAYER_META`);
  - players exposed the shared tuning tables `CONFIG` and `KEYS`.
- **Cost:** about 0.25 ms per tick with 5 players (≈3% of a frame).
- Remaining risks are listed in `TECHNICAL.md` (Sandbox).

---

### Publishing-safety plan, step 2: watchdog (done, option A)
- `core/watchdog.lua` + `core/watchdog_thread.lua`: `love.update` beats every frame; the gameplay scene says which level runs (`watchdog.enter(root)` before loading, `leave()` on exit).
- After 8 s without a beat during a level, the thread writes `watchdog_report.json` and ends the process with `_exit`.
- The next launch shows why the game closed. A downloaded level (`online/<sha256>`) goes on `blocked_levels.json`; `levelpack.mount` and the loader refuse it. Bundled and local levels are reported, not blocked.
- Tested in `tests/sim_test.lua` (with a 0.3 s timeout, no exit). The real exit was checked once by hand with a scratch game: a true `while true do end` freeze ended with exit code 3 after 0.77 s (0.5 s timeout), and the next launch blocked the level.
- Option B (simulation in its own thread): after Phase 2. Clients will draw from snapshots by then, so the host can draw the same way and the simulation can move to a thread with a much smaller change. It matters most once uploaded levels run online (Phase 4).

### Publishing-safety plan, step 3: flexibility (done)
Scripts get these directly on the level (reference: `MODDING.md`):
- **Custom input actions:** `level.json` `"actions"` (key per keyboard layout, gamepad buttons, stick directions, triggers; at most 16). `player.pressed` / `player.released` edges; `input.pack` / `unpack` give a bit mask for the network.
- **Replaceable player controller:** `level.playerController` or `player.controller` (`update`, optional `draw`); the platformer is the default and stays callable (`player:update`, `player:animate`).
- **Runtime spawning:** `level:spawnEntity(type, x, y, def)`. Ids continue after the placements; it emits a `spawned` event; snapshots carry `spawnedType`.
- **Camera control:** `level.camera` (`follow` players, screens, any body or fixed; `zoom`; `clamp`), on both axes.
- **Gravity:** `level.gravity` / `maxFall` (from `level.json`, changeable) and `body.gravityScale`.
- **Gamemode hooks:** the step is `level.stages`, a per-level list of named stages that scripts add, remove, replace or wrap; `level:finish(outcome, message)` ends the level with a result screen. Level script hooks: `load`, `playerJoined`, `update`, `message`.
- **World drawing:** `drawBehind` / `drawWorld` / `drawHud` hooks and `entity:draw(ui)`; `ui` gained circles, lines, images, sprites and `view()`.
- **Script network state:** `level.net`, `player.net` and the camera/gravity/outcome go in snapshots; `level:send(name, data)` messages reach every machine's `message` hook. Everything sent must be plain data (`netstate.isPlain`).
- **Example:** `levels/topdown` is a top-down coin race with zero gravity, its own controller, a dash action, spawned coins, a magnet stage, a win condition and popups. Play it with `love2d . --level topdown`.
- **Checks:** the audit now runs on both levels. Neither the example level's behaviour baseline nor the per-tick cost changed.

### Players kick and carry each other (done)
Not lethal. A kick knocks back; grab carries; kick while carrying throws; a carried player cannot get away (by design) until dropped, thrown, or someone dies. Rules in `ARCHITECTURE.md` (Physics rules); checks in `tests/sim/players.lua`.

### Goal zone, respawn count, restart vote (done)
- Example level: `levels/example/scripts/goal.lua` highlights a zone past the flag pole; the level is won when every player is alive inside it.
- `player.respawns` survives restarts and resets on a win. Restarting is a toggleable vote (more than half, then a 5 s countdown). See `ARCHITECTURE.md` (Local players); checks in `tests/sim/scene.lua` and `tests/sim/features.lua`.

### Phase 1 leftovers for network play (done)
- **Local-player view:** the scene passes its players' ids (`localIds()`) to `camera.frame`, `hud.draw` and `present.all`. The camera follows the live local players (then the live remote ones while they are dead); the HUD corner lists local players; local players' events get sound and shake, remote players' only positional sound (`present.soundAt`). Local co-op is unchanged: every player is local.
- **`restart{seed}`:** the host picks the seed, queues `restart{seed}` (`gameplay.takeOutbox`) and restarts through `gameplay.restart(seed)`, the call a client will make on that message (it refuses bad seeds). `level.seed` keeps the seed.
- **Source of truth** written down in `NETWORKING.md`: the lobby host decides, clients only ask, the host's snapshots overwrite, drift heals through full snapshots and state hashes.
- Checks in `tests/sim/features.lua` (local players) and `tests/sim/scene.lua` (restart seed). Behaviour baseline unchanged.

### Local couch co-op deprecated (done)
- Joining a second local player (J, gamepad A/Start) and the HUD join hint are off unless the game runs with `love2d . --local-coop`. `gameplay.join` stays for that flag and for tests.
- Gamepads are deprecated with it: without `--local-coop` the scene ignores every gamepad press. `core/input.lua` keeps its gamepad source.
- The engine keeps N players (`level.players`, player-vs-player rules): network play needs them. Only the *local* multi-slot input is frozen.

### Phase 2 step 1: sessions over ENet (done)
- `core/net/protocol.lua` (message types, strict validation of untrusted bytes, port 26967, addresses) and `core/net/session.lua` (ENet host and client, the join handshake, refusals with a reason, 5 s timeouts, session messages). `core/version.lua` holds the game and protocol versions.
- `love2d . --host` opens a session; `love2d . --join <ip[:port]>` joins one. The host checks game version and level fingerprint (`levelpack.fingerprint`), sends the seed, generation and player list, then a full snapshot. Restarts (`restart{seed, generation, players}`) and votes (`vote{on}`) are networked; joins and leaves are announced; ESC to the menu ends the session.
- Player ids are stable for the session (`level:addPlayer(player, id)`); a late joiner spawns at the host's latest checkpoint.
- Remote players stood still and clients only saw their own restart vote then; step 2 fixed the first.
- Checks: `tests/sim/net.lua` (messages, fingerprints, host and clients over localhost: join, snapshot, restart, wrong level, wrong version, garbage, leave, host closing). Checked once by hand: two scratch clients joined a real `love2d . --host` game, got the 72-entity snapshot, voted a restart (generation 1 → 2) and the leave was announced.

### Phase 2 step 2: player state (done)
- `core/net/playersync.lua`: each machine sends its own player's state 20 times a second (`state`), absolute and newest-wins, stamped with generation, sequence and authority numbers. The host referees it (outside the level, impossibly fast, teleported) and answers the impossible with `setPlayer` and a higher authority; states still stamped with the old one are dropped. The host forwards every player's newest state to every client (`players`). A late joiner gets a `setPlayer` to the host's checkpoint.
- Other machines' players are **puppets**: not simulated, solid but immovable (players collide, nobody pushes a puppet; `body.immovable` in `core/physics`), skipped by rules that change a player (`stages.simulated`), and not kickable or grabbable yet. Between states a puppet keeps its last velocity for up to 0.1 s. Their jump, stomp and death sounds travel with their state.
- **Protocol 2** (`core/version.lua`, game 0.1.5): older builds are refused at join.
- **Not yet:** every machine still simulates the world itself, so enemies, blocks and props can differ between machines (a remote player's stomp, block bump or kick only happens on its own machine) until step 3 (host world snapshots) and step 4 (claims). Clients see only their own restart vote. Host scripts moving a remote player do not send `setPlayer` yet: while clients run their own copy of the scripts the owner's machine already does the same move, so sending it too would apply it twice; it comes with step 3. Custom controllers' own fields (a dash) are not synced; a puppet shows the platformer pose fields only (on hold with the top-down level).
- Checks: `tests/sim/net.lua` (wire form, message checks, referee, puppets in physics and rules, dead reckoning, overrides, and the gameplay scene as host with a client: checkpoint placement, puppet following, the host's state reaching the client, a refused teleport, stale authority and generation). Checked by hand with two headless game processes (host and client running the real scene over localhost): after both stopped moving, each showed both players at the same place (x 153.0 and 466.6).

### Phase 2 step 3: the host's world (done)
- `core/net/worldsync.lua`: the host runs the world (every rule, entity and level script) and, 20 times a second, captures the synced state (entities with positions and velocities snapped to 1/8, level state, players' `net`) as a numbered snapshot. Each client gets a delta against the snapshot it last acknowledged (`k` in its `state`), or a full one (on join, restart, a lost base or a hash mismatch; at most one a second, reliable). Every message carries a hash of the whole state; a client whose rebuilt state does not match acknowledges 0 and gets a full one. Deltas go unreliable: a lost one is covered by the next. A quiet delta is about 150 bytes; a full snapshot of the example level about 2.4 KB.
- One-off events (debris, explosions, corpses, sounds, level scripts' `message`) go reliable, in order (`events`). Restart votes and the countdown come with the world, so everyone sees all votes.
- Clients run only their own player's stages (`worldsync.CLIENT_STAGES`: input, players, collisions, hazards, enemyTouch, bounds, playerAnimation; `level:update(delta, only)`) against the world they were sent; no world rules, no level scripts' `update`. Their own deaths stay theirs. `level.remoteWorld` marks a client's level. The join snapshot of step 1 is gone (the first world message replaces it).
- **Host scripts moving a remote player** (position, velocity, respawn point, e.g. a checkpoint) now send that player's machine a `setPlayer` with only the changed fields (OPEN_DECISION A4). Checkpoints work for clients this way.
- **Protocol 3** (game 0.1.6).
- **Not yet:** a client cannot stomp-kill enemies (it bounces, the host does not know), kick, grab, break blocks or push props: those become claims in step 4. Explosions do not hurt client players yet (step 4 rule). World bodies on clients move by dead reckoning between snapshots, with small snaps (interpolation is step 5). The top-down level is on hold.
- Checks: `tests/sim/net.lua` (full and delta snapshots between two levels: moves, removals, a spawn, level state, old and orphan deltas, hash mismatch → full; the scene sends a joined client the full world; a host script moving a remote player sends a setPlayer). By hand: two headless game processes over localhost; the client applied 1 full snapshot and 123 deltas with no hash mismatch, and both showed 72 entities and 13 enemies.

## Next

**Phase 2: LAN netcode over direct IP** (`NETWORKING.md`, Netcode). Model: each machine owns its own player's movement; the host owns the world and the session. Every machine has exactly one local player. Phase 2 is tested on one PC and a LAN; internet play without port forwarding is Phase 3.

Decided: players collide but do not push each other (solid, immovable to each other; kicks shove; an owner that cannot get out of an overlap passes through, so nobody gets stuck). Kick and grab still apply.

All decisions needed for Phase 2 are made (`OPEN_DECISION.md`, Decided). New open questions go there.

Settled by the model: a custom (script) controller runs on its owner's machine for that player; clients run only the draw hooks and `message` of level scripts.

Then, in rough order:
1. ~~ENet host/client over direct IP; join sends `level.seed`, the level generation and a full snapshot; the outbox's session messages go on the reliable channel.~~ Done (above).
2. ~~Owner → host player state (newest wins, sequence + authority + generation numbers); host forwards it and runs referee checks; `setPlayer` overrides.~~ Done (above).
3. ~~Host → clients world snapshots and deltas, periodic full snapshots and a world hash so clients detect drift. Clients stop running world rules and level scripts' update; host scripts moving a remote player then send `setPlayer` (OPEN_DECISION A4); restart votes are shown to everyone.~~ Done (above); the hash replaces periodic full snapshots.
4. Optimistic claims and their rules (stomps, kicks, deaths, props, checkpoints, `impulse`), then carrying players (`NETWORKING.md`, Interactions between owners).
5. Interpolation (~100 ms) of remote players and world bodies; timeouts and clean leave handling.
6. Done when 5 instances play cleanly on one PC/LAN, stay playable at 150 ms and 5% emulated loss, and never desync or break the session.

Testing: a built-in `--net-lag <ms> --net-loss <%>` emulator for the 150 ms / 5% loss check.

### Roadmap after that (from `NETWORKING.md`)
| Phase | Scope |
|---|---|
| 1 (done) | Local co-op polish, plus the local-player view and `restart{seed}` |
| 2 | LAN netcode over direct IP: ENet, owner-driven player state, host world snapshots and deltas, interpolation. |
| 3 | Plug-and-play internet play: rendezvous (NAT hole punching) + relay fallback, room codes, no accounts. Players never set up port forwarding. |
| 4 | Backend: accounts + level repository (upload pipeline, asset conversion, headless load test). Needs HTTPS: LÖVE 11.5 has no TLS, so ship the `lua-https` module per platform. |
| 5 | Public lobby (room list, accounts) on top of Phase 3 |
| 6 | Polish: host migration, reconnect, moderation |
| after 2 | Simulation in its own thread (watchdog option B) |
| later | Process isolation for scripts (the real security boundary) |

---

## Working notes

- **Run every test:** `sh tests/run.sh`. It runs the physics, sandbox and JSON suites under `luajit` and `lua`, then the headless LÖVE suite (`love2d . --sim-test`). `lua5.1` and `luajit` are installed system-wide.
- **Behaviour baseline:** the scripted run in `tests/sim_test.lua` should keep giving
  - 1 player: furthest x 922, 5 deaths, enemies 13 → 12;
  - 3 players: 921, 12 deaths, 13 → 10;
  - 5 players: 958, 19 deaths, 13 → 10.

  (The 3- and 5-player numbers changed when players learned to kick and carry each other; the scripted inputs now hit each other.)

  If those numbers move, the change altered gameplay.
- **Speed baseline:** about 0.5 ms per tick with the protections on (≈0.23 ms without).
- **Commits:** Phase 0 and step 1 are in `a91b41f v0.1.0`; steps 2 and 3, kick/carry and the goal/respawn/vote work are in `7cc3f1d v0.1.1`. The Phase 1 leftovers and the co-op/gamepad deprecation are in `v0.1.2`.
- **Not yet checked in a real window:**
  - effects, sound and shake via events;
  - package-relative images;
  - the "This level stopped" and finish screens;
  - gamepad joining (deprecated with couch co-op; only with `--local-coop`);
  - the camera zoom and vertical follow (`--level topdown`);
  - the watchdog notice on the next launch.
  - remote players' positional sound (needs network play to see for real; covered by checks for now).
