# Repository

The level repository: players upload levels, browse them and download them. **Built (game 0.4.0): uploads, the list and downloads over plain HTTP, no accounts.** Below that, the Phase 4 design for what is not built yet (accounts, HTTPS, asset normalization, the headless load test, moderation). The package format and what the game does with downloads: `../../NETWORKING.md` (Level repository).

---

## Built

`package.go` (the format and its rules, the same as the game's `core/levelpack.lua`) and `repository.go` (storage and the API), served by `kusogaki-server -data <dir>` over HTTP on the lobby's port number (TCP).

**Package:** the level's files in byte order of their paths, each as `path \0 size \0 contents`; its id is its sha256. Checked on upload:
- only `level.json`, `entities/<name>.lua`, `scripts/<name>.lua` and `assets/...` with `.png .jpg .jpeg .wav .ogg .mp3`; path parts never start with a dot, at most 4 deep, 100 characters;
- files strictly in order, sizes written plainly (no leading zeros), nothing left over;
- at most 256 files, 16 MB, 200 KB of Lua; no compiled Lua (`\27` first);
- images and sounds start with their format's magic bytes;
- `level.json` is JSON with `"format": 1` and a `name` of letters, digits and `_` (at most 32): rooms and the room list carry that name.

**API:**

| Request | Answer |
|---|---|
| `GET /levels?page=N` | `{"page", "pages", "levels": [{"id", "name", "author", "size", "uploaded"}]}`, 8 a page, newest first |
| `GET /levels/{id}/info` | one level, or 404 |
| `GET /levels/{id}` | the package (immutable, cacheable), or 404 |
| `POST /levels` | body: a package; `X-Author`: the player's name (16 printable characters kept). 201 with the level, 200 when it was there already, 400 with `{"error"}` naming what is wrong |

**Storage:** `<dir>/<id>.pkg` and `<dir>/<id>.json` (its description), written through a temporary file and read back at start. At most 5000 levels and 4 GB.

**Limits:** 10 new uploads an hour per address (re-uploading a stored level is free); requests time out (headers 10 s, body 60 s). No addresses in the log.

**Not protected yet:** plain HTTP, so someone on the network path could change the list or block a download. They cannot change a level: the game checks every download against the id it asked for. Uploads are anonymous: anyone can upload, and nothing can be deleted except by hand on the server (delete both files, restart).

---

# Phase 4 design (not built)

Moved here from `NETWORKING.md` (Level repository). Decided: backend in Go (`../../OPEN_DECISION.md`, E4); HTTPS from the bundled `lua-https` module on the game side, since LÖVE 11.5 has no TLS (`../../NETWORKING.md`, HTTPS).

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
2. **Package safety** (built, see above): size caps, no absolute paths or `..`, a file whitelist by folder.
3. **Validation:**
   - `level.json` against a JSON schema; names match `^[%w_]+$`, as the loader already requires.
   - Lua is text only (reject `\27Lua` bytecode) and within size limits.
4. **Asset normalization** (see the table above).
5. **Headless load test:**
   - runs in a container with no network and CPU/memory/time limits;
   - LÖVE with the hardened sandbox loads the level and steps 600 ticks with no input;
   - any error or limit hit rejects the upload with the message.
6. **Storage:**
   - the package goes to S3 at `levels/<sha256>` (built: a directory on the server);
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
