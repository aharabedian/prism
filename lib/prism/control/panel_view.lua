--[[ prism.control.panel_view: the panel under the list and the footer.

  PanelView.new(ui, m) -> v
  v.draw()        the process panel while a process is selected, the rule editor while a rule is
                  edited, else ROUTE ITEM (or the RULES help)
  v.drawFooter()  flash message / router error / rotating alerts, RELOAD CFG and QUIT
]]

local U = require("prism.util")

local PanelView = {}

function PanelView.new(ui, m)
  local S, C, L, W, H = m.S, ui.C, ui.L, ui.W, ui.H
  local put, fill, fit, rfit, len, button = ui.put, ui.fill, ui.fit, ui.rfit, ui.len, ui.button
  local RX, RW, P = L.RX, L.RW, L.PANEL_TOP

  local function processButtons(y0, current)
    local procs = {}
    for _, p in ipairs(S.status and S.status.knownProcesses or {}) do procs[#procs + 1] = p end
    procs[#procs + 1] = "ignore"
    local x, y = RX + 1, y0
    for _, p in ipairs(procs) do
      if x + len(p) + 2 > W then x, y = RX + 1, y + 1 end
      if y > y0 + 1 then break end
      x = button(x, y, p, { on = current == p, fn = function() m.pickProcess(p) end })
    end
  end

  -- Where items go when `process` has too much waiting (or is diverted): none, or another process.
  local function fallbackButtons(y, process, current)
    put(RX + 1, y, "Fallback", C.dim, C.panel)
    if not process or process == "ignore" then
      put(RX + 11, y, "-", C.dim, C.panel)
      return
    end
    local x = button(RX + 11, y, "none", { on = current == nil, fn = function() m.pickFallback(nil) end })
    local listed = current == nil
    for _, p in ipairs(S.status and S.status.knownProcesses or {}) do
      if p ~= process then
        if p == current then listed = true end
        if x + len(p) + 2 > W then break end
        x = button(x, y, p, { on = current == p, fn = function() m.pickFallback(p) end })
      end
    end
    if not listed and x + len(current) + 2 <= W then button(x, y, current, { on = true }) end
  end

  local function batchButtons(y, current)
    put(RX + 1, y, "Batch", C.dim, C.panel)
    local x, listed = RX + 11, false
    for _, b in ipairs(m.settings.batches) do
      if b == current then listed = true end
      if x + len(tostring(b)) + 2 > W then break end
      x = button(x, y, tostring(b), { on = current == b, fn = function() m.pickBatch(b) end })
    end
    if not listed then put(x, y, " ×" .. current .. " ", C.text, C.btnOn) end
  end

  local function priorityButtons(y, current)
    put(RX + 1, y, "Priority", C.dim, C.panel)
    local x = RX + 11
    x = button(x, y, "-10", { fn = function() m.pickPriority(math.max(0, current - 10)) end })
    x = button(x, y, "-1",  { fn = function() m.pickPriority(math.max(0, current - 1)) end })
    put(x, y, rfit(current, 4) .. " ", C.accent, C.panel); x = x + 6
    x = button(x, y, "+1",  { fn = function() m.pickPriority(current + 1) end })
    button(x, y, "+10",     { fn = function() m.pickPriority(current + 10) end })
  end

  local function drawRulePanel()
    local r = S.ruleEdit
    fill(RX, P, RW, H - 1 - P, C.panel)
    put(RX, P, r.index and (" EDIT RULE #" .. r.index) or " NEW RULE  (added at the top - first match wins)", C.accent, C.panel)
    put(RX + 1, P + 1, "Pattern", C.dim, C.panel)
    put(RX + 10, P + 1, fit(r.pattern .. "_", RW - 11), C.text, C.field)
    local p = S.preview
    if p and p.error then
      put(RX + 1, P + 2, fit("bad pattern: " .. p.error, RW - 2), C.bad, C.panel)
    else
      put(RX + 1, P + 2, fit("^ start   $ end   .+ anything   %. a literal dot   [AB] A or B", RW - 2), C.dim, C.panel)
    end

    processButtons(P + 4, r.process)
    fallbackButtons(P + 7, r.process, r.fallback)
    batchButtons(P + 8, r.batch)
    priorityButtons(P + 9, r.priority)

    local nRules = S.rules and #S.rules or 0
    local x = RX + 1
    x = button(x, P + 11, "SAVE", { color = C.good, fg = C.bg,
      disabled = not r.process or r.pattern == "" or (p and p.error ~= nil), fn = m.saveRule })
    if r.index then
      local c = m.confirming("deleteRule")
      x = button(x, P + 11, c and "TAP AGAIN" or "DELETE", { color = C.bad, fg = C.bg,
        fn = function() m.askConfirm("deleteRule", m.deleteRule) end })
      x = button(x, P + 11, "▲ UP", { disabled = r.index <= 1, fn = function() m.moveRule(-1) end })
      x = button(x, P + 11, "▼ DOWN", { disabled = r.index >= nRules, fn = function() m.moveRule(1) end })
    end
    button(x, P + 11, "CANCEL", { fn = m.cancelRule })
  end

  local function drawItemPanel()
    fill(RX, P, RW, H - 1 - P, C.panel)
    if S.tab == "rules" then
      put(RX, P, " RULES", C.accent, C.panel)
      put(RX + 1, P + 2, "Tap a rule to edit or reorder it, or + NEW RULE.", C.dim, C.panel)
      put(RX + 1, P + 3, "Tip: MAKE RULE on any item starts a rule from its name.", C.dim, C.panel)
      return
    end
    put(RX, P, " ROUTE ITEM", C.accent, C.panel)
    local sel = S.sel
    if not sel then
      put(RX + 1, P + 2, "Tap an item in the list to choose where it goes.", C.dim, C.panel)
      put(RX + 1, P + 3, "ITEMS lists everything seen, even when none is in stock.", C.dim, C.panel)
      return
    end

    put(RX + 1, P + 1, fit(sel.label or sel.key, RW - 2), C.text, C.panel)
    local src = ({ cfg = "set in prism.cfg", rule = "matched by a rule", gui = "screen override" })[sel.source or ""]
    local info = sel.key .. (sel.size and sel.size > 0 and ("   ×" .. U.fmtNum(sel.size)) or "")
                         .. (src and ("   (" .. src .. ")") or "")
    put(RX + 1, P + 2, fit(info, RW - 2), C.dim, C.panel)

    processButtons(P + 4, S.selProc)
    fallbackButtons(P + 7, S.selProc, S.selFallback)
    batchButtons(P + 8, S.selBatch)
    priorityButtons(P + 9, S.selPrio)

    local x = RX + 1
    x = button(x, P + 11, "APPLY", { color = C.good, fg = C.bg, disabled = not S.selProc, fn = m.apply })
    if sel.source == "gui" then x = button(x, P + 11, "REMOVE OVERRIDE", { color = C.bad, fg = C.bg, fn = m.removeOverride }) end
    if sel.list == "items" then x = button(x, P + 11, "FORGET", { color = C.bad, fg = C.bg, fn = m.forget }) end
    if sel.label then x = button(x, P + 11, "MAKE RULE", { fn = m.makeRule }) end
    button(x, P + 11, "CANCEL", { fn = m.cancelSelection })
  end

  local function drawProcessPanel()
    local name = S.procSel
    local p = S.status and S.status.processes and S.status.processes[name] or {}
    fill(RX, P, RW, H - 1 - P, C.panel)
    put(RX, P, " PROCESS " .. name, C.accent, C.panel)
    put(RX + 1, P + 2, fit(("%s items waiting (%d types)  ·  %d output(s)"):format(
      U.fmtNum(p.items or 0), p.types or 0, p.buses or 0), RW - 2), C.text, C.panel)
    if p.overflow then
      local text = ("Overflow: past %s waiting, items with a fallback are shared"):format(U.fmtNum(p.overflow))
      put(RX + 1, P + 3, fit(text, RW - 2), C.text, C.panel)
    else
      put(RX + 1, P + 3, fit(("No overflow limit (processes.%s.overflow in prism.cfg)"):format(name), RW - 2), C.dim, C.panel)
    end
    if (p.spilled or 0) > 0 then
      put(RX + 1, P + 4, fit(("↷ %s items shared with their fallbacks"):format(U.fmtNum(p.spilled)), RW - 2), C.warn, C.panel)
    else
      put(RX + 1, P + 4, "nothing going to fallbacks", C.dim, C.panel)
    end
    if p.diverted then
      put(RX + 1, P + 5, fit("DIVERTED: every item with a fallback is shared", RW - 2), C.warn, C.panel)
    end
    put(RX + 1, P + 7, fit("Fallbacks are set per rule or override (the Fallback row).", RW - 2), C.dim, C.panel)
    put(RX + 1, P + 8, fit("Items without one always wait for this process.", RW - 2), C.dim, C.panel)

    local x = RX + 1
    if p.diverted then
      x = button(x, P + 11, "STOP DIVERTING", { color = C.good, fg = C.bg, fn = function() m.divert(false) end })
    else
      x = button(x, P + 11, "DIVERT TO FALLBACKS", { color = C.warn, fg = C.bg, fn = function() m.divert(true) end })
    end
    button(x, P + 11, "CLOSE", { fn = m.cancelProcess })
  end

  local v = {}

  function v.draw()
    if S.procSel then drawProcessPanel()
    elseif S.ruleEdit then drawRulePanel() else drawItemPanel() end
  end

  function v.drawFooter()
    fill(1, H, W, 1, C.panel)
    local text, color
    local alerts = S.status and S.status.alerts or {}
    if S.msg then
      text, color = S.msg, S.msgOk and C.good or C.bad
    elseif S.status and S.status.lastError then
      text, color = "router: " .. S.status.lastError, C.bad
    elseif #alerts > 0 then
      local a = alerts[S.alertTick % #alerts + 1]
      text = ("⚠ %s%s"):format(a.text, #alerts > 1 and ("   (" .. (S.alertTick % #alerts + 1) .. "/" .. #alerts .. ")") or "")
      color = a.level == "warn" and C.warn or C.bad
    else
      text, color = "Tap an item to route it  ·  type to search  ·  Ctrl+C or QUIT to exit", C.dim
    end
    put(2, H, fit(text, W - 28), color, C.panel)
    local x = button(W - 24, H, "RELOAD CFG", { fn = m.reloadRouter })
    button(x, H, "QUIT", { color = C.bad, fg = C.bg, fn = m.quit })
  end

  return v
end

return PanelView
