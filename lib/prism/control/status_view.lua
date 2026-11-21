--[[ prism.control.status_view: the header and the left column, one card per process.

  StatusView.new(ui, m) -> v
  v.drawHeader()          the top bar: LIVE / NO SIGNAL, alerts, router stats, version mismatch
  v.draw()                the left column: a card per process (backlog, history, its machines, a line
                          about its outputs and how many items wait below their batch, its throughput
                          and time to clear on the right); tapping a card
                          selects the process (m.selectProcess)
  v.redrawMachines() -> false if the machines changed (names/processes), so everything must be redrawn
  When the cards don't fit, the biggest ones first list fewer machines ("+N more"), then shrink to their
  header row (machines as dots, the outputs line only when something's wrong).
  Machines, buses and feeders without a process go in a last "(no process)" card.
]]

local computer = require("computer")
local VERSION  = require("prism.version")
local U        = require("prism.util")
local protocol = require("prism.protocol")

local StatusView = {}

local LEVEL_COLORS = { ok = "good", idle = "dim", warn = "warn", bad = "bad" }

function StatusView.new(ui, m)
  local S, C, L, W, H = m.S, ui.C, ui.L, ui.W, ui.H
  local put, fill, fit, rfit, len = ui.put, ui.fill, ui.fit, ui.rfit, ui.len
  local LW = L.LW
  local v = {}

  function v.drawHeader()
    fill(1, 1, W, 1, C.panel)
    put(1, 1, " PRISM ", C.bg, C.accent)
    local st = S.status
    local x = 10
    if not st then
      put(x, 1, "● waiting for router ...", C.warn, C.panel)
      return
    end
    local age = computer.uptime() - S.statusAt
    local text
    if age > (st.interval or 5) * m.settings.staleAfter then
      text = "● NO SIGNAL  last update " .. U.fmtTime(age) .. " ago"
      put(x, 1, text, C.bad, C.panel)
    else
      text = ("● LIVE  %ds ago"):format(math.floor(age))
      put(x, 1, text, C.good, C.panel)
    end
    local n = st.alerts and #st.alerts or 0
    if n > 0 then
      put(x + len(text) + 3, 1, (" ⚠ %d ALERT%s "):format(n, n == 1 and "" or "S"), C.bg, C.bad)
    end
    local right = ("cycle %d  ·  %dms  ·  %s writes  ·  up %s "):format(
      st.cycles or 0, st.cycleMs or 0, U.fmtNum(st.writes), U.fmtTime(st.uptime))
    put(W - len(right) + 1, 1, right, C.dim, C.panel)
    if st.version ~= VERSION then   -- router and screen running different releases
      local ver = (" router %s ≠ screen %s "):format(tostring(st.version or "?"), VERSION)
      put(W - len(right) - len(ver), 1, ver, C.bg, C.warn)
    end
  end

  ---------------------------------------------------------------- process cards
  -- One card per process: a header row (backlog, history, machines working), its machines in cells,
  -- then one line about its outputs (buses, stockers, interfaces, feeders).

  local CELL = 29                                   -- machine cell width
  local RIGHT = 20                                  -- the header's machines area ("4/6 working" or dots)
  local COLS = math.max(1, math.floor((LW - 2) / CELL))
  local TOP = 5                                     -- first card row
  local machCells, machHeads, machSig = {}, {}, nil -- where redrawMachines draws

  -- dot, dot color, state text, state color for one machine
  local function machineLook(mc)
    local st = mc.state or "?"
    if st == "working" then return "●", C.good, nil, C.good end
    if st == "idle" then
      if mc.idle then return "○", C.warn, "idle " .. (U.fmtTime(mc.idle):gsub("^0m", "")), C.warn end
      return "○", C.dim, "idle", C.dim
    end
    if st == "disabled" then return "●", C.warn, st, C.warn end
    return "●", C.bad, st, C.bad
  end

  local function workingText(g)
    local n, w = #g.machines, 0
    for _, mc in ipairs(g.machines) do if mc.state == "working" then w = w + 1 end end
    return n, w
  end

  -- Processes with what belongs to them, sorted by name ("-": things without a process, last).
  local function groups(st)
    local by, order = {}, {}
    local function g(name)
      name = name or "-"
      if not by[name] then
        by[name] = { name = name, p = st.processes and st.processes[name] or {}, machines = {}, outs = {} }
        order[#order + 1] = name
      end
      return by[name]
    end
    for name in pairs(st.processes or {}) do g(name) end
    for _, mc in ipairs(st.machines or {}) do table.insert(g(mc.process).machines, mc) end
    for _, b in ipairs(st.buses or {}) do table.insert(g(b.process).outs, b) end
    for _, f in ipairs(st.feeders or {}) do table.insert(g(f.process).outs, { feeder = f }) end
    table.sort(order, function(a, b)
      if (a == "-") ~= (b == "-") then return b == "-" end
      return a < b
    end)
    for _, name in ipairs(order) do
      table.sort(by[name].machines, function(a, b) return U.natLess(a.name, b.name) end)
    end
    return order, by
  end

  -- The outputs line: { text, color } parts, and whether it reports a problem.
  local function outputParts(g)
    local parts, problem = {}, false
    local kinds, counts, filters, known, empty, feeders = {}, {}, {}, {}, {}, {}
    for _, o in ipairs(g.outs) do
      if o.feeder then feeders[#feeders + 1] = o.feeder
      else
        local k = o.kind or "bus"
        if not counts[k] then kinds[#kinds + 1] = k end
        counts[k] = (counts[k] or 0) + 1
        if o.filters then
          known[k] = true
          filters[k] = (filters[k] or 0) + #o.filters
          if #o.filters == 0 then empty[#empty + 1] = o.name end
        end
      end
    end
    local plural = { bus = "buses", stocker = "stockers", interface = "interfaces" }
    for _, k in ipairs(kinds) do
      parts[#parts + 1] = { counts[k] .. " " .. (counts[k] == 1 and k or plural[k] or (k .. "s")), C.dim }
      if known[k] and filters[k] > 0 then
        parts[#parts + 1] = { filters[k] .. (k == "bus" and (filters[k] == 1 and " filter" or " filters") or " stocked"), C.good }
      end
    end
    if (g.p.below or 0) > 0 then parts[#parts + 1] = { U.fmtNum(g.p.below) .. " below batch", C.dim } end
    if #empty > 0 then
      parts[#parts + 1] = { table.concat(empty, ", ") .. (#empty == 1 and " is idle" or " are idle"), C.warn }
    end
    if #feeders > 0 then
      table.sort(feeders, function(a, b) return U.natLess(a.name, b.name) end)
      local busy = 0
      for _, f in ipairs(feeders) do if (f.level or protocol.feederLevel(f.state)) == "ok" then busy = busy + 1 end end
      parts[#parts + 1] = { #feeders .. (#feeders == 1 and " feeder" or " feeders"), C.dim }
      parts[#parts + 1] = { busy .. " feeding", busy > 0 and C.good or C.dim }
      for _, f in ipairs(feeders) do
        local level = f.level or protocol.feederLevel(f.state)
        if level == "warn" or level == "bad" then
          parts[#parts + 1] = { f.name .. " " .. tostring(f.state), C[LEVEL_COLORS[level]] }
          problem = true
        end
      end
    end
    if #g.outs == 0 then
      local items = g.p.items or 0
      parts[#parts + 1] = { items > 0 and "no outputs: nothing takes these items" or "no outputs", items > 0 and C.bad or C.dim }
      problem = items > 0
    end
    return parts, problem or #empty > 0
  end

  local function drawCell(x, y, mc)
    local dot, dc, state, sc = machineLook(mc)
    put(x, y, dot, dc, C.bg)
    put(x + 2, y, fit(mc.name, 14), C.text, C.bg)
    put(x + 16, y, mc.eu and mc.eu < 0.2 and "⚡" or " ", C.bad, C.bg)
    if state then
      put(x + 17, y, fit(state, 10), sc, C.bg)
    else
      local BW = 5
      local f = mc.progress and math.floor(mc.progress * BW + 0.5) or 0
      if f > 0 then put(x + 17, y, string.rep("█", f), C.info, C.bg) end
      if f < BW then put(x + 17 + f, y, string.rep("·", BW - f), C.line, C.bg) end
      put(x + 22, y, rfit(U.pct(mc.progress), 5), C.dim, C.bg)
    end
  end

  -- "4/6 working", or the machines as dots when compact. Right-aligned at the end of the header row.
  local function drawWorking(y, g, compact, rowBg)
    local n, w = workingText(g)
    if n == 0 then return end
    local color = w == n and C.good or C.warn
    if compact then
      local count = (" %d/%d"):format(w, n)
      local dots = math.min(n, RIGHT - len(count) - 2)
      local x = LW - dots - len(count) - (n > dots and 1 or 0)
      for i = 1, dots do
        local dot, dc = machineLook(g.machines[i])
        put(x + i - 1, y, dot, dc, rowBg)
      end
      if n > dots then put(x + dots, y, "…", C.dim, rowBg) end
      put(LW - len(count), y, count, color, rowBg)
    else
      local text = ("%d/%d working"):format(w, n)
      put(LW - RIGHT, y, rfit(text, RIGHT), color, rowBg)
    end
  end

  local function drawHeader(y, g, maxItems, compact)
    local name, p = g.name, g.p
    local items = p.items or 0
    local none = #g.outs == 0 and items > 0
    local stalled = p.stalled ~= nil
    local spilling = p.alwaysShare or (p.spilled or 0) > 0
    local rowBg = S.procSel == name and C.sel or C.panel
    fill(1, y, LW, 1, rowBg)
    local label = stalled and ("⚠ " .. name) or (spilling and ("↷ " .. name)) or name
    local color = (none or stalled) and C.bad or (p.alwaysShare and C.warn) or C.accent
    if name == "-" then
      put(2, y, "(no process)", C.dim, rowBg)
    else
      put(2, y, fit(label, 13), color, rowBg)
      put(15, y, rfit(U.fmtNum(items), 7) .. " items ", C.text, rowBg)
      put(29, y, rfit(p.types or 0, 3) .. ((p.types or 0) == 1 and " type" or " types"), C.dim, rowBg)
      local BW = 18
      local x = 41
      local f = math.floor(items / maxItems * BW + 0.5)
      if items > 0 and f == 0 then f = 1 end
      if f > 0 then put(x, y, string.rep("█", f), (none or stalled) and C.bad or C.accent, rowBg) end
      if f < BW then put(x + f, y, string.rep("·", BW - f), C.line, rowBg) end
      x = x + BW + 2
      local spW = LW - RIGHT - 3 - x
      if spW > 0 then
        local hist = S.history[name] or {}
        put(x, y, ui.sparkline(hist, spW), C.info, rowBg)
        local now, before = hist[#hist], hist[#hist - 5] or hist[1]
        local ax = x + spW + 1
        if stalled then put(ax, y, "⚠", C.bad, rowBg)
        elseif now and before and now > before then put(ax, y, "▲", C.warn, rowBg)
        elseif now and before and now < before then put(ax, y, "▼", C.good, rowBg)
        else put(ax, y, "–", C.dim, rowBg) end
      end
    end
    drawWorking(y, g, compact, rowBg)
    machHeads[name] = { y = y, compact = compact, bg = rowBg }
  end

  -- The outputs line, with the process's throughput right-aligned when the router has measured it.
  local function drawOutputs(y, g)
    local parts = outputParts(g)
    local limit = LW
    local rate, kind = ui.rateText(g.p)
    if rate then
      limit = LW - len(rate) - 4
      put(LW - len(rate), y, rate, kind == "growing" and C.warn or C.dim, C.bg)
    end
    local x = 5
    put(x, y, "↳ ", C.line, C.bg); x = x + 2
    for i, part in ipairs(parts) do
      local text = (i > 1 and "  ·  " or "") .. part[1]
      if x + len(text) > limit then put(x, y, "  …", C.dim, C.bg); break end
      if i > 1 then put(x, y, "  ·  ", C.line, C.bg) end
      put(x + (i > 1 and 5 or 0), y, part[1], part[2], C.bg)
      x = x + len(text)
    end
  end

  local function cardRows(g, compact)
    if compact then
      local _, problem = outputParts(g)
      return 1 + (problem and 1 or 0)
    end
    return 1 + math.ceil(#g.machines / COLS) + 1
  end

  -- The machines' names and processes, to tell whether a router-machines update fits the drawn cards.
  local function signature(list)
    local t = {}
    for i, mc in ipairs(list or {}) do t[i] = tostring(mc.name) .. "\0" .. tostring(mc.process) end
    return table.concat(t, "\1")
  end

  local function drawCards()
    local st = S.status
    machCells, machHeads, machSig = {}, {}, nil
    put(2, 3, "PROCESSES", C.accent, C.bg)
    if not st then put(2, TOP, "waiting for the router ...", C.dim, C.bg); return end
    local order, by = groups(st)
    if #order == 0 then put(2, TOP, "no processes yet", C.dim, C.bg); return end
    put(13, 3, "tap a process for its buses and feeders", C.dim, C.bg)

    local index = {}                                  -- machine -> its place in st.machines
    for i, mc in ipairs(st.machines or {}) do index[mc] = i end
    local maxItems = 1
    for _, name in ipairs(order) do maxItems = math.max(maxItems, by[name].p.items or 0) end

    -- Shrink the biggest cards to their header until everything fits, then drop the gaps.
    local avail = H - TOP                             -- rows TOP .. H-1
    local compact, limit, tried, rows, total = {}, {}, {}, {}, 0
    for _, name in ipairs(order) do rows[name] = cardRows(by[name], false); total = total + rows[name] end
    while total + #order - 1 > avail do
      local big
      for _, name in ipairs(order) do
        if not tried[name] and (not big or rows[name] > rows[big]) then big = name end
      end
      if not big or total <= avail then break end
      tried[big] = true
      local over = total + (#order - 1) - avail
      local mrows = math.ceil(#by[big].machines / COLS)
      if mrows - over >= 2 then                     -- fewer machine rows, the last cell says how many more
        limit[big], total, rows[big] = mrows - over, total - over, rows[big] - over
      else
        local small = cardRows(by[big], true)
        if small < rows[big] then compact[big], total, rows[big] = true, total - rows[big] + small, small end
      end
    end
    local gap = total + #order - 1 <= avail and 1 or 0

    local y = TOP
    for i, name in ipairs(order) do
      local g = by[name]
      local need = rows[name]
      if y + need - 1 > H - 1 then
        put(2, math.min(y, H - 1), fit(("+%d more processes"):format(#order - i + 1), LW - 2), C.dim, C.bg)
        break
      end
      local y0 = y
      drawHeader(y, g, maxItems, compact[name]); y = y + 1
      if not compact[name] then
        local n = #g.machines
        local shown = limit[name] and (limit[name] * COLS - 1) or n
        for j = 1, math.min(n, shown) do
          local mc = g.machines[j]
          local cx = 3 + ((j - 1) % COLS) * CELL
          local cy = y + math.floor((j - 1) / COLS)
          drawCell(cx, cy, mc)
          machCells[#machCells + 1] = { x = cx, y = cy, i = index[mc] }
        end
        if n > shown then
          put(3 + (shown % COLS) * CELL, y + math.floor(shown / COLS), ("+%d more"):format(n - shown), C.dim, C.bg)
        end
        y = y + (limit[name] or math.ceil(n / COLS))
        drawOutputs(y, g); y = y + 1
      elseif need > 1 then
        drawOutputs(y, g); y = y + 1
      end
      if g.name ~= "-" then ui.hit(1, y0, LW, y - 1, function() m.selectProcess(name) end) end
      y = y + gap
    end
    machSig = signature(st.machines)
  end

  -- Redraw machine cells and the working counts in place; false when the cards must be redrawn.
  function v.redrawMachines()
    local st = S.status
    if not st or machSig == nil or signature(st.machines) ~= machSig then return false end
    for _, c in ipairs(machCells) do drawCell(c.x, c.y, st.machines[c.i]) end
    local _, by = groups(st)
    for name, h in pairs(machHeads) do
      if by[name] then drawWorking(h.y, by[name], h.compact, h.bg) end
    end
    return true
  end

  function v.draw()
    fill(1, 2, LW + 1, H - 2, C.bg)
    drawCards()
  end

  return v
end

return StatusView
