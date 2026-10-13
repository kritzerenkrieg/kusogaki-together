-- Input sources. Each source turns a device (a keyboard layout or a gamepad)
-- into an input frame, the only thing the simulation reads:
--   { left, right, jump, kick, hold, <custom actions...> }  (booleans, held state)
-- The scene reads one frame per player per tick. Network play will produce the
-- same frames from packets (input.pack / input.unpack). See NETWORKING.md
-- (Input frames).
--
-- Custom actions: a level declares extra actions in level.json, with a key per
-- keyboard layout and gamepad buttons (input.parseActions):
--   "actions": [ { "name": "up", "keys": ["up", "w"], "gamepad": ["dpup", "leftup"] } ]
-- Every source then reports them too (read(level.actions)).
local config = require("core.player.config")

local input = {}

input.ACTIONS = { "left", "right", "jump", "kick", "hold" }
input.MAX_CUSTOM_ACTIONS = 16

-- Keyboard layouts: the first is the single-player layout (config.KEYS); the
-- second lets a second player share the keyboard.
input.KEYBOARD_LAYOUTS = {
    config.KEYS,
    { left = "a", right = "d", jump = "j", kick = "l", hold = "k", restart = "e" },
}

-- Gamepad buttons per action (LÖVE gamepad names). Moving also takes the left stick.
input.GAMEPAD = {
    left = { "dpleft" },
    right = { "dpright" },
    jump = { "a" },
    kick = { "b", "y" },
    hold = { "x" },
}
local STICK_DEADZONE = 0.4

-- Names a custom action may use on a gamepad: buttons, plus stick directions
-- and triggers, read from the axes.
local GAMEPAD_BUTTONS = {}
for _, name in ipairs({ "a", "b", "x", "y", "back", "guide", "start", "leftstick", "rightstick",
    "leftshoulder", "rightshoulder", "dpup", "dpdown", "dpleft", "dpright" }) do
    GAMEPAD_BUTTONS[name] = true
end
local GAMEPAD_AXES = { -- name -> { axis, direction }
    leftup = { "lefty", -1 }, leftdown = { "lefty", 1 }, leftleft = { "leftx", -1 }, leftright = { "leftx", 1 },
    rightup = { "righty", -1 }, rightdown = { "righty", 1 }, rightleft = { "rightx", -1 },
    rightright = { "rightx", 1 }, triggerleft = { "triggerleft", 1 }, triggerright = { "triggerright", 1 },
}

local BASE = {}
for _, name in ipairs(input.ACTIONS) do
    BASE[name] = true
end

-- Is `key` a key LÖVE knows? love.keyboard.isDown raises on unknown names.
function input.validKey(key)
    if type(key) ~= "string" or #key == 0 or #key > 16 then
        return false
    end
    if love.keyboard then
        return (pcall(love.keyboard.isDown, key))
    end
    return key:match("^[%w%p ]+$") ~= nil
end

-- Check a level's custom actions (level.json "actions"). Returns a fresh,
-- validated list { { name, keys = { [layout] = key }, gamepad = { names } } },
-- or raises with a message naming `path`.
function input.parseActions(list, path)
    local actions, seen = {}, {}
    if list == nil then
        return actions
    end
    local function fail(message)
        error(("%s: actions: %s"):format(path, message), 0)
    end
    if type(list) ~= "table" then fail("must be a list") end
    if #list > input.MAX_CUSTOM_ACTIONS then fail("at most " .. input.MAX_CUSTOM_ACTIONS) end
    for _, def in ipairs(list) do
        local name = type(def) == "table" and def.name
        if type(name) ~= "string" or not name:match("^[%a_][%w_]*$") or #name > 24 then
            fail("invalid action name " .. tostring(name))
        end
        if BASE[name] or seen[name] then fail("action " .. name .. " is already defined") end
        seen[name] = true
        local action = { name = name, keys = {}, gamepad = {} }
        for layout, key in ipairs(type(def.keys) == "table" and def.keys or {}) do
            if layout > #input.KEYBOARD_LAYOUTS then break end
            if key ~= false and key ~= "" then
                if not input.validKey(key) then fail(("%s: unknown key %s"):format(name, tostring(key))) end
                action.keys[layout] = key
            end
        end
        for i, button in ipairs(type(def.gamepad) == "table" and def.gamepad or {}) do
            if i > 4 then break end
            if not (GAMEPAD_BUTTONS[button] or GAMEPAD_AXES[button]) then
                fail(("%s: unknown gamepad input %s"):format(name, tostring(button)))
            end
            action.gamepad[#action.gamepad + 1] = button
        end
        actions[#actions + 1] = action
    end
    return actions
end

-- Every action name in frame order: the base actions, then the custom ones.
function input.names(actions)
    local names = {}
    for _, name in ipairs(input.ACTIONS) do
        names[#names + 1] = name
    end
    for _, action in ipairs(actions or {}) do
        names[#names + 1] = action.name
    end
    return names
end

-- A frame as an integer bit mask (bit i = names[i] held), and back. Used for
-- the network: one number per player per tick.
function input.pack(frame, names)
    local mask, bit = 0, 1
    for _, name in ipairs(names) do
        if frame and frame[name] == true then
            mask = mask + bit
        end
        bit = bit * 2
    end
    return mask
end

function input.unpack(mask, names)
    local frame, bit = {}, 1
    for _, name in ipairs(names) do
        frame[name] = math.floor(mask / bit) % 2 == 1
        bit = bit * 2
    end
    return frame
end

-- `actions`: the level's custom actions (level.actions), or nil.
function input.keyboard(layoutIndex)
    local keys = input.KEYBOARD_LAYOUTS[layoutIndex]
    return {
        kind = "keyboard",
        layout = layoutIndex,
        keys = keys,
        read = function(actions)
            local frame = {}
            for _, action in ipairs(input.ACTIONS) do
                frame[action] = love.keyboard.isDown(keys[action])
            end
            for _, action in ipairs(actions or {}) do
                local key = action.keys[layoutIndex]
                frame[action.name] = key ~= nil and love.keyboard.isDown(key)
            end
            return frame
        end,
    }
end

local function gamepadDown(joystick, name)
    local axis = GAMEPAD_AXES[name]
    if axis then
        return joystick:getGamepadAxis(axis[1]) * axis[2] > STICK_DEADZONE
    end
    return joystick:isGamepadDown(name)
end

function input.gamepad(joystick)
    return {
        kind = "gamepad",
        joystick = joystick,
        read = function(actions)
            local frame = {}
            if not joystick:isConnected() then
                return frame -- nothing held (a fresh table: frames are given to scripts)
            end
            for _, action in ipairs(input.ACTIONS) do
                frame[action] = joystick:isGamepadDown(unpack(input.GAMEPAD[action]))
            end
            local stickX = joystick:getGamepadAxis("leftx")
            frame.left = frame.left or stickX < -STICK_DEADZONE
            frame.right = frame.right or stickX > STICK_DEADZONE
            for _, action in ipairs(actions or {}) do
                local down = false
                for _, name in ipairs(action.gamepad) do
                    down = down or gamepadDown(joystick, name)
                end
                frame[action.name] = down
            end
            return frame
        end,
    }
end

-- Gamepad button that toggles a player's restart vote (keyboard: `restart`
-- in the layout).
input.GAMEPAD_RESTART = "back"

-- The keyboard layout whose `action` key is `key`, or nil (jump joins a game,
-- restart toggles a restart vote).
function input.layoutForKey(key, action)
    for index, keys in ipairs(input.KEYBOARD_LAYOUTS) do
        if keys[action] == key then
            return index
        end
    end
    return nil
end

return input
