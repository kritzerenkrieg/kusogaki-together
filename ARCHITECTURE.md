# Architecture

How the code is organized and the rules it follows. Code comments stay short and point here; when a rule changes, update this file with the code.

For engine vision, the Lua sandbox and level packages, see `TECHNICAL.md`. For online play (repository, lobby, P2P netcode), see `NETWORKING.md`.

---

## Layout

```text
main.lua              boots LÖVE, registers scenes
scenes/
  gameplay.lua        loads a level and its local players, wires update/draw/keys/join
  title_screen.lua
core/
  level/              a running level; require("core.level") is init.lua
    init.lua            Level.load(name), step order, draw
    loader.lua          level.json + entity scripts → level data
    view.lua            background and static geometry drawing
    ui.lua              screen-space drawing API for level scripts
    entity.lua          base entity: collider, mass, movement, draw
    prop.lua            base carryable prop: ground friction, placeholder draw
    enemies.lua         enemy rules
    blocks.lua          hazard and breakable-block rules
    bounds.lua          falling out of the level
    blast.lua           explosions: who dies in a blast radius
    events.lua          the step's event queue (rules report, presentation consumes)
    netstate.lua        net state: snapshot fields per player/entity, wire form of events
    props.lua           prop rules (detonating props)
    triggers.lua        non-solid triggers touched by players
  physics/            AABB physics; require("core.physics") is init.lua
    config.lua          tuning constants
    geometry.lua        overlap tests, contact records
    mass.lua            mass from size, inverse mass
    movement.lua        sweeping bodies against statics
    statics.lua         exits from static overlap
    oneway.lua          props and players as one-way platforms for a player
    impulse.lua         contact velocity and friction
    collision.lua       dynamic body pairs, full collision pass, push-out
  player/             platformer player; require("core.player") is init.lua
    init.lua            body and update order; public API
    config.lua          key bindings, tuning, animation timing
    controller.lua      input, movement, jump, kick
    carry.lua           grab, drop, throw, held-prop position
    state.lua           state fields, timers, death/respawn
    view.lua            sprite selection and drawing
    feedback.lua        sound and camera shake for player events (called by present.lua)
  graphics/
    render.lua          virtual resolution
    camera.lua          horizontal follow (clamped to the level) and shake
    fx.lua              scene transitions, debris, corpses
    hud.lua             gameplay HUD
    interp.lua          draw-time blending between fixed ticks
    present.lua         events -> effects, sound and shake
  fixedstep.lua       fixed-timestep clock (60 Hz ticks)
  script.lua          the script sandbox: environment, read-only engine views, limits
  json.lua            JSON decode/encode
  wire.lua            binary encoding for network messages (love.data.pack)
  levelpack.lua       downloaded level packages: sha256 check, mount at online/<sha256>
  scenes.lua          scene registry and switching
  input.lua           input sources (keyboard layouts, gamepads) → input frames
  mathx.lua           math helpers, easing, seeded random (mathx.newRandom)
  audio.lua, text.lua
levels/<name>/
  level.json          layout, placements, background
  entities/<type>.lua entity type scripts (sandboxed)
  scripts/<name>.lua  level scripts (sandboxed), listed in level.json "scripts"
  assets/             images and sounds (scripts name them package-relative: "assets/box.png")
tests/
  physics_test.lua    headless physics checks (lua tests/physics_test.lua)
  sandbox_test.lua    one check per sandbox rule, limits, seeded random (luajit/lua)
  json_test.lua       JSON round trips, null, limits (luajit/lua)
  sim_test.lua        headless level runs with 1-5 players: fixed step, determinism, events,
                      wire format, asset paths, packages (love2d . --sim-test)
  run.sh              every suite under every interpreter (sh tests/run.sh)
```

Base behavior lives in `core/`; concrete types live in `levels/`.

### Where code goes

- **Scenes** orchestrate only: load a level, create the players, feed them input frames, call `update`/`draw`, handle scene keys. No gameplay rules.
- **`core/level/`** owns everything that happens inside a running level. A rule about how two kinds of body interact goes in a rules module (`enemies.lua`, `blocks.lua`, or a new one), called from `Level:update`.
- **`core/physics/`** knows only bodies and statics, never entity kinds (exception: `isPlayer`, for player-specific contact rules).
- **The simulation reads input frames only** (`player.input`, `{ left, right, jump, kick, hold }`), never a device. `core/input.lua` turns devices into frames; network play will too.
- **`core/player/`** is the player only; it reads the level it is given but does not own other bodies' rules.
- **Rules never call `fx`, `audio` or `camera`.** They report events (`core/level/events.lua`); the scene hands each step's events to `core/graphics/present.lua`. See Events.

---

## Level

`Level.load(name)` (`core/level/init.lua`) runs the loader and builds a level object. Players join with `level:addPlayer(player)`, which gives them `id` 1..`Level.MAX_PLAYERS` (5) in join order. `level:update(delta)` runs one step for all of them; the scene sets each player's `input` frame before it. Players and entities receive the level as `level` in `update(delta, level)`.

Fields:
- `name`, `spawn`, `background`
- `width`, `height`: world size in px, from `level.json` `"size": { "w", "h" }` (default: one screen). The camera stays inside `width`; falling below `height` is falling out.
- `geometry`: plain static rectangles from `level.json` (drawing only)
- `statics`: everything bodies collide with as immovable: geometry, hazards and blocks
- `byId`: entity id -> entity, for every entity still in the level (`level:get(id)`)
- `root`: the package root (`levels/<name>` or `online/<sha256>`)
- `random`: the level's seeded generator (`mathx.newRandom(seed)`); `Level.load(nameOrRoot, { seed })`, a new seed per (re)start
- `hazards`, `blocks`, `enemies`, `props`, `triggers`: entities by kind
- `scripts`: level script hook tables, in `level.json` order
- `players`: the players in join order. Every rule loops over them in this order, so when two players affect the same thing in one step, the earlier one wins (e.g. who breaks a block).

### Level scripts

Level-wide behavior that is not an entity (tutorials, signs, level events) is a level script: `levels/<name>/scripts/<script>.lua`, listed by name in `level.json` as `"scripts": ["tutorial"]`. It runs in the same sandbox as entity scripts and returns a table of optional hooks:

- `update(delta)`: called at the end of every `Level:update`.
- `drawHud(ui)`: screen-space overlay, drawn after the world and before the core HUD. Scripts have no `love`; `ui` (`core/level/ui.lua`) is their drawing surface: `ui.size()`, `ui.color(r, g, b, a)`, `ui.rect(x, y, w, h)`, `ui.text(str, x, y, size)`, `ui.textWidth(str, size)`.

The example level's controls bar is `levels/example/scripts/tutorial.lua`.

### Entity helpers for scripts

Entity scripts are sandboxed (no `love`, no `require`), so the base `Entity` provides what they need:
- `self:move(delta, level)`: move by velocity without gravity (flyers).
- `self:groundAhead(level, dir)`: is there ground just past the front edge (ledge check).
- `self:playSfx(name)`: play the package's `assets/<name>`, or else the engine's `assets/audio/sfx/<name>` (reported as an `sfx` event); only plain `name.wav|ogg|mp3` names are accepted.
- `Entity.loadImage(path)`: `path` is package-relative (`"assets/box.png"`, `.png`/`.jpg`); a path the package lacks may name the engine's shared art (`"assets/graphics/..."`). See `loader.resolveAsset`.
- `random(m, n)`: the level's seeded generator (same results on every machine for the host's seed). `math.random` is not available.
- `self.rotation`: draw rotation; `self.flash` (0..1): white silhouette drawn over the sprite.

### Data mapping

- **Level package** (`levels/<name>/`): declares spawn, static geometry and entity placements; see `TECHNICAL.md`.
- **Entity types** (`levels/<name>/entities/<type>.lua`): one class per type, defining `name`, `kind` (`"prop"`, `"hazard"`, `"block"`, `"enemy"` or `"trigger"`), `assetPath`, `w`/`h`, `load()`, `new(x, y)`. The loader injects `Entity` and `Prop` into the sandbox.
- Placements are `{ type, x, y, ... }` in one `entities` list; the type's `kind` picks the list it goes to. The whole placement is passed to `Type.new(x, y, def)`, so a type can read its own instance fields (e.g. `dokan`'s `target`).
- Collision size belongs to the type (`Type.w`, `Type.h`); placements give position only.
- Placements reference a type by name (`"box"`), never a file path.
- Every entity gets `id` = its placement's index in `entities` (stable across loads and machines) and `kind` = its type's kind. Both are reserved: scripts must not set them.
- **Removal:** rules take an entity out of the level only with `level:removeEntity(entity)`, which updates its list, `statics` and `byId` and marks it `removed`.
- Static geometry is drawn as a colored rectangle (`color`, optional `wall`), or tiled when it names tiles from the level's `assets/`: `"tiles": { "top": "grass", "fill": "dirt" }` draws one row of `top` and repeats `fill` below it, starting at the static's top-left corner. With `"randomFill": true`, each full fill tile gets a random rotation and mirror (seeded from the static's placement, so it is the same on every load and for every player); partial edge tiles stay unrotated.
- Coordinates are center-based `x, y, w, h` in pixels, matching physics.

### Step order (`Level:update`)

The scene runs `Level:update` in fixed 1/60 s ticks through `core/fixedstep.lua`, never with the raw frame time; a frame may run zero or several ticks. Drawing blends moving bodies (players, enemies, props) between the last two ticks (`core/graphics/interp.lua`) and puts them back afterwards, so the simulation never sees a blended position. The camera follows the blended players.


1. Player updates, in join order (input frame, carry, kick, movement against statics).
2. Enemy prop hits: a fast prop kills an enemy it overlaps.
3. Prop push-out: props overlapping an enemy are pushed out of it.
4. Enemy update, each seeing its own solids and the players (`{ statics, players }`).
5. Prop update, then hazard/block `animate`.
6. Dynamic body collisions (live players in join order, then props), then settle against statics.
7. Trigger touches, hazard touches, block breaking, enemy stomp/touch.
8. Detonated props explode; dead and detonated enemies removed (corpse or explosion); fallen bodies handled (`bounds`).
9. Player animation state refresh.
10. Level scripts' `update`.

Draw order: background (screen space); then, in world space inside `camera.pushWorld()`, geometry, triggers, hazards, blocks, enemies, props, debris, corpses, the players (player 1 on top) and explosions; then, in screen space, level scripts' `drawHud` and the HUD. The scene calls `camera.follow` at draw time, after blending, on the midpoint between the leftmost and rightmost live player.

### Protected phases

`Level:update`, the scene's drawing and event presentation each run under `script.protect` (`level:protect(fn, ...)`): script code inside them has instruction and memory limits even when the engine reaches it indirectly (a function a script stored on an entity, a metamethod). If a phase fails, `level:fault(message)` stops the level for good: `update` and `protect` return false from then on, and the scene draws "This level stopped" with R (restart) and ESC (menu). Engine errors in a phase also fault the level (with a traceback in the console) rather than crash the game. See `TECHNICAL.md` (Sandbox).

### Events

Rules report what happened instead of showing it. During `Level:update`, `events.emit(event)` appends to `level.events`; `level:takeEvents()` hands the list over and empties it. After every tick the scene passes the list to `present.all(events, level)`, which draws effects, plays sounds and shakes the camera. Network play will send the same events to clients (`netstate.event` strips the local-only `entity` field).

| Event | Reported by | Fields | Presented as |
|---|---|---|---|
| `explosion` | explosive blocks, `blast.explode` | id, x, y, w, h | voxel blast + `debris.wav` |
| `debris` | broken blocks | id, x, y, w, h | debris chips + `debris.wav` |
| `corpse` | dead enemies | id, x, y, w, h, `cause` (stomp, kick, blast), vx, vy | flattened or thrown-away corpse; `hit.wav` unless the cause is a blast |
| `sfx` | `Entity:playSfx` | id, x, y, name | the sound |
| `player` | player state (`state.emit`) | player (id), name (jump, land, kick, kickHit, throw, grab, drop, stomp, death, respawn), x, y | `feedback.onEvent`: sound and shake |
| `removed` | `level:removeEntity` | id | nothing (network bookkeeping) |

Entity events also carry `entity`, the object itself, for local presentation (image, sprite region).

---

## Level rules

### Enemies (`core/level/enemies.lua`)

- **Wake-up:** an enemy does not update until a live player comes within `WAKE_DISTANCE` (one screen width, 640px) horizontally; then it stays awake. Uses player positions, not the camera, so it works for every player in multiplayer.
- **Solids:** an enemy walks into statics, loose props and other live enemies, and turns around when blocked sideways. A `dodon` also turns around at a ledge (`Entity:groundAhead`), so it never walks off an edge on its own; thrown or knocked off, it still falls.
- **Props are pushed, enemies are not.** When a prop overlaps an enemy (placed or shoved into it), the prop is pushed out and the enemy never moves. A prop still overlapping an enemy is not a solid for it; otherwise it would snap the enemy to one of its faces, which could teleport it into the player.
- **Thrown props kill:** a loose prop faster than `THROWN_KILL_SPEED` that overlaps an enemy kills it like a kick (checked before enemies move, so the corpse starts where the hit happened).
- **Player contact:** landing on an enemy (falling, feet above its top last frame) kills it and bounces the player; any other touch kills the player, unless the player is in kick grace. Kicks kill enemies in `player:update`.
- Dead enemies are removed and leave a corpse (`fx.flatten` for stomps, `fx.throwAway` otherwise).
- **Detonation:** an enemy that sets `detonated` is removed and explodes (see Blasts).
- **`dokan` (precision missile):** hovers at its spawn until a player enters its trigger circle (`trigger.radius`, centered on `target` unless `trigger.x/y` are given; radius 0 makes it a dormant pickup that never fires on its own), then instantly launches at full speed (500px/s, no lock-on or acceleration) and flies straight to `target` and detonates there, or on the first static, prop or enemy it hits. Touching an armed one sets it off. Stomp, kick or a thrown prop kills it. Grabbing it (even mid-flight) makes it a weapon: thrown faster than `armSpeed` it falls like a thrown body and detonates on its first contact with a static, prop, enemy or player; dropped gently it is a harmless dud that can be grabbed and thrown again.

### Blasts (`core/level/blast.lua`)

- `blast.explode(level, source, players)` plays `fx.explosion` at `source` and kills every player and every other live enemy within `source.blastRadius` (measured to the nearest point of their box); enemies are thrown away from the blast. Used by detonating enemies and props.

### Props (`core/level/props.lua`)

- A prop that sets `detonated` is removed and explodes (see Blasts). A player still holding it lets go first, then the blast applies as usual (the holder is normally inside it).
- **`fake_box`:** looks exactly like `box` (its `name` is `"box"`, so the HUD does not give it away). The first grab lights a 3 s fuse that keeps running when dropped or thrown: it beeps (`beep.wav`) with the gap shrinking from 0.5 s to 0.08 s, flashing white on each beep, then detonates with a 24 px blast.

### Triggers (`core/level/triggers.lua`)

- Triggers are never solid. Every step, each live player overlapping one calls `trigger:onTouch(player)`.
- **`checkpoint`:** sets that player's respawn point (`player:setSpawn`) to stand at the pole, and the first touch raises the flag (frame 2) and plays `checkpoint.wav`. Each player keeps their own respawn point. Restarting the level (R) builds a new level and new players (same devices), so checkpoints never survive a restart; dying respawns at the last checkpoint touched. A player who joins mid-level starts at player 1's current respawn point.

### Bounds (`core/level/bounds.lua`)

- A player whose top falls more than 32px below `level.height` dies (pits). Props and enemies that fall out are removed silently.

### Hazards and blocks (`core/level/blocks.lua`)

- Hazards and blocks are statics. They never get `update()` (`Entity:update` would apply gravity); a type that animates defines `animate(delta)`, called every step after props update (e.g. `mystery_boom`'s idle shimmer).
- A hazard hurts only when physics actually blocked the player on it this frame (`player.contacts`). There is no separate touch zone.
- Touching a block is harmless; a block whose `onTouch` or `onKick` returns true (e.g. `brick`, hit from below while rising, or kicked) records that player as `brokenBy`, is removed from `statics` and breaks into debris.
- An `explosive` block (e.g. `fake_brick`, which looks exactly like `brick`, and `mystery_boom`, a "?" block) breaks on any contact or kick: it explodes (`fx.explosion`: debris, voxel blast, shake), kills the player who set it off (`block.brokenBy`, the kicker or toucher; never other players), and is removed like any broken block.

---

## Physics rules

- **Held props have no physics.** A carried prop is drawn at the hand, overlapping the player's facing edge by 4px. Static and body resolution skip it.
- **Release/throw** moves the prop to touch the player first, so release never shoves the player. If that spot is blocked, the overlap stays.
- **Static exits:** a body overlapping a static takes the cheapest exit (smallest pixel move) that does not land it in another static. Exits are the top face or the face on the side the body is already on. A static never pushes a body downward, and no exit crosses the static. If no exit is clear, the body stays put.
- **Pair corrections:** a body whose corrected position would sit inside a static gets no share; the other body takes the whole correction. If neither can take it, the correction is skipped. Otherwise the player absorbs it, so props take it only when the player is blocked. Two players share it by mass, so they push each other equally.
- **Players stand on players.** A player is a one-way platform for another player, just like a prop (`oneway.playerPair` makes the higher player the lander). Walking under someone does not carry them along.
- **Resting stacks:** a slow fall onto a support clamps the upper body's vertical speed to the support's, regardless of pair order.
- **Push-out** (`physics.pushOut(mover, fixed, statics)`): moves `mover` out of `fixed` without moving `fixed`. It tries, in order, the exit along the contact axis, then on top of `fixed`, then the opposite side, and takes the first that does not land in a static. Velocity into `fixed` along the push is removed; popping on top grounds `mover`. If every exit is blocked, the overlap stays.

---

## Local players

- `scenes/gameplay.lua` keeps one slot per local player: an input source (`core/input.lua`) and the player it drives. Player 1 is keyboard layout 1 (arrows, Z jump, X grab, C kick).
- **Joining:** press I (keyboard layout 2: J/L move, I jump, U grab, O kick) or A/Start on a gamepad (D-pad or left stick, A jump, X grab, B/Y kick). Up to 5 players; each device joins once.
- Each player has a tint (`config.TINTS`, player 1 untinted). The HUD lists every player's state and draws an arrow at the screen edge for a player outside the view.

