-- Data that leaves the simulation: the wire format, asset paths, the seeded
-- random generator and downloaded packages.
local Level = require("core.level")
local playerModule = require("core.player")
local netstate = require("core.level.netstate")
local helpers = require("tests.sim.helpers")
local check = helpers.check
local inputAt = helpers.inputAt
local plain = helpers.plain
local run = helpers.run
local EVEN = helpers.EVEN

-- ── Wire format: snapshots and events survive encoding exactly ──────────
do
    local wire = require("core.wire")
    local level = Level.load("example")
    level:addPlayer(playerModule.new(level.spawn.x, level.spawn.y))
    level:addPlayer(playerModule.new(level.spawn.x + 20, level.spawn.y))
    local list = {}
    for tick = 1, 600 do
        for i, player in ipairs(level.players) do
            player.input = inputAt(tick, i)
        end
        level:update(1 / 60)
        for _, event in ipairs(level:takeEvents()) do
            list[#list + 1] = netstate.event(event)
        end
    end
    local snapshot = netstate.snapshot(level, 600)
    local extrasFor = function(id) return level:get(id) and level:get(id).netFields end
    -- nil and false both mean "not set" on the wire (changes s in place)
    local function settled(s)
        for _, list in ipairs({ s.players, s.entities }) do
            for _, record in ipairs(list) do
                for key, value in pairs(record) do
                    if value == false then record[key] = nil end
                end
            end
        end
        return plain(s, "s")
    end
    local generic = wire.encode(snapshot)
    check("generic data survives the wire format", plain(wire.decode(generic), "g") == plain(snapshot, "g"))
    local bytes = wire.encode(netstate.pack(snapshot, extrasFor))
    local decoded = wire.decode(bytes)
    check("a snapshot survives packing and the wire format",
        decoded and settled(netstate.unpack(decoded, extrasFor)) == settled(snapshot))
    check("the same snapshot encodes to the same bytes",
        wire.encode(netstate.pack(netstate.unpack(decoded, extrasFor), extrasFor)) == bytes)
    check("packed snapshots are smaller than generic ones", #bytes < #generic / 2,
        #bytes .. " vs " .. #generic)
    local eventBytes = wire.encode(list)
    check("events survive the wire format", plain(wire.decode(eventBytes), "e") == plain(list, "e"))
    print(string.format("      wire: snapshot %d bytes packed (%d generic; %d entities, %d players), %d events %d bytes",
        #bytes, #generic, #snapshot.entities, #snapshot.players, #list, #eventBytes))

    local truncated = bytes:sub(1, #bytes - 3)
    check("truncated data is rejected", wire.decode(truncated) == nil)
    check("trailing data is rejected", wire.decode(bytes .. "\0") == nil)
    check("an unknown tag is rejected", wire.decode("\9") == nil)
    check("a huge declared length is rejected", wire.decode("\6\255\255\255\127") == nil)
    local deep = string.rep("\7\1\0\0\0\3\1", wire.MAX_DEPTH + 1) .. "\0"
    check("deep nesting is rejected", wire.decode(deep) == nil)
    local _, err = wire.decode(123)
    check("non-strings are rejected", err ~= nil)
end

-- ── Asset paths a script may load ────────────────────────────────────────
do
    local loader = require("core.level.loader")
    local IMAGES = { png = true, jpg = true, jpeg = true }
    local function resolves(path)
        local ok, result = pcall(loader.resolveAsset, "levels/example", path, IMAGES)
        return ok and result
    end
    check("package assets resolve inside the package", resolves("assets/box.png") == "levels/example/assets/box.png")
    check("shared engine graphics resolve", resolves("assets/graphics/entities/spike.png") == "assets/graphics/entities/spike.png")
    check("parent paths are refused", not resolves("../example/assets/box.png") and not resolves("assets/../level.json"))
    check("absolute paths are refused", not resolves("/etc/passwd"))
    check("other file types are refused", not resolves("entities/box.lua"))
    check("missing assets are refused", not resolves("assets/nope.png"))
    check("engine files outside shared graphics are refused", not resolves("assets/audio/sfx/hit.png"))
    check("level names and roots map to roots", loader.rootFor("example") == "levels/example"
        and loader.rootFor("downloads/" .. string.rep("a", 64)) == "downloads/" .. string.rep("a", 64)
        and loader.rootFor("builtin/example") == "builtin/example"
        and not pcall(loader.rootFor, "levels/../x") and not pcall(loader.rootFor, "../x")
        and not pcall(loader.rootFor, "online/" .. string.rep("a", 64)))
end

-- ── Seeded level random ──────────────────────────────────────────────────
do
    local a, b = Level.load("example", { seed = 7 }), Level.load("example", { seed = 7 })
    local c = Level.load("example", { seed = 8 })
    local x, y, z = a.random:random(), b.random:random(), c.random:random()
    check("a level's random follows its seed", x == y and x ~= z)
end

-- ── Downloaded levels: a package of the example level, installed ─────────
do
    local levelpack = require("core.levelpack")
    local levels = require("core.levels")
    local package = levelpack.pack("builtin/example")
    local id = levelpack.sha256(package)
    levels.remove("downloads/" .. id)
    local root = levels.install(id, package)
    check("a package installs at downloads/<id>", root == "downloads/" .. id)
    if root then
        check("... and packs back to the same package", levelpack.pack(root) == package)
        local bundled = run(600, EVEN, 2)
        local downloaded = run(600, EVEN, 2, root)
        check("the downloaded level plays exactly like the bundled one", bundled == downloaded)
        levels.remove(root)
        check("removing a download deletes it", not love.filesystem.getInfo(root))
    end
end
