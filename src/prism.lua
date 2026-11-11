--[[ prism.lua - PRISM router: Programmable Routing & Item Sorting for ME (AE2) networks

  Every few seconds:
    1. scan the ME (sub)network and remember every item ever seen (the catalog)
    2. decide each item's process, priority and batch size
       (screen overrides > prism.cfg overrides > rules)
    3. rank waiting items per process (priority, then quantity)
    4. export buses: rewrite filters to hold the top batch-1 items for their process;
       GT stocking input buses: hold the top items (any batch size) for their process
    5. detect stalls and raise alerts, then broadcast status for the control screen
  Every second (feedInterval), feeders move exact multiples of an item's batch
  size from an ME Interface into a machine through a transposer.
  Every couple of seconds (monitorInterval), GT machines with an adapter are
  polled for working/idle/progress/power/maintenance.

  Usage: prism [path/to/prism.cfg]     (default /home/prism.cfg)
  Files next to the config:
    prism-overrides.cfg  per-item overrides made on the screen
    prism-items.cfg      catalog of every item seen
    prism-rules.cfg      rules edited on the screen (replaces the rules in prism.cfg)

  Wireless commands (serialized tables on cfg.modemPort, add token = "..." if set):
    assign {key, process, priority, batch, label}   unassign {key}
    forget {key}   forgetAbsent {}
    items {offset, req}   overrides {}   status {}   reload {}
    rules {}   setRule {index?, pattern, process, priority, batch}   (no index = new rule at the top)
    deleteRule {index}   moveRule {index, dir = -1|1}   resetRules {}
    previewRule {pattern, index?, req}
  Changes reply with { type = "router-ack", ok = bool, text = "..." }.
]]

local component     = require("component")
local computer      = require("computer")
local event         = require("event")
local serialization = require("serialization")
local sides         = require("sides")

local VERSION = "0.5.0"

local args = { ... }
local CONFIG_PATH    = args[1] or "/home/prism.cfg"
local BASE           = CONFIG_PATH:gsub("%.cfg$", "")
local OVERRIDES_PATH = BASE .. "-overrides.cfg"
local CATALOG_PATH   = BASE .. "-items.cfg"
local RULES_PATH     = BASE .. "-rules.cfg"

local SIDE_NAMES = { [0] = "down", "up", "north", "south", "west", "east" }

local cfg, overrides, catalog, screenRules
local net, db, modem
local buses, stockers, feeders, machines = {}, {}, {}, {}
local stats = { cycles = 0, writes = 0, cycleMs = 0, lastError = nil }
local lastStatus
local lastLabels  = {}  -- key -> display name from the latest scan
local lastPresent = {}  -- key -> quantity in the network at the latest scan
local lastQueues  = {}  -- process -> ranked entries, used by feeders between scans
local stallState  = {}  -- process -> { since = uptime when movement stopped }
local fedAtScan   = {}  -- process -> feeder total at the previous scan
local activeAlerts = {} -- alert id -> true, to log new/resolved alerts once
local reported    = {}  -- things already warned about, to avoid log spam

local function log(fmt, ...)
  io.write(os.date("[%H:%M:%S] "), string.format(fmt, ...), "\n")
end

local function keyOf(stack)
  return stack.name .. ":" .. math.floor(stack.damage or 0)
end

local function fmtSecs(s)
  s = math.floor(s or 0)
  if s < 60 then return s .. "s" end
  return ("%dm%02ds"):format(math.floor(s / 60), s % 60)
end

local function fmtNum(n)
  if n >= 1e6 then return ("%.1fM"):format(n / 1e6) end
  if n >= 1e4 then return ("%.1fk"):format(n / 1e3) end
  return tostring(math.floor(n))
end

---------------------------------------------------------------- files

local function fileExists(path)
  local f = io.open(path, "r")
  if f then f:close(); return true end
  return false
end

local function readTable(path)
  local f = io.open(path, "r")
  if not f then return {} end
  local data = f:read("*a")
  f:close()
  return serialization.unserialize(data) or {}
end

local function writeTable(path, t)
  local f, err = io.open(path, "w")
  if not f then log("can't save %s: %s", path, tostring(err)); return end
  f:write(serialization.serialize(t))
  f:close()
end

local function saveOverrides() writeTable(OVERRIDES_PATH, overrides) end
local function saveCatalog() writeTable(CATALOG_PATH, catalog) end
local function saveRules() writeTable(RULES_PATH, screenRules) end

---------------------------------------------------------------- rules

local function validPattern(p)
  if type(p) ~= "string" or p == "" then return false, "empty pattern" end
  local ok, err = pcall(string.find, "", p)
  if not ok then return false, (tostring(err):gsub("^.-:%d+: ", "")) end
  return true
end

local function cleanRules(list, where)
  local out = {}
  for i, r in ipairs(list or {}) do
    local ok, err = validPattern(r.pattern)
    if ok and type(r.process) == "string" then out[#out + 1] = r
    else log("%s rule #%d skipped: %s", where, i, ok and "no process" or err) end
  end
  return out
end

local function rulesList() return screenRules or cfg.rules end

local function ensureScreenRules()
  if screenRules then return end
  screenRules = {}
  for i, r in ipairs(cfg.rules) do
    screenRules[i] = { pattern = r.pattern, process = r.process, priority = r.priority, batch = r.batch }
  end
end

-- Returns process, priority, batch, source ("gui" | "cfg" | "rule"), rule index - or nil.
local function classify(label, key, rules)
  local o = overrides[key]
  if o then return o.process, o.priority or cfg.defaultPriority, o.batch or 1, "gui" end
  o = cfg.overrides[key]
  if o then return o.process, o.priority or cfg.defaultPriority, o.batch or 1, "cfg" end
  label = label or ""
  for i, r in ipairs(rules or rulesList()) do
    if label:find(r.pattern) then return r.process, r.priority or cfg.defaultPriority, r.batch or 1, "rule", i end
  end
  return nil
end

---------------------------------------------------------------- config + components

local function loadConfig()
  if not fileExists(CONFIG_PATH) then error("no " .. CONFIG_PATH .. " - run prism-setup to create it", 0) end
  local fn, err = loadfile(CONFIG_PATH, "t", { sides = sides })
  if not fn then error("can't load " .. CONFIG_PATH .. ": " .. tostring(err), 0) end
  local ok, c = pcall(fn)
  if not ok or type(c) ~= "table" then error("bad config: " .. tostring(c), 0) end
  c.interval        = c.interval or 5
  c.feedInterval    = c.feedInterval or 1
  c.monitorInterval = c.monitorInterval or 2
  c.stallAfter      = c.stallAfter or 60
  c.idleAlert       = c.idleAlert or 30
  c.slotsPerBus     = c.slotsPerBus or 9
  c.defaultPriority = c.defaultPriority or 10
  c.overrides       = c.overrides or {}
  c.buses           = c.buses or {}
  c.stockers        = c.stockers or {}
  c.feeders         = c.feeders or {}
  c.machines        = c.machines or {}
  c.rules           = cleanRules(c.rules, "prism.cfg")
  return c
end

local function proxyOf(ctype, addr)
  local full
  if addr then full = component.get(addr, ctype) else full = component.list(ctype)() end
  return full and component.proxy(full) or nil
end

-- Returns the filter stack, false for an empty slot, or nil + reason if there
-- is no export bus on that side (the driver either throws or returns nil, msg).
local function readSlot(proxy, side, slot)
  local ok, stack, err = pcall(proxy.getExportConfiguration, side, slot)
  if not ok then return nil, tostring(stack) end
  if stack == nil and err then return nil, tostring(err) end
  return stack or false
end

-- Copy an item from the network into a database slot so a filter / interface
-- config can reference it. Slots are reused round-robin: once a bus or
-- interface is configured it keeps its own copy, so the database never fills up.
local function stage(key, stack)
  local s = db.slotOf[key]
  if s then return s end
  s = db.nextSlot
  db.nextSlot = s % (db.size - 1) + 1
  if db.keyIn[s] then db.slotOf[db.keyIn[s]] = nil; db.keyIn[s] = nil end
  db.proxy.clear(s)
  net.store({ name = stack.name, damage = stack.damage }, db.proxy.address, s, 1)
  local got = db.proxy.get(s)
  if not got or keyOf(got) ~= key then
    return nil, "store() didn't put " .. key .. " into the database"
  end
  db.slotOf[key], db.keyIn[s] = s, key
  return s
end

-- Point a feeder's interface slot at an item (stocking a full stack), or clear it.
local function setIface(f, key, stack)
  local entry, err
  if key then
    entry, err = stage(key, stack)
    if not entry then return false, err end
  else
    entry = db.emptySlot
  end
  local ok, res
  if key then
    ok, res = pcall(f.iface.setInterfaceConfiguration, f.slot, db.proxy.address, entry,
                    math.min(64, stack.maxSize or 64))
  else
    ok, res = pcall(f.iface.setInterfaceConfiguration, f.slot, db.proxy.address, entry)
  end
  if not ok then return false, tostring(res) end
  f.item = key
  stats.writes = stats.writes + 1
  if cfg.verbose then log("%s interface -> %s", f.name, key and (lastLabels[key] or key) or "(cleared)") end
  return true
end

local function setup()
  cfg = loadConfig()
  overrides = readTable(OVERRIDES_PATH)
  catalog = readTable(CATALOG_PATH)
  screenRules = fileExists(RULES_PATH) and cleanRules(readTable(RULES_PATH), "prism-rules.cfg") or nil
  reported, stallState, activeAlerts = {}, {}, {}

  net = proxyOf("me_controller", cfg.network) or proxyOf("me_interface", cfg.network)
  if not net then error("no ME controller/interface found - is an adapter touching it?", 0) end

  -- Only export buses and feeders need the database; stocking buses take item tables directly.
  local dbProxy = proxyOf("database", cfg.database)
  db = nil
  if dbProxy then
    local size
    for _, n in ipairs({ 81, 25, 9 }) do
      if pcall(dbProxy.get, n) then size = n; break end
    end
    if not size then error("couldn't work out the database size", 0) end
    -- Slots 1..size-1 stage items; the last slot stays empty and is used to clear configs.
    db = { proxy = dbProxy, size = size, emptySlot = size, slotOf = {}, keyIn = {}, nextSlot = 1 }
    for s = 1, size do pcall(dbProxy.clear, s) end
  elseif #cfg.buses + #cfg.feeders > 0 then
    error("no database found - put a Database Upgrade in an adapter (export buses and feeders need one)", 0)
  end

  buses = {}
  for i, b in ipairs(cfg.buses) do
    if not b.process then error(("bus #%d has no process"):format(i), 0) end
    local p = proxyOf("me_exportbus", b.address)
    if not p then error(("bus #%d: no me_exportbus matching %q"):format(i, tostring(b.address)), 0) end
    local bus = { proxy = p, side = b.side, process = b.process,
                  name = b.name or (b.process .. "#" .. i), slots = {} }
    for s = 1, cfg.slotsPerBus do
      local st, err = readSlot(p, b.side, s)
      if st == nil then
        error(("bus %s (side %s): %s"):format(bus.name, SIDE_NAMES[b.side] or tostring(b.side), err), 0)
      end
      bus.slots[s] = st and keyOf(st) or false
    end
    buses[#buses + 1] = bus
  end

  stockers = {}
  for i, sc in ipairs(cfg.stockers) do
    if not sc.process then error(("stocker #%d has no process"):format(i), 0) end
    local name = sc.name or (sc.process .. " stocker #" .. i)
    local p = proxyOf("me_inputbus", sc.address)
    if not p then error(("%s: no me_inputbus matching %q"):format(name, tostring(sc.address)), 0) end
    local ok, n = pcall(p.getSlotSize)
    if not ok or type(n) ~= "number" then error(("%s: can't read the stocking bus: %s"):format(name, tostring(n)), 0) end
    -- Auto-pull (advanced bus) fills the slots itself and would fight ours.
    local okAdv, adv = pcall(p.isAdvanced)
    if okAdv and adv and p.getAutoPull() then
      p.setAutoPull(false)
      log("%s: auto-pull switched off - PRISM picks its items", name)
    end
    local st = { proxy = p, process = sc.process, name = name, size = math.floor(n), slots = {}, kind = "stocker" }
    for s = 1, st.size do
      local okS, c = pcall(p.getConfiguration, s)
      if not okS then error(("%s: %s"):format(name, tostring(c)), 0) end
      st.slots[s] = type(c) == "table" and c.name and keyOf(c) or false
    end
    stockers[#stockers + 1] = st
  end

  feeders = {}
  for i, fc in ipairs(cfg.feeders) do
    local name = fc.name or ((fc.process or "?") .. " feeder #" .. i)
    if not fc.process then error(name .. ": no process", 0) end
    local iface = proxyOf("me_interface", fc.interface)
    if not iface then error(("%s: no me_interface matching %q"):format(name, tostring(fc.interface)), 0) end
    local tp = proxyOf("transposer", fc.transposer)
    if not tp then error(("%s: no transposer matching %q"):format(name, tostring(fc.transposer)), 0) end
    for _, s in ipairs({ { fc.interfaceSide, "interfaceSide" }, { fc.machineSide, "machineSide" } }) do
      local okSize, n = pcall(tp.getInventorySize, s[1])
      if not okSize or type(n) ~= "number" then
        error(("%s: transposer sees no inventory on %s (%s)"):format(name, s[2], SIDE_NAMES[s[1]] or tostring(s[1])), 0)
      end
    end
    local f = { iface = iface, tp = tp, ifaceSide = fc.interfaceSide, machineSide = fc.machineSide,
                process = fc.process, name = name, slot = fc.slot or 1,
                item = "?", fed = 0, state = "starting" }
    local ok, err = setIface(f, nil)
    if not ok then error(name .. ": can't configure the interface: " .. tostring(err), 0) end
    feeders[#feeders + 1] = f
  end

  machines = {}
  for i, mc in ipairs(cfg.machines) do
    local name = mc.name or ("machine #" .. i)
    local p = proxyOf("gt_machine", mc.address)
    if not p then error(("%s: no gt_machine matching %q"):format(name, tostring(mc.address)), 0) end
    machines[#machines + 1] = { proxy = p, name = name, process = mc.process, state = "?" }
  end

  modem = proxyOf("modem")
  if modem and cfg.modemPort then modem.open(cfg.modemPort) end

  local known = 0
  for _ in pairs(catalog) do known = known + 1 end
  log("router %s - network %s, database %s, %d bus(es), %d stocker(s), %d feeder(s), %d machine(s), %d known items, modem %s",
    VERSION, net.address:sub(1, 8), db and (db.size .. " slots") or "none", #buses, #stockers, #feeders, #machines, known,
    modem and ("port " .. tostring(cfg.modemPort)) or "none")
  if screenRules then
    log("using %d rule(s) from %s - rules in prism.cfg are ignored", #screenRules, RULES_PATH)
  end
  if #buses + #stockers + #feeders == 0 then log("no buses, stockers or feeders configured yet - run prism-setup") end
end

---------------------------------------------------------------- export buses

local function writeSlot(bus, slot, key, stack, label)
  local ok, res
  if bus.kind == "stocker" then
    -- Stocking buses take an item table ({name, damage}) directly; no argument clears the slot.
    if key then ok, res = pcall(bus.proxy.setConfiguration, slot,
                                   { name = stack.name, damage = math.floor(stack.damage or 0) })
    else ok, res = pcall(bus.proxy.setConfiguration, slot) end
  else
    local entry, err
    if key then
      entry, err = stage(key, stack)
      if not entry then return false, err end
    else
      entry = db.emptySlot
    end
    ok, res = pcall(bus.proxy.setExportConfiguration, bus.side, slot, db.proxy.address, entry)
  end
  if not ok then return false, tostring(res) end
  bus.slots[slot] = key or false
  stats.writes = stats.writes + 1
  if cfg.verbose then log("%s slot %d -> %s", bus.name, slot, key and (label or key) or "(cleared)") end
  return true
end

-- Make a bus's filter (or a stocker's slots) hold exactly `wanted` (ordered
-- queue entries), leaving slots that are already right untouched.
local function applyBus(bus, wanted)
  local n = bus.size or cfg.slotsPerBus
  local want = {}
  for _, e in ipairs(wanted) do want[e.key] = e end
  local placed = {}
  for s = 1, n do
    local k = bus.slots[s]
    if k and want[k] and not placed[k] then placed[k] = true end
  end
  local todo = {}
  for _, e in ipairs(wanted) do if not placed[e.key] then todo[#todo + 1] = e end end

  local nextTodo = 1
  for s = 1, n do
    local k = bus.slots[s]
    if k and want[k] and placed[k] == true then
      placed[k] = "kept"            -- a duplicate of k in a later slot gets replaced
    else
      local e = todo[nextTodo]
      local ok, err
      if e then
        nextTodo = nextTodo + 1
        ok, err = writeSlot(bus, s, e.key, e.stack, e.label)
      elseif k then
        ok, err = writeSlot(bus, s, nil)
      else
        ok = true
      end
      if not ok then
        stats.lastError = bus.name .. ": " .. tostring(err)
        log("%s", stats.lastError)
        return                        -- bus probably unloaded; try again next cycle
      end
    end
  end
end

---------------------------------------------------------------- feeders

local function machineContents(f)
  local n = f.tp.getInventorySize(f.machineSide)
  if type(n) ~= "number" then return nil, "can't see the machine" end
  local out = {}
  for s = 1, n do
    local st = f.tp.getStackInSlot(f.machineSide, s)
    if st and st.name then
      local k = keyOf(st)
      local e = out[k] or { size = 0, label = st.label }
      e.size = e.size + (st.size or 0)
      out[k] = e
    end
  end
  return out
end

-- One feed step: keep the machine topped up with exact multiples of the batch size.
local function feed(f)
  local q = lastQueues[f.process] or {}
  local machine, err = machineContents(f)
  if not machine then f.state = "error: " .. err; return end
  local stock = f.tp.getStackInSlot(f.ifaceSide, f.slot)
  local stockKey  = stock and stock.name and keyOf(stock) or nil
  local stockSize = stock and stock.size or 0

  -- Prefer whatever is already in the machine (top it up), then queue order.
  local pick
  for _, e in ipairs(q) do
    if machine[e.key] then pick = e; break end
  end
  if not pick then
    for _, e in ipairs(q) do
      local have = e.size + ((stockKey == e.key) and stockSize or 0)
      if have >= e.batch then pick = e; break end
    end
  end

  if not pick then
    if f.item then setIface(f, nil) end
    f.state, f.label, f.batch = "idle", nil, nil
    return
  end
  f.label, f.batch = pick.label, pick.batch

  local inMachine = machine[pick.key] and machine[pick.key].size or 0
  if inMachine % pick.batch ~= 0 then
    f.state = ("blocked: %d in machine, not a multiple of %d"):format(inMachine, pick.batch)
    return
  end

  if f.item ~= pick.key then
    local ok, e2 = setIface(f, pick.key, pick.stack)
    if not ok then f.state = "error: " .. tostring(e2); return end
    f.state = "stocking"              -- the interface needs a moment to pull stock
    return
  end

  local avail = (stockKey == pick.key) and stockSize or 0
  local room = (pick.stack.maxSize or 64) - inMachine
  local amount = math.floor(math.min(avail, room) / pick.batch) * pick.batch
  if amount <= 0 then
    f.state = (room < pick.batch) and "machine full" or "waiting for stock"
    return
  end

  local moved = tonumber((f.tp.transferItem(f.ifaceSide, f.machineSide, amount, f.slot))) or 0
  if moved == 0 then f.state = "machine not accepting"; return end
  f.fed = f.fed + moved
  if moved % pick.batch ~= 0 then
    f.state = ("warning: only %d of %d went in"):format(moved, amount)
    stats.lastError = f.name .. ": partial insert (" .. moved .. " of " .. amount .. ")"
    log("%s", stats.lastError)
  else
    f.state = "feeding"
  end
end

local function feedAll()
  for _, f in ipairs(feeders) do
    local ok, err = pcall(feed, f)
    if not ok then f.state = "error: " .. tostring(err) end
  end
end

---------------------------------------------------------------- machines

local function mcall(p, fn)
  if p[fn] == nil then return nil end
  local ok, v = pcall(p[fn])
  if ok then return v end
  return nil
end

local function round2(x) return x and math.floor(x * 100 + 0.5) / 100 or nil end

local function pollMachine(m)
  local p = m.proxy
  local active = mcall(p, "isMachineActive")
  if active == nil then m.state, m.progress, m.eu = "offline", nil, nil; return end
  local allowed = mcall(p, "isWorkAllowed")
  local prog, max = tonumber(mcall(p, "getWorkProgress")), tonumber(mcall(p, "getWorkMaxProgress"))
  local eu    = tonumber(mcall(p, "getEUStored") or mcall(p, "getStoredEU"))
  local euMax = tonumber(mcall(p, "getEUMaxStored") or mcall(p, "getEUCapacity"))
  m.progress = (max or 0) > 0 and round2(math.min(1, (prog or 0) / max)) or nil
  m.eu       = (euMax or 0) > 0 and round2(math.min(1, (eu or 0) / euMax)) or nil
  local problems = 0
  local info = mcall(p, "getSensorInformation")
  if type(info) == "table" then
    for _, line in ipairs(info) do
      local n = tostring(line):gsub("§.", ""):match("Problems:%s*(%d+)")
      if n then problems = tonumber(n) end
    end
  end
  if allowed == false then m.state = "disabled"
  elseif problems > 0 then m.state = "maintenance"
  elseif active then m.state = "working"
  elseif m.eu and m.eu < 0.05 then m.state = "no power"
  else m.state = "idle" end
end

local function machineSummary()
  local list = {}
  for _, m in ipairs(machines) do
    list[#list + 1] = { name = m.name, process = m.process, state = m.state,
                        progress = m.progress, eu = m.eu, idle = m.idleFor }
  end
  return list
end

---------------------------------------------------------------- status

local function knownProcesses()
  local list, seen = {}, {}
  local function add(p)
    if p and p ~= "ignore" and not seen[p] then seen[p] = true; list[#list + 1] = p end
  end
  for _, b in ipairs(buses) do add(b.process) end
  for _, b in ipairs(stockers) do add(b.process) end
  for _, f in ipairs(feeders) do add(f.process) end
  for _, m in ipairs(machines) do add(m.process) end
  for _, r in ipairs(rulesList()) do add(r.process) end
  for _, o in pairs(cfg.overrides) do add(o.process) end
  for _, o in pairs(overrides) do add(o.process) end
  table.sort(list)
  return list
end

local function overrideList()
  local list = {}
  local function add(key, o, source)
    list[#list + 1] = { key = key, process = o.process, priority = o.priority, batch = o.batch,
                        label = o.label or (catalog[key] and catalog[key].label) or lastLabels[key],
                        source = source }
  end
  for key, o in pairs(cfg.overrides) do if not overrides[key] then add(key, o, "cfg") end end
  for key, o in pairs(overrides) do add(key, o, "gui") end
  table.sort(list, function(a, b) return (a.label or a.key):lower() < (b.label or b.key):lower() end)
  return list
end

local function itemList()
  local list = {}
  for key, c in pairs(catalog) do
    local label = c.label or key
    local proc, prio, batch, src = classify(label, key)
    list[#list + 1] = { key = key, label = label, size = lastPresent[key] or 0,
                        process = proc, priority = prio, batch = batch, source = src }
  end
  table.sort(list, function(a, b) return a.label:lower() < b.label:lower() end)
  return list
end

local function countOf(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end

local function buildStatus(backlog, labels, unassigned, stalled, alerts)
  local s = {
    type = "router-status", version = VERSION, uptime = math.floor(computer.uptime()), interval = cfg.interval,
    cycles = stats.cycles, cycleMs = stats.cycleMs, writes = stats.writes,
    lastError = stats.lastError, processes = {}, buses = {}, feeders = {}, unassigned = {},
    unassignedCount = #unassigned, catalogCount = countOf(catalog),
    knownProcesses = knownProcesses(), machines = machineSummary(), alerts = alerts,
  }
  for proc, b in pairs(backlog) do
    s.processes[proc] = { types = b.types, items = b.items, buses = 0, stalled = stalled[proc] }
  end
  local function outputFor(proc)
    local p = s.processes[proc] or { types = 0, items = 0, buses = 0 }
    p.buses = p.buses + 1
    s.processes[proc] = p
  end
  local function addBus(bus)
    outputFor(bus.process)
    local filters = {}
    for i = 1, bus.size or cfg.slotsPerBus do
      local k = bus.slots[i]
      if k then filters[#filters + 1] = labels[k] or k end
    end
    s.buses[#s.buses + 1] = { name = bus.name, process = bus.process, filters = filters, kind = bus.kind }
  end
  for _, bus in ipairs(buses) do addBus(bus) end
  for _, st in ipairs(stockers) do addBus(st) end
  for _, f in ipairs(feeders) do
    outputFor(f.process)
    s.feeders[#s.feeders + 1] = { name = f.name, process = f.process, state = f.state,
                                  label = f.label, batch = f.batch, fed = f.fed }
  end
  for i = 1, math.min(#unassigned, 25) do s.unassigned[i] = unassigned[i] end
  return s
end

local function send(target, msg)
  if not (modem and cfg.modemPort) then return end
  local max = (modem.maxPacketSize and modem.maxPacketSize() or 8192) - 64
  local data = serialization.serialize(msg)
  local trim = msg.unassigned or msg.list
  while #data > max and trim and #trim > 0 do
    table.remove(trim)
    msg.truncated = true
    data = serialization.serialize(msg)
  end
  if #data > max and msg.buses then
    for _, b in ipairs(msg.buses) do b.filters = nil end
    data = serialization.serialize(msg)
  end
  if #data > max then return end
  if target then modem.send(target, cfg.modemPort, data) else modem.broadcast(cfg.modemPort, data) end
end

---------------------------------------------------------------- stalls + alerts

-- A process is stalled when it has items waiting and somewhere to send them,
-- but for stallAfter seconds nothing left the network, no feeder moved
-- anything and none of its monitored machines were working.
local function detectStalls(queues, backlog, present)
  local now = computer.uptime()
  local moved, working, hasOutput = {}, {}, {}

  for proc, q in pairs(queues) do
    for _, e in ipairs(q) do
      local before = lastPresent[e.key]
      if before and e.size < before then moved[proc] = true; break end
    end
  end
  for key in pairs(lastPresent) do
    if not present[key] then
      local proc = classify(catalog[key] and catalog[key].label or lastLabels[key], key)
      if proc then moved[proc] = true end
    end
  end
  local fedNow = {}
  for _, f in ipairs(feeders) do
    hasOutput[f.process] = true
    fedNow[f.process] = (fedNow[f.process] or 0) + f.fed
  end
  for proc, n in pairs(fedNow) do
    if n > (fedAtScan[proc] or 0) then moved[proc] = true end
  end
  fedAtScan = fedNow
  for _, b in ipairs(buses) do hasOutput[b.process] = true end
  for _, b in ipairs(stockers) do hasOutput[b.process] = true end
  for _, m in ipairs(machines) do
    if m.state == "working" then working[m.process or ""] = true end
    local waiting = m.process and backlog[m.process] and backlog[m.process].items > 0
    if m.state == "idle" and waiting then
      m.idleSince = m.idleSince or now
      m.idleFor = math.floor(now - m.idleSince)
    else
      m.idleSince, m.idleFor = nil, nil
    end
  end

  local stalled = {}
  for proc in pairs(backlog) do
    local s = stallState[proc] or {}
    stallState[proc] = s
    if moved[proc] or working[proc] or not hasOutput[proc] then
      s.since = nil
    else
      s.since = s.since or now
      if now - s.since >= cfg.stallAfter then stalled[proc] = math.floor(now - s.since) end
    end
  end
  for proc in pairs(stallState) do if not backlog[proc] then stallState[proc] = nil end end
  return stalled
end

local function buildAlerts(backlog, stalled)
  local list = {}
  local function add(id, level, text) list[#list + 1] = { id = id, level = level, text = text } end
  local procs = {}
  for proc in pairs(stalled) do procs[#procs + 1] = proc end
  table.sort(procs)
  for _, proc in ipairs(procs) do
    add("stall:" .. proc, "bad", ("%s stalled %s - %s waiting, nothing moving"):format(
      proc, fmtSecs(stalled[proc]), fmtNum(backlog[proc].items)))
  end
  for _, f in ipairs(feeders) do
    local st = f.state or ""
    if st:find("^blocked") or st:find("^error") or st:find("^warning") then
      add("feeder:" .. f.name, "bad", f.name .. ": " .. st)
    end
  end
  for _, m in ipairs(machines) do
    if m.state == "offline" or m.state == "no power" or m.state == "maintenance" then
      add("machine:" .. m.name, "bad", m.name .. ": " .. m.state)
    elseif m.state == "disabled" then
      add("machine:" .. m.name, "warn", m.name .. ": disabled (soft mallet)")
    elseif m.idleFor and m.idleFor >= cfg.idleAlert then
      add("idle:" .. m.name, "warn", ("%s idle %s with work waiting"):format(m.name, fmtSecs(m.idleFor)))
    end
  end

  local seen = {}
  for _, a in ipairs(list) do
    seen[a.id] = true
    if not activeAlerts[a.id] then log("ALERT %s", a.text) end
  end
  for id in pairs(activeAlerts) do
    if not seen[id] then log("resolved: %s", id) end
  end
  activeAlerts = seen
  return list
end

---------------------------------------------------------------- scan cycle

local function cycle()
  local t0 = computer.uptime()
  stats.lastError = nil               -- only report problems from this cycle
  local items = net.getItemsInNetwork() or {}

  -- merge duplicates (same item with different NBT shows up as separate stacks)
  local merged, order = {}, {}
  for _, st in ipairs(items) do
    if st.name and (st.size or 0) > 0 then
      local key = keyOf(st)
      local m = merged[key]
      if m then m.size = m.size + st.size
      else merged[key] = { key = key, stack = st, label = st.label or key, size = st.size }; order[#order + 1] = key end
    end
  end

  local queues, labels, present, unassigned, backlog = {}, {}, {}, {}, {}
  local catalogChanged = false
  for _, key in ipairs(order) do
    local e = merged[key]
    labels[key], present[key] = e.label, e.size
    if not catalog[key] or catalog[key].label ~= e.label then
      catalog[key] = { label = e.label }
      catalogChanged = true
    end
    local proc, prio, batch = classify(e.label, key)
    if proc == nil then
      unassigned[#unassigned + 1] = { key = key, label = e.label, size = e.size }
      if not reported[key] then
        reported[key] = true
        log("unassigned: %s (%s) x%d", e.label, key, e.size)
      end
    elseif proc ~= "ignore" then
      e.prio, e.batch = prio, math.max(1, math.floor(batch or 1))
      queues[proc] = queues[proc] or {}
      table.insert(queues[proc], e)
      local b = backlog[proc] or { types = 0, items = 0 }
      b.types, b.items = b.types + 1, b.items + e.size
      backlog[proc] = b
    end
  end
  if catalogChanged then saveCatalog() end

  for proc, q in pairs(queues) do
    table.sort(q, function(a, b)
      if a.prio ~= b.prio then return a.prio > b.prio end
      if a.size ~= b.size then return a.size > b.size end
      return a.key < b.key
    end)
    local hasBus, hasFeeder = false, false
    for _, bus in ipairs(buses) do if bus.process == proc then hasBus = true; break end end
    for _, f in ipairs(feeders) do if f.process == proc then hasFeeder = true; break end end
    for _, st in ipairs(stockers) do if st.process == proc then hasFeeder = true; break end end
    if not hasBus and not hasFeeder and not reported["proc:" .. proc] then
      reported["proc:" .. proc] = true
      log("items waiting for '%s' but no bus, stocker or feeder is configured for it", proc)
    end
    if not hasFeeder then
      for _, e in ipairs(q) do
        if e.batch > 1 and not reported["batch:" .. e.key] then
          reported["batch:" .. e.key] = true
          log("%s needs batches of %d - '%s' has no feeder or stocker, so it won't be sent", e.label, e.batch, proc)
        end
      end
    end
  end

  -- Export buses can't send exact amounts, so they only get batch-1 items.
  for _, bus in ipairs(buses) do
    local wanted = {}
    for _, e in ipairs(queues[bus.process] or {}) do
      if #wanted >= cfg.slotsPerBus then break end
      if e.batch == 1 then wanted[#wanted + 1] = e end
    end
    applyBus(bus, wanted)
  end

  -- Stocking buses expose the network to a multiblock, which takes exactly what each
  -- recipe needs, so batch items are fine there.
  for _, st in ipairs(stockers) do
    local wanted = {}
    for _, e in ipairs(queues[st.process] or {}) do
      if #wanted >= st.size then break end
      wanted[#wanted + 1] = e
    end
    applyBus(st, wanted)
  end

  local stalled = detectStalls(queues, backlog, present)
  local alerts = buildAlerts(backlog, stalled)

  table.sort(unassigned, function(a, b) return a.size > b.size end)
  lastLabels, lastPresent, lastQueues = labels, present, queues
  stats.cycles = stats.cycles + 1
  stats.cycleMs = math.floor((computer.uptime() - t0) * 1000)
  lastStatus = buildStatus(backlog, labels, unassigned, stalled, alerts)
  send(nil, lastStatus)
end

---------------------------------------------------------------- rule commands

local function ruleFromMsg(msg)
  local ok, err = validPattern(msg.pattern)
  if not ok then return nil, "bad pattern: " .. tostring(err) end
  if type(msg.process) ~= "string" or msg.process == "" then return nil, "pick a process for the rule" end
  local batch = math.max(1, math.floor(tonumber(msg.batch) or 1))
  return { pattern = msg.pattern, process = msg.process, priority = tonumber(msg.priority),
           batch = batch > 1 and batch or nil }
end

local function ruleList()
  local rules = rulesList()
  local used = {}
  for key, c in pairs(catalog) do
    local _, _, _, src, idx = classify(c.label, key, rules)
    if src == "rule" then used[idx] = (used[idx] or 0) + 1 end
  end
  local list = {}
  for i, r in ipairs(rules) do
    list[i] = { index = i, pattern = r.pattern, process = r.process, priority = r.priority,
                batch = r.batch, used = used[i] or 0 }
  end
  return list
end

-- What would happen if this pattern were saved at `index` (or as a new rule at the top)?
local function previewRule(msg)
  local ok, err = validPattern(msg.pattern)
  if not ok then return { type = "router-preview", req = msg.req, error = err } end
  local rules, pos = {}, 1
  for i, r in ipairs(rulesList()) do rules[i] = r end
  local candidate = { pattern = msg.pattern, process = msg.process or "?" }
  local index = tonumber(msg.index)
  if index and rules[index] then rules[index] = candidate; pos = index
  else table.insert(rules, 1, candidate) end

  local list, applies = {}, 0
  for key, c in pairs(catalog) do
    local label = c.label or key
    if label:find(msg.pattern) then
      local _, _, _, src, idx = classify(label, key, rules)
      local now = classify(label, key)
      local effect
      if src == "rule" and idx == pos then effect = "applies"; applies = applies + 1
      elseif src == "gui" or src == "cfg" then effect = "override wins"
      else effect = "rule #" .. tostring(idx) .. " wins" end
      list[#list + 1] = { key = key, label = label, now = now, effect = effect }
    end
  end
  table.sort(list, function(a, b) return a.label:lower() < b.label:lower() end)
  local total = #list
  for i = #list, 41, -1 do list[i] = nil end
  return { type = "router-preview", req = msg.req, total = total, applies = applies, list = list }
end

---------------------------------------------------------------- commands

-- Returns true when the command changed something and a scan should run now.
local function handleMessage(from, port, data)
  if port ~= cfg.modemPort or type(data) ~= "string" then return false end
  local msg = serialization.unserialize(data)
  if type(msg) ~= "table" or not msg.cmd then return false end
  if cfg.token and msg.token ~= cfg.token then return false end
  local function ack(ok, text) send(from, { type = "router-ack", ok = ok, text = text }) end
  local function nameOf(key) return (catalog[key] and catalog[key].label) or lastLabels[key] or key end
  local cmd = msg.cmd

  if cmd == "assign" and type(msg.key) == "string" and type(msg.process) == "string" then
    local label = type(msg.label) == "string" and msg.label or nameOf(msg.key)
    local batch = math.max(1, math.floor(tonumber(msg.batch) or 1))
    overrides[msg.key] = { process = msg.process, priority = tonumber(msg.priority),
                           batch = batch > 1 and batch or nil, label = label }
    saveOverrides()
    if not catalog[msg.key] then catalog[msg.key] = { label = label }; saveCatalog() end
    reported[msg.key], reported["batch:" .. msg.key] = nil, nil
    log("override: %s -> %s (priority %s, batch %d)", label, msg.process, tostring(msg.priority or "default"), batch)
    ack(true, ("%s -> %s%s"):format(label, msg.process, batch > 1 and (" in batches of " .. batch) or ""))
    return true

  elseif cmd == "unassign" and type(msg.key) == "string" then
    local had = overrides[msg.key] ~= nil
    overrides[msg.key] = nil
    saveOverrides()
    reported[msg.key] = nil
    log("override removed: %s", msg.key)
    ack(had, had and ("removed override for " .. nameOf(msg.key))
                 or "that override lives in prism.cfg - edit it there")
    return true

  elseif cmd == "forget" and type(msg.key) == "string" then
    local name = nameOf(msg.key)
    local had = catalog[msg.key] ~= nil
    catalog[msg.key] = nil
    saveCatalog()
    local hadOverride = overrides[msg.key] ~= nil
    if hadOverride then overrides[msg.key] = nil; saveOverrides() end
    local text = "forgot " .. name .. (hadOverride and " and its override" or "")
    if lastPresent[msg.key] then text = text .. " - it's still in the network, so it'll be re-added" end
    log("%s", text)
    ack(had, text)
    return true

  elseif cmd == "forgetAbsent" then
    local removed, kept = 0, 0
    for key in pairs(catalog) do
      if not lastPresent[key] then
        if overrides[key] or cfg.overrides[key] then kept = kept + 1
        else catalog[key] = nil; removed = removed + 1 end
      end
    end
    saveCatalog()
    local text = ("forgot %d absent item(s)"):format(removed)
    if kept > 0 then text = text .. (" - kept %d with overrides"):format(kept) end
    log("%s", text)
    ack(true, text)
    return true

  elseif cmd == "setRule" then
    local r, err = ruleFromMsg(msg)
    if not r then ack(false, err); return false end
    ensureScreenRules()
    local index = tonumber(msg.index)
    if index and screenRules[index] then screenRules[index] = r
    else table.insert(screenRules, 1, r); index = 1 end
    saveRules()
    log("rule #%d: %s -> %s", index, r.pattern, r.process)
    ack(true, ("rule #%d saved: %s -> %s"):format(index, r.pattern, r.process))
    return true

  elseif cmd == "deleteRule" then
    ensureScreenRules()
    local index = tonumber(msg.index)
    local r = index and screenRules[index]
    if not r then ack(false, "no rule #" .. tostring(msg.index)); return false end
    table.remove(screenRules, index)
    saveRules()
    log("rule #%d deleted: %s", index, r.pattern)
    ack(true, ("deleted rule #%d (%s)"):format(index, r.pattern))
    return true

  elseif cmd == "moveRule" then
    ensureScreenRules()
    local index, dir = tonumber(msg.index), tonumber(msg.dir)
    local target = index and dir and index + (dir < 0 and -1 or 1)
    if not (target and screenRules[index] and screenRules[target]) then ack(false, "can't move that rule"); return false end
    screenRules[index], screenRules[target] = screenRules[target], screenRules[index]
    saveRules()
    ack(true, ("rule moved to #%d"):format(target))
    return true

  elseif cmd == "resetRules" then
    screenRules = nil
    os.remove(RULES_PATH)
    log("screen rules removed - back to the rules in prism.cfg")
    ack(true, "back to the rules in prism.cfg")
    return true

  elseif cmd == "reload" then
    local ok, err = pcall(setup)
    if not ok then stats.lastError = tostring(err); log("reload failed: %s", tostring(err)) end
    ack(ok, ok and "config reloaded" or ("reload failed: " .. tostring(err)))
    return true

  elseif cmd == "status" then
    if lastStatus then send(from, lastStatus) end
  elseif cmd == "overrides" then
    send(from, { type = "router-overrides", list = overrideList() })
  elseif cmd == "rules" then
    send(from, { type = "router-rules", source = screenRules and "screen" or "config", list = ruleList() })
  elseif cmd == "previewRule" then
    send(from, previewRule(msg))
  elseif cmd == "items" then
    local all = itemList()
    local offset = math.max(0, math.floor(tonumber(msg.offset) or 0))
    local page = {}
    for i = offset + 1, math.min(#all, offset + 40) do page[#page + 1] = all[i] end
    send(from, { type = "router-items", req = msg.req, offset = offset, total = #all, list = page })
  end
  return false
end

---------------------------------------------------------------- main

setup()
log("scanning every %ss%s%s - Ctrl+C to stop", tostring(cfg.interval),
  #feeders > 0 and (", feeding every " .. tostring(cfg.feedInterval) .. "s") or "",
  #machines > 0 and (", watching machines every " .. tostring(cfg.monitorInterval) .. "s") or "")

local running = true
local nextScan, nextFeed, nextMonitor = 0, 0, 0
while running do
  if #machines > 0 and computer.uptime() >= nextMonitor then
    for _, m in ipairs(machines) do
      if not pcall(pollMachine, m) then m.state = "offline" end
    end
    if nextScan > computer.uptime() then       -- the scan sends its own full status
      send(nil, { type = "router-machines", machines = machineSummary() })
    end
    nextMonitor = computer.uptime() + cfg.monitorInterval
  end
  if computer.uptime() >= nextScan then
    local ok, err = pcall(cycle)
    if not ok then
      stats.lastError = tostring(err)
      log("cycle failed: %s", tostring(err))
    end
    nextScan = computer.uptime() + cfg.interval
  end
  if #feeders > 0 and computer.uptime() >= nextFeed then
    feedAll()
    nextFeed = computer.uptime() + cfg.feedInterval
  end

  local wake = nextScan
  if #feeders > 0 and nextFeed < wake then wake = nextFeed end
  if #machines > 0 and nextMonitor < wake then wake = nextMonitor end
  local wait = wake - computer.uptime()
  if wait > 0 then
    local ev = table.pack(event.pullMultiple(wait, "modem_message", "interrupted"))
    if ev[1] == "interrupted" then
      running = false
    elseif ev[1] == "modem_message" then
      -- modem_message: localAddress, remoteAddress, port, distance, payload...
      local okMsg, rerun = pcall(handleMessage, ev[3], ev[4], ev[6])
      if not okMsg then log("bad message: %s", tostring(rerun)) end
      if okMsg and rerun then nextScan = 0 end
    end
  end
end

for _, f in ipairs(feeders) do pcall(setIface, f, nil) end   -- hand stock back to the network
if modem and cfg.modemPort then modem.close(cfg.modemPort) end
log("stopped")
