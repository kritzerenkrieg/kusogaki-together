-- `love2d . --sim-test` runs tests/sim_test.lua headless: no window, graphics or audio.
SIM_TEST = false
for _, value in ipairs(arg or {}) do
    if value == "--sim-test" then
        SIM_TEST = true
    end
end

function love.conf(settings)
    settings.identity = "kusogaki-together"
    settings.window.title = "Kusogaki Together"
    settings.window.width = 640
    settings.window.height = 360
    settings.window.fullscreen = true
    settings.window.fullscreentype = "desktop"
    if SIM_TEST then
        settings.window = false
        settings.modules.window = false
        settings.modules.graphics = false
        settings.modules.audio = false
    end
end
