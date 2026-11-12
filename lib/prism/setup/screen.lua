--[[ prism.setup.screen: prism-setup's full-screen editor for the router's hardware (tier 2 screen or better).

  available() -> true | nil, why   a GPU and screen of at least 80x25 (touch works on tier 2 and up)
  run() -> "text" | nil            edit /home/prism.cfg; "text" when the user asked for the text wizard

  Tabs: BUSES, STOCKERS, INTERFACES, FEEDERS, MACHINES list every component found plus configured ones
  that weren't (flagged red). Tap one to pick its process, name it, or drop it. GENERAL: network,
  database, Capacity Cards, wireless, start on boot. SAVE shows the changes and warnings before writing
  (prism.cfg.bak keeps the old file). Keys: typing goes to the focused field (Enter done, Esc cancels);
  otherwise Up/Down pick a row and Left/Right switch tabs. The edits themselves live in prism.setup.editor.
]]

local component = require("component")
local event     = require("event")
local sides     = require("sides")
local term      = require("term")
local unicode   = require("unicode")
local Gui       = require("prism.gui")
local U         = require("prism.util")
local VERSION   = require("prism.version")
local files     = require("prism.files")
local probe     = require("prism.probe")
local Editor    = require("prism.setup.editor")
local paths     = require("prism.setup.paths")
local render    = require("prism.setup.render")
local autostart = require("prism.setup.autostart")
local save      = require("prism.setup.save")

local Screen = {}

local MIN_W, MIN_H = 80, 25
local KEY = { enter = 28, back = 14, esc = 1, up = 200, down = 208, left = 203, right = 205 }
local TABS = {
  { id = "buses",      title = "BUSES",      what = "Export bus" },
  { id = "stockers",   title = "STOCKERS",   what = "Stocking input bus" },
  { id = "interfaces", title = "INTERFACES", what = "ME interface (another network pulls from it)" },
  { id = "feeders",    title = "FEEDERS",    what = "Feeder through transposer" },
  { id = "machines",   title = "MACHINES",   what = "GT machine" },
  { id = "general",    title = "GENERAL" },
}

function Screen.available()
  if not (component.isAvailable("gpu") and component.isAvailable("screen")) then return nil, "no GPU and screen" end
  local w, h = component.gpu.maxResolution()
  if w < MIN_W or h < MIN_H then return nil, ("the screen is %dx%d; the editor needs %dx%d"):format(w, h, MIN_W, MIN_H) end
  return true
end

local function loadState()
  local old = files.loadLua(paths.ROUTER_CFG, { sides = sides }) or {}
  local rules = files.exists(paths.RULES_PATH) and files.readTable(paths.RULES_PATH) or nil
  return Editor.new(old, probe.snapshot(), rules)
end

function Screen.run()
  local W, H = component.gpu.maxResolution()
  local ui = Gui.new(component.gpu, W, H)
  local C = ui.C
  local LIST_TOP, LIST_BOTTOM, SEP, DETAIL = 4, H - 9, H - 8, H - 7
  local MSG_ROW, FOOT = H - 1, H

  local ed = loadState()
  local boot = autostart.read("prism")
  local S = {
    tab = "buses", sel = {}, scroll = {}, view = "edit", running = true,
    focus = nil,          -- { field, text, kind?, key?, x, y, w } while typing
    boot = boot.present,  -- start prism on boot
    msg = nil, msgOk = true, confirmQuit = false, result = nil,
  }

  -- Text from x to the right edge, cut to fit (hints after buttons and fields).
  local function say(x, y, text, fg, bg) if x < W then ui.put(x, y, Gui.fit(text, W - x), fg, bg) end end
  local function flash(text, ok) S.msg, S.msgOk = text, ok ~= false end
  local function shrc() return autostart.text("prism", S.boot) end
  local function dirty() return #ed.changes() > 0 or shrc() ~= nil end
  local function rows() return S.tab ~= "general" and ed.rows(S.tab) or {} end
  local function selected()
    for _, r in ipairs(rows()) do if r.key == S.sel[S.tab] then return r end end
  end

  ------------------------------------------------------------------ actions
  local function commitFocus()
    local f = S.focus
    if not f then return end
    S.focus = nil
    local text = U.trim(f.text)
    if f.field == "name" then
      ed.rename(f.kind, f.key, text)
    elseif f.field == "newproc" then
      if text ~= "" then
        local ok, why = ed.assign(f.kind, f.key, text)
        if not ok then flash(why, false) end
      end
    elseif f.field == "port" then
      local n = tonumber(text)
      if n and n == math.floor(n) and n >= 1 and n <= 65535 then ed.set("modemPort", math.floor(n))
      else flash("the port must be a number from 1 to 65535", false) end
    elseif f.field == "token" then
      ed.set("token", text ~= "" and text or nil)
    end
  end
  local function focus(field, text, extra)
    S.focus = { field = field, text = text or "" }
    for k, v in pairs(extra or {}) do S.focus[k] = v end
  end
  local function switchTab(id) S.tab = id end
  local function select(key) S.sel[S.tab] = key end

  local function moveSel(d)
    local list = rows()
    if #list == 0 then return end
    local at = 0
    for i, r in ipairs(list) do if r.key == S.sel[S.tab] then at = i end end
    at = math.max(1, math.min(#list, at + d))
    S.sel[S.tab] = list[at].key
    local scroll, height = S.scroll[S.tab] or 0, LIST_BOTTOM - LIST_TOP + 1
    if at <= scroll then scroll = at - 1 elseif at > scroll + height then scroll = at - height end
    S.scroll[S.tab] = scroll
  end
  local function scrollBy(d)
    local maxScroll = math.max(0, #rows() - (LIST_BOTTOM - LIST_TOP + 1))
    S.scroll[S.tab] = math.max(0, math.min(maxScroll, (S.scroll[S.tab] or 0) + d))
  end

  local function cycle(list, current, same)
    if #list == 0 then return current end
    for i, v in ipairs(list) do
      if (same and same(v, current)) or v == current then return list[i % #list + 1] end
    end
    return list[1]
  end

  local function doSave()
    local c = ed.result()
    local ok, why = save.commit(paths.ROUTER_CFG, render.router(c), shrc())
    if not ok then flash(why, false); S.view = "edit"; return end
    ed = loadState()
    boot = autostart.read("prism")
    S.boot = boot.present
    S.view = "saved"
  end

  local function quit()
    if dirty() and not S.confirmQuit then
      S.confirmQuit = true
      flash("Unsaved changes: tap QUIT again to throw them away", false)
      return
    end
    S.running = false
  end

  ------------------------------------------------------------------ drawing
  local function drawField(x, y, w, value, field, extra)
    local f = S.focus
    local active = f and f.field == field
    local shown = active and (f.text .. "_") or tostring(value or "")
    if active then f.x, f.y, f.w = x, y, w end
    -- Long text scrolls so the end (where you type) stays visible.
    if active and unicode.len(shown) > w then shown = unicode.sub(shown, -w) end
    ui.put(x, y, Gui.fit(shown, w), active and C.accent or C.text, C.field)
    ui.hit(x, y, x + w - 1, y, function() commitFocus(); focus(field, tostring(value or ""), extra) end)
    return x + w + 1
  end

  local function info(kind, r)
    local f, e = r.found, r.entry
    if not f then return "not found - still in prism.cfg", C.bad end
    if kind == "buses" or kind == "interfaces" then return "slot 1: " .. f.marker, C.dim end
    if kind == "stockers" then return "slot 1: " .. f.marker .. (f.advanced and ", advanced" or ""), C.dim end
    if kind == "machines" then
      return f.state .. f.where, f.state == "working" and C.good or (f.state == "disabled" and C.warn or C.dim)
    end
    if e then
      return ("from %s, %s -> %s"):format(tostring(e.interface):sub(1, 8), U.sideName(e.interfaceSide), U.sideName(e.machineSide)), C.dim
    end
    local names = {}
    for _, s in ipairs(f.inv) do names[#names + 1] = U.sideName(s.side) .. ": " .. s.name:gsub("^.*[:.]", "") end
    return #f.inv < 2 and "touches fewer than two inventories" or table.concat(names, ", "), C.dim
  end

  local function drawList()
    local kind = S.tab
    local list = rows()
    local bus = kind == "buses"
    local xProc = bus and 20 or 13
    local xName, xInfo = xProc + 13, xProc + 13 + 19
    ui.fill(1, 3, W, 1, C.bg)
    ui.put(4, 3, "ADDRESS", C.dim, C.bg)
    if bus then ui.put(13, 3, "SIDE", C.dim) end
    ui.put(xProc, 3, "PROCESS", C.dim)
    ui.put(xName, 3, "NAME", C.dim)
    ui.put(xInfo, 3, kind == "machines" and "STATE" or "", C.dim)
    local height = LIST_BOTTOM - LIST_TOP + 1
    local scroll = S.scroll[kind] or 0
    if #list > height then
      ui.button(W - 9, 3, "▲", { fn = function() scrollBy(-height + 1) end })
      ui.button(W - 4, 3, "▼", { fn = function() scrollBy(height - 1) end })
    end
    if #list == 0 then
      local hint = {
        buses = "No export buses found: put an adapter against the cable block your export buses are on.",
        stockers = "No stocking input buses found: put an adapter against each Stocking Input Bus (ME).",
        interfaces = "No ME interfaces found besides the network's and feeders'.",
        feeders = "No transposers found: a feeder is ME Interface block -> transposer -> machine.",
        machines = "No GT machines found: put an adapter against each machine to watch.",
      }
      ui.put(3, LIST_TOP + 1, Gui.fit(hint[kind], W - 4), C.dim, C.bg)
    end
    for i = 1, height do
      local r, y = list[scroll + i], LIST_TOP + i - 1
      if r then
        local sel = r.key == S.sel[kind]
        local bg = sel and C.sel or C.bg
        ui.fill(1, y, W, 1, bg)
        local e, f = r.entry, r.found
        local mark, mc = "·", C.dim
        if e and f then mark, mc = "●", C.good elseif e then mark, mc = "!", C.bad end
        ui.put(2, y, mark, mc, bg)
        local addr = f and f.addr or (kind == "feeders" and e.transposer or e.address)
        ui.put(4, y, Gui.fit(tostring(addr):sub(1, 8), 8), C.text)
        if bus then ui.put(13, y, Gui.fit(U.sideName(f and f.side or e.side), 6), C.text) end
        ui.put(xProc, y, Gui.fit(e and e.process or "not used", 12), e and C.info or C.dim)
        ui.put(xName, y, Gui.fit(e and e.name or "", 18), C.text)
        local text, color = info(kind, r)
        ui.put(xInfo, y, Gui.fit(text, W - xInfo), color)
        ui.hit(1, y, W, y, function() commitFocus(); select(r.key) end)
      else
        ui.fill(1, y, W, 1, C.bg)
      end
    end
  end

  local function drawDetail()
    local kind = S.tab
    local r = selected()
    local y = DETAIL
    if not r then
      ui.put(3, y, "Tap a row to choose what it's for.", C.dim, C.panel)
      return
    end
    local e, f = r.entry, r.found
    local tab
    for _, t in ipairs(TABS) do if t.id == kind then tab = t end end
    local addr = f and f.addr or (kind == "feeders" and e.transposer or e.address)
    local title = tab.what .. " " .. tostring(addr) .. ((kind == "buses") and (", " .. U.sideName(f and f.side or e.side) .. " side") or "")
    ui.put(3, y, Gui.fit(title, W - 4), C.accent, C.panel)

    if not f then
      ui.put(3, y + 1, Gui.fit("Not found: check its adapter and RESCAN, or drop it from prism.cfg.", W - 4), C.bad, C.panel)
      ui.button(3, y + 2, "DROP", { color = C.bad, fn = function() ed.drop(kind, r.key); S.sel[kind] = nil end })
      return
    end

    -- Process buttons, wrapping onto a second row.
    ui.put(3, y + 1, "Process", C.dim, C.panel)
    local x, py = 12, y + 1
    local function place(label)
      local w = Gui.len(label) + 3
      if x + w > W then
        if py == y + 2 then return nil end
        x, py = 12, y + 2
      end
      local at = x
      x = x + w
      return at
    end
    for _, p in ipairs(ed.processes()) do
      local at = place(p)
      if not at then break end
      ui.button(at, py, p, { on = e and e.process == p, fn = function()
        commitFocus()
        local ok, why = ed.assign(kind, r.key, p)
        if not ok then flash(why, false) end
      end })
    end
    local at = place("+ NEW")
    if at then ui.button(at, py, "+ NEW", { fn = function() commitFocus(); focus("newproc", "", { kind = kind, key = r.key }) end }) end
    at = place("NOT USED")
    if at then ui.button(at, py, "NOT USED", { on = not e, fn = function() commitFocus(); ed.drop(kind, r.key) end }) end

    if S.focus and S.focus.field == "newproc" then
      ui.put(3, y + 3, "New     ", C.dim, C.panel)
      local nx = drawField(12, y + 3, 20, "", "newproc", { kind = kind, key = r.key })
      say(nx, y + 3, "type a process name, Enter adds it, Esc cancels", C.dim, C.panel)
    elseif e then
      ui.put(3, y + 3, "Name    ", C.dim, C.panel)
      local nx = drawField(12, y + 3, 20, e.name or "", "name", { kind = kind, key = r.key })
      say(nx, y + 3, "shown on the control screen and in logs (optional)", C.dim, C.panel)
    end

    if kind == "feeders" and e then
      local ch = ed.feederChoices(r.key)
      local sideList = {}
      for _, s in ipairs(ch.sides) do sideList[#sideList + 1] = s.side end
      -- "west BlockInterface" on a wide screen, "west" on a tier 2 one.
      local function sideLabel(s)
        if W < 100 then return U.sideName(s) end
        for _, inv in ipairs(ch.sides) do
          if inv.side == s then return U.sideName(s) .. " " .. inv.name:gsub("^.*[:.]", "") end
        end
        return U.sideName(s)
      end
      local fx = 3
      ui.put(fx, y + 4, "From", C.dim, C.panel)
      fx = ui.button(12, y + 4, tostring(e.interface):sub(1, 8), { fn = function()
        ed.setFeeder(r.key, "interface", cycle(ch.interfaces, e.interface, function(a, b) return a:sub(1, #b) == b end))
      end })
      ui.put(fx, y + 4, "interface side", C.dim, C.panel)
      fx = ui.button(fx + 15, y + 4, sideLabel(e.interfaceSide), { fn = function()
        ed.setFeeder(r.key, "interfaceSide", cycle(sideList, e.interfaceSide))
      end })
      ui.put(fx, y + 4, "machine side", C.dim, C.panel)
      ui.button(fx + 13, y + 4, sideLabel(e.machineSide), { fn = function()
        ed.setFeeder(r.key, "machineSide", cycle(sideList, e.machineSide))
      end })
      say(3, y + 5, "Tap the interface or a side to change it (sides are relative to the transposer).", C.dim, C.panel)
    end
  end

  local function drawGeneral()
    local c = ed.c
    for y = 3, LIST_BOTTOM do ui.fill(1, y, W, 1, C.bg) end
    local y = LIST_TOP
    local function label(text) ui.put(3, y, text, C.dim, C.bg) end
    local function choices(list, current, setter, extra)
      local x = 20
      for _, a in ipairs(list) do
        x = ui.button(x, y, a:sub(1, 8), { on = a == current, fn = function() setter(a) end })
      end
      if extra then x = ui.button(x, y, extra, { on = current == nil, fn = function() setter(nil) end }) end
      return x
    end

    label("ME network")
    if #ed.snap.networks == 0 then say(20, y, "none found: put an adapter against the subnet's ME controller", C.bad, C.bg)
    else choices(ed.snap.networks, c.network, function(a) ed.set("network", a) end) end
    y = y + 2
    label("Database")
    if #ed.snap.databases == 0 then say(20, y, "none found: only buses, interfaces and feeders need one", C.warn, C.bg)
    else choices(ed.snap.databases, c.database, function(a) ed.set("database", a) end, "NONE") end
    y = y + 2
    label("Capacity Cards")
    local x = 20
    for _, n in ipairs({ { 0, 1 }, { 1, 5 }, { 2, 9 } }) do
      x = ui.button(x, y, tostring(n[1]), { on = (c.slotsPerBus or 9) == n[2], fn = function() ed.set("slotsPerBus", n[2]) end })
    end
    say(x, y, "per export bus", C.dim, C.bg)
    y = y + 2
    label("Wireless port")
    x = drawField(20, y, 8, c.modemPort or "", "port")
    ui.button(x, y, "OFF", { on = c.modemPort == false, fn = function()
      commitFocus(); ed.set("modemPort", c.modemPort == false and 4242 or false)
    end })
    y = y + 2
    label("Shared secret")
    x = drawField(20, y, 20, c.token or "", "token")
    say(x, y, "the control screen must send it; blank = none", C.dim, C.bg)
    y = y + 2
    label("Start on boot")
    x = ui.button(20, y, "ON", { on = S.boot, fn = function() S.boot = true end })
    x = ui.button(x, y, "OFF", { on = not S.boot, fn = function() S.boot = false end })
    if boot.other then say(x, y, "(prism-control is in .shrc; saving removes it)", C.warn, C.bg) end
    y = y + 2
    if y <= LIST_BOTTOM then
      ui.put(3, y, Gui.fit("Processes and rules: edit rules on the control screen's RULES tab, or use TEXT SETUP.", W - 4), C.dim, C.bg)
    end
  end

  local function drawGeneralDetail()
    local warnings = ed.warnings()
    ui.put(3, DETAIL, #warnings == 0 and "No warnings." or "Warnings", #warnings == 0 and C.good or C.warn, C.panel)
    for i = 1, math.min(#warnings, 5) do
      ui.put(3, DETAIL + i, Gui.fit(warnings[i], W - 4), C.warn, C.panel)
    end
  end

  local function drawFooter()
    ui.fill(1, MSG_ROW, W, 2, C.bg)
    if S.msg then ui.put(3, MSG_ROW, Gui.fit(S.msg, W - 4), S.msgOk and C.good or C.bad, C.bg) end
    local x = ui.button(2, FOOT, "SAVE", { color = dirty() and C.btnOn or C.btn, fn = function()
      commitFocus(); S.view = "review"
    end })
    x = ui.button(x, FOOT, "RESCAN", { fn = function()
      commitFocus(); ed.rescan(probe.snapshot()); flash("Rescanned the attached components.")
    end })
    x = ui.button(x, FOOT, "TEXT SETUP", { fn = function()
      if dirty() and not S.confirmQuit then
        S.confirmQuit = true
        flash("Unsaved changes: tap TEXT SETUP again to throw them away", false)
        return
      end
      S.result, S.running = "text", false
    end })
    ui.button(x, FOOT, "QUIT", { color = S.confirmQuit and C.bad or nil, fn = quit })
  end

  local function drawEdit()
    ui.fill(1, 1, W, 1, C.panel)
    ui.put(2, 1, "PRISM setup " .. VERSION, C.accent, C.panel)
    local px = 16 + Gui.len(VERSION)
    ui.put(px, 1, Gui.fit(paths.ROUTER_CFG, W - 18 - px), C.dim, C.panel)
    if dirty() then ui.put(W - 16, 1, "unsaved changes", C.warn, C.panel) end
    ui.fill(1, 2, W, 1, C.bg)
    local x = 2
    for _, t in ipairs(TABS) do
      local label = t.title
      if t.id ~= "general" then
        local used, found, missing = 0, 0, false
        for _, r in ipairs(ed.rows(t.id)) do
          if r.found then found = found + 1 end
          if r.entry then used = used + 1 end
          if r.entry and not r.found then missing = true end
        end
        -- "BUSES 2/3": 2 in use of 3 found; a tier 2 screen only has room for the 2.
        label = t.title .. " " .. used .. (W >= 100 and ("/" .. found) or "") .. (missing and "!" or "")
      end
      x = ui.button(x, 2, label, { on = S.tab == t.id, fn = function() commitFocus(); switchTab(t.id) end })
    end
    if S.tab == "general" then drawGeneral() else drawList() end
    ui.fill(1, SEP, W, 1, C.bg, "─")
    ui.fill(1, DETAIL, W, MSG_ROW - DETAIL, C.panel)
    if S.tab == "general" then drawGeneralDetail() else drawDetail() end
    drawFooter()
  end

  local function drawLines(y, lines, color, last)
    for i, l in ipairs(lines) do
      if y > last then break end
      if y == last and i < #lines then
        ui.put(5, y, ("… and %d more"):format(#lines - i + 1), C.dim, C.bg)
        return y + 1
      end
      local c = color
      if not c then
        local m = l:sub(1, 1)
        c = m == "+" and C.good or (m == "-" and C.bad or C.warn)
      end
      ui.put(5, y, Gui.fit(l, W - 6), c, C.bg)
      y = y + 1
    end
    return y
  end

  local function drawReview()
    ui.fill(1, 1, W, H, C.bg)
    ui.fill(1, 1, W, 1, C.panel)
    say(2, 1, "Save " .. paths.ROUTER_CFG .. "?  The current file is kept as prism.cfg.bak.", C.accent, C.panel)
    local changes, warnings = ed.changes(), ed.warnings()
    local s = shrc()
    if s then changes[#changes + 1] = S.boot and "+ start prism on boot (.shrc)" or "- don't start prism on boot (.shrc)" end
    local y = 3
    say(3, y, #changes == 0 and "Nothing changed (saving rewrites the file with every option)." or "Changes", C.text, C.bg)
    local half = #warnings > 0 and math.floor((H - 6) * 0.6) or H - 3
    y = drawLines(y + 1, changes, nil, 3 + half)
    if #warnings > 0 then
      y = y + 1
      ui.put(3, y, "Warnings", C.warn, C.bg)
      drawLines(y + 1, warnings, C.warn, H - 2)
    end
    local x = ui.button(2, FOOT, "SAVE", { color = C.btnOn, fn = doSave })
    ui.button(x, FOOT, "BACK", { fn = function() S.view = "edit" end })
  end

  local function drawSaved()
    ui.fill(1, 1, W, H, C.bg)
    ui.fill(1, 1, W, 1, C.panel)
    ui.put(2, 1, "Saved " .. paths.ROUTER_CFG, C.good, C.panel)
    ui.put(3, 3, "The old file is " .. paths.ROUTER_CFG .. ".bak.", C.text, C.bg)
    say(3, 4, "Start prism to use it, or press RELOAD CFG on the control screen if prism is running.", C.text, C.bg)
    local c = ed.c
    if c.modemPort then
      local secret = c.token and ("%q"):format(c.token) or "none"
      say(3, 6, ("Control screen settings: port %d, secret %s."):format(c.modemPort, secret), C.dim, C.bg)
    end
    local x = ui.button(2, FOOT, "QUIT", { fn = function() S.running = false end })
    ui.button(x, FOOT, "KEEP EDITING", { fn = function() S.view = "edit" end })
  end

  local function drawAll()
    ui.clearHits()
    if S.view == "review" then drawReview()
    elseif S.view == "saved" then drawSaved()
    else drawEdit() end
  end

  -- Only the focused field changes while typing, so only it is redrawn.
  local function redrawField()
    local f = S.focus
    if not (f and f.x) then return drawAll() end
    local shown = f.text .. "_"
    if unicode.len(shown) > f.w then shown = unicode.sub(shown, -f.w) end
    ui.put(f.x, f.y, Gui.fit(shown, f.w), C.accent, C.field)
  end

  ------------------------------------------------------------------ events
  local function onKey(char, code)
    local f = S.focus
    if f then
      if code == KEY.enter then commitFocus(); return "all" end
      if code == KEY.esc then S.focus = nil; return "all" end
      if code == KEY.back then f.text = unicode.sub(f.text, 1, -2); return "field" end
      if char and char >= 32 and char < 127 and unicode.len(f.text) < 40 then
        f.text = f.text .. string.char(char)
        return "field"
      end
      return nil
    end
    if S.view ~= "edit" then return nil end
    if code == KEY.up then moveSel(-1); return "all" end
    if code == KEY.down then moveSel(1); return "all" end
    if code == KEY.left or code == KEY.right then
      local at = 1
      for i, t in ipairs(TABS) do if t.id == S.tab then at = i end end
      at = (at - 1 + (code == KEY.left and -1 or 1)) % #TABS + 1
      switchTab(TABS[at].id)
      return "all"
    end
    return nil
  end

  local function main()
    ui.fill(1, 1, W, H, C.bg)
    drawAll()
    while S.running do
      local ev = table.pack(event.pullMultiple(60, "touch", "key_down", "scroll", "interrupted"))
      local name, redraw = ev[1], nil
      if name == "touch" then
        -- touch: screenAddress, x, y, button, player
        local wasConfirming = S.confirmQuit
        S.msg = nil
        if not ui.tap(math.floor(ev[3]), math.floor(ev[4])) then commitFocus() end
        if wasConfirming and S.confirmQuit and S.running then S.confirmQuit = false; S.msg = nil end
        redraw = "all"
      elseif name == "scroll" then
        -- scroll: screenAddress, x, y, direction (1 = up)
        if S.view == "edit" and S.tab ~= "general" then scrollBy(-(ev[5] or 0)); redraw = "all" end
      elseif name == "key_down" then
        -- key_down: keyboardAddress, char, code, player
        redraw = onKey(ev[3], ev[4])
      elseif name == "interrupted" then
        S.running = false
      end
      if not S.running then break end
      if redraw == "field" then redrawField() elseif redraw then drawAll() end
    end
  end

  local ok, err = xpcall(main, debug.traceback)
  ui.restore()
  term.clear()
  if not ok then error(err, 0) end
  return S.result
end

return Screen
