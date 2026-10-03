--[[--
OpenAI-compatible API client (OpenRouter, OpenAI, Groq, self-hosted servers).

Both functions are blocking and are meant to run inside async.lua's
background subprocess.  `p` is a provider table from the configuration
(base_url, api_key, chat_model, tts_model, voice, audio_format, sample_rate,
timeout).
--]]

local Http = require("voicecompanion/http")

local Provider = {}

local function headers(p)
    return {
        ["Authorization"] = "Bearer " .. (p.api_key or ""),
        ["Content-Type"] = "application/json",
        -- OpenRouter app attribution (ignored by other providers).
        ["HTTP-Referer"] = "https://github.com/imanedr/voicecompanion.koplugin",
        ["X-Title"] = "KOReader Voice Companion",
    }
end

local function url(p, path)
    return (p.base_url or ""):gsub("/+$", "") .. path
end

--- Write a 16-bit mono PCM WAV file.
function Provider.writeWav(path, pcm, sample_rate)
    local function le32(n)
        return string.char(n % 256, math.floor(n / 256) % 256,
            math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
    end
    local function le16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
    if #pcm % 2 == 1 then pcm = pcm:sub(1, -2) end
    local f, err = io.open(path, "wb")
    if not f then return false, err end
    f:write("RIFF", le32(36 + #pcm), "WAVE",
        "fmt ", le32(16), le16(1), le16(1), le32(sample_rate), le32(sample_rate * 2), le16(2), le16(16),
        "data", le32(#pcm), pcm)
    f:close()
    return true
end

--- Synthesize speech to `out_path`.
-- @param opts table { voice, speed, format ("mp3"|"pcm"), model, extra = {} }
-- @return boolean ok, string error_or_out_path
function Provider.speech(p, text, out_path, opts)
    opts = opts or {}
    local JSON = require("json")
    local format = opts.format or p.audio_format or "mp3"
    local body = {
        model = opts.model or p.tts_model,
        input = text,
        voice = opts.voice or p.voice,
        response_format = format,
    }
    if opts.speed and math.abs(opts.speed - 1.0) > 0.01 then
        body.speed = opts.speed
    end
    for k, v in pairs(opts.extra or p.tts_extra or {}) do body[k] = v end

    local raw_path = format == "pcm" and (out_path .. ".pcm") or out_path
    local code, resp, _, err = Http.post(url(p, "/audio/speech"), JSON.encode(body), {
        headers = headers(p), timeout = p.timeout, sink_path = raw_path,
    })
    if err then return false, err end
    if code < 200 or code >= 300 then return false, Http.errorMessage(code, resp) end

    local f = io.open(raw_path, "rb")
    if not f then return false, "no audio received" end
    local data = f:read("*a") or ""
    f:close()
    if #data < 64 then
        os.remove(raw_path)
        return false, "empty audio response"
    end
    if data:sub(1, 1) == "{" then
        os.remove(raw_path)
        return false, "server returned JSON instead of audio: " .. data:sub(1, 200)
    end
    if format == "pcm" then
        os.remove(raw_path)
        if data:sub(1, 4) == "RIFF" then
            local wf = io.open(out_path, "wb")
            wf:write(data)
            wf:close()
        else
            local ok, werr = Provider.writeWav(out_path, data, tonumber(p.sample_rate) or 24000)
            if not ok then return false, werr end
        end
    end
    return true, out_path
end

--- Chat completion.
-- @param messages table  { {role=, content=}, ... }
-- @param opts table { model, max_tokens, temperature }
-- @return boolean ok, string answer_or_error
function Provider.chat(p, messages, opts)
    opts = opts or {}
    local JSON = require("json")
    local body = {
        model = opts.model or p.chat_model,
        messages = messages,
        max_tokens = opts.max_tokens,
        temperature = opts.temperature,
    }
    local code, resp, _, err = Http.post(url(p, "/chat/completions"), JSON.encode(body), {
        headers = headers(p), timeout = p.timeout,
    })
    if err then return false, err end
    if code < 200 or code >= 300 then return false, Http.errorMessage(code, resp) end
    local ok, decoded = pcall(JSON.decode, resp or "")
    if not ok or type(decoded) ~= "table" then
        return false, "could not parse the chat response"
    end
    local choice = type(decoded.choices) == "table" and decoded.choices[1]
    local content = choice and choice.message and choice.message.content
    if type(content) == "table" then
        -- Some providers return content parts.
        local parts = {}
        for _, part in ipairs(content) do
            if type(part) == "table" and part.text then table.insert(parts, part.text) end
        end
        content = table.concat(parts)
    end
    if type(content) ~= "string" or content == "" then
        return false, "the model returned an empty answer"
    end
    return true, content
end

--- Extract the first JSON object from a model answer (tolerates ``` fences
-- and text around it).
function Provider.parseJsonAnswer(text)
    local JSON = require("json")
    local s = text:match("```json%s*(.-)```") or text:match("```%s*(.-)```") or text
    local start = s:find("{", 1, true)
    local stop
    for i = #s, 1, -1 do
        if s:sub(i, i) == "}" then stop = i break end
    end
    if not start or not stop or stop < start then return nil, "no JSON object in answer" end
    local ok, decoded = pcall(JSON.decode, s:sub(start, stop))
    if not ok or type(decoded) ~= "table" then return nil, "invalid JSON in answer" end
    return decoded
end

return Provider
