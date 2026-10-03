-- Minimal test runner.  Usage (from the repo root): luajit spec/run.lua
package.path = "./?.lua;" .. package.path

local Stubs = require("spec/stubs")
Stubs.cleanTmp()

local passed, failed = 0, 0
local failures = {}
local stack = {}   -- describe names
local hooks = {}   -- stack of before_each lists

function describe(name, fn)
    table.insert(stack, name)
    table.insert(hooks, {})
    local ok, err = pcall(fn)
    if not ok then
        failed = failed + 1
        table.insert(failures, table.concat(stack, " > ") .. ": " .. tostring(err))
        print("FAIL " .. table.concat(stack, " > ") .. " (describe block raised)\n     " .. tostring(err))
    end
    table.remove(hooks)
    table.remove(stack)
end

function before_each(fn) table.insert(hooks[#hooks], fn) end

function it(name, fn)
    local full = table.concat(stack, " > ") .. " > " .. name
    local ok, err = pcall(function()
        for _, list in ipairs(hooks) do
            for _, h in ipairs(list) do h() end
        end
        fn()
    end)
    if ok then
        passed = passed + 1
        print("ok   " .. full)
    else
        failed = failed + 1
        table.insert(failures, full)
        print("FAIL " .. full .. "\n     " .. tostring(err))
    end
end

local function show(v)
    if type(v) == "string" then return string.format("%q", v) end
    if type(v) == "table" then
        local parts = {}
        for i, x in ipairs(v) do parts[i] = show(x) end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return tostring(v)
end

local function equal(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    for k, v in pairs(a) do if not equal(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

function assert_eq(actual, expected, msg)
    if not equal(actual, expected) then
        error(string.format("%sexpected %s, got %s", msg and (msg .. ": ") or "", show(expected), show(actual)), 2)
    end
end

function assert_true(v, msg)
    if not v then error(msg or ("expected truthy, got " .. show(v)), 2) end
end

function assert_nil(v, msg)
    if v ~= nil then error((msg and (msg .. ": ") or "") .. "expected nil, got " .. show(v), 2) end
end

function assert_match(str, pattern, msg)
    if type(str) ~= "string" or not str:find(pattern) then
        error(string.format("%s%s does not match %q", msg and (msg .. ": ") or "", show(str), pattern), 2)
    end
end

local p = io.popen("ls spec/*_spec.lua 2>/dev/null")
local files = {}
for line in p:lines() do table.insert(files, line) end
p:close()
table.sort(files)

for _, file in ipairs(files) do
    print("# " .. file)
    local ok, err = pcall(dofile, file)
    if not ok then
        failed = failed + 1
        table.insert(failures, file)
        print("FAIL " .. file .. " (load error)\n     " .. tostring(err))
    end
end

Stubs.cleanTmp()
print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
