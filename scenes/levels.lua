-- Levels (Singleplayer from the menu): two lists. "My levels" are the levels
-- on this machine (core/levels.lua): the player's own folders in the save
-- directory's levels/ (the built-in ones are copied there) and the ones
-- downloaded from the server. Enter plays one alone, U uploads one of the
-- player's own to the server's level repository, Delete removes a download.
-- "Online" lists the repository a page at a time (core/net/repo.lua); Enter
-- downloads a level (or plays it once it is here). The server is the one set
-- in Multiplayer.
local render = require("core.graphics.render")
local text = require("core.text")
local sceneEngine = require("core.scenes")
local levels = require("core.levels")
local repo = require("core.net.repo")
local gameplay = require("scenes.gameplay")

local levelsScene = {}

local BACKGROUND = { 0.125, 0.125, 0.125 }
local TEXT_COLOR = { 1, 1, 1 }
local DIM_COLOR = { 0.55, 0.55, 0.6 }
local WARN_COLOR = { 1, 0.6, 0.45 }
local ACCENT_COLOR = { 0.55, 0.8, 1 }
local LIST_X, LIST_W = 48, 544
local ROW_TOP, ROW_SPACING, ROW_SIZE = 100, 20, 10
local ITEM_SPACING, ITEM_SIZE = 22, 16
local PER_PAGE = 8

local tab = "mine" -- "mine" | "online"
local selected = 1
local page = 1     -- page of "mine" (the online list keeps its own)
local notice, noticeWarning = nil, false
local online = { page = 1, pages = 1, levels = {}, request = nil, error = nil }
local busy = nil   -- { request, kind = "upload" | "download", name }

local function server()
    return require("scenes.lobby").serverAddress()
end

local function say(message, warning)
    notice, noticeWarning = message, warning == true
end

local function minePages()
    return math.max(1, math.ceil(#levels.list() / PER_PAGE))
end

-- The levels shown on this page of the tab.
local function rows()
    if tab == "online" then
        return online.levels
    end
    local list, shown = levels.list(), {}
    for index = (page - 1) * PER_PAGE + 1, math.min(page * PER_PAGE, #list) do
        shown[#shown + 1] = list[index]
    end
    return shown
end

-- Rows first, then the actions under them.
local function items()
    local list = {}
    for _, entry in ipairs(rows()) do
        list[#list + 1] = { kind = "level", entry = entry }
    end
    if tab == "mine" then
        list[#list + 1] = { kind = "action", action = "folder", label = "Open my levels folder" }
    end
    list[#list + 1] = { kind = "action", action = "tab",
        label = tab == "mine" and "Online levels" or "My levels" }
    list[#list + 1] = { kind = "action", action = "back", label = "Back" }
    return list
end

local function fetchOnline(target)
    online.request = repo.list(server(), target or online.page)
    online.error = nil
end

local function show(newTab)
    tab, selected = newTab, 1
    if tab == "online" then
        fetchOnline(1)
    else
        levels.refresh()
        page = math.min(page, minePages())
    end
end

-- Open Levels on a tab ("mine" by default).
function levelsScene.open(newTab)
    say(nil)
    busy = nil
    show(newTab or "mine")
end

local function play(entry)
    gameplay.closeNetwork()
    gameplay.configure({ level = entry.root })
    local ok, err = pcall(gameplay.load)
    if not ok then
        say("This level does not load: " .. tostring(err):sub(1, 160), true)
        return nil
    end
    return "gameplay"
end

local function upload(entry)
    if entry.downloaded then
        say("That level came from the server already.")
        return
    end
    busy = { kind = "upload", name = entry.name,
        request = repo.upload(server(), entry.root, require("scenes.options").playerName()) }
    say("Uploading " .. entry.name .. "...")
end

local function startDownload(entry)
    busy = { kind = "download", name = entry.name, request = repo.download(server(), entry.id) }
    say("Downloading " .. entry.name .. "...")
end

local function activate()
    local item = items()[selected]
    if not item then
        return nil
    end
    if item.kind == "level" then
        local entry = item.entry
        if tab == "mine" then
            return play(entry)
        end
        local mine = levels.byId(entry.id)
        if mine then
            return play(mine)
        elseif not busy then
            startDownload(entry)
        end
    elseif item.action == "folder" then
        love.filesystem.createDirectory(levels.LOCAL)
        love.system.openURL("file://" .. love.filesystem.getSaveDirectory() .. "/" .. levels.LOCAL)
        say("Put a level folder (with its level.json) in there, then come back here.")
    elseif item.action == "tab" then
        show(tab == "mine" and "online" or "mine")
    elseif item.action == "back" then
        return "menu"
    end
    return nil
end

function levelsScene.update()
    if online.request then
        local done, result = online.request:poll()
        if done then
            online.page, online.pages, online.levels = result.page, result.pages, result.levels
            online.request = nil
        elseif done == false then
            online.error, online.levels, online.request = result, {}, nil
        end
    end
    if busy then
        local done, result = busy.request:poll()
        if done ~= nil then
            if busy.kind == "upload" then
                say(done and (busy.name .. " is on the server now.") or ("Upload failed: " .. tostring(result)),
                    not done)
            else
                say(done and (busy.name .. " downloaded: Enter to play it.") or
                    ("Download failed: " .. tostring(result)), not done)
            end
            busy = nil
            levels.refresh()
        end
    end
    selected = math.min(selected, #items())
end

local function turnPage(step)
    if tab == "online" then
        local target = online.page + step
        if target >= 1 and target <= online.pages and not online.request then
            fetchOnline(target)
            selected = 1
        end
    else
        local target = page + step
        if target >= 1 and target <= minePages() then
            page, selected = target, 1
        end
    end
end

function levelsScene.keypressed(key)
    local list = items()
    local item = list[selected]
    if key == "up" then
        selected = selected > 1 and selected - 1 or #list
    elseif key == "down" then
        selected = selected < #list and selected + 1 or 1
    elseif key == "tab" then
        show(tab == "mine" and "online" or "mine")
    elseif key == "escape" then
        return "menu"
    elseif key == "left" or key == "right" then
        turnPage(key == "left" and -1 or 1)
    elseif key == "f5" then
        if tab == "online" then fetchOnline() else levels.refresh() end
    elseif key == "u" and tab == "mine" and item and item.kind == "level" and not busy then
        upload(item.entry)
    elseif key == "delete" and tab == "mine" and item and item.kind == "level" then
        if levels.remove(item.entry.root) then
            say(item.entry.name .. " deleted.")
            page = math.min(page, minePages())
        else
            say("Only downloaded levels are deleted here; your own are in the levels folder.")
        end
    elseif key == "return" or key == "kpenter" or key == "space" or key == "z" then
        return activate()
    end
    return nil
end

local function itemY(index)
    local count = #rows()
    if index <= count then
        return ROW_TOP + (index - 1) * ROW_SPACING
    end
    return ROW_TOP + math.max(count, 1) * ROW_SPACING + 20 + (index - count - 1) * ITEM_SPACING
end

local function itemAt(x, y)
    for index, item in ipairs(items()) do
        local half = (item.kind == "level" and ROW_SPACING or ITEM_SPACING) / 2
        if x >= LIST_X - 16 and x <= LIST_X + LIST_W and math.abs(y - itemY(index)) <= half then
            return index
        end
    end
    return nil
end

function levelsScene.mousemoved(x, y)
    selected = itemAt(x, y) or selected
end

function levelsScene.mousepressed(x, y, button)
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

local function sizeText(bytes)
    if bytes >= 1024 * 1024 then
        return ("%.1f MB"):format(bytes / (1024 * 1024))
    end
    return ("%d KB"):format(math.ceil(bytes / 1024))
end

local function drawRow(entry, y, isSelected)
    local color = isSelected and TEXT_COLOR or DIM_COLOR
    local top = y - ROW_SIZE / 2 - 2
    shadowed(entry.name, LIST_X, top, 250, "left", ROW_SIZE, color)
    if tab == "mine" then
        shadowed(entry.downloaded and "downloaded" or "yours", LIST_X + 260, top, 100, "left", ROW_SIZE, color)
        shadowed(entry.id:sub(1, 8), LIST_X + 370, top, 80, "left", ROW_SIZE, DIM_COLOR)
    else
        shadowed(entry.author ~= "" and entry.author or "-", LIST_X + 260, top, 120, "left", ROW_SIZE, color)
        shadowed(sizeText(entry.size), LIST_X + 390, top, 70, "left", ROW_SIZE, color)
        if levels.byId(entry.id) then
            shadowed("have it", LIST_X + 470, top, 70, "left", ROW_SIZE, isSelected and ACCENT_COLOR or DIM_COLOR)
        end
    end
end

-- The head line of the list: columns, or why there is nothing in it, and the
-- page.
local function drawHead()
    local top = ROW_TOP - 26
    local columns = tab == "mine" and { { "Level", 0 }, { "From", 260 }, { "ID", 370 } }
        or { { "Level", 0 }, { "By", 260 }, { "Size", 390 } }
    local status
    if tab == "online" then
        if server() == "" then
            status = "Set the server address in Multiplayer first."
        elseif online.request and #online.levels == 0 then
            status = "Getting the list..."
        elseif online.error then
            status = "Could not get the list: " .. tostring(online.error)
        elseif #online.levels == 0 then
            status = "No levels on the server yet. Upload one from My levels (U)."
        end
    elseif #levels.list() == 0 then
        status = "No levels yet: open the levels folder, or download some (Online levels)."
    end
    if status then
        shadowed(status, LIST_X, ROW_TOP - ROW_SIZE / 2 - 2, LIST_W, "left", ROW_SIZE, DIM_COLOR)
        return
    end
    for _, column in ipairs(columns) do
        shadowed(column[1], LIST_X + column[2], top, 120, "left", ROW_SIZE, ACCENT_COLOR)
    end
    local current, pages = page, minePages()
    if tab == "online" then
        current, pages = online.page, online.pages
    end
    if pages > 1 then
        shadowed(("< page %d of %d >"):format(current, pages), LIST_X, top, LIST_W, "right", ROW_SIZE, DIM_COLOR)
    end
end

local HINTS = {
    mine = "Enter play   U upload   Delete remove a download   Tab online   Esc back",
    online = "Enter download (or play)   Left/Right pages   F5 refresh   Tab my levels   Esc back",
}

function levelsScene.draw()
    local w, h = render.width, render.height
    render.fill(BACKGROUND[1], BACKGROUND[2], BACKGROUND[3], 1)
    shadowed(tab == "mine" and "MY LEVELS" or "ONLINE LEVELS", 0, 24, w, "center", 32, TEXT_COLOR)
    drawHead()
    for index, item in ipairs(items()) do
        local isSelected = index == selected
        local y = itemY(index)
        if item.kind == "level" then
            if isSelected then
                shadowed(">", LIST_X - 14, y - ROW_SIZE / 2 - 2, 16, "left", ROW_SIZE, TEXT_COLOR)
            end
            drawRow(item.entry, y, isSelected)
        else
            local top = y - ITEM_SIZE / 2 - 2
            if isSelected then
                shadowed(">", LIST_X - 16, top, 16, "left", ITEM_SIZE, TEXT_COLOR)
            end
            shadowed(item.label, LIST_X, top, 480, "left", ITEM_SIZE, isSelected and TEXT_COLOR or DIM_COLOR)
        end
    end
    if notice then
        shadowed(notice, 0, h - 46, w, "center", 10, noticeWarning and WARN_COLOR or ACCENT_COLOR)
    end
    shadowed(HINTS[tab], 0, h - 24, w, "center", 10, DIM_COLOR)
    love.graphics.setColor(1, 1, 1, 1)
end

-- Tests: what the scene shows.
function levelsScene.state()
    return { tab = tab, selected = selected, page = page, notice = notice, online = online, busy = busy,
        items = items() }
end

sceneEngine.register("levels", {
    update = levelsScene.update,
    keypressed = levelsScene.keypressed,
    mousemoved = levelsScene.mousemoved,
    mousepressed = levelsScene.mousepressed,
    draw = levelsScene.draw,
})

return levelsScene
