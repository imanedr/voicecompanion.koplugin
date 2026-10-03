local CliTts = require("voicecompanion/tts/cli")

describe("CliTts.buildCommand", function()
    it("substitutes all placeholders", function()
        local cmd = CliTts.buildCommand("say -v {lang} -r {rate_wpm} -f {text_file} -o {out}",
            "/tmp/in.txt", "/tmp/out.wav", "en-GB", 1.0)
        assert_eq(cmd, "say -v 'en-gb' -r 175 -f '/tmp/in.txt' -o '/tmp/out.wav'")
    end)

    it("leaves unknown placeholders untouched", function()
        assert_eq(CliTts.buildCommand("x {unknown} {out}", "t", "o", "en", 1), "x {unknown} 'o'")
    end)

    it("shell-quotes paths containing single quotes", function()
        local cmd = CliTts.buildCommand("tts {out}", "t", "/tmp/it's.wav", "en", 1)
        assert_eq(cmd, "tts '/tmp/it'\\''s.wav'")
    end)

    it("shell-quotes spaces", function()
        assert_eq(CliTts.buildCommand("{text_file}", "/a b/c.txt", "o", "en", 1), "'/a b/c.txt'")
    end)

    it("maps rate to words per minute", function()
        assert_eq(CliTts.buildCommand("{rate_wpm}", "t", "o", "en", 1.0), "175")
        assert_eq(CliTts.buildCommand("{rate_wpm}", "t", "o", "en", 0.5), "88")
        assert_eq(CliTts.buildCommand("{rate_wpm}", "t", "o", "en", nil), "175")
    end)

    it("defaults the language to en-us", function()
        assert_eq(CliTts.buildCommand("{lang}", "t", "o", nil, 1), "'en-us'")
    end)
end)

describe("CliTts.template", function()
    it("prefers an explicit command", function()
        assert_eq(CliTts.template({ command = "mytts {out}" }), "mytts {out}")
    end)
end)
