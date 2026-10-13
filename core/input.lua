-- Input sources. Each source turns a device (a keyboard layout or a gamepad)
-- into an input frame, the only thing the simulation reads:
--   { left, right, jump, kick, hold }  (booleans, held state)
-- The scene reads one frame per player per tick. Network play will produce the
-- same frames from packets. See NETWORKING.md (Input frames).
local config = require("core.player.config")

local input = {}

input.ACTIONS = { "left", "right", "jump", "kick", "hold" }

-- A frame with nothing held.
input.EMPTY = { left = false, right = false, jump = false, kick = false, hold = false }

-- Keyboard layouts: the first is the single-player layout (config.KEYS); the
-- second lets a second player share the keyboard.
input.KEYBOARD_LAYOUTS = {
    config.KEYS,
    { left = "j", right = "l", jump = "i", kick = "o", hold = "u" },
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

function input.keyboard(layoutIndex)
    local keys = input.KEYBOARD_LAYOUTS[layoutIndex]
    return {
        kind = "keyboard",
        layout = layoutIndex,
        keys = keys,
        read = function()
            local frame = {}
            for _, action in ipairs(input.ACTIONS) do
                frame[action] = love.keyboard.isDown(keys[action])
            end
            return frame
        end,
    }
end

function input.gamepad(joystick)
    return {
        kind = "gamepad",
        joystick = joystick,
        read = function()
            if not joystick:isConnected() then
                return input.EMPTY
            end
            local frame = {}
            for _, action in ipairs(input.ACTIONS) do
                frame[action] = joystick:isGamepadDown(unpack(input.GAMEPAD[action]))
            end
            local stickX = joystick:getGamepadAxis("leftx")
            frame.left = frame.left or stickX < -STICK_DEADZONE
            frame.right = frame.right or stickX > STICK_DEADZONE
            return frame
        end,
    }
end

-- The keyboard layout whose jump key is `key`, or nil (used to join a game).
function input.layoutForJoinKey(key)
    for index, keys in ipairs(input.KEYBOARD_LAYOUTS) do
        if keys.jump == key then
            return index
        end
    end
    return nil
end

return input
