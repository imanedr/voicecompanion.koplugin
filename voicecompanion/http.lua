--[[--
Minimal blocking HTTP(S) POST helper on top of KOReader's LuaSocket/LuaSec.
Meant to run inside a background subprocess (see async.lua).
--]]

local Http = {}

--- POST `body` to `url`.
-- @param opts table { headers = {}, timeout = seconds, sink_path = file path or nil }
--   When `sink_path` is given and the response is 2xx, the body is written
--   there instead of being returned (binary audio).
-- @return number|nil status code, string body (or nil), table headers, string|nil error
function Http.post(url, body, opts)
    opts = opts or {}
    local socket = require("socket")
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local ok_su, socketutil = pcall(require, "socketutil")

    local headers = { ["Content-Length"] = tostring(#body) }
    for k, v in pairs(opts.headers or {}) do headers[k] = v end

    local chunks = {}
    local timeout = opts.timeout or 60
    if ok_su then socketutil:set_timeout(timeout, timeout) end
    local code, resp_headers, status = socket.skip(1, http.request{
        url = url,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(chunks),
    })
    if ok_su then socketutil:reset_timeout() end

    if type(code) ~= "number" then
        return nil, nil, {}, "network error: " .. tostring(code or status)
    end
    local data = table.concat(chunks)
    if opts.sink_path and code >= 200 and code < 300 then
        -- Write then rename, so a process killed mid-write never leaves a
        -- truncated file that later passes for complete audio.
        local part = opts.sink_path .. ".part"
        local f, err = io.open(part, "wb")
        if not f then return code, nil, resp_headers or {}, "cannot write " .. tostring(err) end
        f:write(data)
        f:close()
        local ok, rerr = os.rename(part, opts.sink_path)
        if not ok then
            os.remove(part)
            return code, nil, resp_headers or {}, "cannot write " .. tostring(rerr)
        end
        return code, nil, resp_headers or {}, nil
    end
    return code, data, resp_headers or {}, nil
end

--- Pull a readable message out of an error response body.
function Http.errorMessage(code, body)
    local msg = body or ""
    local ok, JSON = pcall(require, "json")
    if ok and body and body:sub(1, 1) == "{" then
        local okd, decoded = pcall(JSON.decode, body)
        if okd and type(decoded) == "table" then
            local e = decoded.error
            if type(e) == "table" then
                msg = e.message or msg
                -- OpenRouter puts the upstream provider's message here.
                if type(e.metadata) == "table" and type(e.metadata.raw) == "string" then
                    msg = msg .. " (" .. e.metadata.raw:sub(1, 200) .. ")"
                end
            elseif type(e) == "string" then
                msg = e
            end
        end
    end
    msg = tostring(msg):gsub("%s+", " "):sub(1, 300)
    local hints = {
        [401] = "check the API key",
        [402] = "out of credits",
        [404] = "check the model name and base URL",
        [429] = "rate limited, try again shortly",
    }
    local hint = hints[code]
    return string.format("HTTP %s: %s%s", tostring(code), msg, hint and (" — " .. hint) or "")
end

return Http
