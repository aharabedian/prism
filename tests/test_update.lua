-- test_update.lua: prism-update installs from GitHub, keeps prism.cfg, refuses broken downloads.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check

local prefix = H.TMP .. "/root"
os.execute('mkdir -p "' .. prefix .. '/home"')

-- route PRISM_PREFIX to the temp dir, and turn os.exit into a catchable error
local realGetenv, realExit = os.getenv, os.exit
os.getenv = function(k) if k == "PRISM_PREFIX" then return prefix end return realGetenv(k) end
os.exit = function(code) error({ exit = code }) end
local errors = {}
io.stderr = { write = function(_, s) errors[#errors + 1] = s end }

local function serve(repo, branch)
  M.web = {}
  local base = ("https://raw.githubusercontent.com/%s/%s/"):format(repo, branch)
  for _, f in ipairs({ "src/prism.lua", "src/prism-control.lua", "src/prism-discover.lua", "src/prism-update.lua", "config/prism.example.cfg" }) do
    local h = assert(io.open(H.ROOT .. "/" .. f))
    M.web[base .. f] = h:read("*a")
    h:close()
  end
  return base
end
local function read(path) local h = io.open(path); if not h then return nil end; local s = h:read("*a"); h:close(); return s end
local function update(...)
  errors = {}
  local ok, err = pcall(H.run, "prism-update.lua", ...)
  return ok, (type(err) == "table" and err.exit) or err
end
local function quiet(fn) local p = print; print = function() end; local a, b = fn(); print = p; return a, b end

-- no internet card
local ok, code = quiet(function() return update("me/prism") end)
check(not ok and code == 1 and table.concat(errors):find("Internet Card"), "refuses to run without an Internet Card")
M.proxies["in000000"] = { address = "in000000", type = "internet" }

-- no repo given and none saved
ok = quiet(function() return update() end)
check(not ok and table.concat(errors):find("usage"), "asks for OWNER/REPO the first time")

-- fresh install
serve("me/prism", "main")
ok = quiet(function() return update("me/prism") end)
check(ok, "fresh install succeeds")
for _, f in ipairs({ "router", "control", "discover", "prism-update" }) do
  check(read(prefix .. "/home/bin/" .. f .. ".lua") == read(H.ROOT .. "/src/" .. f .. ".lua"), f .. ".lua installed into /home/bin")
end
check(read(prefix .. "/home/prism.cfg") == read(H.ROOT .. "/config/prism.example.cfg"), "prism.cfg created from the example")
local saved = H.readTable(prefix .. "/home/.prism-update.cfg")
check(saved.repo == "me/prism" and saved.branch == "main", "repo and branch saved")

-- update keeps the user's config, uses the saved repo
local h = io.open(prefix .. "/home/prism.cfg", "w"); h:write("return { interval = 9 }"); h:close()
ok = quiet(function() return update() end)
check(ok and read(prefix .. "/home/prism.cfg") == "return { interval = 9 }", "update keeps the user's prism.cfg")

-- a broken download (404 page / wrong branch) leaves the installed files alone
local base = serve("me/prism", "dev")
M.web[base .. "src/prism-control.lua"] = "<html>404: Not Found</html>"
local before = read(prefix .. "/home/bin/prism.lua")
ok = quiet(function() return update("me/prism", "dev") end)
check(not ok and table.concat(errors):find("valid Lua"), "rejects a download that isn't Lua")
check(read(prefix .. "/home/bin/prism.lua") == before, "nothing replaced when any download is bad")
serve("me/prism", "dev")
M.web[base .. "src/prism-discover.lua"] = nil
ok = quiet(function() return update("me/prism", "dev") end)
check(not ok and table.concat(errors):find("can't download src/prism-discover.lua", 1, true), "missing file reported")
check(H.readTable(prefix .. "/home/.prism-update.cfg").branch == "main", "failed update doesn't change saved settings")

-- a computer still set up under the old router*.cfg names gets its files carried over
prefix = H.TMP .. "/legacy"
os.execute('mkdir -p "' .. prefix .. '/home"')
local function put(path, text) local f = io.open(prefix .. "/home/" .. path, "w"); f:write(text); f:close() end
put("router.cfg", "return { interval = 7 }")
put("router-items.cfg", "{}")
put("router-overrides.cfg", "{x=1}")
serve("me/prism", "main")
ok = quiet(function() return update("me/prism") end)
check(ok, "install over an old router setup succeeds")
check(read(prefix .. "/home/prism.cfg") == "return { interval = 7 }", "old router.cfg becomes prism.cfg (not the example)")
check(read(prefix .. "/home/prism-overrides.cfg") == "{x=1}" and read(prefix .. "/home/prism-items.cfg") == "{}",
  "old data files renamed to prism-*.cfg")
check(read(prefix .. "/home/router.cfg") == nil, "old router.cfg is gone after the move")

os.getenv, os.exit = realGetenv, realExit
H.done()
