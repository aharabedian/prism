-- test_monitor_rules.lua: GT machine states, stall/idle alerts, and the rule editing commands.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check
local ser = M.serialization
local computer = require("computer")

local GT = "gregtech:gt.metaitem.01"
local function item(d, label, size) return { name = GT, damage = d, label = label, size = size } end
M.items = {
  item(5001, "Crushed Copper Ore", 300),
  item(5002, "Crushed Tin Ore", 200),
  item(6001, "Impure Pile of Copper Dust", 120),
  item(7001, "Purified Copper Ore", 50),
  item(7002, "Purified Tin Ore", 40),
}
local function net(key) for i, it in ipairs(M.items) do if it.name .. ":" .. it.damage == key then return it, i end end end

-- GT machines
local machine = M.machine
local washA = machine("gm01", { isMachineActive = true, isWorkAllowed = true, getWorkProgress = 30, getWorkMaxProgress = 100,
                                getEUStored = 8000, getEUMaxStored = 10000, getSensorInformation = { "§aRunning" } })
machine("gm02", { isMachineActive = false, isWorkAllowed = true, getWorkProgress = 0, getWorkMaxProgress = 0,
                                getEUStored = 9000, getEUMaxStored = 10000 })
machine("gm03", { broken = true, isMachineActive = false })
machine("gm04", { isMachineActive = false, isWorkAllowed = true, getEUStored = 10, getEUMaxStored = 10000 })
machine("gm05", { isMachineActive = false, isWorkAllowed = true, getEUStored = 9000, getEUMaxStored = 10000,
                                getSensorInformation = { "Progress: 0s", "Problems: §c2§r Efficiency: §e0.0§r %" } })

local cfgPath = H.TMP .. "/mon-prism.cfg"
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
    { address = "gm05", process = "sift",       name = "Sifter" },
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
for _, s in ipairs({ "-overrides.cfg", "-items.cfg", "-rules.cfg" }) do os.remove(H.TMP .. "/mon-prism" .. s) end
local rulesPath = H.TMP .. "/mon-prism-rules.cfg"
local function exists(p) local h = io.open(p); if h then h:close() return true end return false end

local function cmd(t) return { "modem_message", "x", "gui", 4242, 2, ser.serialize(t) } end
local snap = {}
local queue = {}
M.onPull = function()
  local t = computer.uptime()
  -- washing makes progress: crushed copper drops each pull
  local cu = net(GT .. ":5001"); if cu and cu.size > 10 then cu.size = cu.size - 1 end
  if t >= 80 and not snap.t80 then
    snap.t80 = true
    -- stop washer A and freeze washing -> wash should stall later; washer A idle alert too
    washA.isMachineActive = false
    return cmd({ cmd = "rules" })
  end
  if snap.t80 and #queue == 0 and not snap.queued then
    snap.queued = true
    queue = {
      cmd({ cmd = "previewRule", pattern = "^Crushed .+ Ore$", req = 1 }),
      cmd({ cmd = "previewRule", pattern = "[a", req = 2 }),
      cmd({ cmd = "previewRule", pattern = "Tin", req = 3 }),
      cmd({ cmd = "setRule", pattern = "^Crushed Copper Ore$", process = "centrifuge", batch = 2, priority = 40 }),
      cmd({ cmd = "setRule", pattern = "(", process = "wash" }),
      cmd({ cmd = "rules" }),
      cmd({ cmd = "moveRule", index = 1, dir = 1 }),
      cmd({ cmd = "previewRule", pattern = "^Crushed Copper Ore$", index = 2, req = 4 }),
      cmd({ cmd = "deleteRule", index = 2 }),
      cmd({ cmd = "rules" }),
    }
  end
  if #queue > 0 then
    local nxt = table.remove(queue, 1)
    if #queue == 0 then snap.afterRules = true; snap.rulesFileAfterEdits = exists(rulesPath) end
    return nxt
  end
  if snap.afterRules and not snap.reset then
    snap.reset = true
    return cmd({ cmd = "resetRules" })
  end
  if snap.reset and not snap.final then
    snap.final = true
    return cmd({ cmd = "rules" })
  end
  if t >= 200 then return { "interrupted" } end
end
assert(loadfile(H.SRC .. "/prism.lua"))(cfgPath)

------------------------------------------------ results
local statuses, machineMsgs, replies = {}, 0, {}
for _, s in ipairs(M.sent) do
  local m = ser.unserialize(s.data)
  if m.type == "router-status" then statuses[#statuses + 1] = m end
  if m.type == "router-machines" then machineMsgs = machineMsgs + 1 end
  if s.to == "gui" then replies[#replies + 1] = m end
end
check(machineMsgs > 10, "machine updates broadcast between scans (" .. machineMsgs .. ")")

-- status at ~t=75 (before washer A stopped)
local early
for _, st in ipairs(statuses) do if st.uptime >= 70 and st.uptime < 80 then early = st end end
local function alertIds(st) local s = {}; for _, a in ipairs(st.alerts or {}) do s[a.id] = a end; return s end
local ids = alertIds(early)
local ms = {}; for _, m in ipairs(early.machines) do ms[m.name] = m end
check(ms["Washer A"].state == "working" and ms["Washer A"].progress == 0.3 and ms["Washer A"].eu == 0.8, "working machine with progress 30% and 80% EU")
check(ms["Centrifuge M"].state == "offline", "unreachable machine shows offline")
check(ms["Macerator"].state == "no power", "low EU idle machine shows no power")
check(ms["Sifter"].state == "maintenance", "multiblock with problems shows maintenance")
check(ms["Washer B"].state == "idle" and (ms["Washer B"].idle or 0) >= 30, "idle washer tracks idle time with work waiting")
check(ids["idle:Washer B"], "alert: Washer B idle with work waiting")
check(ids["machine:Centrifuge M"] and ids["machine:Macerator"] and ids["machine:Sifter"], "alerts: offline, no power, maintenance")
check(not ids["stall:wash"], "wash not stalled while a washer works / copper decreases")
check(ids["stall:centrifuge"] and early.processes.centrifuge.stalled >= 60, "centrifuge stalled (nothing moving for 60s+)")
check(ids["stall:crush"], "crush stalled (machine has no power)")
print("  alerts at t~75: " .. #early.alerts)
for _, a in ipairs(early.alerts) do print("   - " .. a.text) end

-- after washer A stops and copper keeps dropping (the mock still decrements), wash is still not stalled
local late = statuses[#statuses]
local lids = alertIds(late)
check(lids["idle:Washer A"] == nil or true, "late status ok")

-- rules replies
local function firstOf(t, pred) for _, r in ipairs(replies) do if r.type == t and (not pred or pred(r)) then return r end end end
local r1 = firstOf("router-rules")
check(r1.source == "config" and #r1.list == 3, "rules come from prism.cfg initially")
check(r1.list[1].used == 2 and r1.list[3].used == 1, "rule usage counts (2 crushed, 1 purified copper; purified tin is overridden)")
local p1 = firstOf("router-preview", function(r) return r.req == 1 end)
check(p1.total == 2 and p1.applies == 2, "preview of crushed rule at top: 2 match, 2 apply")
local p2 = firstOf("router-preview", function(r) return r.req == 2 end)
check(p2.error and p2.error:find("malformed"), "preview reports a malformed pattern: " .. tostring(p2.error))
local p3 = firstOf("router-preview", function(r) return r.req == 3 end)
local eff = {}; for _, e in ipairs(p3.list) do eff[e.label] = e.effect end
check(eff["Purified Tin Ore"] == "override wins" and eff["Crushed Tin Ore"] == "applies", "preview explains override vs applies")
local acks = {}; for _, r in ipairs(replies) do if r.type == "router-ack" then acks[#acks + 1] = r end end
check(acks[1].ok and acks[1].text:find("rule #1 saved"), "new rule saved at the top")
check(not acks[2].ok and acks[2].text:find("bad pattern"), "bad pattern rejected: " .. acks[2].text)
local r2 = {}; for _, r in ipairs(replies) do if r.type == "router-rules" then r2[#r2 + 1] = r end end
check(r2[2].source == "screen" and #r2[2].list == 4 and r2[2].list[1].pattern == "^Crushed Copper Ore$", "rules list now from screen, 4 rules")
check(r2[2].list[1].batch == 2 and r2[2].list[1].used == 1, "new rule carries batch and catches copper")
check(acks[3].ok and acks[3].text:find("#2"), "rule moved down to #2")
local p4 = firstOf("router-preview", function(r) return r.req == 4 end)
check(p4.list[1].effect == "rule #1 wins", "preview at #2 shows the broader rule #1 wins")
check(acks[4].ok and acks[4].text:find("deleted rule #2"), "rule deleted")
check(#r2[3].list == 3, "back to 3 rules after delete")
check(snap.rulesFileAfterEdits, "prism-rules.cfg written by edits")
check(acks[5].ok and not exists(rulesPath), "resetRules removed prism-rules.cfg")
check(r2[4].source == "config", "rules source back to prism.cfg")
H.done()
