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
    spilled    = { [process] = { types, items } }   moved to fallbacks by spill (empty until then)
  }
  entry = { key, stack, label, size, prio, batch, fallback?, from? }   from: the process it spilled from
  process "ignore" is neither queued nor unassigned.

  spill(scan, limits, held) -> spilledKeys   { [key] = "overflow" | "diverted" }
    Moves items with a fallback out of a process that has too much waiting, into their fallback's queue.
    limits  { [process] = { overflow = items?, diverted = bool? } }
    held    what spilled last scan (pass the previous result; {} at first)
    Walking a process's queue in rank order, an item with a fallback spills when the items ranked above
    it reach `overflow`, and comes back only once it fits entirely under 3/4 of `overflow`, so items
    don't bounce between processes. Diverted: every item with a fallback spills; when that stops, only
    overflow decides again. Items without a
    fallback never move but count towards `overflow`. Spilled items keep their priority and batch,
    and never spill again from the fallback.
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
  local moves, spilled = {}, {}
  for proc, q in pairs(scan.queues) do
    local lim = limits[proc]
    local overflow = lim and tonumber(lim.overflow)
    if lim and (lim.diverted or overflow) then
      local keep, sum = {}, 0
      for _, e in ipairs(q) do
        local out = false
        if e.fallback then
          if lim.diverted then out = "diverted"
          elseif held[e.key] == "overflow" then out = sum + e.size > math.floor(overflow * 3 / 4) and "overflow"
          else out = sum >= overflow and "overflow" end
        end
        if out then moves[#moves + 1] = { e = e, from = proc }; spilled[e.key] = out
        else keep[#keep + 1] = e; sum = sum + e.size end
      end
      scan.queues[proc] = keep
    end
  end
  local touched = {}
  for _, mv in ipairs(moves) do
    local e, from = mv.e, mv.from
    e.from = from
    local b = scan.backlog[from]
    b.types, b.items = b.types - 1, b.items - e.size
    if b.types == 0 then scan.backlog[from] = nil end
    addTo(scan.spilled, from, e.size)
    addTo(scan.backlog, e.fallback, e.size)
    local q = scan.queues[e.fallback] or {}
    q[#q + 1] = e
    scan.queues[e.fallback], touched[e.fallback] = q, true
  end
  for proc in pairs(touched) do table.sort(scan.queues[proc], rank) end
  for proc, q in pairs(scan.queues) do if #q == 0 then scan.queues[proc] = nil end end
  return spilled
end

return P
