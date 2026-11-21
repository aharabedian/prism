-- test_rule_ideas.lua: UNASSIGNED groups items whose names differ in one word under the rule that would catch
-- them, with MAKE RULE opening the rule editor with it (and asking for its preview); the rest go under
-- "no rule idea for these".
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check
local ser = M.serialization

local RX = math.floor(M.W * 0.56) + 3
local function msg(t) return { "modem_message", "x", "router-addr", 4242, 4, ser.serialize(t) } end
local function lastSent() return ser.unserialize(M.sent[#M.sent].data) end
local function u(n, label, size) return { key = "gregtech:gt.metaitem.01:" .. n, label = label, size = size } end
local status = { type = "router-status", cycles = 1, interval = 5, processes = {}, buses = {}, feeders = {}, machines = {},
  unassigned = { u(1, "Purified Pile of Iron Dust", 212), u(2, "Nether Quartz", 64), u(3, "Purified Pile of Copper Dust", 140),
    u(4, "Tiny Pile of Gold Dust", 31), u(5, "Purified Pile of Tin Dust", 60), u(6, "Tiny Pile of Silver Dust", 22), u(7, "Flint", 12) },
  unassignedCount = 7, catalogCount = 7, knownProcesses = { "centrifuge", "crush" }, alerts = {} }
local seen = {}
local steps = {
  function() return msg(status) end,
  function()
    H.screen("rule-ideas")
    local _, gy = M.find("▾ ^Purified Pile of .+ Dust$", 5, RX)
    seen.group = gy and M.row(gy):find("catches 3 here", 1, true) and M.row(gy):find(" MAKE RULE ", 1, true)
    seen.order = gy and M.row(gy + 1):find("Purified Pile of Iron Dust", 1, true) and M.row(gy + 3):find("Purified Pile of Tin Dust", 1, true)
      and M.row(gy + 4):find("▾ ^Tiny Pile of .+ Dust$", 1, true)
    local _, ry = M.find("▾ no rule idea for these", 5, RX)
    seen.rest = ry and M.row(ry + 1):find("Nether Quartz", 1, true) and M.row(ry + 2):find("Flint", 1, true)
    local x, y = M.find(" MAKE RULE ", gy, RX)
    return { "touch", "screen", x + 2, y, 0, "Aaron" }
  end,
  function()
    local c = lastSent()
    seen.preview = c.cmd == "previewRule" and c.pattern == "^Purified Pile of .+ Dust$"
    seen.editor = M.find("NEW RULE", M.H - 14, RX) ~= nil and M.find("^Purified Pile of .+ Dust$_", M.H - 14, RX) ~= nil
    return { "touch", "screen", M.W - 3, M.H, 0, "Aaron" }
  end,
}
local n = 0
M.onPull = function()
  n = n + 1
  local f = steps[n]
  if f then return f() end
  return { "interrupted" }
end
H.run("prism-control.lua")
check(seen.group, "a rule idea heads its group, with how many it catches and MAKE RULE")
check(seen.order, "its items under it, then the next idea")
check(seen.rest, "items with no idea go under 'no rule idea for these'")
check(seen.editor and seen.preview, "MAKE RULE opens the rule editor with the pattern and asks for its preview")

H.done()
