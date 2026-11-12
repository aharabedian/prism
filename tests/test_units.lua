-- test_units.lua: the pure modules on their own, without running a program: rules, the planner,
-- slot keeping, the wire format and prism-setup's editor.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check

local rules    = require("prism.rules")
local planner  = require("prism.router.planner")
local slots    = require("prism.router.slots")
local protocol = require("prism.protocol")
local Editor   = require("prism.setup.editor")

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
local partial = planner.plan({ { name = "e", damage = 0, label = "End Stone Dust", size = 25 },
                               { name = "f", damage = 0, label = "Other Dust", size = 72 } },
  function(label) return "centrifuge", 10, label == "End Stone Dust" and 36 or 1 end)
check(partial.backlog.centrifuge.items == 97 and partial.backlog.centrifuge.ready == 72,
  "ready counts only stacks with at least one batch")
check(scan.queues.ignore == nil and #scan.unassigned == 1 and scan.unassigned[1].key == "x:0", "ignored items aren't queued or unassigned")

---------------------------------------------------------------- fallbacks
local fbList = { { pattern = "^Crushed", process = "chembath", fallback = "wash" },
                 { pattern = "^Held", process = "chembath", fallback = "chembath" } }
local fbCfg = { defaultPriority = 10, overrides = { ["o:0"] = { process = "chembath", fallback = "thermal" } } }
check(select(6, rules.classify({}, fbCfg, fbList, "Crushed A", "x:0")) == "wash", "a rule's fallback is returned sixth")
check(select(6, rules.classify({}, fbCfg, fbList, "?", "o:0")) == "thermal", "an override's fallback is returned")
check(select(6, rules.classify({}, fbCfg, fbList, "Held B", "y:0")) == nil, "a fallback to the same process is no fallback")
check(rules.validFallback("chembath", "ignore") == nil and rules.validFallback("ignore", "wash") == nil
  and rules.validFallback("a", "") == nil, "ignore and empty are never fallbacks")
check(rules.fromMsg({ pattern = "x", process = "a", fallback = "b" }).fallback == "b"
  and rules.fromMsg({ pattern = "x", process = "a", fallback = "a" }).fallback == nil, "setRule keeps a valid fallback")

-- chembath: A 500 and B 300 can spill to wash, C 400 can't; D waits for wash already
local function fbScan()
  return planner.plan({
    { name = "a", damage = 0, label = "A", size = 500 }, { name = "b", damage = 0, label = "B", size = 300 },
    { name = "c", damage = 0, label = "C", size = 400 }, { name = "d", damage = 0, label = "D", size = 100 },
  }, function(label)
    if label == "D" then return "wash", 10, 1 end
    return "chembath", label == "B" and 5 or 10, 1, label ~= "C" and "wash" or nil
  end)
end
local function keysOf(q) local out = {}; for i, e in ipairs(q or {}) do out[i] = e.key end; return table.concat(out, " ") end

local s1 = fbScan()
local held = planner.spill(s1, {}, {})
check(next(held) == nil and keysOf(s1.queues.chembath) == "a:0 c:0 b:0", "no limits: nothing spills")

-- overflow shares: the item stays in its own queue and joins its fallback's too
s1 = fbScan()
held = planner.spill(s1, { chembath = { overflow = 900 } }, {})
check(keysOf(s1.queues.chembath) == "a:0 c:0 b:0" and held["b:0"] and not held["a:0"],
  "past the overflow, the lowest-ranked item with a fallback is shared, until the rest fits; it stays queued")
check(keysOf(s1.queues.wash) == "d:0 b:0" and s1.queues.wash[2].from == "chembath" and s1.queues.wash[2].prio == 5
  and s1.queues.wash[2] ~= s1.queues.chembath[3], "a copy joins its fallback's queue with its own priority, ranked there")
check(s1.backlog.chembath.items == 1200 and s1.backlog.wash.items == 400 and s1.spilled.chembath.items == 300,
  "it waits in both backlogs, and spilled counts it")

s1 = fbScan()
planner.spill(s1, { chembath = { overflow = 100 } }, {})
check(keysOf(s1.queues.wash) == "a:0 d:0 b:0" and keysOf(s1.queues.chembath) == "a:0 c:0 b:0",
  "far past it, everything with a fallback is shared; items without one only wait here")

s1 = fbScan()
held = planner.spill(s1, { chembath = { overflow = 1000 } }, { ["b:0"] = true })
check(held["b:0"] and keysOf(s1.queues.wash) == "d:0 b:0", "a shared item stays shared until it fits under 3/4 of the overflow")
s1 = fbScan()
held = planner.spill(s1, { chembath = { overflow = 1600 } }, { ["b:0"] = true })
check(not held["b:0"] and keysOf(s1.queues.wash) == "d:0", "then it stops being shared")

-- always share: everything with a fallback, as overflow = 0
s1 = fbScan()
planner.spill(s1, { chembath = { alwaysShare = true, overflow = 5000 } }, {})
check(keysOf(s1.queues.chembath) == "a:0 c:0 b:0" and keysOf(s1.queues.wash) == "a:0 d:0 b:0"
  and s1.backlog.chembath.items == 1200, "always share: everything with a fallback is shared, whatever the overflow")
s1 = fbScan()
planner.spill(s1, { chembath = { alwaysShare = true }, wash = { overflow = 0 } }, {})
check(keysOf(s1.queues.wash) == "a:0 d:0 b:0", "copies are never shared again from the fallback")

local s4 = planner.plan({ { name = "e", damage = 0, label = "End Stone Dust", size = 25 } },
  function() return "centrifuge", 10, 36, "macerate" end)
planner.spill(s4, { centrifuge = { alwaysShare = true } }, {})
check(s4.backlog.macerate.items == 25 and s4.backlog.macerate.ready == 0,
  "a shared copy with less than one batch isn't ready in the fallback either")

-- the in-game case: the biggest stack is the one with a fallback, the rest can't move
local s3 = planner.plan({
  { name = "n", damage = 0, label = "Nickel", size = 12000 }, { name = "p", damage = 0, label = "Plat", size = 2000 },
  { name = "q", damage = 0, label = "Pall", size = 700 },
}, function(label) return "bath", 10, 1, label == "Nickel" and "wash" or nil end)
planner.spill(s3, { bath = { overflow = 10000 } }, {})
check(keysOf(s3.queues.bath) == "n:0 p:0 q:0" and keysOf(s3.queues.wash) == "n:0",
  "the top-ranked item is shared when it's the one that can be")

---------------------------------------------------------------- slot keeping
held = { "a", "b", false }
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

---------------------------------------------------------------- setup editor
local old = {
  network = "me000000", database = "db000000", modemPort = 4242, interval = 7,
  rules = { { pattern = "Ore$", process = "crush" } },
  processes = { chembath = { overflow = 10 } },
  buses = { { address = "eb11", side = 2, process = "wash", name = "Washer 1" },
            { address = "eb99", side = 3, process = "crush" } },                 -- not attached any more
  feeders = {}, machines = {}, stockers = {}, interfaces = {},
}
local snap = {
  networks = { "me000000-0000" }, databases = { "db000000-0000" },
  buses = { { addr = "eb111111-1111", side = 2, marker = "Cobblestone" }, { addr = "eb111111-1111", side = 1, marker = "(empty)" } },
  stockers = { { addr = "st010000-ssss", marker = "Sand", advanced = true } },
  interfaces = { { addr = "me000000-0000", marker = "(empty)" }, { addr = "if000000-iiii", marker = "(empty)" },
                 { addr = "if222222-iiii", marker = "Glass" } },
  transposers = { { addr = "tp000000-tttt", inv = { { side = 4, name = "Interface", size = 9 }, { side = 5, name = "Machine", size = 3 } },
                    ifaceSide = 4, machineSide = 5 },
                  { addr = "tp999999-tttt", inv = { { side = 0, name = "Chest", size = 27 } } } },
  machines = { { addr = "gm010000-aaaa", state = "idle", where = "" } },
}
old.network = "me000000-0000"
local ed = Editor.new(old, snap)
local rows = ed.rows("buses")
check(#rows == 3 and rows[1].key == "eb111111-1111|2" and rows[1].entry.process == "wash"
  and rows[2].entry == nil and rows[3].found == nil and rows[3].entry.address == "eb99",
  "editor: found buses matched to entries by address prefix and side, then entries not found")
check(#ed.changes() == 0, "editor: no changes before any edit")
check(ed.processes()[1] == "crush" and ed.processes()[2] == "wash" and ed.processes()[3] == "chembath",
  "editor: processes from rules, hardware and the processes table")

check(ed.assign("buses", "eb111111-1111|1", "crush") and #ed.c.buses == 3 and ed.c.buses[3].address == "eb111111-1111"
  and ed.c.buses[3].side == 1, "editor: assigning an unused bus adds an entry with its full address")
ed.rename("buses", "eb111111-1111|1", "Mac 1")
ed.assign("buses", "eb111111-1111|2", "chembath")
ed.rename("buses", "eb111111-1111|2", "")
ed.drop("buses", "eb99|3")
check(old.buses[1].process == "wash" and #old.buses == 2, "editor: the old config is never changed")
local ch = table.concat(ed.changes(), "\n")
check(ch:find("+ bus eb111111 up: crush (Mac 1)", 1, true) and ch:find("~ bus eb11 north: wash (Washer 1) -> chembath\n", 1, true)
  and ch:find("- bus eb99 south: crush", 1, true), "editor: changes list added, changed and removed entries")

local irows = ed.rows("interfaces")
check(#irows == 2 and irows[1].key == "if000000-iiii", "editor: the network's interface isn't offered as an output")
local assigned, why = ed.assign("feeders", "tp999999-tttt", "crush")
check(not assigned and why:find("fewer than two"), "editor: a transposer touching one inventory can't be a feeder")
check(ed.assign("feeders", "tp000000-tttt", "centrifuge"), "editor: feeder added")
local f = ed.c.feeders[1]
check(f.interface == "if000000-iiii" and f.interfaceSide == 4 and f.machineSide == 5, "editor: feeder gets a free interface and the guessed sides")
check(#ed.rows("interfaces") == 1 and ed.rows("interfaces")[1].key == "if222222-iiii", "editor: a feeder's interface leaves the interface list")
ed.setFeeder("tp000000-tttt", "machineSide", 4)
check(ed.c.feeders[1].machineSide == 4, "editor: feeder sides can be changed")
check(ed.feederChoices("tp000000-tttt").interfaces[1] == "if000000-iiii", "editor: feeder interface choices include its own")
ed.assign("interfaces", "if222222-iiii", "export")
check(#ed.feederChoices("tp000000-tttt").interfaces == 1, "editor: an interface another network pulls from isn't offered to feeders")
check(ed.result().feeders[1].slot == 1, "editor: feeder slots numbered per interface")
ed.addProcess("ebf")
check(ed.processes()[#ed.processes()] == "ebf" and ed.assign("stockers", "st010000-ssss", "ebf"), "editor: new processes can be added and used")
ed.set("database", nil)
local w = table.concat(ed.warnings(), "\n")
check(w:find("Database Upgrade", 1, true), "editor: warns that buses need a database")
check(w:find('"export"', 1, true) and w:find("no rule sends"), "editor: warns about processes no rule sends items to")
check(table.concat(ed.changes(), "\n"):find("~ database: db000000 -> none", 1, true), "editor: general settings show in changes")
ed.rescan({ networks = {}, databases = {}, buses = {}, stockers = {}, interfaces = {}, transposers = {}, machines = {} })
check(#ed.rows("buses") == 2 and not ed.rows("buses")[1].found, "editor: a rescan keeps edits; entries not found are flagged")
check(Editor.new({}, snap).processes()[1] == "crush", "editor: standard processes offered when the config names none")
check(Editor.new(old, snap, { { pattern = "x", process = "smelt" } }).processes()[3] == "smelt",
  "editor: processes from prism-rules.cfg are offered")

local _ = M
H.done()
