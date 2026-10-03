-- Tiny pure-Lua JSON encoder/decoder used only by the test stubs.
local M = {}

local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function encodeString(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return ESC[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function isArray(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    if n == 0 then return false end
    for i = 1, n do if t[i] == nil then return false end end
    return true
end

local function encode(v)
    local t = type(v)
    if t == "string" then return encodeString(v) end
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then error("cannot encode number " .. tostring(v)) end
        return string.format("%.14g", v)
    end
    if t == "boolean" then return tostring(v) end
    if t == "nil" then return "null" end
    if t ~= "table" then error("cannot encode " .. t) end
    local out = {}
    if isArray(v) then
        for i = 1, #v do out[i] = encode(v[i]) end
        return "[" .. table.concat(out, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local val = v[k]
        if val == nil then val = v[tonumber(k)] end
        out[#out + 1] = encodeString(k) .. ":" .. encode(val)
    end
    return "{" .. table.concat(out, ",") .. "}"
end
M.encode = encode

local function utf8char(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
    if cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
    end
    return string.char(0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64,
        0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

function M.decode(s)
    local pos = 1
    local function fail(msg) error(string.format("JSON error at %d: %s", pos, msg), 0) end
    local function skip() pos = s:find("[^ \t\r\n]", pos) or #s + 1 end
    local value

    local function str()
        pos = pos + 1
        local buf = {}
        while true do
            local c = s:sub(pos, pos)
            if c == "" then fail("unterminated string") end
            if c == '"' then pos = pos + 1 break end
            if c == "\\" then
                local e = s:sub(pos + 1, pos + 1)
                local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
                if e == "u" then
                    local cp = tonumber(s:sub(pos + 2, pos + 5), 16)
                    if not cp then fail("bad \\u escape") end
                    pos = pos + 6
                    if cp >= 0xD800 and cp < 0xDC00 and s:sub(pos, pos + 1) == "\\u" then
                        local lo = tonumber(s:sub(pos + 2, pos + 5), 16)
                        if lo and lo >= 0xDC00 and lo < 0xE000 then
                            cp = 0x10000 + (cp - 0xD800) * 1024 + (lo - 0xDC00)
                            pos = pos + 6
                        end
                    end
                    buf[#buf + 1] = utf8char(cp)
                elseif map[e] then
                    buf[#buf + 1] = map[e]
                    pos = pos + 2
                else
                    fail("bad escape")
                end
            else
                buf[#buf + 1] = c
                pos = pos + 1
            end
        end
        return table.concat(buf)
    end

    function value()
        skip()
        local c = s:sub(pos, pos)
        if c == "{" then
            local obj = {}
            pos = pos + 1
            skip()
            if s:sub(pos, pos) == "}" then pos = pos + 1 return obj end
            while true do
                skip()
                if s:sub(pos, pos) ~= '"' then fail("expected string key") end
                local k = str()
                skip()
                if s:sub(pos, pos) ~= ":" then fail("expected ':'") end
                pos = pos + 1
                obj[k] = value()
                skip()
                local d = s:sub(pos, pos)
                pos = pos + 1
                if d == "}" then return obj end
                if d ~= "," then fail("expected ',' or '}'") end
            end
        elseif c == "[" then
            local arr, n = {}, 0
            pos = pos + 1
            skip()
            if s:sub(pos, pos) == "]" then pos = pos + 1 return arr end
            while true do
                n = n + 1
                arr[n] = value()
                skip()
                local d = s:sub(pos, pos)
                pos = pos + 1
                if d == "]" then return arr end
                if d ~= "," then fail("expected ',' or ']'") end
            end
        elseif c == '"' then
            return str()
        elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4 return true
        elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5 return false
        elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4 return nil
        else
            local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
            if not num or num == "" then fail("unexpected character " .. c) end
            pos = pos + #num
            return tonumber(num)
        end
    end

    local result = value()
    skip()
    if pos <= #s then fail("trailing data") end
    return result
end

return M
