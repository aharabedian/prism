--[[ prism.control.panel_view: the panel under the list and the footer.

  PanelView.new(ui, m) -> v
  v.draw()        the rule editor while a rule is edited, else ROUTE ITEM (or the RULES help)
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
    batchButtons(P + 7, r.batch)
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
    batchButtons(P + 7, S.selBatch)
    priorityButtons(P + 9, S.selPrio)

    local x = RX + 1
    x = button(x, P + 11, "APPLY", { color = C.good, fg = C.bg, disabled = not S.selProc, fn = m.apply })
    if sel.source == "gui" then x = button(x, P + 11, "REMOVE OVERRIDE", { color = C.bad, fg = C.bg, fn = m.removeOverride }) end
    if sel.list == "items" then x = button(x, P + 11, "FORGET", { color = C.bad, fg = C.bg, fn = m.forget }) end
    if sel.label then x = button(x, P + 11, "MAKE RULE", { fn = m.makeRule }) end
    button(x, P + 11, "CANCEL", { fn = m.cancelSelection })
  end

  local v = {}

  function v.draw()
    if S.ruleEdit then drawRulePanel() else drawItemPanel() end
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
