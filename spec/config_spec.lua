local Config = require("voicecompanion/config")
local Stubs = require("spec/stubs")

local function write(path, content)
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
end

describe("Config", function()
    before_each(function()
        Stubs.cleanTmp()
        Config.file = Stubs.TMP .. "/configuration.lua"
    end)

    it("load returns defaults when the file is missing", function()
        local cfg, err = Config.load()
        assert_nil(err)
        assert_eq(cfg, Config.DEFAULTS)
        assert_true(cfg ~= Config.DEFAULTS, "load must return a copy")
        assert_eq(Config.exists(), false)
    end)

    it("merges a user file over the defaults, including nested providers", function()
        write(Config.file, [[return {
            provider = "openai",
            timeout = 10,
            providers = { openai = { api_key = "sk-abc" } },
        }]])
        local cfg, err = Config.load()
        assert_nil(err)
        assert_eq(cfg.provider, "openai")
        assert_eq(cfg.timeout, 10)
        assert_eq(cfg.providers.openai.api_key, "sk-abc")
        assert_eq(cfg.providers.openai.base_url, "https://api.openai.com/v1")  -- default kept
        assert_eq(cfg.providers.openrouter, Config.DEFAULTS.providers.openrouter)
        assert_eq(Config.exists(), true)
    end)

    it("does not mutate DEFAULTS when merging", function()
        write(Config.file, [[return { providers = { openai = { api_key = "x" } } }]])
        Config.load()
        assert_eq(Config.DEFAULTS.providers.openai.api_key, "")
    end)

    it("returns defaults plus an error string on a syntax error", function()
        write(Config.file, "return { provider = ")
        local cfg, err = Config.load()
        assert_eq(type(err), "string")
        assert_eq(cfg, Config.DEFAULTS)
    end)

    it("returns an error when the file does not return a table", function()
        write(Config.file, "return 42")
        local cfg, err = Config.load()
        assert_match(err, "must return a table")
        assert_eq(cfg, Config.DEFAULTS)
    end)

    it("set/save/load round-trips a dotted path", function()
        local ok, err = Config.set("providers.openrouter.voice", "bf_emma")
        assert_true(ok, err)
        local cfg = Config.load()
        assert_eq(cfg.providers.openrouter.voice, "bf_emma")
        assert_eq(cfg.providers.openrouter.tts_model, "hexgrad/kokoro-82m")
    end)

    it("set creates missing intermediate tables", function()
        assert_true(Config.set("extras.nested.flag", true))
        assert_eq(Config.load().extras.nested.flag, true)
    end)

    it("set refuses to overwrite a broken file", function()
        write(Config.file, "return {")
        local ok, err = Config.set("timeout", 5)
        assert_eq(ok, false)
        assert_eq(type(err), "string")
    end)

    it("serialize produces Lua that reloads equal", function()
        local value = {
            name = "x\"y'z\nline",
            n = 1.5,
            flag = false,
            list = { "a", "b", { deep = true } },
            ["odd key"] = 1,
            empty = {},
        }
        local chunk = assert(loadstring("return " .. Config.serialize(value, "")))
        assert_eq(chunk(), value)
    end)

    it("activeProvider returns a copy with name and timeout", function()
        local cfg = Config.load()
        local p = Config.activeProvider(cfg)
        assert_eq(p.name, "openrouter")
        assert_eq(p.timeout, 60)
        assert_nil(cfg.providers.openrouter.name)
    end)

    it("activeProvider reports an unknown provider", function()
        local cfg = Config.load()
        cfg.provider = "nope"
        local p, err = Config.activeProvider(cfg)
        assert_nil(p)
        assert_match(err, "nope")
    end)

    it("isKeyMissing", function()
        assert_eq(Config.isKeyMissing(""), true)
        assert_eq(Config.isKeyMissing(nil), true)
        assert_eq(Config.isKeyMissing("sk-or-v1-PUT-YOUR-KEY-HERE"), true)
        assert_eq(Config.isKeyMissing("sk-or-v1-abcdef"), false)
    end)
end)
