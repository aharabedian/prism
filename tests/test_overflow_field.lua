-- test_overflow_field.lua: the overflow mark set on the screen. setOverflow saves it in prism-processes.cfg, where
-- it wins over prism.cfg's (status says which), sharing follows it, and an empty one goes back to prism.cfg's.
-- The screen: the process page's field, typed and saved with Enter, or cleared.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check
local ser = M.serialization

local GT = "gregtech:gt.metaitem.01"
M.items = { { name = GT, damage = 5002, label = "Crushed Nickel Ore", size = 600 }, { name = GT, damage = 5001, label = "Crushed Platinum Ore", size = 900 } }
M.stocker("st111111-1111")
M.stocker("st222222-2222")
local cfg = H.config("of", [[
return { modemPort = 4242,
  stockers = { { address = "st11", process = "chembath", name = "Bath" }, { address = "st22", process = "wash", name = "Washer" } },
  processes = { chembath = { overflow = 10000 } },
  rules = { { pattern = "^Crushed Platinum Ore$", process = "chembath" },
            { pattern = "^Crushed .+ Ore$", process = "chembath", fallback = "wash" } } }
]])
local function cmd(t) return { "modem_message", "x", "gui", 4242, 2, ser.serialize(t) } end
local function lastOf(kind)
  for i = #M.sent, 1, -1 do
    local m = ser.unserialize(M.sent[i].data)
    if m.type == kind then return m end
  end
end
local cp = {}
M.onPull = function(n)
  if n == 1 then cp[1] = lastOf("router-status"); return cmd({ cmd = "setOverflow", process = "chembath", overflow = 1000 }) end
  if n == 2 then cp[2] = { status = lastOf("router-status"), ack = lastOf("router-ack") }; return cmd({ cmd = "setOverflow", process = "chembath" }) end
  if n == 3 then cp[3] = lastOf("router-status"); return { "interrupted" } end
end
H.run("prism.lua", cfg)
local c1, c2, c3 = cp[1].processes.chembath, cp[2].status.processes.chembath, cp[3].processes.chembath
check(c1.overflow == 10000 and c1.overflowFrom == "cfg" and not c1.spilled, "at first: prism.cfg's mark, nothing shared")
check(cp[2].ack.ok and c2.overflow == 1000 and c2.overflowFrom == "screen" and c2.spilled == 600,
  "setOverflow 1000: it wins, and the nickel is shared with wash")
check(c3.overflow == 10000 and c3.overflowFrom == "cfg", "an empty mark goes back to prism.cfg's")
check(next(H.readTable(H.TMP .. "/of-processes.cfg")) == nil, "prism-processes.cfg is empty again")

------------------------------------------------ the screen
M.sent = {}
local RX = math.floor(M.W * 0.56) + 3
local function msg(t) return { "modem_message", "x", "router-addr", 4242, 4, ser.serialize(t) } end
local function lastSent() return ser.unserialize(M.sent[#M.sent].data) end
local function key(ch) return { "key_down", "kb", string.byte(ch), 0, "Aaron" } end
local function enter() return { "key_down", "kb", 13, 28, "Aaron" } end
local function field()
  local x, y = M.find("Share past", M.H - 8, RX)
  return { "touch", "screen", x + 13, y, 0, "Aaron" }
end
local seen = {}
local status = cp[2].status
local steps = {
  function() return msg(status) end,
  function()
    local x, y = M.find("chembath", 5)
    return { "touch", "screen", x + 1, y, 0, "Aaron" }
  end,
  function()
    seen.shown = M.find(" 1000 ", M.H - 8, RX) and M.find("set here, tap to change", M.H - 8, RX)
    return field()
  end,
  function()
    seen.focus = M.find("type a number, Enter saves", M.H - 8, RX) ~= nil
    return key("2")
  end,
  function() return key("0") end,
  function() return key("0") end,
  function() return key("0") end,
  function()
    seen.typed = M.find(" 2000_", M.H - 8, RX) ~= nil
    return enter()
  end,
  function()
    local c = lastSent()
    seen.sent = c.cmd == "setOverflow" and c.process == "chembath" and c.overflow == 2000
    return field()
  end,
  function() return enter() end,
  function()
    local c = lastSent()
    seen.cleared = c.cmd == "setOverflow" and c.overflow == nil
    return field()
  end,
  function() return key("5") end,
  function()
    local x, y = M.find("PROCESS chembath", 3, RX)
    return { "touch", "screen", x, y, 0, "Aaron" }   -- a tap elsewhere saves what was typed
  end,
  function()
    local c = lastSent()
    seen.blur = c.cmd == "setOverflow" and c.overflow == 5
    return { "touch", "screen", 1, 2, 0, "Aaron" }
  end,
  function()
    seen.quiet = lastSent().overflow == 5             -- nothing typed: nothing sent
    return { "interrupted" }
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
check(seen.shown, "the page shows the mark and that it was set here")
check(seen.focus and seen.typed, "tapping the field focuses it; digits are typed into it")
check(seen.sent, "Enter sends setOverflow with the number")
check(seen.cleared, "Enter on an empty field goes back to prism.cfg's")
check(seen.blur and seen.quiet, "a tap elsewhere sends what was typed, and nothing when nothing was")

H.done()
