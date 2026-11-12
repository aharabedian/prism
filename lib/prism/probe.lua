--[[ prism.probe: finding and describing the components PRISM uses. Shared by prism-setup and
  prism-discover. Never changes a component.

  addresses(ctype)        sorted addresses of every component of that type
  marker(stack)           what a "marker" item in slot 1 is called, or "(empty)"
  exportBuses()           { addr, side, stack }[]: every side of every me_exportbus with a bus on it
  stocker(addr)           { addr, marker, advanced } for a GT Stocking Input Bus (me_inputbus)
  interfaceMarker(addr)   the item configured in an ME interface's slot 1, or "(empty)"
  inventories(transposer) { side, name, size }[]: the inventories a transposer touches
  feederSides(transposer) inventories, interfaceSide?, machineSide? (guessed from inventory names)
  machine(addr)           { addr, state = "working"|"idle"|"disabled", where = " at x y z" | "" }
  isWireless()            true if a wireless network card is installed
  snapshot()              everything prism-setup's editor shows, as plain tables:
                          { networks = addr[], databases = addr[], buses = { addr, side, marker }[],
                            stockers = { addr, marker, advanced }[], interfaces = { addr, marker }[],
                            transposers = { addr, inv, ifaceSide?, machineSide? }[],
                            machines = { addr, state, where }[] }
]]

local component = require("component")

local P = {}

function P.addresses(ctype)
  local out = {}
  for addr in component.list(ctype) do out[#out + 1] = addr end
  table.sort(out)
  return out
end

function P.marker(stack)
  return type(stack) == "table" and (stack.label or stack.name) or "(empty)"
end

function P.exportBuses()
  local found = {}
  for _, addr in ipairs(P.addresses("me_exportbus")) do
    local p = component.proxy(addr)
    for side = 0, 5 do
      -- No bus on a side either throws or returns nil, "reason".
      local ok, stack, err = pcall(p.getExportConfiguration, side, 1)
      if ok and not (stack == nil and err) then found[#found + 1] = { addr = addr, side = side, stack = stack } end
    end
  end
  return found
end

function P.stocker(addr)
  local p = component.proxy(addr)
  local okC, st = pcall(p.getConfiguration, 1)
  local okA, adv = pcall(p.isAdvanced)
  return { addr = addr, marker = P.marker(okC and st or nil), advanced = okA and adv == true }
end

function P.interfaceMarker(addr)
  local p = component.proxy(addr)
  if not p.getInterfaceConfiguration then return "(empty)" end
  local ok, st = pcall(p.getInterfaceConfiguration, 1)
  return P.marker(ok and st or nil)
end

function P.inventories(t)
  local inv = {}
  for side = 0, 5 do
    local ok, size = pcall(t.getInventorySize, side)
    if ok and type(size) == "number" then
      local okName, name = pcall(t.getInventoryName, side)
      inv[#inv + 1] = { side = side, name = okName and tostring(name) or "?", size = size }
    end
  end
  return inv
end

-- Which transposer sides face the ME interface and the machine, from inventory names.
function P.feederSides(t)
  local inv = P.inventories(t)
  local ifaceSide, machineSide
  local others = {}
  for _, s in ipairs(inv) do
    if s.name:lower():find("interface", 1, true) and not ifaceSide then ifaceSide = s.side
    else others[#others + 1] = s end
  end
  if #others == 1 then machineSide = others[1].side end
  return inv, ifaceSide, machineSide
end

function P.machine(addr)
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
    if ok and x then where = (" at %s %s %s"):format(tostring(x), tostring(y), tostring(z)) end
  end
  local allowed, active = try("isWorkAllowed"), try("isMachineActive")
  local state = allowed == false and "disabled" or (active and "working" or "idle")
  return { addr = addr, state = state, where = where }
end

function P.isWireless()
  for addr in component.list("modem") do
    local m = component.proxy(addr)
    if m.isWireless and m.isWireless() then return true end
  end
  return false
end

function P.snapshot()
  local networks = P.addresses("me_controller")
  if #networks == 0 then networks = P.addresses("me_interface") end
  local s = { networks = networks, databases = P.addresses("database"), buses = {}, stockers = {},
              interfaces = {}, transposers = {}, machines = {} }
  for _, b in ipairs(P.exportBuses()) do
    s.buses[#s.buses + 1] = { addr = b.addr, side = b.side, marker = P.marker(b.stack) }
  end
  for _, a in ipairs(P.addresses("me_inputbus")) do s.stockers[#s.stockers + 1] = P.stocker(a) end
  for _, a in ipairs(P.addresses("me_interface")) do
    s.interfaces[#s.interfaces + 1] = { addr = a, marker = P.interfaceMarker(a) }
  end
  for _, a in ipairs(P.addresses("transposer")) do
    local inv, ifaceSide, machineSide = P.feederSides(component.proxy(a))
    s.transposers[#s.transposers + 1] = { addr = a, inv = inv, ifaceSide = ifaceSide, machineSide = machineSide }
  end
  for _, a in ipairs(P.addresses("gt_machine")) do s.machines[#s.machines + 1] = P.machine(a) end
  return s
end

return P
