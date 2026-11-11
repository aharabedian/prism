--[[ prism.router.planner: turn one network scan into ranked work per process. Pure: no I/O.

  plan(items, classify) -> scan
    items     getItemsInNetwork() stacks
    classify  function(label, key) -> process, priority, batch (see prism.rules)

  scan = {
    order      = key[]                          keys in network order (NBT variants merged)
    labels     = { [key] = label }
    present    = { [key] = quantity }
    queues     = { [process] = entry[] }        ranked: priority, then quantity, then key
    backlog    = { [process] = { types, items } }
    unassigned = { key, label, size }[]         largest first
  }
  entry = { key, stack, label, size, prio, batch }
  process "ignore" is neither queued nor unassigned.
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

  local scan = { order = order, labels = {}, present = {}, queues = {}, backlog = {}, unassigned = {} }
  for _, key in ipairs(order) do
    local e = merged[key]
    scan.labels[key], scan.present[key] = e.label, e.size
    local proc, prio, batch = classify(e.label, key)
    if proc == nil then
      scan.unassigned[#scan.unassigned + 1] = { key = key, label = e.label, size = e.size }
    elseif proc ~= "ignore" then
      e.prio, e.batch = prio, math.max(1, math.floor(batch or 1))
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

return P
