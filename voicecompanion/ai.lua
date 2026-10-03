--[[--
Ask the configured chat model, in the background, with a cancellable
"Thinking…" message.
--]]

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Async = require("voicecompanion/async")
local Config = require("voicecompanion/config")
local Provider = require("voicecompanion/provider")
local _ = require("gettext")

local AI = {}

--- on_done(ok, answer_or_error).  Shows a "Thinking…" message that cancels
-- the request when dismissed.
function AI.ask(messages, on_done, opts)
    opts = opts or {}
    local cfg, cfg_err = Config.load()
    if cfg_err then return on_done(false, "configuration.lua has an error: " .. cfg_err) end
    local p, perr = Config.activeProvider(cfg)
    if not p then return on_done(false, perr) end
    if Config.isKeyMissing(p.api_key) then
        return on_done(false, string.format("No API key for provider %q. Add it in configuration.lua or Settings.", p.name))
    end
    if not p.chat_model or p.chat_model == "" then
        return on_done(false, string.format("No chat_model set for provider %q.", p.name))
    end

    local handle
    local waiting = InfoMessage:new{
        text = opts.waiting_text or _("Thinking…"),
        dismiss_callback = function()
            if handle and not handle.finished then handle.cancel() end
        end,
    }
    UIManager:show(waiting)
    local chat_opts = { max_tokens = opts.max_tokens, temperature = opts.temperature }
    handle = Async.run(function()
        return Provider.chat(p, messages, chat_opts)
    end, function(ok, answer)
        -- Close the message without triggering its cancel callback.
        waiting.dismiss_callback = nil
        UIManager:close(waiting)
        on_done(ok, answer)
    end, { timeout = cfg.timeout })
    return handle
end

return AI
