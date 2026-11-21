-- test_throughput.lua: items out and in per process. router-status carries outRate, inRate (per minute over 5
-- minutes) and busy (machines working, last hour); LENS gets prism_items_out_total; the screen's cards show
-- "N/min  ·  clears T" or "growing", and the process panel the rates and what the busy share means.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check
local ser = M.serialization
local computer = require("computer")
local codec = require("prism.lens.codec")

local GT = "gregtech:gt.metaitem.01"
local iron = { name = GT, damage = 5001, label = "Crushed Iron Ore", size = 9000 }
local dust = { name = GT, damage = 2834, label = "Iron Dust", size = 100 }
M.items = { iron, dust }
M.stocker("st111111-1111")
M.stocker("st222222-2222")
M.machine("ow01", { isMachineActive = true, isWorkAllowed = true, getEUStored = 9000, getEUMaxStored = 10000 })
M.machine("ow02", { isMachineActive = true, isWorkAllowed = true, getEUStored = 9000, getEUMaxStored = 10000 })
local cfg = H.config("tp", [[
return { modemPort = 4242, interval = 5, lensPort = 4243, lensNode = "prism-ore",
  stockers = { { address = "st11", process = "wash", name = "Washers" }, { address = "st22", process = "export", name = "Main net" } },
  machines = { { address = "ow01", process = "wash", name = "Washer A" }, { address = "ow02", process = "wash", name = "Washer B" } },
  rules = { { pattern = "^Crushed .+ Ore$", process = "wash" }, { pattern = "Dust$", process = "export" } } }
]])
-- every 5 s scan: 18 iron leaves (216/min), 10 dust arrives and none leaves (growing)
local lastT = -1
M.onPull = function()
  local t = computer.uptime()
  if t >= 300 then return { "interrupted" } end
  if math.floor(t / 5) ~= lastT then
    lastT = math.floor(t / 5)
    if t > 0 then iron.size = iron.size - 18; dust.size = dust.size + 10 end
  end
end
H.run("prism.lua", cfg)
local status, outTotal
local asm = codec.assembler()
for _, s in ipairs(M.sent) do
  if s.port == 4242 then
    local m = ser.unserialize(s.data)
    if m.type == "router-status" then status = m end
  else
    local m = codec.decode(s.data)
    local whole = m and asm:add(m, 0)
    if whole and whole.kind == "snapshot" then
      for _, x in ipairs(whole.samples or {}) do
        if x[1] == "prism_items_out_total" and (x[3] or {}).process == "wash" then outTotal = x[2] end
      end
    end
  end
end
local w, e = status.processes.wash, status.processes.export
check(w.outRate and math.abs(w.outRate - 216) <= 4 and w.inRate == 0, "wash: about 216 out a minute, none in (" .. tostring(w.outRate) .. ")")
check(e.outRate == 0 and math.abs(e.inRate - 120) <= 3, "export: 120 in a minute, none out")
check(w.busy == 1 and e.busy == nil, "busy: both washers working; no machines for export")
check(outTotal and outTotal >= 18 * 50, "LENS: prism_items_out_total counts what left wash (" .. tostring(outTotal) .. ")")

------------------------------------------------ the screen
M.sent = {}
local function tap(text, minY)
  local x, y = M.find(text, minY)
  assert(x, "can't find '" .. text .. "' on screen")
  return { "touch", "screen", x + 1, y, 0, "Aaron" }
end
local function msg(t) return { "modem_message", "x", "router-addr", 4242, 4, ser.serialize(t) } end
local seen = {}
local slow = ser.unserialize(ser.serialize(status))
slow.cycles = slow.cycles + 1
slow.processes.wash.busy = 0.35
local steps = {
  function() return msg(status) end,
  function()
    local _, y = M.find("wash", 5)
    local mins = math.floor(w.items / (w.outRate - w.inRate))
    seen.clears = y and M.row(y + 2):find(("%d/min  ·  clears %dm"):format(w.outRate, mins), 1, true) ~= nil
    local _, ey = M.find("export", 5)
    seen.growing = ey and M.row(ey + 1):find("0/min  ·  growing " .. e.inRate .. "/min", 1, true) ~= nil
    return tap("wash", 5)
  end,
  function()
    H.screen("throughput-panel")
    seen.rates = M.find(("Out %d/min  ·  in 0/min  (last 5 min)  ·  clears in"):format(w.outRate), 3) ~= nil
    seen.limit = M.find("Machines busy 100% in the last hour: they are the limit.", 3) ~= nil
    return msg(slow)
  end,
  function()
    seen.slow = M.find("Machines busy 35% in the last hour while items wait", 3) ~= nil
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
check(seen.clears, "the wash card: out a minute and how long until it clears")
check(seen.growing, "the export card: growing, in yellow")
check(seen.rates, "the process page: out, in and time to clear")
check(seen.limit and seen.slow, "and what the machines' busy share means")

H.done()
