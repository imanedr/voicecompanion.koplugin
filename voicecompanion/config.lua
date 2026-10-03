--[[--
Configuration: `configuration.lua` in the plugin folder, merged over the
defaults below.  Users copy `configuration.sample.lua` to create it, or the
settings menu writes it (comments are not preserved when the menu saves).
--]]

local logger = require("logger")

local Config = {}

local plugin_dir = (debug.getinfo(1, "S").source:match("^@(.*/)voicecompanion/[^/]*$")) or "./"
Config.plugin_dir = plugin_dir
Config.file = plugin_dir .. "configuration.lua"

Config.DEFAULTS = {
    -- Which entry of `providers` is used for AI voices and explanations.
    provider = "openrouter",
    providers = {
        openrouter = {
            base_url = "https://openrouter.ai/api/v1",
            api_key = "",
            chat_model = "google/gemini-3.8-flash",
            tts_model = "hexgrad/kokoro-82m",
            voice = "af_heart",
            -- Audio format requested from the speech endpoint: "mp3" or "pcm".
            audio_format = "mp3",
            -- Only used for "pcm": sample rate of the raw audio.
            sample_rate = 24000,
        },
        openai = {
            base_url = "https://api.openai.com/v1",
            api_key = "",
            chat_model = "gpt-4o-mini",
            tts_model = "gpt-4o-mini-tts",
            voice = "alloy",
            audio_format = "mp3",
            sample_rate = 24000,
        },
    },
    -- Voice used when a feature doesn't say otherwise: "cloud" or "local".
    voice_engine = "cloud",
    local_tts = {
        -- BCP-47 language tag for the device voice, e.g. "en-US", "en-GB".
        language = "en-US",
        rate = 1.0,
        pitch = 1.0,
        -- Linux only: command that writes a WAV file.  {text_file}, {out},
        -- {lang} and {rate_wpm} are substituted.  Empty = auto-detect
        -- espeak-ng / espeak / piper.
        command = "",
    },
    pronounce = {
        engine = "cloud",
        slow_speed = 0.7,
    },
    explain = {
        -- Language the explanations are written and spoken in.
        language = "English",
        max_context_chars = 6000,
        speak_answer = true,
    },
    read_aloud = {
        engine = "cloud",
        highlight = true,
        -- Sentences fetched ahead while one is playing (cloud voices).
        prefetch = 2,
        stop_at_chapter_end = false,
    },
    -- Seconds to wait for one network request.
    timeout = 60,
    -- Megabytes of audio kept in the cache (repeat plays are free).
    cache_mb = 50,
}

local function deepCopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = deepCopy(v) end
    return out
end

--- Merge `src` over `dst` recursively (tables merged, scalars replaced).
local function merge(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" then
            merge(dst[k], v)
        else
            dst[k] = deepCopy(v)
        end
    end
    return dst
end

--- Load the configuration.  Never raises.
-- @return table config, string|nil error (config falls back to defaults)
function Config.load()
    local cfg = deepCopy(Config.DEFAULTS)
    local f = io.open(Config.file, "r")
    if not f then return cfg end
    f:close()
    local ok, user = pcall(dofile, Config.file)
    if not ok then
        logger.warn("VoiceCompanion: configuration error:", user)
        return cfg, tostring(user)
    end
    if type(user) ~= "table" then
        return cfg, "configuration.lua must return a table"
    end
    return merge(cfg, user)
end

function Config.exists()
    local f = io.open(Config.file, "r")
    if f then f:close() return true end
    return false
end

--- The active provider's settings (plus its name), or nil + error.
function Config.activeProvider(cfg)
    local name = cfg.provider
    local p = cfg.providers and cfg.providers[name]
    if type(p) ~= "table" then
        return nil, string.format("provider %q is not defined in providers", tostring(name))
    end
    p = deepCopy(p)
    p.name = name
    p.timeout = p.timeout or cfg.timeout
    return p
end

--- True if an API key looks unset (empty or the sample placeholder).
function Config.isKeyMissing(key)
    return key == nil or key == "" or key:find("PUT-YOUR-KEY", 1, true) ~= nil
end

-- ── Writing ────────────────────────────────────────────────────────────

local function isIdentifier(k)
    return type(k) == "string" and k:match("^[%a_][%w_]*$") ~= nil
end

local function serialize(v, indent)
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t == "number" or t == "boolean" then return tostring(v) end
    if t ~= "table" then return "nil" end
    local keys = {}
    for k in pairs(v) do table.insert(keys, k) end
    if #keys == 0 then return "{}" end
    table.sort(keys, function(a, b)
        if type(a) == type(b) then return a < b end
        return type(a) == "number"
    end)
    local inner = indent .. "    "
    local lines = { "{" }
    for _, k in ipairs(keys) do
        local key = isIdentifier(k) and k or ("[" .. serialize(k, inner) .. "]")
        table.insert(lines, string.format("%s%s = %s,", inner, key, serialize(v[k], inner)))
    end
    table.insert(lines, indent .. "}")
    return table.concat(lines, "\n")
end
Config.serialize = serialize

--- Write the full configuration table to configuration.lua.
-- @return boolean ok, string|nil error
function Config.save(cfg)
    local body = "-- Voice Companion configuration (written by the settings menu).\n"
        .. "-- See configuration.sample.lua for what each option does.\n"
        .. "return " .. serialize(cfg, "") .. "\n"
    local tmp = Config.file .. ".tmp"
    local f, err = io.open(tmp, "w")
    if not f then return false, err end
    f:write(body)
    f:close()
    local ok, rerr = os.rename(tmp, Config.file)
    if not ok then return false, rerr end
    return true
end

--- Set one value by dotted path ("providers.openrouter.voice") and save.
-- Re-reads the file first so manual edits made meanwhile are kept.
function Config.set(path, value)
    local cfg, err = Config.load()
    if err then return false, err end
    local node = cfg
    local parts = {}
    for part in path:gmatch("[^%.]+") do table.insert(parts, part) end
    for i = 1, #parts - 1 do
        if type(node[parts[i]]) ~= "table" then node[parts[i]] = {} end
        node = node[parts[i]]
    end
    node[parts[#parts]] = value
    return Config.save(cfg)
end

return Config
