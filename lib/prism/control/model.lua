--[[ prism.control.model: the control screen's state, the actions buttons trigger, and the
  router's messages. Knows nothing about drawing: views read m.S and call actions.

  Model.new(settings, modem) -> m
  m.S                       the state (fields below); m.settings: prism-control.cfg
  m.onMessage(from, port, data) -> "full" | "machines" | false   what needs redrawing
  m.onKey(char, code) -> redraw?
  m.tick(now) -> redraw?    expire flash messages, confirmations and stuck fetches
  m.start()                 ask the router for status
  actions: switchTab, selectRow, editRule, newRule, makeRule, saveRule, deleteRule, moveRule,
           cancelRule, cancelSelection, apply, removeOverride, forget, forgetAbsent, resetRules,
           reloadRouter, pickProcess, pickFallback, pickBatch, pickPriority, setScroll, clearFilter, quit,
           selectProcess, cancelProcess, setAlwaysShare(on),
           askConfirm(what, fn), confirming(what)

  S.status      latest router-status (S.statusAt: when it arrived; S.router: its address)
  S.history     { [process] = backlog samples } for the sparklines
  S.items / S.overrides / S.rules (+ S.rulesSource)   lists fetched for their tabs
  S.tab         "unassigned" | "items" | "overrides" | "rules";  S.scroll, S.filter
  S.sel         the item being routed: { key, label, size, list, source, process },
                with the choices S.selProc, S.selFallback, S.selPrio, S.selBatch
  S.ruleEdit    the rule being edited: { index?, pattern, process, fallback?, priority, batch }; S.preview
  S.procSel     the process tapped in the PROCESSES list (its panel: overflow, ALWAYS SHARE)
  S.msg/msgOk   the flash message in the footer; S.confirm: an action waiting for a second tap
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
    tab = "unassigned", scroll = 0, filter = "",
    sel = nil, selProc = nil, selFallback = nil, selPrio = 10, selBatch = 1, procSel = nil,
    msg = nil, msgOk = true, msgAt = 0,
    confirm = nil, confirmAt = 0,
  }
  local m = { S = S, settings = settings, modem = modem, port = PORT }

  ---------------------------------------------------------------- talking to the router

  function m.flash(text, ok) S.msg, S.msgOk, S.msgAt = text, ok, computer.uptime() end

  function m.send(t)
    if not modem then m.flash("no network card in this computer", false); return end
    t.token = TOKEN
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

  local function refreshTab()
    if S.tab == "items" then fetchItems()
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
  function m.pickPriority(v) if S.ruleEdit then S.ruleEdit.priority = v else S.selPrio = v end end

  ---------------------------------------------------------------- processes

  function m.selectProcess(name)
    S.sel, S.ruleEdit, S.preview = nil, nil, nil
    S.procSel = name
  end

  function m.cancelProcess() S.procSel = nil end

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
      S.status, S.statusAt = msg, computer.uptime()
      if S.tab == "items" and not S.fetching then fetchItems() end   -- keep quantities fresh
      return "full"
    elseif msg.type == "router-machines" then
      if not S.status then return false end
      local sameCount = #(msg.machines or {}) == #(S.status.machines or {})
      S.status.machines = msg.machines
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
      return S.tab == "overrides" and "full"
    elseif msg.type == "router-rules" then
      S.rules, S.rulesSource = msg.list or {}, msg.source
      return S.tab == "rules" and "full"
    elseif msg.type == "router-preview" then
      if msg.req ~= S.previewReq or not S.ruleEdit then return false end
      S.preview = msg
      return "full"
    elseif msg.type == "router-ack" then
      m.flash(msg.text or "ok", msg.ok ~= false)
      refreshTab()
      return "full"
    end
    return false
  end

  -- Typing edits the rule pattern while editing a rule, else the search filter.
  function m.onKey(char, code)
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
