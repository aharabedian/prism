-- test_process_page.lua: tapping a process card turns the right side into its page. The router's queue command
-- (rank order, what each item is doing, shared items both ways); the page: summary, BACKLOG chart, MACHINES bands
-- from the screen's own readings, QUEUE, OUTPUTS, sharing and its buttons; CLOSE goes back to the lists.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check
local ser = M.serialization
local computer = require("computer")

local GT = "gregtech:gt.metaitem.01"
local function item(d, label, size) return { name = GT, damage = d, label = label, size = size } end
M.items = {
  item(5002, "Crushed Nickel Ore", 600), item(5001, "Crushed Platinum Ore", 96),
  item(5003, "Crushed Iron Ore", 500), item(5004, "Crushed Tin Ore", 100),
}
M.stocker("st111111-1111")
M.machine("ow01", { isMachineActive = true, isWorkAllowed = true, getEUStored = 9000, getEUMaxStored = 10000 })
M.machine("ow02", { isMachineActive = false, isWorkAllowed = true, getEUStored = 9000, getEUMaxStored = 10000 })
local cfg = H.config("pp", [[
return { modemPort = 4242, slotsPerBus = 1,
  buses = { { address = "eb11", side = sides.north, process = "wash", name = "Washer bus" } },
  stockers = { { address = "st11", process = "chembath", name = "Bath" } },
  machines = { { address = "ow01", process = "wash", name = "Washer A" }, { address = "ow02", process = "wash", name = "Washer B" } },
  processes = { chembath = { overflow = 100 } },
  rules = { { pattern = "^Crushed Platinum Ore$", process = "chembath" },
            { pattern = "^Crushed Nickel Ore$", process = "chembath", fallback = "wash" },
            { pattern = "^Crushed .+ Ore$", process = "wash" } } }
]])
local function cmd(t) return { "modem_message", "x", "gui", 4242, 2, ser.serialize(t) } end
M.onPull = function(n)
  if n == 2 then return cmd({ cmd = "queue", process = "wash", req = 7 }) end
  if n == 3 then return cmd({ cmd = "queue", process = "chembath", req = 8 }) end
  if n > 3 and computer.uptime() > 12 then return { "interrupted" } end
end
H.run("prism.lua", cfg)
local status, queues, machinesMsg = nil, {}, nil
for _, s in ipairs(M.sent) do
  local m = ser.unserialize(s.data)
  if m.type == "router-status" then status = m end
  if m.type == "router-queue" then queues[m.process] = m end
  if m.type == "router-machines" then machinesMsg = m end
end
local wq, cq = queues.wash, queues.chembath
check(wq and wq.req == 7 and wq.total == 3 and wq.list[1].label == "Crushed Nickel Ore" and wq.list[2].label == "Crushed Iron Ore",
  "queue: the process's items in rank order, a shared one included")
check(wq.list[1].now == "shared from chembath; on Washer bus (slot 1)" and wq.list[1].level == "ok",
  "a shared item says where it came from and where it is")
check(wq.list[2].now == "rank 2; outputs hold 1" and wq.list[3].now == "rank 3; outputs hold 1", "ranked below what the outputs hold")
check(cq.list[1].now == "on Bath (slot 1); ↷ wash" and cq.list[2].now == "on Bath (slot 2)", "the sharing process says it's shared")

------------------------------------------------ the screen
M.sent = {}
local RX = math.floor(M.W * 0.56) + 3
local function tap(text, minY, minX)
  local x, y = M.find(text, minY, minX)
  assert(x, "can't find '" .. text .. "' on screen")
  return { "touch", "screen", x + 1, y, 0, "Aaron" }
end
local function msg(t) return { "modem_message", "x", "router-addr", 4242, 4, ser.serialize(t) } end
local function lastSent() return ser.unserialize(M.sent[#M.sent].data) end
local function statusAt(cycle, wash)
  local s = ser.unserialize(ser.serialize(status))
  s.cycles = cycle
  s.processes.wash.items = wash
  return s
end
local seen = {}
local steps = {}
for i = 1, 8 do steps[#steps + 1] = function() return msg(statusAt(10 + i, 400 + i * 100)) end end
for _ = 1, 3 do steps[#steps + 1] = function() return msg(machinesMsg) end end
steps[#steps + 1] = function() return tap("wash", 5) end
steps[#steps + 1] = function()
  local c = lastSent()
  seen.asked = c.cmd == "queue" and c.process == "wash"
  seen.waiting = M.find("asking the router ...", 5, RX) ~= nil
  local q = ser.unserialize(ser.serialize(wq))
  q.req = c.req
  return msg(q)
end
steps[#steps + 1] = function()
  H.screen("process-page")
  seen.title = M.find("PROCESS wash", 3, RX) ~= nil and M.find(" UNASSIGNED ", 3, RX) == nil
  seen.chart = M.find("BACKLOG", 5, RX) ~= nil and M.find("1200", 5, RX) ~= nil and M.find("now", 5, RX) ~= nil
  local _, ay = M.find("Washer A", 5, RX)
  local _, by = M.find("Washer B", 5, RX)
  seen.bands = ay and by and M.row(ay):find("█", 1, true) and M.row(ay):find("busy 100%", 1, true)
    and M.row(by):find("busy 0%", 1, true)
  local x = ay and M.find("█", ay, RX)
  seen.green = x and M.fgb[ay][x] == require("prism.control.ui").C.good
  seen.queue = M.find("shared from chembath; on Washer", 5, RX) ~= nil
    and M.find("rank 2; outputs hold 1", 5, RX) ~= nil
  seen.outputs = M.find("OUTPUTS", 5, RX) ~= nil and M.find("Washer bus", M.H - 9, RX) ~= nil
  seen.share = M.find("Fallbacks: never shared", M.H - 6, RX) ~= nil
  return tap(" CLOSE ", M.H - 3, RX)
end
steps[#steps + 1] = function()
  seen.closed = M.find("PROCESS wash", 3, RX) == nil and M.find(" UNASSIGNED ", 3, RX) ~= nil
  return tap(" QUIT ", M.H)
end
local n = 0
M.onPull = function()
  n = n + 1
  local f = steps[n]
  if f then return f() end
  return { "interrupted" }
end
H.run("prism-control.lua")
check(seen.asked and seen.waiting, "tapping a card asks for its queue")
check(seen.title, "the right side becomes the process's page")
check(seen.chart, "BACKLOG charts the screen's samples, with the highest and now")
check(seen.bands and seen.green, "MACHINES: a band per machine, green while working, and its busy share")
check(seen.queue, "QUEUE: what each item is doing")
check(seen.outputs and seen.share, "OUTPUTS and sharing at the bottom")
check(seen.closed, "CLOSE goes back to the lists")

H.done()
