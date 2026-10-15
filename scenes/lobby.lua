-- Internet play from the menu (Phase 3, NETWORKING.md Connectivity): host a
-- room or join one by its 6-digit code, through our rendezvous server. Both
-- screens have the Relay only switch (hide this machine's IP address behind
-- the relay) and the server address. The switch and the address are kept
-- in the save directory (online.txt) for next time.
local render = require("core.graphics.render")
local text = require("core.text")
local sceneEngine = require("core.scenes")
local gameplay = require("scenes.gameplay")

local lobby = {}

local SETTINGS_FILE = "online.txt"
local BACKGROUND = { 0.125, 0.125, 0.125 }
local TEXT_COLOR = { 1, 1, 1 }
local DIM_COLOR = { 0.55, 0.55, 0.6 }
local WARN_COLOR = { 1, 0.6, 0.45 }
local ITEM_X, ITEM_TOP, ITEM_SPACING, ITEM_SIZE = 200, 140, 24, 16
local MAX_SERVER = 64

local mode = "host"  -- "host" | "join"
local selected = 1
local notice = nil   -- what is wrong with the last attempt
local settings = { server = "", relayOnly = false }
local code = ""

local function loadSettings()
    local ok, data = pcall(love.filesystem.read, SETTINGS_FILE)
    if not ok or type(data) ~= "string" then
        return
    end
    for key, value in data:gmatch("([%w_]+)=([^\n]*)") do
        if key == "server" then
            settings.server = value:sub(1, MAX_SERVER)
        elseif key == "relayOnly" then
            settings.relayOnly = value == "1"
        end
    end
end

local function saveSettings()
    pcall(love.filesystem.write, SETTINGS_FILE,
        ("server=%s\nrelayOnly=%s\n"):format(settings.server, settings.relayOnly and "1" or "0"))
end

-- The screen's items: { label, kind = "toggle" | "field" | "action", ... }.
local function items()
    local list = {}
    if mode == "join" then
        list[#list + 1] = { kind = "field", field = "code",
            label = "Room code: " .. (code ~= "" and code or "______") }
    end
    list[#list + 1] = { kind = "toggle", label = "Relay only: " .. (settings.relayOnly and "On" or "Off"),
        hint = "Hides your IP address from the other players (a little more lag)." }
    list[#list + 1] = { kind = "field", field = "server",
        label = "Server: " .. (settings.server ~= "" and settings.server or "(not set)"),
        hint = "The rendezvous server's address (type it; Backspace erases)." }
    list[#list + 1] = { kind = "action", action = "start", label = mode == "host" and "Open room" or "Join" }
    list[#list + 1] = { kind = "action", action = "back", label = "Back" }
    return list
end

-- Open the lobby for "host" or "join".
function lobby.open(newMode)
    mode = newMode
    selected = 1
    notice = nil
    loadSettings()
end

local function start()
    if settings.server == "" then
        notice = "Set the server address first."
        return nil
    end
    if mode == "join" and not code:match("^%d%d%d%d%d%d$") then
        notice = "A room code is 6 digits."
        return nil
    end
    saveSettings()
    gameplay.configure({
        mode = mode == "host" and "host" or "client",
        online = { server = settings.server, relayOnly = settings.relayOnly, code = mode == "join" and code or nil },
    })
    gameplay.load()
    return "gameplay"
end

local function activate()
    local item = items()[selected]
    if item.kind == "toggle" then
        settings.relayOnly = not settings.relayOnly
        saveSettings()
    elseif item.action == "start" then
        return start()
    elseif item.action == "back" then
        return "menu"
    elseif item.field == "code" then
        selected = selected + 1
    end
    return nil
end

local function edit(field, typed)
    if field == "code" then
        code = (code .. typed:gsub("%D", "")):sub(1, 6)
    else
        settings.server = (settings.server .. typed:gsub("[^%w%.%-:]", "")):sub(1, MAX_SERVER)
    end
end

local function erase(field)
    if field == "code" then
        code = code:sub(1, -2)
    else
        settings.server = settings.server:sub(1, -2)
    end
end

function lobby.textinput(typed)
    local item = items()[selected]
    if item.kind == "field" then
        edit(item.field, typed)
        notice = nil
    end
end

function lobby.keypressed(key)
    local list = items()
    local item = list[selected]
    if key == "up" then
        selected = selected > 1 and selected - 1 or #list
    elseif key == "down" or key == "tab" then
        selected = selected < #list and selected + 1 or 1
    elseif key == "escape" then
        return "menu"
    elseif key == "backspace" and item.kind == "field" then
        erase(item.field)
    elseif key == "v" and love.keyboard.isDown("lctrl", "rctrl") and item.kind == "field" then
        local ok, pasted = pcall(love.system.getClipboardText)
        if ok and pasted then
            edit(item.field, pasted)
        end
    elseif key == "return" or key == "kpenter" or (key == "space" and item.kind ~= "field") then
        return activate()
    end
    return nil
end

local function itemY(index)
    return ITEM_TOP + (index - 1) * ITEM_SPACING
end

local function itemAt(x, y)
    for index in ipairs(items()) do
        if x >= ITEM_X - 16 and x <= ITEM_X + 300 and math.abs(y - itemY(index)) <= ITEM_SPACING / 2 then
            return index
        end
    end
    return nil
end

function lobby.mousemoved(x, y)
    selected = itemAt(x, y) or selected
end

function lobby.mousepressed(x, y, button)
    local index = button == 1 and itemAt(x, y)
    if index then
        selected = index
        return activate()
    end
end

local function shadowed(label, x, y, width, align, size, color)
    love.graphics.setColor(0, 0, 0, 1)
    text.printf(label, x + 1, y + 1, width, align, size)
    love.graphics.setColor(color[1], color[2], color[3], 1)
    text.printf(label, x, y, width, align, size)
end

function lobby.draw()
    local w, h = render.width, render.height
    render.fill(BACKGROUND[1], BACKGROUND[2], BACKGROUND[3], 1)
    shadowed(mode == "host" and "HOST ONLINE" or "JOIN ONLINE", 0, 60, w, "center", 32, TEXT_COLOR)
    shadowed(mode == "host" and "Open a room and give your friends its code."
        or "Type the code your friend's room shows.", 0, 102, w, "center", 10, DIM_COLOR)
    local list = items()
    for index, item in ipairs(list) do
        local isSelected = index == selected
        local label = item.label
        if isSelected and item.kind == "field" and love.timer.getTime() % 1 < 0.5 then
            label = label .. "_"
        end
        local y = itemY(index) - ITEM_SIZE / 2 - 2
        if isSelected then
            shadowed(">", ITEM_X - 16, y, 16, "left", ITEM_SIZE, TEXT_COLOR)
        end
        shadowed(label, ITEM_X, y, 400, "left", ITEM_SIZE, isSelected and TEXT_COLOR or DIM_COLOR)
    end
    local item = list[selected]
    if notice then
        shadowed(notice, 0, h - 52, w, "center", 10, WARN_COLOR)
    elseif item and item.hint then
        shadowed(item.hint, 0, h - 52, w, "center", 10, DIM_COLOR)
    end
    love.graphics.setColor(1, 1, 1, 1)
end

-- Tests: the code and settings without the save directory.
function lobby.state()
    return { mode = mode, selected = selected, code = code, notice = notice, settings = settings }
end

sceneEngine.register("lobby", {
    keypressed = lobby.keypressed,
    textinput = lobby.textinput,
    mousemoved = lobby.mousemoved,
    mousepressed = lobby.mousepressed,
    draw = lobby.draw,
})

return lobby
