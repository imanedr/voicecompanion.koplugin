--[[--
Capability tests, runnable one at a time from the menu.

Before each test starts, a "started" line is written (and flushed) to
diagnostics.log.  If KOReader crashes during a test, the next session sees
a test that started but never finished and reports it, so a crash is never
a mystery.
--]]

local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Async = require("voicecompanion/async")
local Config = require("voicecompanion/config")
local Provider = require("voicecompanion/provider")
local _ = require("gettext")

local Diagnostics = {}

--- The plugin's shared Voice (set by main.lua), so tests don't create
-- extra TTS engines.
function Diagnostics.setVoice(voice)
    Diagnostics.voice = voice
end

local function getVoice()
    if not Diagnostics.voice then
        Diagnostics.voice = require("voicecompanion/voice"):new()
    end
    return Diagnostics.voice
end

local function logPath()
    return Async.tempDir() .. "/diagnostics.log"
end

local function appendLog(line)
    local f = io.open(logPath(), "a")
    if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S "), line, "\n")
        f:close()
    end
end

--- If the last test started but never finished, return its name.
function Diagnostics.crashedTest()
    local f = io.open(logPath(), "r")
    if not f then return nil end
    local open = {}
    for line in f:lines() do
        local what, name = line:match("^%S+ %S+ (%u+) (.+)$")
        if name then name = name:gsub(" :: .*$", "") end
        if what == "START" then open[name] = true
        elseif what == "PASS" or what == "FAIL" then open[name] = nil end
    end
    f:close()
    return next(open)
end

function Diagnostics.clearLog()
    os.remove(logPath())
end

local function report(name, ok, detail)
    appendLog((ok and "PASS " or "FAIL ") .. name .. (detail and (" :: " .. detail) or ""))
    UIManager:show(InfoMessage:new{
        text = (ok and "✓ " or "✗ ") .. name .. (detail and ("\n\n" .. detail) or ""),
        timeout = ok and 4 or nil,
    })
end

--- Run `body(done)` as test `name`; body calls done(ok, detail).
local function runTest(name, body)
    appendLog("START " .. name)
    local finished = false
    local function done(ok, detail)
        if finished then return end
        finished = true
        report(name, ok, detail and tostring(detail) or nil)
    end
    local ok, err = pcall(body, done)
    if not ok then done(false, err) end
end

Diagnostics.TESTS = {}

local function add(id, title, body)
    table.insert(Diagnostics.TESTS, { id = id, title = title, run = function() runTest(title, body) end })
end

add("config", _("Configuration file"), function(done)
    local cfg, err = Config.load()
    if err then return done(false, err) end
    local p, perr = Config.activeProvider(cfg)
    if not p then return done(false, perr) end
    local lines = {
        (Config.exists() and _("configuration.lua found") or _("configuration.lua not created yet (using defaults)")),
        _("Provider: ") .. p.name .. " (" .. (p.base_url or "?") .. ")",
        _("API key: ") .. (Config.isKeyMissing(p.api_key) and _("MISSING") or ("…" .. p.api_key:sub(-4))),
        _("Voice engine: ") .. tostring(cfg.voice_engine),
    }
    done(not Config.isKeyMissing(p.api_key) or cfg.voice_engine == "local", table.concat(lines, "\n"))
end)

add("subprocess", _("Background requests"), function(done)
    local t0 = os.time()
    Async.run(function() return true, "pong" end, function(ok, payload)
        if ok and payload == "pong" then
            done(true, string.format(_("Background process works (%d s)."), os.time() - t0))
        else
            done(false, payload)
        end
    end, { timeout = 15 })
end)

add("player", _("Audio player (test tone)"), function(done)
    -- One second of a 440 Hz tone: tests playback without network or TTS.
    local rate, samples = 22050, 22050
    local parts = {}
    for i = 0, samples - 1 do
        local v = math.floor(math.sin(2 * math.pi * 440 * i / rate) * 8000)
        if v < 0 then v = v + 65536 end
        parts[#parts + 1] = string.char(v % 256, math.floor(v / 256))
    end
    local path = Async.tempDir() .. "/diagnostic_tone.wav"
    local ok, err = Provider.writeWav(path, table.concat(parts), rate)
    if not ok then return done(false, err) end
    local player
    if Device:isAndroid() then
        player = require("voicecompanion/audio/android_player"):new()
    else
        player = require("voicecompanion/audio/linux_player"):new()
    end
    UIManager:show(InfoMessage:new{ text = _("Playing a one-second beep…"), timeout = 2 })
    player:play(path, function(pok, perr)
        os.remove(path)
        done(pok, pok and _("You should have heard a beep.") or perr)
    end)
end)

add("cloud", _("Cloud voice (short phrase)"), function(done)
    local voice = getVoice()
    UIManager:show(InfoMessage:new{ text = _("Requesting cloud audio…"), timeout = 2 })
    voice:speak(_("Hello from Voice Companion."), { engine = "cloud" }, function(ok, err)
        done(ok, ok and _("You should have heard the cloud voice.") or err)
    end)
end)

add("local", _("Device voice (system TTS)"), function(done)
    local voice = getVoice()
    UIManager:show(InfoMessage:new{ text = _("Starting the device voice…"), timeout = 2 })
    voice:speak(_("This is the device voice."), { engine = "local" }, function(ok, err)
        done(ok, ok and _("You should have heard the device voice.") or err)
    end)
end)

return Diagnostics
