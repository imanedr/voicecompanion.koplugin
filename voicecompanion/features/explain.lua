--[[--
Explain what you're reading, out loud: explain a passage, define a word in
context, translate, summarize the page so far, or ask your own question.
The answer is shown in a dialog and spoken; follow-up questions keep the
conversation.
--]]

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local AI = require("voicecompanion/ai")
local BookText = require("voicecompanion/reader/booktext")
local Config = require("voicecompanion/config")
local T = require("ffi/util").template
local _ = require("gettext")

local Explain = {}

Explain.MODES = {
    {
        id = "explain",
        title = _("Explain"),
        prompt = "Explain the following passage from the book in simple words: what it means, and anything a reader might find unclear (references, idioms, difficult words).\n\nPassage: «%s»",
    },
    {
        id = "define",
        title = _("Define in context"),
        prompt = "Give the meaning of «%s» as it is used here, in one or two sentences, then one short example sentence.",
    },
    {
        id = "translate",
        title = _("Translate"),
        prompt = "Translate the following into the answer language, naturally. Then briefly note any nuance that is lost in translation.\n\nText: «%s»",
        answer_language_only = true,
    },
    {
        id = "summary",
        title = _("Summarize the page"),
        prompt = "Summarize what happens in the current page of the book (given as the book context) in a few spoken-style sentences. Do not reveal anything beyond it.",
        no_selection = true,
    },
}

local function systemPrompt(cfg, book_title)
    return string.format([[You are a reading companion inside an e-reader. Your answers are read aloud, so:
- write in %s, in plain conversational sentences;
- no markdown, no bullet symbols, no tables, no headings;
- keep it short: about 3 to 6 sentences unless asked for more;
- never reveal plot points beyond the context you are given.
The book is: %s.]], cfg.explain.language or "English", book_title or "unknown")
end

local function bookTitle(ui)
    local props = ui and ui.doc_props
    if props then
        local title = props.display_title or props.title
        if props.authors and props.authors ~= "" then
            return string.format("%s by %s", tostring(title), tostring(props.authors))
        end
        return title
    end
end

--- Start a conversation.  `selection` = { text, pos0, pos1 } or nil.
function Explain.run(plugin, mode_id, selection)
    local mode
    for _i, m in ipairs(Explain.MODES) do
        if m.id == mode_id then mode = m end
    end
    if not mode then return end
    local ui = plugin.ui
    local cfg = Config.load()
    local text = selection and selection.text
    if not mode.no_selection and (not text or text:match("^%s*$")) then return end

    local context = BookText.contextText(ui, cfg.explain.max_context_chars or 6000)
    local user = mode.no_selection and mode.prompt or string.format(mode.prompt, text)
    if mode_id == "define" then
        local sentence = BookText.selectionSentence(ui, selection)
        if sentence then user = user .. "\nSentence: «" .. sentence .. "»" end
    end
    local messages = { { role = "system", content = systemPrompt(cfg, bookTitle(ui)) } }
    if context and context ~= "" then
        table.insert(messages, { role = "user", content = "Book context (the text just before and on the current page):\n«" .. context .. "»" })
        table.insert(messages, { role = "assistant", content = "Understood." })
    elseif mode.no_selection then
        UIManager:show(InfoMessage:new{ text = _("Page text is only available for EPUB-style books.") })
        return
    end
    table.insert(messages, { role = "user", content = user })
    Explain.ask(plugin, messages, mode.title)
end

--- Free question about the current page.
function Explain.askQuestion(plugin, selection)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Ask about the book"),
        input_hint = _("e.g. Who is Mr. Smith?"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Ask"),
                is_enter_default = true,
                callback = function()
                    local q = dialog:getInputText()
                    UIManager:close(dialog)
                    if q:match("%S") then
                        local cfg = Config.load()
                        local ui = plugin.ui
                        local messages = { { role = "system", content = systemPrompt(cfg, bookTitle(ui)) } }
                        local context = BookText.contextText(ui, cfg.explain.max_context_chars or 6000)
                        if context then
                            table.insert(messages, { role = "user", content = "Book context:\n«" .. context .. "»" })
                            table.insert(messages, { role = "assistant", content = "Understood." })
                        end
                        if selection and selection.text then
                            q = q .. "\n(About this passage: «" .. selection.text .. "»)"
                        end
                        table.insert(messages, { role = "user", content = q })
                        Explain.ask(plugin, messages, _("Question"))
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Send `messages`, show and speak the answer.
function Explain.ask(plugin, messages, title)
    AI.ask(messages, function(ok, answer)
        if not ok then return plugin:showError(answer) end
        answer = answer:gsub("%*%*", ""):gsub("^%s+", ""):gsub("%s+$", "")
        table.insert(messages, { role = "assistant", content = answer })
        Explain.show(plugin, messages, title, answer)
    end)
end

function Explain.show(plugin, messages, title, answer)
    local TextViewer = require("ui/widget/textviewer")
    local cfg = Config.load()
    local viewer
    local function speak() plugin:speakLongText(answer, cfg.voice_engine) end
    viewer = TextViewer:new{
        title = title,
        text = answer,
        justified = false,
        add_default_buttons = false,
        buttons_table = {
            {
                { text = "▶ " .. _("Listen"), callback = speak },
                { text = "■ " .. _("Stop"), callback = function() plugin:onVoiceCompanionStop() end },
            },
            {
                {
                    text = _("Ask follow-up"),
                    callback = function()
                        local InputDialog = require("ui/widget/inputdialog")
                        local dialog
                        dialog = InputDialog:new{
                            title = _("Follow-up question"),
                            buttons = {{
                                { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                                {
                                    text = _("Ask"),
                                    is_enter_default = true,
                                    callback = function()
                                        local q = dialog:getInputText()
                                        UIManager:close(dialog)
                                        if q:match("%S") then
                                            plugin:onVoiceCompanionStop()
                                            UIManager:close(viewer)
                                            table.insert(messages, { role = "user", content = q })
                                            Explain.ask(plugin, messages, title)
                                        end
                                    end,
                                },
                            }},
                        }
                        UIManager:show(dialog)
                        dialog:onShowKeyboard()
                    end,
                },
                {
                    text = _("Close"),
                    callback = function()
                        plugin:onVoiceCompanionStop()
                        UIManager:close(viewer)
                    end,
                },
            },
        },
    }
    UIManager:show(viewer)
    if cfg.explain.speak_answer then speak() end
end

return Explain
