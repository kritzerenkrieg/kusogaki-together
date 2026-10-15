# Lobby

Rooms with 6-digit codes, the public room list, and the introductions that let a client and a host connect peer to peer. Phase 3 (built). Accounts and downloaded levels in the list are Phase 5 (planned, below).

Code: `lobby.go`. Tests: `lobby_test.go`. Game side: `../../core/net/rendezvous.lua`.

---

## How a join works

1. The **host** opens a room (`open`) and gets a code and a secret. It then polls every 250 ms; the room lives while the polls come and is closed 15 s after the last (or at once on `close`).
2. Both machines send a **probe** from their game socket (below), so the lobby learns each one's public `ip:port` as their routers map it. The host repeats its probe every 10 s to keep that mapping.
3. The **client** joins with the code (`join`) and polls its join (`status`).
4. Once both probes have arrived, the lobby **introduces** them: the client's `status` answers `direct <host public> <host LAN>`, and the host's poll lists `join <id> <client public> <client LAN>`. The client connects to both addresses; the host makes connect attempts to both at the same time, which opens its router for the client's packets (hole punching). The first connection to complete wins.
5. If nothing connects within 3 s the client asks for the **relay** (`relay`): the lobby opens a relay pair (`../relay/`) and both get its ports and tokens. With **Relay only** (the host's choice when it opens the room) step 4 is skipped: the lobby never hands out either address and goes straight to the relay.
6. Connected, the client sends `done` and the join is forgotten.

## Probes

The lobby must learn the public address of each machine's **game** socket (the one ENet uses), not of the socket that sends control messages: a router gives them different mappings. lua-enet cannot send raw datagrams, so the game makes an ENet connect attempt to the lobby's port carrying a random probe token as the connect data. The lobby reads the source address and the token from that raw packet (`../relay/enet.go`) and never answers; the game resets the attempt after a second.

The ENet connect packet: a 2-byte header (peer id plus flags; 4 bytes with the sent-time flag 0x8000), then the connect command (command byte 2 in the low nibble, channel, sequence) and 44 bytes of parameters whose last 4 are the connect data, big-endian. lua-enet takes the data as a signed int, so tokens stay below 2^31. Compressed packets (flag 0x4000) are ignored.

## Control messages

UDP to the lobby port, one datagram each way, text: `KG1 <verb> <fields...>`, at most 512 bytes. The game resends a request every 0.5 s until it is answered, so every request is idempotent (a repeated `open` or `join` with the same probe token gets the same room or join).

| From | Request | Answer |
|---|---|---|
| host | `open <protocol> <probe> <lan> <relayOnly>` | `room <code> <secret>` |
| host | `poll <code> <secret> [<players> <playing> <dropIn> <public> <level> <name...>]` | `hosted <code>`, then one line per pending join: `join <id> <public> <lan>` (punch these) and/or `relay <id> <port> <token>` (punch the relay) |
| host | `close <code> <secret>` | `closed` |
| client | `join <code> <protocol> <probe> <lan> <relayOnly>` | `joining <id> <secret>` |
| client | `status <id> <secret>` | `wait`, `direct <public> <lan>` or `relay <port> <token>` |
| client | `relay <id> <secret>` | as `status`, after opening a relay pair |
| client | `done <id> <secret>` | `done` |
| any | `list <protocol> <page>`, padded with spaces to at least 256 bytes | `rooms <page> <pages>`, then one line per room: `room <code> <players> <playing> <dropIn> <relay> <level> <name...>` |
| any | anything wrong | `error <reason>` (shown to the player) |

- `protocol` is the game's network protocol (`../../core/version.lua`); a join with another protocol than the room's is refused with "version mismatch: ...".
- `lan` is the machine's LAN `ip:port` (for two players behind the same router) or `-`. `relayOnly` is `0` or `1`; a join's is ignored (games send `0`): only the host chooses the relay.
- **Room info:** a host's polls carry what the list shows: players (1–5), whether a level is being played, drop-in, public (`0`/`1` each), the level (letters, digits, `_`, at most 32) and the room's name (printable ASCII, single spaces, at most 24 bytes). A join to a room with 5 players is refused with "the room is full", and to a playing room without drop-in with "the game has already started".
- **The list** has the public rooms of the asking protocol, waiting rooms first, then by code, 6 a page; a page past the end gives the last. Private rooms are never listed and are joined by code. Requests shorter than 256 bytes are refused, so a reply (at most about 600 bytes) is never much larger than the request: the list cannot be used to amplify traffic toward a spoofed address.
- Relay ports are on the lobby's own address, which the game already knows.
- Codes, secrets and ids are random (`crypto/rand`); secrets and ids are 16 hex digits.

## Limits

| What | Limit |
|---|---|
| Opens and joins | 20 per address, refilled over a minute (code guessing: 1 in 1,000,000 per try) |
| Pending joins per room | 8 |
| Rooms | 10,000 |
| A room without polls | closed after 15 s |
| A join not finished | forgotten after 60 s |
| A probe | remembered 60 s after it was last seen |
| Control datagram | 512 bytes |

---

## Planned: the room list with accounts (Phase 5)

Moved here from `NETWORKING.md` (Public lobby). Needs accounts and the level repository (Phase 4), and HTTPS.

- `POST /rooms` creates a room. It holds:
  - level id + version + sha256;
  - max players (2–5);
  - public or private (private rooms get the numeric join code above);
  - a display name.
- `GET /rooms` lists public rooms that aren't full, with level title, players and region/ping hint.
- `POST /rooms/{id}/join` (or `/rooms/join/{code}`) returns a session token plus what's needed for connectivity (the introductions above).
- **Liveness:**
  - The host heartbeats every 5 s with its player count. A room disappears after 15 s without a heartbeat.
  - Clients poll room state while waiting. LÖVE has no WebSocket, and polling is enough at lobby rates.
- **Before connecting:**
  - The client downloads and verifies the level.
  - The host checks the level hash and engine version in the ENet connect handshake, and rejects mismatches with a reason.
- How a wrong game version is shown here is on hold until this list and the repository exist (`../../OPEN_DECISION.md`, F9).
