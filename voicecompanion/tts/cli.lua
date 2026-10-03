--[[--
Local text-to-speech on Linux through a command-line engine that writes a
WAV file: espeak-ng, espeak, piper, or a user-supplied command template.
`synthesize` is blocking and runs inside async.lua's subprocess.
--]]

local CliTts = {}

local function shellQuote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function commandExists(bin)
    local rc = os.execute("command -v " .. bin .. " >/dev/null 2>&1")
    return rc == 0 or rc == true
end

--- Command template for the configured or detected engine, or nil.
-- Placeholders: {text_file} {out} {lang} {rate_wpm}
function CliTts.template(local_cfg)
    if local_cfg and local_cfg.command and local_cfg.command ~= "" then
        return local_cfg.command
    end
    if commandExists("espeak-ng") then
        return "espeak-ng -v {lang} -s {rate_wpm} -f {text_file} -w {out}"
    end
    if commandExists("espeak") then
        return "espeak -v {lang} -s {rate_wpm} -f {text_file} -w {out}"
    end
    return nil
end

function CliTts.isAvailable(local_cfg)
    return CliTts.template(local_cfg) ~= nil
end

--- Build the shell command (exposed for tests).
function CliTts.buildCommand(template, text_file, out, lang, rate)
    local espeak_lang = (lang or "en-US"):lower()
    local subs = {
        text_file = shellQuote(text_file),
        out = shellQuote(out),
        lang = shellQuote(espeak_lang),
        rate_wpm = tostring(math.floor(175 * (rate or 1.0) + 0.5)),
    }
    return (template:gsub("{([%w_]+)}", function(k) return subs[k] or ("{" .. k .. "}") end))
end

--- Synthesize `text` into the WAV file `out`.
-- @return boolean ok, string error_or_out
function CliTts.synthesize(local_cfg, text, out, rate)
    local template = CliTts.template(local_cfg)
    if not template then return false, "no local TTS engine found (install espeak-ng)" end
    local text_file = out .. ".txt"
    local f = io.open(text_file, "w")
    if not f then return false, "cannot write temporary text file" end
    f:write(text)
    f:close()
    local cmd = CliTts.buildCommand(template, text_file, out, local_cfg.language, rate or local_cfg.rate)
    local rc = os.execute(cmd .. " >/dev/null 2>&1")
    os.remove(text_file)
    local wf = io.open(out, "rb")
    local size = wf and wf:seek("end") or 0
    if wf then wf:close() end
    if size <= 44 then
        return false, "local TTS command failed (exit " .. tostring(rc) .. "): " .. cmd
    end
    return true, out
end

return CliTts
