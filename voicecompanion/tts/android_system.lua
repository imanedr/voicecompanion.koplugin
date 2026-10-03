--[[--
Android system text-to-speech (android.speech.tts.TextToSpeech) via JNI.

No helper .dex and no Java listener classes: the engine is created with a
null OnInitListener (allowed by the framework), readiness is detected by
retrying speak() until the engine is bound, and the end of an utterance is
detected by polling isSpeaking().  The engine is created on first use only.
--]]

local UIManager = require("ui/uimanager")
local logger = require("logger")
local JNI = require("voicecompanion/jni")

local TTS_CLASS = "android/speech/tts/TextToSpeech"
local QUEUE_FLUSH = 0
local SUCCESS = 0

local AndroidTts = {
    name = "Android system voice",
    POLL_INTERVAL = 0.2,
    BIND_TIMEOUT = 10,     -- seconds to wait for the engine to bind
    START_TIMEOUT = 5,     -- seconds for speech to begin after speak()
}
AndroidTts.__index = AndroidTts

function AndroidTts.isAvailable()
    return JNI.available()
end

function AndroidTts:new(o)
    o = setmetatable(o or {}, self)
    o.language = o.language or "en-US"
    o.rate = o.rate or 1.0
    o.pitch = o.pitch or 1.0
    o._utterance = 0
    return o
end

function AndroidTts:_ensureEngine()
    if self._tts then return true end
    local ok, result = JNI.run(function(J)
        local tts = J:new(TTS_CLASS,
            "(Landroid/content/Context;Landroid/speech/tts/TextToSpeech$OnInitListener;)V",
            J:appContext(), nil)
        return J:global(tts)
    end)
    if not ok then return false, result end
    self._tts = result
    self._configured = false
    return true
end

--- Apply language/rate/pitch.  Returns false while the engine is unbound.
function AndroidTts:_configure(J)
    local locale = J:callStatic("java/util/Locale", "forLanguageTag",
        "(Ljava/lang/String;)Ljava/util/Locale;", self.language)
    local lang_result = J:call(self._tts, "setLanguage", "(Ljava/util/Locale;)I", locale)
    J:call(self._tts, "setSpeechRate", "(F)I", self.rate)
    J:call(self._tts, "setPitch", "(F)I", self.pitch)
    -- -2 = LANG_NOT_SUPPORTED, -1 = LANG_MISSING_DATA (or unbound)
    return lang_result
end

function AndroidTts:setOptions(opts)
    if opts.language then self.language = opts.language end
    if opts.rate then self.rate = opts.rate end
    if opts.pitch then self.pitch = opts.pitch end
    self._configured = false
end

--- Speak `text`; `on_done(ok, err)` fires when speech ends or fails.
-- @param opts table|nil { rate = number } one-off rate for this utterance
function AndroidTts:speak(text, on_done, opts)
    opts = opts or {}
    local ok, err = self:_ensureEngine()
    if not ok then
        if on_done then UIManager:scheduleIn(0, function() on_done(false, err) end) end
        return
    end
    self._utterance = self._utterance + 1
    local id = self._utterance
    local started = os.time()
    local phase = "binding"
    local seen_speaking = false

    local function fail(msg)
        if id ~= self._utterance then return end
        self._utterance = self._utterance + 1
        if on_done then on_done(false, msg) end
    end

    local function poll()
        if id ~= self._utterance then return end   -- stopped or replaced
        if phase == "binding" then
            local pok, res = JNI.run(function(J)
                if not self._configured or opts.rate then
                    local lang = self:_configure(J)
                    if opts.rate then J:call(self._tts, "setSpeechRate", "(F)I", opts.rate) end
                    if lang ~= nil and lang >= 0 then self._configured = not opts.rate end
                    if lang == -2 then
                        logger.warn("VoiceCompanion: TTS language not supported:", self.language)
                    end
                end
                return J:call(self._tts, "speak",
                    "(Ljava/lang/CharSequence;ILandroid/os/Bundle;Ljava/lang/String;)I",
                    text, QUEUE_FLUSH, nil, "vc" .. id)
            end)
            if not pok then return fail(res) end
            if res == SUCCESS then
                phase = "speaking"
                started = os.time()
            elseif os.time() - started > self.BIND_TIMEOUT then
                return fail("the Android TTS engine did not start (is a TTS engine installed and set as default?)")
            end
            UIManager:scheduleIn(self.POLL_INTERVAL, poll)
            return
        end
        -- phase == "speaking"
        local pok, speaking = JNI.run(function(J)
            return J:call(self._tts, "isSpeaking", "()Z")
        end)
        if not pok then return fail(speaking) end
        if speaking then
            seen_speaking = true
        elseif seen_speaking or os.time() - started > self.START_TIMEOUT then
            self._utterance = self._utterance + 1
            if on_done then on_done(seen_speaking, not seen_speaking and "no speech was produced" or nil) end
            return
        end
        UIManager:scheduleIn(self.POLL_INTERVAL, poll)
    end
    UIManager:scheduleIn(0, poll)
end

--- Stop speaking; the pending on_done callback is not called.
function AndroidTts:stop()
    self._utterance = self._utterance + 1
    if self._tts then
        JNI.run(function(J) J:call(self._tts, "stop", "()I") end)
    end
end

--- Release the engine (plugin teardown).
function AndroidTts:shutdown()
    self:stop()
    local tts = self._tts
    self._tts = nil
    if tts then
        JNI.run(function(J)
            pcall(J.call, J, tts, "shutdown", "()V")
            J:deleteGlobal(tts)
        end)
    end
end

--- Installed voices' language tags (for the settings menu).
function AndroidTts:listLanguages()
    local ok, err = self:_ensureEngine()
    if not ok then return nil, err end
    return JNI.run(function(J)
        local set = J:call(self._tts, "getAvailableLanguages", "()Ljava/util/Set;")
        if set == nil then return {} end
        local arr = J:call(set, "toArray", "()[Ljava/lang/Object;")
        local n = J.env[0].GetArrayLength(J.env, arr)
        local out = {}
        for i = 0, n - 1 do
            local loc = J.env[0].GetObjectArrayElement(J.env, arr, i)
            J:check("GetObjectArrayElement")
            J:_track(loc)
            table.insert(out, J:str(J:call(loc, "toLanguageTag", "()Ljava/lang/String;")))
        end
        table.sort(out)
        return out
    end)
end

return AndroidTts
