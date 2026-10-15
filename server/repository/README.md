# Repository

Accounts and the level repository: uploads, validation, asset normalization, a headless load test, storage and downloads. **Phase 4: design only, nothing built yet.** Moved here from `NETWORKING.md` (Level repository); the package format and what the game does with downloads stay there (Package, Client side), since the game reads them too.

Decided: backend in Go (`../../OPEN_DECISION.md`, E4); HTTPS from the bundled `lua-https` module on the game side, since LÖVE 11.5 has no TLS (`../../NETWORKING.md`, HTTPS).

---

## Asset formats
Uploads may use common media types. The server normalizes them so every client gets something LÖVE 11.5 can load (verified: LÖVE 11.5 decodes png, jpg, wav, ogg and mp3; it does not decode gif or webp).

| Upload | Stored as | Notes |
|---|---|---|
| `png` | `png` | decode check |
| `jpg` / `jpeg` | `jpg` | decode check |
| `webp` | `png` | transcoded (Go `golang.org/x/image/webp`) |
| `gif`, single frame | `png` | transcoded |
| `gif`, animated | `png` spritesheet + `<name>.anim.json` | frames laid out horizontally; sidecar has frame count, frame size and per-frame delays, read by `Entity` animation |
| `wav`, `ogg`, `mp3` | unchanged | decode check, duration/size caps |

- The file type comes from the magic bytes and must match the extension.
- After normalization the server rewrites references in `level.json` and the scripts' asset names to the stored names. The package hash covers the normalized package, and the original upload is kept for re-processing.
- **Limits** (initial values, tune later):

| What | Limit |
|---|---|
| Package | 16 MB |
| Image | 2048×2048 px |
| GIF | 64 frames |
| Sound effect | 10 s |
| Music | 4 min / 10 MB per file |
| Lua | 200 KB total |

## Upload pipeline (`POST /levels`)
1. **Auth and rate limit.**
2. **Zip safety:**
   - total and per-file size caps, and a compression-ratio cap (zip bombs);
   - no absolute paths or `..`;
   - a file whitelist by folder.
3. **Validation:**
   - `level.json` against a JSON schema; names match `^[%w_]+$`, as the loader already requires.
   - Lua is text only (reject `\27Lua` bytecode) and within size limits.
4. **Asset normalization** (see the table above).
5. **Headless load test:**
   - runs in a container with no network and CPU/memory/time limits;
   - LÖVE with the hardened sandbox loads the level and steps 600 ticks with no input;
   - any error or limit hit rejects the upload with the message.
6. **Storage:**
   - the package goes to S3 at `levels/<sha256>.zip`;
   - a new immutable `level_versions` row goes into Postgres.

## Data (Postgres)
- `users(id, name, device_token_hash, created_at, banned)`
- `levels(id, author_id, title, description, tags, status, created_at)`, where status is listed, unlisted or hidden
- `level_versions(id, level_id, version, sha256, size, engine_version, created_at)`, immutable
- `ratings(user_id, level_id, value)`, `play_stats(level_id, plays, clears)`, `reports(id, level_id, user_id, reason, created_at, resolved)`

## API
- `GET /levels?q=&tag=&sort=` lists levels, `GET /levels/{id}` gives details and versions, `GET /levels/{id}/versions/{v}/download` redirects to the package.
- `POST /levels`, `POST /levels/{id}/versions`, `PATCH /levels/{id}` (title, description, tags, unlist).
- `POST /levels/{id}/rate`, `POST /levels/{id}/report`.
- HTTPS only. Plain HTTP is allowed only against a localhost dev server.

## Accounts
- Guest device tokens at first, stored hashed. OAuth can be added later.
- Uploads, room creation, joins and reports are rate-limited per account and IP.

## Moderation
- Reports past a threshold auto-hide a level until an admin reviews it.
- Authors can unlist. Versions are never edited, only superseded.

## Security
- **Uploaded Lua runs on every host.** The sandbox is a guardrail, not a security boundary (`../../TECHNICAL.md`). So the checks and the load test above reject obvious abuse, only hash-verified repository levels run online, and per-call instruction and memory limits stop runaway scripts. Running scripts in a separate process is the long-term goal (`../../NETWORKING.md`, Security and trust).
