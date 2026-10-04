--[[--
Run the plugin's sentence walker against KOReader's real crengine, headless.
Started by tools/crengine_check.sh (from inside KOReader's install dir);
see there for usage.  Modes:
  sentences  print sentences from the page
  groups     print read-aloud groups and where their highlight ends
  stats      walk N sentences: count ends not at punctuation or a paragraph
             end, and sentences whose highlighted text differs from the
             spoken text (both should be 0)
--]]

-- Results go to stderr: KOReader logs to stdout, which the wrapper drops.
local function out(line) io.stderr:write(line, "\n") end

local plugin = assert(os.getenv("PLUGIN"), "PLUGIN not set")
local home = assert(os.getenv("HOME"))
require("setupkoenv")
package.path = plugin .. "/?.lua;" .. package.path
G_defaults = require("luadefaults"):open(home .. "/defaults.lua")         -- luacheck: ignore 121
G_reader_settings = require("luasettings"):open(home .. "/settings.reader.lua")   -- luacheck: ignore 121

local Device = require("device")
require("document/canvascontext"):init(Device)
require("document/credocument"):engineInit()
local book = assert(os.getenv("BOOK"), "BOOK not set")
local doc = require("document/documentregistry"):openDocument(book)
assert(doc and doc:loadDocument(), "could not load the book")
doc:setStyleSheet(doc.default_css)
doc:setFontFace("Noto Serif")
doc:setFontSize(22)
doc:setViewMode("page")
doc:render()

local BookText = require("voicecompanion/reader/booktext")
local ReadAloud = require("voicecompanion/features/readaloud")
local ui = { document = doc, rolling = {}, view = { view_mode = "page" } }
doc:gotoPage(tonumber(os.getenv("PAGE") or "5"))
local first = BookText.firstSentenceOnPage(ui)
local mode = os.getenv("MODE") or "sentences"
local n = tonumber(os.getenv("N") or "") or (mode == "stats" and 3000 or 25)

local function lit(s)   -- the highlighted text, whitespace-normalized
    return ((doc:getTextFromXPointers(s.pos0, s.pos1) or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

if mode == "stats" then
    local s, total, odd, mismatch, longest = first, 0, 0, 0, 0
    while s and total < n do
        total = total + 1
        if lit(s) ~= s.text then
            mismatch = mismatch + 1
            if mismatch <= 5 then out("MISMATCH spoken: " .. s.text .. "\n         lit:    " .. lit(s)) end
        end
        local tail = s.text:sub(-3)
        local punct = tail:find("[%.!%?\"'%)%]:;,]$") or tail:find("\226\128[\157\153\166\148\147]$")
            or tail:find("\194\187$")
        if not punct and not s.ends_block then
            odd = odd + 1
            if odd <= 8 then out("ODD END: ..." .. s.text:sub(-70)) end
        end
        local _, words = s.text:gsub("%S+", "")
        longest = math.max(longest, words)
        s = BookText.nextSentence(ui, s)
    end
    out(string.format("sentences %d, odd ends %d, spoken~=highlight %d, longest %d words",
        total, odd, mismatch, longest))
elseif mode == "groups" then
    local last
    local next_group = ReadAloud.grouper(function()
        local s = last == nil and first or BookText.nextSentence(ui, last)
        if s then last = s end
        return s
    end, tonumber(os.getenv("CHUNK") or "300"))
    for i = 1, n do
        local g = next_group()
        if not g then break end
        out(string.format("[%d] %s\n    highlight ends: ...%s|", i, g.text:gsub("\n", " / "),
            lit(g):sub(-40)))
    end
else
    local s = first
    for i = 1, n do
        if not s then break end
        out(string.format("[%d] %s", i, s.text))
        s = BookText.nextSentence(ui, s)
    end
end
os.exit(0)
