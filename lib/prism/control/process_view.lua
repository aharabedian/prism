--[[ prism.control.process_view: the right side while a process is selected (m.S.procSel): the process page.
  It takes the place of the tabbed list and the panel.

  ProcessView.new(ui, m) -> v
  v.draw()   top to bottom:
               PROCESS <name>; what's waiting, its throughput and what its machines' busy share means (or that
               it's held), and the supply it needs (prism.cfg `supplies`), with how long it has been low
               BACKLOG: a chart of the screen's own samples (m.S.history, one per status)
               MACHINES: each machine's last 2 hours as a band (m.S.machineCells), and its busy share
               QUEUE: the process's queue in rank order with what each item is doing (m.S.queue, router-queue)
               OUTPUTS: each bus, stocker, interface and feeder with what it holds
               sharing: the overflow mark as a field (m.S.overflowEdit while typing), what's shared, then
               HOLD (or RESUME), SHARE ON OVERFLOW, ALWAYS SHARE, CLOSE
  ProcessView.CELL = 160, ProcessView.CELLS = 45   seconds per band cell, cells per band (2 hours)
]]

local computer = require("computer")
local U        = require("prism.util")
local protocol = require("prism.protocol")

local ProcessView = { CELL = 160, CELLS = 45 }

local LEVEL_COLORS = { ok = "good", idle = "dim", warn = "warn", bad = "bad" }
local BLOCKS = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

function ProcessView.new(ui, m)
  local S, C, L, W, H = m.S, ui.C, ui.L, ui.W, ui.H
  local put, fill, fit, rfit, len, button = ui.put, ui.fill, ui.fit, ui.rfit, ui.len, ui.button
  local RX, RW = L.RX, L.RW
  local v = {}

  local function heading(y, title, note)
    put(RX, y, title, C.accent, C.bg)
    if note then put(RX + len(title) + 1, y, fit(note, RW - len(title) - 1), C.dim, C.bg) end
  end

  -- A filled chart h rows tall, one row string per GPU call.
  local function chart(x, y, w, h, vals, max)
    local cols = {}
    for i = 1, w do
      local v0 = vals[#vals - w + i]
      cols[i] = v0 and math.floor(math.max(0, v0) / max * h * 8 + 0.5) or -1
    end
    for row = 0, h - 1 do                            -- row 0 is the bottom
      local s = {}
      for i = 1, w do
        local e = cols[i] - row * 8
        s[i] = cols[i] < 0 and " " or e >= 8 and "█" or e > 0 and BLOCKS[e] or (row == 0 and "▁" or " ")
      end
      put(x, y + h - 1 - row, table.concat(s), C.info, C.bg)
    end
  end

  local function backlog(y, name)
    local hist = S.history[name] or {}
    local every = S.status and S.status.interval or 5
    local CW = math.min(60, RW - 8)
    heading(y, "BACKLOG", ("last %s, one point per scan"):format(U.fmtShort(#hist * every):gsub("^<", "")))
    local max = 1
    for _, n in ipairs(hist) do max = math.max(max, n) end
    chart(RX, y + 1, CW, 6, hist, max)
    put(RX + CW + 2, y + 1, U.fmtNum(max), C.dim, C.bg)
    put(RX + CW + 2, y + 6, "0", C.dim, C.bg)
    put(RX, y + 7, "-" .. U.fmtShort(math.min(#hist, CW) * every):gsub("^<", ""), C.dim, C.bg)
    put(RX + CW - 3, y + 7, "now", C.dim, C.bg)
    return y + 9
  end

  local function cellColor(c)
    if not c then return nil end
    if c.down > 0 then return C.bad end
    if c.w * 2 >= c.n then return C.good end
    if c.wait > 0 then return C.warn end
    return C.line
  end

  local function machines(y, name, rows)
    local list = {}
    for _, mc in ipairs(S.status and S.status.machines or {}) do
      if mc.process == name then list[#list + 1] = mc end
    end
    if #list == 0 then return y end
    table.sort(list, function(a, b) return U.natLess(a.name, b.name) end)
    heading(y, "MACHINES", "last 2 hours")
    local cur = math.floor(computer.uptime() / ProcessView.CELL)
    for i, mc in ipairs(list) do
      local yy = y + i
      if i == rows and #list > rows then put(RX, yy, ("+%d more"):format(#list - rows + 1), C.dim, C.bg); break end
      put(RX, yy, fit(mc.name, 12), C.text, C.bg)
      local cells = S.machineCells[mc.name] or {}
      local w, n = 0, 0
      local x0 = RX + 13
      local runStart, runColor = 1, nil
      local function flush(upTo)
        if runColor and upTo >= runStart then put(x0 + runStart - 1, yy, string.rep("█", upTo - runStart + 1), runColor, C.bg) end
      end
      for k = 1, ProcessView.CELLS do
        local c = cells[cur - ProcessView.CELLS + k]
        if c then w, n = w + c.w, n + c.n end
        local col = cellColor(c)
        if col ~= runColor then flush(k - 1); runStart, runColor = k, col end
      end
      flush(ProcessView.CELLS)
      if n > 0 then put(W - 9, yy, rfit("busy " .. U.pct(w / n), 9), C.dim, C.bg) end
    end
    return y + math.min(#list, rows) + 2
  end

  local function queue(y, name, last)
    local q = S.queue and S.queue.process == name and S.queue or nil
    heading(y, "QUEUE", "in rank order: priority, then quantity")
    if not q then put(RX, y + 1, "asking the router ...", C.dim, C.bg); return end
    if (q.total or 0) == 0 then put(RX, y + 1, "nothing waiting", C.dim, C.bg); return end
    put(RX, y + 1, "  # " .. fit("item", 24) .. rfit("qty", 6) .. "  now", C.dim, C.bg)
    local rows = last - (y + 2) + 1
    for i, r in ipairs(q.list or {}) do
      local yy = y + 1 + i
      if i == rows and (q.total or 0) > rows then
        put(RX, yy, ("+%d more"):format(q.total - rows + 1), C.dim, C.bg)
        return
      end
      if yy > last then return end
      put(RX, yy, rfit(r.rank, 3) .. " " .. fit(r.label or r.key, 24) .. rfit(U.fmtNum(r.size), 6) .. "  ", C.text, C.bg)
      put(RX + 36, yy, fit(tostring(r.now or ""), RW - 36), C[LEVEL_COLORS[r.level] or "dim"], C.bg)
    end
  end

  -- The process's buses, stockers, interfaces and feeders, one per row (at most `rows`).
  local function outputs(name, y, rows)
    local st, outs = S.status or {}, {}
    for _, b in ipairs(st.buses or {}) do if b.process == name then outs[#outs + 1] = b end end
    for _, f in ipairs(st.feeders or {}) do if f.process == name then outs[#outs + 1] = { feeder = f, name = f.name } end end
    table.sort(outs, function(a, b) return U.natLess(a.name, b.name) end)
    if #outs == 0 then
      put(RX, y, "no buses, stockers, interfaces or feeders for this process", C.bad, C.bg)
      return
    end
    for i, o in ipairs(outs) do
      if i == rows and #outs > rows then
        put(RX, y, ("+%d more"):format(#outs - rows + 1), C.dim, C.bg)
        return
      end
      put(RX, y, fit(o.name, 16), C.text, C.bg)
      local f = o.feeder
      if f then
        local level = f.level or protocol.feederLevel(f.state)
        put(RX + 16, y, "feeder    ", C.dim, C.bg)
        put(RX + 26, y, fit(f.state or "?", 20), C[LEVEL_COLORS[level]], C.bg)
        local what = f.label and (f.label .. ((f.batch or 1) > 1 and (" ×" .. f.batch) or "")) or ""
        put(RX + 47, y, fit(what, RW - 47), C.dim, C.bg)
      else
        put(RX + 16, y, fit(o.kind or "bus", 10), C.dim, C.bg)
        local n = o.filters and #o.filters
        local text = not n and "..." or n == 0 and "idle" or (n .. ": " .. table.concat(o.filters, ", "))
        put(RX + 26, y, fit(text, RW - 26), n == 0 and C.warn or C.dim, C.bg)
      end
      y = y + 1
    end
  end

  function v.draw()
    local name = S.procSel
    local p = S.status and S.status.processes and S.status.processes[name] or {}
    fill(RX - 1, 2, W - RX + 2, H - 2, C.bg)
    ui.fg(C.line)
    fill(RX - 2, 3, 1, H - 4, C.bg, "│")

    put(RX, 3, "PROCESS " .. name, C.accent, C.bg)
    put(RX, 5, fit(("%s items waiting (%d types)  ·  %d output(s)"):format(
      U.fmtNum(p.items or 0), p.types or 0, p.buses or 0), RW), C.text, C.bg)
    if p.outRate then
      local net = p.outRate - (p.inRate or 0)
      local tail = (p.items or 0) == 0 and "" or net > 0 and ("clears in " .. U.fmtShort(p.items / net * 60))
        or net < 0 and ("growing " .. U.fmtNum(-net) .. "/min") or "steady"
      put(RX, 6, fit(("Out %s/min  ·  in %s/min  (last 5 min)%s"):format(U.fmtNum(p.outRate), U.fmtNum(p.inRate or 0),
        tail ~= "" and ("  ·  " .. tail) or ""), RW), net < 0 and C.warn or C.text, C.bg)
    end
    local busy, kind = ui.busyText(p)
    if p.held then
      put(RX, 7, fit(("‖ Held%s for %s: its outputs are cleared and its stall and idle alerts are off."):format(
        p.heldBy and (" by " .. p.heldBy) or "", U.fmtShort(p.heldFor or 0)), RW), C.warn, C.bg)
    elseif busy then put(RX, 7, fit(busy, RW), (kind == "limit" or kind == "slow") and C.warn or C.dim, C.bg) end
    local sup = p.supply
    if sup then
      local text = ("Needs %s: %s of %s%s"):format(sup.name, U.fmtNum(sup.amount or 0), U.fmtNum(sup.min), sup.unit or "")
      if sup.low then text = "⚠ " .. text .. (sup.lowFor and (", low for " .. U.fmtShort(sup.lowFor)) or "")
        .. ": items with a fallback are shared" end
      put(RX, 8, fit(text, RW), sup.low and C.warn or C.dim, C.bg)
    end

    local y = backlog(10, name)
    y = machines(y, name, 4)

    local bottom = H - 10                            -- OUTPUTS, sharing and the buttons below this
    queue(y, name, bottom - 2)

    heading(bottom, "OUTPUTS")
    outputs(name, bottom + 1, 3)
    -- The overflow mark: tap, type, Enter (an empty field goes back to prism.cfg's).
    local editing = S.overflowEdit ~= nil
    put(RX, H - 6, "Share past", C.dim, C.bg)
    put(RX + 11, H - 6, " " .. fit(editing and (S.overflowEdit .. "_") or (p.overflow and tostring(p.overflow) or "-"), 7) .. " ",
      editing and C.accent or C.text, C.field)
    ui.hit(RX + 11, H - 6, RX + 19, H - 6, m.editOverflow)
    put(RX + 21, H - 6, fit(editing and "type a number, Enter saves (empty: prism.cfg's)"
      or ("items waiting  ·  " .. (p.overflowFrom == "screen" and "set here, tap to change" or "tap to type")), RW - 21), C.dim, C.bg)
    if p.alwaysShare then
      put(RX, H - 5, fit("Fallbacks: always shared", RW), C.warn, C.bg)
    elseif p.overflow then
      put(RX, H - 5, fit(("Fallbacks: shared on overflow (past %s waiting)"):format(U.fmtNum(p.overflow)), RW), C.text, C.bg)
    else
      put(RX, H - 5, fit("Fallbacks: never shared (no overflow mark)", RW), C.dim, C.bg)
    end
    if (p.spilled or 0) > 0 then
      put(RX, H - 4, fit(("↷ %s items shared with their fallbacks"):format(U.fmtNum(p.spilled)), RW), C.warn, C.bg)
    else
      put(RX, H - 4, "nothing going to fallbacks", C.dim, C.bg)
    end
    local x = RX
    if p.held then x = button(x, H - 2, "RESUME", { color = C.good, fg = C.bg, fn = function() m.setHold(false) end })
    else x = button(x, H - 2, "HOLD", { color = C.warn, fg = C.bg, fn = function() m.setHold(true) end }) end
    x = button(x, H - 2, "SHARE ON OVERFLOW", { on = not p.alwaysShare, fn = function() m.setAlwaysShare(false) end })
    x = button(x, H - 2, "ALWAYS SHARE", { on = p.alwaysShare == true, fn = function() m.setAlwaysShare(true) end })
    button(x, H - 2, "CLOSE", { fn = m.cancelProcess })
  end

  return v
end

return ProcessView
