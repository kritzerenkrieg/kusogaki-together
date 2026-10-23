-- Levels outside the game: the built-in levels copied into the save
-- directory, level packages (core/levelpack.lua), the level list
-- (core/levels.lua), the Levels screen, and the level repository on the
-- server (core/net/repo.lua; needs KUSOGAKI_SERVER, see tests/run.sh).
local helpers = require("tests.sim.helpers")
local check = helpers.check
local levelpack = require("core.levelpack")
local levels = require("core.levels")

-- ── Built-in levels are copied into the save directory ───────────────────
do
    check("the built-in levels are in the save directory",
        love.filesystem.getRealDirectory("levels/kusogaki_stage1/level.json") == love.filesystem.getSaveDirectory()
        and love.filesystem.getInfo("levels/topdown/level.json") ~= nil)
    check("... as exact copies", levelpack.fingerprint("levels/kusogaki_stage1") == levelpack.fingerprint("builtin/kusogaki_stage1"))
    check("the game itself has no levels/ folder", love.filesystem.getRealDirectory("levels") ==
        love.filesystem.getSaveDirectory())

    local script = "levels/topdown/scripts/coins.lua"
    local original = love.filesystem.read(script)
    love.filesystem.write(script, original .. "\n-- changed by the player\n")
    levels.seed()
    check("a level the player changed is kept", love.filesystem.read(script):find("changed by the player") ~= nil)

    -- The player's copy is an older built-in version: a new one replaces it.
    local seeded = require("core.json").decode(love.filesystem.read(levels.SEED_FILE))
    seeded.topdown = levelpack.fingerprint("levels/topdown")
    love.filesystem.write(levels.SEED_FILE, require("core.json").encode(seeded))
    levels.seed()
    check("an unchanged older copy is updated", love.filesystem.read(script) == original)

    levelpack.removeTree("levels/topdown")
    levels.seed()
    check("a missing built-in level comes back", levelpack.fingerprint("levels/topdown")
        == levelpack.fingerprint("builtin/topdown"))
end

-- ── Packages ─────────────────────────────────────────────────────────────
do
    for path, want in pairs({
        ["level.json"] = true, ["entities/box.lua"] = true, ["scripts/goal.lua"] = true,
        ["assets/box.png"] = true, ["assets/sfx/hit.ogg"] = true,
        ["entities/a/box.lua"] = false, ["notes.txt"] = false, ["assets/.x.png"] = false,
        ["assets/../level.json"] = false, ["/level.json"] = false, ["assets/box.gif"] = false,
        ["assets//box.png"] = false, ["assets/a/b/c/d.png"] = false,
    }) do
        check("a level may have " .. path .. ": " .. tostring(want), levelpack.allowed(path) == want)
    end

    love.filesystem.createDirectory("levels/packtest/scripts")
    local levelJson = '{"format": 1, "name": "packtest", "spawn": {"x": 0, "y": 0}}'
    love.filesystem.write("levels/packtest/level.json", levelJson)
    love.filesystem.write("levels/packtest/scripts/a.lua", "return {}")
    love.filesystem.write("levels/packtest/notes.txt", "not part of the level")
    local package, skipped = levelpack.pack("levels/packtest")
    check("a package holds the level's files in order", package ==
        "level.json\0" .. #levelJson .. "\0" .. levelJson .. "scripts/a.lua\0" .. 9 .. "\0return {}", package)
    check("... and leaves out other files", skipped[1] == "notes.txt" and #skipped == 1)
    check("a package's fingerprint is its sha256", levelpack.fingerprint("levels/packtest")
        == levelpack.sha256(package))
    check("a package unpacks", #assert(levelpack.unpack(package)) == 2)
    local function refused(why, bad)
        local files, err = levelpack.unpack(bad)
        check("a package is refused: " .. why, files == nil and err ~= nil)
    end
    refused("cut short", package:sub(1, -2))
    refused("trailing bytes", package .. "x")
    refused("out of order", "scripts/a.lua\0" .. "0\0" .. "level.json\0" .. "2\0{}")
    refused("no level.json", "scripts/a.lua\0" .. "0\0")
    refused("a padded size", "level.json\0" .. "02\0{}")
    refused("compiled Lua", "level.json\0" .. "2\0{}" .. "scripts/a.lua\0" .. "4\0\27Lua")
    refused("a file outside the rules", "level.json\0" .. "2\0{}" .. "readme.md\0" .. "0\0")

    local id = levelpack.sha256(package)
    check("a download that is not the level asked for is refused",
        levels.install(("0"):rep(64), package) == nil and levels.byId(("0"):rep(64)) == nil)
    local root = levels.install(id, package)
    local entry = levels.byId(id)
    check("an installed download is listed", entry and entry.root == root and entry.downloaded
        and entry.name == "packtest")
    check("the player's own level of the same files has the same id", levels.byRoot("levels/packtest").id == id)
    check("the list is sorted by name", levels.list()[1].name:lower() <= levels.list()[#levels.list()].name:lower())
    check("only downloads are removed here", not levels.remove("levels/packtest") and levels.remove(root)
        and levels.byId(id).root == "levels/packtest")
end

-- ── The Levels screen ────────────────────────────────────────────────────
do
    local scene = require("scenes.levels")
    local gameplay = require("scenes.gameplay")
    scene.open()
    local state = scene.state()
    check("Levels opens on my levels", state.tab == "mine" and state.items[1].kind == "level")
    check("my levels draw", pcall(scene.draw))
    local index
    for i, item in ipairs(state.items) do
        if item.entry and item.entry.root == "levels/kusogaki_stage1" then index = i end
    end
    for _ = 2, index or 1 do scene.keypressed("down") end
    check("Enter plays the selected level alone", scene.keypressed("return") == "gameplay"
        and gameplay.getLevel() and gameplay.getLevel().root == "levels/kusogaki_stage1" and gameplay.getMode() == nil)
    scene.open()
    for i, item in ipairs(scene.state().items) do
        if item.entry and item.entry.root == "levels/packtest" then index = i end
    end
    for _ = 2, index do scene.keypressed("down") end
    love.filesystem.write("levels/packtest/level.json", "{")
    levels.refresh()
    check("a level that does not load says so", scene.keypressed("return") == nil
        and tostring(scene.state().notice):find("does not load") ~= nil, scene.state().notice)
    levelpack.removeTree("levels/packtest")
    levels.refresh()
    scene.keypressed("tab")
    check("Tab shows the online levels", scene.state().tab == "online")
    check("the online list draws", pcall(scene.draw))
    check("Esc goes back to the menu", scene.keypressed("escape") == "menu")

    local title = require("scenes.title_screen")
    -- Clicks on the menu's options (on the cursor's place: no font widths here).
    local opened = title.mousepressed(280, 180, 1)
    check("the main menu opens the online levels", opened == "levels" and scene.state().tab == "online",
        tostring(opened) .. " " .. scene.state().tab)
    check("... and Singleplayer my levels", title.mousepressed(280, 156, 1) == "levels"
        and scene.state().tab == "mine")
end

-- ── The level repository on the server ───────────────────────────────────
local server = os.getenv("KUSOGAKI_SERVER")
if not server then
    print("skip  level repository checks (no KUSOGAKI_SERVER)")
    return
end
do
    local repo = require("core.net.repo")
    check("the repository's address", repo.baseUrl("10.0.0.1") == "http://10.0.0.1:26968"
        and repo.baseUrl("example.com:4000") == "http://example.com:4000" and repo.baseUrl("") == nil)
    local done, list = repo.list(server, 1):wait()
    check("the server lists its levels", done and type(list.levels) == "table" and list.pages >= 1, list)
    -- Uploads only to a test server: the real one's list is public.
    if not server:match("^127%.") then
        print("skip  level upload checks (only against a server on 127.0.0.1)")
        return
    end
    local id = levelpack.fingerprint("levels/topdown")
    local uploaded, result = repo.upload(server, "levels/topdown", "Tester"):wait()
    check("a level uploads, under its fingerprint", uploaded and result == id, result)
    local _, again = repo.upload(server, "levels/topdown", "Tester"):wait()
    check("uploading it again gives the same level", again == id)
    local found, info = repo.info(server, id):wait()
    check("the server knows it", found and info.name == "topdown" and info.author == "Tester", info)
    local missing, why = repo.info(server, ("0"):rep(64)):wait()
    check("an unknown level is not on the server", missing == false and why == "not on the server")
    _, list = repo.list(server, 1):wait()
    local listed = false
    for _, entry in ipairs(list.levels) do
        listed = listed or entry.id == id
    end
    check("the list shows it", listed)
    local got, root = repo.download(server, id):wait()
    check("it downloads and installs", got and root == "downloads/" .. id and levels.byId(id) ~= nil, root)
    check("the download is the same level", got and levelpack.pack(root) == levelpack.pack("levels/topdown"))
    levels.remove("downloads/" .. id)
    local nothing, err = repo.download(server, ("0"):rep(64)):wait()
    check("a missing level does not download", nothing == false and err ~= nil)

    love.filesystem.createDirectory("levels/badupload")
    love.filesystem.write("levels/badupload/level.json", '{"format": 1, "name": "has space"}')
    local refusedUpload, reason = repo.upload(server, "levels/badupload", "Tester"):wait()
    check("the server's reason comes back", refusedUpload == false and tostring(reason):find("name") ~= nil, reason)
    levelpack.removeTree("levels/badupload")
    levels.refresh()
end
