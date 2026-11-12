-- test_modules.lua: packaging and the contracts between files: manifest.lua lists every program and module,
-- the version is the same everywhere, every config key and command is documented, and a program drops
-- module copies cached by an earlier run and says what to do when the modules aren't installed.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
require("oc")
local check = H.check

local function read(path) local f = io.open(H.ROOT .. "/" .. path); if not f then return nil end; local s = f:read("*a"); f:close(); return s end
local function lines(cmd) local out, p = {}, io.popen(cmd); for l in p:lines() do out[#out + 1] = l end; p:close(); return out end

---------------------------------------------------------------- manifest
local listed = {}
for _, f in ipairs(dofile(H.ROOT .. "/manifest.lua")) do listed[f[1]] = f[2] end
local missing = {}
for _, f in ipairs(lines('cd "' .. H.ROOT .. '" && find src lib -name "*.lua" | sort')) do
  if not listed[f] then missing[#missing + 1] = f end
end
check(#missing == 0, "manifest.lua lists every file in src/ and lib/" .. (#missing > 0 and (": missing " .. table.concat(missing, ", ")) or ""))
local absent = {}
for src in pairs(listed) do if not read(src) then absent[#absent + 1] = src end end
check(#absent == 0, "every file manifest.lua lists exists" .. (#absent > 0 and (": " .. table.concat(absent, ", ")) or ""))
local placed = true
for src, dest in pairs(listed) do
  if src:find("^src/") and dest ~= "bin/" .. src:sub(5) then placed = false end
  if src:find("^lib/") and dest ~= src then placed = false end
end
check(placed, "programs install to /home/bin and modules to /home/lib (where the programs look for them)")

---------------------------------------------------------------- vendored LENS modules
-- lib/prism/lens/ holds copies of LENS's lens.metrics and lens.codec (tools/sync-lens.sh). When a LENS
-- checkout sits next to this one, they must match it byte for byte; CI has no checkout and skips this.
local lensRoot = os.getenv("LENS_ROOT") or (H.ROOT .. "/../lens")
if read("../lens/lib/lens/codec.lua") or os.getenv("LENS_ROOT") then
  local differ = {}
  for _, f in ipairs({ "metrics", "codec" }) do
    local theirs = io.open(lensRoot .. "/lib/lens/" .. f .. ".lua")
    local t = theirs and theirs:read("*a")
    if theirs then theirs:close() end
    if t ~= read("lib/prism/lens/" .. f .. ".lua") then differ[#differ + 1] = f end
  end
  check(#differ == 0, "lib/prism/lens/ matches the LENS checkout (run tools/sync-lens.sh)" ..
    (#differ > 0 and (": " .. table.concat(differ, ", ") .. " differ") or ""))
end

---------------------------------------------------------------- version
local version = dofile(H.ROOT .. "/lib/prism/version.lua")
check(read("src/prism-update.lua"):match('local VERSION = "([^"]*)"') == version,
  "prism-update.lua's own VERSION matches lib/prism/version.lua")
local stray = lines('cd "' .. H.ROOT .. '" && grep -l "local VERSION = \\"" src/*.lua lib -r')
check(#stray == 1 and stray[1] == "src/prism-update.lua", "only prism-update.lua carries its own VERSION")

---------------------------------------------------------------- docs cover the code
local config = require("prism.config")
local confDoc = read("docs/configuration.md")
local undocumented = {}
for _, t in ipairs(config.ROUTER_TUNING) do
  if not confDoc:find("| `" .. t[1] .. "` |", 1, true) then undocumented[#undocumented + 1] = t[1] end
end
for k in pairs(config.ROUTER_DEFAULTS) do
  if not confDoc:find("| `" .. k .. "` |", 1, true) then undocumented[#undocumented + 1] = k end
end
check(#undocumented == 0, "docs/configuration.md documents every router setting" ..
  (#undocumented > 0 and (": missing " .. table.concat(undocumented, ", ")) or ""))

local protoDoc = read("docs/protocol.md")
local commands = require("prism.router.commands").COMMANDS
local notDocumented, notImplemented = {}, {}
for cmd in pairs(commands) do
  if not protoDoc:find("| `" .. cmd .. "` |", 1, true) then notDocumented[#notDocumented + 1] = cmd end
end
for cmd in protoDoc:match("## Commands.-\n(.-)\n## "):gmatch("\n| `([%w]+)` |") do
  if cmd ~= "cmd" and not commands[cmd] then notImplemented[#notImplemented + 1] = cmd end
end
check(#notDocumented == 0, "docs/protocol.md lists every command the router answers" ..
  (#notDocumented > 0 and (": missing " .. table.concat(notDocumented, ", ")) or ""))
check(#notImplemented == 0, "every command in docs/protocol.md is implemented" ..
  (#notImplemented > 0 and (": " .. table.concat(notImplemented, ", ")) or ""))

---------------------------------------------------------------- program bootstrap
local out = {}
local realPrint = print
print = function(...) out[#out + 1] = table.concat({ ... }, "\t") end
package.loaded["prism.version"] = "stale"          -- as if left by an earlier run before an update
H.run("prism-discover.lua")
print = realPrint
check(out[1] == "prism-discover " .. version, "a program drops prism.* modules cached by an earlier run")

local realPath = package.path
package.path = package.path:gsub("[^;]*/lib/%?%.lua;", "")
package.loaded["prism.version"] = nil
local ok, err = pcall(H.run, "prism-discover.lua")
package.path = realPath
check(not ok and tostring(err):find("run prism-update", 1, true),
  "without its modules, a program says to run prism-update (not a raw require error)")

H.done()
