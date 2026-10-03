--[[--
Access to the book's text and on-screen positions, for reflowable documents
(EPUB, FB2, HTML, …) rendered by crengine.

crengine exposes word navigation but no sentence navigation, so sentences
are built here by walking words: a sentence ends after . ! ? … (unless it
is an abbreviation, or the next word starts in lowercase), at a paragraph
break, or after MAX_WORDS words.
--]]

local BookText = {
    MAX_WORDS = 60,
}

local ABBREVIATIONS = {
    mr = true, mrs = true, ms = true, dr = true, prof = true, st = true, jr = true, sr = true,
    vs = true, etc = true, ["e.g"] = true, ["i.e"] = true, no = true, vol = true, fig = true,
    gen = true, col = true, capt = true, lt = true, sgt = true, rev = true, mt = true,
}

function BookText.isReflowable(ui)
    return ui and ui.rolling ~= nil and ui.document ~= nil
        and ui.document.getNextVisibleWordStart ~= nil
end

--- Normalize `xp` to the start of the word it is in (or the next word).
function BookText.wordStart(ui, xp)
    local doc = ui.document
    local ok, we = pcall(doc.getNextVisibleWordEnd, doc, xp)
    if not ok or not we then return nil end
    local ok2, ws = pcall(doc.getPrevVisibleWordStart, doc, we)
    if ok2 and ws then return ws end
    return nil
end

--- Classify the text between one word's start and the next word's start
-- ("word" + punctuation + spaces/newlines): does a sentence end here?
-- `next_word` is the following word's text (or nil at the end).
function BookText.endsSentence(chunk, next_word)
    if chunk:find("\n") then return true end   -- paragraph / block break
    local s = chunk:gsub("%s+$", ""):gsub("\226\128\166", "...")   -- … -> ...
    -- Strip closing quotes and brackets: ” ’ » " ' ) ]
    while true do
        local t = s:gsub("[\"')%]]$", ""):gsub("\226\128[\157\153]$", ""):gsub("\194\187$", "")
        if t == s then break end
        s = t
    end
    local last = s:sub(-1)
    if last ~= "." and last ~= "!" and last ~= "?" then return false end
    if last == "." and not s:find("%.%.$") then
        local word = s:match("([^%s]+)%.$") or ""
        local bare = word:lower():gsub("^[%(\"']+", ""):gsub("^\226\128[\156\152]", "")
        if ABBREVIATIONS[bare] then return false end
        if #bare == 1 and bare:match("%a") then return false end   -- initials: "J. Smith"
    end
    if next_word and next_word:match("^%l") then return false end
    return true
end

-- Inline elements: a change only in these does not start a new block.
local INLINE = {
    a = true, abbr = true, b = true, big = true, cite = true, code = true, del = true,
    dfn = true, em = true, font = true, i = true, ins = true, kbd = true, q = true,
    s = true, samp = true, small = true, span = true, strike = true, strong = true,
    sub = true, sup = true, tt = true, u = true, var = true,
}

--- The block-level part of an xpointer path, e.g.
-- "/body/DocFragment/body/p[3]/em/text().4" -> "/body/DocFragment/body/p[3]"
function BookText.blockPath(xp)
    local path = (xp or ""):gsub("/text%(%)[^/]*$", ""):gsub("%.%d+$", "")
    while true do
        local parent, tag = path:match("^(.*)/([%a][%w]*)[^/]*$")
        if not tag or not INLINE[tag:lower()] then break end
        path = parent
    end
    return path
end

local CLOSING = { ".", "!", "?", "\"", "'", ")", "]", ":", ";",
    "\226\128\166", "\226\128\157", "\226\128\153", "\194\187" }  -- … ” ’ »

--- The leading run of closing punctuation in `s` (stops at anything else,
-- e.g. the next block's opening quote).
function BookText.closingPunctuation(s)
    local out, i = {}, 1
    while i <= #s do
        local matched
        for _j, p in ipairs(CLOSING) do
            if s:sub(i, i + #p - 1) == p then matched = p break end
        end
        if not matched then break end
        table.insert(out, matched)
        i = i + #matched
    end
    return table.concat(out)
end

--- Build the sentence starting at word start `ws`.
-- @return { text, pos0, pos1, next_start } or nil
function BookText.sentenceFrom(ui, ws)
    local doc = ui.document
    if not ws then return nil end
    local pos0 = ws
    -- Include an opening quote or bracket right before the first word.
    local ok_p, prev = pcall(doc.getPrevVisibleChar, doc, ws)
    if ok_p and prev then
        local c = doc:getTextFromXPointers(prev, ws) or ""
        if c == "\"" or c == "'" or c == "(" or c == "[" or c == "\226\128\156"
                or c == "\226\128\152" or c == "\194\171" then
            pos0 = prev
        end
    end
    local pos1
    local next_start
    local trailing = ""
    local words = 0
    local cur = ws
    while true do
        local ok_e, we = pcall(doc.getNextVisibleWordEnd, doc, cur)
        if not ok_e or not we then pos1 = pos1 or cur break end
        local ok_s, nws = pcall(doc.getNextVisibleWordStart, doc, we)
        words = words + 1
        if not ok_s or not nws or nws == cur then
            pos1 = we
            next_start = nil
            break
        end
        local chunk = doc:getTextFromXPointers(cur, nws) or ""
        local next_word
        if chunk:find("[%.!%?]") or chunk:find("\226\128\166") then
            local ok_n, nwe = pcall(doc.getNextVisibleWordEnd, doc, nws)
            next_word = ok_n and nwe and doc:getTextFromXPointers(nws, nwe) or nil
        end
        local new_block = BookText.blockPath(cur) ~= BookText.blockPath(nws)
        if new_block or BookText.endsSentence(chunk, next_word) or words >= BookText.MAX_WORDS then
            -- End at the next word's start so closing punctuation is included
            -- (but not across a block boundary, which would highlight it).
            pos1 = new_block and we or nws
            if new_block then
                -- Keep the block's final punctuation for intonation.
                local word_text = doc:getTextFromXPointers(cur, we) or ""
                if word_text ~= "" and chunk:sub(1, #word_text) == word_text then
                    trailing = BookText.closingPunctuation(chunk:sub(#word_text + 1))
                end
            end
            next_start = nws
            break
        end
        cur = nws
    end
    local text = (doc:getTextFromXPointers(pos0, pos1) or "") .. trailing
    return {
        text = (text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")),
        pos0 = pos0,
        pos1 = pos1,
        next_start = next_start,
    }
end

--- The sentence starting at (the word containing) `xp`.
function BookText.sentenceAt(ui, xp)
    if not xp then return nil end
    return BookText.sentenceFrom(ui, BookText.wordStart(ui, xp))
end

--- The sentence after `sentence`, or nil at the end of the book.
function BookText.nextSentence(ui, sentence)
    if not sentence.next_start then return nil end
    return BookText.sentenceFrom(ui, sentence.next_start)
end

--- First sentence at the top of the current page.
function BookText.firstSentenceOnPage(ui)
    return BookText.sentenceAt(ui, ui.document:getXPointer())
end

function BookText.currentPage(ui)
    return ui.document:getCurrentPage()
end

--- Text of pages [from, to] (clamped), whitespace-normalized.
function BookText.pagesText(ui, from, to)
    local doc = ui.document
    local count = doc:getPageCount()
    from = math.max(1, from)
    to = math.min(count, to)
    local text
    if to < count then
        text = doc:getTextFromXPointers(doc:getPageXPointer(from), doc:getPageXPointer(to + 1))
    else
        -- No page after the last one: collect sentences to the end instead.
        text = BookText.sentencesFrom(ui, from)
    end
    return ((text or ""):gsub("%s+", " "))
end

--- Text of up to 200 sentences starting at the top of `page`.
function BookText.sentencesFrom(ui, page)
    local doc = ui.document
    local s = BookText.sentenceAt(ui, doc:getPageXPointer(page))
    local parts = {}
    while s and #parts < 200 do
        table.insert(parts, s.text)
        s = BookText.nextSentence(ui, s)
    end
    return table.concat(parts, " ")
end

--- Book text around the reading position, at most `max_chars`, ending at
-- the current page (text before the position matters most for context).
function BookText.contextText(ui, max_chars)
    if not BookText.isReflowable(ui) then return nil end
    local ok, text = pcall(function()
        local page = BookText.currentPage(ui)
        return BookText.pagesText(ui, page - 3, page)
    end)
    if not ok or not text then return nil end
    if #text > max_chars then
        text = text:sub(-max_chars)
        text = text:gsub("^[\128-\191]+", "")  -- don't start mid UTF-8 char
    end
    return text
end

--- Text of the current page.
function BookText.pageText(ui)
    if not BookText.isReflowable(ui) then return nil end
    local ok, text = pcall(function()
        local page = BookText.currentPage(ui)
        return BookText.pagesText(ui, page, page)
    end)
    return ok and text or nil
end

--- The sentence around a selection, for context (best effort).
function BookText.selectionSentence(ui, selected)
    if not (BookText.isReflowable(ui) and selected and selected.pos0 and selected.pos1) then return nil end
    local ok, text = pcall(function()
        local doc = ui.document
        local a, b = selected.pos0, selected.pos1
        for _i = 1, 40 do
            local p = doc:getPrevVisibleWordStart(a)
            if not p or p == a then break end
            a = p
        end
        for _i = 1, 40 do
            local n = doc:getNextVisibleWordEnd(b)
            if not n or n == b then break end
            b = n
        end
        local before = doc:getTextFromXPointers(a, selected.pos0) or ""
        local middle = doc:getTextFromXPointers(selected.pos0, selected.pos1) or ""
        local after = doc:getTextFromXPointers(selected.pos1, b) or ""
        before = before:match(".*[%.!%?\n][\"'%)]*%s+(.-)$") or before
        after = after:match("^(.-[%.!%?][\"'%)]*)%s") or after
        return ((before .. middle .. after):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
    end)
    return ok and text or nil
end

-- ── Highlighting the sentence being read ─────────────────────────────

-- Whether the temporary highlight currently shown is ours (so we never
-- clear a selection the user is making).
local owns_highlight = false

function BookText.highlight(ui, sentence)
    local view = ui.view
    if not view or not view.highlight then return end
    local ok, boxes = pcall(ui.document.getScreenBoxesFromPositions, ui.document,
        sentence.pos0, sentence.pos1, true)
    if not ok or not boxes then return end
    view.highlight.temp = { [BookText.currentPage(ui)] = boxes }
    owns_highlight = true
    require("ui/uimanager"):setDirty(view.dialog, "ui")
end

function BookText.clearHighlight(ui)
    local view = ui.view
    if not owns_highlight or not view or not view.highlight then return end
    owns_highlight = false
    view.highlight.temp = {}
    require("ui/uimanager"):setDirty(view.dialog, "ui")
end

return BookText
