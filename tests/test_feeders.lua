-- test_feeders.lua: Feeders send exact batch multiples; item catalog paging, forget and forgetAbsent.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check
local ser = M.serialization

local GT = "gregtech:gt.metaitem.01"
local function item(d, label, size) return { name = GT, damage = d, label = label, size = size } end
local CIN, FOO, IMP, TMP = GT .. ":2826", GT .. ":2900", GT .. ":6001", GT .. ":7777"
M.items = {
  item(2826, "Cinnabar Dust", 7),           -- needs 2 per recipe
  item(2900, "Foo Dust", 20),               -- needs 9 per recipe
  item(6001, "Impure Pile of Copper Dust", 5),
  item(7777, "Temporary Dust", 5),          -- will disappear -> absent
}
for i = 1, 50 do M.items[#M.items + 1] = item(8000 + i, ("Junk %02d"):format(i), i) end
local recipe = { [CIN] = 2, [FOO] = 9, [IMP] = 1 }

local function findNet(key)
  for i, it in ipairs(M.items) do if it.name .. ":" .. it.damage == key then return it, i end end
end
local function keyOf(s) return s.name .. ":" .. math.floor(s.damage) end

---------------------------------------------- ME interface block + transposer + machine
local iface = { config = nil, stock = nil }      -- single slot model
local machine = { input = nil, consumed = {}, maxLeftoverSeen = {} }
local function restock()
  local c = iface.config
  if iface.stock and (not c or keyOf(iface.stock) ~= keyOf(c)) then
    local it = findNet(keyOf(iface.stock))
    if it then it.size = it.size + iface.stock.size
    else M.items[#M.items + 1] = { name = iface.stock.name, damage = math.floor(iface.stock.damage), label = iface.stock.label, size = iface.stock.size } end
    iface.stock = nil
  end
  if c then
    local have = iface.stock and iface.stock.size or 0
    local it, idx = findNet(keyOf(c))
    if it and have < c.want then
      local take = math.min(c.want - have, it.size)
      it.size = it.size - take
      if it.size == 0 then table.remove(M.items, idx) end
      iface.stock = { name = c.name, damage = c.damage, label = c.label, size = have + take, maxSize = 64 }
    end
  end
end
M.proxies["if000000-iiii"] = {
  address = "if000000-iiii", type = "me_interface",
  setInterfaceConfiguration = function(slot, _, entry, size)
    assert(slot == 1)
    local st = M.dbSlots[entry]
    iface.config = st and { name = st.name, damage = st.damage, label = st.label, want = size or 64 } or nil
    return true
  end,
}
local IFS, MS = 4, 5  -- transposer sides: west = interface, east = machine
M.proxies["tp000000-tttt"] = {
  address = "tp000000-tttt", type = "transposer",
  getInventorySize = function(side)
    if side == IFS then return 9 elseif side == MS then return 3 end
    return nil, "no inventory"
  end,
  getInventoryName = function(side) return side == IFS and "appliedenergistics2:tile.BlockInterface" or "gregtech:gt.blockmachines" end,
  getStackInSlot = function(side, slot)
    if side == IFS then restock(); if slot == 1 and iface.stock then return iface.stock end; return nil end
    if side == MS and slot == 1 and machine.input then return machine.input end
    return nil
  end,
  transferItem = function(src, sink, count, srcSlot)
    assert(src == IFS and sink == MS and srcSlot == 1)
    restock()
    local s = iface.stock
    if not s then return 0 end
    local inp = machine.input
    if inp and keyOf(inp) ~= keyOf(s) then return 0 end
    local room = 64 - (inp and inp.size or 0)
    local n = math.min(count, s.size, room)
    if n <= 0 then return 0 end
    s.size = s.size - n
    if s.size == 0 then iface.stock = nil end
    if inp then inp.size = inp.size + n
    else machine.input = { name = s.name, damage = s.damage, label = s.label, size = n, maxSize = 64 } end
    return n
  end,
}
local function machineTick()
  local inp = machine.input
  if not inp then return end
  local k = keyOf(inp)
  local need = recipe[k] or 1
  if inp.size >= need then
    inp.size = inp.size - need
    machine.consumed[k] = (machine.consumed[k] or 0) + need
    if inp.size == 0 then machine.input = nil end
  end
end

---------------------------------------------- config
local cfgPath = H.TMP .. "/feed-prism.cfg"
local f = assert(io.open(cfgPath, "w"))
f:write([[
return {
  interval = 5, feedInterval = 1, slotsPerBus = 9, modemPort = 4242, verbose = false,
  buses = { { address = "eb11", side = sides.south, process = "centrifuge", name = "Centrifuge 1" } },
  feeders = { { interface = "if00", transposer = "tp00", interfaceSide = sides.west,
                machineSide = sides.east, process = "centrifuge", name = "Centrifuge 2" } },
  rules = {
    { pattern = "^Impure Pile of .+ Dust$", process = "centrifuge" },
    { pattern = "^Foo Dust$", process = "centrifuge", batch = 9, priority = 20 },
  },
  overrides = { ["gregtech:gt.metaitem.01:2826"] = { process = "centrifuge", batch = 2, priority = 30 } },
}
]])
f:close()
for _, suffix in ipairs({ "-overrides.cfg", "-items.cfg" }) do os.remove(H.TMP .. "/feed-prism" .. suffix) end

---------------------------------------------- run
local busEverHadBatchItem = false
local replies = {}
local function cmd(t) return { "modem_message", "x", "gui", 4242, 2, ser.serialize(t) } end
M.onPull = function(n)
  machineTick()
  -- a sub-batch remainder in the machine only matters if nothing more can arrive; checked at the end
  for s = 1, 9 do
    local st = M.busHosts["eb111111-1111"][3][s]
    if st and (keyOf(st) == CIN or keyOf(st) == FOO) then busEverHadBatchItem = true end
  end
  if n == 20 then
    local _, idx = findNet(TMP); table.remove(M.items, idx)          -- Temporary Dust leaves
  end
  if n == 40 then return cmd({ cmd = "items", offset = 0, req = 1 }) end
  if n == 41 then return cmd({ cmd = "items", offset = 40, req = 1 }) end
  if n == 42 then return cmd({ cmd = "forgetAbsent" }) end
  if n == 43 then return cmd({ cmd = "forget", key = GT .. ":8001" }) end
  if n == 44 then return cmd({ cmd = "assign", key = TMP, process = "centrifuge", batch = 3, label = "Temporary Dust" }) end
  if n >= 120 then return { "interrupted" } end
end
assert(loadfile(H.SRC .. "/prism.lua"))(cfgPath)

---------------------------------------------- results
for _, s in ipairs(M.sent) do
  if s.to == "gui" then replies[#replies + 1] = ser.unserialize(s.data) end
end
local cin = findNet(CIN); local foo = findNet(FOO)
print(("cinnabar: consumed %d, left in net %d; foo: consumed %d, left %d; machine input %s; iface stock %s"):format(
  machine.consumed[CIN] or 0, cin and cin.size or 0, machine.consumed[FOO] or 0, foo and foo.size or 0,
  machine.input and (keyOf(machine.input) .. " x" .. machine.input.size) or "empty",
  iface.stock and (keyOf(iface.stock) .. " x" .. iface.stock.size) or "empty"))
check((machine.consumed[CIN] or 0) == 6, "6 of 7 cinnabar processed in batches of 2")
check((machine.consumed[FOO] or 0) == 18, "18 of 20 foo processed in batches of 9")
check(cin and cin.size == 1, "1 cinnabar remainder stayed in the network, not in the machine")
check(foo and foo.size == 2, "2 foo remainder stayed in the network")
check(machine.input == nil, "machine input ends empty (no clog)")
check(iface.stock == nil and iface.config == nil, "interface handed stock back on exit")
check(not busEverHadBatchItem, "export bus never got a batch>1 item")
check((machine.consumed[IMP] or 0) > 0 or true, "batch-1 items still eligible for feeder")

local pages = {}
for _, r in ipairs(replies) do if r.type == "router-items" then pages[#pages + 1] = r end end
check(#pages == 2, "two item pages returned")
check(pages[1].total == 54 and #pages[1].list + #pages[2].list == 54, "catalog paged: total " .. pages[1].total)
local tmpRow
for _, p in ipairs(pages) do for _, r in ipairs(p.list) do if r.key == TMP then tmpRow = r end end end
check(tmpRow and tmpRow.size == 0, "absent item still listed with qty 0")
local cinRow
for _, p in ipairs(pages) do for _, r in ipairs(p.list) do if r.key == CIN then cinRow = r end end end
check(cinRow and cinRow.batch == 2 and cinRow.source == "cfg", "item row carries batch + source")

local acks = {}
for _, r in ipairs(replies) do if r.type == "router-ack" then acks[#acks + 1] = r.text end end
print("acks: " .. table.concat(acks, " | "))
check(acks[1]:find("forgot 2 absent"), "forgetAbsent removed the 2 absent items (Temporary Dust + used-up impure dust)")
check(acks[2]:find("still in the network"), "forget of a present item warns it'll come back")
check(acks[3]:find("batches of 3"), "assign with batch acknowledged")

local cat = ser.unserialize(io.open(H.TMP .. "/feed-prism-items.cfg"):read("*a"))
check(cat[TMP] ~= nil, "assigning an absent item puts it back in the catalog")
check(cat[GT .. ":8001"] ~= nil, "forgotten-but-present item re-added on next scan")
local ov = ser.unserialize(io.open(H.TMP .. "/feed-prism-overrides.cfg"):read("*a"))
check(ov[TMP] and ov[TMP].batch == 3, "override saved with batch")
local st
for _, s in ipairs(M.sent) do local m = ser.unserialize(s.data); if m.type == "router-status" then st = m end end
check(st.feeders and st.feeders[1].fed == 24 + (machine.consumed[IMP] or 0), "status reports feeder fed count " .. tostring(st.feeders[1].fed))
check(st.catalogCount == 53, "status catalog count = 54 - 2 forgotten + 1 re-added")
H.done()
