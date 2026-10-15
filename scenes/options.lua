-- Options from the menu: the player's name (shown to the others in a room),
-- and music and sound effect volume in steps of 10%. Left/Right (or a click)
-- changes the selected volume; a sound effect change plays a beep at the new
-- level. Kept in the save directory (settings.txt) and applied at startup.
local render = require("core.graphics.render")
local text = require("core.text")
local mathx = require("core.mathx")
local sceneEngine = require("core.scenes")
local audio = require("core.audio")

local options = {}

local SETTINGS_FILE = "settings.txt"
local MAX_NAME = 16
local BACKGROUND = { 0.125, 0.125, 0.125 }
local TEXT_COLOR = { 1, 1, 1 }
local DIM_COLOR = { 0.55, 0.55, 0.6 }
local ITEM_X, ITEM_TOP, ITEM_SPACING, ITEM_SIZE = 200, 140, 24, 16
local STEP = 0.1
local PREVIEW_SFX = "beep.wav"

local selected = 1
local settings = { musicVolume = 1, sfxVolume = 1, name = "" }

local ITEMS = {
    { field = "name", label = "Name" },
    { setting = "musicVolume", label = "Music" },
    { setting = "sfxVolume", label = "Sound effects" },
    { action = "back", label = "Back" },
}

local function saveSettings()
    pcall(love.filesystem.write, SETTINGS_FILE, ("name=%s\nmusicVolume=%.1f\nsfxVolume=%.1f\n"):format(
        settings.name, settings.musicVolume, settings.sfxVolume))
end

-- A name as typed: printable ASCII, at most MAX_NAME bytes.
local function cleanName(text)
    return (text:gsub("[^\32-\126]", "")):sub(1, MAX_NAME)
end

-- Read settings.txt (if any) and apply it; called once at startup.
function options.load()
    local ok, data = pcall(love.filesystem.read, SETTINGS_FILE)
    if ok and type(data) == "string" then
        for key, value in data:gmatch("([%w_]+)=([^\n]*)") do
            if key == "name" then
                settings.name = cleanName(value)
            elseif settings[key] and tonumber(value) then
                settings[key] = mathx.clamp(tonumber(value), 0, 1)
            end
        end
    end
    audio.applySettings(settings)
end

-- The player's name (for rooms), "Player" when none was set.
function options.playerName()
    local name = settings.name:gsub("^%s+", ""):gsub("%s+$", "")
    return name ~= "" and name or "Player"
end

-- Change the selected volume by `steps` of 10%: wraps from 100% to 0% when
-- `wrap` (clicks), otherwise stops at the ends.
local function change(item, steps, wrap)
    local level = math.floor(settings[item.setting] / STEP + 0.5) + steps
    if wrap then
        level = level % (1 / STEP + 1)
    end
    settings[item.setting] = mathx.clamp(level, 0, 1 / STEP) * STEP
    if item.setting == "musicVolume" then
        audio.setMusicVolume(settings.musicVolume)
    else
        audio.setSfxVolume(settings.sfxVolume)
        audio.playSfx(PREVIEW_SFX)
    end
    saveSettings()
end

local function label(item)
    if item.field then
        local value = settings[item.field]
        return item.label .. ": " .. (value ~= "" and value or "(not set)")
    end
    if not item.setting then
        return item.label
    end
    return ("%s: < %d%% >"):format(item.label, math.floor(settings[item.setting] * 100 + 0.5))
end

function options.textinput(typed)
    local item = ITEMS[selected]
    if item.field then
        settings[item.field] = cleanName(settings[item.field] .. typed)
        saveSettings()
    end
end

function options.keypressed(key)
    local item = ITEMS[selected]
    if key == "backspace" and item.field then
        settings[item.field] = settings[item.field]:sub(1, -2)
        saveSettings()
    elseif key == "up" then
        selected = selected > 1 and selected - 1 or #ITEMS
    elseif key == "down" or key == "tab" then
        selected = selected < #ITEMS and selected + 1 or 1
    elseif key == "escape" then
        return "menu"
    elseif (key == "left" or key == "right") and item.setting then
        change(item, key == "left" and -1 or 1)
    elseif key == "return" or key == "kpenter" or (not item.field and (key == "space" or key == "z")) then
        if item.action == "back" then
            return "menu"
        elseif item.field then
            selected = selected + 1
        else
            change(item, 1, true)
        end
    end
    return nil
end

local function itemY(index)
    return ITEM_TOP + (index - 1) * ITEM_SPACING
end

local function itemAt(x, y)
    for index in ipairs(ITEMS) do
        if x >= ITEM_X - 16 and x <= ITEM_X + 300 and math.abs(y - itemY(index)) <= ITEM_SPACING / 2 then
            return index
        end
    end
    return nil
end

function options.mousemoved(x, y)
    selected = itemAt(x, y) or selected
end

-- Left-click raises a volume (wrapping to 0%), right-click lowers it.
function options.mousepressed(x, y, button)
    local index = (button == 1 or button == 2) and itemAt(x, y)
    if not index then
        return nil
    end
    selected = index
    local item = ITEMS[index]
    if item.action == "back" then
        return button == 1 and "menu" or nil
    elseif item.field then
        return nil
    end
    change(item, button == 1 and 1 or -1, button == 1)
    return nil
end

local function shadowed(label, x, y, width, align, size, color)
    love.graphics.setColor(0, 0, 0, 1)
    text.printf(label, x + 1, y + 1, width, align, size)
    love.graphics.setColor(color[1], color[2], color[3], 1)
    text.printf(label, x, y, width, align, size)
end

function options.draw()
    local w, h = render.width, render.height
    render.fill(BACKGROUND[1], BACKGROUND[2], BACKGROUND[3], 1)
    shadowed("OPTIONS", 0, 60, w, "center", 32, TEXT_COLOR)
    for index, item in ipairs(ITEMS) do
        local isSelected = index == selected
        local y = itemY(index) - ITEM_SIZE / 2 - 2
        if isSelected then
            shadowed(">", ITEM_X - 16, y, 16, "left", ITEM_SIZE, TEXT_COLOR)
        end
        local shown = label(item)
        if isSelected and item.field and love.timer.getTime() % 1 < 0.5 then
            shown = shown .. "_"
        end
        shadowed(shown, ITEM_X, y, 400, "left", ITEM_SIZE, isSelected and TEXT_COLOR or DIM_COLOR)
    end
    local hint = ITEMS[selected].field and "Type your name (shown to the others in a room)."
        or "Left/Right to change, Esc to go back."
    shadowed(hint, 0, h - 52, w, "center", 10, DIM_COLOR)
    love.graphics.setColor(1, 1, 1, 1)
end

-- Tests: the settings without the save directory.
function options.state()
    return { selected = selected, settings = settings }
end

sceneEngine.register("options", {
    enter = function()
        selected = 1
    end,
    keypressed = options.keypressed,
    textinput = options.textinput,
    mousemoved = options.mousemoved,
    mousepressed = options.mousepressed,
    draw = options.draw,
})

return options
