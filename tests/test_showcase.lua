-- test_showcase.lua: A busy ore line on the control screen (showcase-*.png, for the README and the website).
-- Real messages from a router run over nine processes, three kinds of output and thirteen machines, then the
-- screen: process cards, ITEMS grouped by process with an item open, and a broad rule's preview.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check
local ser = M.serialization
local computer = require("computer")

local GT, ORE = "gregtech:gt.metaitem.01", "gregtech:gt.blockores"
local function item(name, d, label, size) return { name = name, damage = d, label = label, size = size } end
M.items = {
  item(ORE, 35, "Copper Ore", 512), item(ORE, 32, "Iron Ore", 1024), item(ORE, 57, "Tin Ore", 256),
  item(ORE, 86, "Gold Ore", 128),
  item(GT, 5035, "Crushed Copper Ore", 2431), item(GT, 5032, "Crushed Iron Ore", 3872),
  item(GT, 5057, "Crushed Tin Ore", 1207), item(GT, 5086, "Crushed Gold Ore", 412),
  item(GT, 5034, "Crushed Nickel Ore", 286), item(GT, 5089, "Crushed Lead Ore", 655),
  item(GT, 5085, "Crushed Platinum Ore", 96),
  item(GT, 6035, "Purified Copper Ore", 845), item(GT, 6032, "Purified Iron Ore", 1540),
  item(GT, 6057, "Purified Tin Ore", 390), item(GT, 6502, "Purified Ruby Ore", 64),
  item(GT, 6503, "Purified Sapphire Ore", 48),
  item(GT, 7035, "Impure Pile of Copper Dust", 1120), item(GT, 7032, "Impure Pile of Iron Dust", 2045),
  item(GT, 8057, "Purified Pile of Tin Dust", 380),
  item(GT, 2019, "Aluminium Dust", 768), item(GT, 2028, "Titanium Dust", 256),
  item(GT, 2836, "Bauxite Dust", 512), item(GT, 2839, "Sphalerite Dust", 340),
  item(GT, 2035, "Copper Dust", 18432), item(GT, 2032, "Iron Dust", 25600), item(GT, 2057, "Tin Dust", 9120),
  item(GT, 2299, "Stone Dust", 4512),
}

local function working(p)
  return { isMachineActive = true, isWorkAllowed = true, getWorkProgress = p, getWorkMaxProgress = 100,
           getEUStored = 9000, getEUMaxStored = 10000 }
end
local function idle() return { isMachineActive = false, isWorkAllowed = true, getEUStored = 9500, getEUMaxStored = 10000 } end
M.machine("ma01", working(64))
M.machine("ow01", working(72)); M.machine("ow02", working(38)); M.machine("ow03", working(15))
M.machine("tc01", working(81)); M.machine("tc02", working(22))
M.machine("ce01", working(55)); M.machine("ce02", idle())
M.machine("si01", working(47))
M.machine("cb01", working(90))
M.machine("eb01", working(33)); M.machine("eb02", working(71))
M.machine("el01", working(12))
for _, a in ipairs({ "st111111-1111", "st222222-2222", "st333333-3333", "st444444-4444",
                     "st555555-5555", "st666666-6666", "st777777-7777" }) do M.stocker(a) end
M.iface("if111111-1111")

local cfgPath = H.TMP .. "/show-prism.cfg"
local f = assert(io.open(cfgPath, "w"))
f:write([[
return {
  interval = 5, monitorInterval = 2, stallAfter = 60, idleAlert = 30, modemPort = 4242, verbose = false,
  buses = {
    { address = "eb11", side = sides.north, process = "wash",       name = "Washer bus A" },
    { address = "eb22", side = sides.up,    process = "wash",       name = "Washer bus B" },
    { address = "eb11", side = sides.south, process = "centrifuge", name = "Centrifuge bus" },
  },
  stockers = {
    { address = "st11", process = "crush",    name = "Maceration Stack" },
    { address = "st22", process = "thermal",  name = "Thermal Centrifuge" },
    { address = "st33", process = "sift",     name = "Industrial Sifter" },
    { address = "st44", process = "chembath", name = "Chemical Bath" },
    { address = "st55", process = "ebf",      name = "EBF 1" },
    { address = "st66", process = "ebf",      name = "EBF 2" },
    { address = "st77", process = "electrolyze", name = "Electrolyzer" },
  },
  interfaces = { { address = "if11", process = "export", name = "Main net" } },
  machines = {
    { address = "ma01", process = "crush",      name = "Macerator" },
    { address = "ow01", process = "wash",       name = "Washer A" },
    { address = "ow02", process = "wash",       name = "Washer B" },
    { address = "ow03", process = "wash",       name = "Washer C" },
    { address = "tc01", process = "thermal",    name = "Thermal A" },
    { address = "tc02", process = "thermal",    name = "Thermal B" },
    { address = "ce01", process = "centrifuge", name = "Centrifuge A" },
    { address = "ce02", process = "centrifuge", name = "Centrifuge B" },
    { address = "si01", process = "sift",       name = "Sifter" },
    { address = "cb01", process = "chembath",   name = "Chem Bath" },
    { address = "eb01", process = "ebf",        name = "EBF 1" },
    { address = "eb02", process = "ebf",        name = "EBF 2" },
    { address = "el01", process = "electrolyze", name = "Electrolyzer" },
  },
  processes = { chembath = { overflow = 50 } },
  rules = {
    { pattern = "^Crushed .+ Ore$",           process = "wash",       priority = 10 },
    { pattern = "^Purified .+ Ore$",          process = "thermal" },
    { pattern = "^Impure Pile of .+ Dust$",   process = "centrifuge" },
    { pattern = "^Purified Pile of .+ Dust$", process = "centrifuge" },
    { pattern = "Ore$",                       process = "crush",      priority = 5 },
    { pattern = "^Aluminium Dust$",           process = "ebf" },
    { pattern = "^Titanium Dust$",            process = "ebf",        priority = 20 },
    { pattern = "^Bauxite Dust$",             process = "electrolyze" },
    { pattern = "^Sphalerite Dust$",          process = "electrolyze" },
    { pattern = "^%a+ Dust$",                 process = "export" },
  },
  overrides = {
    [ "gregtech:gt.metaitem.01:5085" ] = { process = "chembath", fallback = "wash" },
    [ "gregtech:gt.metaitem.01:6502" ] = { process = "sift" },
    [ "gregtech:gt.metaitem.01:6503" ] = { process = "sift" },
    [ "gregtech:gt.metaitem.01:2299" ] = { process = "ignore" },
  },
}
]])
f:close()
for _, s in ipairs({ "-overrides.cfg", "-items.cfg", "-rules.cfg" }) do os.remove(H.TMP .. "/show-prism" .. s) end

------------------------------------------------ 1) router run: past idleAlert, short of stallAfter
local function cmd(t) return { "modem_message", "x", "gui", 4242, 2, ser.serialize(t) } end
local done = {}
M.onPull = function()
  if computer.uptime() < 45 then return nil end
  if not done.r then done.r = true; return cmd({ cmd = "rules" }) end
  if not done.p then done.p = true; return cmd({ cmd = "previewRule", pattern = "Ore$", index = 5, req = 1 }) end
  if not done.i then done.i = true; return cmd({ cmd = "items", offset = 0, req = 1 }) end
  return { "interrupted" }
end
assert(loadfile(H.SRC .. "/prism.lua"))(cfgPath)
local status, rulesMsg, preview, itemsMsg
for _, s in ipairs(M.sent) do
  local m = ser.unserialize(s.data)
  if m.type == "router-status" then status = s.data end
  if m.type == "router-rules" then rulesMsg = s.data end
  if m.type == "router-preview" then preview = m end
  if m.type == "router-items" then itemsMsg = m end
end
check(status and rulesMsg and preview and itemsMsg, "router produced status, rules, preview and items")
local st = ser.unserialize(status)
local procs = 0
for _ in pairs(st.processes) do procs = procs + 1 end
check(procs >= 9, "nine processes have work (" .. procs .. ")")
check(#st.alerts == 1, "one alert: the idle centrifuge (" .. #st.alerts .. ")")

-- the screen pages the item list itself; answer with the router's list as one page
local all = itemsMsg.list
check(#all >= 20, "the item list has the whole line (" .. #all .. ")")
local function itemsPage(req) return ser.serialize({ type = "router-items", req = req, offset = 0, total = #all, list = all }) end

-- a few earlier scans, so each card's backlog history has a shape
local function statusAt(cycle, scale)
  local s = ser.unserialize(status)
  s.cycles = cycle
  for _, p in pairs(s.processes) do p.items = math.floor(p.items * scale) end
  return ser.serialize(s)
end

------------------------------------------------ 2) control screen
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
local function msg(data) if type(data) == "table" then data = ser.serialize(data) end; return { "modem_message", "x", "router-addr", 4242, 4, data } end
local function withReq(m, req) local c = {}; for k, v in pairs(m) do c[k] = v end; c.req = req; return c end

local scales = { 1.5, 1.35, 1.4, 1.2, 1.25, 1.1, 1.15, 1.05 }
local steps = {
  function() return msg(status) end,
  function() return tap(" ITEMS ", 3) end,
  function()
    local c = lastSent()
    check(c.cmd == "items", "ITEMS tab requests the list")
    return msg(itemsPage(c.req))
  end,
  function()
    check(M.find("▾ centrifuge", 5, RX) ~= nil and M.find("▾ ebf", 5, RX) ~= nil, "ITEMS grouped by process")
    return tap("Titanium Dust", 5, RX)
  end,
  function()
    H.screen("showcase-dashboard")
    for _, p in ipairs({ "crush", "wash", "thermal", "centrifuge", "sift", "chembath", "ebf", "electrolyze", "export" }) do
      check(M.find(p, 5) ~= nil, "a card for " .. p)
    end
    check(M.find("Titanium Dust", PT) ~= nil, "the route panel shows the tapped item")
    return tap(" RULES ", 3)
  end,
  function()
    check(lastSent().cmd == "rules", "RULES tab requests rules")
    return msg(rulesMsg)
  end,
  function()                                  -- rule 5, Ore$: four rows under rule 1
    local x, y = M.find("^Crushed .+ Ore$", 5, RX)
    return { "touch", "screen", x + 1, y + 4, 0, "Aaron" }
  end,
  function()
    local c = lastSent()
    check(c.cmd == "previewRule" and c.index == 5 and c.pattern == "Ore$", "editing rule 5 requests a preview")
    return msg(withReq(preview, c.req))
  end,
  function()
    H.screen("showcase-rules")
    check(M.find("Copper Ore", 5, RX) ~= nil and M.find("rule #1 wins", 5, RX) ~= nil, "the preview says which rule wins")
    return tap(" QUIT ", M.H)
  end,
}
local n = 0
M.onPull = function()
  n = n + 1
  if n <= #scales then return msg(statusAt(100 + n, scales[n])) end
  local s = steps[n - #scales]
  if s then return s() end
  return { "interrupted" }
end
assert(loadfile(H.SRC .. "/prism-control.lua"))()
check(#stderr == 0, "control exited cleanly " .. table.concat(stderr))
check(M.oob == 0, "no drawing outside the screen (" .. tostring(M.oobAt) .. ")")
H.done()
