--[[--
Settings submenu.  Every change is written to configuration.lua through
Config.set, so the file stays the single source of truth.
--]]

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Config = require("voicecompanion/config")
local T = require("ffi/util").template
local _ = require("gettext")

local SettingsMenu = {}

local function saveOrWarn(path, value)
    local ok, err = Config.set(path, value)
    if not ok then
        UIManager:show(InfoMessage:new{ text = T(_("Could not save setting:\n%1"), tostring(err)) })
    end
    return ok
end

--- Text input for one setting.  `kind` = "string" | "number".
local function inputItem(label_fn, path_fn, opts)
    opts = opts or {}
    return {
        text_func = label_fn,
        keep_menu_open = true,
        separator = opts.separator,
        callback = function(touchmenu_instance)
            local InputDialog = require("ui/widget/inputdialog")
            local cfg = Config.load()
            local node = cfg
            local path = path_fn(cfg)
            for part in path:gmatch("[^%.]+") do node = type(node) == "table" and node[part] or nil end
            local dialog
            dialog = InputDialog:new{
                title = opts.title,
                input = node ~= nil and tostring(node) or "",
                input_hint = opts.hint,
                description = opts.description,
                buttons = {{
                    { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                    {
                        text = _("Save"),
                        is_enter_default = true,
                        callback = function()
                            local v = dialog:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                            if opts.kind == "number" then
                                v = tonumber(v)
                                if not v then return end
                            end
                            if saveOrWarn(path, v) then
                                UIManager:close(dialog)
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                            end
                        end,
                    },
                }},
            }
            UIManager:show(dialog)
            dialog:onShowKeyboard()
        end,
    }
end

local function providerField(field)
    return function(cfg) return "providers." .. cfg.provider .. "." .. field end
end

local function current(field)
    local cfg = Config.load()
    local p = cfg.providers[cfg.provider] or {}
    return p[field]
end

function SettingsMenu.build()
    local items = {}

    table.insert(items, {
        text_func = function()
            local _cfg, err = Config.load()
            if err then return _("Configuration file: ERROR (tap)") end
            return Config.exists() and _("Configuration file: configuration.lua")
                or _("Configuration file: not created yet (tap)")
        end,
        keep_menu_open = true,
        callback = function()
            local _cfg, err = Config.load()
            UIManager:show(InfoMessage:new{
                text = err and T(_("Error in %1:\n\n%2"), Config.file, err)
                    or T(_("Settings are stored in:\n%1\n\nEdit it on a computer (start from configuration.sample.lua), or change settings here and it is written for you."), Config.file),
            })
        end,
        separator = true,
    })

    table.insert(items, {
        text = _("Default voice"),
        sub_item_table = {
            {
                text = _("Cloud (AI voice)"),
                checked_func = function() return Config.load().voice_engine == "cloud" end,
                callback = function() saveOrWarn("voice_engine", "cloud") end,
            },
            {
                text = _("Device voice (offline)"),
                checked_func = function() return Config.load().voice_engine == "local" end,
                callback = function() saveOrWarn("voice_engine", "local") end,
            },
        },
    })

    table.insert(items, {
        text_func = function() return T(_("Provider: %1"), Config.load().provider) end,
        sub_item_table_func = function()
            local sub = {}
            local names = {}
            for name in pairs(Config.load().providers) do table.insert(names, name) end
            table.sort(names)
            for _i, name in ipairs(names) do
                table.insert(sub, {
                    text = name,
                    checked_func = function() return Config.load().provider == name end,
                    callback = function() saveOrWarn("provider", name) end,
                })
            end
            return sub
        end,
    })

    table.insert(items, inputItem(function()
        local key = current("api_key")
        return T(_("API key: %1"), Config.isKeyMissing(key) and _("not set") or ("…" .. key:sub(-4)))
    end, providerField("api_key"), {
        title = _("API key"), hint = "sk-or-v1-…",
        description = _("For OpenRouter, create a key at openrouter.ai/keys."),
    }))
    table.insert(items, inputItem(function() return T(_("Cloud voice: %1"), tostring(current("voice"))) end,
        providerField("voice"), {
            title = _("Cloud voice"), hint = "af_heart",
            description = _("Must be a voice the speech model supports (Kokoro: af_heart, bf_emma, am_michael …)."),
        }))
    table.insert(items, inputItem(function() return T(_("Speech model: %1"), tostring(current("tts_model"))) end,
        providerField("tts_model"), {
            title = _("Speech model"), hint = "hexgrad/kokoro-82m",
            description = _("Some models need a specific audio format (Gemini TTS: pcm). Set it under Audio format."),
        }))
    table.insert(items, {
        text_func = function() return T(_("Audio format: %1"), tostring(current("audio_format") or "mp3")) end,
        sub_item_table_func = function()
            local function formatItem(format, label)
                return {
                    text = label,
                    checked_func = function() return (current("audio_format") or "mp3") == format end,
                    callback = function() saveOrWarn(providerField("audio_format")(Config.load()), format) end,
                }
            end
            return {
                formatItem("mp3", _("mp3 (smaller downloads)")),
                formatItem("pcm", _("pcm (raw audio; required by Gemini TTS)")),
            }
        end,
    })
    table.insert(items, inputItem(function()
        return T(_("PCM sample rate: %1"), tostring(current("sample_rate")))
    end, providerField("sample_rate"), {
        title = _("PCM sample rate"), hint = "24000", kind = "number",
        description = _("Only used with pcm. Must match the model's output, or speech plays too fast or too slow (Kokoro, OpenAI and Gemini: 24000)."),
    }))
    table.insert(items, inputItem(function() return T(_("Chat model: %1"), tostring(current("chat_model"))) end,
        providerField("chat_model"), {
            title = _("Chat model"), hint = "google/gemini-3.8-flash",
            description = _("Used for pronunciation help and explanations."),
            separator = true,
        }))
    table.insert(items, {
        text = _("Reading aloud"),
        sub_item_table_func = function() return SettingsMenu.readAloudItems() end,
        separator = true,
    })
    table.insert(items, inputItem(function()
        return T(_("Device voice language: %1"), tostring(Config.load().local_tts.language))
    end, function() return "local_tts.language" end, {
        title = _("Device voice language"), hint = "en-US",
        description = _("Language tag such as en-US, en-GB, fr-FR. The voice must be installed in Android's text-to-speech settings."),
    }))
    table.insert(items, inputItem(function()
        return T(_("Device voice speed: %1"), tostring(Config.load().local_tts.rate))
    end, function() return "local_tts.rate" end, {
        title = _("Device voice speed"), hint = "1.0", kind = "number",
    }))
    return items
end

local function choiceItem(path, value, label)
    return {
        text = label,
        checked_func = function()
            local node = Config.load()
            for part in path:gmatch("[^%.]+") do node = type(node) == "table" and node[part] or nil end
            return node == value
        end,
        callback = function() saveOrWarn(path, value) end,
    }
end

function SettingsMenu.readAloudItems()
    local function get(field) return Config.load().read_aloud[field] end
    return {
        {
            text_func = function()
                local n = tonumber(get("chunk_chars")) or 300
                return T(_("Text per request: %1"), n > 0 and T(_("~%1 characters"), n) or _("one sentence"))
            end,
            sub_item_table = {
                choiceItem("read_aloud.chunk_chars", 0, _("One sentence (highlight follows each sentence)")),
                choiceItem("read_aloud.chunk_chars", 150, _("Short (~150 characters)")),
                choiceItem("read_aloud.chunk_chars", 300, _("Medium (~300 characters)")),
                choiceItem("read_aloud.chunk_chars", 500, _("Long (~500 characters)")),
            },
        },
        {
            text_func = function() return T(_("Requests at once: %1"), tostring(get("parallel") or 2)) end,
            sub_item_table = {
                choiceItem("read_aloud.parallel", 1, _("1 (slow connections)")),
                choiceItem("read_aloud.parallel", 2, "2"),
                choiceItem("read_aloud.parallel", 3, "3"),
            },
        },
        {
            text = _("Highlight the text being read"),
            checked_func = function() return get("highlight") ~= false end,
            callback = function() saveOrWarn("read_aloud.highlight", get("highlight") == false) end,
        },
        {
            text = _("Trim silence around AI audio (pcm)"),
            checked_func = function() return Config.load().trim_silence ~= false end,
            callback = function() saveOrWarn("trim_silence", Config.load().trim_silence == false) end,
            help_text = _("Some models (Gemini TTS) add silence before and after each clip, heard as pauses between sentences."),
        },
    }
end

return SettingsMenu
