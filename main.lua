--[[--
Voice Companion: listen to words, sentences and books with AI or device
voices, get pronunciation coaching, and hear explanations.

Nothing heavy happens at startup: voices, network and Android TTS are only
initialized when a feature is first used.
--]]

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
    Dispatcher:registerAction("voicecompanion_stop", {
        category = "none", event = "VoiceCompanionStop",
        title = _("Voice Companion: stop speaking"), general = true,
    })
    Dispatcher:registerAction("voicecompanion_pause", {
        category = "none", event = "VoiceCompanionPauseResume",
        title = _("Voice Companion: pause / resume"), general = true,
    })
end

function VoiceCompanion:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    if self.ui.highlight then
        self:addHighlightButtons()
    end
end

--- Shared Voice instance, created on first use.
function VoiceCompanion:getVoice()
    if not self.voice then
        self.voice = require("voicecompanion/voice"):new()
    end
    return self.voice
end

function VoiceCompanion:showError(err)
    logger.warn("VoiceCompanion:", err)
    UIManager:show(InfoMessage:new{ text = T(_("Voice Companion:\n%1"), tostring(err)) })
end

--- Speak `text` with the default voice; on_done(ok) optional.
function VoiceCompanion:speakText(text, opts, on_done)
    if not text or text:match("^%s*$") then return end
    self:getVoice():speak(text, opts, function(ok, err)
        if not ok then self:showError(err) end
        if on_done then on_done(ok) end
    end)
end

local function selectedText(this)
    local text = this.selected_text and this.selected_text.text
    if not text then return nil end
    local ok, util = pcall(require, "util")
    if ok and util.cleanupSelectedText then text = util.cleanupSelectedText(text) end
    return text
end

function VoiceCompanion:addHighlightButtons()
    self.ui.highlight:addToHighlightDialog("13_vc_speak", function(this)
        return {
            text = _("Speak"),
            callback = function()
                local text = selectedText(this)
                this:onClose(true)  -- keep the selection visible while speaking
                self:speakText(text, nil, function()
                    this:clear()
                end)
            end,
        }
    end)
end

function VoiceCompanion:onVoiceCompanionStop()
    if self.voice then self.voice:stop() end
    return true
end

function VoiceCompanion:onVoiceCompanionPauseResume()
    local voice = self.voice
    if not voice then return true end
    if voice:isPaused() then
        voice:resume()
    elseif voice.busy then
        if voice:canPause() then voice:pause() else voice:stop() end
    end
    return true
end

function VoiceCompanion:addToMainMenu(menu_items)
    menu_items.voicecompanion = {
        text = _("Voice Companion"),
        sorting_hint = "tools",
        sub_item_table_func = function() return self:buildMenu() end,
    }
end

function VoiceCompanion:buildMenu()
    local Diagnostics = require("voicecompanion/diagnostics")
    local items = {
        {
            text = _("Stop speaking"),
            enabled_func = function() return self.voice ~= nil and self.voice.busy end,
            callback = function() self:onVoiceCompanionStop() end,
            separator = true,
        },
        {
            text = _("Settings"),
            sub_item_table_func = function()
                return require("voicecompanion/ui/settings_menu").build()
            end,
        },
    }
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
    table.insert(items, { text = _("Diagnostics"), sub_item_table = diag })
    return items
end

function VoiceCompanion:onCloseDocument()
    if self.voice then self.voice:stop() end
end

function VoiceCompanion:onSuspend()
    if self.voice then self.voice:stop() end
end

function VoiceCompanion:onExit()
    if self.voice then self.voice:shutdown() end
end

return VoiceCompanion
