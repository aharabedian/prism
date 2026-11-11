--[[ prism-update.lua - install or update PRISM from GitHub

  First time (needs an Internet Card):
    wget -f https://raw.githubusercontent.com/aharabedian/prism/main/src/prism-update.lua /home/prism-update.lua
    /home/prism-update

  After that, on any computer:
    prism-update                  update from the saved source (default: latest release of aharabedian/prism)
    prism-update latest           follow releases
    prism-update main             follow the main branch (newest, may be unfinished)
    prism-update v0.5.0           install that release and stay on it
    prism-update OWNER/REPO [REF] use a fork: its latest release, or a branch/tag
  The choice is saved for next time. A repo with no releases yet installs from main.

  Installs prism, prism-control, prism-discover, prism-setup and prism-update into /home/bin (on the
  shell PATH) and prism.example.cfg into /home. Your /home/prism.cfg,
  prism-control.cfg and the prism-*.cfg data files are never touched; run
  prism-setup to create or change them. Each download is syntax-checked before
  it replaces the installed file, so a failed download can't break a computer.
]]

local component  = require("component")
local filesystem = require("filesystem")
local serialization = require("serialization")

local VERSION = "0.4.0"

local PREFIX   = os.getenv("PRISM_PREFIX") or ""   -- lets the test suite install into a temp dir
local HOME     = PREFIX .. "/home"
local BIN      = PREFIX .. "/home/bin"
local SETTINGS = PREFIX .. "/home/.prism-update.cfg"

local DEFAULT_REPO = "aharabedian/prism"
local USAGE = [[
usage: prism-update [OWNER/REPO] [latest | BRANCH | TAG]
  prism-update                  update from the saved source (first time: latest release of ]] .. DEFAULT_REPO .. [[)
  prism-update latest           follow releases (the default)
  prism-update main             follow the main branch (newest, may be unfinished)
  prism-update v0.5.0           install that release and stay on it
  prism-update OWNER/REPO [REF] use a fork: its latest release, or a branch/tag
The choice is saved for next time.]]

local FILES = {
  { "src/prism.lua",           BIN .. "/prism.lua" },
  { "src/prism-control.lua",          BIN .. "/prism-control.lua" },
  { "src/prism-discover.lua",         BIN .. "/prism-discover.lua" },
  { "src/prism-setup.lua",            BIN .. "/prism-setup.lua" },
  { "src/prism-update.lua",    BIN .. "/prism-update.lua" },
  { "config/prism.example.cfg", HOME .. "/prism.example.cfg" },
}

local function fail(msg) io.stderr:write("prism-update: " .. msg .. "\n"); os.exit(1) end

local function readSettings()
  local f = io.open(SETTINGS, "r")
  if not f then return {} end
  local data = f:read("*a")
  f:close()
  return serialization.unserialize(data) or {}
end

local function writeFile(path, data)
  local f, err = io.open(path, "w")
  if not f then return false, err end
  f:write(data)
  f:close()
  return true
end

-- Returns the body, or nil, reason, HTTP status (when the server answered).
local function fetch(url, headers)
  local internet = require("internet")
  local ok, handle = pcall(internet.request, url, nil, headers)
  if not ok then return nil, tostring(handle) end
  local parts = {}
  local okRead, err = pcall(function() for chunk in handle do parts[#parts + 1] = chunk end end)
  if not okRead then
    -- An HTTP error makes the read throw; the handle's response() has the status code.
    local okCode, status = pcall(function() return (handle.response()) end)
    status = okCode and tonumber(status) or nil
    return nil, status and ("HTTP " .. status) or tostring(err), status
  end
  local data = table.concat(parts)
  if data == "" then return nil, "empty response" end
  return data
end

-- The tag of the repo's latest release; nil, "none" if it has no releases; nil, reason on failure.
local function latestRelease(repo)
  local url = ("https://api.github.com/repos/%s/releases/latest"):format(repo)
  local data, err, status = fetch(url, { ["User-Agent"] = "prism-update", Accept = "application/vnd.github+json" })
  if not data then
    if status == 404 then return nil, "none" end
    return nil, err
  end
  local tag = data:match('"tag_name"%s*:%s*"([^"]+)"')
  if not tag then return nil, "no tag_name in GitHub's answer" end
  return tag
end

---------------------------------------------------------------- main

if not component.isAvailable("internet") then fail("needs an Internet Card") end

local args = { ... }
if args[1] == "-h" or args[1] == "--help" or args[1] == "help" then print(USAGE); return end

local function usage(msg) fail(msg .. "\n" .. USAGE) end
local REPO_PATTERN, REF_PATTERN = "^[%w%-_.]+/[%w%-_.]+$", "^[%w%-_./]+$"

-- What to install: `repo` and `ref`, where ref "latest" means the newest release.
local settings = readSettings()
local repo, ref
if args[1] and args[1]:find("/", 1, true) then
  if not args[1]:match(REPO_PATTERN) then usage("not a GitHub repo: " .. args[1]) end
  repo, ref = args[1], args[2] or "latest"           -- a branch name from the old repo may not exist here
elseif args[1] then
  if args[2] then usage("too many arguments") end
  ref = args[1]
end
repo = repo or settings.repo or DEFAULT_REPO
-- Before releases, the updater saved branch = "main" as its default: move those computers to releases.
ref = ref or settings.ref or (settings.branch ~= "main" and settings.branch) or "latest"
if not repo:match(REPO_PATTERN) then usage("not a GitHub repo: " .. repo) end
if not ref:match(REF_PATTERN) or ref:find("..", 1, true) then usage("not a branch or tag: " .. ref) end

local source, what = ref, ref
if ref == "latest" then
  local tag, err = latestRelease(repo)
  if tag then
    source, what = tag, "latest release " .. tag
  elseif err == "none" then
    source, what = "main", "main (no releases yet)"
  else
    fail(("can't find the latest release of %s: %s\n  (prism-update main installs from the main branch instead)"):format(repo, err))
  end
end

local base = ("https://raw.githubusercontent.com/%s/%s/"):format(repo, source)
print(("prism-update %s: %s, %s"):format(VERSION, repo, what))

-- Download everything first; only replace installed files once all downloads look right.
local downloads = {}
for _, f in ipairs(FILES) do
  local data, err = fetch(base .. f[1])
  if not data then fail(("can't download %s from %s@%s: %s"):format(f[1], repo, source, err)) end
  local chunk, syntax = load(data, "=" .. f[1], "t", {})   -- the config is Lua too
  if not chunk then fail(("%s doesn't look like valid Lua (wrong repo or branch?): %s"):format(f[1], syntax)) end
  downloads[#downloads + 1] = { path = f[2], data = data, name = f[1] }
end

if not filesystem.exists(BIN) then filesystem.makeDirectory(BIN) end
for _, d in ipairs(downloads) do
  local tmp = d.path .. ".new"
  local ok, err = writeFile(tmp, d.data)
  if not ok then fail(("can't write %s: %s"):format(tmp, tostring(err))) end
  if filesystem.exists(d.path) then filesystem.remove(d.path) end
  filesystem.rename(tmp, d.path)
  print("  installed " .. d.path)
end

local cfg = HOME .. "/prism.cfg"

-- Before the PRISM name, the config and data files were /home/router*.cfg: carry them over once.
if not filesystem.exists(cfg) and filesystem.exists(HOME .. "/router.cfg") then
  for _, suffix in ipairs({ "", "-overrides", "-items", "-rules" }) do
    local old, new = HOME .. "/router" .. suffix .. ".cfg", HOME .. "/prism" .. suffix .. ".cfg"
    if filesystem.exists(old) and not filesystem.exists(new) then
      filesystem.rename(old, new)
      print("  moved " .. old .. " -> " .. new)
    end
  end
end

if not filesystem.exists(cfg) and not filesystem.exists(HOME .. "/prism-control.cfg") then
  print("  not configured yet - run prism-setup to set this computer up as the router or the control screen")
end

writeFile(SETTINGS, serialization.serialize({ repo = repo, ref = ref }))
local installed = downloads[1].data:match('local VERSION%s*=%s*"([^"]+)"')
print(("done - PRISM %s installed; restart prism / prism-control to use it"):format(installed or "?"))
if ref ~= "latest" then print(("  staying on %s; prism-update latest goes back to releases"):format(ref)) end
