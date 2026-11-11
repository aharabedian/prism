-- test_control.lua: Control screen: routing an item, ITEMS paging + search, batch, forget, clear absent, overrides.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check
local ser = M.serialization

local GT = "gregtech:gt.metaitem.01"
local function item(d, label, size) return { name = GT, damage = d, label = label, size = size } end
local names = { "Copper", "Tin", "Iron", "Gold", "Nickel", "Lead", "Silver", "Zinc", "Antimony", "Bauxite", "Cassiterite", "Chalcopyrite" }
M.items = {}
for i, n in ipairs(names) do M.items[#M.items + 1] = item(5000 + i, "Crushed " .. n .. " Ore", (13 - i) * 37) end
M.items[#M.items + 1] = item(6001, "Impure Pile of Copper Dust", 410)
M.items[#M.items + 1] = item(2826, "Cinnabar Dust", 96)
M.items[#M.items + 1] = { name = "gregtech:gt.blockores", damage = 35, label = "Copper Ore", size = 7 }
M.items[#M.items + 1] = item(9999, "Crushed Platinum Ore Tailings", 3)
M.items[#M.items + 1] = item(7001, "Copper Dust", 1288)
M.items[#M.items + 1] = item(7002, "Stone Dust", 9431)

local cfgPath = H.TMP .. "/ctl2-prism.cfg"
local f = assert(io.open(cfgPath, "w"))
f:write([[
return {
  interval = 5, slotsPerBus = 9, modemPort = 4242, verbose = false,
  buses = {
    { address = "eb11", side = sides.north, process = "wash",       name = "Washer 1" },
    { address = "eb22", side = sides.up,    process = "wash",       name = "Washer 2" },
    { address = "eb11", side = sides.south, process = "centrifuge", name = "Centrifuge 1" },
  },
  rules = {
    { pattern = "^Crushed .+ Ore$",           process = "wash",       priority = 10 },
    { pattern = "^Impure Pile of .+ Dust$",   process = "centrifuge", priority = 10 },
    { pattern = "Ore$",                       process = "crush",      priority = 5  },
  },
  overrides = { [ "gregtech:gt.metaitem.01:2826" ] = { process = "centrifuge", batch = 2, priority = 30 } },
}
]])
f:close()
for _, s in ipairs({ "-overrides.cfg", "-items.cfg" }) do os.remove(H.TMP .. "/ctl2-prism" .. s) end

------------------------------------------------ 1) router run to capture real messages
M.onPull = function(n)
  if n == 1 then
    return { "modem_message", "x", "gui", 4242, 1,
             ser.serialize({ cmd = "assign", key = GT .. ":7002", process = "ignore", label = "Stone Dust" }) }
  end
  if n == 3 then return { "modem_message", "x", "gui", 4242, 1, ser.serialize({ cmd = "overrides" }) } end
  if n == 4 then return { "modem_message", "x", "gui", 4242, 1, ser.serialize({ cmd = "items", offset = 0, req = 1 }) } end
  if n == 5 then return { "interrupted" } end
end
assert(loadfile(H.SRC .. "/prism.lua"))(cfgPath)
local statusMsg, ovMsg, itemsMsg
for _, s in ipairs(M.sent) do
  local m = ser.unserialize(s.data)
  if m.type == "router-status" and not statusMsg then statusMsg = s.data end
  if m.type == "router-overrides" then ovMsg = s.data end
  if m.type == "router-items" then itemsMsg = m end
end
check(statusMsg and ovMsg and itemsMsg, "router produced status, overrides and items")

-- split the item list into two pages and add an absent item, to exercise paging
local all = itemsMsg.list
table.insert(all, { key = GT .. ":2999", label = "Cooperite Dust", size = 0, process = "centrifuge", priority = 10, batch = 4, source = "gui" })
local function page(req, offset, n)
  local l = {}
  for i = offset + 1, math.min(#all, offset + n) do l[#l + 1] = all[i] end
  return ser.serialize({ type = "router-items", req = req, offset = offset, total = #all, list = l })
end

local function statusWith(cycle, scale)
  local s = ser.unserialize(statusMsg)
  s.cycles = cycle
  for _, p in pairs(s.processes) do p.items = math.floor(p.items * scale) end
  s.feeders = {
    { name = "Centrifuge 2", process = "centrifuge", state = "feeding", label = "Cinnabar Dust", batch = 2, fed = 1234 },
    { name = "Sifter 1", process = "sift", state = "blocked: 1 in machine, not a multiple of 2", label = "Purified Ore", batch = 2, fed = 56 },
  }
  s.processes.sift = { types = 1, items = 40, buses = 1 }
  return ser.serialize(s)
end

------------------------------------------------ 2) control screen
M.sent = {}
local stderr = {}
io.stderr = { write = function(_, s) stderr[#stderr + 1] = s end }
local function tap(text, minY)
  local x, y = M.find(text, minY)
  assert(x, "can't find '" .. text .. "' on screen")
  return { "touch", "screen", x + 1, y, 0, "Aaron" }
end
local function key(ch) return { "key_down", "kb", string.byte(ch), 0, "Aaron" } end
local function lastSent() return ser.unserialize(M.sent[#M.sent].data) end
local function msg(data) return { "modem_message", "x", "router-addr", 4242, 4, data } end
local PT = M.H - 14

local scales = { 1.6, 1.4, 1.5, 1.2, 1.25, 1.1, 1.0 }
local steps = {
  function() -- unassigned tab: pick item
    H.screen("route-dashboard")
    check(M.find("FEEDERS") ~= nil, "feeders section drawn")
    check(M.find("blocked: 1 in machine") ~= nil, "blocked feeder state shown")
    return tap("Crushed Platinum Ore Tailings", 5)
  end,
  function() return tap(" centrifuge ", PT) end,
  function() return tap(" 2 ", PT + 7) end,          -- batch 2
  function() return tap(" +10 ", PT + 9) end,
  function()
    H.screen("route-assign")
    return tap(" APPLY ", PT + 11)
  end,
  function()
    local c = lastSent()
    check(c.cmd == "assign" and c.process == "centrifuge" and c.batch == 2 and c.priority == 20, "APPLY sends process, batch 2, priority 20")
    return msg(ser.serialize({ type = "router-ack", ok = true, text = "Crushed Platinum Ore Tailings -> centrifuge in batches of 2" }))
  end,
  function()
    check(M.find("in batches of 2", M.H) ~= nil, "ack shown in footer")
    return tap(" ITEMS ", 3)
  end,
  function()
    local c = lastSent()
    check(c.cmd == "items" and c.offset == 0, "ITEMS tab requests page 1")
    return msg(page(c.req, 0, 10))
  end,
  function()
    local c = lastSent()
    check(c.cmd == "items" and c.offset == 10, "client asks for the next page")
    return msg(page(c.req, 10, 40))
  end,
  function()
    check(M.find("absent", 5) ~= nil, "absent item shown as absent")
    check(M.find("×4", 5) ~= nil, "batch column shows ×4")
    return key("c")
  end,
  function() return key("o") end,
  function() return key("p") end,
  function()
    H.screen("route-items")
    check(M.find("search: cop_") ~= nil, "search text shown")
    local RX = math.floor(M.W * 0.56) + 3
    check(M.find("Crushed Copper Ore", 5, RX) ~= nil and M.find("Cooperite Dust", 5, RX) == nil and M.find("Crushed Tin Ore", 5, RX) == nil,
      "list filtered to 'cop' (Cooperite doesn't match)")
    return { "key_down", "kb", 8, 14, "Aaron" }   -- backspace -> "co"
  end,
  function()
    check(M.find("Cooperite Dust", 5) ~= nil, "backspace widened the search to 'co'")
    return tap("Cooperite Dust", 5)
  end,
  function()
    check(M.find(" FORGET ", PT) ~= nil, "FORGET offered on ITEMS tab")
    check(M.find(" REMOVE OVERRIDE ", PT) ~= nil, "REMOVE offered for a screen override")
    local x, y = M.find(" 4 ", PT + 7)
    check(M.bgb[y][x + 1] == 0x2f6fb5, "batch 4 preselected from the item")
    return tap(" FORGET ", PT + 11)
  end,
  function()
    check(lastSent().cmd == "forget" and lastSent().key == GT .. ":2999", "FORGET sent")
    return tap(" CLEAR ABSENT ", PT - 2)
  end,
  function()
    check(M.find("TAP AGAIN TO CLEAR ABSENT") ~= nil, "clear absent asks for confirmation")
    check(lastSent().cmd ~= "forgetAbsent", "nothing sent on first tap")
    return tap(" TAP AGAIN TO CLEAR ABSENT ", PT - 2)
  end,
  function()
    check(lastSent().cmd == "forgetAbsent", "second tap sends forgetAbsent")
    return tap(" ✕ ", PT - 3)
  end,
  function()
    check(M.find("type to search") ~= nil, "✕ cleared the search")
    return tap(" OVERRIDES ", 3)
  end,
  function() return msg(ovMsg) end,
  function() return tap("Stone Dust", 5) end,
  function()
    H.screen("route-overrides")
    return tap(" REMOVE OVERRIDE ", PT + 11)
  end,
  function()
    check(lastSent().cmd == "unassign" and lastSent().key == GT .. ":7002", "REMOVE OVERRIDE sent unassign")
    return tap("Cinnabar Dust", 5)
  end,
  function()
    check(M.find(" REMOVE OVERRIDE ", PT) == nil and M.find(" FORGET ", PT) == nil, "cfg override: no remove/forget")
    check(M.find("set in prism.cfg", PT) ~= nil, "cfg source noted")
    return tap(" QUIT ", M.H)
  end,
}
M.onPull = function(n)
  if n <= #scales then return msg(statusWith(100 + n, scales[n])) end
  local s = steps[n - #scales]
  if s then return s() end
  return { "interrupted" }
end
assert(loadfile(H.SRC .. "/prism-control.lua"))()
check(#stderr == 0, "control exited cleanly " .. table.concat(stderr))
check(M.oob == 0, "no drawing outside the screen (" .. tostring(M.oobAt) .. ")")
H.done()
