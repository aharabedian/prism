--[[ prism.setup.hardware: the router's hardware steps. Each finds the components (prism.probe),
  asks what each one is for, and returns the config entries. `old` is the matching part of the
  current prism.cfg; its answers are offered as defaults.

  network(old) -> address | nil         database(old) -> address | nil
  buses(old, oldSlots, procs) -> buses, slotsPerBus
  stockers(old, procs) -> stockers      feeders(old, network, procs, skip?) -> feeders
  interfaces(old, skip, procs) -> interfaces      skip(address): true for interfaces not to offer
  machines(old, procs) -> machines
]]

local component = require("component")
local U         = require("prism.util")
local probe     = require("prism.probe")
local input     = require("prism.setup.input")

local Hw = {}

local function findOld(list, fn)
  for _, e in ipairs(list or {}) do if fn(e) then return e end end
end

function Hw.network(old)
  input.header("ME network")
  local list = probe.addresses("me_controller")
  if #list == 0 then list = probe.addresses("me_interface") end
  if #list == 0 then
    print("  none found - put an adapter against the subnet's ME controller (or an ME interface on it), then run this again")
    return nil
  end
  local addr = input.pickOne(list, old)
  print("  using " .. addr)
  return addr
end

function Hw.database(old)
  input.header("Database Upgrade")
  local list = probe.addresses("database")
  if #list == 0 then
    print("  none found - only export buses and feeders need one; skipping them")
    print("  (put a Database Upgrade inside an adapter and run this again to set them up)")
    return nil
  end
  local addr = input.pickOne(list, old)
  print("  using " .. addr)
  return addr
end

function Hw.buses(old, oldSlots, procs)
  input.header("Export buses (tip: a marker item in slot 1 of a bus's filter shows which one it is)")
  local found = probe.exportBuses()
  if #found == 0 then
    print("  none found - put an adapter against the cable block your export buses are on")
    return {}, oldSlots
  end

  local cards
  while true do
    cards = tonumber(input.ask("  Capacity Cards per bus: 0, 1 or 2", ({ [1] = "0", [5] = "1", [9] = "2" })[oldSlots or 9]))
    if cards == 0 or cards == 1 or cards == 2 then break end
    print("  enter 0, 1 or 2")
  end
  local slots = ({ [0] = 1, 5, 9 })[cards]

  local out = {}
  input.processHint(procs)
  for _, b in ipairs(found) do
    print(("  bus %s, %s side - slot 1: %s"):format(b.addr:sub(1, 8), U.sideName(b.side), probe.marker(b.stack)))
    local prev = findOld(old, function(e) return e.side == b.side and input.sameAddr(b.addr, e.address) end)
    local proc, name = input.askProcess("this bus", prev, procs)
    if proc then out[#out + 1] = { address = b.addr, side = b.side, process = proc, name = name } end
  end
  return out, slots
end

function Hw.stockers(old, procs)
  input.header("Stocking input buses (GT multiblocks; a marker in slot 1 shows which one it is)")
  local out = {}
  local list = probe.addresses("me_inputbus")
  if #list == 0 then
    print("  none - put an adapter against each Stocking Input Bus (ME) you want PRISM to fill")
    return out
  end
  input.processHint(procs)
  for _, addr in ipairs(list) do
    local s = probe.stocker(addr)
    print(("  stocking bus %s%s - slot 1: %s"):format(addr:sub(1, 8), s.advanced and ", advanced" or "", s.marker))
    local prev = findOld(old, function(e) return input.sameAddr(addr, e.address) end)
    local proc, name = input.askProcess("this stocking bus", prev, procs)
    if proc then out[#out + 1] = { address = addr, process = proc, name = name } end
  end
  return out
end

function Hw.feeders(old, network, procs, skip)
  input.header("Feeders (ME Interface block -> transposer -> machine, for batch items)")
  local out = {}
  local transposers = probe.addresses("transposer")
  if #transposers == 0 then print("  no transposers - skipping"); return out end
  local ifaces = {}
  for _, a in ipairs(probe.addresses("me_interface")) do
    if a ~= network and not (skip and skip(a)) then ifaces[#ifaces + 1] = a end
  end
  if #ifaces == 0 then
    print("  no ME interface with an adapter (other than the network's and ones other networks pull from) - skipping")
    return out
  end
  input.processHint(procs)
  local slotsUsed = {}
  for _, addr in ipairs(transposers) do
    local inv, ifaceSide, machineSide = probe.feederSides(component.proxy(addr))
    print(("  transposer %s"):format(addr:sub(1, 8)))
    if #inv < 2 then
      print("    touches fewer than two inventories - skipping")
    else
      local prev = findOld(old, function(f) return input.sameAddr(addr, f.transposer) end)
      if prev and prev.interfaceSide and prev.machineSide then
        ifaceSide, machineSide = prev.interfaceSide, prev.machineSide
      end
      if ifaceSide and machineSide then
        print(("    interface on %s, machine on %s"):format(U.sideName(ifaceSide), U.sideName(machineSide)))
      end
      local proc, name = input.askProcess("this feeder", prev, procs)
      if proc then
        ifaceSide = ifaceSide or input.askSide("ME interface", inv)
        machineSide = machineSide or input.askSide("machine", inv)
        if #ifaces > 1 then print("    which ME interface block does it pull from?") end
        local iface = input.pickOne(ifaces, prev and prev.interface)
        slotsUsed[iface] = (slotsUsed[iface] or 0) + 1
        out[#out + 1] = { interface = iface, transposer = addr, interfaceSide = ifaceSide,
                          machineSide = machineSide, slot = slotsUsed[iface], process = proc, name = name }
      end
    end
  end
  return out
end

function Hw.interfaces(old, skip, procs)
  input.header("Interfaces another network pulls from (its import bus faces the interface; a marker in slot 1 shows which)")
  local out, list = {}, {}
  for _, a in ipairs(probe.addresses("me_interface")) do if not skip(a) then list[#list + 1] = a end end
  if #list == 0 then
    print("  none - put an adapter against an ME interface block on the subnet, with the other network's import bus facing it")
    return out
  end
  input.processHint(procs)
  for _, addr in ipairs(list) do
    print(("  interface %s - slot 1: %s"):format(addr:sub(1, 8), probe.interfaceMarker(addr)))
    local prev = findOld(old, function(e) return input.sameAddr(addr, e.address) end)
    local proc, name = input.askProcess("this interface", prev, procs)
    if proc then out[#out + 1] = { address = addr, process = proc, name = name, slots = prev and prev.slots } end
  end
  return out
end

function Hw.machines(old, procs)
  input.header("GT machines to monitor (toggle one with a soft mallet to see it change to disabled)")
  local out = {}
  local list = probe.addresses("gt_machine")
  if #list == 0 then print("  none - put an adapter against each GT machine you want to watch"); return out end
  input.processHint(procs)
  for _, addr in ipairs(list) do
    local m = probe.machine(addr)
    print(("  machine %s, %s%s"):format(addr:sub(1, 8), m.state, m.where))
    local prev = findOld(old, function(e) return input.sameAddr(addr, e.address) end)
    local proc, name = input.askProcess("this machine", prev, procs)
    if proc then out[#out + 1] = { address = addr, process = proc, name = name } end
  end
  return out
end

return Hw
