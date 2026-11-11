-- test_interfaces.lua: ME interfaces as outputs (an import bus on another network pulls from them): top batch-1
-- items in its 9 slots, cleared at start and on exit, one rewrite per item running out, status and screen row,
-- and the configuration errors (no database, the network's own interface, two outputs on the same slots).
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check
local ser = M.serialization

local GT = "gregtech:gt.metaitem.01"
M.items = {}
for i = 1, 12 do M.items[i] = { name = GT, damage = 2000 + i, label = "Dust" .. i, size = i * 10 } end
M.items[#M.items + 1] = { name = GT, damage = 2900, label = "Cinnabar Dust", size = 500 }   -- batch 2

local main = M.iface("if111111-1111")
main.config[4] = { name = "minecraft:dirt", damage = 0, label = "Dirt", want = 64 }      -- left from before

local logged = {}
local realWrite = io.write
io.write = function(...) for _, s in ipairs({ ... }) do logged[#logged + 1] = tostring(s) end end

local RULES = [[
  rules = { { pattern = "^Cinnabar Dust$", process = "export", batch = 2, priority = 50 },
            { pattern = "^Dust%d+$", process = "export" } },
]]
local cfg = H.config("iface", "return { modemPort = 4242,\n" .. RULES ..
  [[  interfaces = { { address = "if11", process = "export", name = "Main net" } } }]])

local function keys()
  local out = {}
  for s = 1, 9 do local c = main.config[s]; out[s] = c and (c.name .. ":" .. math.floor(c.damage)) or false end
  return out
end
local function setOf(list) local s = {}; for _, k in pairs(list) do if k then s[k] = true end end; return s end
local function dust(i) return GT .. ":" .. (2000 + i) end

local cp = {}
M.onPull = function(n)
  if n == 1 then
    cp[1] = { slots = keys(), sets = M.setCalls, want = main.config[1] and main.config[1].want }
    main.restock(); main.drain()                  -- the main net's import bus empties it
    cp[1].left = {}
    for _, it in ipairs(M.items) do cp[1].left[it.label] = it.size end
  elseif n == 2 then
    cp[2] = { slots = keys(), sets = M.setCalls }
    return { "interrupted" }
  end
end
H.run("prism.lua", cfg)
io.write = realWrite
local log = table.concat(logged)

local c1 = cp[1]
local s1 = setOf(c1.slots)
check(not s1["minecraft:dirt:0"], "a slot configured before the router started is cleared")
local n = 0; for _ in pairs(s1) do n = n + 1 end
check(n == 9 and s1[dust(12)] and s1[dust(4)] and not s1[dust(3)], "the top 9 items fill the 9 slots; the smallest wait")
check(not s1[GT .. ":2900"], "batch items aren't stocked: an import bus can't take exact amounts")
check(log:find("Cinnabar Dust needs batches of 2", 1, true) ~= nil, "and the log says why")
check(c1.want == 64, "each slot stocks a full stack")
check(main.exported[dust(12)] == 64 and c1.left.Dust12 == 56 and c1.left.Dust4 == nil,
  "the import bus pulls stocked items out of the subnet")

local changed = 0
for s = 1, 9 do if c1.slots[s] ~= cp[2].slots[s] then changed = changed + 1 end end
check(changed == 3 and cp[2].sets - c1.sets == 3, "three items ran out: exactly three slots rewritten")
check(setOf(cp[2].slots)[dust(1)] and setOf(cp[2].slots)[dust(3)], "the waiting items take their place")
check(next(main.config) == nil, "every slot is cleared on exit, so the stock goes back to the subnet")

local st = ser.unserialize(M.sent[1].data)
local b = st.buses[1]
check(b.kind == "interface" and b.name == "Main net" and b.process == "export" and #b.filters == 9,
  "status lists the interface with what it stocks")
check(st.processes.export.buses == 1, "the interface counts as an output for its process")

---------------------------------------------------------------- configuration errors
local function startError(text)
  M.onPull = function() return { "interrupted" } end
  local ok, err = pcall(H.run, "prism.lua", H.config("bad", text))
  return not ok and tostring(err) or nil
end
local twice = startError("return { " .. RULES .. [[ interfaces = {
  { address = "if11", process = "export", name = "A" }, { address = "if11", process = "export", name = "B" } } }]])
check(twice and twice:find("A and B both use slot 1 of ME interface if111111", 1, true),
  "two outputs on the same interface slots is an error: " .. tostring(twice))
local net = startError("return { network = \"if11\", " .. RULES .. [[ interfaces = { { address = "if11", process = "export" } } }]])
check(net and net:find("is the network PRISM scans", 1, true), "the network's own interface can't be an output")
local db = M.proxies["db000000-aaaa"]
M.proxies["db000000-aaaa"] = nil
local nodb = startError("return { " .. RULES .. [[ interfaces = { { address = "if11", process = "export" } } }]])
M.proxies["db000000-aaaa"] = db
check(nodb and nodb:find("no database found", 1, true) and nodb:find("interfaces", 1, true),
  "interfaces need a Database Upgrade")

---------------------------------------------------------------- the control screen shows it
local pulls = 0
M.onPull = function()
  pulls = pulls + 1
  if pulls == 1 then return { "modem_message", "x", "router", 4242, 4, M.sent[1].data } end
  H.screen("interface-dashboard")
  return { "interrupted" }
end
H.run("prism-control.lua")
local _, y = M.find("Main net")
check(y and M.row(y):find("9 stocked", 1, true), "the screen row says how many items it stocks")
check(M.oob == 0, "no drawing outside the screen")
H.done()
