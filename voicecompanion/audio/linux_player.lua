--[[--
Audio file playback on Linux (desktop KOReader) through an external player
(mpv, ffplay, paplay or aplay) running in a subprocess.
--]]

local UIManager = require("ui/uimanager")

local has_socket, socket = pcall(require, "socket")
local now = has_socket and socket.gettime or os.time

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

--- Duration in ms of a PCM WAV file, or nil (other formats, bad header).
function LinuxPlayer.wavDuration(path)
    if not path:find("%.wav$") then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    local header = f:read(44)
    local size = f:seek("end")
    f:close()
    if not header or #header < 44 or header:sub(1, 4) ~= "RIFF" then return nil end
    local b1, b2, b3, b4 = header:byte(29, 32)
    local byte_rate = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
    if byte_rate <= 0 then return nil end
    return (size - 44) / byte_rate * 1000
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
    self._started, self._paused_at, self._paused_total = now(), nil, 0
    self._duration = LinuxPlayer.wavDuration(path)
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
        self._paused_at = now()
    end
end

function LinuxPlayer:resume()
    if self._pid and self._paused then
        os.execute("kill -CONT -" .. self._pid .. " 2>/dev/null")
        self._paused = false
        if self._paused_at then
            self._paused_total = self._paused_total + (now() - self._paused_at)
            self._paused_at = nil
        end
    end
end

--- ms played (wall clock minus pauses) and ms total (WAV only, else nil).
function LinuxPlayer:progress()
    if not self._pid or not self._started then return nil end
    local t = (self._paused_at or now()) - self._started - (self._paused_total or 0)
    return math.max(0, t * 1000), self._duration
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
