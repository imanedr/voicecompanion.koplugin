-- package.preload stubs for the KOReader modules the plugin requires.
-- Installed by spec/run.lua before any plugin module is loaded.

local Stubs = {}

Stubs.TMP = "spec/tmp"

local function shellQuote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

--- Wipe and recreate spec/tmp.
function Stubs.cleanTmp()
    os.execute("rm -rf " .. Stubs.TMP .. " && mkdir -p " .. Stubs.TMP)
end

local function preload(name, fn) package.preload[name] = fn end

-- ── logger / gettext ────────────────────────────────────────────────
preload("logger", function()
    local noop = function() end
    return { dbg = noop, info = noop, warn = noop, err = noop }
end)

preload("gettext", function()
    local G = {}
    G.ngettext = function(s, p, n) return n == 1 and s or p end
    G.pgettext = function(_, s) return s end
    return setmetatable(G, { __call = function(_, s) return s end })
end)

-- ── ffi/util ────────────────────────────────────────────────────────
preload("ffi/util", function()
    return {
        template = function(str, ...)
            local args = { ... }
            return (str:gsub("%%([1-9])", function(i) return tostring(args[tonumber(i)]) end))
        end,
        runInSubProcess = function(fn)
            fn()
            return 4242
        end,
        isSubProcessDone = function() return true end,
        terminateSubProcess = function() end,
    }
end)

-- ── ui/uimanager ────────────────────────────────────────────────────
preload("ui/uimanager", function()
    local UIManager = { queue = {}, calls = {} }
    local function record(name, ...)
        table.insert(UIManager.calls, { name = name, args = { ... } })
    end
    function UIManager:scheduleIn(_, f) table.insert(self.queue, f) end
    function UIManager:nextTick(f) table.insert(self.queue, f) end
    function UIManager:show(...) record("show", ...) end
    function UIManager:close(...) record("close", ...) end
    function UIManager:setDirty(...) record("setDirty", ...) end
    function UIManager:unschedule() end
    --- Run queued callbacks until the queue is empty.
    function UIManager._drain()
        local n = 0
        while #UIManager.queue > 0 do
            n = n + 1
            if n > 10000 then error("UIManager._drain: queue never emptied") end
            table.remove(UIManager.queue, 1)()
        end
    end
    function UIManager._reset() UIManager.queue, UIManager.calls = {}, {} end
    return UIManager
end)

preload("ui/event", function()
    return { new = function(_, name, ...) return { name = name, args = { ... } } end }
end)

preload("ui/widget/infomessage", function()
    return { new = function(self, o) return o or self end }
end)

-- ── device ──────────────────────────────────────────────────────────
preload("device", function()
    local Device = { android = false, screen = { getHeight = function() return 800 end } }
    function Device:isAndroid() return self.android end
    return Device
end)

-- ── datastorage / lfs ───────────────────────────────────────────────
preload("datastorage", function()
    return { getDataDir = function() return Stubs.TMP .. "/data" end }
end)

preload("libs/libkoreader-lfs", function()
    local lfs = {}
    function lfs.attributes(path, field)
        local f = io.open(path, "rb")
        if not f then return nil end
        local _, _, code = f:read(0)
        local attr
        if code == 21 then -- EISDIR
            attr = { mode = "directory", size = 0 }
        else
            attr = { mode = "file", size = f:seek("end") or 0 }
        end
        f:close()
        attr.access, attr.modification = 0, 0
        if field then return attr[field] end
        return attr
    end
    function lfs.mkdir(path)
        os.execute("mkdir -p " .. shellQuote(path))
        return true
    end
    function lfs.dir(path)
        local p = io.popen("ls -a " .. shellQuote(path) .. " 2>/dev/null")
        local names = {}
        if p then
            for line in p:lines() do table.insert(names, line) end
            p:close()
        end
        local i = 0
        return function() i = i + 1 return names[i] end
    end
    return lfs
end)

-- ── json ────────────────────────────────────────────────────────────
preload("json", function() return require("spec/json") end)

-- ── network: socket, socket.http, ltn12, socketutil ─────────────────
-- Tests set Stubs.http.handler = function(req) return code, body, headers end.
Stubs.http = { requests = {} }
function Stubs.http.reset()
    Stubs.http.requests = {}
    Stubs.http.handler = function() return 200, "" end
end
Stubs.http.reset()

preload("socket", function()
    return { skip = function(n, ...) return select(n + 1, ...) end }
end)

preload("ltn12", function()
    return {
        source = { string = function(s) return s end },
        sink = { table = function(t) return t end },
    }
end)

preload("socket.http", function()
    return {
        request = function(req)
            local record = { url = req.url, method = req.method, headers = req.headers, body = req.source }
            table.insert(Stubs.http.requests, record)
            local code, body, headers = Stubs.http.handler(record)
            if type(code) ~= "number" then return nil, code end
            if body and req.sink then table.insert(req.sink, body) end
            return 1, code, headers or {}, "status"
        end,
    }
end)

preload("socketutil", function()
    return { set_timeout = function() end, reset_timeout = function() end }
end)

return Stubs
