-- test_supplies.lua: supplies a process needs. A fluid read from another ME network (getFluidsInNetwork, which is
-- unverified in game): below its min for a minute, the process shares every item with a fallback, its stall and
-- idle alerts give way to one supply warn, status says so; back above for a minute, it stops. prism-discover
-- --fluids lists each network's fluids. The screen: the card, the process page.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check
local ser = M.serialization
local computer = require("computer")

local GT = "gregtech:gt.metaitem.01"
M.items = { { name = GT, damage = 5002, label = "Crushed Nickel Ore", size = 600 }, { name = GT, damage = 5001, label = "Crushed Platinum Ore", size = 96 } }
local bath = M.stocker("st111111-1111")
local washer = M.stocker("st222222-2222")
M.machine("cb01", { isMachineActive = false, isWorkAllowed = true, getEUStored = 9000, getEUMaxStored = 10000 })
local acid = { name = "sulfuricacid", label = "Sulfuric Acid", amount = 12000 }
M.network("ma1n0000-0000", { { name = GT, damage = 1, label = "Iron Dust", size = 64 } }, { acid, { name = "water", label = "Water", amount = 500000 } })
local cfg = H.config("sp", [[
return { modemPort = 4242, network = "me00", idleAlert = 10, stallAfter = 30, stuckAfter = false,
  stockers = { { address = "st11", process = "chembath", name = "Bath" }, { address = "st22", process = "wash", name = "Washer" } },
  machines = { { address = "cb01", process = "chembath", name = "Chem Bath" } },
  supplies = { { process = "chembath", fluid = "Sulfuric Acid", min = 8000, network = "ma1n" } },
  rules = { { pattern = "^Crushed Platinum Ore$", process = "chembath" },
            { pattern = "^Crushed .+ Ore$", process = "chembath", fallback = "wash" } } }
]])
local function lastOf(kind)
  for i = #M.sent, 1, -1 do
    local m = ser.unserialize(M.sent[i].data)
    if m.type == kind then return m end
  end
end
local function stocked(s) local n = 0; for i = 1, 16 do if s.slots[i] then n = n + 1 end end; return n end
local cp = {}
M.onPull = function()
  local t = computer.uptime()
  if t >= 18 and not cp.before then cp.before = { status = lastOf("router-status"), washer = stocked(washer) }; acid.amount = 2100 end
  if t >= 50 and not cp.held then cp.held = { status = lastOf("router-status"), washer = stocked(washer) } end
  if t >= 110 and not cp.low then
    cp.low = { status = lastOf("router-status"), washer = stocked(washer), bath = stocked(bath) }
    acid.amount = 9000
  end
  if t >= 200 then cp.back = { status = lastOf("router-status"), washer = stocked(washer) }; return { "interrupted" } end
end
H.run("prism.lua", cfg)
local function ids(st) local out = {} for _, a in ipairs(st.alerts) do out[a.id] = a end return out end
local b = cp.before.status.processes.chembath
check(b.supply and b.supply.amount == 12000 and b.supply.min == 8000 and not b.supply.low and cp.before.washer == 0,
  "above its min: the amount is shown, nothing shared")
check(not cp.held.status.processes.chembath.supply.low and cp.held.washer == 0, "below for less than a minute: nothing yet")
local l = cp.low.status.processes.chembath
check(l.supply.low and l.supply.amount == 2100 and l.supply.lowFor >= 1, "below for a minute: low")
check(cp.low.washer == 1 and cp.low.bath == 2, "its items with a fallback are shared with wash (the nickel)")
local a = ids(cp.low.status)
check(a["supply:chembath"] and a["supply:chembath"].text == "chembath low on Sulfuric Acid: 2100 of 8000 L"
  and not a["idle:Chem Bath"] and not a["stall:chembath"], "one supply warn instead of its idle and stall alerts")
check(not cp.back.status.processes.chembath.supply.low and cp.back.washer == 0 and not ids(cp.back.status)["supply:chembath"],
  "back above for a minute: sharing and the warn stop")

------------------------------------------------ prism-discover --fluids
local lines = {}
local realPrint = print
print = function(...) local p = {} for i = 1, select("#", ...) do p[#p + 1] = tostring((select(i, ...))) end lines[#lines + 1] = table.concat(p, "\t") end
H.run("prism-discover.lua", "--fluids")
print = realPrint
local out = table.concat(lines, "\n")
check(out:find("Fluids in each ME network", 1, true) and out:find("me_controller ma1n0000-0000", 1, true)
  and out:find("2 fluid(s), the call took", 1, true) and out:find("Sulfuric Acid", 1, true), "--fluids lists each network's fluids and the time taken")
lines = {}
print = function(...) lines[#lines + 1] = table.concat({ ... }, "\t") end
H.run("prism-discover.lua")
print = realPrint
check(not table.concat(lines, "\n"):find("Fluids in each", 1, true), "only with --fluids")

------------------------------------------------ the screen
M.sent = {}
local RX = math.floor(M.W * 0.56) + 3
local function msg(t) return { "modem_message", "x", "router-addr", 4242, 4, ser.serialize(t) } end
local seen = {}
local steps = {
  function() return msg(cp.low.status) end,
  function()
    local _, y = M.find("↷ chembath", 5)
    seen.card = y and M.row(y + 2):find("Sulfuric Acid low: 2100 of 8000 L", 1, true) ~= nil
    local x
    x, y = M.find("chembath", 5)
    return { "touch", "screen", x + 1, y, 0, "Aaron" }
  end,
  function()
    H.screen("supplies-page")
    seen.page = M.find("⚠ Needs Sulfuric Acid: 2100 of 8000 L, low for", 3, RX) ~= nil
    return { "interrupted" }
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
check(seen.card, "the card says the supply is low")
check(seen.page, "the process page says what it needs and how long it has been low")

H.done()
