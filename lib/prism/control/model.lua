--[[ prism.control.model: the control screen's state, the actions buttons trigger, and the
  router's messages. Knows nothing about drawing: views read m.S and call actions.

  Model.new(settings, modem) -> m
  m.S                       the state (fields below); m.settings: prism-control.cfg
  m.onMessage(from, port, data) -> "full" | "machines" | false   what needs redrawing
  m.onKey(char, code) -> redraw?
  m.tick(now) -> redraw?    expire flash messages, confirmations and stuck fetches
  m.start()                 ask the router for status
  actions: switchTab, selectRow, editRule, newRule, makeRule, makeRuleFrom(pattern), saveRule, deleteRule, moveRule,
           cancelRule, cancelSelection, apply, removeOverride, forget, forgetAbsent, resetRules,
           reloadRouter, pickProcess, pickFallback, pickBatch, editBatch, blur, pickPriority, setScroll,
           clearFilter, quit,
           selectProcess, cancelProcess, setHold(on), setAlwaysShare(on), editOverflow, setItemSort(how),
           toggleBelowBatch, toggleGroup(process), setLogFilter(filter),
           askConfirm(what, fn), confirming(what)

  S.status      latest router-status (S.statusAt: when it arrived; S.router: its address)
  S.history     { [process] = backlog samples } for the sparklines
  S.items / S.overrides / S.rules (+ S.rulesSource)   lists fetched for their tabs
  S.tab         "unassigned" | "items" | "overrides" | "rules" | "log";  S.scroll, S.filter
  S.log         the router's event log { list (newest first), now, real, at }: fetched in pages (router-log) when
                LOG opens and when router-status's `events` count changes; S.logFilter nil | "alerts" | "changes"
  S.itemSort    how ITEMS is ordered: "process" (grouped, S.collapsed[process] = true hides a group),
                "name" or "qty"; S.belowBatch: ITEMS lists only items with less than one batch
  S.sel         the item being routed: { key, label, size, list, source, process },
                with the choices S.selProc, S.selFallback, S.selPrio, S.selBatch
  S.explain     the router's line on what S.sel is doing now: { key, text, level } (router-explain); asked
                again with every status while an item is selected
  S.ruleEdit    the rule being edited: { index?, pattern, process, fallback?, priority, batch }; S.preview
  S.batchEdit   the digits typed into the Batch field while it has focus (nil: not focused)
  S.overflowEdit  the digits typed into the process page's overflow field (nil: not focused)
  S.procSel     the process tapped in the PROCESSES list: its page (prism.control.process_view) replaces the
                list and panel. S.queue: its queue in rank order (router-queue), asked again with every status
  S.machineCells  { [machine] = { [cell] = { w, n, down, wait } } }: machine states seen per 160 s cell (the
                last 45), for the process page's bands
  S.msg/msgOk   the flash message in the footer (S.msgWarn: in yellow, for news like a new item);
                S.confirm: an action waiting for a second tap
  S.player      the player who last touched the screen, sent with every command
]]

local computer      = require("computer")
local serialization = require("serialization")
local unicode       = require("unicode")
local protocol      = require("prism.protocol")

local Model = {}

local function escapePattern(s) return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")) end

function Model.new(settings, modem)
  local PORT, TOKEN, HISTORY, BEEP = settings.modemPort, settings.token, settings.history, settings.beep
  if not PORT then modem = nil end

  local S = {
    running = true,
    status = nil, statusAt = nil, lastCycle = nil, router = nil,
    history = {}, alertIds = {}, alertTick = 0,
    overrides = nil,
    items = nil, itemsBuf = nil, itemsReq = 0, fetching = false, fetchAt = 0,
    rules = nil, rulesSource = nil,
    ruleEdit = nil, preview = nil, previewReq = 0,
    explain = nil, explainReq = 0, queue = nil, queueReq = 0, machineCells = {},
    tab = "unassigned", scroll = 0, filter = "", itemSort = "process", collapsed = {},
    sel = nil, selProc = nil, selFallback = nil, selPrio = 10, selBatch = 1, procSel = nil, batchEdit = nil,
    msg = nil, msgOk = true, msgAt = 0,
    confirm = nil, confirmAt = 0,
  }
  local m = { S = S, settings = settings, modem = modem, port = PORT }

  ---------------------------------------------------------------- talking to the router

  function m.flash(text, ok, warn) S.msg, S.msgOk, S.msgWarn, S.msgAt = text, ok, warn, computer.uptime() end

  function m.send(t)
    if not modem then m.flash("no network card in this computer", false); return end
    t.token = TOKEN
    if t.player == nil then t.player = S.player end   -- who tapped: the router logs it with changes
    local data = serialization.serialize(t)
    if S.router then modem.send(S.router, PORT, data) else modem.broadcast(PORT, data) end
  end

  local function fetchItems()
    S.itemsReq = S.itemsReq + 1
    S.itemsBuf, S.fetching, S.fetchAt = {}, true, computer.uptime()
    m.send({ cmd = "items", offset = 0, req = S.itemsReq })
  end

  local function requestPreview()
    local r = S.ruleEdit
    if not r then return end
    if r.pattern == "" then S.preview = nil; return end
    S.previewReq = S.previewReq + 1
    m.send({ cmd = "previewRule", pattern = r.pattern, index = r.index, process = r.process, req = S.previewReq })
  end

  local function askExplain()
    if not S.sel then return end
    S.explainReq = S.explainReq + 1
    m.send({ cmd = "explain", key = S.sel.key, req = S.explainReq })
  end

  local function askQueue()
    if not S.procSel then return end
    S.queueReq = S.queueReq + 1
    m.send({ cmd = "queue", process = S.procSel, req = S.queueReq })
  end

  -- One count per machine reading in the current cell: working, down (no power, maintenance, disabled,
  -- offline), idle with work waiting.
  local CELL, CELLS = 160, 45
  local DOWN = { ["no power"] = true, maintenance = true, disabled = true, offline = true }
  local function recordMachines(list)
    local cur = math.floor(computer.uptime() / CELL)
    for _, mc in ipairs(list or {}) do
      local cells = S.machineCells[mc.name] or {}
      S.machineCells[mc.name] = cells
      local c = cells[cur] or { w = 0, n = 0, down = 0, wait = 0 }
      cells[cur] = c
      c.n = c.n + 1
      if mc.state == "working" then c.w = c.w + 1
      elseif DOWN[mc.state] then c.down = c.down + 1
      elseif mc.idle then c.wait = c.wait + 1 end
      for k in pairs(cells) do if k <= cur - CELLS then cells[k] = nil end end
    end
  end

  local function fetchLog()
    S.logReq = (S.logReq or 0) + 1
    S.logBuf = {}
    m.send({ cmd = "log", offset = 0, filter = S.logFilter, req = S.logReq })
  end

  local function refreshTab()
    if S.tab == "items" then fetchItems()
    elseif S.tab == "log" then fetchLog()
    elseif S.tab == "overrides" then m.send({ cmd = "overrides" })
    elseif S.tab == "rules" then
      m.send({ cmd = "rules" })
      requestPreview()
    end
  end

  function m.start() m.send({ cmd = "status" }) end

  ---------------------------------------------------------------- confirmations

  function m.confirming(what) return S.confirm == what and computer.uptime() - S.confirmAt <= 5 end

  function m.askConfirm(what, fn)
    if m.confirming(what) then
      S.confirm = nil
      fn()
    else
      S.confirm, S.confirmAt = what, computer.uptime()
    end
  end

  ---------------------------------------------------------------- navigation

  function m.switchTab(tab)
    if tab ~= "rules" then S.ruleEdit, S.preview = nil, nil end
    S.tab, S.scroll = tab, 0
    refreshTab()
  end

  function m.setItemSort(how) S.itemSort, S.scroll = how, 0 end
  function m.setLogFilter(f) S.logFilter, S.scroll = f, 0; fetchLog() end
  function m.toggleBelowBatch() S.belowBatch, S.scroll = not S.belowBatch, 0 end
  function m.toggleGroup(process) S.collapsed[process] = not S.collapsed[process] or nil end

  function m.setScroll(n) S.scroll = math.max(0, n) end
  function m.clearFilter() S.filter, S.scroll = "", 0 end
  function m.quit() S.running = false end

  ---------------------------------------------------------------- routing an item

  function m.selectRow(row, list)
    S.procSel = nil
    S.sel = { key = row.key, label = row.label, size = row.size, list = list,
              source = row.source, process = row.process }
    S.selProc  = row.process
    S.selFallback = row.fallback
    S.selPrio  = row.priority or 10
    S.selBatch = row.batch or 1
    S.explain = nil
    askExplain()
  end

  function m.cancelSelection() S.sel = nil end

  function m.apply()
    local sel = S.sel
    if not (sel and S.selProc) then return end
    m.send({ cmd = "assign", key = sel.key, process = S.selProc, priority = S.selPrio,
             batch = S.selBatch, fallback = S.selFallback, label = sel.label })
    m.flash(("sending %s -> %s ..."):format(sel.label or sel.key, S.selProc), true)
    S.sel = nil
  end

  function m.removeOverride()
    if not S.sel then return end
    m.send({ cmd = "unassign", key = S.sel.key })
    m.flash(("removing override for %s ..."):format(S.sel.label or S.sel.key), true)
    S.sel = nil
  end

  function m.forget()
    if not S.sel then return end
    m.send({ cmd = "forget", key = S.sel.key })
    m.flash(("forgetting %s ..."):format(S.sel.label or S.sel.key), true)
    S.sel = nil
  end

  function m.forgetAbsent()
    m.send({ cmd = "forgetAbsent" })
    m.flash("clearing absent items ...", true)
  end

  -- Process, fallback, batch and priority buttons edit the rule being edited, else the item being routed.
  -- A fallback equal to the new process is dropped. pickFallback(nil): no fallback.
  function m.pickProcess(v)
    local t = S.ruleEdit
    if t then t.process = v; if t.fallback == v then t.fallback = nil end
    else S.selProc = v; if S.selFallback == v then S.selFallback = nil end end
  end
  function m.pickFallback(v) if S.ruleEdit then S.ruleEdit.fallback = v else S.selFallback = v end end
  function m.pickBatch(v) if S.ruleEdit then S.ruleEdit.batch = v else S.selBatch = v end end
  -- The Batch field: editBatch() focuses it (typing then replaces the batch), blur() drops focus (any tap).
  function m.editBatch() S.batchEdit = "" end

  -- The process page's overflow field: editOverflow() focuses it; Enter sends what was typed (empty: back to
  -- prism.cfg's); a tap elsewhere sends it if something was typed.
  local function sendOverflow()
    local t = S.overflowEdit
    S.overflowEdit = nil
    if not S.procSel or t == nil then return end
    m.send({ cmd = "setOverflow", process = S.procSel, overflow = tonumber(t), player = S.player })
    m.flash(("%s: overflow %s ..."):format(S.procSel, t ~= "" and t or "back to prism.cfg"), true)
  end
  function m.editOverflow() S.overflowEdit = "" end
  function m.blur()
    S.batchEdit = nil
    if S.overflowEdit and S.overflowEdit ~= "" then sendOverflow() else S.overflowEdit = nil end
  end
  function m.pickPriority(v) if S.ruleEdit then S.ruleEdit.priority = v else S.selPrio = v end end

  ---------------------------------------------------------------- processes

  function m.selectProcess(name)
    S.sel, S.ruleEdit, S.preview = nil, nil, nil
    S.procSel, S.queue = name, nil
    askQueue()
  end

  function m.cancelProcess() S.procSel, S.queue, S.overflowEdit = nil, nil, nil end

  function m.setHold(on)
    if not S.procSel then return end
    m.send({ cmd = "hold", process = S.procSel, on = on, player = S.player })
    m.flash((on and "%s: holding ..." or "%s: resuming ..."):format(S.procSel), true)
  end

  function m.setAlwaysShare(on)
    if not S.procSel then return end
    m.send({ cmd = "alwaysShare", process = S.procSel, on = on })
    m.flash((on and "%s: always sharing ..." or "%s: sharing on overflow ..."):format(S.procSel), true)
  end

  ---------------------------------------------------------------- rules

  function m.editRule(rule)
    S.sel, S.procSel = nil, nil
    S.ruleEdit = { index = rule.index, pattern = rule.pattern or "", process = rule.process,
                   fallback = rule.fallback, priority = rule.priority or 10, batch = rule.batch or 1 }
    S.preview, S.scroll = nil, 0
    requestPreview()
  end

  function m.newRule() m.editRule({ pattern = "", priority = 10, batch = 1 }) end

  -- The rule editor with a pattern filled in (UNASSIGNED's rule ideas); its preview shows what it catches.
  function m.makeRuleFrom(pattern)
    S.tab, S.scroll = "rules", 0
    m.send({ cmd = "rules" })
    m.editRule({ pattern = pattern, priority = 10, batch = 1 })
  end

  -- A rule matching the selected item's exact name, with its current choices.
  function m.makeRule()
    local sel = S.sel
    if not sel then return end
    local rule = { pattern = "^" .. escapePattern(sel.label or "") .. "$", process = S.selProc,
                   fallback = S.selFallback, priority = S.selPrio, batch = S.selBatch }
    S.tab, S.scroll = "rules", 0
    m.send({ cmd = "rules" })
    m.editRule(rule)
  end

  function m.saveRule()
    local r = S.ruleEdit
    if not (r and r.process and r.pattern ~= "") then return end
    m.send({ cmd = "setRule", index = r.index, pattern = r.pattern, process = r.process,
             fallback = r.fallback, priority = r.priority, batch = r.batch })
    m.flash("saving rule ...", true)
    S.ruleEdit, S.preview = nil, nil
  end

  function m.deleteRule()
    m.send({ cmd = "deleteRule", index = S.ruleEdit.index })
    m.flash("deleting rule ...", true)
    S.ruleEdit, S.preview = nil, nil
  end

  function m.moveRule(dir)
    local r = S.ruleEdit
    m.send({ cmd = "moveRule", index = r.index, dir = dir })
    r.index = r.index + dir
  end

  function m.cancelRule() S.ruleEdit, S.preview = nil, nil end

  function m.resetRules()
    m.send({ cmd = "resetRules" })
    m.flash("resetting rules ...", true)
  end

  function m.reloadRouter()
    m.send({ cmd = "reload" })
    m.flash("reload sent ...", true)
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

  -- An item that just appeared with no rule for it: say so in the footer, with one beep. Not for the first status.
  local function checkNewItems(msg)
    local keys, fresh = {}, nil
    for _, u in ipairs(msg.unassigned or {}) do
      keys[u.key] = true
      local recent = u.seen and msg.now and msg.now - u.seen < 600
      if S.unassignedKeys and not S.unassignedKeys[u.key] and recent and not fresh then fresh = u end
    end
    S.unassignedKeys = keys
    if fresh then
      m.flash(("New item: %s - no rule routes it (UNASSIGNED)"):format(fresh.label or fresh.key), true, true)
      if BEEP then pcall(computer.beep, 660, 0.15) end
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

  function m.onMessage(from, port, data)
    if port ~= PORT then return false end
    local msg = protocol.decode(data)
    if not msg then return false end

    if msg.type == "router-status" then
      S.router = from
      pushHistory(msg)
      checkAlerts(msg)
      checkNewItems(msg)
      S.status, S.statusAt = msg, computer.uptime()
      if S.tab == "items" and not S.fetching then fetchItems() end   -- keep quantities fresh
      if S.tab == "log" and msg.events ~= S.logEvents then fetchLog() end
      S.logEvents = msg.events
      askExplain()
      askQueue()
      recordMachines(msg.machines)
      return "full"
    elseif msg.type == "router-machines" then
      if not S.status then return false end
      local sameCount = #(msg.machines or {}) == #(S.status.machines or {})
      S.status.machines = msg.machines
      recordMachines(msg.machines)
      return sameCount and "machines" or "full"
    elseif msg.type == "router-items" then
      if msg.req ~= S.itemsReq or not S.itemsBuf then return false end
      for _, r in ipairs(msg.list or {}) do S.itemsBuf[#S.itemsBuf + 1] = r end
      if #S.itemsBuf < (msg.total or 0) and #(msg.list or {}) > 0 then
        m.send({ cmd = "items", offset = #S.itemsBuf, req = S.itemsReq })
        return false
      end
      S.items, S.itemsBuf, S.fetching = S.itemsBuf, nil, false
      return S.tab == "items" and "full"
    elseif msg.type == "router-overrides" then
      S.overrides = msg.list or {}
      S.overridesNow, S.overridesAt = msg.now, msg.now and computer.uptime() or nil
      return S.tab == "overrides" and "full"
    elseif msg.type == "router-rules" then
      S.rules, S.rulesSource = msg.list or {}, msg.source
      return S.tab == "rules" and "full"
    elseif msg.type == "router-preview" then
      if msg.req ~= S.previewReq or not S.ruleEdit then return false end
      S.preview = msg
      return "full"
    elseif msg.type == "router-log" then
      if msg.req ~= S.logReq or not S.logBuf then return false end
      for _, r in ipairs(msg.list or {}) do S.logBuf[#S.logBuf + 1] = r end
      if #S.logBuf < (msg.total or 0) and #(msg.list or {}) > 0 then
        m.send({ cmd = "log", offset = #S.logBuf, filter = S.logFilter, req = S.logReq })
        return false
      end
      S.log = { list = S.logBuf, now = msg.now or 0, real = msg.real, at = computer.uptime() }
      S.logBuf = nil
      return S.tab == "log" and "full"
    elseif msg.type == "router-queue" then
      if msg.req ~= S.queueReq or msg.process ~= S.procSel then return false end
      S.queue = msg
      return "full"
    elseif msg.type == "router-explain" then
      if msg.req ~= S.explainReq or not S.sel or msg.key ~= S.sel.key then return false end
      S.explain = { key = msg.key, text = msg.text, level = msg.level }
      return "full"
    elseif msg.type == "router-ack" then
      m.flash(msg.text or "ok", msg.ok ~= false)
      refreshTab()
      return "full"
    end
    return false
  end

  -- Digits typed into the focused Batch field set the batch; Enter (or any other key) leaves the field.
  local function batchKey(char, code)
    local t = S.batchEdit
    if code == 14 then t = t:sub(1, -2)
    elseif char and char >= 48 and char <= 57 then
      if #t >= 4 or (t == "" and char == 48) then return true end
      t = t .. string.char(char)
    else
      S.batchEdit = nil
      return code == 28                                 -- Enter just leaves; other keys go on to the text
    end
    S.batchEdit = t
    if t ~= "" then m.pickBatch(tonumber(t)) end
    return true
  end

  local function overflowKey(char, code)
    local t = S.overflowEdit
    if code == 14 then S.overflowEdit = t:sub(1, -2); return true end
    if code == 28 then sendOverflow(); return true end
    if char and char >= 48 and char <= 57 then
      if #t < 7 then S.overflowEdit = t .. string.char(char) end
      return true
    end
    S.overflowEdit = nil
    return true
  end

  -- Typing edits the Batch or overflow field while it has focus, else the rule pattern while editing a rule,
  -- else the search filter.
  function m.onKey(char, code)
    if S.overflowEdit then return overflowKey(char, code) end
    if S.batchEdit and batchKey(char, code) then return true end
    local r = S.ruleEdit
    local text = r and r.pattern or S.filter
    if code == 14 then                                   -- backspace
      text = unicode.sub(text, 1, -2)
    elseif char and char >= 32 and char < 127 and unicode.len(text) < 60 then
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

  function m.tick(now)
    local dirty = false
    if S.msg and now - S.msgAt > 8 then S.msg = nil; dirty = true end
    if S.confirm and now - S.confirmAt > 5 then S.confirm = nil; dirty = true end
    if S.fetching and now - S.fetchAt > 10 then S.fetching = false; S.itemsBuf = nil end
    return dirty
  end

  return m
end

return Model
