--[[--
Run blocking work (network requests) in a forked subprocess so the UI keeps
responding, and poll for the result from the UI loop.

The child returns `ok, payload` (payload is a string).  It is passed back
through a small result file rather than a pipe, so a large payload can never
block the child on a full pipe buffer.  The child must not touch the UI,
JNI or any device driver: only files and sockets.

If forking is not possible, the work runs synchronously instead (the UI
freezes for the duration, but the feature still works).
--]]

local UIManager = require("ui/uimanager")
local logger = require("logger")

local Async = {
    POLL_INTERVAL = 0.15,
    -- Set to true (e.g. from Diagnostics) to force the synchronous path.
    force_sync = false,
}

local counter = 0

local function tempDir()
    local DataStorage = require("datastorage")
    local dir = DataStorage:getDataDir() .. "/cache/voicecompanion"
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(DataStorage:getDataDir() .. "/cache")
        lfs.mkdir(dir)
    end
    return dir
end
Async.tempDir = tempDir

local function writeResult(path, ok, payload)
    local f = io.open(path, "wb")
    if not f then return end
    f:write(ok and "1" or "0", "\n", payload or "")
    f:close()
end

local function readResult(path)
    local f = io.open(path, "rb")
    if not f then return false, "background request produced no result" end
    local data = f:read("*a") or ""
    f:close()
    os.remove(path)
    local flag, payload = data:match("^([01])\n(.*)$")
    if not flag then return false, "background request result was malformed" end
    return flag == "1", payload
end

--- Run `work()` in the background; `on_done(ok, payload)` is called on the
-- UI thread.  `work` must return `ok (boolean), payload (string)`.
-- @param opts table|nil  { timeout = seconds }
-- @return table handle with :cancel()
function Async.run(work, on_done, opts)
    opts = opts or {}
    local timeout = opts.timeout or 60
    counter = counter + 1
    local result_path = string.format("%s/result_%d_%d", tempDir(), os.time(), counter)
    local handle = { cancelled = false }

    local function finish(ok, payload)
        if handle.cancelled or handle.finished then return end
        handle.finished = true
        if on_done then
            local cb_ok, err = pcall(on_done, ok, payload)
            if not cb_ok then logger.err("VoiceCompanion: async callback failed:", err) end
        end
    end

    local function runInline()
        local ok, a, b = pcall(work)
        if not ok then
            UIManager:scheduleIn(0, function() finish(false, tostring(a)) end)
        else
            UIManager:scheduleIn(0, function() finish(a and true or false, b) end)
        end
    end

    local ffiutil = require("ffi/util")
    local pid
    if not Async.force_sync then
        pid = ffiutil.runInSubProcess(function()
            local ok, a, b = pcall(work)
            if ok then
                writeResult(result_path, a, b)
            else
                writeResult(result_path, false, tostring(a))
            end
        end)
    end
    if not pid then
        if not Async.force_sync then
            logger.warn("VoiceCompanion: fork failed, running request synchronously")
        end
        runInline()
        function handle.cancel() handle.cancelled = true end
        return handle
    end

    -- After a cancel or timeout: keep collecting the child so it doesn't
    -- linger as a zombie, then drop whatever it wrote.
    local function reap()
        if ffiutil.isSubProcessDone(pid) then
            os.remove(result_path)
        else
            UIManager:scheduleIn(Async.POLL_INTERVAL, reap)
        end
    end

    local started = os.time()
    local function poll()
        if handle.cancelled then return reap() end
        if ffiutil.isSubProcessDone(pid) then
            finish(readResult(result_path))
            return
        end
        if os.time() - started > timeout then
            ffiutil.terminateSubProcess(pid)
            finish(false, "request timed out")
            return reap()
        end
        UIManager:scheduleIn(Async.POLL_INTERVAL, poll)
    end
    UIManager:scheduleIn(Async.POLL_INTERVAL, poll)

    function handle.cancel()
        if handle.finished or handle.cancelled then return end
        handle.cancelled = true
        ffiutil.terminateSubProcess(pid)
    end
    return handle
end

return Async
