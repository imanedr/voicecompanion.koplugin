--[[--
Read the book aloud from the current page: sentence by sentence, with the
current sentence highlighted, pages turned automatically, and upcoming
sentences fetched while one plays.  Reflowable documents only.
--]]

local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local BookText = require("voicecompanion/reader/booktext")
local Config = require("voicecompanion/config")
local _ = require("gettext")

local ReadAloud = {}
ReadAloud.__index = ReadAloud

function ReadAloud:new(plugin)
    return setmetatable({ plugin = plugin, ui = plugin.ui, state = "stopped" }, self)
end

function ReadAloud:isActive()
    return self.state ~= "stopped"
end

local function speakable(text)
    return text and text:find("[%w\128-\255]") ~= nil
end

local function clean(text)
    return (text:gsub("\194\173", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Start reading at `first` (a sentence) or at the top of the current page.
function ReadAloud:start(first)
    local ui = self.ui
    if not BookText.isReflowable(ui) then
        UIManager:show(InfoMessage:new{ text = _("Reading aloud works with EPUB, FB2 and other reflowable books.") })
        return
    end
    first = first or BookText.firstSentenceOnPage(ui)
    if not first then
        UIManager:show(InfoMessage:new{ text = _("No text found on this page.") })
        return
    end
    local cfg = Config.load()
    self.cfg = cfg
    self.list = {}
    self.state = "playing"
    self.current = nil

    -- Lazily walk the book; only speakable sentences enter the list.
    local list = self.list
    local function get(i)
        while #list < i do
            local s
            if #list == 0 then
                s = first
            else
                s = BookText.nextSentence(ui, list[#list])
            end
            local guard = 0
            while s and not speakable(s.text) and guard < 50 do
                s = BookText.nextSentence(ui, s)
                guard = guard + 1
            end
            if not s then return nil end
            s.text = clean(s.text)
            table.insert(list, s)
        end
        return list[i].text
    end

    self.plugin:getVoice():speakSequence(get, {
        engine = cfg.read_aloud.engine,
        prefetch = cfg.read_aloud.prefetch or 2,
    }, {
        on_item = function(i) self:_show(list[i]) end,
        on_done = function(ok, err)
            self:_finish()
            if not ok then self.plugin:showError(err) end
        end,
    })
end

--- Bring the sentence on screen and highlight it.
function ReadAloud:_show(sentence)
    self.current = sentence
    local ui, doc = self.ui, self.ui.document
    if not doc:isXPointerInCurrentPage(sentence.pos0) then
        ui:handleEvent(Event:new("GotoViewRel", 1))
        if not doc:isXPointerInCurrentPage(sentence.pos0) then
            ui:handleEvent(Event:new("GotoXPointer", sentence.pos0, sentence.pos0))
        end
    end
    if self.cfg.read_aloud.highlight then
        BookText.highlight(ui, sentence)
    end
    -- Count listening as activity so the device doesn't auto-suspend
    -- (the AutoSuspend plugin listens on this hook for user input).
    if UIManager.event_hook then
        pcall(UIManager.event_hook.execute, UIManager.event_hook, "InputEvent")
    end
end

function ReadAloud:_finish()
    self.state = "stopped"
    BookText.clearHighlight(self.ui)
end

function ReadAloud:stop()
    if self.state == "stopped" then return end
    self:_finish()
    self.current = nil
    self.plugin:getVoice():stop()
end

--- Pause/resume.  File playback pauses in place; the Android system voice
-- (and audio still loading) can't pause, so it stops and later restarts the
-- current sentence.
function ReadAloud:togglePause()
    local voice = self.plugin:getVoice()
    if self.state == "playing" then
        -- Set first: the voice reports its state change right away.
        self.state = "paused"
        if voice:canPause() then
            voice:pause()
        else
            voice:stop()
        end
    elseif self.state == "paused" then
        if voice:isPaused() then
            voice:resume()
            self.state = "playing"
        else
            local from = self.current
            self.state = "stopped"
            self:start(from)
        end
    end
end

return ReadAloud
