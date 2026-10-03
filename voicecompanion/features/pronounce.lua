--[[--
Pronunciation coach: IPA, an easy respelling, syllables and stress, tips,
similar-sounding words, and buttons to hear the word normally, slowly, by
syllable and in its sentence.  No microphone is needed.

Analyses are cached on disk per word + context language, so reopening the
coach for a word costs nothing.
--]]

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local AI = require("voicecompanion/ai")
local Async = require("voicecompanion/async")
local AudioCache = require("voicecompanion/audiocache")
local Config = require("voicecompanion/config")
local Provider = require("voicecompanion/provider")
local T = require("ffi/util").template
local _ = require("gettext")

local Pronounce = {}

local SYSTEM_PROMPT = [[You are a friendly pronunciation coach for language learners.
Reply with a single JSON object and nothing else.]]

local USER_PROMPT = [[Word: «%s»
%s
Explain how to pronounce this word. Write all explanations in %s.
Return JSON with exactly these keys:
- "word": the word as written
- "language": the language of the word
- "ipa": IPA transcription for the most common accent, with slashes
- "ipa_alt": IPA for the other main accent (e.g. UK vs US) or "" if the same
- "accent": which accent "ipa" is (e.g. "US"), and "accent_alt" for "ipa_alt"
- "respelling": an easy respelling with the stressed syllable in CAPITALS, e.g. "ih-FEM-er-ul"
- "syllables": array of the written syllables, e.g. ["e","phem","er","al"]
- "stress": 1-based index of the stressed syllable
- "meaning": a very short meaning (as used in the sentence, if given)
- "tips": array of 1 to 3 short tips about the sounds learners most often get wrong
- "similar": array of up to 4 objects {"word": ..., "note": ...} with words that rhyme or are easily confused, and how they differ]]

local function cachePath(word, lang)
    return string.format("%s/coach_%s.json", AudioCache.dir(),
        AudioCache.hash(word:lower() .. "\31" .. lang))
end

local function readCache(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    local ok, decoded = pcall(require("json").decode, data)
    return ok and type(decoded) == "table" and decoded or nil
end

local function writeCache(path, info)
    local ok, encoded = pcall(require("json").encode, info)
    if not ok then return end
    local f = io.open(path, "w")
    if f then f:write(encoded) f:close() end
end

local function list(v)
    return type(v) == "table" and v or {}
end

--- Format the analysis for the dialog.
function Pronounce.formatText(info)
    local lines = {}
    local ipa = info.ipa or ""
    if info.accent and info.accent ~= "" then ipa = ipa .. "  (" .. info.accent .. ")" end
    table.insert(lines, ipa)
    if info.ipa_alt and info.ipa_alt ~= "" then
        table.insert(lines, info.ipa_alt .. (info.accent_alt and info.accent_alt ~= "" and ("  (" .. info.accent_alt .. ")") or ""))
    end
    if info.respelling and info.respelling ~= "" then
        table.insert(lines, "")
        table.insert(lines, T(_("Say it: %1"), info.respelling))
    end
    local syl = list(info.syllables)
    if #syl > 0 then
        local parts = {}
        for i, s in ipairs(syl) do
            parts[i] = (i == tonumber(info.stress)) and s:upper() or s
        end
        table.insert(lines, T(_("Syllables: %1"), table.concat(parts, " · ")))
    end
    if info.meaning and info.meaning ~= "" then
        table.insert(lines, "")
        table.insert(lines, T(_("Meaning: %1"), info.meaning))
    end
    local tips = list(info.tips)
    if #tips > 0 then
        table.insert(lines, "")
        table.insert(lines, _("Tips:"))
        for _i, tip in ipairs(tips) do table.insert(lines, "• " .. tostring(tip)) end
    end
    local similar = list(info.similar)
    if #similar > 0 then
        table.insert(lines, "")
        table.insert(lines, _("Similar words:"))
        for _i, s in ipairs(similar) do
            if type(s) == "table" and s.word then
                table.insert(lines, "• " .. s.word .. (s.note and s.note ~= "" and (" — " .. s.note) or ""))
            end
        end
    end
    return table.concat(lines, "\n")
end

--- Open the coach for `word`.  `sentence` (optional) gives context.
function Pronounce.open(plugin, word, sentence)
    word = (word or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if word == "" then return end
    if #word > 60 then
        UIManager:show(InfoMessage:new{ text = _("Select a single word or a short phrase for the pronunciation coach.") })
        return
    end
    local cfg = Config.load()
    local lang = cfg.explain.language or "English"
    local path = cachePath(word, lang)
    local cached = readCache(path)
    if cached then return Pronounce.show(plugin, word, sentence, cached) end

    local context = sentence and sentence ~= "" and ("Sentence: «" .. sentence:sub(1, 400) .. "»") or ""
    AI.ask({
        { role = "system", content = SYSTEM_PROMPT },
        { role = "user", content = string.format(USER_PROMPT, word, context, lang) },
    }, function(ok, answer)
        if not ok then return plugin:showError(answer) end
        local info, perr = Provider.parseJsonAnswer(answer)
        if not info then return plugin:showError(_("The model's answer could not be read: ") .. perr) end
        writeCache(path, info)
        Pronounce.show(plugin, word, sentence, info)
    end, { waiting_text = T(_("Preparing pronunciation for “%1”…"), word), temperature = 0.2 })
end

function Pronounce.show(plugin, word, sentence, info)
    local TextViewer = require("ui/widget/textviewer")
    local cfg = Config.load()
    local engine = cfg.pronounce.engine
    local slow = cfg.pronounce.slow_speed or 0.7
    local viewer

    local function say(text, speed)
        plugin:speakText(text, { engine = engine, speed = speed })
    end

    local syllables = list(info.syllables)
    local row1 = {
        { text = "▶ " .. _("Normal"), callback = function() say(word) end },
        { text = "▶ " .. _("Slow"), callback = function() say(word, slow) end },
    }
    if #syllables > 1 then
        table.insert(row1, {
            text = "▶ " .. _("Syllables"),
            -- Commas make every voice pause between syllables.
            callback = function() say(table.concat(syllables, ", ") .. ".", slow) end,
        })
    end
    local buttons = { row1 }

    local row2 = {}
    if sentence and sentence ~= "" and sentence ~= word then
        table.insert(row2, { text = "▶ " .. _("In sentence"), callback = function() say(sentence) end })
    end
    for _i, s in ipairs(list(info.similar)) do
        if #row2 >= 3 then break end
        if type(s) == "table" and s.word then
            table.insert(row2, { text = "▶ " .. s.word, callback = function() say(s.word) end })
        end
    end
    if #row2 > 0 then table.insert(buttons, row2) end

    table.insert(buttons, {
        { text = "■ " .. _("Stop"), callback = function() plugin:onVoiceCompanionStop() end },
        { text = _("Close"), callback = function() UIManager:close(viewer) end },
    })

    viewer = TextViewer:new{
        title = info.word or word,
        text = Pronounce.formatText(info),
        justified = false,
        buttons_table = buttons,
        add_default_buttons = false,
        height = math.floor(require("device").screen:getHeight() * 0.75),
    }
    UIManager:show(viewer)
    -- Prefetch the normal and slow audio so the first tap plays at once.
    local voice = plugin:getVoice()
    voice:prepare(word, { engine = engine })
    voice:prepare(word, { engine = engine, speed = slow })
end

return Pronounce
