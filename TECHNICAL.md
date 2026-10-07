# Technical Architecture

## Overview

The game is a 2D physics-based platformer with deep community composability.

The native gameplay model is strictly platformer-based. Alternative gameplay such as racing, flying, or Flappy Bird-style mechanics must be constructed by coupling existing engine primitives rather than selecting separate game modes.

Community content is extensible through a visual editor and sandboxed Lua scripting.

---

## Core Engine

```text
Game Engine
├── Entity / Component System
├── Platformer Controller
├── Physics / Collision
├── Animation
├── Rendering
├── Audio / Particles
├── Camera
├── Input
└── Trigger / Event System
          │
    Composition API
       ┌──┴──┐
       │     │
    Editor  Lua VM
       └──┬──┘
          │
     Level Package
```

### Composition

Gameplay is created by coupling engine primitives:

- Entities and components
- Physics bodies and colliders
- Joints and constraints
- Triggers and events
- Player properties and input
- Animation/timeline
- Camera, audio, particles and effects
- Lua scripts

The engine does not provide generic `game_mode` abstractions such as racing, flying, or shooter modes.

The editor and Lua operate on the same underlying entity/component representation.

### Lua

Lua provides controlled access to the engine API.

Allowed:

- Entity manipulation
- Physics operations
- Collision configuration
- Triggers/events
- Player state
- Camera
- Audio
- Particles
- Timers
- Level spawning/destruction

Forbidden:

- Filesystem access
- Process execution
- Arbitrary networking
- Native library loading
- OS/system APIs
- Arbitrary memory access

Lua execution is sandboxed and subject to resource limits.

---

## Level Package

```text
Level Package
├── level data
├── Lua scripts
├── assets
└── metadata
```

Levels are portable and versioned.

The runtime loads the same representation produced by the editor.

---

## Networking

The game uses a **centralized backend with P2P gameplay**.

```text
             Central Backend
          ┌────────────────────┐
          │ Authentication      │
          │ Lobby / Matchmaking │
          │ Signaling           │
          │ Workshop / Levels   │
          │ Player Metadata     │
          └─────────┬──────────┘
                    │
              Connection Setup
                    │
             ┌──────┴──────┐
             │             │
          Host Peer     Client Peer
             │             │
             └──── UDP ────┘
```

### Central Backend

Responsible for:

- Authentication
- Lobby creation/discovery
- Matchmaking
- NAT traversal/signaling
- Level discovery/distribution
- Community metadata
- Moderation/reporting
- Relay fallback

The backend does not normally simulate gameplay.

### Gameplay

Gameplay uses **UDP P2P with one authoritative host**.

```text
                 Host
          ┌───────────────┐
          │ Physics       │
          │ Lua           │
          │ AI            │
          │ Game State    │
          │ Triggers      │
          └───────┬───────┘
                  │
          Authoritative State
             ┌────┴────┐
             │         │
           Peer A    Peer B
```

Clients send player input to the host.

The host executes the authoritative simulation and sends state updates to clients.

Use a UDP networking layer such as ENet rather than implementing reliability directly on raw UDP.

### Network Semantics

- **Unreliable:** frequent movement/physics snapshots
- **Reliable:** important gameplay events and state changes
- **Sequenced:** discard stale state updates
- **Delta compression:** transmit changed state where possible
- **Client interpolation/prediction:** hide latency and jitter
- **Fixed simulation timestep:** consistent gameplay simulation

### NAT Traversal

```text
Lobby / Signaling
       │
    STUN / ICE
       │
 Host UDP ◄──────► Client UDP
       │
       └── failure ──► UDP Relay
```

Direct P2P is preferred; relay is a fallback.

---

## Authority and Security

The host is authoritative for gameplay.

Clients send inputs rather than authoritative game state.

Lua affecting gameplay executes in the authoritative simulation context.

Community levels cannot execute arbitrary system code.

Native engine modifications are separate from ordinary level content and require explicit installation/trust.

---

## Simulation Requirements

The engine should support:

- Fixed timestep simulation
- Seeded deterministic RNG
- Explicit entity ownership
- Host-authoritative state
- State snapshots/delta synchronization
- Client prediction/interpolation
- Replay/input recording
- Host migration
- Lua execution limits

The architecture separates **community extensibility from system authority**: creators can deeply compose gameplay while the engine, operating system, and network boundaries remain controlled.