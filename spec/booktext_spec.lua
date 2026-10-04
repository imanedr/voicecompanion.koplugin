local BookText = require("voicecompanion/reader/booktext")

describe("BookText.endsSentence", function()
    local cases = {
        { "him. ", "The", true },
        { "Mr. ", "Smith", false },
        { "J. ", "Smith", false },
        { "e.g. ", "x", false },
        { "said, ", "and", false },
        { "noticed.\n", "It", true },
        { "wait\226\128\166 ", "Then", true },
        { "\226\128\156Hello!\226\128\157 ", "She", true },
        { "\226\128\156hello\226\128\157 ", "and", false },
        { "end?) ", "Next", true },
        { "him. ", "and", false },          -- lowercase next word continues
        { "Wait... ", "Then", true },
        { "Dr. ", "Who", false },
        { "no. ", "Then", true },           -- "no" ends a sentence
        { "No. ", "5", false },             -- but "No. 5" does not
        { "laughed. \226\128\156", "It", true },  -- next sentence's opening quote
        { "said, \226\128\156", "It", false },
    }
    for _, c in ipairs(cases) do
        it(string.format("%q + %s -> %s", c[1], tostring(c[2]), tostring(c[3])):gsub("\n", "\\n"), function()
            assert_eq(BookText.endsSentence(c[1], c[2]), c[3])
        end)
    end

    it("ends at the end of the book (no next word)", function()
        assert_eq(BookText.endsSentence("the end. ", nil), true)
    end)
end)

describe("BookText.closingPunctuation", function()
    it("returns the leading run of closing marks", function()
        assert_eq(BookText.closingPunctuation(".\226\128\157 Next"), ".\226\128\157")
        assert_eq(BookText.closingPunctuation("?!) word"), "?!)")
    end)

    it("stops at an opening quote or letters", function()
        assert_eq(BookText.closingPunctuation("\226\128\156Hello"), "")
        assert_eq(BookText.closingPunctuation(".abc."), ".")
    end)

    it("handles empty input", function()
        assert_eq(BookText.closingPunctuation(""), "")
    end)
end)

describe("BookText.blockPath", function()
    it("strips text() and inline elements", function()
        assert_eq(BookText.blockPath("/body/DocFragment/body/p[3]/em/text().4"),
            "/body/DocFragment/body/p[3]")
    end)

    it("keeps block elements", function()
        assert_eq(BookText.blockPath("/body/DocFragment/body/p[3]/text().0"),
            "/body/DocFragment/body/p[3]")
        assert_eq(BookText.blockPath("/body/DocFragment/body/div[2]/p[1]"),
            "/body/DocFragment/body/div[2]/p[1]")
    end)

    it("strips nested inline elements", function()
        assert_eq(BookText.blockPath("/body/DocFragment/body/p[1]/b/i/text().2"),
            "/body/DocFragment/body/p[1]")
    end)

    it("tolerates nil", function()
        assert_eq(BookText.blockPath(nil), "")
    end)
end)
