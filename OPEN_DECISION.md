# Open Decisions

Choices still to make for the online work, each with a proposed answer. Fill in **Choice** (write "ok" to take the proposal), then move the row to **Decided** and copy the outcome into the doc named in **Goes to**. Design context: `NETWORKING.md`; current state and plan: `DEVELOPMENT_PHASE.md`.

Status: **open** (not discussed yet) · **discussing** · **decided**

Last updated: 2026-10-14.

---

## Open

Nothing open. Add new questions here as rows: | # | Decision | Proposal | Choice | Status | Goes to |

---

## Decided

Most recent first. Each line: date, decision (choice number), where it is written.

- 2026-10-14: The top-down level (`levels/topdown`) is on hold indefinitely: not supported online and not worked on. Syncing custom player fields (its dash) is held with it. (`DEVELOPMENT_PHASE.md`)
- 2026-10-14: **Modders write no netcode.** The host runs every level script; clients run only draw hooks and `message`. The engine detects what scripts changed in synced state and sends it: world state as deltas against the snapshot each client acknowledged (newest wins, world hash, full snapshot when needed), one-off events on the reliable channel. A host script that moves a remote player sends a `setPlayer` by itself. The one rule for modders: what others must see lives in object fields, not script locals. (`NETWORKING.md` Host → clients, `MODDING.md` Online play)

- 2026-10-14: Stay on LÖVE 11.5; HTTPS from the bundled `lua-https` module (Phase 4). Replaces E3 and E6: LÖVE 12 has no stable release (latest is 11.5, Dec 2023) and is long delayed. (`NETWORKING.md` HTTPS, `DEVELOPMENT_PHASE.md`)
- 2026-10-14: ~~Move to LÖVE 12 as the first step of Phase 2.~~ Replaced above. (E6)
- 2026-10-14: Simulation in its own thread (watchdog option B) after Phase 2, once drawing works from snapshots. (A5; `DEVELOPMENT_PHASE.md`)
- 2026-10-14: A host script that changes a player sends a `setPlayer` automatically (at most at the send rate) for one-off moves; continuous effects go in synced level state that each owner's controller applies. (A4; `NETWORKING.md` Source of truth, `MODDING.md` Online play)

- 2026-10-14: Gamepads parked: not discussed again until there is nothing else to do. (E5; `DEVELOPMENT_PHASE.md`)
- 2026-10-14: Backend in Go. (E4; `DEVELOPMENT_PHASE.md`)
- 2026-10-14: ~~Move to LÖVE 12 for HTTPS; bundling `lua-https` rejected.~~ Replaced by staying on 11.5 with `lua-https`. (E3; `NETWORKING.md` HTTPS, `DEVELOPMENT_PHASE.md`)
- 2026-10-14: Room codes are digits only. (E2; `NETWORKING.md` Connectivity, Public lobby)
- 2026-10-14: Our own rendezvous (hole punching) + relay; Epic Online Services, Steam networking, UPnP and VPN tools rejected. (E1; `NETWORKING.md` Connectivity)
- 2026-10-14: Built-in `--net-lag <ms> --net-loss <%>` emulator for testing. (D6; `DEVELOPMENT_PHASE.md`)
- 2026-10-14: Default UDP port 26967. (D5; `NETWORKING.md` Connectivity)
- 2026-10-14: 20 Hz send rate (30 if choppy); 100 ms interpolation; positions in 1/8 px, velocities in 1/16 px per tick; the referee overrides only the clearly impossible. (D1–D4; `NETWORKING.md` Budget, Source of truth)
- 2026-10-14: The main menu ends the session: no in-game menu that keeps the game running; ESC leaves, and the host leaving ends it for everyone. (C4; `NETWORKING.md` Session flow)
- 2026-10-14: A peer silent for 5 s is dropped with a message; host gone: everyone returns to the menu. (C3; `NETWORKING.md` Session flow)
- 2026-10-14: Restart vote counts all players in the session; joining during the countdown does not cancel it. (C2; `NETWORKING.md` Session flow)
- 2026-10-14: A late joiner spawns at the host's latest checkpoint. (C1; `NETWORKING.md` Session flow)
- 2026-10-14: Gameplay rules between owners as proposed (deaths, stomps, kicks, blocks/props, explosions, prop carry, checkpoints, win, carrying players late in Phase 2 with its edge-case rules), on condition that **claims are optimistic**: the claimer never waits for the host and corrects itself when the host answers; its own movement is never undone. (B1–B10; `NETWORKING.md` Interactions between owners)
- 2026-10-14: The host owns `player.net`; the owner machine owns only movement and pose. (A3; `NETWORKING.md` Who runs what)
- 2026-10-14: Phase 2 plays bundled levels only, checked by sha256 and game version on connect. (A2; `NETWORKING.md` Session flow)
- 2026-10-14: Phase 2 hosts and joins with `--host` and `--join <ip>`. (A1; `NETWORKING.md` Session flow)
- 2026-10-14: Roadmap order: LAN netcode (2) → plug-and-play rendezvous + relay with room codes (3) → accounts + level repository (4) → public lobby (5) → polish (6). Phase 2 is tested on one PC and a LAN. (`NETWORKING.md` Roadmap, `DEVELOPMENT_PHASE.md`)
- 2026-10-14: Network load small and fast; no gameplay session logging, recording or replays. (`NETWORKING.md` Budget)
- 2026-10-14: Players collide but do not push each other; kicks shove; an overlap the owner cannot leave passes through so nobody gets stuck. Kick and grab still apply. (`NETWORKING.md` Interactions between owners)
- 2026-10-14: Each machine owns its own player's movement; the host owns the world and the session and is referee and relay. No client prediction/rewind. (`NETWORKING.md` Source of truth)
- 2026-10-14: A custom (script) controller runs on its owner's machine; clients run only level scripts' draw hooks and `message`. (`NETWORKING.md` Who runs what)
- 2026-10-14: Gamepads deprecated for now. (`DEVELOPMENT_PHASE.md`)
- 2026-10-14: One player per machine; local couch co-op deprecated behind `--local-coop`. (`DEVELOPMENT_PHASE.md`)
- 2026-10-14: Priority for the source of truth: no desync and no broken session. (`NETWORKING.md` Source of truth)
