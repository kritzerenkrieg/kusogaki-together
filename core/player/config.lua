-- Player tuning: key bindings, movement/jump/kick/carry values, animation timing.
-- Bindings: Z = jump, X = kick (throws the carried prop), C = hold (grab & carry).
return {
    KEYS = {
        left  = "left",
        right = "right",
        jump  = "z",
        kick  = "c",
        hold  = "x",
    },

    CONFIG = {
        width          = 12,   -- collision box width (px), default for new players
        height         = 24,   -- collision box height (px), default for new players
        moveSpeed      = 120,  -- max horizontal speed (px/s)
        groundAccel    = 1000,
        groundFriction = 600,
        airAccel       = 500,
        airFriction    = 200,
        jumpVelocity   = -360, -- initial jump impulse (px/s)
        jumpCut        = 0.45, -- velocity multiplier when Z is released early
        coyoteTime     = 0.09, -- grace period to jump after leaving a ledge
        jumpBuffer     = 0.10, -- grace period for pressing Z just before landing
        kickDuration   = 0.16, -- how long the kick hitbox stays active (s)
        kickCooldown   = 0.30, -- minimum time between kicks (s)
        kickGrace      = 0.20, -- after a kick, enemy touches do not kill (s)
        kickReach      = 20,   -- hitbox width in front of the player
        kickHeight     = 20,   -- hitbox height
        kickPush       = 260,  -- horizontal impulse applied to kicked props
        kickLift       = -90,  -- vertical impulse applied to kicked props
        enemyKickPush  = 260,  -- horizontal launch of a kicked enemy (px/s)
        enemyKickLift  = -90,  -- vertical launch of a kicked enemy (px/s)
        throwSpeed     = 260,  -- forward speed of a thrown prop
        throwArc       = -140, -- upward speed of a thrown prop
        grabForward    = 20,   -- distance in front of the player for the grab box
        grabRange      = 30,   -- size of the grab search box
        deathJump      = -380, -- upward pop when the player dies (px/s)
        respawnDelay   = 1.2,  -- time after death before respawning (s)
    },

    -- Animation timing (s). One sprite frame lasts `frame`.
    ANIM = {
        frame    = 0.2,
        kick     = 0.4, -- two frames
        longIdle = 5,   -- idle time before the long-idle animation starts
    },
}
