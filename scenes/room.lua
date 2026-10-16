-- The waiting room of a network session: the room's name and ID, who is in
-- it (and who lacks the chosen level; a client downloads it from the server,
-- core/net/repo.lua), and the room's settings (the others see them, read
-- only, where the host has its controls). The host picks the
-- level, switches drop-in and public, and starts the countdown; at its end
-- every player goes to the level (scenes/gameplay.lua runs the session and
-- switches scenes for everyone). Leaving goes back to the menu.
local render = require("core.graphics.render")
local text = require("core.text")
local sceneEngine = require("core.scenes")
local playerConfig = require("core.player.config")
local gameplay = require("scenes.gameplay")

local roomScene = {}

local BACKGROUND = { 0.125, 0.125, 0.125 }
local TEXT_COLOR = { 1, 1, 1 }
local DIM_COLOR = { 0.55, 0.55, 0.6 }
local WARN_COLOR = { 1, 0.6, 0.45 }
local ACCENT_COLOR = { 0.55, 0.8, 1 }
local PLAYERS_X, PLAYERS_TOP, PLAYER_SPACING = 64, 112, 22
local ITEM_X, ITEM_TOP, ITEM_SPACING, ITEM_SIZE = 352, 112, 24, 16

local selected = 1
local notice = nil

local function onOff(on)
    return on and "On" or "Off"
end

-- The room's state, or nil while connecting (or after leaving).
local function current()
    local room, isHost, you, status = gameplay.getRoom()
    return room, isHost, you, status
end

local function closed(status)
    return status ~= nil and (status:match("^Disconnected") or status:match("^Could not")
        or status:match("^Room:")) ~= nil
end

-- The room's settings as the others see them, above Leave.
local function settingLines(room)
    return {
        "Level: " .. room.level,
        "Drop-in: " .. onOff(room.di),
        "Public: " .. onOff(room.pub),
        "Connection: " .. (room.relay and "relayed" or "direct"),
    }
end

-- How many setting lines come before the items (none for the host, whose
-- items are the settings).
local function linesBefore()
    local room, isHost = current()
    return (room and not isHost) and #settingLines(room) or 0
end

-- The items on the right: the host's controls, then Leave.
local function items()
    local room, isHost, _, status = current()
    local list = {}
    if isHost and room and not closed(status) then
        local counting = room.st == "countdown"
        list[#list + 1] = { action = "level", label = "Level: < " .. room.level .. " >",
            hint = "Left/Right to pick the level." }
        list[#list + 1] = { action = "dropIn", label = "Drop-in: " .. onOff(room.di),
            hint = "On: players can join while a level is played." }
        list[#list + 1] = { action = "public", label = "Public: " .. onOff(room.pub),
            hint = "Off: hidden from the room list; friends join with the room ID." }
        list[#list + 1] = { action = counting and "cancel" or "start", label = counting and "Cancel" or "Start" }
    end
    list[#list + 1] = { action = "leave", label = "Leave" }
    return list
end

local function leave()
    gameplay.closeNetwork()
    return "menu"
end

local function activate(step)
    local item = items()[selected]
    if not item then
        return nil
    end
    if item.action == "leave" then
        return leave()
    end
    local ok, reason = gameplay.roomAction(item.action, step)
    notice = not ok and reason or nil
    return nil
end

function roomScene.update(delta)
    gameplay.update(delta) -- runs the session; switches to the level when it starts
    selected = math.min(selected, #items())
end

function roomScene.keypressed(key)
    local list = items()
    if key == "up" then
        selected = selected > 1 and selected - 1 or #list
    elseif key == "down" or key == "tab" then
        selected = selected < #list and selected + 1 or 1
    elseif key == "escape" then
        return leave()
    elseif (key == "left" or key == "right") and list[selected] and list[selected].action == "level" then
        return activate(key == "left" and -1 or 1)
    elseif key == "return" or key == "kpenter" or key == "space" or key == "z" then
        return activate(1)
    end
    return nil
end

local function itemY(index)
    return ITEM_TOP + (index - 1 + linesBefore()) * ITEM_SPACING
end

local function itemAt(x, y)
    for index in ipairs(items()) do
        if x >= ITEM_X - 16 and x <= ITEM_X + 260 and math.abs(y - itemY(index)) <= ITEM_SPACING / 2 then
            return index
        end
    end
    return nil
end

function roomScene.mousemoved(x, y)
    selected = itemAt(x, y) or selected
end

-- Left-click activates (on the level: the next one); right-click on the
-- level: the one before.
function roomScene.mousepressed(x, y, button)
    local index = (button == 1 or button == 2) and itemAt(x, y)
    if not index then
        return nil
    end
    selected = index
    if button == 2 and items()[index].action ~= "level" then
        return nil
    end
    return activate(button == 1 and 1 or -1)
end

local function shadowed(label, x, y, width, align, size, color)
    love.graphics.setColor(0, 0, 0, 1)
    text.printf(label, x + 1, y + 1, width, align, size)
    love.graphics.setColor(color[1], color[2], color[3], 1)
    text.printf(label, x, y, width, align, size)
end

local function drawPlayers(room, you)
    shadowed("Players " .. #room.players .. "/5", PLAYERS_X, PLAYERS_TOP - 30, 240, "left", 10, ACCENT_COLOR)
    for index, player in ipairs(room.players) do
        local y = PLAYERS_TOP + (index - 1) * PLAYER_SPACING - 8
        local tint = playerConfig.TINTS[player.id] or TEXT_COLOR
        love.graphics.setColor(tint[1], tint[2], tint[3], 1)
        love.graphics.rectangle("fill", PLAYERS_X, y + 3, 10, 10)
        local label = player.name .. (player.id == 1 and " (host)" or "") .. (player.id == you and " - you" or "")
        shadowed(label, PLAYERS_X + 16, y, 220, "left", 12, TEXT_COLOR)
        if not player.has then
            shadowed("missing level", PLAYERS_X + 16, y + 12, 220, "left", 8, WARN_COLOR)
        end
    end
end

-- The room's ID and settings under its name.
local function details(room)
    local parts = { room.code ~= "" and ("Room ID " .. room.code) or "Room ID: opening..." }
    parts[#parts + 1] = room.pub and "public" or "private"
    parts[#parts + 1] = room.relay and "relayed" or "direct"
    parts[#parts + 1] = "drop-in " .. (room.di and "on" or "off")
    return table.concat(parts, "  -  ")
end

function roomScene.draw()
    local w, h = render.width, render.height
    render.fill(BACKGROUND[1], BACKGROUND[2], BACKGROUND[3], 1)
    local room, isHost, you, status = current()
    if room then
        shadowed(room.name, 0, 20, w, "center", 32, TEXT_COLOR)
        shadowed(details(room), 0, 60, w, "center", 10, DIM_COLOR)
        drawPlayers(room, you)
        shadowed(isHost and "Settings" or "Settings (the host's)", ITEM_X, ITEM_TOP - 30, 260, "left", 10,
            ACCENT_COLOR)
        if not isHost then
            for index, line in ipairs(settingLines(room)) do
                shadowed(line, ITEM_X, ITEM_TOP + (index - 1) * ITEM_SPACING - ITEM_SIZE / 2 - 2, 280, "left",
                    ITEM_SIZE, TEXT_COLOR)
            end
        end
    else
        shadowed("WAITING ROOM", 0, 20, w, "center", 32, TEXT_COLOR)
    end
    local list = items()
    for index, item in ipairs(list) do
        local isSelected = index == selected
        local y = itemY(index) - ITEM_SIZE / 2 - 2
        if isSelected then
            shadowed(">", ITEM_X - 16, y, 16, "left", ITEM_SIZE, TEXT_COLOR)
        end
        shadowed(item.label, ITEM_X, y, 280, "left", ITEM_SIZE, isSelected and TEXT_COLOR or DIM_COLOR)
    end
    local line, color = nil, DIM_COLOR
    local levelLine, levelWarning = gameplay.levelStatus()
    if notice then
        line, color = notice, WARN_COLOR
    elseif closed(status) then
        line, color = status, WARN_COLOR
    elseif levelLine and room and room.st ~= "countdown" then
        line, color = levelLine, levelWarning and WARN_COLOR or ACCENT_COLOR
    elseif not room then
        line = status or "Connecting..."
    elseif room.st == "countdown" then
        shadowed("Starting in " .. room.cd .. "...", 0, h - 72, w, "center", 24, ACCENT_COLOR)
    elseif room.st == "playing" then
        line = "A level is being played. You join it in a moment..."
    elseif isHost then
        line = list[selected] and list[selected].hint or "Start when everyone is in."
    else
        line = "Waiting for the host to start..."
    end
    if line then
        shadowed(line, 0, h - 28, w, "center", 10, color)
    end
    love.graphics.setColor(1, 1, 1, 1)
end

-- Tests: the setting lines a player who is not the host sees (nil for the
-- host, or before the room is known).
function roomScene.settingLines()
    local room, isHost = current()
    return room and not isHost and settingLines(room) or nil
end

sceneEngine.register("room", {
    enter = function()
        selected, notice = 1, nil
    end,
    update = roomScene.update,
    keypressed = roomScene.keypressed,
    mousemoved = roomScene.mousemoved,
    mousepressed = roomScene.mousepressed,
    draw = roomScene.draw,
})

return roomScene
