--[[--
Audio file playback on Android through android.media.MediaPlayer (JNI).
Plays MP3 and WAV.  One MediaPlayer per file; completion is detected by
polling from the UI loop.
--]]

local UIManager = require("ui/uimanager")
local logger = require("logger")
local JNI = require("voicecompanion/jni")

local AndroidPlayer = {
    name = "Android MediaPlayer",
    POLL_INTERVAL = 0.2,
}
AndroidPlayer.__index = AndroidPlayer

function AndroidPlayer.isAvailable()
    return JNI.available()
end

function AndroidPlayer:new()
    return setmetatable({}, self)
end

function AndroidPlayer:_release()
    local mp = self._mp
    self._mp = nil
    self._token = (self._token or 0) + 1
    if mp then
        JNI.run(function(J)
            pcall(J.call, J, mp, "stop", "()V")
            pcall(J.call, J, mp, "release", "()V")
            J:deleteGlobal(mp)
        end)
    end
end

--- Play `path`; `on_done(ok, err)` fires when playback ends or fails.
function AndroidPlayer:play(path, on_done)
    self:_release()
    self._paused = false
    local ok, result = JNI.run(function(J)
        local mp = J:new("android/media/MediaPlayer", "()V")
        J:call(mp, "setDataSource", "(Ljava/lang/String;)V", path)
        J:call(mp, "prepare", "()V")
        local duration = J:call(mp, "getDuration", "()I")
        J:call(mp, "start", "()V")
        return { mp = J:global(mp), duration = duration }
    end)
    if not ok then
        logger.warn("VoiceCompanion: MediaPlayer failed:", result)
        if on_done then UIManager:scheduleIn(0, function() on_done(false, result) end) end
        return false, result
    end
    self._mp = result.mp
    self._token = (self._token or 0) + 1
    local token = self._token
    local duration = result.duration or 0
    local idle_polls = 0

    local function poll()
        if token ~= self._token or not self._mp then return end
        if self._paused then
            UIManager:scheduleIn(self.POLL_INTERVAL, poll)
            return
        end
        local pok, state = JNI.run(function(J)
            return {
                playing = J:call(self._mp, "isPlaying", "()Z"),
                position = J:call(self._mp, "getCurrentPosition", "()I"),
            }
        end)
        if not pok then
            self:_release()
            if on_done then on_done(false, state) end
            return
        end
        -- Done when the player stopped on its own, confirmed on two polls
        -- (a single false reading right after start() is possible).
        if not state.playing then
            idle_polls = idle_polls + 1
        else
            idle_polls = 0
        end
        local at_end = duration > 0 and state.position >= duration - 50
        if idle_polls >= 2 or (at_end and not state.playing) then
            self:_release()
            if on_done then on_done(true) end
            return
        end
        UIManager:scheduleIn(self.POLL_INTERVAL, poll)
    end
    UIManager:scheduleIn(self.POLL_INTERVAL, poll)
    return true
end

function AndroidPlayer:pause()
    if not self._mp or self._paused then return end
    local ok = JNI.run(function(J) J:call(self._mp, "pause", "()V") end)
    if ok then self._paused = true end
end

function AndroidPlayer:resume()
    if not self._mp or not self._paused then return end
    local ok = JNI.run(function(J) J:call(self._mp, "start", "()V") end)
    if ok then self._paused = false end
end

function AndroidPlayer:isPaused()
    return self._paused and self._mp ~= nil
end

--- Stop playback; the pending on_done callback is not called.
function AndroidPlayer:stop()
    self._paused = false
    self:_release()
end

return AndroidPlayer
