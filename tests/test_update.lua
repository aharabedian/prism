-- test_update.lua: prism-update installs what manifest.lua lists from the latest release of aharabedian/prism
-- by default (or the single-file programs of a release made before it), can follow a branch, a tag or a fork,
-- falls back to main when a repo has no releases, keeps prism.cfg, refuses broken downloads and manifests,
-- and migrates old settings and router*.cfg files.
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

local SOURCES = { "manifest.lua" }
for _, f in ipairs(dofile(H.ROOT .. "/manifest.lua")) do SOURCES[#SOURCES + 1] = f[1] end
local LEGACY = { "src/prism.lua", "src/prism-control.lua", "src/prism-discover.lua", "src/prism-setup.lua",
                 "src/prism-update.lua", "config/prism.example.cfg" }
local function read(path) local h = io.open(path); if not h then return nil end; local s = h:read("*a"); h:close(); return s end

-- Serve the repo's files at repo@ref. `version` goes into lib/prism/version.lua, to tell refs apart.
local function serve(repo, ref, version)
  local base = ("https://raw.githubusercontent.com/%s/%s/"):format(repo, ref)
  for _, f in ipairs(SOURCES) do
    local text = read(H.ROOT .. "/" .. f)
    if version and f == "lib/prism/version.lua" then text = text:gsub('return "[^"]*"', 'return "' .. version .. '"') end
    M.web[base .. f] = text
  end
  return base
end

-- Serve a release from before manifest.lua: single-file programs, VERSION in prism.lua.
local function serveLegacy(repo, ref, version)
  local base = ("https://raw.githubusercontent.com/%s/%s/"):format(repo, ref)
  M.web[base .. "manifest.lua"] = nil
  for _, f in ipairs(LEGACY) do M.web[base .. f] = read(H.ROOT .. "/" .. f) end
  M.web[base .. "src/prism.lua"] = ('local VERSION = "%s"\nprint("old router")\n'):format(version)
  return base
end
local function api(repo) return ("https://api.github.com/repos/%s/releases/latest"):format(repo) end
local function release(repo, tag)
  M.web[api(repo)] = ('{"url":"x","tag_name":"%s","name":"PRISM %s","prerelease":false}'):format(tag, tag)
end

local out
local function update(...)
  errors, M.requests = {}, {}
  local lines, realPrint = {}, print
  print = function(...) local p = {}; for i = 1, select("#", ...) do p[i] = tostring((select(i, ...))) end; lines[#lines + 1] = table.concat(p, "\t") end
  local ok, err = pcall(H.run, "prism-update.lua", ...)
  print = realPrint
  out = table.concat(lines, "\n") .. table.concat(errors)
  return ok, (type(err) == "table" and err.exit) or err
end
local function has(s) return out:find(s, 1, true) ~= nil end
local function installedVersion()
  return (read(prefix .. "/home/bin/prism.lua") or ""):match('local VERSION = "([^"]*)"')
      or (read(prefix .. "/home/lib/prism/version.lua") or ""):match('return "([^"]*)"')
end
local function saved() return H.readTable(prefix .. "/home/.prism-update.cfg") or {} end
local function fetched(ref)
  for _, r in ipairs(M.requests) do if r.url:find("/" .. ref .. "/src/", 1, true) then return true end end
  return false
end

-- no internet card
local ok, code = update()
check(not ok and code == 1 and has("Internet Card"), "refuses to run without an Internet Card")
M.proxies["in000000"] = { address = "in000000", type = "internet" }

---------------------------------------------------------------- default: aharabedian/prism, latest release
M.web = {}
release("aharabedian/prism", "v0.5.0")
serve("aharabedian/prism", "v0.5.0", "0.5.0")
ok = update()
check(ok, "first run with no arguments succeeds")
check(has("aharabedian/prism") and has("latest release v0.5.0"), "defaults to aharabedian/prism and says which release")
check(installedVersion() == "0.5.0", "installs the latest release's files")
for _, f in ipairs({ "prism", "prism-control", "prism-discover", "prism-setup", "prism-update" }) do
  check(read(prefix .. "/home/bin/" .. f .. ".lua") ~= nil, f .. ".lua installed into /home/bin")
end
check(read(prefix .. "/home/lib/prism/router/core.lua") ~= nil and read(prefix .. "/home/lib/prism/version.lua") ~= nil,
  "modules installed into /home/lib/prism, as manifest.lua lists them")
check(read(prefix .. "/home/manifest.lua") == nil and read(prefix .. "/home/prism.example.cfg") ~= nil,
  "the manifest itself isn't installed; the example config is")
local ua = M.requests[1].headers and M.requests[1].headers["User-Agent"]
check(M.requests[1].url == api("aharabedian/prism") and ua == "prism-update", "asks the GitHub API with a generic User-Agent")
check(has("PRISM 0.5.0"), "reports the version it installed")
check(read(prefix .. "/home/prism.cfg") == nil and has("run prism-setup"), "no prism.cfg made up; points to prism-setup")
check(saved().repo == "aharabedian/prism" and saved().ref == "latest", "saves: follow the latest release")

-- a new release comes out: a plain prism-update picks it up, keeping the user's config
local h = io.open(prefix .. "/home/prism.cfg", "w"); h:write("return { interval = 9 }"); h:close()
release("aharabedian/prism", "v0.6.0")
serve("aharabedian/prism", "v0.6.0", "0.6.0")
ok = update()
check(ok and installedVersion() == "0.6.0" and has("latest release v0.6.0"), "follows new releases")
check(read(prefix .. "/home/prism.cfg") == "return { interval = 9 }", "update keeps the user's prism.cfg")

---------------------------------------------------------------- branches and tags on the same repo
serve("aharabedian/prism", "main", "0.7.0-dev")
ok = update("main")
check(ok and installedVersion() == "0.7.0-dev" and saved().ref == "main", "prism-update main switches to the main branch")
check(M.requests[1].url ~= api("aharabedian/prism"), "a branch doesn't ask for releases")
ok = update()
check(ok and fetched("main") and saved().ref == "main", "stays on main until told otherwise")
serveLegacy("aharabedian/prism", "v0.5.0", "0.5.0")
ok = update("v0.5.0")
check(ok and installedVersion() == "0.5.0" and saved().ref == "v0.5.0", "a tag pins that release")
check(has("PRISM 0.5.0") and read(prefix .. "/home/bin/prism.lua"):find("old router", 1, true),
  "a release from before manifest.lua installs its single-file programs")
ok = update("latest")
check(ok and installedVersion() == "0.6.0" and saved().ref == "latest", "prism-update latest goes back to releases")

---------------------------------------------------------------- forks
serve("me/prism", "main", "0.6.0-fork")
ok = update("me/prism")
check(ok and installedVersion() == "0.6.0-fork", "a fork without releases installs from main")
check(has("no releases") and has("main"), "says it fell back to main")
check(saved().repo == "me/prism" and saved().ref == "latest", "keeps following the fork's releases once it has some")
release("me/prism", "v1.0.0")
serve("me/prism", "v1.0.0", "1.0.0-fork")
ok = update()
check(ok and installedVersion() == "1.0.0-fork", "the fork's first release is picked up")
serve("me/prism", "dev", "dev")
ok = update("me/prism", "dev")
check(ok and installedVersion() == "dev" and saved().ref == "dev", "OWNER/REPO BRANCH")

---------------------------------------------------------------- failures change nothing
local before, settingsBefore = read(prefix .. "/home/bin/prism.lua"), read(prefix .. "/home/.prism-update.cfg")
M.web[api("aharabedian/prism")] = { status = 403 }          -- rate limited
ok = update("aharabedian/prism")
check(not ok and has("can't find the latest release") and has("HTTP 403") and has("prism-update main"),
  "a failed release lookup stops and suggests main")
check(read(prefix .. "/home/bin/prism.lua") == before, "nothing installed after a failed lookup")
check(read(prefix .. "/home/.prism-update.cfg") == settingsBefore, "settings unchanged after a failed lookup")

local base = serve("me/prism", "dev", "dev")
M.web[base .. "src/prism-control.lua"] = "<html>404: Not Found</html>"
ok = update("me/prism", "dev")
check(not ok and has("valid Lua"), "rejects a download that isn't Lua")
check(read(prefix .. "/home/bin/prism.lua") == before, "nothing replaced when any download is bad")
M.web[base .. "src/prism-control.lua"] = read(H.ROOT .. "/src/prism-control.lua")
M.web[base .. "src/prism-discover.lua"] = nil
ok = update("me/prism", "dev")
check(not ok and has("can't download src/prism-discover.lua") and has("HTTP 404"), "missing file reported with its status")
check(read(prefix .. "/home/.prism-update.cfg") == settingsBefore, "failed update doesn't change saved settings")

M.web[base .. "src/prism-discover.lua"] = read(H.ROOT .. "/src/prism-discover.lua")
M.web[base .. "manifest.lua"] = 'return { { "src/prism.lua", "../../etc/evil.lua" } }'
ok = update("me/prism", "dev")
check(not ok and has("manifest.lua has a bad entry"), "a manifest can't install outside /home")
M.web[base .. "manifest.lua"] = "<html>500</html>"
ok = update("me/prism", "dev")
check(not ok and has("manifest.lua doesn't look right"), "a manifest that isn't Lua is rejected")
check(read(prefix .. "/home/bin/prism.lua") == before, "nothing replaced after a bad manifest")

ok = update("not a repo/x y")
check(not ok and has("usage"), "bad arguments print usage")
ok = update("--help")
check(ok and has("prism-update latest") and has("OWNER/REPO") and #M.requests == 0, "--help prints usage and installs nothing")

---------------------------------------------------------------- settings from older versions
release("aharabedian/prism", "v0.6.0")                       -- GitHub answers again
h = io.open(prefix .. "/home/.prism-update.cfg", "w"); h:write('{repo="aharabedian/prism",branch="main"}'); h:close()
ok = update()
check(ok and installedVersion() == "0.6.0" and saved().ref == "latest", "old saved branch = main moves to releases")
serve("me/prism", "dev", "dev")
h = io.open(prefix .. "/home/.prism-update.cfg", "w"); h:write('{repo="me/prism",branch="dev"}'); h:close()
ok = update()
check(ok and installedVersion() == "dev" and saved().ref == "dev", "any other old saved branch is kept")

---------------------------------------------------------------- a computer still set up under the old router*.cfg names
prefix = H.TMP .. "/legacy"
os.execute('mkdir -p "' .. prefix .. '/home"')
local function put(path, text) local f = io.open(prefix .. "/home/" .. path, "w"); f:write(text); f:close() end
put("router.cfg", "return { interval = 7 }")
put("router-items.cfg", "{}")
put("router-overrides.cfg", "{x=1}")
ok = update()
check(ok, "install over an old router setup succeeds")
check(read(prefix .. "/home/prism.cfg") == "return { interval = 7 }", "old router.cfg becomes prism.cfg (not the example)")
check(read(prefix .. "/home/prism-overrides.cfg") == "{x=1}" and read(prefix .. "/home/prism-items.cfg") == "{}",
  "old data files renamed to prism-*.cfg")
check(read(prefix .. "/home/router.cfg") == nil, "old router.cfg is gone after the move")

os.getenv, os.exit = realGetenv, realExit
H.done()
