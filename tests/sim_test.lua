-- Headless simulation checks on a real level: the fixed timestep and
-- determinism (same inputs -> same state). Needs LÖVE for the filesystem and
-- image decoding, but no window. Run from the project root:
--   love2d . --sim-test
-- Graphics and audio are disabled (conf.lua); tests/sim/helpers.lua stubs them.
-- The checks live in tests/sim/, one file per topic.
local helpers = require("tests.sim.helpers") -- first: installs the stubs

-- The levels as on a fresh install: the built-in ones copied into the
-- test save directory (conf.lua gives tests their own).
local levelpack = require("core.levelpack")
for _, path in ipairs({ "levels", "downloads", "seeded_levels.json" }) do
    levelpack.removeTree(path)
end
require("core.levels").seed()

for _, part in ipairs({ "levels", "determinism", "players", "data", "safety", "features", "scene", "net", "rollback",
    "online" }) do
    require("tests.sim." .. part)
end

print(helpers.failures == 0 and "all sim checks passed" or (helpers.failures .. " sim check(s) failed"))
love.event.quit(helpers.failures == 0 and 0 or 1)
