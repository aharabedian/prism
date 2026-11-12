--[[ prism.setup.editor: the hardware half of prism.cfg as prism-setup's screen edits it. Pure: it takes
  the current config and a probe.snapshot(), and never touches components or files.

  Editor.KINDS            { id, label }[]: the hardware lists, in tab order (id = the prism.cfg list)
  Editor.new(old, snap, rules?) -> ed
                          old: prism.cfg as loaded (never changed); rules: the rules in use when they
                          aren't old.rules (prism-rules.cfg, edited on the control screen)
  ed.c                    the config being edited
  ed.snap                 the snapshot in use; ed.rescan(snap) swaps it, keeping every edit
  ed.rows(kind) -> row[]  row = { key, found?, entry? }: each component found (found = its snapshot entry),
                          then configured entries whose component wasn't found. entry nil = not used
  ed.row(kind, key) -> row | nil
  ed.assign(kind, key, process) -> true | nil, why   use the component for a process (adds its entry)
  ed.rename(kind, key, name)     "" or nil removes the name
  ed.drop(kind, key)             remove the entry (not used, or no longer there)
  ed.feederChoices(key) -> { interfaces = addr[], sides = { side, name, size }[] }
  ed.setFeeder(key, field, value)   field: "interface" | "interfaceSide" | "machineSide"
  ed.processes() -> names[]      processes to offer: the config's and the rules', then added ones
                                 (the standard ones when there are none)
  ed.addProcess(name)
  ed.set(key, value)             network, database, slotsPerBus, modemPort, token
  ed.result() -> config          what to render: ed.c with feeder slots numbered per interface
  ed.changes() -> lines[]        how the result differs from old: "+ bus eb111111 north: wash (Washer 1)"
  ed.warnings() -> lines[]       processes not served, missing database, components not found
]]

local U         = require("prism.util")
local processes = require("prism.setup.processes")

local Editor = {}

Editor.KINDS = {
  { id = "buses",      label = "bus" },
  { id = "stockers",   label = "stocker" },
  { id = "interfaces", label = "interface" },
  { id = "feeders",    label = "feeder" },
  { id = "machines",   label = "machine" },
}
local LABEL, SNAP = {}, { buses = "buses", stockers = "stockers", interfaces = "interfaces",
                          feeders = "transposers", machines = "machines" }
for _, k in ipairs(Editor.KINDS) do LABEL[k.id] = k.label end
local GENERAL = { "network", "database", "slotsPerBus", "modemPort", "token" }

local function sameAddr(full, prefix)
  return type(full) == "string" and type(prefix) == "string" and prefix ~= "" and full:sub(1, #prefix) == prefix
end
local function addrOf(kind, e) return kind == "feeders" and e.transposer or e.address end
local function entryKey(kind, e)
  return tostring(addrOf(kind, e)) .. (kind == "buses" and ("|" .. tostring(e.side)) or "")
end
local function foundKey(kind, f) return f.addr .. (kind == "buses" and ("|" .. f.side) or "") end
local function matches(kind, f, e)
  return sameAddr(f.addr, addrOf(kind, e)) and (kind ~= "buses" or e.side == f.side)
end
local function short(a) return tostring(a or "?"):sub(1, 8) end

-- "eb111111 north" for a bus, "tp000000" for a feeder's transposer...
local function where(kind, e)
  return short(addrOf(kind, e)) .. (kind == "buses" and (" " .. U.sideName(e.side)) or "")
end
local function describe(kind, e)
  local s = tostring(e.process) .. (e.name and (" (" .. e.name .. ")") or "")
  if kind == "feeders" then
    s = s .. (", interface %s, %s -> %s"):format(short(e.interface), U.sideName(e.interfaceSide), U.sideName(e.machineSide))
  end
  return s
end
local function show(k, v)
  if v == nil then return "none" end
  if k == "token" then return "(secret)" end
  if v == false then return "off" end
  return tostring(v)
end

function Editor.new(old, snap, rules)
  local ed = { snap = snap }
  local c = U.copy(old)
  for _, k in ipairs(Editor.KINDS) do
    c[k.id] = {}
    for i, e in ipairs(old[k.id] or {}) do c[k.id][i] = U.copy(e) end
  end
  ed.c = c
  local inUse = rules or old.rules or {}
  local added = {}

  function ed.rescan(s) ed.snap = s end

  -- ME interfaces a feeder may pull from: not the network's, not one another network pulls from.
  local function freeInterfaces()
    local out = {}
    for _, f in ipairs(ed.snap.interfaces or {}) do
      local taken = f.addr == c.network
      for _, e in ipairs(c.interfaces) do if sameAddr(f.addr, e.address) then taken = true end end
      if not taken then out[#out + 1] = f.addr end
    end
    return out
  end
  local function feeding(addr)
    for _, e in ipairs(c.feeders) do if sameAddr(addr, e.interface) then return true end end
  end

  function ed.rows(kind)
    local out, used = {}, {}
    for _, f in ipairs(ed.snap[SNAP[kind]] or {}) do
      local entry
      for _, e in ipairs(c[kind]) do if not used[e] and matches(kind, f, e) then entry = e end end
      -- The network's own interface and feeders' interfaces aren't outputs, unless the config says so.
      local hide = kind == "interfaces" and not entry and (f.addr == c.network or feeding(f.addr))
      if not hide then
        if entry then used[entry] = true end
        out[#out + 1] = { key = foundKey(kind, f), found = f, entry = entry }
      end
    end
    for _, e in ipairs(c[kind]) do
      if not used[e] then out[#out + 1] = { key = entryKey(kind, e), entry = e } end
    end
    return out
  end

  function ed.row(kind, key)
    for _, r in ipairs(ed.rows(kind)) do if r.key == key then return r end end
  end

  function ed.addProcess(name)
    if type(name) ~= "string" or name == "" or name == "ignore" then return end
    for _, p in ipairs(added) do if p == name then return end end
    added[#added + 1] = name
  end

  function ed.processes()
    local seen, list = {}, {}
    local function add(p)
      if type(p) == "string" and p ~= "ignore" and not seen[p] then seen[p] = true; list[#list + 1] = p end
    end
    for _, p in ipairs(processes.inConfig(old)) do add(p) end
    for _, r in ipairs(inUse) do add(r.process) end
    local named = {}
    for p in pairs(old.processes or {}) do named[#named + 1] = p end
    table.sort(named)
    for _, p in ipairs(named) do add(p) end
    for _, p in ipairs(processes.inConfig(c)) do add(p) end
    for _, p in ipairs(added) do add(p) end
    if #list == 0 then for _, s in ipairs(processes.STANDARD) do add(s.id) end end
    return list
  end

  function ed.assign(kind, key, process)
    local r = ed.row(kind, key)
    if not r then return nil, "nothing selected" end
    ed.addProcess(process)
    if r.entry then r.entry.process = process; return true end
    local f = r.found
    local e
    if kind == "buses" then
      e = { address = f.addr, side = f.side, process = process }
    elseif kind == "feeders" then
      if #f.inv < 2 then return nil, "this transposer touches fewer than two inventories" end
      local ifaces = freeInterfaces()
      if #ifaces == 0 then return nil, "no free ME interface with an adapter for a feeder to pull from" end
      local iface = ifaces[1]
      for _, a in ipairs(ifaces) do if not feeding(a) then iface = a; break end end
      local iside = f.ifaceSide or f.inv[1].side
      local mside = f.machineSide
      if not mside or mside == iside then
        for _, s in ipairs(f.inv) do if s.side ~= iside then mside = s.side; break end end
      end
      e = { interface = iface, transposer = f.addr, interfaceSide = iside, machineSide = mside, process = process }
    else
      e = { address = f.addr, process = process }
    end
    c[kind][#c[kind] + 1] = e
    return true
  end

  function ed.rename(kind, key, name)
    local r = ed.row(kind, key)
    if r and r.entry then r.entry.name = (name and name ~= "") and name or nil end
  end

  function ed.drop(kind, key)
    local r = ed.row(kind, key)
    if not (r and r.entry) then return end
    for i, e in ipairs(c[kind]) do if e == r.entry then table.remove(c[kind], i); return end end
  end

  function ed.feederChoices(key)
    local r = ed.row("feeders", key)
    local ifaces = freeInterfaces()
    if r and r.entry then
      local has = false
      for _, a in ipairs(ifaces) do if sameAddr(a, r.entry.interface) then has = true end end
      if not has then table.insert(ifaces, 1, r.entry.interface) end
    end
    return { interfaces = ifaces, sides = r and r.found and r.found.inv or {} }
  end

  function ed.setFeeder(key, field, value)
    local r = ed.row("feeders", key)
    if r and r.entry then r.entry[field] = value end
  end

  function ed.set(k, v) c[k] = v end

  function ed.result()
    local used = {}
    for _, f in ipairs(c.feeders) do
      used[f.interface] = (used[f.interface] or 0) + 1
      f.slot = used[f.interface]
    end
    return c
  end

  function ed.changes()
    local out = {}
    for _, k in ipairs(GENERAL) do
      local a, b = old[k], c[k]
      if k == "slotsPerBus" then a, b = a or 9, b or 9 end
      if a ~= b then out[#out + 1] = ("~ %s: %s -> %s"):format(k, show(k, a), show(k, b)) end
    end
    for _, kind in ipairs(Editor.KINDS) do
      local id, label = kind.id, kind.label
      local before = {}
      for _, e in ipairs(old[id] or {}) do before[entryKey(id, e)] = e end
      local now = {}
      for _, e in ipairs(c[id]) do
        local key = entryKey(id, e)
        now[key] = true
        local was = before[key]
        if not was then
          out[#out + 1] = ("+ %s %s: %s"):format(label, where(id, e), describe(id, e))
        elseif describe(id, was) ~= describe(id, e) then
          out[#out + 1] = ("~ %s %s: %s -> %s"):format(label, where(id, e), describe(id, was), describe(id, e))
        end
      end
      for _, e in ipairs(old[id] or {}) do
        if not now[entryKey(id, e)] then out[#out + 1] = ("- %s %s: %s"):format(label, where(id, e), describe(id, e)) end
      end
    end
    return out
  end

  function ed.warnings()
    local r = U.copy(ed.result())
    r.rules = inUse
    local out = processes.coverage(r, ed.processes())
    if not c.database and #c.buses + #c.feeders + #c.interfaces > 0 then
      out[#out + 1] = "export buses, interfaces and feeders need a Database Upgrade - the router won't start without one"
    end
    if not c.network then out[#out + 1] = "no ME network chosen - the router won't start without one" end
    for _, kind in ipairs(Editor.KINDS) do
      for _, row in ipairs(ed.rows(kind.id)) do
        if not row.found then
          out[#out + 1] = ("%s %s wasn't found - check its adapter, or drop it"):format(LABEL[kind.id], where(kind.id, row.entry))
        end
      end
    end
    return out
  end

  return ed
end

return Editor
