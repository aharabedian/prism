--[[ prism-setup.lua - guided setup for either PRISM computer.

  Usage: prism-setup

  Asks whether this computer is the router or the control screen, then:
    router:  processes and starting rules, ME network, database, export buses,
             stocking input buses, feeders, GT machines, wireless, start on boot
             -> /home/prism.cfg
    screen:  wireless, beep, start on boot                -> /home/prism-control.cfg
  Start on boot adds (or removes) the program in /home/.shrc, which the OpenOS
  shell runs when the computer boots.

  Run it again any time: the current settings are offered as defaults (press
  Enter to keep one, "-" to drop it). Settings it doesn't ask about, like
  interval or overrides, are kept. The previous file is saved as <file>.bak.
  Ctrl+D cancels without saving anything.

  Tip: to tell export buses apart, drop a different "marker" item into slot 1
  of each bus's filter by hand first (cobblestone in the washer bus, ...).
  Stocking input buses: the same, in slot 1 of their configuration.
]]

local component  = require("component")
local filesystem = require("filesystem")
local sides      = require("sides")

local VERSION = "0.5.0"

local PREFIX      = os.getenv("PRISM_PREFIX") or ""   -- lets the test suite use a temp dir
local HOME        = PREFIX .. "/home"
local ROUTER_CFG  = HOME .. "/prism.cfg"
local CONTROL_CFG = HOME .. "/prism-control.cfg"
local RULES_PATH  = HOME .. "/prism-rules.cfg"
local SHRC        = HOME .. "/.shrc"

local SIDE_NAMES = { [0] = "down", "up", "north", "south", "west", "east" }
local CANCEL = {}   -- raised (as an error) when input ends

-- Processes offered to the router, in ore-processing order. Names are free text to
-- the router; these are just sensible defaults that the starting rules use.
local STANDARD = {
  { id = "crush",      machine = "Macerator" },
  { id = "wash",       machine = "Ore Washer" },
  { id = "thermal",    machine = "Thermal Centrifuge" },
  { id = "centrifuge", machine = "Centrifuge" },
  { id = "sift",       machine = "Sifter (gem ores)" },
}
local DEFAULT_PROCESSES = { "crush", "wash", "centrifuge" }
local SIFT_GEMS = { "Diamond", "Emerald", "Ruby", "Sapphire", "Green Sapphire", "Olivine",
                    "Topaz", "Tanzanite", "Amethyst", "Opal" }

-- Router settings the wizard doesn't ask about: written with these defaults (or the
-- current value) so the file shows every option. Same defaults as prism.lua.
local ROUTER_TUNING = {
  { "interval",        5,     "seconds between network scans" },
  { "feedInterval",    1,     "seconds between feeder steps" },
  { "monitorInterval", 2,     "seconds between GT machine polls" },
  { "stallAfter",      60,    "seconds of items waiting with nothing moving before a stall alert" },
  { "idleAlert",       30,    "seconds a monitored machine may sit idle with work waiting" },
  { "defaultPriority", 10,    "priority for rules and overrides that don't set one" },
  { "verbose",         false, "log every filter and interface change" },
}
local CONTROL_TUNING = {
  { "history",    60, "backlog samples kept for the sparklines" },
  { "staleAfter", 3,  "missed router cycles before showing NO SIGNAL" },
  { "batches",    { 1, 2, 3, 4, 6, 8, 9, 16, 32, 36, 64 }, "batch buttons offered on the screen" },
}

---------------------------------------------------------------- input

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- Prompt for a line. Blank returns `default`; end of input cancels the wizard.
local function ask(prompt, default)
  io.write(prompt .. (default and (" [" .. default .. "]") or "") .. ": ")
  local line = io.read()
  if line == nil then error(CANCEL, 0) end
  line = trim(line)
  if line == "" then return default end
  return line
end

local function yes(prompt, default)
  return ask(prompt .. " (y/n)", default and "y" or "n"):lower():sub(1, 1) == "y"
end

-- Numbered choice from `labels`; returns the index.
local function choose(labels, default)
  for i, l in ipairs(labels) do print(("  %d) %s"):format(i, l)) end
  while true do
    local n = tonumber(ask(("  choose 1-%d"):format(#labels), default and tostring(default)))
    if n and labels[n] then return n end
    print("  enter a number from the list")
  end
end

local function processHint(procs)
  local parts = {}
  for i, p in ipairs(procs) do parts[i] = i .. ") " .. p end
  print("  processes: " .. table.concat(parts, "  "))
end

-- Ask which process a component serves: a number from `procs`, or a new name
-- (added to `procs`). Returns process, name - or nil to skip the component.
local function askProcess(what, old, procs)
  local default = old and old.process
  local a = ask(("  process for %s (number or name, %s)"):format(what, default and "- skips" or "Enter skips"), default)
  if a == nil or a == "-" then return nil end
  local n = tonumber(a)
  if n and procs[n] then a = procs[n]
  elseif n then print("  (no process " .. a .. " in the list; using it as a name)") end
  local known = false
  for _, p in ipairs(procs) do if p == a then known = true end end
  if not known then procs[#procs + 1] = a end
  local name = ask("  name (optional)", old and old.name)
  if name == "-" then name = nil end
  return a, name
end

-- Returns the port, or false for wireless off (false, not nil: the screen treats a missing port as 4242).
local function askPort(old)
  local default = old == nil and "4242" or tostring(old or 0)
  while true do
    local port = tonumber(ask("  wireless port (0 turns wireless off)", default))
    if port and port == math.floor(port) and port >= 0 and port <= 65535 then
      return port > 0 and math.floor(port) or false
    end
    print("  enter a port from 1 to 65535, or 0")
  end
end

local function askToken(old)
  local token = ask("  shared secret (optional, - for none)", type(old) == "string" and old or nil)
  if token == "-" then token = nil end
  return token
end

---------------------------------------------------------------- files

local function loadLua(path)
  if not filesystem.exists(path) then return nil end
  local fn = loadfile(path, "t", { sides = sides })
  if not fn then return nil end
  local ok, t = pcall(fn)
  return ok and type(t) == "table" and t or nil
end

local function readFile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function writeFile(path, text)
  local tmp = path .. ".new"
  local f, err = io.open(tmp, "w")
  if not f then return false, err end
  f:write(text)
  f:close()
  if filesystem.exists(path) then filesystem.remove(path) end
  filesystem.rename(tmp, path)
  return true
end

-- Keep the previous version as <path>.bak, then write.
local function saveWithBackup(path, text)
  local old = readFile(path)
  if old and old ~= text then
    local ok, err = writeFile(path .. ".bak", old)
    if not ok then return false, err end
  end
  return writeFile(path, text)
end

---------------------------------------------------------------- rendering Lua

local function q(s) return string.format("%q", s) end
local function sideRef(s) return "sides." .. (SIDE_NAMES[s] or tostring(s)) end

-- Any plain value as Lua source, keys sorted so the output is stable.
local function lua(v)
  if type(v) == "string" then return q(v) end
  if type(v) ~= "table" then return tostring(v) end
  local parts, n = {}, #v
  for i = 1, n do parts[#parts + 1] = lua(v[i]) end
  local keys = {}
  for k in pairs(v) do
    if not (math.type(k) == "integer" and k >= 1 and k <= n) then keys[#keys + 1] = k end
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(keys) do
    local ks = type(k) == "string" and k:match("^[%a_][%w_]*$") and k or ("[" .. lua(k) .. "]")
    parts[#parts + 1] = ks .. " = " .. lua(v[k])
  end
  if #parts == 0 then return "{}" end
  return "{ " .. table.concat(parts, ", ") .. " }"
end

local function setting(L, key, value, comment)
  local line = ("  %s = %s,"):format(key, value == nil and "nil" or lua(value))
  L[#L + 1] = comment and (("%-34s -- %s"):format(line, comment)) or line
end

-- Keys of `t` not in `known`, so hand-added settings survive a rewrite.
local function extras(L, t, known)
  local keys = {}
  for k in pairs(t) do if not known[k] then keys[#keys + 1] = k end end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  if #keys > 0 then L[#L + 1] = "" end
  for _, k in ipairs(keys) do
    local ks = type(k) == "string" and k:match("^[%a_][%w_]*$") and k or ("[" .. lua(k) .. "]")
    L[#L + 1] = ("  %s = %s,"):format(ks, lua(t[k]))
  end
end

local function renderRouter(c)
  local L = {
    "-- prism.cfg - written by prism-setup " .. VERSION .. ". Run prism-setup to change it; values you",
    "-- edit by hand are kept when it rewrites this file (comments aren't). Every option: docs/configuration.md",
    "return {",
  }
  local known = {}
  for _, t in ipairs(ROUTER_TUNING) do
    known[t[1]] = true
    local v = c[t[1]]
    if v == nil then v = t[2] end
    setting(L, t[1], v, t[3])
  end
  L[#L + 1] = ""
  setting(L, "network", c.network, "ME controller/interface to scan")
  setting(L, "database", c.database, "Database Upgrade used to stage items")
  setting(L, "modemPort", c.modemPort, "wireless port for the control screen; false = off")
  setting(L, "token", c.token, "shared secret the screen must send; nil = none")
  setting(L, "slotsPerBus", c.slotsPerBus or 9, "filter slots per export bus: 1, 5 or 9")
  for _, k in ipairs({ "network", "database", "modemPort", "token", "slotsPerBus",
                       "buses", "stockers", "feeders", "machines", "rules", "overrides" }) do known[k] = true end

  local function opt(name) return name and (", name = " .. q(name)) or "" end
  L[#L + 1] = ""
  L[#L + 1] = "  buses = {"
  for _, b in ipairs(c.buses or {}) do
    L[#L + 1] = ("    { address = %s, side = %s, process = %s%s },")
      :format(q(b.address), sideRef(b.side), q(b.process), opt(b.name))
  end
  L[#L + 1] = "  },"
  L[#L + 1] = "  stockers = {"
  for _, b in ipairs(c.stockers or {}) do
    L[#L + 1] = ("    { address = %s, process = %s%s },"):format(q(b.address), q(b.process), opt(b.name))
  end
  L[#L + 1] = "  },"
  L[#L + 1] = "  feeders = {"
  for _, f in ipairs(c.feeders or {}) do
    L[#L + 1] = ("    { interface = %s, transposer = %s, interfaceSide = %s, machineSide = %s,%s"):format(
      q(f.interface), q(f.transposer), sideRef(f.interfaceSide), sideRef(f.machineSide),
      f.slot and f.slot > 1 and (" slot = " .. f.slot .. ",") or "")
    L[#L + 1] = ("      process = %s%s },"):format(q(f.process), opt(f.name))
  end
  L[#L + 1] = "  },"
  L[#L + 1] = "  machines = {"
  for _, m in ipairs(c.machines or {}) do
    L[#L + 1] = ("    { address = %s, process = %s%s },"):format(q(m.address), q(m.process), opt(m.name))
  end
  L[#L + 1] = "  },"

  L[#L + 1] = ""
  L[#L + 1] = "  -- Matched against item names, first match wins. Editing rules on the control screen"
  L[#L + 1] = "  -- saves prism-rules.cfg, which replaces this list until RESET TO prism.cfg."
  L[#L + 1] = "  rules = {"
  for _, r in ipairs(c.rules or {}) do
    L[#L + 1] = ("    { pattern = %s, process = %s%s%s },"):format(q(r.pattern), q(r.process),
      r.priority and (", priority = " .. r.priority) or "", r.batch and (", batch = " .. r.batch) or "")
  end
  L[#L + 1] = "  },"
  L[#L + 1] = "  -- Per-item overrides beat the rules. Key = \"itemname:damage\" (the router logs these)."
  L[#L + 1] = "  overrides = {"
  local keys = {}
  for k in pairs(c.overrides or {}) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do L[#L + 1] = ("    [%s] = %s,"):format(q(k), lua(c.overrides[k])) end
  L[#L + 1] = "  },"
  extras(L, c, known)
  L[#L + 1] = "}"
  return table.concat(L, "\n") .. "\n"
end

local function renderControl(c)
  local L = {
    "-- prism-control.cfg - written by prism-setup " .. VERSION .. ". Settings for the control screen;",
    "-- run prism-setup to change them. Values you edit by hand are kept when it rewrites this file.",
    "return {",
  }
  setting(L, "modemPort", c.modemPort, "must match modemPort in the router's prism.cfg")
  setting(L, "token", c.token, "must match token there; nil = none")
  setting(L, "beep", c.beep ~= false, "beep when a new alert appears")
  local known = { modemPort = true, token = true, beep = true }
  for _, t in ipairs(CONTROL_TUNING) do
    known[t[1]] = true
    local v = c[t[1]]
    if v == nil then v = t[2] end
    setting(L, t[1], v, t[3])
  end
  extras(L, c, known)
  L[#L + 1] = "}"
  return table.concat(L, "\n") .. "\n"
end

---------------------------------------------------------------- helpers

local function sameAddr(full, prefix)
  return type(prefix) == "string" and prefix ~= "" and full:sub(1, #prefix) == prefix
end

local function findOld(list, fn)
  for _, e in ipairs(list or {}) do if fn(e) then return e end end
end

local function addresses(ctype)
  local out = {}
  for addr in component.list(ctype) do out[#out + 1] = addr end
  table.sort(out)
  return out
end

-- Pick one address from `list`: automatically when there is one, else ask.
local function pickOne(list, old)
  if #list == 1 then return list[1] end
  local default
  for i, a in ipairs(list) do if sameAddr(a, old) then default = i end end
  return list[choose(list, default)]
end

local step, steps = 0, 0
local function header(text) step = step + 1; print(""); print(("%d/%d %s"):format(step, steps, text)) end

local function hasWireless()
  for addr in component.list("modem") do
    local m = component.proxy(addr)
    if m.isWireless and m.isWireless() then return true end
  end
  return false
end

---------------------------------------------------------------- router: processes + rules

-- Starting rules for a set of processes, falling back to whatever is there:
-- crushed ore is washed if possible, else thermal-centrifuged, else macerated.
local function rulesFor(has)
  local rules = {}
  local function add(pattern, process, priority)
    if process then rules[#rules + 1] = { pattern = pattern, process = process, priority = priority } end
  end
  local function first(...)
    for _, p in ipairs({ ... }) do if has[p] then return p end end
  end
  if has.sift then
    for _, g in ipairs(SIFT_GEMS) do add("^Purified " .. g .. " Ore$", "sift", 15) end
  end
  add("^Crushed .+ Ore$",           first("wash", "thermal", "crush"), 10)
  add("^Purified .+ Ore$",          first("crush", "thermal"), 10)
  add("^Centrifuged .+ Ore$",       first("crush"), 10)
  add("^Impure Pile of .+ Dust$",   first("centrifuge"), 10)
  add("^Purified Pile of .+ Dust$", first("centrifuge"), 10)
  add("Ore$",                       first("crush"), 5)
  return rules
end

local function sameRules(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i].pattern ~= b[i].pattern or a[i].process ~= b[i].process or a[i].priority ~= b[i].priority
      or (a[i].batch or 1) ~= (b[i].batch or 1) then return false end
  end
  return true
end

-- Every process the current config mentions, in first-seen order.
local function processesIn(old)
  local seen, list = {}, {}
  local function add(p)
    if type(p) == "string" and p ~= "ignore" and not seen[p] then seen[p] = true; list[#list + 1] = p end
  end
  for _, key in ipairs({ "rules", "buses", "stockers", "feeders", "machines" }) do
    for _, e in ipairs(old[key] or {}) do add(e.process) end
  end
  return list
end

-- Returns the chosen process list and the rules to use.
local function stepProcesses(old)
  header("Processes and rules")
  print("  Which processes do you have machines for? Numbers separated by spaces; you can also type new names.")
  local options, isOption = {}, {}
  for _, s in ipairs(STANDARD) do
    options[#options + 1] = { id = s.id, label = ("%-11s %s"):format(s.id, s.machine) }
    isOption[s.id] = true
  end
  local previous = processesIn(old)
  for _, p in ipairs(previous) do
    if not isOption[p] then
      options[#options + 1] = { id = p, label = ("%-11s (from your config)"):format(p) }
      isOption[p] = true
    end
  end
  local defaults = {}
  for i, o in ipairs(options) do
    for _, p in ipairs(#previous > 0 and previous or DEFAULT_PROCESSES) do
      if o.id == p then defaults[#defaults + 1] = tostring(i) end
    end
  end
  for i, o in ipairs(options) do print(("  %d) %s"):format(i, o.label)) end

  local procs, has
  while true do
    procs, has = {}, {}
    local answer = ask("  processes", table.concat(defaults, " ")) or ""
    for word in answer:gmatch("[^%s,]+") do
      local n = tonumber(word)
      local p = n and options[n] and options[n].id or (not n and word) or nil
      if p and not has[p] then has[p] = true; procs[#procs + 1] = p end
    end
    if #procs > 0 then break end
    print("  pick at least one")
  end

  local generated = rulesFor(has)
  local current = old.rules or {}
  local rules
  if sameRules(generated, current) then
    print(("  rules: the %d standard rules for these processes"):format(#generated))
    rules = generated
  elseif #generated == 0 then
    print("  no standard rules for these processes - write your own on the control screen's RULES tab")
    rules = current
  else
    print("  Standard rules for these processes (first match wins):")
    for _, r in ipairs(generated) do print(("    %-30s -> %s"):format(r.pattern, r.process)) end
    if #current == 0 or yes(("  use these instead of your current %d rule(s)?"):format(#current), false) then
      rules = generated
    else
      rules = current
    end
  end
  if filesystem.exists(RULES_PATH) then
    print("  note: rules edited on the control screen (" .. RULES_PATH .. ") stay in use;")
    print("  press RESET TO prism.cfg on the RULES tab to switch to these.")
  end
  return procs, rules
end

---------------------------------------------------------------- router: hardware

local function stepNetwork(old)
  header("ME network")
  local list = addresses("me_controller")
  if #list == 0 then list = addresses("me_interface") end
  if #list == 0 then
    print("  none found - put an adapter against the subnet's ME controller (or an ME interface on it), then run this again")
    return nil
  end
  local addr = pickOne(list, old)
  print("  using " .. addr)
  return addr
end

local function stepDatabase(old)
  header("Database Upgrade")
  local list = addresses("database")
  if #list == 0 then
    print("  none found - only export buses and feeders need one; skipping them")
    print("  (put a Database Upgrade inside an adapter and run this again to set them up)")
    return nil
  end
  local addr = pickOne(list, old)
  print("  using " .. addr)
  return addr
end

-- Returns the buses and the filter slots per bus.
local function stepBuses(old, oldSlots, procs)
  header("Export buses (tip: a marker item in slot 1 of a bus's filter shows which one it is)")
  local found = {}
  for _, addr in ipairs(addresses("me_exportbus")) do
    local p = component.proxy(addr)
    for side = 0, 5 do
      -- No bus on a side either throws or returns nil, "reason".
      local ok, stack, err = pcall(p.getExportConfiguration, side, 1)
      if ok and not (stack == nil and err) then found[#found + 1] = { addr = addr, side = side, stack = stack } end
    end
  end
  if #found == 0 then
    print("  none found - put an adapter against the cable block your export buses are on")
    return {}, oldSlots
  end

  local slots
  while true do
    slots = tonumber(ask("  Capacity Cards per bus: 0, 1 or 2", ({ [1] = "0", [5] = "1", [9] = "2" })[oldSlots or 9]))
    if slots == 0 or slots == 1 or slots == 2 then break end
    print("  enter 0, 1 or 2")
  end
  slots = ({ [0] = 1, 5, 9 })[slots]

  local out = {}
  processHint(procs)
  for _, b in ipairs(found) do
    local marker = b.stack and (b.stack.label or b.stack.name) or "(empty)"
    print(("  bus %s, %s side - slot 1: %s"):format(b.addr:sub(1, 8), SIDE_NAMES[b.side], marker))
    local prev = findOld(old, function(e) return e.side == b.side and sameAddr(b.addr, e.address) end)
    local proc, name = askProcess("this bus", prev, procs)
    if proc then out[#out + 1] = { address = b.addr, side = b.side, process = proc, name = name } end
  end
  return out, slots
end

local function stepStockers(old, procs)
  header("Stocking input buses (GT multiblocks; a marker in slot 1 shows which one it is)")
  local out = {}
  local list = addresses("me_inputbus")
  if #list == 0 then
    print("  none - put an adapter against each Stocking Input Bus (ME) you want PRISM to fill")
    return out
  end
  processHint(procs)
  for _, addr in ipairs(list) do
    local p = component.proxy(addr)
    local okC, st = pcall(p.getConfiguration, 1)
    local marker = okC and type(st) == "table" and (st.label or st.name) or "(empty)"
    local okA, adv = pcall(p.isAdvanced)
    print(("  stocking bus %s%s - slot 1: %s"):format(addr:sub(1, 8), okA and adv and ", advanced" or "", marker))
    local prev = findOld(old, function(e) return sameAddr(addr, e.address) end)
    local proc, name = askProcess("this stocking bus", prev, procs)
    if proc then out[#out + 1] = { address = addr, process = proc, name = name } end
  end
  return out
end

-- Which transposer sides face the ME interface and the machine, from inventory names.
local function feederSides(t)
  local inv = {}
  for side = 0, 5 do
    local ok, size = pcall(t.getInventorySize, side)
    if ok and type(size) == "number" then
      local okName, name = pcall(t.getInventoryName, side)
      inv[#inv + 1] = { side = side, name = okName and tostring(name) or "?", size = size }
    end
  end
  local ifaceSide, machineSide
  local others = {}
  for _, s in ipairs(inv) do
    if s.name:lower():find("interface", 1, true) and not ifaceSide then ifaceSide = s.side
    else others[#others + 1] = s end
  end
  if #others == 1 then machineSide = others[1].side end
  return inv, ifaceSide, machineSide
end

local function askSide(what, inv)
  print("    which side is the " .. what .. "?")
  local labels = {}
  for i, s in ipairs(inv) do labels[i] = ("%-6s %s (%d slots)"):format(SIDE_NAMES[s.side], s.name, s.size) end
  return inv[choose(labels)].side
end

local function stepFeeders(old, network, procs)
  header("Feeders (ME Interface block -> transposer -> machine, for batch items)")
  local out = {}
  local transposers = addresses("transposer")
  if #transposers == 0 then print("  no transposers - skipping"); return out end
  local ifaces = {}
  for _, a in ipairs(addresses("me_interface")) do if a ~= network then ifaces[#ifaces + 1] = a end end
  if #ifaces == 0 then
    print("  no ME interface with an adapter (other than the network one) - skipping")
    return out
  end
  processHint(procs)
  local slotsUsed = {}
  for _, addr in ipairs(transposers) do
    local inv, ifaceSide, machineSide = feederSides(component.proxy(addr))
    print(("  transposer %s"):format(addr:sub(1, 8)))
    if #inv < 2 then
      print("    touches fewer than two inventories - skipping")
    else
      local prev = findOld(old, function(f) return sameAddr(addr, f.transposer) end)
      if prev and prev.interfaceSide and prev.machineSide then
        ifaceSide, machineSide = prev.interfaceSide, prev.machineSide
      end
      if ifaceSide and machineSide then
        print(("    interface on %s, machine on %s"):format(SIDE_NAMES[ifaceSide], SIDE_NAMES[machineSide]))
      end
      local proc, name = askProcess("this feeder", prev, procs)
      if proc then
        ifaceSide = ifaceSide or askSide("ME interface", inv)
        machineSide = machineSide or askSide("machine", inv)
        if #ifaces > 1 then print("    which ME interface block does it pull from?") end
        local iface = pickOne(ifaces, prev and prev.interface)
        slotsUsed[iface] = (slotsUsed[iface] or 0) + 1
        out[#out + 1] = { interface = iface, transposer = addr, interfaceSide = ifaceSide,
                          machineSide = machineSide, slot = slotsUsed[iface], process = proc, name = name }
      end
    end
  end
  return out
end

local function stepMachines(old, procs)
  header("GT machines to monitor (toggle one with a soft mallet to see it change to disabled)")
  local out = {}
  local list = addresses("gt_machine")
  if #list == 0 then print("  none - put an adapter against each GT machine you want to watch"); return out end
  processHint(procs)
  for _, addr in ipairs(list) do
    local m = component.proxy(addr)
    local function try(fn)
      if m[fn] == nil then return nil end
      local ok, v = pcall(m[fn])
      if ok then return v end
      return nil
    end
    local where = ""
    if m.getCoordinates then
      local ok, x, y, z = pcall(m.getCoordinates)
      if ok and x then where = (" at %s %s %s"):format(tostring(x), tostring(y), tostring(z)) end
    end
    local allowed, active = try("isWorkAllowed"), try("isMachineActive")
    local state = allowed == false and "disabled" or (active and "working" or "idle")
    print(("  machine %s, %s%s"):format(addr:sub(1, 8), state, where))
    local prev = findOld(old, function(e) return sameAddr(addr, e.address) end)
    local proc, name = askProcess("this machine", prev, procs)
    if proc then out[#out + 1] = { address = addr, process = proc, name = name } end
  end
  return out
end

-- Processes that something will route but nothing receives, and the other way round.
local function coverage(c, procs)
  local served, routed = {}, {}
  for _, key in ipairs({ "buses", "stockers", "feeders" }) do
    for _, e in ipairs(c[key] or {}) do served[e.process] = true end
  end
  for _, r in ipairs(c.rules or {}) do routed[r.process] = true end
  local warnings = {}
  for _, p in ipairs(procs) do
    if routed[p] and not served[p] then
      warnings[#warnings + 1] = ("no bus, stocker or feeder for %q - its items will wait in the network"):format(p)
    elseif served[p] and not routed[p] then
      warnings[#warnings + 1] = ("no rule sends anything to %q - route items on the control screen"):format(p)
    end
  end
  return warnings
end

---------------------------------------------------------------- start on boot

local function programOf(line)
  local word = line:match("^%s*(%S+)")
  return word and (word:gsub("^.*/", ""):gsub("%.lua$", ""))
end

-- Returns the new .shrc text, or nil when nothing changes.
local function stepAutostart(program)
  header("Start on boot")
  local text = readFile(SHRC) or ""
  local lines, present, other = {}, false, nil
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
  if lines[#lines] == "" then lines[#lines] = nil end
  for _, line in ipairs(lines) do
    local p = programOf(line)
    if p == program then present = true
    elseif p == "prism" or p == "prism-control" then other = p end
  end
  print("  /home/.shrc runs when the computer boots into its shell; Ctrl+C in " .. program .. " gets you the shell")
  local want = yes(("  start %s when this computer boots?"):format(program), true)
  if other then print(("  (removing %s from .shrc - this computer is now the %s)"):format(other,
    program == "prism" and "router" or "control screen")) end
  if want == present and not other then return nil end
  local out = {}
  for _, line in ipairs(lines) do
    local p = programOf(line)
    if p ~= "prism" and p ~= "prism-control" then out[#out + 1] = line end
  end
  if want then out[#out + 1] = program end
  return #out > 0 and (table.concat(out, "\n") .. "\n") or ""
end

---------------------------------------------------------------- the two roles

local function review(path, text, shrc)
  print("")
  print("This will be saved to " .. path .. ":")
  io.write(text)
  if shrc then print(""); print("and " .. SHRC .. " will be:"); io.write(shrc ~= "" and shrc or "(empty)\n") end
end

local function commit(path, text, shrc)
  local ok, err = saveWithBackup(path, text)
  if not ok then print("can't write " .. path .. ": " .. tostring(err)); return false end
  if shrc then
    ok, err = writeFile(SHRC, shrc)
    if not ok then print("can't write " .. SHRC .. ": " .. tostring(err)); return false end
  end
  return true
end

local function setupRouter()
  steps = 9
  local old = loadLua(ROUTER_CFG) or {}
  if filesystem.exists(ROUTER_CFG) then print("Editing " .. ROUTER_CFG) end
  local c = {}
  for k, v in pairs(old) do c[k] = v end

  local procs
  procs, c.rules = stepProcesses(old)
  c.network = stepNetwork(old.network)
  if not c.network then return end
  c.database = stepDatabase(old.database)
  -- Without a database, export buses and feeders can't be configured: keep what was there.
  if c.database then
    c.buses, c.slotsPerBus = stepBuses(old.buses, old.slotsPerBus, procs)
  else
    c.buses = old.buses or {}; step = step + 1
  end
  c.stockers = stepStockers(old.stockers, procs)
  if c.database then
    c.feeders = stepFeeders(old.feeders, c.network, procs)
  else
    c.feeders = old.feeders or {}; step = step + 1
  end
  c.machines = stepMachines(old.machines, procs)

  header("Wireless link to the control screen")
  if not hasWireless() then print("  no Wireless Network Card found - the control screen needs one in this computer") end
  c.modemPort = askPort(old.modemPort)
  c.token = c.modemPort and askToken(old.token) or nil

  local shrc = stepAutostart("prism")
  local text = renderRouter(c)
  review(ROUTER_CFG, text, shrc)
  for _, w in ipairs(coverage(c, procs)) do print("warning: " .. w) end
  if not c.database and #c.buses + #c.feeders > 0 then
    print("warning: export buses and feeders need a Database Upgrade - the router won't start without one")
  end
  if not yes("Save?", true) then print("nothing saved"); return end
  if not commit(ROUTER_CFG, text, shrc) then return end
  print(("saved %d bus(es), %d stocker(s), %d feeder(s), %d machine(s), %d rule(s)."):format(
    #c.buses, #c.stockers, #c.feeders, #c.machines, #c.rules))
  if c.modemPort then
    print(("On the control computer, run prism-setup and choose the control screen: port %d, secret %s.")
      :format(c.modemPort, c.token and q(c.token) or "none"))
  end
  print("Start prism to use it (or press RELOAD CFG on the control screen if it's running).")
end

local function setupControl()
  steps = 3
  local old = loadLua(CONTROL_CFG) or {}
  if filesystem.exists(CONTROL_CFG) then print("Editing " .. CONTROL_CFG) end
  local c = {}
  for k, v in pairs(old) do c[k] = v end

  header("Wireless link to the router")
  if not hasWireless() then print("  no Wireless Network Card found - the control screen needs one") end
  print("  use the same port and secret as the router (prism-setup printed them there)")
  c.modemPort = askPort(old.modemPort)
  c.token = c.modemPort and askToken(old.token) or nil

  header("Alerts")
  c.beep = yes("  beep when a new alert appears?", old.beep ~= false)

  local shrc = stepAutostart("prism-control")
  local text = renderControl(c)
  review(CONTROL_CFG, text, shrc)
  if not c.modemPort then print("warning: with wireless off the screen can't reach the router") end
  if component.isAvailable("gpu") then
    local w, h = component.gpu.maxResolution()
    if w < 160 or h < 50 then print(("warning: this GPU/screen gives %dx%d; prism-control wants a tier 3 (160x50)"):format(w, h)) end
  else
    print("warning: no GPU found - prism-control needs a tier 3 GPU and screen")
  end
  if not yes("Save?", true) then print("nothing saved"); return end
  if not commit(CONTROL_CFG, text, shrc) then return end
  print("saved. Start prism-control to use it.")
end

local function main()
  print("prism-setup " .. VERSION .. " - Enter keeps the [default], - skips, Ctrl+D cancels")
  print("")
  print("What is this computer?")
  -- Guess from what's attached: the router has adapters on ME parts.
  local router = false
  for _, t in ipairs({ "me_controller", "me_interface", "me_exportbus", "me_inputbus", "database" }) do
    if component.isAvailable(t) then router = true end
  end
  local role = choose({
    "router - does the routing (adapters on the ME network, buses and machines)",
    "control screen - the touchscreen display that talks to the router",
  }, router and 1 or 2)
  if role == 1 then setupRouter() else setupControl() end
end

local ok, err = pcall(main)
if not ok then
  if err == CANCEL then print(""); print("cancelled - nothing saved")
  else error(err, 0) end
end
