# Modding

How to make a level: the package, `level.json`, entity type scripts and level scripts, and everything a script can change. Scripts get the real game objects (the level, its players and entities), not a limited API: a level can rewrite the rules, replace how players move, spawn things, move the camera and decide who wins. It can turn the platformer into a different game. `levels/topdown` shows this: a top-down coin race with no gravity.

Engine internals are in `ARCHITECTURE.md`; the sandbox rules in `TECHNICAL.md` (Sandbox); online play in `NETWORKING.md`.

**Where levels go:** the save directory's `levels/` folder (Singleplayer → Open my levels folder; the paths are in `NETWORKING.md`, Level repository). Each level is a folder there. Singleplayer lists them; U uploads one to the server so others can download it and play it in rooms. The game's own levels are copied there at startup; edit a copy and the game leaves it alone. From source: `love2d . --level <name>` plays `levels/<name>` (default `example`).

---

## Package

```text
levels/<name>/
  level.json            layout, placements, settings
  entities/<type>.lua   one entity type per file
  scripts/<script>.lua  level scripts, listed in level.json "scripts"
  assets/               images (.png, .jpg) and sounds (.wav, .ogg, .mp3)
```

Every path a script names is relative to the package (`"assets/box.png"`). A path the package does not have may name the engine's shared art (`"assets/graphics/..."`). Nothing else can be read.

Only these files are part of a level: `level.json`, `entities/<name>.lua`, `scripts/<name>.lua`, and images and sounds under `assets/` (at most 4 folders deep). Other files (notes, source art) may sit in the folder but are not uploaded and do not change the level's id. Limits: 256 files, 16 MB, 200 KB of Lua.

---

## level.json

| Field | Meaning |
|---|---|
| `format` | `1` |
| `name` | the level's name in lists and rooms: letters, digits and `_`, at most 32 (required to upload) |
| `size` | `{ "w", "h" }`: world size in px (default: one screen, 640×360). Falling 32 px below `h` is falling out. |
| `spawn` | `{ "x", "y" }`: where players start (required) |
| `gravity` | px/s² pulling bodies down (default 900); `0` for top-down games, negative pulls up |
| `maxFall` | fastest downward speed in px/s (default 420) |
| `camera` | `{ "follow", "zoom", "x", "y", "clamp" }`; see Camera |
| `actions` | custom input actions; see Input |
| `scripts` | level script names, run in this order |
| `background` | `{ "sky": [r, g, b] }` |
| `music` | the game's music track to play, by file name (`"level1.flac"`); default `"playground.flac"`. Tracks are too big for packages, so a level picks one of the game's. |
| `hud` | `true` shows each player's state line (`P1 RUN  CARRY: -`) in the corner (off by default); level scripts draw their own HUD either way |
| `static` | solid rectangles `{ x, y, w, h, color }` or tiled `{ ..., "tiles": { "top", "fill" } }` |
| `entities` | placements `{ "type", "x", "y", ... }`; the whole placement goes to `Type.new(x, y, def)` |

Coordinates are the center of a box, in px. Each placement's entity gets `id` = its index in `entities`.

---

## Entity types

`entities/<type>.lua` returns a type table. `Entity` and `Prop` (the base classes) are available to it:

```lua
local Coin = setmetatable({}, { __index = Entity })
Coin.__index = Coin
Coin.name = "coin"
Coin.kind = "trigger"
Coin.w, Coin.h = 10, 10

function Coin.new(x, y, def)
    return Entity.new(Coin, x, y, { name = Coin.name, w = Coin.w, h = Coin.h })
end

function Coin:onTouch(player, level)
    level:removeEntity(self)
end

return Coin
```

`kind` decides which rules apply:

| Kind | Rules |
|---|---|
| `prop` | falls, can be carried, kicked and thrown, has ground friction |
| `enemy` | updates once a player is near; stomp, kick and touch rules |
| `hazard` | solid; `onTouch(player)` when it blocks a player (e.g. `player:die()`) |
| `block` | solid; may break when touched from below or kicked |
| `trigger` | never solid; `onTouch(player, level)` while a player overlaps it |

Functions a type may define:

| Function | Called |
|---|---|
| `load()` | once per level load: load images here |
| `new(x, y, def)` | create an instance (`Entity.new(Type, x, y, options)`) |
| `update(delta, level)` | each tick (props, enemies). Enemies get a view of the level whose `statics` also hold loose props and other live enemies (what they bump into); every other field is the level's. |
| `animate(delta)` | each tick (hazards, blocks) |
| `onTouch(player, level)` | triggers: a player overlaps. Enemies and blocks get `onTouch(player)`: return true to kill the player (enemy) or break (block). Hazards get `onTouch(player)` and act themselves. |
| `onStomp(player)` (enemies), `onKick(player)` (enemies, blocks) | return true to be killed or broken |
| `draw(ui)` | draw it (default: its sprite). See Drawing. |
| `netFields` | a list of extra field names clients need for drawing (plain data) |

Base helpers: `self:move(delta, level)` (move without gravity, stop at statics), `self:groundAhead(level, dir)`, `self:playSfx("name.wav")`, `Entity.loadImage(path)`, `Entity.sliceFrames(image, w, h)`. Draw fields: `frameIndex`, `facing`, `rotation`, `flash`. Physics fields: `x, y, w, h, vx, vy, onGround`, and `gravityScale` (gravity multiplier, default 1; 0 floats). `noGrab = true` keeps players from picking it up (a boss).

`id`, `kind` and `typeName` belong to the engine; don't set them.

---

## Level scripts

`scripts/<script>.lua` returns a table of hooks. Each one is optional:

| Hook | Called |
|---|---|
| `load(level)` | once, after the level is built. Set up rules here. |
| `playerJoined(player, level)` | a player joined (also each player at the start) |
| `update(delta, level)` | each tick, in the `scripts` stage (the last one) |
| `message(name, data, level)` | a message sent with `level:send` (on every machine) |
| `drawBehind(ui, level)` | world space, behind the level |
| `drawWorld(ui, level)` | world space, over everything |
| `drawHud(ui, level)` | screen space, over the world |

---

## The level

Fields scripts read and change:

| Field | Meaning |
|---|---|
| `players` | players in join order |
| `props`, `enemies`, `hazards`, `blocks`, `triggers` | entities by kind |
| `statics` | everything solid: geometry, hazards, blocks |
| `byId` | entity id → entity (`level:get(id)`) |
| `width`, `height`, `spawn` | world size and spawn point |
| `gravity`, `maxFall` | change any time |
| `camera` | see Camera |
| `stages` | the simulation step; see Stages |
| `playerController` | how every player moves; see Players |
| `actions`, `actionNames` | custom input actions, and every action name |
| `net` | your level-wide state that clients see (plain data) |
| `types` | entity types loaded so far |
| `random` | the seeded generator (also `random(m, n)` in every script) |
| `finished` | `{ outcome, message }` once the level ended |

Methods:

| Method | Does |
|---|---|
| `level:spawnEntity(type, x, y, def)` | create an entity of `entities/<type>.lua`; returns it. `def` is its placement (plain data). |
| `level:removeEntity(entity)` | take an entity out of the level |
| `level:get(id)` | entity by id |
| `level:finish(outcome, message)` | end the level: `"win"`, `"lose"` or any short word; the game shows the result and offers a restart |
| `level:send(name, data)` | a message for every machine's `message` hooks (during a step; `data` plain) |
| `level:addStage(name, run, where)` | add a step stage; `where` = `{ before = "x" }` or `{ after = "x" }` |
| `level:removeStage(name)` | take a stage out (returns it) |
| `level:replaceStage(name, run)` | swap a stage's function; returns the old one, so you can wrap it |
| `level:findStage(name)` | index and entry |

---

## Stages

Each tick runs `level.stages` in order. Every stage is `{ name, run = function(level, delta) }`, and the list belongs to this level, so a script can change the game's rules:

The built-in stages and what each one does are listed, in order, in `ARCHITECTURE.md` (Step order), from `input` (input edges) and `players` (controllers) to `scripts` (level scripts' `update`). Use their names with the stage methods:

```lua
function game.load(level)
    level:removeStage("enemyTouch")                       -- enemies are harmless
    level:addStage("score", scoreRule, { after = "collisions" })
    local hazards = level:replaceStage("hazards", function(level, delta)
        if not level.net.invincible then hazards(level, delta) end
    end)
end
```

---

## Players

Fields: `id` (1–5), `x, y, w, h, vx, vy, facing, onGround, dead`, `carrying` (what it holds: a prop, enemy or player), `held` / `heldBy` (carried by another player), `knockback` (seconds its input cannot steer), `respawns` (times respawned; kept across restarts, reset on a win), `input` (this tick's frame), `pressed` / `released` (actions that changed this tick), `net` (your per-player state that clients see), `controller`, `gravityScale`. Methods: `player:update(delta, level)` (the platformer), `player:die()`, `player:respawn()`, `player:setSpawn(x, y)`, `player:bounce()`, `player:animate(delta)`, `player:draw()`.

**Controllers** replace how players move. A controller is a table `{ update = function(player, delta, level), draw = function(player, ui, level) }` (both optional). Set `level.playerController` for everyone, or `player.controller` for one player. A controller's `update` takes over the player completely. It may still call `player:update(delta, level)` to run the platformer and add to it. Without `draw`, the platformer sprite is drawn; `player:animate(delta)` keeps it animating.

```lua
local Walker = {}
function Walker.update(player, delta, level)
    local input = player.input or {}
    player.vx = ((input.right and 1 or 0) - (input.left and 1 or 0)) * 110
    player.vy = ((input.down and 1 or 0) - (input.up and 1 or 0)) * 110
    Entity.move(player, delta, level) -- walls still stop it
    player.onGround = true
    player:animate(delta)
end
```

---

## Input

Every level has `left, right, jump, kick, hold`. A level adds its own actions in `level.json`, with one key per keyboard layout (player 1, player 2) and gamepad inputs. Only the first key is used in normal play: player 2's key and the gamepad inputs are for the deprecated couch co-op (`--local-coop`) and are still accepted so levels stay valid:

```json
"actions": [
  { "name": "up",   "keys": ["up", "w"], "gamepad": ["dpup", "leftup"] },
  { "name": "dash", "keys": ["v", "p"],  "gamepad": ["rightshoulder"] }
]
```

Gamepad inputs are button names (`a b x y back start leftstick rightstick leftshoulder rightshoulder dpup dpdown dpleft dpright`), stick directions (`leftup leftdown leftleft leftright`, `rightup ...`) and `triggerleft` / `triggerright`. At most 16 actions. Scripts read `player.input.dash` (held) and `player.pressed.dash` (pressed this tick).

---

## Camera

`level.camera` is read every frame:

| Field | Meaning |
|---|---|
| `follow` | `"players"` (default): the middle of the live players, both axes · `"screens"`: jump a screen at a time · a player or entity: follow it · `nil`: stay at `x, y` |
| `zoom` | 0.25 to 4 (1 = normal) |
| `x`, `y` | center when not following |
| `clamp` | `false` lets the view leave the level |

In `level.json`, `"follow"` is `"players"`, `"screens"` or `"fixed"`.

---

## Drawing

Draw hooks get `ui`. There is no `love`.

| Function | Draws |
|---|---|
| `ui.color(r, g, b, a)` | sets the color |
| `ui.rect(x, y, w, h, mode)` | rectangle (`"fill"` or `"line"`) |
| `ui.circle(x, y, radius, mode)` | circle |
| `ui.line(x1, y1, x2, y2, width)` | line |
| `ui.image(image, x, y, r, sx, sy, ox, oy)` | an image from `Entity.loadImage` |
| `ui.sprite(image, frame, x, y, r, sx, sy, ox, oy)` | a frame from `Entity.sliceFrames` |
| `ui.text(text, x, y, size)`, `ui.textWidth(text, size)` | text |
| `ui.size()` | screen width, height |
| `ui.view()` | the world rectangle in view: x, y, w, h |
| `ui.key(action)` | the player's key for `left`, `right`, `jump`, `hold`, `kick` or `restart`, as shown (`"Z"`); players can change them in Options |

---

## Online play: host and clients

In online play the host simulates the level and every player from their inputs; each client runs the same simulation ahead as a prediction and corrects it with the host's state (hybrid rollback, `NETWORKING.md`). **You write no network code:** a level that works alone works online, as long as:

- **Changing state lives on objects** (players, entities, `level.net`), never in a script's local variables. The engine saves and restores levels to correct predictions: every plain field of every object is saved (references to players and entities included), locals are not. Constants in locals (sizes, speeds, text) are fine.
- **The simulation reads only state and inputs:** player controllers read `player.input` (never the keyboard), and randomness uses `random(m, n)` (seeded by the host, saved with the level). There is no `math.random`.
- Everything runs on every machine (stages, `update`, `onTouch`, controllers, entity scripts, draw hooks). On a client it is a prediction: what it does is replaced by the host's state a moment later, so a client may briefly show something that did not happen on the host.
- One-off things to show (a popup, a sound) go through `level:send(name, data)`; every machine's `message` hook gets them, once per tick even when a client replays it.
- Spawned entities get ids after the placements', in spawn order; a client that did not predict a spawn gets the entity from the host's state.

## Limits

Scripts run in a sandbox (`TECHNICAL.md`, Sandbox):

- **Not available:** files, the OS, the network and `love`.
- **Each call** may run 2 million instructions and grow memory by 64 MB.
- **An error in a type's or level script's own function disables that script**, and the game goes on.
- **Code a script stored elsewhere** (stage functions, controllers, `draw` set at runtime) runs under the same limits. An error there stops the level: the game shows "This level stopped" with a restart.
- **A level that freezes the game for 8 seconds** ends it. A downloaded level that does this is blocked on that machine.
