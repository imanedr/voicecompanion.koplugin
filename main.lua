--[[--
Voice Companion: listen to words, sentences and books with AI or device
voices, get pronunciation coaching, and hear explanations.

Nothing heavy happens at startup: voices, network and Android TTS are only
initialized when a feature is first used.
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")

local VoiceCompanion = WidgetContainer:extend{
    name = "voicecompanion",
    is_doc_only = false,
}

function VoiceCompanion:onDispatcherRegisterActions()
    Dispatcher:registerAction("voicecompanion_read", {
        category = "none", event = "VoiceCompanionReadAloud",
        title = _("Voice Companion: read aloud from this page"), reader = true,
    })
    Dispatcher:registerAction("voicecompanion_pause", {
        category = "none", event = "VoiceCompanionPauseResume",
        title = _("Voice Companion: pause / resume"), general = true,
    })
    Dispatcher:registerAction("voicecompanion_stop", {
        category = "none", event = "VoiceCompanionStop",
        title = _("Voice Companion: stop"), general = true,
    })
    Dispatcher:registerAction("voicecompanion_summary", {
        category = "none", event = "VoiceCompanionSummary",
        title = _("Voice Companion: summarize this page"), reader = true,
    })
end

function VoiceCompanion:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    if self.ui.highlight then
        self:addHighlightButtons()
    end
    if self.ui.dictionary and self.ui.dictionary.addToDictButtons then
        self:addDictionaryButtons()
    end
end

--- Shared Voice instance, created on first use.
function VoiceCompanion:getVoice()
    if not self.voice then
        self.voice = require("voicecompanion/voice"):new()
    end
    return self.voice
end

function VoiceCompanion:getReadAloud()
    if not self.read_aloud then
        self.read_aloud = require("voicecompanion/features/readaloud"):new(self)
    end
    return self.read_aloud
end

function VoiceCompanion:showError(err)
    logger.warn("VoiceCompanion:", err)
    UIManager:show(InfoMessage:new{ text = T(_("Voice Companion:\n%1"), tostring(err)) })
end

--- Stop book reading (if any) before another feature speaks.
function VoiceCompanion:interruptReading()
    if self.read_aloud and self.read_aloud:isActive() then
        self.read_aloud:stop()
    end
end

--- Speak a short text; on_done(ok) optional.
function VoiceCompanion:speakText(text, opts, on_done)
    if not text or text:match("^%s*$") then return end
    self:interruptReading()
    self:getVoice():speak(text, opts, function(ok, err)
        if not ok then self:showError(err) end
        if on_done then on_done(ok) end
    end)
end

--- Speak a longer text sentence by sentence (starts sooner, fetches ahead).
function VoiceCompanion:speakLongText(text, engine)
    if not text or text:match("^%s*$") then return end
    self:interruptReading()
    local chunks = require("voicecompanion/sentences").chunks(text)
    self:getVoice():speakSequence(chunks, { engine = engine, prefetch = 2 }, {
        on_done = function(ok, err) if not ok then self:showError(err) end end,
    })
end

-- ── Text selection ─────────────────────────────────────────────────────

local function selectedText(this)
    local text = this.selected_text and this.selected_text.text
    if not text then return nil end
    local ok, util = pcall(require, "util")
    if ok and util.cleanupSelectedText then text = util.cleanupSelectedText(text) end
    return text
end

local function selectionCopy(this)
    local sel = this.selected_text
    if not sel then return nil end
    return { text = selectedText(this), pos0 = sel.pos0, pos1 = sel.pos1 }
end

function VoiceCompanion:showVoiceActions(selection)
    local BookText = require("voicecompanion/reader/booktext")
    local Explain = require("voicecompanion/features/explain")
    local dialog
    local function close() UIManager:close(dialog) end
    local is_word = selection.text and not selection.text:find("%s") and #selection.text <= 40
    local buttons = {
        {
            {
                text = _("Speak"),
                callback = function() close() self:speakText(selection.text) end,
            },
            {
                text = _("Speak slowly"),
                callback = function()
                    close()
                    local cfg = require("voicecompanion/config").load()
                    self:speakText(selection.text, { speed = cfg.pronounce.slow_speed })
                end,
            },
        },
        {
            {
                text = _("Pronunciation coach"),
                enabled = is_word or #selection.text <= 40,
                callback = function()
                    close()
                    require("voicecompanion/features/pronounce").open(self, selection.text,
                        BookText.selectionSentence(self.ui, selection))
                end,
            },
            {
                text = _("Read aloud from here"),
                enabled = BookText.isReflowable(self.ui) and selection.pos0 ~= nil,
                callback = function()
                    close()
                    self:interruptReading()
                    self:getReadAloud():start(BookText.sentenceAt(self.ui, selection.pos0))
                end,
            },
        },
    }
    local row = {}
    for _i, mode in ipairs(Explain.MODES) do
        if not mode.no_selection then
            table.insert(row, {
                text = mode.title,
                callback = function() close() Explain.run(self, mode.id, selection) end,
            })
        end
    end
    table.insert(buttons, row)
    table.insert(buttons, {
        {
            text = _("Ask about this…"),
            callback = function() close() Explain.askQuestion(self, selection) end,
        },
    })
    dialog = ButtonDialog:new{
        title = selection.text:sub(1, 120),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function VoiceCompanion:addHighlightButtons()
    self.ui.highlight:addToHighlightDialog("13_vc_speak", function(this)
        return {
            text = _("Speak"),
            callback = function()
                local text = selectedText(this)
                this:onClose(true)  -- keep the selection visible while speaking
                self:speakText(text, nil, function() this:clear() end)
            end,
        }
    end)
    self.ui.highlight:addToHighlightDialog("13_vc_voice", function(this)
        return {
            text = _("Voice…"),
            callback = function()
                local selection = selectionCopy(this)
                this:onClose()
                if selection and selection.text then self:showVoiceActions(selection) end
            end,
        }
    end)
end

-- ── Dictionary popup ───────────────────────────────────────────────────

function VoiceCompanion:addDictionaryButtons()
    local function word(dict_popup)
        return dict_popup.lookupword or dict_popup.word
    end
    self.ui.dictionary:addToDictButtons({
        id = "vc_1_speak",
        text = "🔊 " .. _("Speak"),
        conditional = true,
        row_group = "voicecompanion",
        callback = function(dict_popup) self:speakText(word(dict_popup)) end,
        hold_callback = function(dict_popup)
            local cfg = require("voicecompanion/config").load()
            self:speakText(word(dict_popup), { speed = cfg.pronounce.slow_speed })
        end,
    })
    self.ui.dictionary:addToDictButtons({
        id = "vc_2_pronounce",
        text = _("Pronunciation"),
        conditional = true,
        row_group = "voicecompanion",
        callback = function(dict_popup)
            require("voicecompanion/features/pronounce").open(self, word(dict_popup))
        end,
    })
end

-- ── Events (gestures) ──────────────────────────────────────────────────

function VoiceCompanion:onVoiceCompanionReadAloud()
    self:interruptReading()
    self:getReadAloud():start()
    return true
end

function VoiceCompanion:onVoiceCompanionStop()
    if self.read_aloud then self.read_aloud:stop() end
    if self.voice then self.voice:stop() end
    return true
end

function VoiceCompanion:onVoiceCompanionPauseResume()
    if self.read_aloud and self.read_aloud:isActive() then
        self.read_aloud:togglePause()
        return true
    end
    local voice = self.voice
    if not voice then return true end
    if voice:isPaused() then
        voice:resume()
    elseif voice.busy then
        if voice:canPause() then voice:pause() else voice:stop() end
    end
    return true
end

function VoiceCompanion:onVoiceCompanionSummary()
    require("voicecompanion/features/explain").run(self, "summary")
    return true
end

-- ── Menu ───────────────────────────────────────────────────────────────

function VoiceCompanion:addToMainMenu(menu_items)
    menu_items.voicecompanion = {
        text = _("Voice Companion"),
        sorting_hint = "tools",
        sub_item_table_func = function() return self:buildMenu() end,
    }
end

function VoiceCompanion:buildMenu()
    local in_book = self.ui.document ~= nil
    local items = {}
    if in_book then
        table.insert(items, {
            text_func = function()
                local ra = self.read_aloud
                if ra and ra.state == "playing" then return _("Pause reading") end
                if ra and ra.state == "paused" then return _("Resume reading") end
                return _("Read aloud from this page")
            end,
            callback = function()
                local ra = self.read_aloud
                if ra and ra:isActive() then
                    ra:togglePause()
                else
                    self:onVoiceCompanionReadAloud()
                end
            end,
        })
    end
    table.insert(items, {
        text = _("Stop"),
        enabled_func = function()
            return (self.voice ~= nil and self.voice.busy)
                or (self.read_aloud ~= nil and self.read_aloud:isActive())
        end,
        callback = function() self:onVoiceCompanionStop() end,
        separator = true,
    })
    if in_book then
        table.insert(items, {
            text = _("Summarize this page"),
            callback = function() self:onVoiceCompanionSummary() end,
        })
        table.insert(items, {
            text = _("Ask about the book…"),
            callback = function() require("voicecompanion/features/explain").askQuestion(self) end,
            separator = true,
        })
    end
    table.insert(items, {
        text = _("Settings"),
        sub_item_table_func = function()
            return require("voicecompanion/ui/settings_menu").build()
        end,
    })
    table.insert(items, {
        text = _("Diagnostics"),
        sub_item_table_func = function() return self:buildDiagnosticsMenu() end,
    })
    return items
end

function VoiceCompanion:buildDiagnosticsMenu()
    local Diagnostics = require("voicecompanion/diagnostics")
    local diag = {}
    local crashed = Diagnostics.crashedTest()
    if crashed then
        table.insert(diag, {
            text = T(_("⚠ Last run stopped during: %1"), crashed),
            keep_menu_open = true,
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = T(_("The test \"%1\" started but never finished, so it probably crashed KOReader.\n\nPlease report this. Tap \"Clear log\" to reset."), crashed),
                })
            end,
        })
    end
    for _i, test in ipairs(Diagnostics.TESTS) do
        table.insert(diag, {
            text = test.title,
            keep_menu_open = true,
            callback = function()
                Diagnostics.setVoice(self:getVoice())
                test.run()
            end,
        })
    end
    table.insert(diag, {
        text = _("Clear log"),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            Diagnostics.clearLog()
            if touchmenu_instance then touchmenu_instance:closeMenu() end
        end,
    })
    return diag
end

-- ── Lifecycle ──────────────────────────────────────────────────────────

function VoiceCompanion:onCloseDocument()
    self:onVoiceCompanionStop()
end

function VoiceCompanion:onSuspend()
    self:onVoiceCompanionStop()
end

function VoiceCompanion:onExit()
    self:onVoiceCompanionStop()
    if self.voice then self.voice:shutdown() end
end

return VoiceCompanion
