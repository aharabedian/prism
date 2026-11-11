--[[ prism.control.ui: drawing primitives, colors, layout and touch targets for the control screen.

  Ui.new(gpu) -> ui       sets the resolution; raises unless the GPU/screen is tier 3
  ui.W, ui.H              screen size
  ui.L                    layout: LW (left column width), RX/RW (right column x/width), PANEL_TOP,
                          LIST_TOP, LIST_BOTTOM, INFO_ROW, ACTION_ROW
  ui.C                    colors
  ui.put(x, y, s, fg?, bg?)      text; colors are only sent to the GPU when they change
  ui.fill(x, y, w, h, bg, ch?)
  ui.fg(c), ui.bg(c)
  ui.button(x, y, label, { on?, color?, fg?, disabled?, fn? }) -> x after the button
  ui.hit(x1, y1, x2, y2, fn)    register a touch target; ui.clearHits() before a full redraw
  ui.tap(x, y) -> true if a target was hit (the last registered wins)
  Ui.len(s), Ui.fit(s, n), Ui.rfit(s, n), Ui.sparkline(series, width)   text helpers (also on ui)
]]

local unicode = require("unicode")

local Ui = {}

Ui.C = {
  bg     = 0x0f1419, panel = 0x1a2129, line  = 0x2c3640,
  text   = 0xe6e9ec, dim   = 0x7d8a96, accent = 0xffa62b,
  good   = 0x4cd17a, bad   = 0xff5c5c, warn  = 0xffd24c, info = 0x5fb4ff,
  btn    = 0x2c3640, btnOn = 0x2f6fb5, sel   = 0x24384d, field = 0x0b0f13,
}

local SPARK = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

function Ui.len(s) return unicode.len(s) end

-- s cut (with …) or padded to exactly n columns.
function Ui.fit(s, n)
  s = tostring(s or "")
  if n <= 0 then return "" end
  local l = unicode.len(s)
  if l > n then return unicode.sub(s, 1, n - 1) .. "…" end
  return s .. string.rep(" ", n - l)
end

-- s right-aligned in n columns.
function Ui.rfit(s, n)
  s = tostring(s or "")
  local l = unicode.len(s)
  if l >= n then return unicode.sub(s, 1, n) end
  return string.rep(" ", n - l) .. s
end

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
  gpu.setResolution(W, H)

  local C = Ui.C
  local LW = math.floor(W * 0.56)
  local PANEL_TOP = H - 14
  local ui = {
    W = W, H = H, C = C, gpu = gpu,
    len = Ui.len, fit = Ui.fit, rfit = Ui.rfit, sparkline = Ui.sparkline,
    L = { LW = LW, RX = LW + 3, RW = W - (LW + 3), PANEL_TOP = PANEL_TOP,
          LIST_TOP = 5, LIST_BOTTOM = PANEL_TOP - 4, INFO_ROW = PANEL_TOP - 3, ACTION_ROW = PANEL_TOP - 2 },
  }

  local curFg, curBg
  function ui.fg(c) if c ~= curFg then gpu.setForeground(c); curFg = c end end
  function ui.bg(c) if c ~= curBg then gpu.setBackground(c); curBg = c end end
  function ui.put(x, y, s, f, b)
    if b then ui.bg(b) end
    ui.fg(f or C.text)
    gpu.set(x, y, s)
  end
  function ui.fill(x, y, w, h, b, ch)
    if w > 0 and h > 0 then ui.bg(b); gpu.fill(x, y, w, h, ch or " ") end
  end

  local hits = {}
  function ui.clearHits() hits = {} end
  function ui.hit(x1, y1, x2, y2, fn) hits[#hits + 1] = { x1, y1, x2, y2, fn } end
  function ui.tap(x, y)
    for i = #hits, 1, -1 do
      local h = hits[i]
      if x >= h[1] and x <= h[3] and y >= h[2] and y <= h[4] then h[5](); return true end
    end
    return false
  end

  function ui.button(x, y, label, o)
    o = o or {}
    local s = " " .. label .. " "
    local back = o.on and C.btnOn or (o.color or C.btn)
    ui.put(x, y, s, o.disabled and C.dim or (o.fg or C.text), back)
    if o.fn and not o.disabled then ui.hit(x, y, x + Ui.len(s) - 1, y, o.fn) end
    return x + Ui.len(s) + 1
  end

  -- Back to a plain terminal on exit.
  function ui.restore()
    gpu.setBackground(0x000000)
    gpu.setForeground(0xFFFFFF)
  end

  return ui
end

return Ui
