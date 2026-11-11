-- test_units.lua: the pure modules on their own, without running a program: rules, the planner,
-- slot keeping and the wire format.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check

local rules    = require("prism.rules")
local planner  = require("prism.router.planner")
local slots    = require("prism.router.slots")
local protocol = require("prism.protocol")

---------------------------------------------------------------- rules
local cfg = { defaultPriority = 10, overrides = { ["b:0"] = { process = "crush" } } }
local list = { { pattern = "^Crushed", process = "wash", batch = 4 }, { pattern = "Ore$", process = "crush", priority = 5 } }
local overrides = { ["a:0"] = { process = "ignore" } }
local function classify(label, key) return rules.classify(overrides, cfg, list, label, key) end

check(select(4, classify("Crushed Iron Ore", "a:0")) == "gui", "a screen override beats everything")
check(select(4, classify("Crushed Iron Ore", "b:0")) == "cfg", "a prism.cfg override beats the rules")
local p, prio, batch, src, idx = classify("Crushed Iron Ore", "c:0")
check(p == "wash" and prio == 10 and batch == 4 and src == "rule" and idx == 1, "first matching rule wins, with defaults")
check(classify("Dirt", "d:0") == nil, "no match: unassigned")
check(not rules.validPattern("[") and not rules.validPattern(""), "bad and empty patterns are rejected")
check(#rules.clean({ { pattern = "[", process = "x" }, { pattern = "x" }, { pattern = "ok", process = "y" } }) == 1,
  "clean keeps only rules with a valid pattern and a process")
local preview = rules.preview(overrides, cfg, list, { ["c:0"] = { label = "Iron Ore" }, ["e:0"] = { label = "Gold Ore" } },
  { pattern = "^Iron" }, 40)
check(preview.total == 1 and preview.applies == 1 and preview.list[1].now == "crush", "preview shows what a new rule would catch")

---------------------------------------------------------------- planner
local scan = planner.plan({
  { name = "a", damage = 0, label = "A", size = 5 },
  { name = "c", damage = 0, label = "Crushed X", size = 3 },
  { name = "c", damage = 0, label = "Crushed X", size = 4 },          -- an NBT variant of the same item
  { name = "d", damage = 0, label = "Crushed Y", size = 9 },
  { name = "x", damage = 0, label = "Dirt", size = 2 },
  { name = "z", damage = 0, label = "Zero", size = 0 },
}, classify)
check(scan.present["c:0"] == 7 and #scan.order == 4, "stacks of the same name:damage are merged; empty stacks dropped")
check(scan.queues.wash[1].key == "d:0" and scan.queues.wash[2].key == "c:0", "a queue is ranked by quantity within a priority")
check(scan.backlog.wash.types == 2 and scan.backlog.wash.items == 16, "backlog counts types and items")
check(scan.queues.ignore == nil and #scan.unassigned == 1 and scan.unassigned[1].key == "x:0", "ignored items aren't queued or unassigned")

---------------------------------------------------------------- slot keeping
local held = { "a", "b", false }
local writes = {}
local function write(s, e) writes[#writes + 1] = { s, e and e.key }; held[s] = e and e.key or false; return true end
slots.apply(held, 3, { { key = "b" }, { key = "a" } }, write)
check(#writes == 0, "an unchanged set causes no writes, whatever the order")
slots.apply(held, 3, { { key = "b" }, { key = "c" } }, write)
check(#writes == 1 and writes[1][1] == 1 and writes[1][2] == "c", "one item running out rewrites one slot")
writes = {}
local ok = slots.apply(held, 3, {}, function() return false, "unloaded" end)
check(not ok, "a failed write stops and reports")

---------------------------------------------------------------- wire format
local msg = { type = "router-status", unassigned = {}, buses = { { name = "b", filters = { "x" } } } }
for i = 1, 200 do msg.unassigned[i] = { key = "item" .. i, label = ("Some Long Item Name %d"):format(i), size = i } end
local data = protocol.encode(msg, 2000)
local back = protocol.decode(data)
check(#data <= 2000 and back.truncated and #back.unassigned < 200, "encode trims unassigned to fit and says so")
check(#msg.unassigned == 200 and msg.truncated == nil, "encode leaves the original message alone")
check(protocol.decode("not lua {") == nil and protocol.decode(nil) == nil, "decode rejects garbage")
check(protocol.feederLevel("blocked: 3 in machine") == "bad" and protocol.feederLevel("feeding") == "ok"
  and protocol.feederLevel("stocking") == "warn", "feeder states map to levels")

local _ = M
H.done()
