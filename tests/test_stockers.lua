-- test_stockers.lua: GT Stocking Input Buses: top items incl. batch items, stable slots, auto-pull off,
-- no database needed, status, and recovery when the bus is unloaded.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check

local GT = "gregtech:gt.metaitem.01"
M.items = {}
for i = 1, 18 do
  M.items[i] = { name = GT, damage = 2000 + i, label = "Dust" .. i, size = i * 10 }
end
M.items[#M.items + 1] = { name = GT, damage = 2900, label = "Cinnabar Dust", size = 5 }  -- batch 2

M.proxies["db000000-aaaa"] = nil                 -- stockers don't need a Database Upgrade
local opts = { advanced = true }                -- auto-pull on, as placed
local ebf = M.stocker("st111111-1111", opts)
ebf.slots[3] = { name = "minecraft:dirt", damage = 0, label = "Dirt" }            -- stale
ebf.slots[7] = { name = GT, damage = 2018, label = "Dust18" }                       -- wanted: stays put

local logged = {}
local realWrite = io.write
io.write = function(...) for _, s in ipairs({ ... }) do logged[#logged + 1] = tostring(s) end end

local cfg = H.config("stock", [[
return { modemPort = 4242,
  stockers = { { address = "st11", process = "ebf", name = "EBF 1" } },
  rules = { { pattern = "^Cinnabar Dust$", process = "ebf", batch = 2, priority = 50 },
            { pattern = "^Dust%d+$", process = "ebf" } } }
]])

local function keys()
  local out = {}
  for s = 1, 16 do local c = ebf.slots[s]; out[s] = c and (c.name .. ":" .. c.damage) or false end
  return out
end
local function setOf(list) local s = {}; for _, k in pairs(list) do if k then s[k] = true end end; return s end

local cp = {}
M.onPull = function(n)
  if n == 1 then
    cp[1] = { slots = keys(), sets = M.setCalls, autoPull = ebf.autoPull }
  elseif n == 2 then
    cp[2] = { sets = M.setCalls }
    table.remove(M.items, 18)                    -- the top Dust runs out
  elseif n == 3 then
    cp[3] = { slots = keys() }
    opts.broken = true                           -- chunk unloaded...
    table.remove(M.items, 17)                    -- ...while the next Dust runs out
  elseif n == 4 then
    cp[4] = { slots = keys() }
    opts.broken = false                          -- loaded again
  elseif n == 5 then
    cp[5] = { slots = keys() }
    return { "interrupted" }
  end
end
H.run("prism.lua", cfg)
io.write = realWrite
local log = table.concat(logged)

local c1 = cp[1]
check(c1.autoPull == false, "auto-pull switched off so it can't overwrite the slots")
check(log:find("router " .. require("prism.version"), 1, true) ~= nil, "router starts without a database when only stockers are configured")
local s1 = setOf(c1.slots)
check(s1[GT .. ":2900"], "batch-2 item is stocked (the multiblock takes exact recipe amounts)")
check(c1.slots[1] == GT .. ":2900", "highest priority item in slot 1")
local n = 0; for _ in pairs(s1) do n = n + 1 end
check(n == 16, "all 16 slots used (" .. n .. ")")
check(not s1["minecraft:dirt:0"], "stale slot replaced")
check(c1.slots[7] == GT .. ":2018", "an already-stocked wanted item keeps its slot")
check(not s1[GT .. ":2001"] and not s1[GT .. ":2002"] and not s1[GT .. ":2003"] and s1[GT .. ":2004"],
  "19 items for 16 slots: the 3 smallest wait")
check(not log:find("has no feeder", 1, true), "no 'needs a feeder' warning for batch items a stocker takes")
check(cp[2].sets == c1.sets, "steady state: no writes on an unchanged network")

local moved = 0
for s = 1, 16 do if c1.slots[s] ~= cp[3].slots[s] then moved = moved + 1 end end
check(moved == 1 and cp[3].slots[7] == GT .. ":2003", "a depleted item frees exactly one slot for the next")

local st = M.serialization.unserialize(M.sent[1].data)
local b = st.buses[1]
check(b.kind == "stocker" and b.name == "EBF 1" and b.process == "ebf" and #b.filters == 16, "status lists the stocker")
check(st.processes.ebf.buses == 1, "stocker counts as an output for its process")

local errStatus
for i = 1, #M.sent do
  local m = M.serialization.unserialize(M.sent[i].data)
  if m.type == "router-status" and m.lastError and m.lastError:find("EBF 1", 1, true) then errStatus = m end
end
check(errStatus ~= nil, "an unloaded stocker is reported as lastError")
local same = true
for s = 1, 16 do if cp[3].slots[s] ~= cp[4].slots[s] then same = false end end
check(same, "nothing changes while it's unloaded")
check(not setOf(cp[5].slots)[GT .. ":2017"] and setOf(cp[5].slots)[GT .. ":2002"], "once loaded again it catches up")

local firstStatus = M.sent[1].data          -- for the screen check at the end

---------------------------------------------------------------- less than one batch left
-- 25 End Stone Dust in batches of 36 can't run a recipe: it isn't stocked, and nothing is stalled or idle
-- for it. 40 Cinnabar in batches of 2 that nothing takes still stalls its process.
M.items = { { name = GT, damage = 2950, label = "End Stone Dust", size = 25 },
            { name = GT, damage = 2900, label = "Cinnabar Dust", size = 40 } }
local cent = M.stocker("st333333-3333")
local mixer = M.stocker("st444444-4444")
M.machine("gm050000-cccc", { isMachineActive = false, isWorkAllowed = true, getEUStored = 9000, getEUMaxStored = 10000 })
local leftover = H.config("leftover", [[
return { modemPort = 4242, interval = 5, stallAfter = 20, idleAlert = 10,
  stockers = { { address = "st33", process = "centrifuge", name = "Centrifuge" },
               { address = "st44", process = "mixer", name = "Mixer" } },
  machines = { { address = "gm05", process = "centrifuge", name = "Centrifuge M" } },
  rules = { { pattern = "^End Stone Dust$", process = "centrifuge", batch = 36 },
            { pattern = "^Cinnabar Dust$", process = "mixer", batch = 2 } } }
]])
M.sent = {}
M.onPull = function()
  if require("computer").uptime() > 200 then return { "interrupted" } end
end
H.run("prism.lua", leftover)
local last
for _, sent in ipairs(M.sent) do
  local m = M.serialization.unserialize(sent.data)
  if m.type == "router-status" then last = m end
end
local alertIds = {}
for _, a in ipairs(last.alerts) do alertIds[a.id] = true end
check(cent.slots[1] == nil and mixer.slots[1] and mixer.slots[1].damage == 2900,
  "less than one batch isn't stocked; a full batch is")
check(not alertIds["stall:centrifuge"] and not alertIds["idle:Centrifuge M"],
  "less than one batch waiting is neither a stall nor an idle machine")
check(alertIds["stall:mixer"], "a full batch nothing takes still stalls")
check(last.processes.centrifuge.items == 25, "the leftover still shows in the backlog")

---------------------------------------------------------------- the control screen shows it
local mixed = M.serialization.unserialize(firstStatus)
table.insert(mixed.buses, 1, { name = "Washer bus", process = "wash", filters = { "Crushed Iron Ore" } })
local pulls = 0
M.onPull = function()
  pulls = pulls + 1
  if pulls == 1 then
    return { "modem_message", "x", "router", 4242, 4, M.serialization.serialize(mixed) }
  elseif pulls == 2 then
    H.screen("stocker-dashboard")
    return { "interrupted" }
  end
end
assert(loadfile(H.SRC .. "/prism-control.lua"))()
check(M.find("BUSES") ~= nil and M.find("EXPORT BUSES") == nil, "section is titled BUSES")
local _, ey = M.find("EBF 1")
check(ey and M.row(ey):find("16 stocked", 1, true), "stocker row says how many items it stocks")
local _, wy = M.find("Washer bus")
check(wy and M.row(wy):find("1 filter", 1, true), "export bus row still counts filters")
check(M.oob == 0, "no drawing outside the screen")
H.done()
