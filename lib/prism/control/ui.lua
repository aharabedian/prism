--[[ prism.control.ui: the control screen's layout on top of prism.gui (drawing, colors, touch targets).

  Ui.new(gpu) -> ui       full resolution; raises unless the GPU/screen is tier 3. Has everything a
                          prism.gui ui has (put, fill, fg, bg, button, hit, clearHits, tap, restore, W, H, C), plus:
  ui.L                    layout: LW (left column width), RX/RW (right column x/width), PANEL_TOP,
                          LIST_TOP, LIST_BOTTOM, INFO_ROW, ACTION_ROW
  Ui.C, Ui.len(s), Ui.fit(s, n), Ui.rfit(s, n)   from prism.gui
  Ui.sparkline(series, width)                    (also on ui)
  Ui.rateText(p) -> text, kind | nil             a router-status process's throughput: "212/min  ·  clears 42m"
                                                 (kind "clears"), "growing 20/min" ("growing"), "steady"; nil
                                                 before the router has measured it or with nothing moving
  Ui.busyText(p) -> text, kind | nil             its machines' busy share over the last hour, and what it
                                                 means; kind "limit", "slow", "waiting" or "ok"
]]

local Gui = require("prism.gui")
local U   = require("prism.util")

local Ui = { C = Gui.C, len = Gui.len, fit = Gui.fit, rfit = Gui.rfit }

local SPARK = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

function Ui.sparkline(series, width)
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

function Ui.rateText(p)
  local out, inn, items = p.outRate, p.inRate or 0, p.items or 0
  if not out or items == 0 or (out == 0 and inn == 0) then return nil end
  local net = out - inn
  if net > 0 then return ("%s/min  ·  clears %s"):format(U.fmtNum(out), U.fmtShort(items / net * 60)), "clears" end
  if net < 0 then return ("%s/min  ·  growing %s/min"):format(U.fmtNum(out), U.fmtNum(-net)), "growing" end
  return ("%s/min  ·  steady"):format(U.fmtNum(out)), "steady"
end

function Ui.busyText(p)
  if not p.busy then return nil end
  local head = ("Machines busy %s in the last hour"):format(U.pct(p.busy))
  if p.busy >= 0.9 then return head .. ": they are the limit.", "limit" end
  if p.busy < 0.5 and (p.items or 0) > (p.below or 0) then
    return head .. " while items wait: items reach them more slowly than they run.", "slow"
  end
  if p.busy < 0.5 then return head .. ": they wait for items.", "waiting" end
  return head .. ".", "ok"
end

function Ui.new(gpu)
  local W, H = gpu.maxResolution()
  if W < 100 or H < 36 then
    error("prism-control.lua needs a tier 3 GPU and screen (got " .. W .. "x" .. H .. ")", 0)
  end
  local ui = Gui.new(gpu, W, H)
  ui.sparkline, ui.rateText, ui.busyText = Ui.sparkline, Ui.rateText, Ui.busyText
  local LW = math.floor(W * 0.56)
  local PANEL_TOP = H - 14
  ui.L = { LW = LW, RX = LW + 3, RW = W - (LW + 3), PANEL_TOP = PANEL_TOP,
           LIST_TOP = 5, LIST_BOTTOM = PANEL_TOP - 4, INFO_ROW = PANEL_TOP - 3, ACTION_ROW = PANEL_TOP - 2 }
  return ui
end

return Ui
