# Architecture

How the code is organized and the rules it follows. Code comments stay short and point here; when a rule changes, update this file with the code.

For engine vision, the Lua sandbox and level packages, see `TECHNICAL.md`. For online play (repository, lobby, P2P netcode), see `NETWORKING.md`. For what level scripts can do (the modding reference), see `MODDING.md`.

---

## Layout

```text
main.lua              boots LÖVE, registers scenes
scenes/
  gameplay.lua        loads a level and its local player, wires update/draw/keys; network play (--host/--join)
  title_screen.lua
core/
  level/              a running level; require("core.level") is init.lua
    init.lua            Level.load(name), players, spawning, finish, messages, draw
    stages.lua          the step as a per-level list of named stages; script hooks
    loader.lua          level.json + entity scripts → level data
    view.lua            background and static geometry drawing
    ui.lua              drawing API for scripts (world and screen space)
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
    camera.lua          the view from level.camera (follow, zoom, screens) and shake
    fx.lua              scene transitions, debris, corpses
    hud.lua             gameplay HUD
    interp.lua          draw-time blending between fixed ticks
    present.lua         events -> effects, sound and shake
  net/                network play (NETWORKING.md)
    protocol.lua        message types, validation of untrusted bytes, port, addresses
    session.lua         ENet host and client: join handshake, refusals, session messages
  version.lua         game and protocol versions (must match to play together)
  fixedstep.lua       fixed-timestep clock (60 Hz ticks)
  script.lua          the script sandbox: environment, read-only engine views, limits
  watchdog.lua        ends the game when a level freezes it; blocks frozen downloads
  watchdog_thread.lua the watchdog's thread (heartbeat timeout, report, exit)
  json.lua            JSON decode/encode
  wire.lua            binary encoding for network messages (love.data.pack)
  levelpack.lua       level packages: fingerprints, sha256 check, mount at online/<sha256>
  scenes.lua          scene registry and switching
  input.lua           input sources (keyboard layouts, gamepads) → input frames; custom actions
  mathx.lua           math helpers, easing, seeded random (mathx.newRandom)
  audio.lua, text.lua
levels/<name>/        example: the platformer level; topdown: a top-down coin race (MODDING.md)
  level.json          layout, placements, background, gravity, camera, actions
  entities/<type>.lua entity type scripts (sandboxed)
  scripts/<name>.lua  level scripts (sandboxed), listed in level.json "scripts"
  assets/             images and sounds (scripts name them package-relative: "assets/box.png")
tests/
  physics_test.lua    headless physics checks (lua tests/physics_test.lua)
  sandbox_test.lua    one check per sandbox rule, limits, seeded random (luajit/lua)
  json_test.lua       JSON round trips, null, limits (luajit/lua)
  sim_test.lua        headless LÖVE checks (love2d . --sim-test); runs tests/sim/*:
  sim/helpers.lua       stubs, check counter, scripted inputs, the level runner
  sim/determinism.lua   fixed step, ids, same inputs -> same state with 1-5 players
  sim/data.lua          wire format, asset paths, seeded random, packages
  sim/safety.lua        script faults, reachability audit, watchdog
  sim/features.lua      input actions, stages, spawning, gravity, finish, camera, levels/topdown
  sim/scene.lua         the gameplay scene
  sim/net.lua           messages, fingerprints, host and clients over localhost
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

`Level.load(name)` (`core/level/init.lua`) runs the loader and builds a level object. Players join with `level:addPlayer(player)`, which gives them `id` 1..`Level.MAX_PLAYERS` (5) in join order and runs level scripts' `playerJoined` hooks. `level:update(delta)` runs one step for all of them; the scene sets each player's `input` frame before it. Players and entities receive the level as `level` in `update(delta, level)` (enemies get a view of the level whose `statics` are their own solids; every other field reads through to the level).

Scripts get the level itself, not a restricted API: what they may change is listed in `MODDING.md`. The engine keeps everything a level can change on the level object (stages, controller, camera, gravity), never in shared modules, so one level never changes another.

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
- Fields scripts change to reshape the level (`stages`, `gravity`/`maxFall`, `camera`, `actions`, `playerController`, `net`, `finished`, `types`/`nextId`) are described once, in `MODDING.md` (The level). Engine side: `physics.fall(body, level, delta)` applies the gravity (times `body.gravityScale`) everywhere, including debris and corpses (`fx.clearEffects(level)`); `camera.frame(level)` reads the camera; `core/level/stages.lua` runs the stages.

### Level scripts

Level-wide behavior that is not an entity (tutorials, signs, level events) is a level script: `levels/<name>/scripts/<script>.lua`, listed by name in `level.json` as `"scripts": ["tutorial"]`. It runs in the same sandbox as entity scripts and returns a table of optional hooks:

The hooks and their arguments are listed in `MODDING.md` (Level scripts). Engine side: `stages.callHooks(level, name, ...)` calls them in `level.json` order. `load` runs at the end of `Level.load` (a failure fails the load). `playerJoined` runs from `level:addPlayer` under `level:protect`. `update` is the `scripts` stage. `message` runs during event presentation. The draw hooks run inside the scene's protected draw. Scripts have no `love`; `ui` (`core/level/ui.lua`, a read-only view) is their drawing surface, and entities get it as `entity:draw(ui)`.

The example level's controls bar is `levels/example/scripts/tutorial.lua`.

### Entity helpers for scripts

Entity scripts are sandboxed (no `love`, no `require`), so the base `Entity` provides what they need:
- `self:move(delta, level)`: move by velocity without gravity (flyers).
- `self:groundAhead(level, dir)`: is there ground just past the front edge (ledge check).
- `self:playSfx(name)`: play the package's `assets/<name>`, or else the engine's `assets/audio/sfx/<name>` (reported as an `sfx` event); only plain `name.wav|ogg|mp3` names are accepted.
- `Entity.loadImage(path)`: `path` is package-relative (`"assets/box.png"`, `.png`/`.jpg`); a path the package lacks may name the engine's shared art (`"assets/graphics/..."`). See `loader.resolveAsset`.
- `random(m, n)`: the level's seeded generator (same results on every machine for the host's seed). `math.random` is not available.
- `self.gravityScale`: multiplies the level's gravity for this body (0 floats).
- `self.rotation`: draw rotation; `self.flash` (0..1): white silhouette drawn over the sprite.

### Data mapping

- **Level package** (`levels/<name>/`): declares spawn, static geometry and entity placements; see `TECHNICAL.md`.
- **Entity types** (`levels/<name>/entities/<type>.lua`): one class per type, defining `name`, `kind` (`"prop"`, `"hazard"`, `"block"`, `"enemy"` or `"trigger"`), `assetPath`, `w`/`h`, `load()`, `new(x, y)`. The loader injects `Entity` and `Prop` into the sandbox.
- Placements are `{ type, x, y, ... }` in one `entities` list; the type's `kind` picks the list it goes to. The whole placement is passed to `Type.new(x, y, def)`, so a type can read its own instance fields (e.g. `dokan`'s `target`).
- Collision size belongs to the type (`Type.w`, `Type.h`); placements give position only.
- Placements reference a type by name (`"box"`), never a file path.
- Every entity gets `id` = its placement's index in `entities` (stable across loads and machines), `kind` = its type's kind and `typeName`. All three are reserved: scripts must not set them.
- **Spawning:** `level:spawnEntity(typeName, x, y, def)` loads `entities/<typeName>.lua` if needed (`loader.loadType`), creates the entity (`loader.newEntity`), gives it the next id after the placements (`level.nextId`), marks it `spawned`, adds it to its list (and `statics`) and `byId`, and reports a `spawned` event. `def` must be plain data. Spawns outside a step are not reported (a joining client gets them in its full snapshot).
- **Removal:** rules take an entity out of the level only with `level:removeEntity(entity)`, which updates its list, `statics` and `byId` and marks it `removed`.
- Static geometry is drawn as a colored rectangle (`color`, optional `wall`), or tiled when it names tiles from the level's `assets/`: `"tiles": { "top": "grass", "fill": "dirt" }` draws one row of `top` and repeats `fill` below it, starting at the static's top-left corner. With `"randomFill": true`, each full fill tile gets a random rotation and mirror (seeded from the static's placement, so it is the same on every load and for every player); partial edge tiles stay unrotated.
- Coordinates are center-based `x, y, w, h` in pixels, matching physics.

### Step order (`Level:update`)

The scene runs `Level:update` in fixed 1/60 s ticks through `core/fixedstep.lua`, never with the raw frame time; a frame may run zero or several ticks. Drawing blends moving bodies (players, enemies, props) between the last two ticks (`core/graphics/interp.lua`) and puts them back afterwards, so the simulation never sees a blended position. The camera follows the blended players.


A step runs the level's `stages` in order (`core/level/stages.lua`; a copy of the list, so a stage may change it). Each level gets fresh stage entries, and scripts may add, remove, replace or reorder them (`level:addStage`, `removeStage`, `replaceStage`, `findStage`). Finishing the level (`level:finish`) ends the step after the current stage. The built-in stages:

1. `input`: `player.pressed` / `player.released` edges for every action name.
2. `players`: each player's controller, in join order: its own `controller.update`, else `level.playerController.update`, else `player:update` (the platformer: input frame, carry, kick, movement against statics).
3. `propHits`: a fast prop kills an enemy it overlaps. `propPushOut`: props overlapping an enemy are pushed out of it.
4. `enemies`: enemy updates, each seeing its own solids and the players.
5. `props`: prop updates; `animateBlocks`: hazard/block `animate`.
6. `collisions`: dynamic body collisions (live players in join order, then props), then settle against statics.
7. `triggers`, `hazards`, `breakBlocks`, `enemyTouch`: trigger touches, hazard touches, block breaking, enemy stomp/touch.
8. `detonations`, `enemyDeaths`, `bounds`: detonated props explode; dead and detonated enemies removed (corpse or explosion); fallen bodies handled.
9. `playerAnimation`: animation state refresh for players on the platformer controller.
10. `scripts`: level scripts' `update`.

Draw order: background (screen space); then, in world space inside `camera.pushWorld()`, level scripts' `drawBehind`, geometry, triggers, hazards, blocks, enemies, props, debris, corpses, the players (`level:drawPlayers`, player 1 on top, through a controller's `draw` when it has one), explosions and level scripts' `drawWorld`; then, in screen space, level scripts' `drawHud` and the HUD. The scene calls `camera.frame(level)` at draw time, after blending: by default it centers the midpoint of the live players' extent on both axes, clamped to the level (see `MODDING.md`, Camera).

### Protected phases

`Level:update`, the scene's drawing and event presentation each run under `script.protect` (`level:protect(fn, ...)`): script code inside them has instruction and memory limits even when the engine reaches it indirectly (a function a script stored on an entity, a metamethod). If a phase fails, `level:fault(message)` stops the level for good: `update` and `protect` return false from then on, and the scene draws "This level stopped" with R (restart) and ESC (menu). Engine errors in a phase also fault the level (with a traceback in the console) rather than crash the game. See `TECHNICAL.md` (Sandbox).

A hang the limits cannot see (a slow built-in C function) is caught by the watchdog (`core/watchdog.lua`): `love.update` sends it a heartbeat every frame, and the gameplay scene tells it which level runs (`watchdog.enter(root)` before loading, `watchdog.leave()` when the scene exits). See `TECHNICAL.md` (Sandbox: watchdog).

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
| `spawned` | `level:spawnEntity` | id, typeName, x, y, def | nothing (network bookkeeping) |
| `message` | `level:send` | name, data | level scripts' `message` hooks |
| `finish` | `level:finish` | outcome, message | nothing (the scene draws the result from `level.finished`) |

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

- Triggers are never solid. Every step, each live player overlapping one calls `trigger:onTouch(player, level)`. The list is copied first, so a trigger may remove itself (a pickup) or spawn others.
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
- **Players kick and carry players, never lethally.** A kick knocks the other player back (`playerKickPush`, `playerKickLift`) and for `knockbackTime` their input cannot steer (friction still applies). Grab picks up a free player like a prop (`held`, `heldBy`); kick while carrying throws them, with the same knockback. A carried player is helpless (no move, jump, kick or grab) until the carrier drops or throws them, by design. No chains: a player who carries or is carried cannot be grabbed. A death on either side ends the hold. Enemies still hurt a carried player.
- **Players stand on players.** A player is a one-way platform for another player, just like a prop (`oneway.playerPair` makes the higher player the lander). Walking under someone does not carry them along.
- **Resting stacks:** a slow fall onto a support clamps the upper body's vertical speed to the support's, regardless of pair order.
- **Push-out** (`physics.pushOut(mover, fixed, statics)`): moves `mover` out of `fixed` without moving `fixed`. It tries, in order, the exit along the contact axis, then on top of `fixed`, then the opposite side, and takes the first that does not land in a static. Velocity into `fixed` along the push is removed; popping on top grounds `mover`. If every exit is blocked, the overlap stays.

---

## Local players

- `scenes/gameplay.lua` keeps one slot per local player: an input source (`core/input.lua`) and the player it drives. Player 1 is keyboard layout 1 (arrows, Z jump, X grab, C kick, R restart vote).
- **One player per machine, on the keyboard.** Multiplayer is network play. Gamepads are deprecated for now (only used with `--local-coop`). Local couch co-op below is **deprecated** and only on with `love2d . --local-coop`; it is kept working, not extended.
- **Joining (deprecated, `--local-coop` only):** press J (keyboard layout 2: A/D move, J jump, K grab, L kick, E restart vote; W/S for levels with up/down actions) or A/Start on a gamepad (D-pad or left stick, A jump, X grab, B/Y kick). Up to 5 players; each device joins once.
- Each player has a tint (`config.TINTS`, player 1 untinted). The HUD lists every local player's state and draws an arrow at the screen edge for any player outside the view.
- **Local vs remote:** the scene's slots are this machine's players (`localIds()`, every player in local play). The camera, the HUD corner, shake and full sound follow them; a remote player's events (network play) get positional sound only (`present.soundAt`). See `NETWORKING.md` (N players).
- Input sources read the level's custom actions too (`source.read(level.actions)`): each action names a key per keyboard layout and gamepad buttons, stick directions or triggers.
- The scene shows a banner over a stopped level ("This level stopped") or a finished one (`LEVEL CLEAR`, `GAME OVER`, or the outcome word, with the level's message).
- **Restart vote:** each player toggles a vote (R for layout 1; with `--local-coop` also E for layout 2 and Back on a gamepad). The HUD shows which players voted. While more than half the players vote, a 5 s countdown runs and then the level restarts; dropping to half or fewer cancels it. A restart clears the votes.
- **Network play:** `love2d . --host` opens a session (UDP port 26967); `love2d . --join <ip[:port]>` joins one. Player ids are stable for the session (`level:addPlayer(player, id)`), so a remote player keeps its id across restarts; remote players are in `level.players` but not in the slots. A client waits for the host's welcome before it has a level. ESC to the main menu ends the session. Design and status: `NETWORKING.md`, `DEVELOPMENT_PHASE.md`.
- **Restart seed:** this machine is the host and the source of truth (`NETWORKING.md`, Source of truth). It picks each (re)start's seed, queues a `restart{seed}` session message (`gameplay.takeOutbox`) and restarts through `gameplay.restart(seed)`, the same call a client makes on that message; it refuses anything but a whole number in 1..2147483646. The level keeps its seed as `level.seed`.
- **Respawn count:** `player.respawns` counts respawns (`core/player/state.lua`). A restart carries each slot's count to its new player; winning (`level:finish("win")`) resets every count (`gameplay.resetRespawns`).
- `love2d . --level <name>` plays another bundled level (default `example`).

