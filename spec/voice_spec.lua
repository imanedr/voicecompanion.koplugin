-- Integration: Voice + Async + Provider + AudioCache + Config with fake
-- network and a fake player.
local Stubs = require("spec/stubs")
local UIManager = require("ui/uimanager")
local Device = require("device")

package.preload["voicecompanion/audio/linux_player"] = function()
    return { canPlayMp3 = function() return false end, isAvailable = function() return true end }
end

local Config = require("voicecompanion/config")
local Voice = require("voicecompanion/voice")

local PCM = string.rep("\1\2", 200)

local function fakePlayer()
    local player = { played = {}, stopped = 0 }
    function player:play(path, cb)
        table.insert(self.played, path)
        UIManager:scheduleIn(0, function() cb(true) end)
    end
    function player:stop() self.stopped = self.stopped + 1 end
    function player:pause() end
    function player:resume() end
    function player:isPaused() return false end
    return player
end

local function newVoice()
    local voice = Voice:new()
    voice.player = fakePlayer()
    return voice
end

describe("Voice (cloud engine, fake player and network)", function()
    before_each(function()
        Stubs.cleanTmp()
        Stubs.http.reset()
        Stubs.http.handler = function() return 200, PCM end
        UIManager._reset()
        Device.android = false
        Config.file = Stubs.TMP .. "/configuration.lua"
        local f = assert(io.open(Config.file, "w"))
        f:write('return { providers = { openrouter = { api_key = "sk-test" } } }')
        f:close()
    end)

    it("speaks text: one request, player gets a WAV, callback fires", function()
        local voice = newVoice()
        local result
        voice:speak("Hello", { engine = "cloud" }, function(ok, err) result = { ok = ok, err = err } end)
        UIManager._drain()
        assert_true(result and result.ok, result and tostring(result.err))
        assert_eq(#Stubs.http.requests, 1)
        assert_eq(#voice.player.played, 1)
        assert_match(voice.player.played[1], "%.wav$")
        assert_match(Stubs.http.requests[1].body, '"response_format":"pcm"')
    end)

    it("serves a repeat from the cache without a new request", function()
        local voice = newVoice()
        local n = 0
        voice:speak("Hello", { engine = "cloud" }, function() n = n + 1 end)
        UIManager._drain()
        voice:speak("Hello", { engine = "cloud" }, function() n = n + 1 end)
        UIManager._drain()
        assert_eq(n, 2)
        assert_eq(#Stubs.http.requests, 1)
        assert_eq(#voice.player.played, 2)
        assert_eq(voice.player.played[1], voice.player.played[2])
    end)

    it("shares one request between prepare and speak", function()
        local voice = newVoice()
        local prepared, spoken
        voice:prepare("Hello", { engine = "cloud" }, function(ok) prepared = ok end)
        voice:speak("Hello", { engine = "cloud" }, function(ok) spoken = ok end)
        UIManager._drain()
        assert_eq(prepared, true)
        assert_eq(spoken, true)
        assert_eq(#Stubs.http.requests, 1)
    end)

    it("stop() before the work completes suppresses the callback", function()
        local voice = newVoice()
        local called = false
        voice:speak("Hello", { engine = "cloud" }, function() called = true end)
        voice:stop()
        UIManager._drain()
        assert_eq(called, false)
        assert_eq(#voice.player.played, 0)
    end)

    it("fails clearly without an API key", function()
        local f = assert(io.open(Config.file, "w"))
        f:write("return {}")
        f:close()
        local voice = newVoice()
        local ok, err
        voice:speak("Hello", { engine = "cloud" }, function(o, e) ok, err = o, e end)
        assert_eq(ok, false)
        assert_match(err, "No API key")
        assert_eq(#Stubs.http.requests, 0)
    end)

    it("reports provider errors to the callback", function()
        Stubs.http.handler = function() return 401, '{"error":{"message":"bad key"}}' end
        local voice = newVoice()
        local ok, err
        voice:speak("Hello", { engine = "cloud" }, function(o, e) ok, err = o, e end)
        UIManager._drain()
        assert_eq(ok, false)
        assert_match(err, "HTTP 401")
        assert_eq(#voice.player.played, 0)
    end)

    it("reports a configuration error", function()
        local f = assert(io.open(Config.file, "w"))
        f:write("return {")
        f:close()
        local ok, err
        newVoice():speak("Hello", {}, function(o, e) ok, err = o, e end)
        assert_eq(ok, false)
        assert_match(err, "configuration.lua has an error")
    end)

    it("speakSequence plays items in order and finishes with on_done(true)", function()
        local voice = newVoice()
        local items, done = {}, nil
        Stubs.http.handler = function(req) return 200, PCM .. req.body end   -- distinct audio per text
        voice:speakSequence({ "A.", "B.", "C." }, { engine = "cloud" }, {
            on_item = function(i, text) table.insert(items, i .. ":" .. text) end,
            on_done = function(ok) done = ok end,
        })
        UIManager._drain()
        assert_eq(items, { "1:A.", "2:B.", "3:C." })
        assert_eq(done, true)
        assert_eq(#voice.player.played, 3)
        assert_eq(#Stubs.http.requests, 3, "each text fetched once, prefetch must not duplicate")
    end)

    it("speakSequence stops with on_done(false) on failure", function()
        Stubs.http.handler = function() return 500, "boom" end
        local voice = newVoice()
        local done, err
        voice:speakSequence({ "A.", "B." }, { engine = "cloud" }, {
            on_done = function(ok, e) done, err = ok, e end,
        })
        UIManager._drain()
        assert_eq(done, false)
        assert_match(err, "HTTP 500")
    end)

    it("speakSequence fetches ahead only after the current item's audio is ready", function()
        local voice = newVoice()
        Stubs.http.handler = function(req) return 200, PCM .. req.body end
        voice:speakSequence({ "A.", "B.", "C." }, { engine = "cloud", prefetch = 2 }, {})
        assert_eq(#Stubs.http.requests, 1, "only the first item is requested up front")
        UIManager._drain()
        assert_eq(#Stubs.http.requests, 3)
        assert_eq(#voice.player.played, 3)
    end)

    it("reports states: loading, playing, idle (none between sequence items)", function()
        local voice = newVoice()
        local states = {}
        voice.on_state = function(s) table.insert(states, s) end
        Stubs.http.handler = function(req) return 200, PCM .. req.body end
        voice:speakSequence({ "A.", "B.", "C." }, { engine = "cloud" }, {})
        assert_eq(voice:canPause(), false, "audio still loading cannot pause")
        UIManager._drain()
        assert_eq(states, { "loading", "playing", "idle" })
    end)

    it("reports idle on stop() and on failure", function()
        local voice = newVoice()
        local states = {}
        voice.on_state = function(s) table.insert(states, s) end
        voice:speak("Hello", { engine = "cloud" })
        voice:stop()
        assert_eq(states, { "loading", "idle" })
        Stubs.http.handler = function() return 500, "boom" end
        states = {}
        voice:speak("Other", { engine = "cloud" })
        UIManager._drain()
        assert_eq(states, { "loading", "idle" })
    end)

    it("speakSequence accepts a generator function", function()
        local voice = newVoice()
        local texts = { "One.", "Two." }
        local done
        voice:speakSequence(function(i) return texts[i] end, { engine = "cloud", prefetch = 0 },
            { on_done = function(ok) done = ok end })
        UIManager._drain()
        assert_eq(done, true)
        assert_eq(#voice.player.played, 2)
    end)
end)
