# Open Decisions

Choices still to make for the online work, each with a proposed answer. Fill in **Choice** (write "ok" to take the proposal), then move the row to **Decided** and copy the outcome into the doc named in **Goes to**. Design context: `NETWORKING.md`; current state and plan: `DEVELOPMENT_PHASE.md`.

Status: **open** (not discussed yet) · **discussing** · **decided**

Last updated: 2026-10-15.

---

## Open

Add new questions here as rows: | # | Decision | Proposal | Choice | Status | Goes to |

### G. Other players look jerky on clients (playtest 2026-10-15, phone hotspot)

On the host every player moves smoothly. On a client, other players doing quick moves (tapping left and right, short hops) jerk: the client keeps predicting a player's last input (still walking right, still holding jump), and when the host's state shows otherwise the correction glides them back over ~100 ms (`interp.correct`). Steady running looks fine; every quick change overshoots, then gets pulled back.

How long a client B predicts another player A wrongly (A's own ping adds nothing, A's inputs reach the host early):

| Part | Size | Removable? |
|---|---|---|
| B's round trip to the host | RTT (e.g. 100 ms) | No, while clients run ahead of the host (the price of instant own controls) |
| Lead cushion, `inputsync.TARGET_LEAD` | 4 ticks = 67 ms | Yes, for knowing others' inputs: see G1 |
| Host states at 20 Hz | 0–50 ms, ~25 ms average | Yes, same |

About 190 ms at 100 ms ping. The client learns others' inputs only from the host's states, after the host has used them. G1 (decided, below) removes the lead and the wait for another client's player; for the host's player only the wait goes (the host has no early inputs).

| # | Decision | Proposal | Choice | Status | Goes to |
|---|---|---|---|---|---|
| G2 | If G1 is not enough: how clients draw other players | **Draw others from the host's states** (buffered one state interval, blended between states), exactly as the host showed them, about one round trip plus ~50 ms behind the own player; the simulation still predicts them for collisions. Near the own player (within about a tile) draw the predicted position instead, so stomps and pushes look right. Rejected: slower correction glide for others only (still overshoots, looks floaty); input delay for everyone (every player's own controls lag, host too). | | open | `NETWORKING.md` Client presentation |



---

## Decided

Most recent first. Each line: date, decision (choice number), where it is written.

- 2026-10-16: **Levels live outside the game.** The game ships its levels in `builtin/` and copies them into the save directory's `levels/` (`kusogaki-together`, not under `LOVE`, in the released builds); downloads go to `downloads/<id>/`. Levels travel only through the level repository on our server: a room names its level by id and a client without it downloads it from there. Uploads for now: no accounts, plain HTTP on the lobby's port, rate-limited per address; accounts and HTTPS stay Phase 4. A level's name stays letters, digits and `_` (rooms and the room list carry it). (`NETWORKING.md` Level repository, `server/repository/README.md`)
- 2026-10-15: **Host states stay at 20 Hz.** With G1 the inputs travel every tick; 60 Hz states measured no smoother (200 ms round trip, with and without 10% loss: mean error 20–22 px either way) but cost 2.7× the upload (45 vs 17 KB/s per client) and about 3× the CPU on both sides. (G3; `NETWORKING.md` Budget)
- 2026-10-15: **The host forwards every player's inputs to the other clients each tick** (`ahead`), and clients replay with the real inputs they have; a forwarded input that shows a wrong prediction replays at once. Client-to-client at 200 ms: mean error 31.9 → 19.7 px. (G1; `NETWORKING.md` Host → clients (others' inputs), `DEVELOPMENT_PHASE.md`)
- 2026-10-16: **Multiplayer is a room list and a waiting room.** The menu has Singleplayer and Multiplayer; Multiplayer lists the public rooms on our server (name, room ID, level, players, relayed) and creates rooms; a session starts in a waiting room where the host picks the level and starts a 3 s countdown; when the level is over the host takes everyone back. Rooms can be private (joined by room ID only). Drop-in (joining while a level is played) is a room setting, on by default. Players have a name (Options). (`NETWORKING.md` Public lobby, Session flow)
- 2026-10-16: **Relay only is the host's choice** for the whole room, replacing the per-player option: a relayed room hides every player's address from the others, and the list shows it. (`NETWORKING.md` Connectivity, `PRIVACY.md`)
- 2026-10-15: ~~**Relay only (hide my IP)** is a player option in the lobby~~ (replaced 2026-10-16: the host's choice). (`NETWORKING.md` Connectivity)
- 2026-10-15: A privacy policy is drafted in `PRIVACY.md` (future work: finish before the first public release with internet play). (`PRIVACY.md`)
- 2026-10-15: **Phase 2 is closed.** Carrying players and checkpoints were tested online by hand; with the LAN run and the loss-and-delay hand test, that completes it. (F1; `DEVELOPMENT_PHASE.md`)
- 2026-10-15: A carried player's own machine predicts itself in the carrier's hands from the carrier's last known input; host corrections glide as usual; its own inputs do nothing while carried, as in local play. (F2; `NETWORKING.md` Interactions)
- 2026-10-15: The simulation thread (watchdog option B) comes after Phase 3, unless a play test shows hitches from replays or slow scripts. (F3; `DEVELOPMENT_PHASE.md` Roadmap)
- 2026-10-15: Room codes are 6 digits, made when the host opens the room, gone when the host leaves. (F5; `NETWORKING.md` Connectivity)
- 2026-10-15: IPv4 only. (F8; `NETWORKING.md` Connectivity)
- 2026-10-15: **Keep our own rendezvous and relay** (confirms E1). Play stays peer to peer; the rendezvous only introduces the two machines (hole punching), the relay forwards only when punching fails. One small VPS in one region (Go, UDP only), more regions only if ping demands it. (F4; `NETWORKING.md` Connectivity)
- 2026-10-15: Try direct (public and LAN addresses) for 3 s, then the relay without asking; the room shows "relayed". (F6; `NETWORKING.md` Connectivity)
- 2026-10-15: **No encryption** of game traffic: nothing private travels; the worst case is someone on the same network path reading or tampering with one co-op game. The room code and a session token decide who may join; the relay forwards only for known tokens and caps each room's rate. Account credentials (Phase 4) go over HTTPS anyway. (F7; `NETWORKING.md` Security)
- 2026-10-15: How a wrong game version is shown over the internet is **on hold** until the lobby and level repository exist (Phases 4–5); until then the join handshake refuses it with a reason, as on the LAN. (F9)
- 2026-10-15: **State values are exact, not quantized; messages are LZ4-compressed instead.** A client restores the host's state and replays from it, so it must be the host's exact state. Replaces the quantization part of D1–D4. Deltas 1.3 KB → 650 B; 10 KB/s per client. (`NETWORKING.md` Budget, `DEVELOPMENT_PHASE.md`)

- 2026-10-14: **Netcode is hybrid rollback (host-authoritative rollback).** Clients send their inputs to the host; the host simulates every player and the whole world and is the only source of truth. Each client predicts the world with its own inputs (others' last known inputs repeated), and when a host snapshot arrives it restores it and replays its newer inputs. Players push each other for real again (shared push, as in local play). Replaces: owner-driven player movement, puppets, `setPlayer` overrides and claims (Phase 2 steps 2 and 4), and "no client prediction/rewind". Full rollback (GGPO, inputs only, every machine authoritative) was rejected: it needs bit-exact determinism across platforms and mods, and a difference desyncs the session for good. (`NETWORKING.md`, `DEVELOPMENT_PHASE.md`)

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
- 2026-10-14: 20 Hz send rate (30 if choppy); 100 ms interpolation; ~~positions in 1/8 px, velocities in 1/16 px per tick~~ (replaced 2026-10-15: exact values, compressed); the referee overrides only the clearly impossible. (D1–D4; `NETWORKING.md` Budget, Source of truth)
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
