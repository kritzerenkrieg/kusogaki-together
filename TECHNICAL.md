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

#### Sandbox (partly implemented)

Implemented in `core/script.lua`: text-only chunks, whitelisted environment, injected base classes. Still planned: instruction and memory limits, and process isolation.

LÖVE's LuaJIT has no built-in sandbox, and Lua environment restrictions are a guardrail, not a security boundary.

- Each mod runs in its own environment table (`setfenv`) with whitelisted functions and a restricted `love` subset.
- Mod chunks load as text only; bytecode is rejected.
- `ffi`, `debug`, `package`, `require`, `dofile`, `loadfile`, `load`/`loadstring`, `os`, `io` are unreachable.
- The host enforces instruction and memory limits via `debug.sethook`.
- Fully untrusted code runs in a separate process with no filesystem or network access.
- Each rule needs a test mod that attempts the blocked call.

---

## Level Package

```text
Level Package
├── level data   -- level.json
├── Lua scripts  -- entity types and behavior (entities/, sandboxed)
├── assets       -- images and media
└── metadata     -- name, format version
```

Levels are portable and versioned. Level data is declarative and never executes; Lua scripts run only inside the sandbox.

### Mapping: Level → World → Entities

- **Level** (`levels/<name>/`): level data, Lua scripts, assets, and metadata (see Level Package). Declares spawn, static geometry, and entity placements.
- **World** (built by `scenes/gameplay.lua`): `solids` (static geometry + hazards), `props` (dynamic entities), `hazards`. Physics and scene logic read only the world.
- **Entities** (`levels/<name>/entities/<type>.lua`): one class per type. A type defines `name`, `kind` (`"prop"` or `"hazard"`), `assetPath`, `w`/`h`, `load()`, and `new(x, y)`. Base behavior lives in `core/` (`entity.lua`, `prop.lua`).
- Placements are `{ type, x, y }` in one `entities` list; the type's `kind` decides whether it goes to `props` or `hazards`.

Rules:
- Collision size belongs to the type (`Type.w`, `Type.h`). Placements give position and instance data only.
- Placements reference a type by name (`"box"`), never a file path.
- Hazards are solids; the scene checks touch and kills the player.
- Coordinates are center-based `x, y, w, h` in pixels, matching physics.

Implemented: `core/level.lua` reads `levels/<name>/level.json` (format 1: `spawn`, `background`, `static`, `entities`), validates names, and builds level data. Each type runs once per load from `levels/<name>/entities/<type>.lua` via `core/script.lua`.

---

## Project Layout

```text
core/
  entity.lua    base entity: collider, mass, movement, draw
  prop.lua      base carryable prop: ground friction, placeholder draw
  physics.lua   AABB movement, collision, resting contact
  player/       platformer player, split by concern:
    init.lua          body and update order; public API
    config.lua        key bindings, tuning, animation timing
    controller.lua    input, movement, jump, kick
    carry.lua         grab, drop, throw, held-prop position
    state.lua  state fields, timers, death/respawn
    view.lua          sprite selection and drawing
tests/
  physics_test.lua    headless checks (lua tests/physics_test.lua)
  level.lua     level loader: level.json → level data, draw
  script.lua    sandboxed loader for entity scripts
  json.lua      JSON decoder
levels/example/
  level.json           layout, placements, background
  entities/box.lua     prop type script (asset + collision size)
  entities/spike.lua   hazard type script (asset + collision size)
scenes/gameplay.lua  hosts the level, updates the world
```

Base behavior lives in `core/`; concrete types live in `levels/`.

---

## Physics Rules

- **Held props have no physics.** A carried prop is rendered at the hand, overlapping the player's facing edge by 4px. Solid and body resolution skip it.
- **Release/throw** moves the prop to touch the player first, so release never shoves the player. If that spot is blocked, the overlap stays.
- **Push-out side:** `moveBody` records start positions; overlaps push a body back toward the side it came from, not its center, so bodies are not ejected out of the level.
- **Pinned player:** if a prop's correction would push the player into a solid, the prop takes it instead.
- **Resting stacks:** a slow fall onto a support clamps the upper body's vertical speed to the support's, regardless of pair order.

---

## Networking

Centralized backend with UDP P2P gameplay and one authoritative host.

- **Backend:** authentication, lobby/matchmaking, signaling, NAT traversal, level distribution, community metadata, moderation, relay fallback. Does not simulate gameplay.
- **Host:** runs physics, Lua, AI, game state, and triggers. Clients send inputs; the host sends authoritative state.
- **Transport:** ENet over UDP.
  - Unreliable: frequent snapshots.
  - Reliable: important events and state changes.
  - Sequenced: discard stale updates.
  - Delta compression.
  - Client interpolation/prediction.
  - Fixed timestep.
- **NAT:** STUN/ICE, direct P2P preferred, UDP relay fallback.

---

## Authority and Security

- Host is authoritative. Clients send inputs, not state.
- Lua affecting gameplay runs in the authoritative simulation.
- Community levels cannot run system code.
- Native engine changes are separate from level content and need explicit install/trust.

---

## Simulation Requirements

Fixed timestep · seeded deterministic RNG · explicit entity ownership · host-authoritative state · snapshot/delta sync · client prediction/interpolation · replay/input recording · host migration · Lua execution limits.

The design separates community extensibility from system authority: creators compose gameplay freely, while the engine, OS, and network boundaries stay controlled.
