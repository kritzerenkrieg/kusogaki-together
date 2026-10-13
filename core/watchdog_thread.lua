-- Watchdog thread (started by core/watchdog.lua). It waits for heartbeats from
-- the main thread. When a level is running and no heartbeat arrives for
-- `timeout` seconds, the game is frozen inside something the in-process limits
-- cannot interrupt (a slow built-in C function): the thread writes a report
-- naming the level to the save directory and ends the process. The next launch
-- reads the report (watchdog.start).
--
-- Messages on the "watchdog" channel: "beat", "enter:<root>", "leave", "stop".
require("love.timer")
require("love.filesystem")

local timeout, reportFile, exitOnFreeze = ...
local inbox = love.thread.getChannel("watchdog")
local outbox = love.thread.getChannel("watchdog_out")

-- End the process at once. _exit skips atexit handlers, which could wait on
-- the frozen main thread; os.exit is the fallback.
local function hardExit()
    local ok, ffi = pcall(require, "ffi")
    if ok then
        pcall(ffi.cdef, "void _exit(int status);")
        pcall(function() ffi.C._exit(3) end)
    end
    os.exit(3)
end

local root     -- the running level's package root, or nil between levels
local lastBeat = love.timer.getTime()

while true do
    local message = inbox:demand(0.25)
    local now = love.timer.getTime()
    if message == "stop" then
        return
    elseif message == "leave" then
        root = nil
        lastBeat = now
    elseif type(message) == "string" and message:sub(1, 6) == "enter:" then
        root = message:sub(7)
        lastBeat = now
    elseif message then
        lastBeat = now
    elseif root and now - lastBeat > timeout then
        love.filesystem.write(reportFile,
            ('{"root": "%s", "seconds": %d}\n'):format(root, math.floor(now - lastBeat)))
        if exitOnFreeze then
            hardExit()
        end
        outbox:push("fired:" .. root)
        root = nil
    end
end
