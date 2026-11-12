-- test_fallbacks.lua: overflow to a fallback process, items that never spill, diverting a process from the
-- screen (persisted), and the fields status, items, rules and overrides carry.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check
local ser = M.serialization

local GT = "gregtech:gt.metaitem.01"
local function item(d, label, size) return { name = GT, damage = d, label = label, size = size } end
M.items = {
  item(5001, "Crushed Platinum Ore", 900),   -- no fallback: chembath only
  item(5002, "Crushed Nickel Ore", 600),     -- may fall back to wash
  item(5003, "Crushed Tin Ore", 300),        -- may fall back to wash
}
M.proxies["db000000-aaaa"] = nil
local bath = M.stocker("st111111-1111")
local washer = M.stocker("st222222-2222")

local logged = {}
local realWrite = io.write
io.write = function(...) for _, s in ipairs({ ... }) do logged[#logged + 1] = tostring(s) end end

local cfg = H.config("fb", [[
return { modemPort = 4242,
  stockers = { { address = "st11", process = "chembath", name = "Bath" },
               { address = "st22", process = "wash", name = "Washer" } },
  processes = { chembath = { overflow = 1500 } },
  rules = { { pattern = "^Crushed Platinum Ore$", process = "chembath" },
            { pattern = "^Crushed .+ Ore$", process = "chembath", fallback = "wash" } } }
]])

local function stocked(s)
  local out = {}
  for i = 1, 16 do if s.slots[i] then out[#out + 1] = s.slots[i].damage end end
  table.sort(out)
  return table.concat(out, " ")
end
local function cmd(t) return { "modem_message", "x", "gui", 4242, 2, ser.serialize(t) } end
local function lastOf(kind)
  for i = #M.sent, 1, -1 do
    local m = ser.unserialize(M.sent[i].data)
    if m.type == kind then return m end
  end
end

local cp = {}
M.onPull = function(n)
  if n == 1 then
    cp[1] = { bath = stocked(bath), washer = stocked(washer), status = lastOf("router-status") }
    return cmd({ cmd = "divert", process = "chembath", on = true })
  elseif n == 2 then
    cp[2] = { bath = stocked(bath), washer = stocked(washer), status = lastOf("router-status"), ack = lastOf("router-ack") }
    return cmd({ cmd = "items", offset = 0, req = 1 })
  elseif n == 3 then
    cp[3] = { items = lastOf("router-items") }
    return { "interrupted" }
  end
end
H.run("prism.lua", cfg)

local cp1, cp2, cp3 = cp[1], cp[2], cp[3]
check(cp[1].bath == "5001 5002 5003" and cp[1].washer == "5003",
  "over the overflow, the lowest-ranked item with a fallback is stocked by both processes")
local p1 = cp[1].status.processes
check(p1.chembath.overflow == 1500 and p1.chembath.spilled == 300 and p1.chembath.items == 1800
  and p1.wash.items == 300, "status: overflow, items shared, and the shared item waiting for both")
check(cp[2].ack.ok and cp[2].bath == "5001 5002 5003" and cp[2].washer == "5002 5003",
  "diverted: everything with a fallback is shared; items without one stay")
check(cp[2].status.processes.chembath.diverted == true, "status says the process is diverted")
local byKey = {}
for _, it in ipairs(cp[3].items.list) do byKey[it.key] = it end
check(byKey[GT .. ":5002"].fallback == "wash" and byKey[GT .. ":5002"].spilled
  and byKey[GT .. ":5001"].fallback == nil and not byKey[GT .. ":5001"].spilled, "items carry fallback and spilled")
check(H.readTable(H.TMP .. "/fb-diverts.cfg").chembath == true, "the divert is saved in prism-diverts.cfg")

------------------------------------------------ restart: still diverted; undo; assign with a fallback
M.sent = {}
cp = {}
local pulls = 0
M.onPull = function()
  pulls = pulls + 1
  local n = pulls
  if n == 1 then
    cp[1] = { bath = stocked(bath), washer = stocked(washer) }
    return cmd({ cmd = "divert", process = "chembath", on = false })
  elseif n == 2 then
    cp[2] = { bath = stocked(bath), washer = stocked(washer) }
    return cmd({ cmd = "assign", key = GT .. ":5001", process = "chembath", fallback = "wash", label = "Crushed Platinum Ore" })
  elseif n == 3 then
    return cmd({ cmd = "overrides" })
  elseif n == 4 then
    cp[4] = { ov = lastOf("router-overrides") }
    return cmd({ cmd = "rules" })
  elseif n == 5 then
    cp[5] = { rules = lastOf("router-rules") }
    return { "interrupted" }
  end
end
H.run("prism.lua", cfg)
io.write = realWrite
local log = table.concat(logged)

check(cp[1].washer == "5002 5003", "a divert survives a restart")
check(cp[2].bath == "5001 5002 5003" and cp[2].washer == "5003", "undoing it goes back to overflow only")
check(cp[4].ov.list[1].fallback == "wash", "a screen override keeps its fallback")
check(cp[5].rules.list[2].fallback == "wash" and cp[5].rules.list[1].fallback == nil, "rules carry their fallback")
check(log:find("chembath: sharing 1 item type(s) with fallbacks", 1, true) and log:find("chembath diverted: sharing", 1, true)
  and log:find("chembath no longer diverted", 1, true), "sharing and diverting are logged")

------------------------------------------------ control screen: process panel, divert, fallback row
M.sent = {}
local stderr = {}
io.stderr = { write = function(_, s) stderr[#stderr + 1] = s end }
local PT = M.H - 14
local RX = math.floor(M.W * 0.56) + 3
local function tap(text, minY, minX)
  local x, y = M.find(text, minY, minX)
  assert(x, "can't find '" .. text .. "' on screen")
  return { "touch", "screen", x + 1, y, 0, "Aaron" }
end
local function lastSent() return ser.unserialize(M.sent[#M.sent].data) end
local function msg(t) return { "modem_message", "x", "router-addr", 4242, 4, ser.serialize(t) } end
local spilling, diverted, items = cp1.status, cp2.status, cp3.items
spilling.cycles, diverted.cycles = 501, 502

local steps = {
  function() return msg(spilling) end,
  function()
    H.screen("fallback-dashboard")
    check(M.find("↷ chembath") ~= nil and M.find("↷ chembath") < RX, "a process sending items to fallbacks is marked")
    return tap("↷ chembath", 3)
  end,
  function()
    H.screen("fallback-process")
    check(M.find("PROCESS chembath", PT) and M.find("Overflow: past 1500", PT) and M.find("↷ 300 items shared with their fallbacks", PT),
      "tapping a process shows its overflow and what's spilling")
    return tap(" DIVERT TO FALLBACKS ", PT + 11)
  end,
  function()
    local s = lastSent()
    check(s.cmd == "divert" and s.process == "chembath" and s.on == true, "DIVERT sent divert on")
    return msg(diverted)
  end,
  function()
    check(M.find("DIVERTED", PT) and M.find(" STOP DIVERTING ", PT + 11), "a diverted process offers STOP DIVERTING")
    check(M.find("↷ 900 items shared with their fallbacks", PT), "diverted items are shared too")
    return tap(" STOP DIVERTING ", PT + 11)
  end,
  function()
    check(lastSent().cmd == "divert" and lastSent().on == false, "STOP DIVERTING sent divert off")
    return tap(" CLOSE ", PT + 11)
  end,
  function()
    check(M.find("PROCESS chembath", PT) == nil, "CLOSE closes the process panel")
    return tap(" ITEMS ", 3)
  end,
  function() items.req = lastSent().req; return msg(items) end,
  function()
    check(M.find("chembath›wash", 5, RX) ~= nil, "the items list shows process›fallback")
    return tap("Crushed Nickel Ore", 5, RX)
  end,
  function()
    H.screen("fallback-route")
    check(M.find("Fallback", PT) ~= nil, "the route panel has a Fallback row")
    local x, y = M.find(" wash ", PT + 7, RX)
    check(y == PT + 7 and M.bgb[y][x] == require("prism.control.ui").C.btnOn, "the item's fallback is selected")
    return tap(" none ", PT + 7, RX)
  end,
  function() return tap(" APPLY ", PT + 11) end,
  function()
    local s = lastSent()
    check(s.cmd == "assign" and s.key == GT .. ":5002" and s.fallback == nil, "fallback none: assign without one")
    return tap("Crushed Platinum Ore", 5, RX)
  end,
  function() return tap(" wash ", PT + 7, RX) end,
  function() return tap(" APPLY ", PT + 11) end,
  function()
    local s = lastSent()
    check(s.cmd == "assign" and s.key == GT .. ":5001" and s.process == "chembath" and s.fallback == "wash",
      "picking a fallback sends it")
    return tap("Crushed Tin Ore", 5, RX)
  end,
  function() return tap(" MAKE RULE ", PT + 11) end,
  function()
    H.screen("fallback-rule")
    local x, y = M.find(" wash ", PT + 7, RX)
    check(y == PT + 7 and M.bgb[y][x] == require("prism.control.ui").C.btnOn, "MAKE RULE keeps the fallback")
    return tap(" SAVE ", PT + 11)
  end,
  function()
    local s = lastSent()
    check(s.cmd == "setRule" and s.fallback == "wash", "SAVE sends the rule's fallback")
    return tap(" QUIT ", M.H)
  end,
}
local pulls2 = 0
M.onPull = function()
  pulls2 = pulls2 + 1
  local st = steps[pulls2]
  if st then return st() end
  return { "interrupted" }
end
assert(loadfile(H.SRC .. "/prism-control.lua"))()
check(#stderr == 0, "control exited cleanly " .. table.concat(stderr))
check(M.oob == 0, "no drawing outside the screen (" .. tostring(M.oobAt) .. ")")
H.done()
