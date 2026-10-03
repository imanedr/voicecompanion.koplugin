local Sentences = require("voicecompanion/sentences")

describe("Sentences.split", function()
    it("splits on . ! ?", function()
        assert_eq(Sentences.split("One. Two! Three?"), { "One.", "Two!", "Three?" })
    end)

    it("does not split after abbreviations", function()
        assert_eq(Sentences.split("Mr. Smith met Dr. Jones, e.g. at noon. Then left."),
            { "Mr. Smith met Dr. Jones, e.g. at noon.", "Then left." })
    end)

    it("does not split decimals", function()
        assert_eq(Sentences.split("Pi is 3.14 today. Fine."), { "Pi is 3.14 today.", "Fine." })
    end)

    it("keeps repeated punctuation together", function()
        assert_eq(Sentences.split("Really?! Yes."), { "Really?!", "Yes." })
    end)

    it("keeps closing quotes with their sentence", function()
        assert_eq(Sentences.split('He said "Go!" Then left.'), { 'He said "Go!"', "Then left." })
        assert_eq(Sentences.split("\226\128\156Hi.\226\128\157 She nodded."),
            { "\226\128\156Hi.\226\128\157", "She nodded." })
    end)

    it("treats paragraph breaks as sentence ends", function()
        assert_eq(Sentences.split("Para one\n\nPara two. Next"), { "Para one", "Para two.", "Next" })
    end)

    it("normalizes whitespace and CRLF", function()
        assert_eq(Sentences.split("A  b\r\nc.   D."), { "A b c.", "D." })
    end)

    it("keeps an unterminated tail", function()
        assert_eq(Sentences.split("Done. trailing words"), { "Done.", "trailing words" })
    end)

    it("returns nothing for blank text", function()
        assert_eq(Sentences.split("  \n\n  "), {})
    end)
end)

describe("Sentences.chunks", function()
    it("merges short sentences up to MIN_LEN", function()
        local chunks = Sentences.chunks("Hi. Yes. This is a longer sentence here. Ok.")
        assert_eq(chunks, { "Hi. Yes. This is a longer sentence here. Ok." })
    end)

    it("keeps sentences separate once they reach min_len", function()
        local a = "This sentence is long enough."
        local b = "So is this other sentence."
        assert_eq(Sentences.chunks(a .. " " .. b, 20, 350), { a, b })
    end)

    it("appends a short trailing sentence to the previous chunk", function()
        local a = "This sentence is long enough."
        assert_eq(Sentences.chunks(a .. " Ok.", 20, 350), { a .. " Ok." })
    end)

    it("splits over-long sentences at commas", function()
        local long = "alpha beta, gamma delta, epsilon zeta, eta theta, iota kappa, lambda mu"
        local chunks = Sentences.chunks(long, 10, 30)
        assert_eq(chunks, { "alpha beta, gamma delta,", "epsilon zeta, eta theta, iota", "kappa, lambda mu" })
        for _, c in ipairs(chunks) do assert_true(#c <= 30, "chunk too long: " .. c) end
    end)

    it("uses MIN_LEN/MAX_LEN defaults", function()
        assert_eq(Sentences.MIN_LEN, 25)
        assert_eq(Sentences.MAX_LEN, 350)
    end)
end)

describe("Sentences.split unicode ellipsis", function()
    it("ends a sentence at …", function()
        local out = Sentences.split("Yes… Ok then.")
        assert_eq(#out, 2)
        assert_eq(out[1], "Yes…")
    end)
end)
