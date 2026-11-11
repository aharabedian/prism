--[[ tests/run.lua - run every tests/test_*.lua in its own Lua process

  lua5.3 tests/run.lua              run everything
  lua5.3 tests/run.lua feeders      only files whose name contains "feeders"
  lua5.3 tests/run.lua -v           show every check, not just failures

  Each test runs in a fresh interpreter, so mock state never leaks between files.
  Exit status is non-zero if anything failed (CI relies on this).
]]

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or "."
local lua = arg[-1] or "lua"
local verbose, filter = false, nil
for _, a in ipairs(arg) do
  if a == "-v" then verbose = true else filter = a end
end

local files = {}
local p = io.popen('ls "' .. here .. '"/test_*.lua 2>/dev/null')
for line in p:lines() do
  if not filter or line:find(filter, 1, true) then files[#files + 1] = line end
end
p:close()
table.sort(files)
if #files == 0 then print("no test files found"); os.exit(1) end

local failed = {}
for _, file in ipairs(files) do
  local name = file:match("([^/\\]+)%.lua$")
  local out = io.popen(('"%s" "%s" 2>&1'):format(lua, file))
  local text = out:read("*a")
  local ok = out:close()
  local summary = text:match("PASS [^\n]+")
  if ok and summary then
    print(summary)
    if verbose then io.write(text) end
  else
    failed[#failed + 1] = name
    print("FAIL " .. name)
    io.write(text, "\n")
  end
end

print(("%d/%d test files passed"):format(#files - #failed, #files))
os.exit(#failed == 0 and 0 or 1)
