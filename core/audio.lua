local audio = {}
local mathx = require("core.math")

-- Master volume mixers (0..1)
audio.masterMusicVolume = 1
audio.masterSfxVolume = 1

-- Where to look for sound files
audio.musicPath = "assets/audio/music"
audio.sfxPath = "assets/audio/sfx"

audio.currentMusic = nil

-- Music keeps a track-specific gain, but dynamic live changes belong to SFX.
audio.currentMusicVolume = 1
audio.currentSfxVolume = 1

-- Turn a 0..1 request into a clamped LÖVE volume.
local function normalizeVolume(volume)
    return mathx.clamp(volume or 1, 0, 1)
end

-- Keep pan inside the -1..1 stereo range.
local function normalizePan(pan)
    return mathx.clamp(pan or 0, -1, 1)
end

-- Streams and loops a music track.
function audio.playMusic(name, volume)
    audio.stopMusic()

    local source = love.audio.newSource(
        audio.musicPath .. "/" .. name,
        "stream"
    )

    source:setLooping(true)

    -- Music keeps a track-specific gain separate from the overall music master volume.
    audio.currentMusicVolume = normalizeVolume(volume)

    source:setVolume(
        audio.currentMusicVolume * audio.masterMusicVolume
    )

    source:play()

    audio.currentMusic = source

    return source
end

-- Stops and releases the current music source.
function audio.stopMusic()
    if audio.currentMusic then
        audio.currentMusic:stop()
        audio.currentMusic:release()
        audio.currentMusic = nil
    end
end

-- Plays a short sound effect.
function audio.playSfx(name, volume, pan)
    local source = love.audio.newSource(
        audio.sfxPath .. "/" .. name,
        "static"
    )

    -- Dynamic/temporary gain belongs to SFX rather than music.
    audio.currentSfxVolume = normalizeVolume(volume)

    source:setVolume(
        audio.currentSfxVolume * audio.masterSfxVolume
    )

    source:setPan(normalizePan(pan))
    source:play()

    return source
end

-- Sets the master music volume.
function audio.setMusicVolume(volume)
    audio.masterMusicVolume = normalizeVolume(volume)

    if audio.currentMusic then
        audio.currentMusic:setVolume(
            audio.currentMusicVolume * audio.masterMusicVolume
        )
    end
end

-- Sets the master SFX volume.
function audio.setSfxVolume(volume)
    audio.masterSfxVolume = normalizeVolume(volume)

    -- Keep the current dynamic SFX gain aligned with the master SFX level.
    if audio.currentSfxVolume then
        audio.currentSfxVolume = normalizeVolume(audio.currentSfxVolume)
    end
end

-- Applies a settings table.
function audio.applySettings(settings)
    settings = settings or {}

    if settings.musicVolume ~= nil then
        audio.masterMusicVolume = normalizeVolume(settings.musicVolume)
    end

    if settings.sfxVolume ~= nil then
        audio.masterSfxVolume = normalizeVolume(settings.sfxVolume)
    end

    if settings.musicPath then
        audio.musicPath = settings.musicPath
    end

    if settings.sfxPath then
        audio.sfxPath = settings.sfxPath
    end

    -- Reapply the master music volume to the active track.
    audio.setMusicVolume(audio.masterMusicVolume)
end

return audio