--[[--
The one place features go to make sound.

    voice:speak(text, { engine = "cloud"|"local", speed = 0.7 }, on_done)
    voice:prepare(text, opts, on_ready)   -- fetch ahead (cloud), no sound
    voice:stop() / pause() / resume()
    voice:progress()                      -- ms played, ms total (or nil)
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
    o._handles = {}      -- cache path -> Async handle (cancelled by stop())
    o._fetching = 0      -- requests in flight
    o._fetches = 0       -- requests started (the cache is trimmed every so often)
    o._gen = 0           -- bumps on stop(): stale callbacks are ignored
    o._seq = 0           -- bumps when a sequence starts or stop() is called
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

--- Errors worth one more try: network trouble, rate limits, server errors.
function Voice.isRetryable(err)
    err = tostring(err or "")
    return err:find("^network error") ~= nil or err:find("^HTTP 5%d%d") ~= nil
        or err:find("^HTTP 429") ~= nil or err:find("empty audio response", 1, true) ~= nil
end

Voice.RETRY_DELAY = 1.5
Voice.TRIM_EVERY = 25   -- requests between cache trims

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
    local trim = format == "pcm" and cfg.trim_silence ~= false
    -- Settings that change the sound beyond the basic key.
    local extra = {}
    if format == "pcm" then
        table.insert(extra, "rate=" .. tostring(p.sample_rate or 24000))
        if trim then table.insert(extra, "trim") end
    end
    local tts_extra = opts.extra or p.tts_extra
    if type(tts_extra) == "table" and next(tts_extra) ~= nil then
        table.insert(extra, Config.serialize(tts_extra, ""))
    end
    return {
        engine = "cloud",
        provider = p,
        format = format,
        voice = voice,
        speed = speed,
        trim = trim,
        path = AudioCache.path({ provider = p.name, model = p.tts_model, voice = voice, speed = speed,
            format = format, text = text, extra = table.concat(extra, ";") }, format == "pcm" and "wav" or "mp3"),
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
    local timeout = cfg.timeout
    if plan.engine == "cloud" then
        local p, path = plan.provider, plan.path
        local req = { voice = plan.voice, speed = plan.speed, format = plan.format, trim_silence = plan.trim }
        local delay = Voice.RETRY_DELAY
        work = function()
            local ok, res = Provider.speech(p, text, path, req)
            if not ok and Voice.isRetryable(res) then
                local has_socket_c, sock = pcall(require, "socket")
                if has_socket_c and sock.sleep then sock.sleep(delay) end
                ok, res = Provider.speech(p, text, path, req)
            end
            return ok, res
        end
        -- Room for the retry.
        timeout = (cfg.timeout or 60) * 2 + delay
    else
        local local_cfg, path, rate = cfg.local_tts, plan.path, plan.rate
        work = function()
            return require("voicecompanion/tts/cli").synthesize(local_cfg, text, path, rate)
        end
    end
    local started = now()
    self._fetching = self._fetching + 1
    self._fetches = self._fetches + 1
    if self._fetches % Voice.TRIM_EVERY == 1 then
        local ok, err = pcall(AudioCache.trim, cfg.cache_mb)
        if not ok then logger.warn("VoiceCompanion: cache trim failed:", err) end
    end
    timing("fetch start  %s, %d chars", plan.engine, #text)
    self._handles[plan.path] = Async.run(work, function(ok, payload)
        self._inflight[plan.path] = nil
        self._handles[plan.path] = nil
        self._fetching = math.max(0, self._fetching - 1)
        timing("fetch %s %.2fs, %d chars", ok and "done " or "FAIL ", now() - started, #text)
        if not ok then logger.warn("VoiceCompanion: synthesis failed:", payload) end
        for _, cb in ipairs(waiting) do
            local cok, cerr = pcall(cb, ok, payload)
            if not cok then logger.err("VoiceCompanion: callback error:", cerr) end
        end
    end, { timeout = timeout })
end

--- Cancel every request in flight (their callbacks are dropped).
function Voice:_cancelFetches()
    local handles = self._handles
    self._handles = {}
    self._inflight = {}
    self._fetching = 0
    for _, h in pairs(handles) do
        if h and h.cancel then h:cancel() end
    end
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

--- "ready" (cached or nothing to fetch), "fetching", "missing", or "error".
function Voice:_audioState(text, opts, cfg)
    local plan = self:_plan(text, opts, cfg)
    if not plan then return "error" end
    if plan.engine == "android" or AudioCache.has(plan.path) then return "ready" end
    if self._inflight[plan.path] then return "fetching" end
    return "missing"
end

--- Speak `text`.  on_done(ok, err) fires after playback ends or on failure;
-- it is not called if stop() interrupts.
function Voice:speak(text, opts, on_done)
    self:_speak(text, opts or {}, on_done or function() end, {})
end

--- speak() with internal hooks:
--   seq = true: part of a sequence (don't report "idle" when this item ends)
--   on_ready(): the audio is ready (or not needed); time to fetch ahead
--   on_play(): playback has just started
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
    local play_started
    local function done(ok, e)
        if gen ~= self._gen then return end
        self.busy = false
        self._play_started = nil
        if play_started then
            self._last_end = now()
            timing("end          %d chars, %.2fs", #text, self._last_end - play_started)
        end
        if not internal.seq or not ok then self:_setState("idle") end
        on_done(ok, e)
    end
    local function started()
        play_started = now()
        self._play_started = play_started
        local gap = self._last_end and (play_started - self._last_end)
        if gap and gap < 60 then
            timing("play         %d chars, gap %.2fs", #text, gap)
        else
            timing("play         %d chars", #text)
        end
        if internal.on_play then internal.on_play() end
    end

    if plan.engine == "android" then
        self._active = "android"
        self:_setState("playing")
        local tts = self:_androidTts(cfg)
        tts:speak(text, done, { rate = opts.speed and (cfg.local_tts.rate or 1) * opts.speed or nil })
        started()
        if internal.on_ready then internal.on_ready() end
        return
    end
    self._active = "player"
    if not AudioCache.has(plan.path) then self:_setState("loading") end
    self:_fetch(text, plan, cfg, function(ok, path_or_err)
        if gen ~= self._gen then return end
        if not ok then return done(false, path_or_err) end
        self:_setState("playing")
        self:_player():play(path_or_err, done)
        started()
        if internal.on_ready then internal.on_ready() end
    end)
end

--- Speak a list of texts in order, fetching ahead while one plays.
-- @param items table  array of strings, or a function(i) -> string|nil
--   (a function lets the caller produce items lazily, e.g. book sentences)
-- @param opts table  speak options plus `prefetch` (items fetched ahead)
--   and `parallel` (requests at once while fetching ahead)
-- @param hooks table { on_item = function(i, text), on_play = function(i, text),
--   on_done = function(ok, err) }
function Voice:speakSequence(items, opts, hooks)
    opts = opts or {}
    hooks = hooks or {}
    local get = type(items) == "function" and items or function(i) return items[i] end
    local prefetch = opts.prefetch or 2
    local parallel = math.max(1, opts.parallel or 2)
    self:_halt()
    self._seq = self._seq + 1
    local seq = self._seq
    local seq_gen = self._gen
    local index = 0
    -- The current item's audio is ready: only then fetch ahead, so the
    -- requests made ahead never delay the one being waited for.
    local current_ready = false

    -- Keep up to `prefetch` items ahead fetched, `parallel` requests at a
    -- time.  Called when the current item is ready and whenever a request
    -- made ahead completes.
    local function fill()
        if seq ~= self._seq or not current_ready then return end
        local cfg = Config.load()
        for k = 1, prefetch do
            local ahead = get(index + k)
            if not ahead then return end
            local state = self:_audioState(ahead, opts, cfg)
            if state == "error" then return end
            if state == "missing" then
                if self._fetching >= parallel then return end
                self:prepare(ahead, opts, function(ok)
                    -- A failure is left for the item itself to report.
                    if ok then fill() end
                end)
            end
        end
    end

    local function playNext()
        if seq_gen ~= self._gen or seq ~= self._seq then return end
        index = index + 1
        current_ready = false
        local text = get(index)
        if not text then
            self.busy = false
            self:_setState("idle")
            if hooks.on_done then hooks.on_done(true) end
            return
        end
        local i = index
        if hooks.on_item then hooks.on_item(i, text) end
        -- _speak() bumps the generation; keep our sequence id in step.
        self:_speak(text, opts, function(ok, err)
            if not ok then
                self.busy = false
                if hooks.on_done then hooks.on_done(false, err) end
                return
            end
            playNext()
        end, {
            seq = true,
            on_ready = function()
                current_ready = true
                fill()
            end,
            on_play = hooks.on_play and function() hooks.on_play(i, text) end,
        })
        seq_gen = self._gen
    end
    playNext()
end

--- Silence everything and invalidate pending callbacks, without reporting
-- a state change (used between items).
function Voice:_halt()
    self._gen = self._gen + 1
    self.busy = false
    self._play_started = nil
    if self.player then self.player:stop() end
    if self.android_tts then self.android_tts:stop() end
end

--- Stop playback and drop every pending request.
function Voice:stop()
    self._seq = self._seq + 1
    self:_halt()
    self:_cancelFetches()
    self._last_end = nil
    self:_setState("idle")
end

--- Playback position: ms played and ms total (total is nil when unknown).
-- nil when nothing is playing.
function Voice:progress()
    if self._active == "player" then
        if self.player and self.player.progress and self.state ~= "loading" and self.state ~= "idle" then
            return self.player:progress()
        end
        return nil
    end
    if self._active == "android" and self._play_started then
        return (now() - self._play_started) * 1000, nil
    end
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
