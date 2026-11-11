-- test_control_rules.lua: Control screen: machines, alerts, rule editor with preview, MAKE RULE, compact layout.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check
local ser = M.serialization
local computer = require("computer")

local GT = "gregtech:gt.metaitem.01"
local function item(d, label, size) return { name = GT, damage = d, label = label, size = size } end
M.items = {
  item(5001, "Crushed Copper Ore", 300), item(5002, "Crushed Tin Ore", 200),
  item(6001, "Impure Pile of Copper Dust", 120), item(7001, "Purified Copper Ore", 50),
  item(7002, "Purified Tin Ore", 40),
}
local machine = M.machine
machine("gm01", { isMachineActive = true, isWorkAllowed = true, getWorkProgress = 30, getWorkMaxProgress = 100, getEUStored = 8000, getEUMaxStored = 10000 })
machine("gm02", { isMachineActive = false, isWorkAllowed = true, getEUStored = 9000, getEUMaxStored = 10000 })
machine("gm03", { broken = true, isMachineActive = false })
machine("gm04", { isMachineActive = false, isWorkAllowed = true, getEUStored = 10, getEUMaxStored = 10000 })

local cfgPath = H.TMP .. "/c3-prism.cfg"
local f = assert(io.open(cfgPath, "w"))
f:write([[
return {
  interval = 5, monitorInterval = 2, stallAfter = 60, idleAlert = 30, modemPort = 4242, verbose = false,
  buses = {
    { address = "eb11", side = sides.north, process = "wash",       name = "Washer bus" },
    { address = "eb11", side = sides.south, process = "centrifuge", name = "Centrifuge bus" },
    { address = "eb22", side = sides.up,    process = "crush",      name = "Macerator bus" },
  },
  machines = {
    { address = "gm01", process = "wash",       name = "Washer A" },
    { address = "gm02", process = "wash",       name = "Washer B" },
    { address = "gm03", process = "centrifuge", name = "Centrifuge M" },
    { address = "gm04", process = "crush",      name = "Macerator" },
  },
  rules = {
    { pattern = "^Crushed .+ Ore$",           process = "wash" },
    { pattern = "^Impure Pile of .+ Dust$",   process = "centrifuge" },
    { pattern = "Ore$",                       process = "crush" },
  },
  overrides = { [ "gregtech:gt.metaitem.01:7002" ] = { process = "sift" } },
}
]])
f:close()
for _, s in ipairs({ "-overrides.cfg", "-items.cfg", "-rules.cfg" }) do os.remove(H.TMP .. "/c3-prism" .. s) end

------------------------------------------------ 1) router run to capture messages
local function cmd(t) return { "modem_message", "x", "gui", 4242, 2, ser.serialize(t) } end
local done = {}
M.onPull = function()
  local cu = nil
  for _, it in ipairs(M.items) do if it.damage == 5001 then cu = it end end
  if cu and cu.size > 10 then cu.size = cu.size - 1 end
  if computer.uptime() < 75 then return nil end
  if not done.r then done.r = true; return cmd({ cmd = "rules" }) end
  if not done.p1 then done.p1 = true; return cmd({ cmd = "previewRule", pattern = "^Crushed .+ Ore$", index = 1, req = 1 }) end
  if not done.p2 then done.p2 = true; return cmd({ cmd = "previewRule", pattern = "[a", req = 2 }) end
  if not done.items then done.items = true; return cmd({ cmd = "items", offset = 0, req = 1 }) end
  return { "interrupted" }
end
assert(loadfile(H.SRC .. "/prism.lua"))(cfgPath)
local status, machinesMsg, rulesMsg, prev1, prev2, itemsMsg
for _, s in ipairs(M.sent) do
  local m = ser.unserialize(s.data)
  if m.type == "router-status" then status = s.data end
  if m.type == "router-machines" then machinesMsg = m end
  if m.type == "router-rules" then rulesMsg = s.data end
  if m.type == "router-preview" and m.req == 1 then prev1 = m end
  if m.type == "router-preview" and m.req == 2 then prev2 = m end
  if m.type == "router-items" then itemsMsg = m end
end
check(status and machinesMsg and rulesMsg and prev1 and prev2 and itemsMsg, "router produced all message types")
local st0 = ser.unserialize(status)
check(#st0.alerts >= 4, "status has alerts (" .. #st0.alerts .. ")")

------------------------------------------------ 2) control screen
M.sent = {}
M.beeps = 0
local stderr = {}
io.stderr = { write = function(_, s) stderr[#stderr + 1] = s end }
local PT = M.H - 14
local RXc = math.floor(M.W * 0.56) + 3
local function tap(text, minY, minX)
  local x, y = M.find(text, minY, minX)
  assert(x, "can't find '" .. text .. "' on screen")
  return { "touch", "screen", x + 1, y, 0, "Aaron" }
end
local function key(ch) return { "key_down", "kb", string.byte(ch), 0, "Aaron" } end
local function bksp() return { "key_down", "kb", 8, 14, "Aaron" } end
local function lastSent() return ser.unserialize(M.sent[#M.sent].data) end
local function msg(data) if type(data) == "table" then data = ser.serialize(data) end; return { "modem_message", "x", "router-addr", 4242, 4, data } end
local function withReq(m, req) local c = {}; for k, v in pairs(m) do c[k] = v end; c.req = req; return c end

local bigStatus = ser.unserialize(status)
bigStatus.cycles = 999
bigStatus.version = "0.3.9"   -- pretend the router is an older release
for i = 1, 9 do bigStatus.buses[#bigStatus.buses + 1] = { name = "Extra bus " .. i, process = "wash", filters = { "Crushed Iron Ore", "Crushed Gold Ore" } } end
bigStatus.feeders = {}
for i = 1, 5 do
  bigStatus.feeders[i] = { name = "Feeder " .. i, process = "centrifuge", state = "feeding",
                          label = "Cinnabar Dust", batch = 2, fed = 100 * i }
end

local steps = {
  function() return msg(status) end,
  function()
    H.screen("rules-dashboard")
    check(M.find("MACHINES") ~= nil, "machines section drawn")
    local _, y = M.find("Washer A")
    check(M.row(y):find("30%", 1, true) and M.row(y):find("working", 1, true), "Washer A row: working 30%")
    check(M.find("Centrifuge M") and M.row(select(2, M.find("Centrifuge M"))):find("offline", 1, true), "offline machine shown")
    check(M.find("ALERTS", 1) ~= nil and select(2, M.find("ALERTS")) == 1, "alert badge in header")
    check(M.find("⚠ centrifuge") ~= nil, "stalled process flagged")
    check(M.beeps == 1, "beeped once for new alerts")
    check(M.find("⚠ ", M.H) ~= nil, "footer shows an alert")
    -- live machine update: Washer A progress 55%
    local mm = ser.unserialize(ser.serialize(machinesMsg))
    for _, m in ipairs(mm.machines) do if m.name == "Washer A" then m.progress = 0.55; m.state = "working" end end
    return msg(mm)
  end,
  function()
    local _, y = M.find("Washer A")
    check(M.row(y):find("55%", 1, true), "machine row updated in place from router-machines")
    return msg(status)    -- same status again: no new beep
  end,
  function()
    check(M.beeps == 1, "no beep when alerts unchanged")
    return tap(" RULES ", 3)
  end,
  function()
    check(lastSent().cmd == "rules", "RULES tab requests rules")
    return msg(rulesMsg)
  end,
  function()
    check(M.find("^Crushed .+ Ore$", 5, RXc) ~= nil, "rules listed")
    check(M.find("from prism.cfg", PT - 2) ~= nil, "rule source note shown")
    return tap("^Crushed .+ Ore$", 5, RXc)
  end,
  function()
    local c = lastSent()
    check(c.cmd == "previewRule" and c.index == 1 and c.pattern == "^Crushed .+ Ore$", "editing a rule requests a preview")
    check(M.find("EDIT RULE #1", PT) ~= nil, "rule editor open")
    return msg(withReq(prev1, c.req))
  end,
  function()
    H.screen("rules-rule")
    check(M.find("PREVIEW  2 match", 4) ~= nil, "preview header shows matches")
    check(M.find("applies", 5, RXc) ~= nil, "preview rows show effect")
    return key("x")
  end,
  function()
    check(lastSent().cmd == "previewRule" and lastSent().pattern == "^Crushed .+ Ore$x", "typing edits the pattern and re-previews")
    return bksp()
  end,
  function()
    check(lastSent().pattern == "^Crushed .+ Ore$", "backspace edits the pattern")
    return msg(withReq(prev2, lastSent().req))
  end,
  function()
    check(M.find("bad pattern: malformed", PT) ~= nil, "pattern error shown")
    local x, y = M.find(" SAVE ", PT + 11)
    check(M.fgb[y][x + 1] == 0x7d8a96, "SAVE disabled while the pattern is bad")
    return tap(" DELETE ", PT + 11)
  end,
  function()
    check(M.find("TAP AGAIN", PT + 11) ~= nil, "delete asks for confirmation")
    return tap(" TAP AGAIN ", PT + 11)
  end,
  function()
    check(lastSent().cmd == "deleteRule" and lastSent().index == 1, "deleteRule sent after confirm")
    return msg({ type = "router-ack", ok = true, text = "deleted rule #1" })
  end,
  function()
    check(lastSent().cmd == "rules", "ack refreshes rules")
    return msg(rulesMsg)
  end,
  function() return tap(" + NEW RULE ", PT - 2) end,
  function()
    check(M.find("NEW RULE", PT) ~= nil, "new rule editor")
    return key("T")
  end,
  function() return key("i") end,
  function() return key("n") end,
  function() return tap(" crush ", PT + 4) end,
  function() return tap(" 4 ", PT + 7) end,
  function() return tap(" SAVE ", PT + 11) end,
  function()
    local c = lastSent()
    check(c.cmd == "setRule" and c.index == nil and c.pattern == "Tin" and c.process == "crush" and c.batch == 4,
      "SAVE sends a new rule (Tin -> crush, batch 4)")
    return tap(" ITEMS ", 3)
  end,
  function()
    local c = lastSent()
    local page = { type = "router-items", req = c.req, offset = 0, total = 2, list = {
      { key = GT .. ":4242", label = "Tiny Pile of Gold-Dust (Raw)", size = 3, source = nil },
      itemsMsg.list[1] } }
    return msg(page)
  end,
  function() return tap("Tiny Pile of Gold-Dust (Raw)", 5, RXc) end,
  function() return tap(" sift ", PT + 4) end,
  function() return tap(" MAKE RULE ", PT + 11) end,
  function()
    local c = lastSent()
    check(c.cmd == "previewRule" and c.pattern == "^Tiny Pile of Gold%-Dust %(Raw%)$", "MAKE RULE escapes the name: " .. c.pattern)
    check(M.find("NEW RULE", PT) ~= nil and M.find(" sift ", PT + 4) ~= nil, "editor opened from the item with its process")
    local x, y = M.find(" sift ", PT + 4)
    check(M.bgb[y][x + 1] == 0x2f6fb5, "process carried over")
    return tap(" CANCEL ", PT + 11)
  end,
  function()
    check(M.find("RULES", PT) ~= nil, "cancel returns to the rules list")
    return msg(ser.serialize(bigStatus))
  end,
  function()
    H.screen("rules-compact")
    local _, y = M.find("Extra bus 1")
    check(M.row(y):find("Crushed Iron Ore", 1, true), "compact mode: bus filters on the same row")
    check(M.find("router 0.3.9 ≠ screen", 1) ~= nil, "version mismatch flagged in the header")
    return tap(" QUIT ", M.H)
  end,
}
local i = 0
M.onPull = function()
  i = i + 1
  if steps[i] then return steps[i]() end
  return { "interrupted" }
end
assert(loadfile(H.SRC .. "/prism-control.lua"))()
check(#stderr == 0, "control exited cleanly " .. table.concat(stderr))
check(i == #steps + 1 or i == #steps, "all steps ran (" .. i .. ")")
check(M.oob == 0, "no drawing outside the screen (" .. tostring(M.oobAt) .. ")")
H.done()
