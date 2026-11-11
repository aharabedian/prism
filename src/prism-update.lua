--[[ prism-update.lua - install or update PRISM from GitHub

  First time (needs an Internet Card):
    wget -f https://raw.githubusercontent.com/OWNER/prism/main/src/prism-update.lua /home/prism-update.lua
    /home/prism-update OWNER/prism

  After that, on any computer:
    prism-update                 update from the saved repo/branch
    prism-update OWNER/REPO      switch repo (saved for next time)
    prism-update OWNER/REPO dev  use a different branch

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

local function fetch(url)
  local internet = require("internet")
  local ok, handle = pcall(internet.request, url)
  if not ok then return nil, tostring(handle) end
  local parts = {}
  local okRead, err = pcall(function() for chunk in handle do parts[#parts + 1] = chunk end end)
  if not okRead then return nil, tostring(err) end
  local data = table.concat(parts)
  if data == "" then return nil, "empty response" end
  return data
end

---------------------------------------------------------------- main

if not component.isAvailable("internet") then fail("needs an Internet Card") end

local args = { ... }
local settings = readSettings()
local repo   = args[1] or settings.repo
local branch = args[2] or settings.branch or "main"
if not repo or not repo:match("^[%w%-_.]+/[%w%-_.]+$") then
  fail("usage: prism-update OWNER/REPO [branch]   (repo is saved after the first run)")
end

local base = ("https://raw.githubusercontent.com/%s/%s/"):format(repo, branch)
print(("prism-update %s: %s@%s"):format(VERSION, repo, branch))

-- Download everything first; only replace installed files once all downloads look right.
local downloads = {}
for _, f in ipairs(FILES) do
  local data, err = fetch(base .. f[1])
  if not data then fail(("can't download %s: %s"):format(f[1], err)) end
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

writeFile(SETTINGS, serialization.serialize({ repo = repo, branch = branch }))
print("done - restart prism / prism-control to use the new version")
