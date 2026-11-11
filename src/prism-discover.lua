--[[ prism-discover.lua - find the components the PRISM router needs.

  Tip: to tell your export buses apart, drop a different "marker" item into
  slot 1 of each bus's filter by hand (cobblestone in the washer bus, dirt in
  the centrifuge bus, ...) before running this. The marker is printed next to
  each bus so you know which line is which.
]]

local component = require("component")

local VERSION = "0.4.0"

local SIDE_NAMES = { [0] = "down", "up", "north", "south", "west", "east" }

local function header(text) print(""); print(text) end

print("prism-discover " .. VERSION)

header("ME networks (prism.cfg 'network'):")
local found = false
for addr, ctype in component.list() do
  if ctype == "me_controller" or ctype == "me_interface" then
    print(string.format("  %-14s %s", ctype, addr)); found = true
  end
end
if not found then print("  none - put an adapter against the subnet's controller or ME interface") end

header("Databases (prism.cfg 'database'):")
found = false
for addr in component.list("database") do print("  " .. addr); found = true end
if not found then print("  none - put a Database Upgrade inside an adapter") end

header("Wireless/network cards:")
found = false
for addr in component.list("modem") do
  local m = component.proxy(addr)
  print(string.format("  %s  wireless=%s", addr, tostring(m.isWireless and m.isWireless())))
  found = true
end
if not found then print("  none") end

header("Export buses - paste into prism.cfg 'buses' and set each process:")
found = false
for addr in component.list("me_exportbus") do
  local p = component.proxy(addr)
  for side = 0, 5 do
    -- No bus on a side either throws or returns nil, "reason".
    local ok, stack, err = pcall(p.getExportConfiguration, side, 1)
    if ok and not (stack == nil and err) then
      local marker = stack and (stack.label or stack.name) or "(empty)"
      print(string.format('  { address = "%s", side = sides.%s, process = "?" }, -- slot 1: %s',
        addr:sub(1, 8), SIDE_NAMES[side], marker))
      found = true
    end
  end
end
if not found then print("  none - put an adapter against the cable block your export buses are on") end

header("ME interfaces (feeder 'interface'):")
found = false
for addr in component.list("me_interface") do print("  " .. addr); found = true end
if not found then print("  none") end

header("Transposers (feeder 'transposer') and what they touch:")
found = false
for addr in component.list("transposer") do
  local t = component.proxy(addr)
  print("  " .. addr)
  for side = 0, 5 do
    local ok, size = pcall(t.getInventorySize, side)
    if ok and type(size) == "number" then
      local okName, name = pcall(t.getInventoryName, side)
      print(string.format("    sides.%-6s %-40s %d slots", SIDE_NAMES[side],
        okName and tostring(name) or "?", size))
    end
  end
  found = true
end
if not found then print("  none") end

header("GT machines (prism.cfg 'machines') - toggle one with a soft mallet to spot it:")
found = false
for addr in component.list("gt_machine") do
  local m = component.proxy(addr)
  local function try(fn)
    if m[fn] == nil then return nil end
    local ok, v = pcall(m[fn])
    if ok then return v end
    return nil
  end
  local where = ""
  if m.getCoordinates then
    local ok, x, y, z = pcall(m.getCoordinates)
    if ok and x then where = ("  at %s %s %s"):format(tostring(x), tostring(y), tostring(z)) end
  end
  local active = try("isMachineActive")
  local allowed = try("isWorkAllowed")
  local state = allowed == false and "disabled" or (active and "working" or "idle")
  print(string.format('  { address = "%s", process = "?", name = "?" }, -- %s%s',
    addr:sub(1, 8), state, where))
  found = true
end
if not found then print("  none - put an adapter against each GT machine you want to watch") end
print("")
