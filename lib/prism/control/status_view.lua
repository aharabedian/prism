--[[ prism.control.status_view: the header and the left column (processes, buses, feeders, machines).

  StatusView.new(ui, m) -> v
  v.drawHeader()          the top bar: LIVE / NO SIGNAL, alerts, router stats, version mismatch
  v.draw()                the whole left column
  v.redrawMachines() -> false if the machine rows aren't on screen (then redraw everything)
  The column switches to one row per bus and feeder when everything wouldn't otherwise fit.
]]

local computer = require("computer")
local VERSION  = require("prism.version")
local U        = require("prism.util")
local protocol = require("prism.protocol")

local StatusView = {}

local LEVEL_COLORS = { ok = "good", idle = "dim", warn = "warn", bad = "bad" }
local MACHINE_COLORS = { working = "good", idle = "dim", disabled = "warn" }

function StatusView.new(ui, m)
  local S, C, L, W, H = m.S, ui.C, ui.L, ui.W, ui.H
  local put, fill, fit, rfit, len = ui.put, ui.fill, ui.fit, ui.rfit, ui.len
  local LW = L.LW
  local machY, machCount = nil, 0
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

  local function drawProcesses(y)
    local NW, BW = 14, 22
    local spW = LW - 2 - (NW + 6 + 7 + 8 + 2 + BW + 2 + 2)
    put(2, y, "PROCESSES", C.accent, C.bg); y = y + 1
    put(2, y, fit("name", NW) .. rfit("outs", 6) .. rfit("types", 7) .. rfit("items", 8) .. "  "
              .. fit("backlog", BW) .. "  " .. fit("history", spW), C.dim, C.bg)
    y = y + 1

    local st = S.status
    if not st then return y + 1 end
    local names, maxItems = {}, 1
    for name, p in pairs(st.processes or {}) do
      names[#names + 1] = name
      if (p.items or 0) > maxItems then maxItems = p.items end
    end
    table.sort(names)

    for _, name in ipairs(names) do
      local p = st.processes[name]
      local items = p.items or 0
      local none = (p.buses or 0) == 0 and items > 0
      local stalled = p.stalled ~= nil
      local x = 2
      put(x, y, fit(stalled and ("⚠ " .. name) or name, NW), (none or stalled) and C.bad or C.text, C.bg); x = x + NW
      put(x, y, rfit(none and "NONE" or p.buses, 6), none and C.bad or C.dim); x = x + 6
      put(x, y, rfit(p.types or 0, 7), C.text);                              x = x + 7
      put(x, y, rfit(U.fmtNum(items), 8), C.text);                           x = x + 8 + 2
      local f = math.floor(items / maxItems * BW + 0.5)
      if items > 0 and f == 0 then f = 1 end
      if f > 0 then put(x, y, string.rep("█", f), (none or stalled) and C.bad or C.accent) end
      if f < BW then put(x + f, y, string.rep("·", BW - f), C.line) end
      x = x + BW + 2
      local hist = S.history[name] or {}
      put(x, y, ui.sparkline(hist, spW), C.info); x = x + spW + 1
      local now, before = hist[#hist], hist[#hist - 5] or hist[1]
      if stalled then put(x, y, "⚠", C.bad)
      elseif now and before and now > before then put(x, y, "▲", C.warn)
      elseif now and before and now < before then put(x, y, "▼", C.good)
      else put(x, y, "–", C.dim) end
      y = y + 1
    end
    if #names == 0 then put(2, y, "no processes yet", C.dim); y = y + 1 end
    return y
  end

  local function drawBuses(y, compact)
    local list = S.status and S.status.buses or {}
    if #list == 0 then return y end
    y = y + 1
    put(2, y, "BUSES", C.accent, C.bg); y = y + 1
    for i, b in ipairs(list) do
      if y > H - 2 or (not compact and y + 1 > H - 2) then
        put(2, y, ("+%d more"):format(#list - i + 1), C.dim, C.bg); return y + 1
      end
      local nf = b.filters and #b.filters or 0
      put(2, y, fit(b.name, 18), C.text, C.bg)
      put(20, y, fit("[" .. tostring(b.process) .. "]", 14), C.info)
      local summary
      if nf == 0 then summary = "idle"
      elseif b.kind == "stocker" or b.kind == "interface" then summary = nf .. " stocked"
      else summary = nf .. (nf == 1 and " filter" or " filters") end
      if compact then
        put(34, y, fit(summary, 11), nf == 0 and C.dim or C.good)
        put(45, y, fit(b.filters and table.concat(b.filters, ", ") or "", LW - 45), C.dim)
        y = y + 1
      else
        put(34, y, fit(summary, LW - 34), nf == 0 and C.dim or C.good)
        y = y + 1
        put(4, y, fit(b.filters and table.concat(b.filters, ", ") or "...", LW - 4), C.dim)
        y = y + 1
      end
    end
    return y
  end

  local function drawFeeders(y, compact)
    local list = S.status and S.status.feeders or {}
    if #list == 0 then return y end
    y = y + 1
    if y > H - 3 then return y end
    put(2, y, "FEEDERS", C.accent, C.bg); y = y + 1
    for i, f in ipairs(list) do
      if y > H - 2 or (not compact and y + 1 > H - 2) then
        put(2, y, ("+%d more"):format(#list - i + 1), C.dim, C.bg); return y + 1
      end
      local color = C[LEVEL_COLORS[f.level or protocol.feederLevel(f.state)]]   -- older routers send no level
      local what = f.label and (f.label .. ((f.batch or 1) > 1 and ("  ×" .. f.batch) or "")) or "-"
      put(2, y, fit(f.name, 18), C.text, C.bg)
      put(20, y, fit("[" .. tostring(f.process) .. "]", 14), C.info)
      if compact then
        put(34, y, fit(f.state or "?", 20), color)
        put(55, y, fit(what, LW - 55), C.dim)
        y = y + 1
      else
        put(34, y, fit(f.state or "?", LW - 34), color)
        y = y + 1
        put(4, y, fit(what, LW - 20), C.dim)
        put(LW - 15, y, rfit("fed " .. U.fmtNum(f.fed), 15), C.dim)
        y = y + 1
      end
    end
    return y
  end

  local function drawMachineRow(y, mc)
    put(2, y, fit(mc.name, 16), C.text, C.bg)
    put(18, y, fit("[" .. tostring(mc.process or "-") .. "]", 13), C.info)
    local state, color = mc.state or "?", C[MACHINE_COLORS[mc.state] or "bad"]
    if mc.state == "idle" and mc.idle then state, color = "idle " .. (U.fmtTime(mc.idle):gsub("^0m", "")), C.warn end
    put(31, y, fit(state, 13), color)
    local BW = 16
    local f = mc.progress and math.floor(mc.progress * BW + 0.5) or 0
    if f > 0 then put(44, y, string.rep("█", f), C.info) end
    if f < BW then put(44 + f, y, string.rep("·", BW - f), C.line) end
    put(60, y, rfit(mc.state == "working" and U.pct(mc.progress) or "", 5), C.dim)
    if mc.eu then put(66, y, "⚡" .. rfit(U.pct(mc.eu), 4), mc.eu < 0.2 and C.bad or C.dim)
    else put(66, y, "     ", C.dim) end
  end

  local function drawMachines(y)
    local list = S.status and S.status.machines or {}
    machY, machCount = nil, 0
    if #list == 0 then return y end
    y = y + 1
    if y > H - 3 then return y end
    put(2, y, "MACHINES", C.accent, C.bg); y = y + 1
    machY = y
    for i, mc in ipairs(list) do
      if y > H - 2 then put(2, y, ("+%d more"):format(#list - i + 1), C.dim, C.bg); break end
      drawMachineRow(y, mc)
      machCount = i
      y = y + 1
    end
    return y
  end

  function v.redrawMachines()
    if not machY then return false end
    local list = S.status and S.status.machines or {}
    for i = 1, machCount do
      if list[i] then drawMachineRow(machY + i - 1, list[i]) end
    end
    return true
  end

  -- Rows the left column needs, to decide whether it must be compact.
  local function rowsNeeded(st, compact)
    local per = compact and 1 or 2
    local n = 2 + math.max(1, U.count(st.processes))
    if #(st.buses or {}) > 0 then n = n + 2 + #st.buses * per end
    if #(st.feeders or {}) > 0 then n = n + 2 + #st.feeders * per end
    if #(st.machines or {}) > 0 then n = n + 2 + #st.machines end
    return n
  end

  function v.draw()
    fill(1, 2, LW + 1, H - 2, C.bg)
    local st = S.status
    local compact = st and rowsNeeded(st, false) > H - 3
    local y = drawProcesses(3)
    y = drawBuses(y, compact)
    y = drawFeeders(y, compact)
    drawMachines(y)
  end

  return v
end

return StatusView
