-- test_below_batch.lua: items below a full batch. router-status counts them per process (below); the screen's
-- cards say "N below batch", and ITEMS' BELOW BATCH lists only those items with how many more each needs.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check
local ser = M.serialization

local GT = "gregtech:gt.metaitem.01"
local function item(d, label, size) return { name = GT, damage = d, label = label, size = size } end
M.items = {
  item(2834, "End Stone Dust", 25), item(2835, "Netherrack Dust", 31), item(2836, "Basalt Dust", 80),
  item(2019, "Bauxite Dust", 38), item(5001, "Crushed Iron Ore", 500),
}
M.stocker("st111111-1111")
M.stocker("st222222-2222")
local cfg = H.config("bb", [[
return { modemPort = 4242,
  buses = { { address = "eb11", side = sides.north, process = "wash", name = "Washer bus" } },
  stockers = { { address = "st11", process = "centrifuge", name = "Centrifuge" },
               { address = "st22", process = "electrolyze", name = "Electrolyzer" } },
  rules = { { pattern = "^Crushed .+ Ore$", process = "wash" },
            { pattern = "^Bauxite Dust$", process = "electrolyze", batch = 39 },
            { pattern = "Dust$", process = "centrifuge", batch = 36 } } }
]])
local function cmd(t) return { "modem_message", "x", "gui", 4242, 2, ser.serialize(t) } end
M.onPull = function(n)
  if n == 1 then return cmd({ cmd = "items", offset = 0, req = 1 }) end
  return { "interrupted" }
end
H.run("prism.lua", cfg)
local status, items
for _, s in ipairs(M.sent) do
  local m = ser.unserialize(s.data)
  if m.type == "router-status" then status = m end
  if m.type == "router-items" then items = m end
end
local p = status.processes
check(p.centrifuge.below == 56 and p.centrifuge.items == 136, "centrifuge: 25 + 31 below their batch of 36, Basalt can run")
check(p.electrolyze.below == 38 and p.wash.below == nil, "a whole process below; none below for batch-1 items")

------------------------------------------------ the screen
M.sent = {}
local function tap(text, minY, minX)
  local x, y = M.find(text, minY, minX)
  assert(x, "can't find '" .. text .. "' on screen")
  return { "touch", "screen", x + 1, y, 0, "Aaron" }
end
local function msg(t) return { "modem_message", "x", "router-addr", 4242, 4, ser.serialize(t) } end
local function lastSent() return ser.unserialize(M.sent[#M.sent].data) end
local RX = math.floor(M.W * 0.56) + 3
local seen = {}
local steps = {
  function() return msg(status) end,
  function()
    local _, y = M.find("centrifuge", 5)
    seen.card = y and M.row(y + 1):find("56 below batch", 1, true) ~= nil
    local _, ey = M.find("electrolyze", 5)
    seen.card2 = ey and M.row(ey + 1):find("38 below batch", 1, true) ~= nil
    local _, wy = M.find("wash", 5)
    seen.none = wy and not M.row(wy + 1):find("below batch", 1, true)
    return tap(" ITEMS ", 3)
  end,
  function() local c = lastSent(); items.req = c.req; return msg(items) end,
  function()
    seen.all = M.find("Crushed Iron Ore", 5, RX) ~= nil and M.find("Basalt Dust", 5, RX) ~= nil
    return tap(" BELOW BATCH ", M.H - 16, RX)
  end,
  function()
    H.screen("below-batch")
    seen.only = M.find("End Stone Dust", 5, RX) and M.find("Netherrack Dust", 5, RX) and M.find("Bauxite Dust", 5, RX)
      and not M.find("Basalt Dust", 5, RX) and not M.find("Crushed Iron Ore", 5, RX)
    local _, y = M.find("End Stone Dust", 5, RX)
    seen.needs = y and M.row(y):find("×36   +11", 1, true) ~= nil and M.find("needs", 4, RX) ~= nil
    seen.info = M.find("3 items below their batch  ·  94 in all", M.H - 17, RX) ~= nil
    return tap(" BELOW BATCH ", M.H - 16, RX)
  end,
  function()
    seen.back = M.find("Crushed Iron Ore", 5, RX) ~= nil
    return tap(" QUIT ", M.H)
  end,
}
local n = 0
M.onPull = function()
  n = n + 1
  local f = steps[n]
  if f then return f() end
  return { "interrupted" }
end
H.run("prism-control.lua")
check(seen.card and seen.card2 and seen.none, "each card's outputs line says how many items wait below their batch")
check(seen.all, "ITEMS lists everything at first")
check(seen.only, "BELOW BATCH lists only the items with less than one batch")
check(seen.needs, "with how many more each needs")
check(seen.info, "and how many there are")
check(seen.back, "tapping it again lists everything")

H.done()
