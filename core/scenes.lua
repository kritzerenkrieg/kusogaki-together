local sceneEngine = {
    current = "intro_splash",
    scenes = {}
}

function sceneEngine.register(name, scene)
    sceneEngine.scenes[name] = scene
end

-- Make `name` the active scene. A scene may define enter(), called on entry.
function sceneEngine.start(name)
    local scene = name and sceneEngine.scenes[name]
    if scene then
        sceneEngine.current = name
        if scene.enter then
            scene.enter()
        end
    end
end

function sceneEngine.switch(name)
    sceneEngine.start(name)
end

function sceneEngine.update(delta)
    local scene = sceneEngine.scenes[sceneEngine.current]
    if scene and scene.update then
        scene.update(delta)
    end
end

function sceneEngine.keypressed(key)
    local scene = sceneEngine.scenes[sceneEngine.current]
    if not scene or not scene.keypressed then
        return
    end

    local nextScene = scene.keypressed(key)
    if nextScene == "exit" then
        love.event.quit()
    elseif nextScene then
        sceneEngine.switch(nextScene)
    end
end

function sceneEngine.gamepadpressed(joystick, button)
    local scene = sceneEngine.scenes[sceneEngine.current]
    if scene and scene.gamepadpressed then
        scene.gamepadpressed(joystick, button)
    end
end

-- Pointer input, in canvas coordinates. mousepressed may return a scene name
-- like keypressed.
function sceneEngine.mousemoved(x, y)
    local scene = sceneEngine.scenes[sceneEngine.current]
    if scene and scene.mousemoved then
        scene.mousemoved(x, y)
    end
end

function sceneEngine.mousepressed(x, y, button)
    local scene = sceneEngine.scenes[sceneEngine.current]
    if not scene or not scene.mousepressed then
        return
    end

    local nextScene = scene.mousepressed(x, y, button)
    if nextScene == "exit" then
        love.event.quit()
    elseif nextScene then
        sceneEngine.switch(nextScene)
    end
end

function sceneEngine.draw()
    local scene = sceneEngine.scenes[sceneEngine.current]
    if scene and scene.draw then
        scene.draw()
    end
end

return sceneEngine
