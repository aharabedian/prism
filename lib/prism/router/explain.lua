--[[ prism.router.explain: one line saying what an item is doing now, for the screen's ROUTE ITEM panel.

  item(r, key) -> { text, level }
    r      the router (prism.router.core): store, last (the latest scan's labels, present, queues), outputs, spilled
    level  "ok" (on an output now), "warn" (waiting for something the player can fix or wait for), "dim"
  Reasons, first that applies: not in the network; unassigned; ignored; its process held; on outputs (which, and the slot);
  no output for its process; less than one batch; a batch item with only outputs that can't take batches;
  ranked below what its outputs hold; else it waits for the next scan. A shared item says so too.
  row(r, proc, rank, e) -> text, level
    a short version for one entry of a process's queue (the process page): "on Washer bus (slot 3)",
    "↷ shared with wash", "shared from chembath", "below batch: 25 of 36", "rank 12; outputs hold 9" ...
  queue(r, proc, offset, n) -> total, rows   rows = { rank, key, label, size, batch, prio, now, level }[]
  Uses only the output interface (holds, size, takesBatches), so a new output kind needs nothing here.
]]

local U = require("prism.util")

local E = {}

local function rankIn(queue, key)
  for i, e in ipairs(queue or {}) do if e.key == key then return i, e end end
end

function E.item(r, key)
  local store, last = r.store, r.last
  local size = last.present[key]
  if not size or size == 0 then return { text = "Not in the network now.", level = "dim" } end
  local label = store:labelOf(key, last.labels[key]) or key
  local proc, _, _, _, _, fallback = store:classify(label, key)
  if proc == nil then return { text = "Unassigned: no rule or override matches its name.", level = "warn" } end
  if proc == "ignore" then return { text = "Ignored: it stays in the network.", level = "dim" } end

  if store.held[proc] then
    local h = store.held[proc]
    return { text = ("Held: %s is on hold%s, so its outputs are cleared."):format(proc,
      type(h) == "table" and h.by and (" (" .. h.by .. ")") or ""), level = "warn" }
  end
  local rank, e = rankIn(last.queues[proc], key)
  local shared = r.spilled[key] and fallback
  local held, serves, batches, most = {}, 0, false, 0
  for _, o in ipairs(r.outputs) do
    local place = o:holds(key)
    if place then held[#held + 1] = o.name .. " (" .. place .. ")" end
    if o.process == proc or (shared and o.process == fallback) then
      serves = serves + 1
      if o.takesBatches then batches = true end
      if o.process == proc then most = math.max(most, o.size or 1) end
    end
  end
  local sharedText = shared and ("; shared with " .. fallback) or ""
  if #held > 0 then
    return { text = "On " .. table.concat(held, ", ") .. sharedText .. ".", level = "ok" }
  end
  if serves == 0 then
    return { text = ("Nothing serves %s: add a bus, stocker, interface or feeder for it."):format(proc), level = "warn" }
  end
  local batch = e and e.batch or 1
  if size < batch then
    return { text = ("Waits for a full batch: %s of %d, needs %s more."):format(U.fmtNum(size), batch,
      U.fmtNum(batch - size)), level = "warn" }
  end
  if batch > 1 and not batches then
    return { text = ("Needs batches of %d, and %s has no feeder or stocker to take them."):format(batch, proc),
      level = "warn" }
  end
  if rank and rank > most then
    return { text = ("Rank %d of %d in %s; its outputs hold the top %d%s."):format(rank, #last.queues[proc], proc,
      most, sharedText), level = "dim" }
  end
  return { text = "Waiting for the next scan to place it" .. sharedText .. ".", level = "dim" }
end

-- Outputs of `proc` holding the item: "Washer bus (slot 3)", "+1" more.
local function heldBy(r, proc, key)
  local held = {}
  for _, o in ipairs(r.outputs) do
    if o.process == proc then
      local place = o:holds(key)
      if place then held[#held + 1] = o.name .. " (" .. place .. ")" end
    end
  end
  if #held == 0 then return nil end
  return held[1] .. (#held > 1 and (", +" .. (#held - 1)) or "")
end

function E.row(r, proc, rank, e)
  if r.store.held[proc] then return "held", "warn" end
  local on = heldBy(r, proc, e.key)
  if e.from then return "shared from " .. e.from .. (on and ("; on " .. on) or ""), on and "ok" or "dim" end
  local shared = r.spilled[e.key] and e.fallback
  if on then return "on " .. on .. (shared and ("; ↷ " .. e.fallback) or ""), "ok" end
  if shared then return "↷ shared with " .. e.fallback, "warn" end
  local serves, batches, most = 0, false, 0
  for _, o in ipairs(r.outputs) do
    if o.process == proc then
      serves, most = serves + 1, math.max(most, o.size or 1)
      if o.takesBatches then batches = true end
    end
  end
  if serves == 0 then return "nothing serves " .. proc, "warn" end
  if e.size < e.batch then return ("below batch: %s of %d"):format(U.fmtNum(e.size), e.batch), "warn" end
  if e.batch > 1 and not batches then return "needs a feeder or stocker", "warn" end
  if rank > most then return ("rank %d; outputs hold %d"):format(rank, most), "dim" end
  return "next scan places it", "dim"
end

function E.queue(r, proc, offset, n)
  local q = r.last.queues[proc] or {}
  local rows = {}
  for i = offset + 1, math.min(#q, offset + n) do
    local e = q[i]
    local now, level = E.row(r, proc, i, e)
    rows[#rows + 1] = { rank = i, key = e.key, label = e.label, size = e.size, batch = e.batch, prio = e.prio,
      now = now, level = level }
  end
  return #q, rows
end

return E
