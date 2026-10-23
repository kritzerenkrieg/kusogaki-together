-- Level script: controls tutorial along the bottom of the screen. Runs in the
-- sandbox; drawing goes through the `ui` table passed to drawHud.
local tutorial = {}

local BAR_HEIGHT = 26

function tutorial.drawHud(ui)
    local width, height = ui.size()
    ui.color(0, 0, 0, 0.45)
    ui.rect(0, height - BAR_HEIGHT, width, BAR_HEIGHT)
    ui.color(0.92, 0.94, 0.98, 1)
    local text = ("%s/%s move   %s jump   %s grab   %s kick   ESC menu   %s vote restart"):format(
        ui.key("left"), ui.key("right"), ui.key("jump"), ui.key("hold"), ui.key("kick"), ui.key("restart"))
    ui.text(text, 8, height - 20, 10)
end

return tutorial
