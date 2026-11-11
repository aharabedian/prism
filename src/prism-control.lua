--[[ prism-control.lua - touchscreen control panel for prism.lua

  Runs on the display computer (tier 3 screen + GPU, wireless card).
  Left:  per-process backlog (stalls flagged), export buses, feeders and
         monitored machines with live progress.
  Right: UNASSIGNED, ITEMS (everything ever seen), OVERRIDES and RULES.
         Tap an item to route it; tap a rule (or + NEW RULE / MAKE RULE) to
         edit it with a live preview of what it would catch.
  Keyboard: types into the search box, or into the pattern while editing a rule.

  Usage: prism-control [path]   (default /home/prism-control.cfg; run prism-setup to write it)
  QUIT button or Ctrl+C to exit.
]]

local component     = require("component")
local computer      = require("computer")
local event         = require("event")
local serialization = require("serialization")
local unicode       = require("unicode")
local term          = require("term")

local VERSION = "0.4.0"

---------------------------------------------------------------- settings

-- From prism-control.cfg (written by prism-setup); every setting has a default, so the file is optional.
local CONFIG_PATH = ({ ... })[1] or "/home/prism-control.cfg"

local function loadSettings()
  local f = io.open(CONFIG_PATH, "r")
  if not f then return {} end
  f:close()
  local fn, err = loadfile(CONFIG_PATH, "t", {})
  if not fn then error("can't load " .. CONFIG_PATH .. ": " .. tostring(err), 0) end
  local ok, t = pcall(fn)
  if not ok or type(t) ~= "table" then error("bad config " .. CONFIG_PATH .. ": " .. tostring(t), 0) end
  return t
end

local settings = loadSettings()
local function opt(v, default) if v == nil then return default end return v end
local PORT        = opt(settings.modemPort, 4242)  -- must match the router's modemPort; false = wireless off
local TOKEN       = settings.token or nil         -- must match the router's token, if it has one
local HISTORY     = opt(settings.history, 60)      -- backlog samples kept for the sparklines
local STALE_AFTER = opt(settings.staleAfter, 3)    -- missed router cycles before showing NO SIGNAL
local BEEP        = opt(settings.beep, true)       -- beep when a new alert appears
local BATCHES     = opt(settings.batches, { 1, 2, 3, 4, 6, 8, 9, 16, 32, 36, 64 })

local C = {
  bg     = 0x0f1419, panel = 0x1a2129, line  = 0x2c3640,
  text   = 0xe6e9ec, dim   = 0x7d8a96, accent = 0xffa62b,
  good   = 0x4cd17a, bad   = 0xff5c5c, warn  = 0xffd24c, info = 0x5fb4ff,
  btn    = 0x2c3640, btnOn = 0x2f6fb5, sel   = 0x24384d, field = 0x0b0f13,
}

local SPARK = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

---------------------------------------------------------------- setup

local gpu = component.gpu
local modem = PORT and component.isAvailable("modem") and component.modem or nil

local W, H = gpu.maxResolution()
if W < 100 or H < 36 then
  error("prism-control.lua needs a tier 3 GPU and screen (got " .. W .. "x" .. H .. ")", 0)
end
gpu.setResolution(W, H)

local LW          = math.floor(W * 0.56)  -- left column width
local RX          = LW + 3                -- right column start
local RW          = W - RX                -- right column width (RX .. W-1)
local PANEL_TOP   = H - 14
local LIST_TOP    = 5
local LIST_BOTTOM = PANEL_TOP - 4
local INFO_ROW    = PANEL_TOP - 3
local ACTION_ROW  = PANEL_TOP - 2

local S = {
  running = true,
  status = nil, statusAt = nil, lastCycle = nil, router = nil,
  history = {}, alertIds = {}, alertTick = 0,
  overrides = nil,
  items = nil, itemsBuf = nil, itemsReq = 0, fetching = false, fetchAt = 0,
  rules = nil, rulesSource = nil,
  ruleEdit = nil, preview = nil, previewReq = 0,
  tab = "unassigned", scroll = 0, filter = "",
  sel = nil, selProc = nil, selPrio = 10, selBatch = 1,
  msg = nil, msgOk = true, msgAt = 0,
  confirm = nil, confirmAt = 0,
  machY = nil, machCount = 0,
}

---------------------------------------------------------------- drawing helpers

local curFg, curBg
local function fg(c) if c ~= curFg then gpu.setForeground(c); curFg = c end end
local function bg(c) if c ~= curBg then gpu.setBackground(c); curBg = c end end
local function put(x, y, s, f, b)
  if b then bg(b) end
  fg(f or C.text)
  gpu.set(x, y, s)
end
local function fill(x, y, w, h, b, ch)
  if w > 0 and h > 0 then bg(b); gpu.fill(x, y, w, h, ch or " ") end
end

local function len(s) return unicode.len(s) end
local function fit(s, n)
  s = tostring(s or "")
  if n <= 0 then return "" end
  local l = len(s)
  if l > n then return unicode.sub(s, 1, n - 1) .. "…" end
  return s .. string.rep(" ", n - l)
end
local function rfit(s, n)
  s = tostring(s or "")
  local l = len(s)
  if l >= n then return unicode.sub(s, 1, n) end
  return string.rep(" ", n - l) .. s
end
local function fmtNum(n)
  n = n or 0
  if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
  if n >= 1e4 then return string.format("%.1fk", n / 1e3) end
  return tostring(math.floor(n))
end
local function fmtTime(s)
  s = math.floor(s or 0)
  local h, m = math.floor(s / 3600), math.floor(s % 3600 / 60)
  if h > 0 then return string.format("%dh%02dm", h, m) end
  return string.format("%dm%02ds", m, s % 60)
end
local function pct(x) return x and (math.floor(x * 100 + 0.5) .. "%") or "" end

-- Touch targets, rebuilt on every full redraw: { x1, y1, x2, y2, fn }
local hits = {}
local function hit(x1, y1, x2, y2, fn) hits[#hits + 1] = { x1, y1, x2, y2, fn } end

local function button(x, y, label, o)
  o = o or {}
  local s = " " .. label .. " "
  local back = o.on and C.btnOn or (o.color or C.btn)
  put(x, y, s, o.disabled and C.dim or (o.fg or C.text), back)
  if o.fn and not o.disabled then hit(x, y, x + len(s) - 1, y, o.fn) end
  return x + len(s) + 1
end

local function confirming(what) return S.confirm == what and computer.uptime() - S.confirmAt <= 5 end

---------------------------------------------------------------- commands

local function flash(text, ok) S.msg, S.msgOk, S.msgAt = text, ok, computer.uptime() end

local function sendCmd(t)
  if not modem then flash("no network card in this computer", false); return end
  t.token = TOKEN
  local data = serialization.serialize(t)
  if S.router then modem.send(S.router, PORT, data) else modem.broadcast(PORT, data) end
end

local function fetchItems()
  S.itemsReq = S.itemsReq + 1
  S.itemsBuf, S.fetching, S.fetchAt = {}, true, computer.uptime()
  sendCmd({ cmd = "items", offset = 0, req = S.itemsReq })
end

local function requestPreview()
  local r = S.ruleEdit
  if not r then return end
  if r.pattern == "" then S.preview = nil; return end
  S.previewReq = S.previewReq + 1
  sendCmd({ cmd = "previewRule", pattern = r.pattern, index = r.index, process = r.process, req = S.previewReq })
end

local function refreshTab()
  if S.tab == "items" then fetchItems()
  elseif S.tab == "overrides" then sendCmd({ cmd = "overrides" })
  elseif S.tab == "rules" then
    sendCmd({ cmd = "rules" })
    requestPreview()
  end
end

local function apply()
  local sel = S.sel
  if not (sel and S.selProc) then return end
  sendCmd({ cmd = "assign", key = sel.key, process = S.selProc, priority = S.selPrio,
            batch = S.selBatch, label = sel.label })
  flash(("sending %s -> %s ..."):format(sel.label or sel.key, S.selProc), true)
  S.sel = nil
end

local function remove()
  if not S.sel then return end
  sendCmd({ cmd = "unassign", key = S.sel.key })
  flash(("removing override for %s ..."):format(S.sel.label or S.sel.key), true)
  S.sel = nil
end

local function forget()
  if not S.sel then return end
  sendCmd({ cmd = "forget", key = S.sel.key })
  flash(("forgetting %s ..."):format(S.sel.label or S.sel.key), true)
  S.sel = nil
end

local function askConfirm(what, fn)
  if confirming(what) then
    S.confirm = nil
    fn()
  else
    S.confirm, S.confirmAt = what, computer.uptime()
  end
end

local function selectRow(row, list)
  S.sel = { key = row.key, label = row.label, size = row.size, list = list,
            source = row.source, process = row.process }
  S.selProc  = row.process
  S.selPrio  = row.priority or 10
  S.selBatch = row.batch or 1
end

local function switchTab(tab)
  if tab ~= "rules" then S.ruleEdit, S.preview = nil, nil end
  S.tab, S.scroll = tab, 0
  refreshTab()
end

local function editRule(rule)
  S.sel = nil
  S.ruleEdit = { index = rule.index, pattern = rule.pattern or "", process = rule.process,
                 priority = rule.priority or 10, batch = rule.batch or 1 }
  S.preview, S.scroll = nil, 0
  requestPreview()
end

local function escapePattern(s) return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")) end

local function makeRule()
  local sel = S.sel
  if not sel then return end
  local rule = { pattern = "^" .. escapePattern(sel.label or "") .. "$", process = S.selProc,
                 priority = S.selPrio, batch = S.selBatch }
  S.tab, S.scroll = "rules", 0
  sendCmd({ cmd = "rules" })
  editRule(rule)
end

local function saveRule()
  local r = S.ruleEdit
  if not (r and r.process and r.pattern ~= "") then return end
  sendCmd({ cmd = "setRule", index = r.index, pattern = r.pattern, process = r.process,
            priority = r.priority, batch = r.batch })
  flash("saving rule ...", true)
  S.ruleEdit, S.preview = nil, nil
end

---------------------------------------------------------------- left column

local function drawHeader()
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
  if age > (st.interval or 5) * STALE_AFTER then
    text = "● NO SIGNAL  last update " .. fmtTime(age) .. " ago"
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
    st.cycles or 0, st.cycleMs or 0, fmtNum(st.writes), fmtTime(st.uptime))
  put(W - len(right) + 1, 1, right, C.dim, C.panel)
  if st.version ~= VERSION then   -- router and screen running different releases
    local v = (" router %s ≠ screen %s "):format(tostring(st.version or "?"), VERSION)
    put(W - len(right) - len(v), 1, v, C.bg, C.warn)
  end
end

local function sparkline(series, width)
  local n, m, out = #series, 0, {}
  for i = math.max(1, n - width + 1), n do if series[i] > m then m = series[i] end end
  for i = n - width + 1, n do
    local v = series[i]
    if not v then out[#out + 1] = " "
    elseif m == 0 then out[#out + 1] = SPARK[1]
    else out[#out + 1] = SPARK[1 + math.floor(v / m * 7 + 0.5)] end
  end
  return table.concat(out)
end

local function countKeys(t) local n = 0; for _ in pairs(t or {}) do n = n + 1 end; return n end

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
    put(x, y, rfit(fmtNum(items), 8), C.text);                             x = x + 8 + 2
    local f = math.floor(items / maxItems * BW + 0.5)
    if items > 0 and f == 0 then f = 1 end
    if f > 0 then put(x, y, string.rep("█", f), (none or stalled) and C.bad or C.accent) end
    if f < BW then put(x + f, y, string.rep("·", BW - f), C.line) end
    x = x + BW + 2
    local hist = S.history[name] or {}
    put(x, y, sparkline(hist, spW), C.info); x = x + spW + 1
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
  put(2, y, "EXPORT BUSES", C.accent, C.bg); y = y + 1
  for i, b in ipairs(list) do
    if y > H - 2 or (not compact and y + 1 > H - 2) then
      put(2, y, ("+%d more"):format(#list - i + 1), C.dim, C.bg); return y + 1
    end
    local nf = b.filters and #b.filters or 0
    put(2, y, fit(b.name, 18), C.text, C.bg)
    put(20, y, fit("[" .. tostring(b.process) .. "]", 14), C.info)
    local summary = nf == 0 and "idle" or (nf .. (nf == 1 and " filter" or " filters"))
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

local function feederColor(state)
  state = state or ""
  if state == "feeding" then return C.good end
  if state == "idle" then return C.dim end
  if state:find("^blocked") or state:find("^error") or state:find("^warning") then return C.bad end
  return C.warn
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
    local what = f.label and (f.label .. ((f.batch or 1) > 1 and ("  ×" .. f.batch) or "")) or "-"
    put(2, y, fit(f.name, 18), C.text, C.bg)
    put(20, y, fit("[" .. tostring(f.process) .. "]", 14), C.info)
    if compact then
      put(34, y, fit(f.state or "?", 20), feederColor(f.state))
      put(55, y, fit(what, LW - 55), C.dim)
      y = y + 1
    else
      put(34, y, fit(f.state or "?", LW - 34), feederColor(f.state))
      y = y + 1
      put(4, y, fit(what, LW - 20), C.dim)
      put(LW - 15, y, rfit("fed " .. fmtNum(f.fed), 15), C.dim)
      y = y + 1
    end
  end
  return y
end

local MACHINE_COLORS = { working = "good", idle = "dim", disabled = "warn" }

local function drawMachineRow(y, m)
  put(2, y, fit(m.name, 16), C.text, C.bg)
  put(18, y, fit("[" .. tostring(m.process or "-") .. "]", 13), C.info)
  local state, color = m.state or "?", C[MACHINE_COLORS[m.state] or "bad"]
  if m.state == "idle" and m.idle then state, color = "idle " .. (fmtTime(m.idle):gsub("^0m", "")), C.warn end
  put(31, y, fit(state, 13), color)
  local BW = 16
  local f = m.progress and math.floor(m.progress * BW + 0.5) or 0
  if f > 0 then put(44, y, string.rep("█", f), C.info) end
  if f < BW then put(44 + f, y, string.rep("·", BW - f), C.line) end
  put(60, y, rfit(m.state == "working" and pct(m.progress) or "", 5), C.dim)
  if m.eu then put(66, y, "⚡" .. rfit(pct(m.eu), 4), m.eu < 0.2 and C.bad or C.dim)
  else put(66, y, "     ", C.dim) end
end

local function drawMachines(y)
  local list = S.status and S.status.machines or {}
  S.machY, S.machCount = nil, 0
  if #list == 0 then return y end
  y = y + 1
  if y > H - 3 then return y end
  put(2, y, "MACHINES", C.accent, C.bg); y = y + 1
  S.machY = y
  for i, m in ipairs(list) do
    if y > H - 2 then put(2, y, ("+%d more"):format(#list - i + 1), C.dim, C.bg); break end
    drawMachineRow(y, m)
    S.machCount = i
    y = y + 1
  end
  return y
end

-- Just the machine rows, for the frequent machine updates between scans.
local function redrawMachines()
  local list = S.status and S.status.machines or {}
  if not S.machY then return end
  for i = 1, S.machCount do
    if list[i] then drawMachineRow(S.machY + i - 1, list[i]) end
  end
end

local function leftRows(st, compact)
  local per = compact and 1 or 2
  local n = 2 + math.max(1, countKeys(st.processes))
  if #(st.buses or {}) > 0 then n = n + 2 + #st.buses * per end
  if #(st.feeders or {}) > 0 then n = n + 2 + #st.feeders * per end
  if #(st.machines or {}) > 0 then n = n + 2 + #st.machines end
  return n
end

---------------------------------------------------------------- right column

local function listRows()
  local rows
  if S.tab == "unassigned" then rows = S.status and S.status.unassigned or {}
  elseif S.tab == "items" then rows = S.items or {}
  elseif S.tab == "overrides" then rows = S.overrides or {}
  elseif S.ruleEdit then return S.preview and S.preview.list or {}
  else rows = S.rules or {} end
  if S.filter == "" then return rows end
  local f, out = S.filter:lower(), {}
  for _, r in ipairs(rows) do
    local text = (r.label or r.pattern or ""):lower()
    if text:find(f, 1, true) or (r.key and r.key:lower():find(f, 1, true)) then out[#out + 1] = r end
  end
  return out
end

local function drawListHeader()
  local h
  if S.tab == "unassigned" then
    h = fit("item", RW - 9) .. rfit("qty", 8) .. " "
  elseif S.tab == "items" then
    h = fit("item", RW - 30) .. rfit("qty", 7) .. " " .. fit("process", 11) .. rfit("batch", 5) .. rfit("from", 6)
  elseif S.tab == "overrides" then
    h = fit("item", RW - 30) .. fit("process", 12) .. rfit("batch", 6) .. rfit("prio", 6) .. rfit("from", 6)
  elseif S.ruleEdit then
    local p = S.preview
    if p and p.total then
      h = fit(("PREVIEW  %d match  ·  %d would use this rule"):format(p.total, p.applies or 0), RW)
    else
      h = fit("PREVIEW  type a pattern to see what it catches", RW)
    end
    put(RX, 4, h, C.accent, C.bg)
    return
  else
    h = fit("  # pattern", RW - 30) .. fit("process", 12) .. rfit("batch", 6) .. rfit("prio", 6) .. rfit("used", 6)
  end
  put(RX, 4, h, C.dim, C.bg)
end

local function drawRow(y, r, rb)
  local batch = (r.batch or 1) > 1 and ("×" .. r.batch) or ""
  if S.tab == "unassigned" then
    put(RX, y, fit(r.label or r.key, RW - 9), C.text, rb)
    put(RX + RW - 9, y, rfit(fmtNum(r.size), 8) .. " ", C.warn, rb)
  elseif S.tab == "items" then
    local present = (r.size or 0) > 0
    put(RX, y, fit(r.label or r.key, RW - 30), present and C.text or C.dim, rb)
    put(RX + RW - 30, y, rfit(present and fmtNum(r.size) or "absent", 7) .. " ", present and C.text or C.dim, rb)
    put(RX + RW - 22, y, fit(r.process or "unassigned", 11),
        r.process == nil and C.warn or (r.process == "ignore" and C.dim or C.info), rb)
    put(RX + RW - 11, y, rfit(batch, 5), C.accent, rb)
    put(RX + RW - 6, y, rfit(r.source or "", 6), C.dim, rb)
  elseif S.tab == "overrides" then
    put(RX, y, fit(r.label or r.key, RW - 30), C.text, rb)
    put(RX + RW - 30, y, fit(r.process, 12), r.process == "ignore" and C.dim or C.info, rb)
    put(RX + RW - 18, y, rfit(batch, 6), C.accent, rb)
    put(RX + RW - 12, y, rfit(r.priority or "-", 6), C.text, rb)
    put(RX + RW - 6, y, rfit(r.source or "", 6), C.dim, rb)
  elseif S.ruleEdit then
    local good = r.effect == "applies"
    put(RX, y, fit(r.label, RW - 34), C.text, rb)
    put(RX + RW - 34, y, fit(r.now or "unassigned", 12), r.now and C.dim or C.warn, rb)
    put(RX + RW - 22, y, rfit(r.effect, 22), good and C.good or C.warn, rb)
  else
    put(RX, y, rfit(r.index, 3) .. " " .. fit(r.pattern, RW - 34), C.text, rb)
    put(RX + RW - 30, y, fit(r.process, 12), r.process == "ignore" and C.dim or C.info, rb)
    put(RX + RW - 18, y, rfit(batch, 6), C.accent, rb)
    put(RX + RW - 12, y, rfit(r.priority or "-", 6), C.text, rb)
    put(RX + RW - 6, y, rfit(r.used or 0, 6), (r.used or 0) == 0 and C.dim or C.text, rb)
  end
end

local function drawList()
  fill(RX - 1, 2, W - RX + 2, PANEL_TOP - 2, C.bg)
  fg(C.line)
  fill(RX - 2, 3, 1, H - 4, C.bg, "│")   -- column divider

  local st = S.status
  local ucount = st and st.unassignedCount or 0
  local x = RX
  x = button(x, 3, "UNASSIGNED " .. ucount, { on = S.tab == "unassigned",
    fg = (ucount > 0 and S.tab ~= "unassigned") and C.warn or nil,
    fn = function() switchTab("unassigned") end })
  x = button(x, 3, "ITEMS " .. (st and st.catalogCount or "?"), { on = S.tab == "items",
    fn = function() switchTab("items") end })
  x = button(x, 3, "OVERRIDES", { on = S.tab == "overrides", fn = function() switchTab("overrides") end })
  button(x, 3, "RULES", { on = S.tab == "rules", fn = function() switchTab("rules") end })

  local rows = listRows()
  local visible = LIST_BOTTOM - LIST_TOP + 1
  local maxScroll = math.max(0, #rows - visible)
  if S.scroll > maxScroll then S.scroll = maxScroll end
  button(W - 8, 3, "▲", { disabled = S.scroll == 0,
    fn = function() S.scroll = math.max(0, S.scroll - (visible - 1)) end })
  button(W - 4, 3, "▼", { disabled = S.scroll >= maxScroll,
    fn = function() S.scroll = S.scroll + (visible - 1) end })

  drawListHeader()
  for i = 1, visible do
    local r = rows[i + S.scroll]
    if not r then break end
    local y = LIST_TOP + i - 1
    local selected = S.tab ~= "rules" and S.sel and S.sel.key == r.key and S.sel.list == S.tab
    drawRow(y, r, selected and C.sel or C.bg)
    if S.tab == "rules" then
      if not S.ruleEdit then hit(RX, y, W - 1, y, function() editRule(r) end) end
    else
      local tab = S.tab
      hit(RX, y, W - 1, y, function() selectRow(r, tab) end)
    end
  end

  if #rows == 0 then
    local empty
    if S.ruleEdit then
      empty = S.preview and S.preview.error and "" or (S.preview and "the pattern matches nothing seen so far" or "")
    elseif S.filter ~= "" then empty = "nothing matches \"" .. S.filter .. "\""
    elseif S.tab == "unassigned" then empty = "nothing unassigned - every item has a home"
    elseif S.tab == "items" then empty = S.items and "no items seen yet" or "loading ..."
    elseif S.tab == "overrides" then empty = S.overrides and "no overrides yet" or "loading ..."
    else empty = S.rules and "no rules yet - tap + NEW RULE" or "loading ..." end
    put(RX, LIST_TOP, empty, C.dim, C.bg)
  end

  -- info row: search (or rule source) on the left, position on the right
  if S.ruleEdit then
    put(RX, INFO_ROW, "keyboard edits the pattern", C.dim, C.bg)
  elseif S.filter ~= "" then
    local s = "search: " .. S.filter .. "_"
    put(RX, INFO_ROW, s, C.accent, C.bg)
    button(RX + len(s) + 1, INFO_ROW, "✕", { fn = function() S.filter, S.scroll = "", 0 end })
  else
    put(RX, INFO_ROW, "type to search", C.dim, C.bg)
  end
  if #rows > visible then
    local pos = ("%d-%d of %d"):format(S.scroll + 1, math.min(#rows, S.scroll + visible), #rows)
    put(W - len(pos), INFO_ROW, pos, C.dim, C.bg)
  elseif S.tab == "unassigned" and st and (st.unassignedCount or 0) > #rows and S.filter == "" then
    local note = ("router sent top %d of %d"):format(#rows, st.unassignedCount)
    put(W - len(note), INFO_ROW, note, C.dim, C.bg)
  end

  if S.tab == "items" then
    local c = confirming("clearAbsent")
    local xx = button(RX, ACTION_ROW, c and "TAP AGAIN TO CLEAR ABSENT" or "CLEAR ABSENT",
      { color = c and C.bad or C.btn, fg = c and C.bg or C.text,
        fn = function() askConfirm("clearAbsent", function()
          sendCmd({ cmd = "forgetAbsent" }); flash("clearing absent items ...", true) end) end })
    put(xx, ACTION_ROW, "forgets absent items without an override", C.dim, C.bg)
    if S.fetching then put(W - 12, ACTION_ROW, "refreshing…", C.dim, C.bg) end
  elseif S.tab == "rules" and not S.ruleEdit then
    local xx = button(RX, ACTION_ROW, "+ NEW RULE", { color = C.good, fg = C.bg,
      fn = function() editRule({ pattern = "", priority = 10, batch = 1 }) end })
    if S.rulesSource == "screen" then
      local c = confirming("resetRules")
      xx = button(xx, ACTION_ROW, c and "TAP AGAIN TO RESET" or "RESET TO prism.cfg",
        { color = c and C.bad or C.btn, fg = c and C.bg or C.text,
          fn = function() askConfirm("resetRules", function()
            sendCmd({ cmd = "resetRules" }); flash("resetting rules ...", true) end) end })
      put(xx, ACTION_ROW, "first match wins", C.dim, C.bg)
    else
      put(xx, ACTION_ROW, "from prism.cfg - editing saves prism-rules.cfg", C.dim, C.bg)
    end
  end
end

---------------------------------------------------------------- panels

local function processButtons(y0, current, set)
  local procs = {}
  for _, p in ipairs(S.status and S.status.knownProcesses or {}) do procs[#procs + 1] = p end
  procs[#procs + 1] = "ignore"
  local x, y = RX + 1, y0
  for _, p in ipairs(procs) do
    if x + len(p) + 2 > W then x, y = RX + 1, y + 1 end
    if y > y0 + 1 then break end
    x = button(x, y, p, { on = current == p, fn = function() set(p) end })
  end
end

local function batchButtons(y, current, set)
  put(RX + 1, y, "Batch", C.dim, C.panel)
  local x, listed = RX + 11, false
  for _, b in ipairs(BATCHES) do
    if b == current then listed = true end
    if x + len(tostring(b)) + 2 > W then break end
    x = button(x, y, tostring(b), { on = current == b, fn = function() set(b) end })
  end
  if not listed then put(x, y, " ×" .. current .. " ", C.text, C.btnOn) end
end

local function priorityButtons(y, current, set)
  put(RX + 1, y, "Priority", C.dim, C.panel)
  local x = RX + 11
  x = button(x, y, "-10", { fn = function() set(math.max(0, current - 10)) end })
  x = button(x, y, "-1",  { fn = function() set(math.max(0, current - 1)) end })
  put(x, y, rfit(current, 4) .. " ", C.accent, C.panel); x = x + 6
  x = button(x, y, "+1",  { fn = function() set(current + 1) end })
  button(x, y, "+10",     { fn = function() set(current + 10) end })
end

local function drawRulePanel()
  local r = S.ruleEdit
  local P = PANEL_TOP
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

  processButtons(P + 4, r.process, function(v) r.process = v end)
  batchButtons(P + 7, r.batch, function(v) r.batch = v end)
  priorityButtons(P + 9, r.priority, function(v) r.priority = v end)

  local nRules = S.rules and #S.rules or 0
  local x = RX + 1
  x = button(x, P + 11, "SAVE", { color = C.good, fg = C.bg,
    disabled = not r.process or r.pattern == "" or (p and p.error ~= nil), fn = saveRule })
  if r.index then
    local c = confirming("deleteRule")
    x = button(x, P + 11, c and "TAP AGAIN" or "DELETE", { color = C.bad, fg = C.bg,
      fn = function() askConfirm("deleteRule", function()
        sendCmd({ cmd = "deleteRule", index = r.index }); flash("deleting rule ...", true)
        S.ruleEdit, S.preview = nil, nil end) end })
    x = button(x, P + 11, "▲ UP", { disabled = r.index <= 1, fn = function()
      sendCmd({ cmd = "moveRule", index = r.index, dir = -1 }); r.index = r.index - 1 end })
    x = button(x, P + 11, "▼ DOWN", { disabled = r.index >= nRules, fn = function()
      sendCmd({ cmd = "moveRule", index = r.index, dir = 1 }); r.index = r.index + 1 end })
  end
  button(x, P + 11, "CANCEL", { fn = function() S.ruleEdit, S.preview = nil, nil end })
end

local function drawItemPanel()
  local P = PANEL_TOP
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
  local info = sel.key .. (sel.size and sel.size > 0 and ("   ×" .. fmtNum(sel.size)) or "")
                       .. (src and ("   (" .. src .. ")") or "")
  put(RX + 1, P + 2, fit(info, RW - 2), C.dim, C.panel)

  processButtons(P + 4, S.selProc, function(v) S.selProc = v end)
  batchButtons(P + 7, S.selBatch, function(v) S.selBatch = v end)
  priorityButtons(P + 9, S.selPrio, function(v) S.selPrio = v end)

  local x = RX + 1
  x = button(x, P + 11, "APPLY", { color = C.good, fg = C.bg, disabled = not S.selProc, fn = apply })
  if sel.source == "gui" then x = button(x, P + 11, "REMOVE OVERRIDE", { color = C.bad, fg = C.bg, fn = remove }) end
  if sel.list == "items" then x = button(x, P + 11, "FORGET", { color = C.bad, fg = C.bg, fn = forget }) end
  if sel.label then x = button(x, P + 11, "MAKE RULE", { fn = makeRule }) end
  button(x, P + 11, "CANCEL", { fn = function() S.sel = nil end })
end

local function drawFooter()
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
  local x = button(W - 24, H, "RELOAD CFG", {
    fn = function() sendCmd({ cmd = "reload" }); flash("reload sent ...", true) end })
  button(x, H, "QUIT", { color = C.bad, fg = C.bg, fn = function() S.running = false end })
end

local function drawAll()
  hits = {}
  drawHeader()
  fill(1, 2, LW + 1, H - 2, C.bg)
  local st = S.status
  local compact = st and leftRows(st, false) > H - 3
  local y = drawProcesses(3)
  y = drawBuses(y, compact)
  y = drawFeeders(y, compact)
  drawMachines(y)
  drawList()
  if S.ruleEdit then drawRulePanel() else drawItemPanel() end
  drawFooter()
end

---------------------------------------------------------------- messages

local function pushHistory(msg)
  if msg.cycles == S.lastCycle then return end
  S.lastCycle = msg.cycles
  S.alertTick = S.alertTick + 1
  local seen = {}
  for name, p in pairs(msg.processes or {}) do
    seen[name] = true
    local h = S.history[name] or {}
    h[#h + 1] = p.items or 0
    if #h > HISTORY then table.remove(h, 1) end
    S.history[name] = h
  end
  for name, h in pairs(S.history) do
    if not seen[name] then
      h[#h + 1] = 0
      if #h > HISTORY then table.remove(h, 1) end
    end
  end
end

local function checkAlerts(msg)
  local ids, fresh = {}, false
  for _, a in ipairs(msg.alerts or {}) do
    ids[a.id] = true
    if not S.alertIds[a.id] then fresh = true end
  end
  S.alertIds = ids
  if fresh and BEEP then pcall(computer.beep, 880, 0.15) end
end

-- Returns true when the screen needs a full redraw.
local function onMessage(from, port, data)
  if port ~= PORT or type(data) ~= "string" then return false end
  local msg = serialization.unserialize(data)
  if type(msg) ~= "table" then return false end

  if msg.type == "router-status" then
    S.router = from
    pushHistory(msg)
    checkAlerts(msg)
    S.status, S.statusAt = msg, computer.uptime()
    if S.tab == "items" and not S.fetching then fetchItems() end   -- keep quantities fresh
    return true
  elseif msg.type == "router-machines" then
    if not S.status then return false end
    local sameCount = #(msg.machines or {}) == #(S.status.machines or {})
    S.status.machines = msg.machines
    if sameCount and S.machY then redrawMachines(); return false end
    return true
  elseif msg.type == "router-items" then
    if msg.req ~= S.itemsReq or not S.itemsBuf then return false end
    for _, r in ipairs(msg.list or {}) do S.itemsBuf[#S.itemsBuf + 1] = r end
    if #S.itemsBuf < (msg.total or 0) and #(msg.list or {}) > 0 then
      sendCmd({ cmd = "items", offset = #S.itemsBuf, req = S.itemsReq })
      return false
    end
    S.items, S.itemsBuf, S.fetching = S.itemsBuf, nil, false
    return S.tab == "items"
  elseif msg.type == "router-overrides" then
    S.overrides = msg.list or {}
    return S.tab == "overrides"
  elseif msg.type == "router-rules" then
    S.rules, S.rulesSource = msg.list or {}, msg.source
    return S.tab == "rules"
  elseif msg.type == "router-preview" then
    if msg.req ~= S.previewReq or not S.ruleEdit then return false end
    S.preview = msg
    return true
  elseif msg.type == "router-ack" then
    flash(msg.text or "ok", msg.ok ~= false)
    refreshTab()
    return true
  end
  return false
end

local function onKey(char, code)
  local r = S.ruleEdit
  local text = r and r.pattern or S.filter
  if code == 14 then                                   -- backspace
    text = unicode.sub(text, 1, -2)
  elseif char and char >= 32 and char < 127 and len(text) < 60 then
    text = text .. string.char(char)
  else
    return false
  end
  if r then
    r.pattern = text
    requestPreview()
  else
    S.filter, S.scroll = text, 0
  end
  return true
end

---------------------------------------------------------------- main

local function main()
  if modem then modem.open(PORT) end
  fill(1, 1, W, H, C.bg)
  drawAll()
  sendCmd({ cmd = "status" })

  while S.running do
    local ev = table.pack(event.pullMultiple(1, "modem_message", "touch", "key_down", "interrupted"))
    local name, dirty = ev[1], false
    if name == "modem_message" then
      -- modem_message: localAddress, remoteAddress, port, distance, payload
      dirty = onMessage(ev[3], ev[4], ev[6])
    elseif name == "touch" then
      -- touch: screenAddress, x, y, button, player
      local tx, ty = math.floor(ev[3]), math.floor(ev[4])
      for i = #hits, 1, -1 do
        local h = hits[i]
        if tx >= h[1] and tx <= h[3] and ty >= h[2] and ty <= h[4] then h[5](); break end
      end
      dirty = true
    elseif name == "key_down" then
      -- key_down: keyboardAddress, char, code, player
      dirty = onKey(ev[3], ev[4])
    elseif name == "interrupted" then
      S.running = false
    end

    local now = computer.uptime()
    if S.msg and now - S.msgAt > 8 then S.msg = nil; dirty = true end
    if S.confirm and now - S.confirmAt > 5 then S.confirm = nil; dirty = true end
    if S.fetching and now - S.fetchAt > 10 then S.fetching = false; S.itemsBuf = nil end
    if not S.running then break end
    if dirty then drawAll() else drawHeader() end
  end
end

local ok, err = xpcall(main, debug.traceback)
if modem then modem.close(PORT) end
gpu.setBackground(0x000000)
gpu.setForeground(0xFFFFFF)
term.clear()
if not ok then io.stderr:write(tostring(err) .. "\n") end
