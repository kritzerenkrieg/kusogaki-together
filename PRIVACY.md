# Privacy Policy (draft)

**Status: future work.** A draft to finish before the first public release with internet play (Phase 3) and to extend when accounts arrive (Phase 4). Not yet in force; the contact, operator name and hosting details are still to fill in.

Last updated: 2026-10-15.

---

## What Kusogaki Together collects

### Internet play (rooms with codes)
- **Your IP address and port.** The rendezvous server sees them when you open or join a room, so it can introduce the machines in the room to each other. The relay sees them when it forwards your game traffic.
- **Room codes and session tokens.** They are made when a host opens a room and decide who may join it.

The rendezvous keeps addresses, codes and tokens only while the room is open and forgets them when the host leaves. The relay forwards packets and keeps nothing. Neither writes your address to a log.

### What other players see
Play is peer to peer: the machines in a room talk to each other directly. **Players in your room can see your IP address** (in practice, the host's address is visible to everyone who joins). To hide yours, turn on **Relay only** in the lobby: your traffic then goes through our relay and the other players see only the relay's address.

### What is never collected
- No gameplay recording, replays or session logs.
- No analytics or tracking.
- Game traffic is inputs and game state only: no chat, voice or personal data.
- Game traffic is not encrypted (it carries nothing private). Account sign-in (Phase 4) always goes over HTTPS.

### Accounts and levels (Phase 4, not built yet)
To be written when built. Planned: a display name, a device token stored only as a hash, the levels you upload, and reports you make or receive for moderation.

---

## Who handles it
- The rendezvous and relay run on a server we rent (provider and region: to fill in).
- We do not sell or share your data. It goes to nobody except the players in your room (your IP address, as above).

## Your rights
Under the GDPR and similar laws you may ask what we hold about you and ask us to delete it. For internet play there is nothing to delete after your room closes. Contact: _to fill in_.

## Storefronts
If you got the game through a store (for example Steam or itch.io), that store's own privacy policy covers your store account; this policy covers only the game and our servers.
