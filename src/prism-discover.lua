--[[ prism-discover.lua - list the components the PRISM router can use, as prism.cfg lines.
  prism-setup does the same interactively; this is for writing prism.cfg by hand.

  Tip: to tell your export buses apart, drop a different "marker" item into
  slot 1 of each bus's filter by hand (cobblestone in the washer bus, dirt in
  the centrifuge bus, ...) before running this. The marker is printed next to
  each bus so you know which line is which. Stocking input buses work the
  same way: put a marker in slot 1 of their configuration.
]]

-- Modules live in /home/lib/prism (prism-update installs them). Forget copies cached by an earlier
-- run, so restarting after an update loads the new ones.
if not package.path:find("/home/lib/?.lua", 1, true) then package.path = package.path .. ";/home/lib/?.lua" end
for name in pairs(package.loaded) do if name:find("^prism%.") then package.loaded[name] = nil end end
if not pcall(require, "prism.version") then error("PRISM's modules are missing from /home/lib/prism - run prism-update", 0) end

local component = require("component")
local VERSION   = require("prism.version")
local U         = require("prism.util")
local probe     = require("prism.probe")

-- Print a section: a heading, a line per item from `lines`, or `none` when there are none.
local function section(heading, lines, none)
  print("")
  print(heading)
  for _, l in ipairs(lines) do print(l) end
  if #lines == 0 then print("  " .. none) end
end

local function map(list, fn)
  local out = {}
  for _, x in ipairs(list) do
    local r = fn(x)
    if type(r) == "table" then for _, l in ipairs(r) do out[#out + 1] = l end else out[#out + 1] = r end
  end
  return out
end

print("prism-discover " .. VERSION)

local networks = {}
for _, ctype in ipairs({ "me_controller", "me_interface" }) do
  for _, addr in ipairs(probe.addresses(ctype)) do networks[#networks + 1] = ("  %-14s %s"):format(ctype, addr) end
end
section("ME networks (prism.cfg 'network'):", networks,
  "none - put an adapter against the subnet's controller or ME interface")

section("Databases (prism.cfg 'database'):", map(probe.addresses("database"), function(a) return "  " .. a end),
  "none - put a Database Upgrade inside an adapter")

section("Wireless/network cards:", map(probe.addresses("modem"), function(a)
  local m = component.proxy(a)
  return ("  %s  wireless=%s"):format(a, tostring(m.isWireless and m.isWireless()))
end), "none")

section("Export buses - paste into prism.cfg 'buses' and set each process:", map(probe.exportBuses(), function(b)
  return ('  { address = "%s", side = sides.%s, process = "?" }, -- slot 1: %s'):format(
    b.addr:sub(1, 8), U.sideName(b.side), probe.marker(b.stack))
end), "none - put an adapter against the cable block your export buses are on")

section("GT Stocking Input Buses (ME) - paste into prism.cfg 'stockers' and set each process:",
  map(probe.addresses("me_inputbus"), function(a)
    local s = probe.stocker(a)
    return ('  { address = "%s", process = "?" }, -- %sslot 1: %s'):format(
      a:sub(1, 8), s.advanced and "advanced, " or "", s.marker)
  end), "none - put an adapter against each stocking input bus (needs a GTNH build with its OC driver)")

section("ME interfaces (feeder 'interface'):", map(probe.addresses("me_interface"), function(a) return "  " .. a end),
  "none")

section("Transposers (feeder 'transposer') and what they touch:", map(probe.addresses("transposer"), function(a)
  local out = { "  " .. a }
  for _, inv in ipairs(probe.inventories(component.proxy(a))) do
    out[#out + 1] = ("    sides.%-6s %-40s %d slots"):format(U.sideName(inv.side), inv.name, inv.size)
  end
  return out
end), "none")

section("GT machines (prism.cfg 'machines') - toggle one with a soft mallet to spot it:",
  map(probe.addresses("gt_machine"), function(a)
    local m = probe.machine(a)
    return ('  { address = "%s", process = "?", name = "?" }, -- %s%s'):format(a:sub(1, 8), m.state,
      m.where ~= "" and (" " .. m.where) or "")
  end), "none - put an adapter against each GT machine you want to watch")
print("")
