-- Game and network protocol versions. Machines in one session must match both
-- (checked when a client joins; see core/net/session.lua).
return {
    GAME = "0.4.3",
    PROTOCOL = 10,
}
