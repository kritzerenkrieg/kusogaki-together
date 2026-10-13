# Development Phase

Where the online/modding work stands, what was decided, and what comes next. It's a handover note: read it first when picking the work up again. Design details live in `NETWORKING.md` (online), `TECHNICAL.md` (engine and sandbox) and `ARCHITECTURE.md` (code layout and rules).

Last updated: 2026-10-13.

---

## Decisions (made by the project owner)

| Topic | Decision |
|---|---|
| Online model | Host-authoritative P2P (ENet/UDP) with a backend for accounts, level repository, lobby, NAT punching and relay. Clients send inputs; the host sends snapshots and events. No lockstep. |
| Session size | Up to **5 players** (1 host + 4 clients). |
| Backend stack | Go (or Node) + Postgres + S3-compatible storage. |
| User levels | Custom Lua in uploaded levels is **allowed**, behind a hardened sandbox. |
| Uploaded assets | png, jpg/jpeg, gif, webp, wav, ogg, mp3. The server converts webp and gif to png (LÖVE 11.5 can't decode them); animated gif becomes a spritesheet plus `<name>.anim.json`. |
| Script access | **Raw access, no API proxies.** Scripts get the real level, players and entities, Garry's Mod–style flexibility. Security relies on the sandbox, protected phases and the reachability audit, later on process isolation. |
| Goal | Players can bend the game into other genres (Garry's Mod–like). Flexibility comes from engine features exposed directly to scripts (step 3 below). |

---

## Done

### Phase 0: engine prerequisites (complete)
- **Fixed timestep:** 60 Hz via `core/fixedstep.lua`, with draw interpolation in `core/graphics/interp.lua`.
- **Up to 5 players:** `level.players`, `level:addPlayer`, every rule loops over all players, player-on-player physics (standing on heads, shared pushes). Local co-op: keyboard layout 2 joins with I, gamepads with A/Start; per-player tints, HUD and edge markers.
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
- **Protected phases** (`script.protect` / `level:protect`): each step, draw and event presentation limits script code wherever it runs (stored functions, metamethods). A failure faults the level: a "This level stopped" screen with R restart / ESC menu instead of a crash.
- **Reachability audit** in `tests/sim_test.lua`. It found and fixed two leaks:
  - `obj.__index` exposed engine classes (fixed with separate protected metatables: `LEVEL_META`, `RANDOM_META`, `ENTITY_META`, `PROP_META`, methods-only `PLAYER_META`);
  - players exposed the shared tuning tables `CONFIG` and `KEYS`.
- **Cost:** about 0.25 ms per tick with 5 players (≈3% of a frame).
- Remaining risks are listed in `TECHNICAL.md` (Sandbox).

---

## Next

### Publishing-safety plan, step 2: watchdog (decision pending)
A built-in C function that hangs can't be interrupted in-process. Two options were proposed:
- **A. Light watchdog (recommended now, small):** a `love.thread` expects a heartbeat every frame. After about 5 s frozen during a level, it writes the level's root/hash to a "blocked" file in the save directory and the game exits. The next launch tells the player the level was blocked and refuses it; later this gets reported to the server.
- **B. Simulation in a worker thread (large):** the main thread only draws and can drop a frozen session. This is the same split as host and client, so it belongs to Phase 2.

The owner has not yet confirmed A. Ask, then implement.

### Publishing-safety plan, step 3: flexibility (engine features exposed directly to scripts)
- **Custom input actions** declared by the level package (not only the 5 fixed ones); the input mask grows from them.
- **Replaceable player controller:** the platformer controller becomes the default.
- **Runtime spawning:** `level:spawn(type, x, y)` with host-assigned ids, so the network can sync spawns.
- **Camera control:** follow any body, both axes, zoom, fixed screens.
- **Gravity per level and per body:** zero gravity for top-down.
- **Gamemode hooks** at each stage of `Level:update`, plus win/lose.
- **World-space drawing hooks,** driven by synced state only.
- **Script network state:** script-declared `netFields` and a message API, with docs on host, client and shared code.

### Roadmap after that (from `NETWORKING.md`)
| Phase | Scope |
|---|---|
| 1 | Local co-op polish (mostly done during Phase 0) |
| 2 | LAN netcode over direct IP: ENet, snapshots and deltas, prediction, interpolation. Option B of the watchdog fits here. |
| 3 | Backend: accounts + level repository (upload pipeline, asset conversion, headless load test) |
| 4 | Lobby + NAT punching + relay. Needs HTTPS: LÖVE 11.5 has no TLS, so ship `lua-https` or move to LÖVE 12. |
| 5 | Polish: host migration, reconnect, moderation, replays |
| later | Process isolation for scripts (the real security boundary) |

---

## Working notes

- **Run every test:** `sh tests/run.sh`. It runs the physics, sandbox and JSON suites under `luajit` and `lua`, then the headless LÖVE suite (`love2d . --sim-test`). `lua5.1` and `luajit` are installed system-wide.
- **Behaviour baseline:** the scripted run in `tests/sim_test.lua` should keep giving
  - 1 player: furthest x 922, 5 deaths, enemies 13 → 12;
  - 3 players: 869, 12 deaths, 13 → 10;
  - 5 players: 868, 19 deaths, 13 → 10.

  If those numbers move, the change altered gameplay.
- **Speed baseline:** about 0.5 ms per tick with the protections on (≈0.23 ms without).
- **Not committed:** all of Phase 0 and step 1 are uncommitted (about 55 changed or new files on top of `7c7685e v0.0.8`). The staged `assets/audio/music/level1.mp3` and `level3.wav` were already staged before this work and were left as they were.
- **Not yet checked in a real window:** effects, sound and shake via events; package-relative images; the "This level stopped" screen; gamepad joining.
