--[[ prism.setup.render: prism.cfg and prism-control.cfg as Lua source.

  router(c) -> text     every setting (tuning defaults from prism.config), then buses, stockers,
                        feeders, machines, rules and overrides; unknown keys are kept at the end
  control(c) -> text
  lua(v) -> text        any plain value as Lua source, keys sorted so the output is stable
]]

local VERSION = require("prism.version")
local U       = require("prism.util")
local config  = require("prism.config")

local R = {}

local function q(s) return string.format("%q", s) end
local function sideRef(s) return "sides." .. U.sideName(s) end
local function keyRef(k)
  return type(k) == "string" and k:match("^[%a_][%w_]*$") and k or ("[" .. R.lua(k) .. "]")
end

function R.lua(v)
  if type(v) == "string" then return q(v) end
  if type(v) ~= "table" then return tostring(v) end
  local parts, n = {}, #v
  for i = 1, n do parts[#parts + 1] = R.lua(v[i]) end
  local keys = {}
  for k in pairs(v) do
    if not (math.type(k) == "integer" and k >= 1 and k <= n) then keys[#keys + 1] = k end
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(keys) do parts[#parts + 1] = keyRef(k) .. " = " .. R.lua(v[k]) end
  if #parts == 0 then return "{}" end
  return "{ " .. table.concat(parts, ", ") .. " }"
end

local function setting(L, key, value, comment)
  local line = ("  %s = %s,"):format(key, value == nil and "nil" or R.lua(value))
  L[#L + 1] = comment and (("%-34s -- %s"):format(line, comment)) or line
end

local function tuning(L, c, list, known)
  for _, t in ipairs(list) do
    known[t[1]] = true
    local v = c[t[1]]
    if v == nil then v = t[2] end
    setting(L, t[1], v, t[3])
  end
end

-- Keys of `t` not in `known`, so hand-added settings survive a rewrite.
local function extras(L, t, known)
  local keys = {}
  for k in pairs(t) do if not known[k] then keys[#keys + 1] = k end end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  if #keys > 0 then L[#L + 1] = "" end
  for _, k in ipairs(keys) do L[#L + 1] = ("  %s = %s,"):format(keyRef(k), R.lua(t[k])) end
end

function R.router(c)
  local L = {
    "-- prism.cfg - written by prism-setup " .. VERSION .. ". Run prism-setup to change it; values you",
    "-- edit by hand are kept when it rewrites this file (comments aren't). Every option: docs/configuration.md",
    "return {",
  }
  local known = {}
  tuning(L, c, config.ROUTER_TUNING, known)
  L[#L + 1] = ""
  setting(L, "network", c.network, "ME controller/interface to scan")
  setting(L, "database", c.database, "Database Upgrade used to stage items")
  setting(L, "modemPort", c.modemPort, "wireless port for the control screen; false = off")
  setting(L, "token", c.token, "shared secret the screen must send; nil = none")
  setting(L, "slotsPerBus", c.slotsPerBus or config.ROUTER_DEFAULTS.slotsPerBus, "filter slots per export bus: 1, 5 or 9")
  for _, k in ipairs({ "network", "database", "modemPort", "token", "slotsPerBus",
                       "buses", "stockers", "feeders", "machines", "rules", "overrides" }) do known[k] = true end

  local function opt(name) return name and (", name = " .. q(name)) or "" end
  L[#L + 1] = ""
  L[#L + 1] = "  buses = {"
  for _, b in ipairs(c.buses or {}) do
    L[#L + 1] = ("    { address = %s, side = %s, process = %s%s },")
      :format(q(b.address), sideRef(b.side), q(b.process), opt(b.name))
  end
  L[#L + 1] = "  },"
  L[#L + 1] = "  stockers = {"
  for _, b in ipairs(c.stockers or {}) do
    L[#L + 1] = ("    { address = %s, process = %s%s },"):format(q(b.address), q(b.process), opt(b.name))
  end
  L[#L + 1] = "  },"
  L[#L + 1] = "  feeders = {"
  for _, f in ipairs(c.feeders or {}) do
    L[#L + 1] = ("    { interface = %s, transposer = %s, interfaceSide = %s, machineSide = %s,%s"):format(
      q(f.interface), q(f.transposer), sideRef(f.interfaceSide), sideRef(f.machineSide),
      f.slot and f.slot > 1 and (" slot = " .. f.slot .. ",") or "")
    L[#L + 1] = ("      process = %s%s },"):format(q(f.process), opt(f.name))
  end
  L[#L + 1] = "  },"
  L[#L + 1] = "  machines = {"
  for _, m in ipairs(c.machines or {}) do
    L[#L + 1] = ("    { address = %s, process = %s%s },"):format(q(m.address), q(m.process), opt(m.name))
  end
  L[#L + 1] = "  },"

  L[#L + 1] = ""
  L[#L + 1] = "  -- Matched against item names, first match wins. Editing rules on the control screen"
  L[#L + 1] = "  -- saves prism-rules.cfg, which replaces this list until RESET TO prism.cfg."
  L[#L + 1] = "  rules = {"
  for _, r in ipairs(c.rules or {}) do
    L[#L + 1] = ("    { pattern = %s, process = %s%s%s },"):format(q(r.pattern), q(r.process),
      r.priority and (", priority = " .. r.priority) or "", r.batch and (", batch = " .. r.batch) or "")
  end
  L[#L + 1] = "  },"
  L[#L + 1] = "  -- Per-item overrides beat the rules. Key = \"itemname:damage\" (the router logs these)."
  L[#L + 1] = "  overrides = {"
  local keys = {}
  for k in pairs(c.overrides or {}) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do L[#L + 1] = ("    [%s] = %s,"):format(q(k), R.lua(c.overrides[k])) end
  L[#L + 1] = "  },"
  extras(L, c, known)
  L[#L + 1] = "}"
  return table.concat(L, "\n") .. "\n"
end

function R.control(c)
  local L = {
    "-- prism-control.cfg - written by prism-setup " .. VERSION .. ". Settings for the control screen;",
    "-- run prism-setup to change them. Values you edit by hand are kept when it rewrites this file.",
    "return {",
  }
  setting(L, "modemPort", c.modemPort, "must match modemPort in the router's prism.cfg")
  setting(L, "token", c.token, "must match token there; nil = none")
  setting(L, "beep", c.beep ~= false, "beep when a new alert appears")
  local known = { modemPort = true, token = true, beep = true }
  tuning(L, c, config.CONTROL_TUNING, known)
  extras(L, c, known)
  L[#L + 1] = "}"
  return table.concat(L, "\n") .. "\n"
end

return R
