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

return mathx