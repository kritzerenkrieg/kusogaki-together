# Architecture

How the code is organized and the rules it follows. Code comments stay short and point here; when a rule changes, update this file with the code.

For engine vision, the Lua sandbox, level packages and networking, see `TECHNICAL.md`.

---

## Layout

```text
main.lua              boots LÖVE, registers scenes
scenes/
  gameplay.lua        loads a level and a player, wires update/draw/keys
  title_screen.lua
core/
  level/              a running level; require("core.level") is init.lua
    init.lua            Level.load(name), step order, draw
    loader.lua          level.json + entity scripts → level data
    view.lua            background and static geometry drawing
    entity.lua          base entity: collider, mass, movement, draw
    prop.lua            base carryable prop: ground friction, placeholder draw
    enemies.lua         enemy rules
    blocks.lua          hazard and breakable-block rules
  physics/            AABB physics; require("core.physics") is init.lua
    config.lua          tuning constants
    geometry.lua        overlap tests, contact records
    mass.lua            mass from size, inverse mass
    movement.lua        sweeping bodies against statics
    statics.lua         exits from static overlap
    oneway.lua          props as one-way platforms for the player
    impulse.lua         contact velocity and friction
    collision.lua       dynamic body pairs, full collision pass, push-out
  player/             platformer player; require("core.player") is init.lua
    init.lua            body and update order; public API
    config.lua          key bindings, tuning, animation timing
    controller.lua      input, movement, jump, kick
    carry.lua           grab, drop, throw, held-prop position
    state.lua           state fields, timers, death/respawn
    view.lua            sprite selection and drawing
    feedback.lua        sound and camera shake for player events
  graphics/
    render.lua          virtual resolution
    camera.lua          camera and shake
    fx.lua              scene transitions, debris, corpses
    hud.lua             gameplay HUD
  script.lua          sandboxed loader for entity scripts
  json.lua            JSON decoder
  scenes.lua          scene registry and switching
  audio.lua, controls.lua, math.lua, text.lua
levels/<name>/
  level.json          layout, placements, background
  entities/<type>.lua entity type scripts (sandboxed)
  assets/             images
tests/
  physics_test.lua    headless checks (lua tests/physics_test.lua)
```

Base behavior lives in `core/`; concrete types live in `levels/`.

### Where code goes

- **Scenes** orchestrate only: load a level, create the player, call `update`/`draw`, handle scene keys. No gameplay rules.
- **`core/level/`** owns everything that happens inside a running level. A rule about how two kinds of body interact goes in a rules module (`enemies.lua`, `blocks.lua`, or a new one), called from `Level:update`.
- **`core/physics/`** knows only bodies and statics, never entity kinds (exception: `isPlayer`, for player-specific contact rules).
- **`core/player/`** is the player only; it reads the level it is given but does not own other bodies' rules.
- Presentation (sound, shake, HUD) stays out of rules where possible; the player reports events through `player.onEvent`.

---

## Level

`Level.load(name)` (`core/level/init.lua`) runs the loader and builds a level object. The player and entities receive this object as `level` in `update(delta, level)`.

Fields:
- `name`, `spawn`, `background`
- `geometry`: plain static rectangles from `level.json` (drawing only)
- `statics`: everything bodies collide with as immovable: geometry, hazards and blocks
- `hazards`, `blocks`, `enemies`, `props`: entities by kind

### Data mapping

- **Level package** (`levels/<name>/`): declares spawn, static geometry and entity placements; see `TECHNICAL.md`.
- **Entity types** (`levels/<name>/entities/<type>.lua`): one class per type, defining `name`, `kind` (`"prop"`, `"hazard"`, `"block"` or `"enemy"`), `assetPath`, `w`/`h`, `load()`, `new(x, y)`. The loader injects `Entity` and `Prop` into the sandbox.
- Placements are `{ type, x, y }` in one `entities` list; the type's `kind` picks the list it goes to.
- Collision size belongs to the type (`Type.w`, `Type.h`); placements give position only.
- Placements reference a type by name (`"box"`), never a file path.
- Coordinates are center-based `x, y, w, h` in pixels, matching physics.

### Step order (`Level:update`)

1. Player update (input, carry, kick, movement against statics).
2. Enemy prop hits: a fast prop kills an enemy it overlaps.
3. Prop push-out: props overlapping an enemy are pushed out of it.
4. Enemy update, each against its own solids.
5. Prop update.
6. Dynamic body collisions (player and props), then settle against statics.
7. Hazard touches, block breaking, enemy stomp/touch.
8. Player animation state refresh.

Draw order: background, geometry, hazards, blocks, enemies, props; the scene then draws debris, corpses, the player and the HUD.

---

## Level rules

### Enemies (`core/level/enemies.lua`)

- **Solids:** an enemy walks into statics, loose props and other live enemies, and turns around when blocked sideways.
- **Props are pushed, enemies are not.** When a prop overlaps an enemy (placed or shoved into it), the prop is pushed out and the enemy never moves. A prop still overlapping an enemy is not a solid for it; otherwise it would snap the enemy to one of its faces, which could teleport it into the player.
- **Thrown props kill:** a loose prop faster than `THROWN_KILL_SPEED` that overlaps an enemy kills it like a kick (checked before enemies move, so the corpse starts where the hit happened).
- **Player contact:** landing on an enemy (falling, feet above its top last frame) kills it and bounces the player; any other touch kills the player, unless the player is in kick grace. Kicks kill enemies in `player:update`.
- Dead enemies are removed and leave a corpse (`fx.flatten` for stomps, `fx.throwAway` otherwise).

### Hazards and blocks (`core/level/blocks.lua`)

- Hazards and blocks are statics.
- A hazard hurts only when physics actually blocked the player on it this frame (`player.contacts`). There is no separate touch zone.
- Touching a block is harmless; a block whose `onTouch` returns true (e.g. `brick`, hit from below while rising) or that is `broken` (kicked) is removed from `statics` and breaks into debris.

---

## Physics rules

- **Held props have no physics.** A carried prop is drawn at the hand, overlapping the player's facing edge by 4px. Static and body resolution skip it.
- **Release/throw** moves the prop to touch the player first, so release never shoves the player. If that spot is blocked, the overlap stays.
- **Static exits:** a body overlapping a static takes the cheapest exit (smallest pixel move) that does not land it in another static. Exits are the top face or the face on the side the body is already on. A static never pushes a body downward, and no exit crosses the static. If no exit is clear, the body stays put.
- **Pair corrections:** a body whose corrected position would sit inside a static gets no share; the other body takes the whole correction. If neither can take it, the correction is skipped. Otherwise the player absorbs it, so props take it only when the player is blocked.
- **Resting stacks:** a slow fall onto a support clamps the upper body's vertical speed to the support's, regardless of pair order.
- **Push-out** (`physics.pushOut(mover, fixed, statics)`): moves `mover` out of `fixed` without moving `fixed`. It tries, in order, the exit along the contact axis, then on top of `fixed`, then the opposite side, and takes the first that does not land in a static. Velocity into `fixed` along the push is removed; popping on top grounds `mover`. If every exit is blocked, the overlap stays.
