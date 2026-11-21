-- test_run_next.lua: RUN NEXT. runNext puts an item first in its process (its outputs take it before anything
-- else) until it ends, kept in prism-next.cfg across a restart; it ends by itself (logged) or with STOP NEXT.
-- explain, items and overrides say so. The screen: RUN NEXT / STOP NEXT in ROUTE ITEM, "next" in OVERRIDES.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check
local ser = M.serialization
local computer = require("computer")

local GT = "gregtech:gt.metaitem.01"
M.items = { { name = GT, damage = 1, label = "Iron Dust", size = 9000 }, { name = GT, damage = 2, label = "Titanium Dust", size = 256 } }
local cfg = H.config("rn", [[
return { modemPort = 4242, stuckAfter = false,
  buses = { { address = "eb11", side = sides.north, process = "ebf", name = "EBF bus" } }, slotsPerBus = 1,
  rules = { { pattern = "Dust$", process = "ebf" } } }
]])
local function cmd(t) return { "modem_message", "x", "gui", 4242, 2, ser.serialize(t) } end
local function bus() local s = M.busHosts["eb111111-1111"][2][1]; return s and s.label end
local function lastOf(kind)
  for i = #M.sent, 1, -1 do
    local m = ser.unserialize(M.sent[i].data)
    if m.type == kind then return m end
  end
end
local cp = {}
M.onPull = function()
  local t = computer.uptime()
  if t >= 10 and not cp.before then
    cp.before = bus()
    return cmd({ cmd = "runNext", key = GT .. ":2", on = true, minutes = 1, player = "Aaron" })
  end
  if cp.before and not cp.asked then
    cp.asked = true
    cp.during = bus()
    return cmd({ cmd = "explain", key = GT .. ":2", req = 1 })
  end
  if cp.asked and not cp.items then cp.items = true; return cmd({ cmd = "items", req = 2 }) end
  if t >= 90 then
    cp.after = bus()
    return { "interrupted" }
  end
end
H.run("prism.lua", cfg)
local items = lastOf("router-items")
local ti
for _, r in ipairs(items.list) do if r.key == GT .. ":2" then ti = r end end
check(cp.before == "Iron Dust", "before: the biggest stack goes first")
check(cp.during == "Titanium Dust", "RUN NEXT: titanium takes the bus")
local ex = lastOf("router-explain")
check(ex.text == "Run next (1m left): On EBF bus (slot 1).", "explain starts with Run next and the time left")
check(ti.next and ti.next > 0 and ti.next <= 60, "items carry the time left")
check(cp.after == "Iron Dust", "when it ends, iron goes first again")
local log = H.readTable(H.TMP .. "/rn-log.cfg")
local texts = {}
for _, e in ipairs(log) do texts[#texts + 1] = e.text end
check(table.concat(texts, "|"):find("run next: Titanium Dust for 1m", 1, true) and table.concat(texts, "|"):find("run next ended: Titanium Dust", 1, true),
  "the log has it starting and ending")

------------------------------------------------ the screen
M.sent = {}
local RX = math.floor(M.W * 0.56) + 3
local PT = M.H - 14
local function tap(text, minY, minX)
  local x, y = M.find(text, minY, minX)
  assert(x, "can't find '" .. text .. "' on screen")
  return { "touch", "screen", x + 1, y, 0, "Aaron" }
end
local function msg(t) return { "modem_message", "x", "router-addr", 4242, 4, ser.serialize(t) } end
local function lastSent() return ser.unserialize(M.sent[#M.sent].data) end
local seen = {}
local steps = {
  function()
    return msg({ type = "router-status", cycles = 1, interval = 5, processes = {}, buses = {}, feeders = {}, machines = {},
      unassigned = {}, unassignedCount = 0, catalogCount = 2, knownProcesses = { "ebf" }, alerts = {} })
  end,
  function() return tap(" ITEMS ", 3, RX) end,
  function() items.req = lastSent().req; return msg(items) end,
  function() return tap("Iron Dust", 5, RX) end,
  function() return tap(" RUN NEXT ", PT + 11, RX) end,
  function()
    local c = lastSent()
    seen.sent = c.cmd == "runNext" and c.key == GT .. ":1" and c.on == true and c.minutes == 30
    seen.stop = M.find(" STOP NEXT ", PT + 11, RX) ~= nil
    return tap(" STOP NEXT ", PT + 11, RX)
  end,
  function()
    local c = lastSent()
    seen.stopped = c.cmd == "runNext" and c.on == false
    return tap(" OVERRIDES ", 3, RX)
  end,
  function()
    return msg({ type = "router-overrides", now = M.epoch, list = { { key = GT .. ":2", label = "Titanium Dust", process = "ebf",
      source = "gui", by = "Aaron", at = M.epoch, next = 1440 } } })
  end,
  function()
    local _, y = M.find("Titanium Dust", 5, RX)
    seen.ov = y and M.row(y):find(" next", 1, true) ~= nil
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
check(seen.sent, "RUN NEXT sends runNext for 30 minutes")
check(seen.stop and seen.stopped, "then the button is STOP NEXT, which sends it off")
check(seen.ov, "OVERRIDES shows next in the priority column")

H.done()
