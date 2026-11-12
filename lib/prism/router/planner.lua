--[[ prism.router.planner: turn one network scan into ranked work per process. Pure: no I/O.

  plan(items, classify) -> scan
    items     getItemsInNetwork() stacks
    classify  function(label, key) -> process, priority, batch, fallback (see prism.rules)

  scan = {
    order      = key[]                          keys in network order (NBT variants merged)
    labels     = { [key] = label }
    present    = { [key] = quantity }
    queues     = { [process] = entry[] }        ranked: priority, then quantity, then key
    backlog    = { [process] = { types, items } }
    unassigned = { key, label, size }[]         largest first
    spilled    = { [process] = { types, items } }   shared with fallbacks by spill
  }
  entry = { key, stack, label, size, prio, batch, fallback?, from? }
    from: on the copy in a fallback's queue, the process it came from
  process "ignore" is neither queued nor unassigned.

  spill(scan, limits, held) -> sharedKeys   { [key] = true }
    Shares items with a fallback with that process when theirs has too much waiting: the item stays in
    its own queue and backlog, and a copy joins its fallback's, so both pull from the same stock.
    limits  { [process] = { overflow = items?, diverted = bool? } }   diverted: as overflow = 0
    held    what was shared last scan (pass the previous result; {} at first)
    While the unshared items add up to more than `overflow`, items with a fallback are shared,
    lowest-ranked first (the top one too, if it's the one that can be). A shared item stops being
    shared once the unshared items plus it fit under 3/4 of `overflow`, highest-ranked first, so items
    don't flip back and forth. Items without a fallback are never shared but count towards `overflow`.
    Copies keep their priority and batch, and are never shared again from the fallback.
]]

local U = require("prism.util")

local P = {}

local function rank(a, b)
  if a.prio ~= b.prio then return a.prio > b.prio end
  if a.size ~= b.size then return a.size > b.size end
  return a.key < b.key
end

function P.plan(items, classify)
  -- the same item with different NBT shows up as separate stacks
  local merged, order = {}, {}
  for _, st in ipairs(items) do
    if st.name and (st.size or 0) > 0 then
      local key = U.keyOf(st)
      local m = merged[key]
      if m then m.size = m.size + st.size
      else merged[key] = { key = key, stack = st, label = st.label or key, size = st.size }; order[#order + 1] = key end
    end
  end

  local scan = { order = order, labels = {}, present = {}, queues = {}, backlog = {}, unassigned = {}, spilled = {} }
  for _, key in ipairs(order) do
    local e = merged[key]
    scan.labels[key], scan.present[key] = e.label, e.size
    local proc, prio, batch, fallback = classify(e.label, key)
    if proc == nil then
      scan.unassigned[#scan.unassigned + 1] = { key = key, label = e.label, size = e.size }
    elseif proc ~= "ignore" then
      e.prio, e.batch, e.fallback = prio, math.max(1, math.floor(batch or 1)), fallback
      local q = scan.queues[proc] or {}
      q[#q + 1] = e
      scan.queues[proc] = q
      local b = scan.backlog[proc] or { types = 0, items = 0 }
      b.types, b.items = b.types + 1, b.items + e.size
      scan.backlog[proc] = b
    end
  end
  for _, q in pairs(scan.queues) do table.sort(q, rank) end
  table.sort(scan.unassigned, function(a, b) return a.size > b.size end)
  return scan
end

local function addTo(t, proc, size)
  local b = t[proc] or { types = 0, items = 0 }
  b.types, b.items = b.types + 1, b.items + size
  t[proc] = b
end

function P.spill(scan, limits, held)
  local shares, shared = {}, {}
  for proc, q in pairs(scan.queues) do
    local lim = limits[proc] or {}
    local overflow = lim.diverted and 0 or tonumber(lim.overflow)
    if overflow then
      local function wasShared(e) return e.fallback and held[e.key] end
      local unshared = 0
      for _, e in ipairs(q) do if not wasShared(e) then unshared = unshared + e.size end end
      local back = math.floor(overflow * 3 / 4)
      for _, e in ipairs(q) do                    -- shared last scan: stop if it fits, best first
        if wasShared(e) then
          if unshared + e.size <= back then unshared = unshared + e.size else shared[e.key] = true end
        end
      end
      for i = #q, 1, -1 do                        -- still too much: share from the bottom up
        if unshared <= overflow then break end
        local e = q[i]
        if e.fallback and not shared[e.key] then shared[e.key] = true; unshared = unshared - e.size end
      end
      for _, e in ipairs(q) do
        if shared[e.key] and e.fallback then shares[#shares + 1] = { e = e, from = proc } end
      end
    end
  end
  local touched = {}
  for _, sh in ipairs(shares) do
    local copy = {}
    for k, v in pairs(sh.e) do copy[k] = v end
    copy.from = sh.from
    addTo(scan.spilled, sh.from, copy.size)
    addTo(scan.backlog, copy.fallback, copy.size)
    local q = scan.queues[copy.fallback] or {}
    q[#q + 1] = copy
    scan.queues[copy.fallback], touched[copy.fallback] = q, true
  end
  for proc in pairs(touched) do table.sort(scan.queues[proc], rank) end
  return shared
end

return P
