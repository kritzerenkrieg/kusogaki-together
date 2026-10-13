-- Shared math / easing helpers used across the core modules.
local mathx = {}

-- Clamp x into [min, max].
function mathx.clamp(x, min, max)
    return math.max(min, math.min(max, x))
end

-- Linear interpolation from a to b by t (t clamped to [0, 1]).
function mathx.lerp(a, b, t)
    return a + (b - a) * mathx.clamp(t, 0, 1)
end

-- Move x toward target by at most delta, never overshooting.
function mathx.approach(x, target, delta)
    if x < target then
        return math.min(x + delta, target)
    end
    return math.max(x - delta, target)
end

mathx.easings = {
    linear     = function(t) return t end,
    easein     = function(t) return t * t end,
    easeout    = function(t) return 1 - (1 - t) * (1 - t) end,
    easeinout  = function(t) return t < 0.5 and 2 * t * t or 1 - (-2 * t + 2) ^ 2 / 2 end,
    smoothstep = function(t)
        t = mathx.clamp(t, 0, 1)
        return t * t * (3 - 2 * t)
    end,
}

-- Smoothstep easing: eases t from 0 to 1 with a smooth ramp.
function mathx.smoothstep(t)
    return mathx.easings.smoothstep(t)
end

-- ── Seeded random numbers ─────────────────────────────────────────────────
-- Gameplay randomness must give the same numbers on every machine for the
-- same seed (see NETWORKING.md, Seeded RNG), so this is plain Lua arithmetic,
-- not math.random or love.math: a Lehmer generator (MINSTD, multiplier 48271,
-- modulus 2^31 - 1). Every intermediate product stays below 2^53, so the
-- results are exact in doubles under Lua 5.1 and LuaJIT alike.
-- Cosmetic effects (debris, shake) keep using love.math.random.

local MODULUS = 2147483647
local MULTIPLIER = 48271

local Random = {}
-- Scripts reach generators through the level: a separate, protected metatable
-- keeps the class out of reach (see Level's LEVEL_META).
local RANDOM_META = { __index = Random, __metatable = false }

-- Any number or string seed maps to a state in [1, MODULUS - 1].
local function seedState(seed)
    local value
    if type(seed) == "string" then
        value = 0
        for i = 1, #seed do
            value = (value * 31 + seed:byte(i)) % MODULUS
        end
    else
        value = math.floor(math.abs(tonumber(seed) or 0)) % MODULUS
    end
    if value == 0 then
        value = 1
    end
    return value
end

function mathx.newRandom(seed)
    return setmetatable({ state = seedState(seed) }, RANDOM_META)
end

-- Like math.random: no arguments gives [0, 1); random(n) an integer in
-- [1, n]; random(m, n) an integer in [m, n].
function Random:random(m, n)
    self.state = (self.state * MULTIPLIER) % MODULUS
    local unit = (self.state - 1) / (MODULUS - 1) -- [0, 1)
    if m == nil then
        return unit
    end
    if n == nil then
        m, n = 1, m
    end
    m, n = math.floor(m), math.floor(n)
    assert(m <= n, "random: empty interval")
    return m + math.floor(unit * (n - m + 1))
end

-- The generator's state, for snapshots; setState restores it exactly.
function Random:getState()
    return self.state
end

function Random:setState(state)
    self.state = seedState(state)
end

return mathx