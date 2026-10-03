local Provider = require("voicecompanion/provider")
local Http = require("voicecompanion/http")
local JSON = require("json")
local Stubs = require("spec/stubs")

local function read(path)
    local f = assert(io.open(path, "rb"))
    local d = f:read("*a")
    f:close()
    return d
end

local function le32(s, pos)
    local a, b, c, d = s:byte(pos, pos + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end

local function provider(extra)
    local p = {
        base_url = "https://example.test/api/v1/", api_key = "sk-test", chat_model = "chat-m",
        tts_model = "tts-m", voice = "af_heart", audio_format = "mp3", sample_rate = 22050, timeout = 5,
    }
    for k, v in pairs(extra or {}) do p[k] = v end
    return p
end

local PCM = string.rep("\1\2", 100)

describe("Provider.writeWav", function()
    before_each(Stubs.cleanTmp)

    it("writes a 16-bit mono PCM header", function()
        local path = Stubs.TMP .. "/a.wav"
        assert_true(Provider.writeWav(path, PCM, 24000))
        local d = read(path)
        assert_eq(#d, 44 + #PCM)
        assert_eq(d:sub(1, 4), "RIFF")
        assert_eq(le32(d, 5), 36 + #PCM)
        assert_eq(d:sub(9, 16), "WAVEfmt ")
        assert_eq(le32(d, 17), 16)
        assert_eq(d:byte(21), 1)           -- PCM
        assert_eq(d:byte(23), 1)           -- mono
        assert_eq(le32(d, 25), 24000)      -- sample rate
        assert_eq(le32(d, 29), 48000)      -- byte rate
        assert_eq(d:byte(33), 2)           -- block align
        assert_eq(d:byte(35), 16)          -- bits per sample
        assert_eq(d:sub(37, 40), "data")
        assert_eq(le32(d, 41), #PCM)
    end)

    it("drops a dangling odd byte", function()
        local path = Stubs.TMP .. "/odd.wav"
        Provider.writeWav(path, PCM .. "\9", 8000)
        assert_eq(#read(path), 44 + #PCM)
    end)

    it("reports an unwritable path", function()
        local ok, err = Provider.writeWav(Stubs.TMP .. "/missing/dir/x.wav", PCM, 8000)
        assert_eq(ok, false)
        assert_eq(type(err), "string")
    end)
end)

describe("Provider.speech", function()
    before_each(function()
        Stubs.cleanTmp()
        Stubs.http.reset()
    end)

    it("posts the expected body and headers", function()
        Stubs.http.handler = function() return 200, string.rep("x", 100) end
        local out = Stubs.TMP .. "/o.mp3"
        local ok, res = Provider.speech(provider(), "Hello", out, { format = "mp3" })
        assert_true(ok, res)
        assert_eq(res, out)
        assert_eq(#Stubs.http.requests, 1)
        local req = Stubs.http.requests[1]
        assert_eq(req.url, "https://example.test/api/v1/audio/speech")
        assert_eq(req.method, "POST")
        assert_eq(req.headers["Authorization"], "Bearer sk-test")
        assert_eq(req.headers["Content-Type"], "application/json")
        local body = JSON.decode(req.body)
        assert_eq(body, { model = "tts-m", input = "Hello", voice = "af_heart", response_format = "mp3" })
    end)

    it("sends speed only when it differs from 1", function()
        Stubs.http.handler = function() return 200, string.rep("x", 100) end
        Provider.speech(provider(), "a", Stubs.TMP .. "/1.mp3", { speed = 1.0 })
        Provider.speech(provider(), "a", Stubs.TMP .. "/2.mp3", { speed = 0.7 })
        assert_nil(JSON.decode(Stubs.http.requests[1].body).speed)
        assert_eq(JSON.decode(Stubs.http.requests[2].body).speed, 0.7)
    end)

    it("merges tts_extra and per-call overrides", function()
        Stubs.http.handler = function() return 200, string.rep("x", 100) end
        Provider.speech(provider({ tts_extra = { lang_code = "b" } }), "a", Stubs.TMP .. "/e.mp3",
            { voice = "bf_emma", model = "other" })
        local body = JSON.decode(Stubs.http.requests[1].body)
        assert_eq(body.lang_code, "b")
        assert_eq(body.voice, "bf_emma")
        assert_eq(body.model, "other")
    end)

    it("writes mp3 bytes as-is", function()
        local mp3 = "ID3" .. string.rep("\255\251", 60)
        Stubs.http.handler = function() return 200, mp3 end
        local out = Stubs.TMP .. "/m.mp3"
        assert_true(Provider.speech(provider(), "a", out, { format = "mp3" }))
        assert_eq(read(out), mp3)
    end)

    it("wraps pcm into a WAV using the provider sample rate", function()
        Stubs.http.handler = function() return 200, PCM end
        local out = Stubs.TMP .. "/p.wav"
        local ok, res = Provider.speech(provider(), "a", out, { format = "pcm" })
        assert_true(ok, res)
        local d = read(out)
        assert_eq(d:sub(1, 4), "RIFF")
        assert_eq(le32(d, 25), 22050)
        assert_eq(le32(d, 41), #PCM)
        assert_eq(JSON.decode(Stubs.http.requests[1].body).response_format, "pcm")
        assert_nil(io.open(out .. ".pcm"), "temporary .pcm file should be removed")
    end)

    it("keeps a ready-made WAV response", function()
        local wav = "RIFF" .. string.rep("\0", 100)
        Stubs.http.handler = function() return 200, wav end
        local out = Stubs.TMP .. "/w.wav"
        assert_true(Provider.speech(provider(), "a", out, { format = "pcm" }))
        assert_eq(read(out), wav)
    end)

    it("turns an HTTP 401 JSON error into a readable failure", function()
        Stubs.http.handler = function() return 401, '{"error":{"message":"Invalid key"}}' end
        local ok, err = Provider.speech(provider(), "a", Stubs.TMP .. "/x.mp3", {})
        assert_eq(ok, false)
        assert_match(err, "HTTP 401")
        assert_match(err, "Invalid key")
        assert_match(err, "check the API key")
    end)

    it("rejects a JSON body served with status 200", function()
        Stubs.http.handler = function() return 200, '{"error":"nope"}' .. string.rep(" ", 80) end
        local ok, err = Provider.speech(provider(), "a", Stubs.TMP .. "/j.mp3", { format = "mp3" })
        assert_eq(ok, false)
        assert_match(err, "JSON instead of audio")
    end)

    it("rejects an empty audio response", function()
        Stubs.http.handler = function() return 200, "tiny" end
        local ok, err = Provider.speech(provider(), "a", Stubs.TMP .. "/t.mp3", {})
        assert_eq(ok, false)
        assert_match(err, "empty audio")
    end)

    it("reports network errors", function()
        Stubs.http.handler = function() return "connection refused" end
        local ok, err = Provider.speech(provider(), "a", Stubs.TMP .. "/n.mp3", {})
        assert_eq(ok, false)
        assert_match(err, "network error: connection refused")
    end)
end)

describe("Provider.chat", function()
    before_each(Stubs.http.reset)

    local function answer(content)
        return JSON.encode({ choices = { { message = { content = content } } } })
    end

    it("parses choices[1].message.content", function()
        Stubs.http.handler = function() return 200, answer("Hi there") end
        local ok, text = Provider.chat(provider(), { { role = "user", content = "hey" } },
            { max_tokens = 50, temperature = 0.2 })
        assert_true(ok, text)
        assert_eq(text, "Hi there")
        local req = Stubs.http.requests[1]
        assert_eq(req.url, "https://example.test/api/v1/chat/completions")
        local body = JSON.decode(req.body)
        assert_eq(body.model, "chat-m")
        assert_eq(body.max_tokens, 50)
        assert_eq(body.messages[1].content, "hey")
    end)

    it("joins content-part arrays", function()
        Stubs.http.handler = function()
            return 200, answer({ { type = "text", text = "Part one. " }, { type = "text", text = "Part two." } })
        end
        local ok, text = Provider.chat(provider(), {})
        assert_true(ok, text)
        assert_eq(text, "Part one. Part two.")
    end)

    it("fails on an empty answer", function()
        Stubs.http.handler = function() return 200, answer("") end
        local ok, err = Provider.chat(provider(), {})
        assert_eq(ok, false)
        assert_match(err, "empty answer")
    end)

    it("fails on an unparsable body", function()
        Stubs.http.handler = function() return 200, "<html>" end
        local ok, err = Provider.chat(provider(), {})
        assert_eq(ok, false)
        assert_match(err, "could not parse")
    end)

    it("surfaces HTTP errors", function()
        Stubs.http.handler = function() return 429, "slow down" end
        local ok, err = Provider.chat(provider(), {})
        assert_eq(ok, false)
        assert_match(err, "HTTP 429")
        assert_match(err, "rate limited")
    end)
end)

describe("Provider.parseJsonAnswer", function()
    it("reads a ```json fenced block", function()
        local r = Provider.parseJsonAnswer('Sure!\n```json\n{"a": 1, "b": ["x"]}\n```\nHope that helps.')
        assert_eq(r, { a = 1, b = { "x" } })
    end)

    it("reads a bare fence", function()
        assert_eq(Provider.parseJsonAnswer('```\n{"a": true}\n```'), { a = true })
    end)

    it("finds an object surrounded by prose", function()
        assert_eq(Provider.parseJsonAnswer('Result: {"word": "cat"} - done'), { word = "cat" })
    end)

    it("fails without an object", function()
        local r, err = Provider.parseJsonAnswer("no json here")
        assert_nil(r)
        assert_match(err, "no JSON object")
    end)

    it("fails on invalid JSON", function()
        local r, err = Provider.parseJsonAnswer("{not json}")
        assert_nil(r)
        assert_match(err, "invalid JSON")
    end)
end)

describe("Http.errorMessage", function()
    it("extracts OpenRouter-style error and upstream metadata", function()
        local body = JSON.encode({ error = { message = "Provider returned error", metadata = { raw = "quota exceeded" } } })
        assert_eq(Http.errorMessage(402, body),
            "HTTP 402: Provider returned error (quota exceeded) \226\128\148 out of credits")
    end)

    it("accepts a string error field", function()
        assert_eq(Http.errorMessage(500, '{"error":"boom"}'), "HTTP 500: boom")
    end)

    it("falls back to plain text and collapses whitespace", function()
        assert_eq(Http.errorMessage(404, "Not\n  Found"),
            "HTTP 404: Not Found \226\128\148 check the model name and base URL")
    end)

    it("handles a nil body", function()
        assert_eq(Http.errorMessage(503, nil), "HTTP 503: ")
    end)

    it("truncates very long messages", function()
        assert_eq(#Http.errorMessage(500, string.rep("a", 1000)), #"HTTP 500: " + 300)
    end)
end)
