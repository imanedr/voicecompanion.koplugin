--[[--
Audio file playback on Linux (desktop KOReader) through an external player
(mpv, ffplay, paplay or aplay) running in a subprocess.
--]]

local UIManager = require("ui/uimanager")

local LinuxPlayer = {
    name = "Linux player",
    POLL_INTERVAL = 0.2,
    -- {binary, command template, plays mp3?}
    CANDIDATES = {
        { "mpv", "mpv --no-video --really-quiet %s", true },
        { "ffplay", "ffplay -nodisp -autoexit -loglevel quiet %s", true },
        { "paplay", "paplay %s", false },
        { "aplay", "aplay -q %s", false },
    },
}
LinuxPlayer.__index = LinuxPlayer

local function shellQuote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end
LinuxPlayer.shellQuote = shellQuote

local function commandExists(bin)
    local rc = os.execute("command -v " .. bin .. " >/dev/null 2>&1")
    return rc == 0 or rc == true
end

--- The first available player: { bin, template, mp3 }.
function LinuxPlayer.detect()
    if LinuxPlayer._detected ~= nil then return LinuxPlayer._detected or nil end
    for _, c in ipairs(LinuxPlayer.CANDIDATES) do
        if commandExists(c[1]) then
            LinuxPlayer._detected = { bin = c[1], template = c[2], mp3 = c[3] }
            return LinuxPlayer._detected
        end
    end
    LinuxPlayer._detected = false
    return nil
end

function LinuxPlayer.isAvailable()
    return LinuxPlayer.detect() ~= nil
end

--- True if the detected player can play MP3 (otherwise request PCM/WAV).
function LinuxPlayer.canPlayMp3()
    local d = LinuxPlayer.detect()
    return d ~= nil and d.mp3
end

function LinuxPlayer:new()
    return setmetatable({}, self)
end

function LinuxPlayer:play(path, on_done)
    self:stop()
    local d = LinuxPlayer.detect()
    if not d then
        if on_done then UIManager:scheduleIn(0, function() on_done(false, "no audio player found (install mpv)") end) end
        return false
    end
    local ffiutil = require("ffi/util")
    local cmd = string.format(d.template, shellQuote(path))
    local rc_path = path .. ".rc"
    os.remove(rc_path)
    local pid = ffiutil.runInSubProcess(function()
        local rc = os.execute(cmd .. " 2>" .. shellQuote(rc_path .. ".err") .. " >/dev/null")
        local f = io.open(rc_path, "w")
        if f then f:write(tostring(rc)) f:close() end
    end)
    if not pid then
        if on_done then UIManager:scheduleIn(0, function() on_done(false, "could not start the audio player") end) end
        return false
    end
    self._pid = pid
    self._paused = false
    local function poll()
        if self._pid ~= pid then return end
        if ffiutil.isSubProcessDone(pid) then
            self._pid = nil
            local f = io.open(rc_path, "r")
            local rc = f and f:read("*a")
            if f then f:close() end
            local ef = io.open(rc_path .. ".err", "r")
            local stderr = ef and ef:read("*a") or ""
            if ef then ef:close() end
            os.remove(rc_path)
            os.remove(rc_path .. ".err")
            local ok = rc == "0" or rc == "true"
            if on_done then
                on_done(ok, not ok and (d.bin .. " failed: " .. stderr:gsub("%s+", " "):sub(1, 200)) or nil)
            end
            return
        end
        UIManager:scheduleIn(self.POLL_INTERVAL, poll)
    end
    UIManager:scheduleIn(self.POLL_INTERVAL, poll)
    return true
end

function LinuxPlayer:pause()
    if self._pid and not self._paused then
        os.execute("kill -STOP -" .. self._pid .. " 2>/dev/null")
        self._paused = true
    end
end

function LinuxPlayer:resume()
    if self._pid and self._paused then
        os.execute("kill -CONT -" .. self._pid .. " 2>/dev/null")
        self._paused = false
    end
end

function LinuxPlayer:isPaused()
    return self._paused and self._pid ~= nil
end

function LinuxPlayer:stop()
    local pid = self._pid
    self._pid = nil
    if pid then
        local ffiutil = require("ffi/util")
        if self._paused then os.execute("kill -CONT -" .. pid .. " 2>/dev/null") end
        ffiutil.terminateSubProcess(pid)
        local function reap()
            if not ffiutil.isSubProcessDone(pid) then UIManager:scheduleIn(0.2, reap) end
        end
        reap()
    end
    self._paused = false
end

return LinuxPlayer
