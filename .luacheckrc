-- luacheck config. Run: luacheck .
-- OpenComputers runs Lua 5.2/5.3; programs must not rely on 5.4-only features.
std = "lua53"
max_line_length = 140
codes = true

files["src/"] = {
  -- OpenOS globals that aren't in plain Lua
  read_globals = { "os.sleep" },
}
files["lib/"] = {
  -- OpenOS globals that aren't in plain Lua
  read_globals = { "os.sleep" },
}

files["tests/"] = {
  -- tests deliberately swap these to capture output / trap exits
  globals = { "print", "io.write", "io.read", "io.stderr", "os.getenv", "os.exit" },
  max_line_length = 160,
}

exclude_files = { ".luarocks/**", "lua_modules/**", ".venv/**", "build/**" }
