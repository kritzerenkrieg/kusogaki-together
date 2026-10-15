# Relay

Copies datagrams between a client and a host that could not connect directly (hole punching failed, typically behind carrier-grade NAT or strict routers), or where a player chose **Relay only** to keep its IP address from the others. Phase 3 (built).

Code: `relay.go` (pairs), `enet.go` (reading ENet connect packets; the lobby uses it for probes too). Tests: `relay_test.go`.

---

## Pairs

Each relayed client gets a **pair** of UDP ports from the range (`-relay-ports`, default 27000–27999, so up to 500 relayed players at once):

```text
client  ──ENet──▶  relay:ClientPort   relay:HostPort  ◀──ENet──  host
         (connects as if to the host)  (the host's punch, then the client's traffic)
```

- The client connects to `ClientPort` as if it were the host. The host makes a connect attempt to `HostPort` (it opens the host's router toward the relay); from then on the host sees the client as `relay:HostPort`.
- Each end is accepted only from an ENet connect packet carrying the **token** the lobby issued for that end (`ClientToken`, `HostToken`; random, below 2^31). The first such packet locks that end's address; anything from any other address is dropped.
- Nothing is forwarded until both ends are known. The host's own connect attempts (carrying `HostToken`) are never forwarded: the client must not see them.
- After that the relay copies datagrams both ways without reading them. ENet runs end to end: acknowledgements, resends and the game's messages pass through unchanged.

## Limits

| What | Limit |
|---|---|
| Rate | 64 KB/s each direction, bursts up to 256 KB (token bucket) |
| Idle | a pair silent for 30 s is closed |
| Room closed | its pairs are closed |
| Datagram | 2048 bytes read |

Expected load: the host sends a client about 10–11 KB/s (state deltas, `../../NETWORKING.md` Budget) and a client sends about 4.5 KB/s, so a relayed client costs the server about 15 KB/s in and 15 KB/s out. A full room of four relayed clients is about 60 KB/s each way.

## Not done (on purpose)

- No encryption and no inspection: game traffic carries nothing private (`../../OPEN_DECISION.md`, F7).
- No logging of addresses (`../README.md`, Rules).
- One region. More relays in more regions only if ping demands it (`../../OPEN_DECISION.md`, F4).
