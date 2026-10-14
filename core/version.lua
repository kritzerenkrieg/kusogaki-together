-- Game and network protocol versions. Machines in one session must match both
-- (checked when a client joins; see core/net/session.lua).
return {
    GAME = "0.1.8",
    PROTOCOL = 4,
}
