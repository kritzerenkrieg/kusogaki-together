-- Tuning constants for the shared physics. Changing a value changes every body.
return {
    gravity = 900,             -- px/s^2 pulling bodies down
    maxFall = 420,             -- terminal fall speed (px/s)
    restitution = 0.35,        -- bounciness for dynamic body collisions
    restingSpeed = 70,         -- vertical speed below this settles instead of bouncing
    contactFriction = 0.35,    -- tangential damping while resting on another body
}
