--[[ prism.config: what prism.cfg and prism-control.cfg may contain, and their defaults.
  The single source of defaults: the programs load through here and prism-setup writes these.
  Every option is documented in docs/configuration.md.

  ROUTER_TUNING, CONTROL_TUNING   { key, default, comment }[]: plain settings prism-setup writes with a comment
  loadRouter(path, log)           prism.cfg with defaults filled in; raises a readable error if it can't
  loadControl(path)               prism-control.cfg with defaults filled in; the file is optional
]]

local files    = require("prism.files")
local rules    = require("prism.rules")
local protocol = require("prism.protocol")

local C = {}

C.ROUTER_TUNING = {
  { "interval",        5,     "seconds between network scans" },
  { "feedInterval",    1,     "seconds between feeder steps" },
  { "monitorInterval", 2,     "seconds between GT machine polls" },
  { "stallAfter",      60,    "seconds of items waiting with nothing moving before a stall alert" },
  { "idleAlert",       30,    "seconds a monitored machine may sit idle with work waiting" },
  { "defaultPriority", 10,    "priority for rules and overrides that don't set one" },
  { "verbose",         false, "log every filter and interface change" },
}
C.ROUTER_DEFAULTS = { slotsPerBus = 9 }
C.ROUTER_LISTS = { "overrides", "buses", "stockers", "interfaces", "feeders", "machines", "processes" }

C.CONTROL_TUNING = {
  { "history",    60, "backlog samples kept for the sparklines" },
  { "staleAfter", 3,  "missed router cycles before showing NO SIGNAL" },
  { "batches",    { 1, 2, 3, 4, 6, 8, 9, 16, 32, 36, 64 }, "batch buttons offered on the screen" },
}
-- modemPort = false turns wireless off, so these defaults only replace nil.
C.CONTROL_DEFAULTS = { modemPort = protocol.DEFAULT_PORT, beep = true }

function C.loadRouter(path, log)
  if not files.exists(path) then error("no " .. path .. " - run prism-setup to create it", 0) end
  local fn, err = loadfile(path, "t", { sides = require("sides") })
  if not fn then error("can't load " .. path .. ": " .. tostring(err), 0) end
  local ok, c = pcall(fn)
  if not ok or type(c) ~= "table" then error("bad config: " .. tostring(c), 0) end
  for _, t in ipairs(C.ROUTER_TUNING) do
    if c[t[1]] == nil then c[t[1]] = t[2] end
  end
  for k, v in pairs(C.ROUTER_DEFAULTS) do
    if c[k] == nil then c[k] = v end
  end
  for _, k in ipairs(C.ROUTER_LISTS) do c[k] = c[k] or {} end
  c.rules = rules.clean(c.rules, "prism.cfg", log)
  return c
end

function C.loadControl(path)
  local t, err = files.loadLua(path, {})
  if not t and err then error("bad config " .. path .. ": " .. err, 0) end
  t = t or {}
  for _, s in ipairs(C.CONTROL_TUNING) do
    if t[s[1]] == nil then t[s[1]] = s[2] end
  end
  for k, v in pairs(C.CONTROL_DEFAULTS) do
    if t[k] == nil then t[k] = v end
  end
  return t
end

return C
