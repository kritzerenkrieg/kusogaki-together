# Technical Architecture

2D physics-based platformer with community composability. Gameplay is platformer-based; other genres are built by combining engine primitives, not separate game modes.

---

## Core Engine

```text
Entity/Component · Platformer Controller · Physics/Collision · Animation
Rendering · Audio/Particles · Camera · Input · Trigger/Event
                    │
            Composition API
              ┌─────┴─────┐
           Editor      Lua VM
              └─────┬─────┘
                Level Package
```

- Gameplay is built from entities/components, bodies/colliders, joints, triggers/events, player input, animation, camera/audio/effects, and Lua.
- The editor and Lua operate on the same entity/component representation.

### Lua

- **Allowed:** entity, physics, collision, trigger/event, player state, camera, audio, particles, timers, level spawn/destroy.
- **Forbidden:** filesystem, process execution, networking, native libraries, OS APIs, raw memory.

#### Sandbox

Implemented in `core/script.lua` and `core/watchdog.lua`; every rule has a test in `tests/sandbox_test.lua` (run under LuaJIT and Lua 5.1) or `tests/sim_test.lua`. Still planned: process isolation.

Scripts get raw access to their own level (its players, entities, stages, camera, gravity): that is what lets a level become a different game (`MODDING.md`). The rules below keep that access inside the level: no engine module, class or shared data, no OS, and limits on time and memory.

LÖVE's LuaJIT has no built-in sandbox, and Lua environment restrictions are a guardrail, not a security boundary.

- Each script runs in its own environment table (`setfenv`) with whitelisted functions only; there is no `love`.
- Chunks load as text only; bytecode is rejected.
- `ffi`, `jit`, `debug`, `package`, `require`, `dofile`, `loadfile`, `load`/`loadstring`, `os`, `io`, `getfenv`/`setfenv`, `coroutine`, `collectgarbage`, `print` and `_G` are unreachable.
- `math`, `string` and `table` are per-script copies: changing them never reaches the engine. `math.random`/`math.randomseed` are removed; scripts use `random(m, n)`, the level's seeded generator. `string.dump` is removed and `string.rep` is size-capped.
- Injected engine classes (`Entity`, `Prop`) are read-only views, deeply: a script cannot change engine methods or tables such as `Prop.CONFIG`. Engine classes and players protect their metatables (`__metatable`), and `getmetatable` returns nothing for strings (whose metatable is the engine's string library).
- **Limits on functions a script defines at load** (`script.guard`): an instruction budget (2 million per call, checked every 20 instructions with `debug.sethook`) and a memory budget (64 MB of heap growth per call). Script chunks run with the JIT off (`jit.off`), because LuaJIT skips hooks in compiled code. A script's `pcall` cannot swallow a limit error. A script that errors or hits a limit at runtime is disabled (its functions become no-ops) and the game goes on. Errors while loading a level fail the load with the message.
- **Limits on script code anywhere else** (`script.protect`): scripts get live objects, so they can store functions where the engine later calls them (an entity's `draw`, a fake event, a metatable on a table they were given). Each simulation step, drawing and event presentation runs as a protected phase: script code in it (recognised by the chunk it was loaded from) has the same instruction budget, checked every 1,000 instructions, and the phase has the memory budget. A failure there stops the level (`level:fault`): the scene shows "This level stopped" with restart/menu instead of crashing.
- **Built-in C functions run as one step**, so the hook cannot interrupt them. They are limited before they run, in the global string/table libraries so method calls (`("x"):rep(n)`) are covered too: `string.rep`, `string.gsub` and `table.concat` refuse results over 16 MB; while script code runs, patterns may have at most 8 quantifiers and search at most 256 KB (catastrophic backtracking needs both).
- **No engine classes or shared data reachable**: classes hand out instances through separate protected metatables (`LEVEL_META`, `RANDOM_META`, `ENTITY_META`, player methods only), so `obj.__index` or a lookup never returns a class, and per-session tuning (`CONFIG`, `KEYS`) stays out of reach. `tests/sim_test.lua` audits this: it walks everything a script can reach from what it is given and fails on engine modules, engine classes, data shared across levels, unsafe built-ins, or functions from modules scripts must not reach (it found and closed the `__index` class leak and the shared player tuning).
- Asset paths are package-relative and resolved by the loader: no `..`, no absolute paths, images only from the package or the engine's shared `assets/graphics/`. Sound events naming anything but a plain `name.wav|ogg|mp3` are ignored.
- **Cost:** about 0.25 ms per tick in the example level with 5 players (0.49 vs 0.23 ms), about 3% of a 60 Hz frame.
- **Watchdog** (`core/watchdog.lua`, thread in `core/watchdog_thread.lua`): `love.update` sends a heartbeat every frame. If a level is running (`watchdog.enter(root)`, before its scripts even load) and no heartbeat arrives for 8 s, the thread writes `watchdog_report.json` (the level's root) to the save directory and ends the process (`_exit`, so nothing waits on the frozen main thread). The next launch reads the report, tells the player why the game closed, and adds a downloaded level's sha256 to `blocked_levels.json`; `levelpack.mount` and the loader refuse blocked packages. Bundled and local levels are reported but never blocked (their author is testing them). Menus call `watchdog.leave()`, so a pause there is never blamed on a level. Known false positive: anything that stops the main loop for 8 s during a level (a debugger breakpoint, dragging the window on some systems) also ends the game.

Remaining risks (reasons for the watchdog and process isolation):
- A C function that is slow without being caught by the limits above (e.g. a crafted pattern on a table's metamethod path outside a guarded call) can still freeze the game for up to 8 s, until the watchdog ends it. Ending is all it can do: the frozen thread cannot be resumed.
- LÖVE objects scripts can reach (an entity's `Image`, its sprite `Quad`s) expose their methods; none read or write files, but `image:release()` can break drawing (the level then stops). The audit cannot list userdata methods headlessly; this list is checked by hand.
- A bug in LuaJIT itself, or a reachable engine function that misbehaves with crafted arguments. The audit keeps that surface small and listed; process isolation is the real boundary.
- Scripts may change their own level's state, by design.

---

## Level Package

```text
Level Package
├── level data   -- level.json
├── Lua scripts  -- entity types (entities/) and level scripts (scripts/), sandboxed
├── assets       -- images and media
└── metadata     -- name, format version
```

Levels are portable and versioned. Level data is declarative and never executes; Lua scripts run only inside the sandbox.

Implemented: `core/level/loader.lua` loads a package from its root: a bundled `levels/<name>` or a downloaded package mounted at `online/<sha256>` by `core/levelpack.lua` (zip in the save directory, sha256-checked before mounting). It reads `level.json` (format 1: `spawn`, `background`, `static`, `entities`, optional `scripts`), validates names, and builds level data. Each type runs once per load from `<root>/entities/<type>.lua`, and each listed level script from `<root>/scripts/<script>.lua`, via `core/script.lua`. Scripts name assets relative to the package (`assets/box.png`).

Code layout, the running level, gameplay rules and physics rules are in `ARCHITECTURE.md`.

---

## Networking

Centralized backend with UDP P2P gameplay and one authoritative host (up to 5 players).

- **Backend:** accounts, level repository, lobby, NAT traversal and relay. Does not simulate gameplay.
- **Host:** runs physics, Lua, AI, game state and triggers at a fixed 60 Hz. Clients send inputs; the host sends snapshots of declared net state, plus events.
- **Transport:** ENet over UDP.

The full design (engine prerequisites, level repository, lobby, connectivity, netcode, roadmap) is in `NETWORKING.md`.

---

## Authority and Security

- Host is authoritative. Clients send inputs, not state.
- Sync is never trusted to be perfect: the lobby host is the single source of truth, its snapshots overwrite client state, and clients converge on it (full snapshots, state hashes). See `NETWORKING.md` (Source of truth).
- Lua affecting gameplay runs in the authoritative simulation.
- Community levels cannot run system code.
- Native engine changes are separate from level content and need explicit install/trust.

---

## Simulation Requirements

Fixed timestep · seeded deterministic RNG · stable entity IDs · host-authoritative state · snapshot/delta sync · client prediction/interpolation · replay/input recording · host migration · Lua execution limits. See `NETWORKING.md` → Engine prerequisites.

The design separates community extensibility from system authority: creators compose gameplay freely, while the engine, OS, and network boundaries stay controlled.
