--[[ prism.control.ui: the control screen's layout on top of prism.gui (drawing, colors, touch targets).

  Ui.new(gpu) -> ui       full resolution; raises unless the GPU/screen is tier 3. Has everything a
                          prism.gui ui has (put, fill, fg, bg, button, hit, clearHits, tap, restore, W, H, C), plus:
  ui.L                    layout: LW (left column width), RX/RW (right column x/width), PANEL_TOP,
                          LIST_TOP, LIST_BOTTOM, INFO_ROW, ACTION_ROW
  Ui.C, Ui.len(s), Ui.fit(s, n), Ui.rfit(s, n)   from prism.gui
  Ui.sparkline(series, width)                    (also on ui)
]]

local Gui = require("prism.gui")

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

function Ui.new(gpu)
  local W, H = gpu.maxResolution()
  if W < 100 or H < 36 then
    error("prism-control.lua needs a tier 3 GPU and screen (got " .. W .. "x" .. H .. ")", 0)
  end
  local ui = Gui.new(gpu, W, H)
  ui.sparkline = Ui.sparkline
  local LW = math.floor(W * 0.56)
  local PANEL_TOP = H - 14
  ui.L = { LW = LW, RX = LW + 3, RW = W - (LW + 3), PANEL_TOP = PANEL_TOP,
           LIST_TOP = 5, LIST_BOTTOM = PANEL_TOP - 4, INFO_ROW = PANEL_TOP - 3, ACTION_ROW = PANEL_TOP - 2 }
  return ui
end

return Ui
