-- Watchdog: ends the game when a level freezes it. The in-process script limits
-- (core/script.lua) stop runaway Lua, but a built-in C function that runs for
-- minutes cannot be interrupted from the same thread. A separate thread
-- (core/watchdog_thread.lua) expects a heartbeat every frame while a level
-- runs; after TIMEOUT seconds without one it writes a report naming the level
-- and ends the process. On the next launch, watchdog.start reads the report:
-- a downloaded level (online/<sha256>) is added to the block list and refused
-- from then on (levelpack.mount, loader), and the player is told why the game
-- closed. Bundled and local levels are reported but never blocked.
-- See TECHNICAL.md (Sandbox: watchdog).
local json = require("core.json")

local watchdog = {}

watchdog.TIMEOUT = 8 -- seconds frozen before the game is ended
watchdog.REPORT_FILE = "watchdog_report.json"
watchdog.BLOCK_FILE = "blocked_levels.json"

local thread
local inbox
local blocked -- sha256 -> true, loaded on first use
watchdog.lastReport = nil -- { root, seconds, blocked } from the previous run, if it froze

local function hashOf(root)
    return type(root) == "string" and root:match("^online/(%x+)$")
end

local function loadBlocked()
    if blocked then
        return blocked
    end
    blocked = {}
    local text = love.filesystem.getInfo(watchdog.BLOCK_FILE, "file") and love.filesystem.read(watchdog.BLOCK_FILE)
    local ok, list = pcall(json.decode, text or "[]")
    if ok and type(list) == "table" then
        for _, hash in ipairs(list) do
            if type(hash) == "string" and hash:match("^%x+$") then
                blocked[hash:lower()] = true
            end
        end
    end
    return blocked
end

local function saveBlocked()
    local list = {}
    for hash in pairs(loadBlocked()) do
        list[#list + 1] = hash
    end
    table.sort(list)
    love.filesystem.write(watchdog.BLOCK_FILE, json.encode(list))
end

-- Is the downloaded level with this sha256 blocked (it froze the game before)?
function watchdog.isBlocked(hash)
    return type(hash) == "string" and loadBlocked()[hash:lower()] == true
end

function watchdog.block(hash)
    loadBlocked()[hash:lower()] = true
    saveBlocked()
end

-- Read (and delete) the report a frozen previous run left. Blocks the level it
-- names when that is a downloaded package. Returns the report or nil.
function watchdog.readReport()
    if not love.filesystem.getInfo(watchdog.REPORT_FILE, "file") then
        return nil
    end
    local text = love.filesystem.read(watchdog.REPORT_FILE)
    love.filesystem.remove(watchdog.REPORT_FILE)
    local ok, report = pcall(json.decode, text or "")
    if not ok or type(report) ~= "table" or type(report.root) ~= "string" then
        return nil
    end
    local hash = hashOf(report.root)
    if hash then
        watchdog.block(hash)
        report.blocked = true
    end
    watchdog.lastReport = report
    return report
end

-- Start the watchdog thread (once). options.exitOnFreeze = false makes it
-- report on the "watchdog_out" channel instead of ending the process (tests);
-- options.timeout overrides TIMEOUT.
function watchdog.start(options)
    options = options or {}
    if thread or not love.thread then
        return
    end
    watchdog.readReport()
    inbox = love.thread.getChannel("watchdog")
    inbox:clear()
    thread = love.thread.newThread("core/watchdog_thread.lua")
    thread:start(options.timeout or watchdog.TIMEOUT, watchdog.REPORT_FILE, options.exitOnFreeze ~= false)
end

function watchdog.stop()
    if thread then
        inbox:push("stop")
        thread:wait()
        thread = nil
    end
end

-- A level started: from now on the watchdog expects heartbeats. Call it before
-- loading the level, so a freeze while its scripts load is caught too.
function watchdog.enter(root)
    if inbox then
        inbox:push("enter:" .. tostring(root))
    end
end

-- No level is running (menus): freezes are not a level's fault.
function watchdog.leave()
    if inbox then
        inbox:push("leave")
    end
end

-- Once per frame, from love.update.
function watchdog.beat()
    if inbox and inbox:getCount() < 8 then
        inbox:push("beat")
    end
end

-- The watchdog thread's error, if it crashed (nil while it runs fine).
function watchdog.error()
    return thread and thread:getError()
end

return watchdog
