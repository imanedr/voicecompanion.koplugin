local AudioCache = require("voicecompanion/audiocache")
local Stubs = require("spec/stubs")

local base = { provider = "openrouter", model = "m", voice = "v", speed = 1.0, format = "mp3", text = "Hello" }

local function with(field, value)
    local p = {}
    for k, v in pairs(base) do p[k] = v end
    p[field] = value
    return p
end

describe("AudioCache.path", function()
    before_each(Stubs.cleanTmp)

    it("is stable for identical parts", function()
        assert_eq(AudioCache.path(base, "mp3"), AudioCache.path(with("text", "Hello"), "mp3"))
    end)

    for field, other in pairs({ provider = "openai", model = "m2", voice = "v2", speed = 0.7,
            format = "pcm", text = "Hello!" }) do
        it("differs when " .. field .. " differs", function()
            assert_true(AudioCache.path(base, "mp3") ~= AudioCache.path(with(field, other), "mp3"))
        end)
    end

    it("is not fooled by shifting text between fields", function()
        local a = AudioCache.path({ provider = "ab", model = "c", text = "" }, "mp3")
        local b = AudioCache.path({ provider = "a", model = "bc", text = "" }, "mp3")
        assert_true(a ~= b)
    end)

    it("uses the given extension and lives under the temp dir", function()
        local p = AudioCache.path(base, "wav")
        assert_match(p, "^spec/tmp/data/cache/voicecompanion/audio/%x+%d*%.wav$")
        assert_match(AudioCache.path(base), "%.mp3$")
    end)
end)

describe("AudioCache.has / trim", function()
    before_each(Stubs.cleanTmp)

    local function put(path, size)
        local f = assert(io.open(path, "wb"))
        f:write(string.rep("x", size))
        f:close()
    end

    it("has requires more than a WAV header", function()
        local dir = AudioCache.dir()
        put(dir .. "/small", 40)
        put(dir .. "/big", 100)
        assert_eq(AudioCache.has(dir .. "/small"), false)
        assert_eq(AudioCache.has(dir .. "/big"), true)
        assert_eq(AudioCache.has(dir .. "/none"), false)
    end)

    it("trim does nothing under the limit", function()
        put(AudioCache.dir() .. "/a", 100)
        assert_eq(AudioCache.trim(1), 0)
    end)

    it("trim removes files when over the limit", function()
        local dir = AudioCache.dir()
        put(dir .. "/a", 700 * 1024)
        put(dir .. "/b", 700 * 1024)
        assert_eq(AudioCache.trim(1), 1)
    end)
end)
