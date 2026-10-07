local sceneEngine = {
    current = "intro_splash",
    scenes = {}
}

function sceneEngine.register(name, scene)
    sceneEngine.scenes[name] = scene
end

function sceneEngine.start(name)
    if name and sceneEngine.scenes[name] then
        sceneEngine.current = name
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

function sceneEngine.draw()
    local scene = sceneEngine.scenes[sceneEngine.current]
    if scene and scene.draw then
        scene.draw()
    end
end

return sceneEngine
