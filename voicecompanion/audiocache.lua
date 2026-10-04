--[[--
On-disk cache of synthesized audio, keyed by everything that affects the
sound (provider, model, voice, speed, format, text), so replaying a word or
sentence never costs a second API call.
--]]

local AudioCache = {}

local function hash(s)
    local ok, sha2 = pcall(require, "ffi/sha2")
    if ok and sha2 and sha2.md5 then return sha2.md5(s) end
    -- Fallback (tests / unusual builds): two independent 32-bit string hashes.
    local h1, h2 = 5381, 0
    for i = 1, #s do
        local c = s:byte(i)
        h1 = (h1 * 33 + c) % 4294967296
        h2 = (h2 * 65599 + c) % 4294967296
    end
    return string.format("%08x%08x%d", h1, h2, #s)
end
AudioCache.hash = hash

function AudioCache.dir()
    local Async = require("voicecompanion/async")
    local lfs = require("libs/libkoreader-lfs")
    local dir = Async.tempDir() .. "/audio"
    if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
    return dir
end

--- Cache path for the given parts (does not check existence).
function AudioCache.path(parts, ext)
    local key = table.concat({
        parts.provider or "", parts.model or "", parts.voice or "",
        string.format("%.2f", parts.speed or 1), parts.format or "", parts.text or "",
    }, "\31")
    -- Anything else that changes the sound (sample rate, extra request
    -- fields, post-processing).  Left out when empty so older keys still hit.
    if parts.extra and parts.extra ~= "" then key = key .. "\31" .. parts.extra end
    return string.format("%s/%s.%s", AudioCache.dir(), hash(key), ext or "mp3")
end

function AudioCache.has(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local size = f:seek("end")
    f:close()
    return size and size > 44
end

--- Delete the oldest files until the cache is under `max_mb`.
function AudioCache.trim(max_mb)
    local lfs = require("libs/libkoreader-lfs")
    local dir = AudioCache.dir()
    local files, total = {}, 0
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then
            local path = dir .. "/" .. name
            local attr = lfs.attributes(path)
            if attr and attr.mode == "file" then
                table.insert(files, { path = path, size = attr.size, time = attr.access or attr.modification })
                total = total + attr.size
            end
        end
    end
    local limit = (max_mb or 50) * 1024 * 1024
    if total <= limit then return 0 end
    table.sort(files, function(a, b) return a.time < b.time end)
    local removed = 0
    for _, f in ipairs(files) do
        if total <= limit then break end
        os.remove(f.path)
        total = total - f.size
        removed = removed + 1
    end
    return removed
end

return AudioCache
