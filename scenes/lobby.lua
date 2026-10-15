-- Multiplayer from the menu (Phase 3, NETWORKING.md Connectivity): the
-- public rooms on our server (name, room ID, level, players, relayed or not),
-- a page at a time and refreshed every couple of seconds; creating a room
-- (its name, public or private, drop-in, relay only); and joining a room by
-- its ID (private rooms are only joined that way). Joining or creating goes
-- to the waiting room (scenes/room.lua). The server address and the last
-- room settings are kept in the save directory (online.txt) for next time.
local render = require("core.graphics.render")
local text = require("core.text")
local sceneEngine = require("core.scenes")
local rendezvous = require("core.net.rendezvous")
local version = require("core.version")
local gameplay = require("scenes.gameplay")

local lobby = {}

local SETTINGS_FILE = "online.txt"
local BACKGROUND = { 0.125, 0.125, 0.125 }
local TEXT_COLOR = { 1, 1, 1 }
local DIM_COLOR = { 0.55, 0.55, 0.6 }
local WARN_COLOR = { 1, 0.6, 0.45 }
local ACCENT_COLOR = { 0.55, 0.8, 1 }
local LIST_X, LIST_W = 48, 544
local ITEM_X, ITEM_TOP, ITEM_SPACING, ITEM_SIZE = 200, 120, 22, 16
local ROW_TOP, ROW_SPACING, ROW_SIZE = 96, 22, 10
local MAX_SERVER = 64

local page = "list" -- "list" | "create" | "code"
local selected = 1
local notice = nil  -- what is wrong with the last attempt
local settings = { server = "", relayOnly = false, roomName = "", public = true, dropIn = true }
local code = ""
local browser = nil -- rendezvous.browse, while the list is shown

local function loadSettings()
    local ok, data = pcall(love.filesystem.read, SETTINGS_FILE)
    if not ok or type(data) ~= "string" then
        return
    end
    for key, value in data:gmatch("([%w_]+)=([^\n]*)") do
        if key == "server" then
            settings.server = value:sub(1, MAX_SERVER)
        elseif key == "roomName" then
            settings.roomName = rendezvous.cleanName(value)
        elseif key == "relayOnly" or key == "public" or key == "dropIn" then
            settings[key] = value == "1"
        end
    end
end

local function saveSettings()
    local function bit(on) return on and "1" or "0" end
    pcall(love.filesystem.write, SETTINGS_FILE, ("server=%s\nrelayOnly=%s\npublic=%s\ndropIn=%s\nroomName=%s\n"):format(
        settings.server, bit(settings.relayOnly), bit(settings.public), bit(settings.dropIn), settings.roomName))
end

local function closeBrowser()
    if browser then
        browser:close()
        browser = nil
    end
end

-- (Re)open the room list on the server in the settings.
local function openBrowser()
    closeBrowser()
    if settings.server ~= "" then
        local err
        browser, err = rendezvous.browse(settings.server, version.PROTOCOL)
        notice = not browser and err or nil
    end
end

local function playerName()
    return require("scenes.options").playerName()
end

-- The rooms shown on this page of the list.
local function rooms()
    return browser and browser.state == "ok" and browser.rooms or {}
end

local function onOff(on)
    return on and "On" or "Off"
end

-- The page's items: { label, kind = "room" | "toggle" | "field" | "action", ... }.
local function items()
    local list = {}
    if page == "list" then
        for _, entry in ipairs(rooms()) do
            list[#list + 1] = { kind = "room", room = entry }
        end
        list[#list + 1] = { kind = "action", action = "create", label = "Create room" }
        list[#list + 1] = { kind = "action", action = "code", label = "Join by room ID" }
        list[#list + 1] = { kind = "field", field = "server",
            label = "Server: " .. (settings.server ~= "" and settings.server or "(not set)"),
            hint = "The server's address (type it; Backspace erases)." }
        list[#list + 1] = { kind = "action", action = "back", label = "Back" }
    elseif page == "create" then
        list[#list + 1] = { kind = "field", field = "roomName",
            label = "Room name: " .. (settings.roomName ~= "" and settings.roomName or (playerName() .. "'s room")),
            hint = "Shown in the room list." }
        list[#list + 1] = { kind = "toggle", toggle = "public", label = "Public: " .. onOff(settings.public),
            hint = "Off: hidden from the list; friends join with the room ID." }
        list[#list + 1] = { kind = "toggle", toggle = "dropIn", label = "Drop-in: " .. onOff(settings.dropIn),
            hint = "On: players can join while a level is played." }
        list[#list + 1] = { kind = "toggle", toggle = "relayOnly", label = "Relay only: " .. onOff(settings.relayOnly),
            hint = "Hides everyone's IP address behind the server (a little more lag)." }
        list[#list + 1] = { kind = "action", action = "start", label = "Create" }
        list[#list + 1] = { kind = "action", action = "back", label = "Back" }
    else
        list[#list + 1] = { kind = "field", field = "code",
            label = "Room ID: " .. (code ~= "" and code or "______"), hint = "The 6-digit ID your friend's room shows." }
        list[#list + 1] = { kind = "action", action = "start", label = "Join" }
        list[#list + 1] = { kind = "action", action = "back", label = "Back" }
    end
    return list
end

local function show(newPage)
    page, selected, notice = newPage, 1, nil
end

-- Open Multiplayer at the room list.
function lobby.open()
    loadSettings()
    show("list")
    code = ""
    openBrowser()
end

local function needServer()
    if settings.server == "" then
        notice = "Set the server address first."
        return false
    end
    return true
end

-- Join room `roomCode` and go to the waiting room.
local function join(roomCode)
    if not needServer() then
        return nil
    end
    if not roomCode:match("^%d%d%d%d%d%d$") then
        notice = "A room ID is 6 digits."
        return nil
    end
    saveSettings()
    closeBrowser()
    gameplay.configure({
        mode = "client", name = playerName(),
        online = { server = settings.server, code = roomCode },
    })
    gameplay.load()
    return "room"
end

local function create()
    if not needServer() then
        return nil
    end
    saveSettings()
    closeBrowser()
    local name = settings.roomName ~= "" and settings.roomName or rendezvous.cleanName(playerName() .. "'s room")
    gameplay.configure({
        mode = "host", name = playerName(),
        online = { server = settings.server, relayOnly = settings.relayOnly },
        room = { name = name, public = settings.public, dropIn = settings.dropIn },
    })
    gameplay.load()
    return "room"
end

local function back()
    if page == "list" then
        closeBrowser()
        return "menu"
    end
    show("list")
    openBrowser()
    return nil
end

local function activate()
    local item = items()[selected]
    if item.kind == "room" then
        local entry = item.room
        if entry.players >= 5 then
            notice = "That room is full."
            return nil
        elseif entry.playing and not entry.dropIn then
            notice = "That room is playing a level; try again when it is back in the room."
            return nil
        end
        return join(entry.code)
    elseif item.kind == "toggle" then
        settings[item.toggle] = not settings[item.toggle]
        saveSettings()
    elseif item.action == "create" then
        show("create")
        closeBrowser()
    elseif item.action == "code" then
        show("code")
        closeBrowser()
    elseif item.action == "start" then
        return page == "create" and create() or join(code)
    elseif item.action == "back" then
        return back()
    elseif item.kind == "field" then
        if item.field == "server" then
            saveSettings()
            openBrowser()
        end
        selected = selected + 1
    end
    return nil
end

local function edit(field, typed)
    if field == "code" then
        code = (code .. typed:gsub("%D", "")):sub(1, 6)
    elseif field == "roomName" then
        settings.roomName = (settings.roomName .. typed:gsub("[^\32-\126]", "")):sub(1, rendezvous.MAX_ROOM_NAME)
    else
        settings.server = (settings.server .. typed:gsub("[^%w%.%-:]", "")):sub(1, MAX_SERVER)
    end
end

local function erase(field)
    if field == "code" then
        code = code:sub(1, -2)
    else
        settings[field] = settings[field]:sub(1, -2)
    end
end

function lobby.update()
    if browser then
        browser:update(love.timer.getTime())
        local count = #items()
        selected = math.min(selected, count)
    end
end

function lobby.textinput(typed)
    local item = items()[selected]
    if item.kind == "field" then
        edit(item.field, typed)
        notice = nil
    end
end

-- Another page of the room list.
local function turnPage(step)
    if browser and browser.state == "ok" then
        local target = browser.page + step
        if target >= 1 and target <= browser.pages then
            browser:show(target)
            selected = 1
        end
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
        return back()
    elseif page == "list" and (key == "left" or key == "right") and item.kind ~= "field" then
        turnPage(key == "left" and -1 or 1)
    elseif page == "list" and key == "f5" then
        if browser then browser:refresh() end
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

-- Canvas y of item `index` (room rows are smaller, the actions follow them).
local function itemY(index)
    if page ~= "list" then
        return ITEM_TOP + (index - 1) * ITEM_SPACING
    end
    local count = #rooms()
    if index <= count then
        return ROW_TOP + (index - 1) * ROW_SPACING
    end
    return ROW_TOP + math.max(count, 1) * ROW_SPACING + 24 + (index - count - 1) * ITEM_SPACING
end

local function itemAt(x, y)
    for index, item in ipairs(items()) do
        local half = (item.kind == "room" and ROW_SPACING or ITEM_SPACING) / 2
        if x >= LIST_X - 16 and x <= LIST_X + LIST_W and math.abs(y - itemY(index)) <= half then
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

-- One room of the list: name, room ID, level, players, relay and playing.
local function drawRoom(entry, y, isSelected)
    local color = isSelected and TEXT_COLOR or DIM_COLOR
    local top = y - ROW_SIZE / 2 - 2
    local x = LIST_X
    shadowed(entry.name, x, top, 220, "left", ROW_SIZE, color)
    shadowed(entry.code, x + 224, top, 60, "left", ROW_SIZE, color)
    shadowed(entry.level, x + 290, top, 110, "left", ROW_SIZE, color)
    shadowed(entry.players .. "/5", x + 404, top, 36, "left", ROW_SIZE, color)
    local tags = {}
    if entry.relay then tags[#tags + 1] = "relayed" end
    if entry.playing then tags[#tags + 1] = entry.dropIn and "playing" or "playing (locked)" end
    shadowed(table.concat(tags, ", "), x + 444, top, 100, "left", ROW_SIZE,
        isSelected and ACCENT_COLOR or DIM_COLOR)
end

-- The list's head line and its state (loading, empty, unreachable, pages).
local function drawListHead()
    local top = ROW_TOP - 30
    for _, column in ipairs({ { "Room", 0 }, { "ID", 224 }, { "Level", 290 }, { "Players", 404 } }) do
        shadowed(column[1], LIST_X + column[2], top, 120, "left", ROW_SIZE, ACCENT_COLOR)
    end
    local status
    if settings.server == "" then
        status = "Set the server address below to see the rooms."
    elseif not browser or browser.state == "loading" then
        status = "Looking for rooms..."
    elseif browser.state == "failed" then
        status = "Could not get the rooms: " .. tostring(browser.error)
    elseif #browser.rooms == 0 then
        status = "No public rooms yet. Create one!"
    end
    if status then
        shadowed(status, LIST_X, ROW_TOP - ROW_SIZE / 2 - 2, LIST_W, "left", ROW_SIZE, DIM_COLOR)
    elseif browser.pages > 1 then
        shadowed(("< page %d of %d >"):format(browser.page, browser.pages), LIST_X, top, LIST_W, "right",
            ROW_SIZE, DIM_COLOR)
    end
end

local TITLES = { list = "MULTIPLAYER", create = "CREATE ROOM", code = "JOIN BY ROOM ID" }

function lobby.draw()
    local w, h = render.width, render.height
    render.fill(BACKGROUND[1], BACKGROUND[2], BACKGROUND[3], 1)
    shadowed(TITLES[page], 0, 24, w, "center", 32, TEXT_COLOR)
    if page == "list" then
        drawListHead()
    end
    local list = items()
    for index, item in ipairs(list) do
        local isSelected = index == selected
        local y = itemY(index)
        if item.kind == "room" then
            if isSelected then
                shadowed(">", LIST_X - 14, y - ROW_SIZE / 2 - 2, 16, "left", ROW_SIZE, TEXT_COLOR)
            end
            drawRoom(item.room, y, isSelected)
        else
            local label = item.label
            if isSelected and item.kind == "field" and love.timer.getTime() % 1 < 0.5 then
                label = label .. "_"
            end
            local x = page == "list" and LIST_X or ITEM_X
            local top = y - ITEM_SIZE / 2 - 2
            if isSelected then
                shadowed(">", x - 16, top, 16, "left", ITEM_SIZE, TEXT_COLOR)
            end
            shadowed(label, x, top, 480, "left", ITEM_SIZE, isSelected and TEXT_COLOR or DIM_COLOR)
        end
    end
    local item = list[selected]
    if notice then
        shadowed(notice, 0, h - 28, w, "center", 10, WARN_COLOR)
    elseif item and item.hint then
        shadowed(item.hint, 0, h - 28, w, "center", 10, DIM_COLOR)
    elseif item and item.kind == "room" then
        shadowed("Enter to join   Left/Right pages   F5 refresh   Esc back", 0, h - 28, w, "center", 10, DIM_COLOR)
    end
    love.graphics.setColor(1, 1, 1, 1)
end

-- Tests: the page, code and settings without the save directory.
function lobby.state()
    return { page = page, selected = selected, code = code, notice = notice, settings = settings,
        rooms = rooms(), browser = browser }
end

sceneEngine.register("lobby", {
    update = lobby.update,
    keypressed = lobby.keypressed,
    textinput = lobby.textinput,
    mousemoved = lobby.mousemoved,
    mousepressed = lobby.mousepressed,
    draw = lobby.draw,
})

return lobby
