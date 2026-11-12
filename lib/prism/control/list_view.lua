--[[ prism.control.list_view: the tabbed list in the right column.

  ListView.new(ui, m) -> v
  v.draw()     tab buttons, the list for the current tab, the search/info row and the action row

  Each tab is a descriptor in MODES (the rule preview replaces the RULES list while a rule is edited):
    rows()         the rows to list (before the search filter)
    filter         true if typing filters this list
    header()       -> text, color for the column header row
    row(y, r, bg)  draw one row
    empty()        text when there are no rows
    tap(r)         what tapping a row does (nil: nothing)
    actions(y)     buttons on the action row (optional)
  To add a tab: add a descriptor here, a button in TABS, and fetch its data in prism.control.model.
]]

local U = require("prism.util")

local ListView = {}

local TABS = {
  { id = "unassigned", label = function(st) return "UNASSIGNED " .. (st and st.unassignedCount or 0) end },
  { id = "items",      label = function(st) return "ITEMS " .. (st and st.catalogCount or "?") end },
  { id = "overrides",  label = function() return "OVERRIDES" end },
  { id = "rules",      label = function() return "RULES" end },
}

function ListView.new(ui, m)
  local S, C, L, W = m.S, ui.C, ui.L, ui.W
  local put, fill, fit, rfit, len, button = ui.put, ui.fill, ui.fit, ui.rfit, ui.len, ui.button
  local RX, RW = L.RX, L.RW

  local function batchText(r) return (r.batch or 1) > 1 and ("×" .. r.batch) or "" end
  local function processColor(p) return p == "ignore" and C.dim or C.info end
  -- "chembath›wash" when the row has a fallback
  local function processText(r) return r.fallback and (r.process .. "›" .. r.fallback) or r.process end

  -- A confirm-on-second-tap button on the action row.
  local function dangerButton(x, y, what, label, again, fn)
    local c = m.confirming(what)
    return button(x, y, c and again or label, { color = c and C.bad or C.btn, fg = c and C.bg or C.text,
      fn = function() m.askConfirm(what, fn) end })
  end

  local MODES = {}

  MODES.unassigned = {
    filter = true,
    rows = function() return S.status and S.status.unassigned or {} end,
    header = function() return fit("item", RW - 9) .. rfit("qty", 8) .. " " end,
    row = function(y, r, rb)
      put(RX, y, fit(r.label or r.key, RW - 9), C.text, rb)
      put(RX + RW - 9, y, rfit(U.fmtNum(r.size), 8) .. " ", C.warn, rb)
    end,
    empty = function() return "nothing unassigned - every item has a home" end,
    tap = function(r) return function() m.selectRow(r, "unassigned") end end,
  }

  MODES.items = {
    filter = true,
    rows = function() return S.items or {} end,
    header = function()
      return fit("item", RW - 34) .. rfit("qty", 7) .. " " .. fit("process", 15) .. rfit("batch", 5) .. rfit("from", 6)
    end,
    row = function(y, r, rb)
      local present = (r.size or 0) > 0
      put(RX, y, fit(r.label or r.key, RW - 34), present and C.text or C.dim, rb)
      put(RX + RW - 34, y, rfit(present and U.fmtNum(r.size) or "absent", 7) .. " ", present and C.text or C.dim, rb)
      local pc = r.process == nil and C.warn or (r.spilled and C.warn) or processColor(r.process)
      put(RX + RW - 26, y, fit(r.process and processText(r) or "unassigned", 15), pc, rb)
      put(RX + RW - 11, y, rfit(batchText(r), 5), C.accent, rb)
      put(RX + RW - 6, y, rfit(r.source or "", 6), C.dim, rb)
    end,
    empty = function() return S.items and "no items seen yet" or "loading ..." end,
    tap = function(r) return function() m.selectRow(r, "items") end end,
    actions = function(y)
      local x = dangerButton(RX, y, "clearAbsent", "CLEAR ABSENT", "TAP AGAIN TO CLEAR ABSENT", m.forgetAbsent)
      put(x, y, "forgets absent items without an override", C.dim, C.bg)
      if S.fetching then put(W - 12, y, "refreshing…", C.dim, C.bg) end
    end,
  }

  MODES.overrides = {
    filter = true,
    rows = function() return S.overrides or {} end,
    header = function()
      return fit("item", RW - 34) .. fit("process", 16) .. rfit("batch", 6) .. rfit("prio", 6) .. rfit("from", 6)
    end,
    row = function(y, r, rb)
      put(RX, y, fit(r.label or r.key, RW - 34), C.text, rb)
      put(RX + RW - 34, y, fit(processText(r), 16), processColor(r.process), rb)
      put(RX + RW - 18, y, rfit(batchText(r), 6), C.accent, rb)
      put(RX + RW - 12, y, rfit(r.priority or "-", 6), C.text, rb)
      put(RX + RW - 6, y, rfit(r.source or "", 6), C.dim, rb)
    end,
    empty = function() return S.overrides and "no overrides yet" or "loading ..." end,
    tap = function(r) return function() m.selectRow(r, "overrides") end end,
  }

  MODES.rules = {
    filter = true,
    rows = function() return S.rules or {} end,
    header = function()
      return fit("  # pattern", RW - 34) .. fit("process", 16) .. rfit("batch", 6) .. rfit("prio", 6) .. rfit("used", 6)
    end,
    row = function(y, r, rb)
      put(RX, y, rfit(r.index, 3) .. " " .. fit(r.pattern, RW - 38), C.text, rb)
      put(RX + RW - 34, y, fit(processText(r), 16), processColor(r.process), rb)
      put(RX + RW - 18, y, rfit(batchText(r), 6), C.accent, rb)
      put(RX + RW - 12, y, rfit(r.priority or "-", 6), C.text, rb)
      put(RX + RW - 6, y, rfit(r.used or 0, 6), (r.used or 0) == 0 and C.dim or C.text, rb)
    end,
    empty = function() return S.rules and "no rules yet - tap + NEW RULE" or "loading ..." end,
    tap = function(r) return function() m.editRule(r) end end,
    actions = function(y)
      local x = button(RX, y, "+ NEW RULE", { color = C.good, fg = C.bg, fn = m.newRule })
      if S.rulesSource == "screen" then
        x = dangerButton(x, y, "resetRules", "RESET TO prism.cfg", "TAP AGAIN TO RESET", m.resetRules)
        put(x, y, "first match wins", C.dim, C.bg)
      else
        put(x, y, "from prism.cfg - editing saves prism-rules.cfg", C.dim, C.bg)
      end
    end,
  }

  MODES.preview = {
    filter = false,
    rows = function() return S.preview and S.preview.list or {} end,
    header = function()
      local p = S.preview
      if p and p.total then
        return fit(("PREVIEW  %d match  ·  %d would use this rule"):format(p.total, p.applies or 0), RW), C.accent
      end
      return fit("PREVIEW  type a pattern to see what it catches", RW), C.accent
    end,
    row = function(y, r, rb)
      put(RX, y, fit(r.label, RW - 34), C.text, rb)
      put(RX + RW - 34, y, fit(r.now or "unassigned", 12), r.now and C.dim or C.warn, rb)
      put(RX + RW - 22, y, rfit(r.effect, 22), r.effect == "applies" and C.good or C.warn, rb)
    end,
    empty = function()
      return S.preview and S.preview.error and "" or (S.preview and "the pattern matches nothing seen so far" or "")
    end,
    tap = function() return nil end,
  }

  local function mode()
    if S.tab == "rules" and S.ruleEdit then return MODES.preview end
    return MODES[S.tab]
  end

  local function visibleRows(md)
    local rows = md.rows()
    if not md.filter or S.filter == "" then return rows end
    local f, out = S.filter:lower(), {}
    for _, r in ipairs(rows) do
      local text = (r.label or r.pattern or ""):lower()
      if text:find(f, 1, true) or (r.key and r.key:lower():find(f, 1, true)) then out[#out + 1] = r end
    end
    return out
  end

  local v = {}

  function v.draw()
    fill(RX - 1, 2, W - RX + 2, L.PANEL_TOP - 2, C.bg)
    ui.fg(C.line)
    fill(RX - 2, 3, 1, ui.H - 4, C.bg, "│")   -- column divider

    local st = S.status
    local ucount = st and st.unassignedCount or 0
    local x = RX
    for _, t in ipairs(TABS) do
      local alert = t.id == "unassigned" and ucount > 0 and S.tab ~= "unassigned"
      x = button(x, 3, t.label(st), { on = S.tab == t.id, fg = alert and C.warn or nil,
                                      fn = function() m.switchTab(t.id) end })
    end

    local md = mode()
    local rows = visibleRows(md)
    local visible = L.LIST_BOTTOM - L.LIST_TOP + 1
    local maxScroll = math.max(0, #rows - visible)
    if S.scroll > maxScroll then S.scroll = maxScroll end
    button(W - 8, 3, "▲", { disabled = S.scroll == 0, fn = function() m.setScroll(S.scroll - (visible - 1)) end })
    button(W - 4, 3, "▼", { disabled = S.scroll >= maxScroll, fn = function() m.setScroll(S.scroll + (visible - 1)) end })

    local header, headerColor = md.header()
    put(RX, 4, header, headerColor or C.dim, C.bg)
    for i = 1, visible do
      local r = rows[i + S.scroll]
      if not r then break end
      local y = L.LIST_TOP + i - 1
      local selected = S.tab ~= "rules" and S.sel and S.sel.key == r.key and S.sel.list == S.tab
      md.row(y, r, selected and C.sel or C.bg)
      local fn = md.tap(r)
      if fn then ui.hit(RX, y, W - 1, y, fn) end
    end

    if #rows == 0 then
      local empty = md.filter and S.filter ~= "" and ("nothing matches \"" .. S.filter .. "\"") or md.empty()
      put(RX, L.LIST_TOP, empty, C.dim, C.bg)
    end

    -- info row: search (or the rule hint) on the left, position on the right
    if S.ruleEdit then
      put(RX, L.INFO_ROW, "keyboard edits the pattern", C.dim, C.bg)
    elseif S.filter ~= "" then
      local s = "search: " .. S.filter .. "_"
      put(RX, L.INFO_ROW, s, C.accent, C.bg)
      button(RX + len(s) + 1, L.INFO_ROW, "✕", { fn = m.clearFilter })
    else
      put(RX, L.INFO_ROW, "type to search", C.dim, C.bg)
    end
    if #rows > visible then
      local pos = ("%d-%d of %d"):format(S.scroll + 1, math.min(#rows, S.scroll + visible), #rows)
      put(W - len(pos), L.INFO_ROW, pos, C.dim, C.bg)
    elseif S.tab == "unassigned" and st and (st.unassignedCount or 0) > #rows and S.filter == "" then
      local note = ("router sent top %d of %d"):format(#rows, st.unassignedCount)
      put(W - len(note), L.INFO_ROW, note, C.dim, C.bg)
    end

    if md.actions then md.actions(L.ACTION_ROW) end
  end

  return v
end

return ListView
