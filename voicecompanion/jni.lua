--[[--
Safe JNI helpers for calling Android framework classes from Lua.

Every call is made with the typed `Call*MethodA` variants (arguments are
packed into a `jvalue` array according to the method signature, so ints,
floats and objects are never mis-passed through C varargs), and every call
is followed by an exception check.  A pending Java exception is cleared and
turned into a Lua error, instead of being left pending (which aborts the
process on the next JNI call).

Usage:
    local JNI = require("voicecompanion/jni")
    local ok, result = JNI.run(function(J)
        local tts = J:new("android/speech/tts/TextToSpeech",
            "(Landroid/content/Context;Landroid/speech/tts/TextToSpeech$OnInitListener;)V",
            J:appContext(), nil)
        return J:global(tts)
    end)

Objects that must outlive one `JNI.run` call have to be turned into global
references with `J:global()` and released later with `J:deleteGlobal()`.
--]]

local ffi = require("ffi")
local logger = require("logger")

local JNI = {}

local Helper = {}
Helper.__index = Helper

local function getAndroid()
    local ok, android = pcall(require, "android")
    if ok and type(android) == "table" and android.jni and android.app then
        return android
    end
    return nil
end

--- True when running inside KOReader for Android with JNI access.
function JNI.available()
    return getAndroid() ~= nil
end

--- Split a JNI method signature into parameter type codes and return type.
-- "(Ljava/lang/String;IF)Z" -> {"L","I","F"}, "Z"
function JNI.parseSignature(sig)
    local params, ret = sig:match("^%((.*)%)(.+)$")
    if not params then error("bad JNI signature: " .. tostring(sig)) end
    local types = {}
    local i = 1
    while i <= #params do
        local c = params:sub(i, i)
        if c == "L" then
            local e = params:find(";", i, true)
            table.insert(types, "L")
            i = e + 1
        elseif c == "[" then
            -- Array: skip all dimensions, then the element type.
            while params:sub(i, i) == "[" do i = i + 1 end
            if params:sub(i, i) == "L" then
                i = params:find(";", i, true) + 1
            else
                i = i + 1
            end
            table.insert(types, "L")
        else
            table.insert(types, c)
            i = i + 1
        end
    end
    local r = ret:sub(1, 1)
    if r == "[" then r = "L" end
    return types, r
end

function Helper:_env()
    return self.env[0]
end

--- Raise a Lua error if a Java exception is pending (after clearing it).
function Helper:check(what)
    local env = self.env
    if env[0].ExceptionCheck(env) ~= 0 then
        local message = "?"
        local exc = env[0].ExceptionOccurred(env)
        env[0].ExceptionClear(env)
        if exc ~= nil then
            -- Best effort: exc.toString(); never let this itself throw.
            local okm, msg = pcall(function()
                local clazz = env[0].GetObjectClass(env, exc)
                local mid = env[0].GetMethodID(env, clazz, "toString", "()Ljava/lang/String;")
                local s = mid ~= nil and env[0].CallObjectMethodA(env, exc, mid, nil) or nil
                local text
                if env[0].ExceptionCheck(env) ~= 0 then
                    env[0].ExceptionClear(env)
                elseif s ~= nil then
                    text = self:str(s)
                    env[0].DeleteLocalRef(env, s)
                end
                env[0].DeleteLocalRef(env, clazz)
                return text
            end)
            if okm and msg then message = msg end
            env[0].DeleteLocalRef(env, exc)
        end
        error(string.format("Java exception in %s: %s", what, message), 0)
    end
end

function Helper:_track(obj)
    if obj ~= nil then table.insert(self._locals, obj) end
    return obj
end

--- Convert a Java string to a Lua string (nil for null).
function Helper:str(jstring)
    if jstring == nil then return nil end
    local env = self.env
    local chars = env[0].GetStringUTFChars(env, jstring, nil)
    if chars == nil then return nil end
    local len = env[0].GetStringUTFLength(env, jstring)
    local s = ffi.string(chars, len)
    env[0].ReleaseStringUTFChars(env, jstring, chars)
    return s
end

--- New Java string from a Lua string (tracked local reference).
function Helper:jstring(s)
    local env = self.env
    local js = env[0].NewStringUTF(env, s)
    self:check("NewStringUTF")
    return self:_track(js)
end

function Helper:findClass(name)
    local env = self.env
    local clazz = env[0].FindClass(env, name)
    self:check("FindClass " .. name)
    if clazz == nil then error("class not found: " .. name, 0) end
    return self:_track(clazz)
end

function Helper:_methodID(clazz, name, sig, static)
    local env = self.env
    local mid
    if static then
        mid = env[0].GetStaticMethodID(env, clazz, name, sig)
    else
        mid = env[0].GetMethodID(env, clazz, name, sig)
    end
    self:check("GetMethodID " .. name .. sig)
    if mid == nil then error("method not found: " .. name .. sig, 0) end
    return mid
end

--- Pack Lua arguments into a jvalue array according to the signature.
function Helper:_args(types, ...)
    local n = #types
    if n == 0 then return nil end
    local args = { ... }
    local jv = ffi.new("jvalue[?]", n)
    for i, t in ipairs(types) do
        local v = args[i]
        if t == "L" then
            if type(v) == "string" then
                jv[i - 1].l = self:jstring(v)
            else
                jv[i - 1].l = v  -- cdata object or nil (null)
            end
        elseif t == "Z" then jv[i - 1].z = v and 1 or 0
        elseif t == "I" then jv[i - 1].i = v or 0
        elseif t == "J" then jv[i - 1].j = v or 0
        elseif t == "F" then jv[i - 1].f = v or 0
        elseif t == "D" then jv[i - 1].d = v or 0
        elseif t == "S" then jv[i - 1].s = v or 0
        elseif t == "B" then jv[i - 1].b = v or 0
        elseif t == "C" then jv[i - 1].c = v or 0
        else error("unsupported JNI type " .. t, 0) end
    end
    return jv
end

local CALL = {
    V = "Void", Z = "Boolean", I = "Int", J = "Long", F = "Float",
    D = "Double", L = "Object", S = "Short", B = "Byte", C = "Char",
}

local function convert(self, r, value)
    if r == "Z" then return value ~= 0 end
    if r == "L" then return self:_track(value) end
    if r == "V" then return nil end
    return tonumber(value)
end

--- Call an instance method: J:call(obj, "speak", "(…)I", ...)
function Helper:call(obj, name, sig, ...)
    if obj == nil then error("call " .. name .. " on null object", 0) end
    local env = self.env
    local types, r = JNI.parseSignature(sig)
    local clazz = self:_track(env[0].GetObjectClass(env, obj))
    local mid = self:_methodID(clazz, name, sig, false)
    local jv = self:_args(types, ...)
    local value = env[0]["Call" .. CALL[r] .. "MethodA"](env, obj, mid, jv)
    self:check(name)
    return convert(self, r, value)
end

--- Call a static method: J:callStatic("java/util/Locale", "forLanguageTag", "(…)…", ...)
function Helper:callStatic(class_name, name, sig, ...)
    local env = self.env
    local types, r = JNI.parseSignature(sig)
    local clazz = self:findClass(class_name)
    local mid = self:_methodID(clazz, name, sig, true)
    local jv = self:_args(types, ...)
    local value = env[0]["CallStatic" .. CALL[r] .. "MethodA"](env, clazz, mid, jv)
    self:check(name)
    return convert(self, r, value)
end

--- Construct an object: J:new("android/media/MediaPlayer", "()V")
function Helper:new(class_name, sig, ...)
    local env = self.env
    local types = JNI.parseSignature(sig)
    local clazz = self:findClass(class_name)
    local mid = self:_methodID(clazz, "<init>", sig, false)
    local jv = self:_args(types, ...)
    local obj = env[0].NewObjectA(env, clazz, mid, jv)
    self:check("new " .. class_name)
    if obj == nil then error("could not construct " .. class_name, 0) end
    return self:_track(obj)
end

--- Promote a local reference to a global one (survives across JNI.run).
function Helper:global(obj)
    if obj == nil then return nil end
    local g = self.env[0].NewGlobalRef(self.env, obj)
    self:check("NewGlobalRef")
    return g
end

function Helper:deleteGlobal(ref)
    if ref ~= nil then self.env[0].DeleteGlobalRef(self.env, ref) end
end

--- The KOReader activity object.
function Helper:activity()
    return self.android.app.activity.clazz
end

--- The application context (safe to keep for service bindings).
function Helper:appContext()
    return self:call(self:activity(), "getApplicationContext", "()Landroid/content/Context;")
end

--- Run `fn(J)` with a JNI environment.  Never raises: returns
-- `true, result` on success or `false, error_message` on failure.  Local
-- references created through the helper are released afterwards.
function JNI.run(fn)
    local android = getAndroid()
    if not android then return false, "JNI is not available on this platform" end
    local ok_ctx, ok, result = pcall(function()
        return android.jni:context(android.app.activity.vm, function(jni)
            local J = setmetatable({ env = jni.env, android = android, _locals = {} }, Helper)
            local ok_fn, res = pcall(fn, J)
            -- Never leave an exception pending, whatever happened.
            if jni.env[0].ExceptionCheck(jni.env) ~= 0 then
                jni.env[0].ExceptionClear(jni.env)
            end
            for i = #J._locals, 1, -1 do
                jni.env[0].DeleteLocalRef(jni.env, J._locals[i])
            end
            return ok_fn, res
        end)
    end)
    if not ok_ctx then
        logger.warn("VoiceCompanion JNI: context failed:", ok)
        return false, tostring(ok)
    end
    if not ok then
        logger.warn("VoiceCompanion JNI:", result)
    end
    return ok, result
end

return JNI
