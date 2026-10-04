local ReadAloud = require("voicecompanion/features/readaloud")
local BookText = require("voicecompanion/reader/booktext")

-- Sentences as the book walker returns them; positions are numbers.
local function walker(texts, block_ends)
    local i = 0
    return function()
        i = i + 1
        if not texts[i] then return nil end
        return { text = texts[i], pos0 = i * 10, pos1 = i * 10 + 5, ends_block = block_ends and block_ends[i] }
    end
end

local function drain(next_group)
    local out = {}
    for g in next_group do table.insert(out, g) end
    return out
end

describe("ReadAloud.grouper", function()
    it("keeps one sentence per group when the size is 0", function()
        local groups = drain(ReadAloud.grouper(walker({ "A.", "B.", "C." }), 0))
        assert_eq(#groups, 3)
        assert_eq(groups[2].text, "B.")
        assert_eq(groups[2].pos0, 20)
    end)

    it("merges short sentences up to the size, spanning their positions", function()
        local s = string.rep("x", 40) .. "."
        local groups = drain(ReadAloud.grouper(walker({ s, s, s, s, s, s, s, s }), 100))
        -- First group capped at FIRST_CHARS (120): three sentences (41+1+41+1+41 = 125).
        assert_eq(#groups[1].text, 125)
        assert_eq(groups[1].pos0, 10)
        assert_eq(groups[1].pos1, 35)
        assert_eq(groups[1].first.pos0, 10)
        assert_eq(groups[1].last.pos0, 30)
        local n = 0
        for _, g in ipairs(groups) do n = n + select(2, g.text:gsub("%.", "")) end
        assert_eq(n, 8, "every sentence read once")
    end)

    it("starts small, then grows to the configured size", function()
        local texts = {}
        for i = 1, 40 do texts[i] = string.rep("w", 29) .. "." end   -- 30 chars each
        local groups = drain(ReadAloud.grouper(walker(texts), 300))
        assert_eq(#groups[1].text, 30 * 4 + 3)    -- reaches 120
        assert_eq(#groups[2].text, 30 * 8 + 7)    -- reaches 240
        assert_eq(#groups[3].text, 30 * 10 + 9)   -- reaches 300
    end)

    it("joins across a paragraph end with a newline", function()
        local groups = drain(ReadAloud.grouper(walker({ "One.", "Two.", "Three." }, { true }), 300))
        assert_eq(#groups, 1)
        assert_eq(groups[1].text, "One.\nTwo. Three.")
    end)
end)

describe("BookText.fractionBefore / viewEnd", function()
    -- A fake document whose xpointers are character offsets.
    local text = string.rep("a", 100)
    local doc = {
        compareXPointers = function(_, a, b) return b > a and 1 or (b == a and 0 or -1) end,
        getTextFromXPointers = function(_, a, b) return text:sub(a + 1, b) end,
        getCurrentPage = function() return 3 end,
        getVisiblePageCount = function() return 2 end,
        getPageCount = function() return 10 end,
        getPageXPointer = function(_, page) return page * 1000 end,
    }
    local ui = { document = doc, view = { view_mode = "page" } }

    it("gives the share of the text before the page end", function()
        assert_eq(BookText.fractionBefore(ui, { pos0 = 20, pos1 = 60 }, 30), 0.25)
    end)

    it("is nil when the page end is outside the span", function()
        assert_nil(BookText.fractionBefore(ui, { pos0 = 20, pos1 = 60 }, 60))
        assert_nil(BookText.fractionBefore(ui, { pos0 = 20, pos1 = 60 }, 10))
    end)

    it("viewEnd is the start of the page after all visible pages", function()
        assert_eq(BookText.viewEnd(ui), 5000)
    end)

    it("viewEnd is nil in scroll mode", function()
        assert_nil(BookText.viewEnd({ document = doc, view = { view_mode = "scroll" } }))
    end)
end)
