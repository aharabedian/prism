--[[ prism.control.glance_view: glance mode, the control screen at a third of its resolution so it reads from
  across the room (53 x 16 on a 160 x 50 screen). prism-control switches to it after glanceAfter minutes without
  a touch, and back on any touch.

  GlanceView.new(ui, m) -> v
  v.size() -> w, h   the glance resolution: a third of ui.W x ui.H
  v.draw()           at that resolution: the header (LIVE / NO SIGNAL, alerts), one row per process (backlog,
                     trend, a dot per machine, and held / stalled / time to clear), the two newest alerts, and
                     "tap anywhere for the full screen"
]]

local computer = require("computer")
local U        = require("prism.util")

local GlanceView = {}

function GlanceView.new(ui, m)
  local S, C = m.S, ui.C
  local put, fill, fit, rfit, len = ui.put, ui.fill, ui.fit, ui.rfit, ui.len
  local v = {}

  function v.size() return math.floor(ui.W / 3), math.floor(ui.H / 3) end

  local function dot(mc)
    if mc.state == "working" then return "●", C.good end
    if mc.state == "idle" then return "○", mc.idle and C.warn or C.dim end
    return "●", mc.state == "disabled" and C.warn or C.bad
  end

  function v.draw()
    local GW, GH = v.size()
    fill(1, 1, GW, GH, C.bg)
    fill(1, 1, GW, 1, C.panel)
    put(1, 1, " PRISM ", C.bg, C.accent)
    local st = S.status
    if not st then put(9, 1, "● waiting for router", C.warn, C.panel); return end
    local age = computer.uptime() - (S.statusAt or 0)
    if age > (st.interval or 5) * m.settings.staleAfter then put(9, 1, "● NO SIGNAL", C.bad, C.panel)
    else put(9, 1, "● LIVE", C.good, C.panel) end
    local alerts = st.alerts or {}
    if #alerts > 0 then
      local a = (" ⚠ %d ALERT%s "):format(#alerts, #alerts == 1 and "" or "S")
      put(GW - len(a) + 1, 1, a, C.bg, C.bad)
    end

    local names = {}
    for name in pairs(st.processes or {}) do names[#names + 1] = name end
    table.sort(names)
    local machinesOf = {}
    for _, mc in ipairs(st.machines or {}) do
      if mc.process then
        machinesOf[mc.process] = machinesOf[mc.process] or {}
        table.insert(machinesOf[mc.process], mc)
      end
    end
    local rows = GH - 6
    for i, name in ipairs(names) do
      local y = 2 + i
      if i == rows and #names > rows then put(2, y, ("+%d more processes"):format(#names - rows + 1), C.dim, C.bg); break end
      local p = st.processes[name]
      local label = p.held and ("‖ " .. name) or p.stalled and ("⚠ " .. name) or ((p.spilled or 0) > 0 and ("↷ " .. name))
        or name
      put(2, y, fit(label, 12), p.held and C.warn or p.stalled and C.bad or C.accent, C.bg)
      put(14, y, rfit(U.fmtNum(p.items or 0), 6), C.text, C.bg)
      local hist = S.history[name] or {}
      local now, before = hist[#hist], hist[#hist - 5] or hist[1]
      local arrow, ac = "–", C.dim
      if p.stalled then arrow, ac = "⚠", C.bad
      elseif now and before and now > before then arrow, ac = "▲", C.warn
      elseif now and before and now < before then arrow, ac = "▼", C.good end
      put(21, y, arrow, ac, C.bg)
      local ms = machinesOf[name] or {}
      table.sort(ms, function(a, b) return U.natLess(a.name, b.name) end)
      for j = 1, math.min(#ms, 4) do
        local d, dc = dot(ms[j])
        put(22 + j, y, d, dc, C.bg)
      end
      local text, color
      if p.held then text, color = "held", C.warn
      elseif p.stalled then text, color = "stalled " .. U.fmtShort(p.stalled), C.bad
      else
        local rate, kind = ui.rateText(p)
        if rate then text, color = rate:gsub("^.-·%s+", ""), kind == "growing" and C.warn or C.dim end
      end
      if text then put(28, y, fit(text, GW - 28), color, C.bg) end
    end
    for i = 1, math.min(2, #alerts) do
      local a = alerts[#alerts - i + 1]
      put(2, GH - 3 + i, fit("⚠ " .. a.text, GW - 2), a.level == "warn" and C.warn or C.bad, C.bg)
    end
    put(2, GH, fit("tap anywhere for the full screen", GW - 2), C.dim, C.bg)
  end

  return v
end

return GlanceView
