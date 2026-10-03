std = "luajit"
max_line_length = false

-- Provided by KOReader at runtime.
read_globals = { "G_reader_settings", "G_defaults" }

-- Unused `self`, and unused arguments/variables starting with `_`.
ignore = { "212/self", "21./_.*" }

exclude_files = { "spec/json.lua", "spec/tmp/**", "dist/**" }

-- The test runner defines these for the specs.
files["spec"] = {
    globals = { "describe", "it", "before_each", "assert_eq", "assert_true", "assert_nil", "assert_match" },
}
