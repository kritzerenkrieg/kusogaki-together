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

Implemented: `core/level/loader.lua` reads `levels/<name>/level.json` (format 1: `spawn`, `background`, `static`, `entities`), validates names, and builds level data. Each type runs once per load from `levels/<name>/entities/<type>.lua` via `core/script.lua`.

Code layout, the running level, gameplay rules and physics rules are in `ARCHITECTURE.md`.

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
