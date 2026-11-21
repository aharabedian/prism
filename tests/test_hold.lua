-- test_hold.lua: putting a process on hold. The hold command clears its outputs (buses, stockers, feeders get
-- nothing), turns off its stall and idle alerts, says so in status and explain, survives a restart, and RESUME
-- sets the outputs again. The screen: HOLD / RESUME on the process page, the card's "‖" and HELD line.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check
local ser = M.serialization
local computer = require("computer")

local GT = "gregtech:gt.metaitem.01"
M.items = { { name = GT, damage = 2028, label = "Titanium Dust", size = 256 }, { name = GT, damage = 5001, label = "Crushed Iron Ore", size = 90 } }
local ebf = M.stocker("st111111-1111")
M.machine("eb01", { isMachineActive = false, isWorkAllowed = true, getEUStored = 9000, getEUMaxStored = 10000 })
local cfg = H.config("hd", [[
return { modemPort = 4242, stallAfter = 20, idleAlert = 10,
  stockers = { { address = "st11", process = "ebf", name = "EBF 1" } },
  buses = { { address = "eb11", side = sides.north, process = "wash", name = "Washer bus" } },
  machines = { { address = "eb01", process = "ebf", name = "EBF 1" } },
  rules = { { pattern = "^Titanium Dust$", process = "ebf" }, { pattern = "^Crushed", process = "wash" } } }
]])
local function cmd(t) return { "modem_message", "x", "gui", 4242, 2, ser.serialize(t) } end
local function lastOf(kind)
  for i = #M.sent, 1, -1 do
    local m = ser.unserialize(M.sent[i].data)
    if m.type == kind then return m end
  end
end
local cp = {}
M.onPull = function()
  local t = computer.uptime()
  if t >= 40 and not cp.before then
    cp.before = { slot = ebf.slots[1], status = lastOf("router-status") }
    return cmd({ cmd = "hold", process = "ebf", on = true, player = "Aaron" })
  end
  if cp.before and not cp.ack then
    cp.ack = lastOf("router-ack")
    return cmd({ cmd = "explain", key = GT .. ":2028", req = 1 })
  end
  if t >= 90 then
    cp.after = { slot = ebf.slots[1], status = lastOf("router-status"), explain = lastOf("router-explain") }
    return { "interrupted" }
  end
end
H.run("prism.lua", cfg)
local function alertIds(st) local t = {} for _, a in ipairs(st.alerts) do t[a.id] = true end return t end
check(cp.before.slot and cp.before.slot.damage == 2028, "before: the EBF's stocking bus holds the titanium")
check(alertIds(cp.before.status)["idle:EBF 1"] and alertIds(cp.before.status)["stall:ebf"], "and EBF 1 idle with work waiting raises alerts")
check(cp.ack.ok and cp.after.slot == nil, "hold: its stocking bus is cleared")
local st = cp.after.status
check(not alertIds(st)["idle:EBF 1"] and not alertIds(st)["stall:ebf"], "no stall or idle alerts while held")
check(st.processes.ebf.held and st.processes.ebf.heldBy == "Aaron" and st.processes.ebf.heldFor >= 40, "status: held, by whom, for how long")
check(cp.after.explain.text:find("Held: ebf is on hold (Aaron)", 1, true), "explain says it's held")
check(H.readTable(H.TMP .. "/hd-held.cfg").ebf.by == "Aaron", "kept in prism-held.cfg")

------------------------------------------------ restart: still held; resume
cp = {}
M.sent = {}
M.onPull = function()
  local t = computer.uptime()
  if not cp.started then
    cp.started = t
    return nil
  end
  if t >= cp.started + 10 and not cp.held then
    cp.held = { slot = ebf.slots[1], status = lastOf("router-status") }
    return cmd({ cmd = "hold", process = "ebf", on = false })
  end
  if cp.held and t >= cp.started + 20 then
    cp.resumed = { slot = ebf.slots[1] }
    return { "interrupted" }
  end
end
H.run("prism.lua", cfg)
check(cp.held.slot == nil and cp.held.status.processes.ebf.held, "after a restart it is still held")
check(cp.resumed.slot and cp.resumed.slot.damage == 2028 and H.readTable(H.TMP .. "/hd-held.cfg").ebf == nil,
  "RESUME: the stocking bus gets the titanium again")

------------------------------------------------ the screen
local status = ser.unserialize(ser.serialize(st))
M.sent = {}
local RX = math.floor(M.W * 0.56) + 3
local function tap(text, minY, minX)
  local x, y = M.find(text, minY, minX)
  assert(x, "can't find '" .. text .. "' on screen")
  return { "touch", "screen", x + 1, y, 0, "Aaron" }
end
local function msg(t) return { "modem_message", "x", "router-addr", 4242, 4, ser.serialize(t) } end
local function lastSent() return ser.unserialize(M.sent[#M.sent].data) end
local seen = {}
local unheld = ser.unserialize(ser.serialize(status))
unheld.cycles = unheld.cycles + 1
unheld.processes.ebf.held, unheld.processes.ebf.heldBy, unheld.processes.ebf.heldFor = nil, nil, nil
local steps = {
  function() return msg(unheld) end,
  function() return tap("ebf", 5) end,
  function() return tap(" HOLD ", M.H - 3, RX) end,
  function()
    local c = lastSent()
    seen.sent = c.cmd == "hold" and c.process == "ebf" and c.on == true and c.player == "Aaron"
    return msg(status)
  end,
  function()
    H.screen("hold-page")
    local _, y = M.find("‖ ebf", 5)
    seen.card = y and M.row(y + 2):find("HELD by Aaron", 1, true) and M.row(y + 2):find("outputs cleared", 1, true)
      and not M.row(y + 2):find("is idle", 1, true)
    seen.page = M.find("‖ Held by Aaron for", 3, RX) ~= nil and M.find(" RESUME ", M.H - 3, RX) ~= nil
    return tap(" RESUME ", M.H - 3, RX)
  end,
  function()
    local c = lastSent()
    seen.resume = c.cmd == "hold" and c.on == false
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
check(seen.sent, "HOLD on the process page sends hold, with the player who tapped")
check(seen.card, "the card: ‖ and HELD by Aaron, outputs cleared (not 'is idle')")
check(seen.page, "the page says it's held, and offers RESUME")
check(seen.resume, "RESUME sends hold off")

H.done()
