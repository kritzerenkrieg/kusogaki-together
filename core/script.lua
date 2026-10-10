-- Runs mod Lua scripts in a restricted environment. Only text chunks load, and
-- the environment holds whitelisted globals plus the injected engine classes.
-- Lua environments are a guardrail, not a security boundary (see TECHNICAL.md).
local script = {}

local SAFE_GLOBALS = {
    "assert", "error", "getmetatable", "ipairs", "next", "pairs", "pcall",
    "rawget", "rawset", "select", "setmetatable", "tonumber", "tostring", "type",
}

-- Load and run the script at `path`, returning what it returns.
-- `injected` adds engine values (e.g. base classes) to the environment.
function script.load(path, injected)
    local source = love.filesystem.read(path)
    if not source then
        error("script not found: " .. path, 0)
    end
    if source:byte(1) == 27 then -- LuaJIT bytecode starts with ESC
        error("bytecode rejected: " .. path, 0)
    end
    local chunk, err = loadstring(source, "@" .. path)
    if not chunk then
        error(err, 0)
    end

    local env = { math = math, string = string, table = table }
    for _, name in ipairs(SAFE_GLOBALS) do
        env[name] = _G[name]
    end
    for name, value in pairs(injected or {}) do
        env[name] = value
    end
    setfenv(chunk, env)
    return chunk()
end

return script
