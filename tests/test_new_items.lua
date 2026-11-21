-- test_new_items.lua: new items. The catalog keeps when each item was first seen; router-status's unassigned rows
-- carry it (with the router's time); unassignedAlert warns about items unassigned that long. The screen: a
-- "seen" column ("new 4m" for the last hour), and a new unassigned item in the footer with one beep.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check
local ser = M.serialization
local computer = require("computer")

local GT = "gregtech:gt.metaitem.01"
M.items = { { name = GT, damage = 1, label = "Nether Quartz", size = 64 }, { name = GT, damage = 5001, label = "Crushed Iron Ore", size = 90 } }
M.stocker("st111111-1111")
local cfg = H.config("ni", [[
return { modemPort = 4242, unassignedAlert = 60,
  stockers = { { address = "st11", process = "wash", name = "Washer" } },
  rules = { { pattern = "^Crushed", process = "wash" } } }
]])
local statuses, added = {}, false
M.onPull = function()
  local t = computer.uptime()
  if t >= 30 and not added then
    added = true
    M.items[#M.items + 1] = { name = GT, damage = 8057, label = "Purified Pile of Tin Dust", size = 60 }
  end
  if t >= 90 then return { "interrupted" } end
end
H.run("prism.lua", cfg)
for _, s in ipairs(M.sent) do
  local m = ser.unserialize(s.data)
  if m.type == "router-status" then statuses[#statuses + 1] = m end
end
local first, last = statuses[1], statuses[#statuses]
local cat = H.readTable(H.TMP .. "/ni-items.cfg")
check(cat[GT .. ":1"].seen >= M.epoch and cat[GT .. ":8057"].seen >= M.epoch + 30, "the catalog keeps when each item was first seen")
local rows = {}
for _, u in ipairs(last.unassigned) do rows[u.label] = u end
check(rows["Purified Pile of Tin Dust"].seen == cat[GT .. ":8057"].seen and last.now >= M.epoch + 85 and last.clockReal,
  "unassigned rows carry it, and the status the router's time")
local function alert(st) for _, a in ipairs(st.alerts) do if a.id == "unassigned" then return a end end end
check(alert(first) == nil and alert(last) and alert(last).text == "1 item unassigned for 1m or more: route it in UNASSIGNED",
  "unassignedAlert: a warn for items unassigned that long (the tin dust is too new)")

------------------------------------------------ the screen
M.sent = {}
local RX = math.floor(M.W * 0.56) + 3
local function msg(t) return { "modem_message", "x", "router-addr", 4242, 4, ser.serialize(t) } end
local before
for _, st in ipairs(statuses) do if #st.unassigned == 1 then before = st end end
local beeps0
local seen = {}
local steps = {
  function() return msg(before) end,
  function()
    seen.quiet = not M.find("New item", M.H)
    beeps0 = M.beeps
    return msg(last)
  end,
  function()
    H.screen("new-items")
    seen.footer = M.find("New item: Purified Pile of Tin Dust - no rule routes it (UNASSIGNED)", M.H) ~= nil
    seen.beep = M.beeps == beeps0 + 2                          -- the unassigned alert is new too
    local _, y = M.find("Purified Pile of Tin Dust", 5, RX)
    seen.new = y and M.row(y):find("new <1m", 1, true) ~= nil
    local _, qy = M.find("Nether Quartz", 5, RX)
    seen.old = qy and M.row(qy):find("new 1m", 1, true) ~= nil
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
check(seen.quiet, "the first status announces nothing")
check(seen.footer and seen.beep, "a new unassigned item: named in the footer, with a beep")
check(seen.new and seen.old, "the seen column: new and how long ago")

H.done()
