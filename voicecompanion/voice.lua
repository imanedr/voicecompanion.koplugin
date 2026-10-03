--[[--
The one place features go to make sound.

    voice:speak(text, { engine = "cloud"|"local", speed = 0.7 }, on_done)
    voice:prepare(text, opts, on_ready)   -- fetch ahead (cloud), no sound
    voice:stop() / pause() / resume()
    voice.on_state = function(state) end  -- "loading"|"playing"|"paused"|"idle"

Cloud voices: provider speech -> audio cache -> player.  Requests for the
same audio are shared, so a prefetch and a later speak() cost one call.
Local voices: Android system TTS on Android; a command-line engine plus the
player on Linux.
--]]

local Device = require("device")
local logger = require("logger")
local Async = require("voicecompanion/async")
local AudioCache = require("voicecompanion/audiocache")
local Config = require("voicecompanion/config")
local Provider = require("voicecompanion/provider")

local Voice = {}
Voice.__index = Voice

local has_socket, socket = pcall(require, "socket")
local now = has_socket and socket.gettime or os.time

local TIMING_LOG_MAX = 64 * 1024

--- Append a line to cache/voicecompanion/timing.log (kept small), so slow
-- starts can be diagnosed on a device without logcat.
local function timing(fmt, ...)
    local line = string.format(fmt, ...)
    local ok, err = pcall(function()
        local path = Async.tempDir() .. "/timing.log"
        local f = io.open(path, "a")
        if not f then return end
        if f:seek("end") > TIMING_LOG_MAX then
            f:close()
            f = io.open(path, "w")
            if not f then return end
        end
        f:write(os.date("%H:%M:%S "), line, "\n")
        f:close()
    end)
    if not ok then logger.dbg("VoiceCompanion: timing log failed:", err) end
end

function Voice:new()
    local o = setmetatable({}, self)
    o._inflight = {}     -- cache path -> { callbacks }
    o._gen = 0           -- bumps on stop(): stale callbacks are ignored
    o.state = "idle"
    return o
end

--- Report a playback state change to `self.on_state` (if set).
function Voice:_setState(state)
    if self.state == state then return end
    self.state = state
    if self.on_state then
        local ok, err = pcall(self.on_state, state)
        if not ok then logger.err("VoiceCompanion: on_state failed:", err) end
    end
end

function Voice:_player()
    if not self.player then
        if Device:isAndroid() then
            self.player = require("voicecompanion/audio/android_player"):new()
        else
            self.player = require("voicecompanion/audio/linux_player"):new()
        end
    end
    return self.player
end

function Voice:_androidTts(cfg)
    if not self.android_tts then
        self.android_tts = require("voicecompanion/tts/android_system"):new{
            language = cfg.local_tts.language, rate = cfg.local_tts.rate, pitch = cfg.local_tts.pitch,
        }
    else
        self.android_tts:setOptions{
            language = cfg.local_tts.language, rate = cfg.local_tts.rate, pitch = cfg.local_tts.pitch,
        }
    end
    return self.android_tts
end

--- Resolve what a request would produce: engine, cache path, request opts.
function Voice:_plan(text, opts, cfg)
    local engine = opts.engine or cfg.voice_engine or "cloud"
    if engine == "local" then
        if Device:isAndroid() then
            return { engine = "android" }
        end
        local rate = (cfg.local_tts.rate or 1) * (opts.speed or 1)
        return {
            engine = "cli",
            path = AudioCache.path({ provider = "local", model = cfg.local_tts.command or "auto",
                voice = cfg.local_tts.language, speed = rate, format = "wav", text = text }, "wav"),
            rate = rate,
        }
    end
    local p, perr = Config.activeProvider(cfg)
    if not p then return nil, perr end
    if Config.isKeyMissing(p.api_key) then
        return nil, string.format("No API key for provider %q. Add it in configuration.lua or Settings.", p.name)
    end
    local format = p.audio_format or "mp3"
    if not Device:isAndroid() and format == "mp3" then
        local LinuxPlayer = require("voicecompanion/audio/linux_player")
        if not LinuxPlayer.canPlayMp3() then format = "pcm" end
    end
    local voice = opts.voice or p.voice
    local speed = opts.speed or 1.0
    return {
        engine = "cloud",
        provider = p,
        format = format,
        voice = voice,
        speed = speed,
        path = AudioCache.path({ provider = p.name, model = p.tts_model, voice = voice, speed = speed,
            format = format, text = text }, format == "pcm" and "wav" or "mp3"),
    }
end

--- Make sure the audio file for `plan` exists; on_ready(ok, path_or_err).
function Voice:_fetch(text, plan, cfg, on_ready)
    if AudioCache.has(plan.path) then
        on_ready(true, plan.path)
        return
    end
    local waiting = self._inflight[plan.path]
    if waiting then
        table.insert(waiting, on_ready)
        return
    end
    waiting = { on_ready }
    self._inflight[plan.path] = waiting
    local work
    if plan.engine == "cloud" then
        local p, path = plan.provider, plan.path
        local req = { voice = plan.voice, speed = plan.speed, format = plan.format }
        work = function() return Provider.speech(p, text, path, req) end
    else
        local local_cfg, path, rate = cfg.local_tts, plan.path, plan.rate
        work = function()
            return require("voicecompanion/tts/cli").synthesize(local_cfg, text, path, rate)
        end
    end
    local started = now()
    timing("fetch start  %s, %d chars", plan.engine, #text)
    Async.run(work, function(ok, payload)
        self._inflight[plan.path] = nil
        timing("fetch %s %.2fs, %d chars", ok and "done " or "FAIL ", now() - started, #text)
        if not ok then logger.warn("VoiceCompanion: synthesis failed:", payload) end
        for _, cb in ipairs(waiting) do
            local cok, cerr = pcall(cb, ok, payload)
            if not cok then logger.err("VoiceCompanion: callback error:", cerr) end
        end
    end, { timeout = cfg.timeout })
end

--- Fetch audio ahead of time without playing it.  Android local voices
-- speak directly and need no preparation.
function Voice:prepare(text, opts, on_ready)
    local cfg = Config.load()
    local plan, err = self:_plan(text, opts or {}, cfg)
    if not plan then
        if on_ready then on_ready(false, err) end
        return
    end
    if plan.engine == "android" then
        if on_ready then on_ready(true) end
        return
    end
    self:_fetch(text, plan, cfg, on_ready or function() end)
end

--- Speak `text`.  on_done(ok, err) fires after playback ends or on failure;
-- it is not called if stop() interrupts.
function Voice:speak(text, opts, on_done)
    self:_speak(text, opts or {}, on_done or function() end, {})
end

--- speak() with internal hooks:
--   seq = true: part of a sequence (don't report "idle" when this item ends)
--   on_ready(): the audio is ready (or not needed); time to fetch ahead
function Voice:_speak(text, opts, on_done, internal)
    self:_halt()
    local gen = self._gen
    local function fail(err)
        self:_setState("idle")
        on_done(false, err)
    end
    local cfg, cfg_err = Config.load()
    if cfg_err then return fail("configuration.lua has an error: " .. cfg_err) end
    local plan, err = self:_plan(text, opts, cfg)
    if not plan then return fail(err) end

    self.busy = true
    local function done(ok, e)
        if gen ~= self._gen then return end
        self.busy = false
        if not internal.seq or not ok then self:_setState("idle") end
        on_done(ok, e)
    end

    if plan.engine == "android" then
        self._active = "android"
        self:_setState("playing")
        local tts = self:_androidTts(cfg)
        tts:speak(text, done, { rate = opts.speed and (cfg.local_tts.rate or 1) * opts.speed or nil })
        if internal.on_ready then internal.on_ready() end
        return
    end
    self._active = "player"
    if not AudioCache.has(plan.path) then self:_setState("loading") end
    self:_fetch(text, plan, cfg, function(ok, path_or_err)
        if gen ~= self._gen then return end
        if not ok then return done(false, path_or_err) end
        timing("play         %d chars", #text)
        self:_setState("playing")
        self:_player():play(path_or_err, done)
        if internal.on_ready then internal.on_ready() end
    end)
end

--- Speak a list of texts in order, fetching ahead while one plays.
-- @param items table  array of strings, or a function(i) -> string|nil
--   (a function lets the caller produce items lazily, e.g. book sentences)
-- @param opts table  speak options plus `prefetch` (items fetched ahead)
-- @param hooks table { on_item = function(i, text), on_done = function(ok, err) }
function Voice:speakSequence(items, opts, hooks)
    opts = opts or {}
    hooks = hooks or {}
    local get = type(items) == "function" and items or function(i) return items[i] end
    local prefetch = opts.prefetch or 2
    self:_halt()
    local seq_gen = self._gen
    local index = 0

    local function playNext()
        if seq_gen ~= self._gen then return end
        index = index + 1
        local text = get(index)
        if not text then
            self.busy = false
            self:_setState("idle")
            if hooks.on_done then hooks.on_done(true) end
            return
        end
        if hooks.on_item then hooks.on_item(index, text) end
        local base = index
        -- Fetch ahead only once the current item's audio is ready, one item
        -- at a time: parallel requests slow down the one being waited for.
        local function prefetchFrom(k, gen)
            if k > prefetch or gen ~= self._gen then return end
            local ahead = get(base + k)
            if not ahead then return end
            self:prepare(ahead, opts, function() prefetchFrom(k + 1, gen) end)
        end
        -- _speak() bumps the generation; keep our sequence id in step.
        self:_speak(text, opts, function(ok, err)
            if not ok then
                self.busy = false
                if hooks.on_done then hooks.on_done(false, err) end
                return
            end
            playNext()
        end, { seq = true, on_ready = function() prefetchFrom(1, self._gen) end })
        seq_gen = self._gen
    end
    playNext()
end

--- Silence everything and invalidate pending callbacks, without reporting
-- a state change (used between items).
function Voice:_halt()
    self._gen = self._gen + 1
    self.busy = false
    if self.player then self.player:stop() end
    if self.android_tts then self.android_tts:stop() end
end

function Voice:stop()
    self:_halt()
    self:_setState("idle")
end

--- Pause/resume apply to file playback (cloud voices, Linux local voices).
-- Android system speech cannot pause, nor can audio that is still loading;
-- callers should stop and re-speak.
function Voice:canPause()
    return self._active == "player" and self.state == "playing"
end

function Voice:pause()
    if self:canPause() then
        self.player:pause()
        self:_setState("paused")
    end
end

function Voice:resume()
    if self.player and self._active == "player" and self:isPaused() then
        self.player:resume()
        self:_setState("playing")
    end
end

function Voice:isPaused()
    return self.player and self._active == "player" and self.player:isPaused() or false
end

function Voice:shutdown()
    self:stop()
    if self.android_tts then self.android_tts:shutdown() end
end

return Voice
