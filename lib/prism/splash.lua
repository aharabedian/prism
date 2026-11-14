--[[ prism.splash: the SPECTRA logo in pixel art, shown for a moment while a program starts.

  splash.show(gpu, w, h, name, version, accent)
      clear the w x h screen and draw the logo, "S P E C T R A" and the program's name (in `accent`) and
      version, centered. Double size when the screen has room (tier 3), else 25 x 12 cells
  splash.rows(scale) -> { { { x, text, fg, bg }... }... }
      the logo as runs of cells, one list per screen row, x from 1. Each cell is two pixels: "▀" in the top
      pixel's color over the bottom one's, or " " when both match (pure)
  splash.ART       the logo: 25 x 23 pixels, a string per row, a character per pixel (PIXEL says which color)
  splash.SECONDS   how long a program shows it before its first screen
]]

local Gui = require("prism.gui")

local splash = {}

splash.SECONDS = 1.5

-- The Hub mark: a prism seen from above, a spoke per project meeting at the hub. Orange PRISM to the
-- apex, blue LENS to the right, green LUMEN to the left. Colors are the logo's, whatever the program.
splash.ART = {
  "............O............",
  "...........WOW...........",
  "...........WOW...........",
  "..........W.O.W..........",
  "..........W.O.W..........",
  ".........W..O..W.........",
  ".........W..O..W.........",
  "........W...O...W........",
  "........W...O...W........",
  ".......W....O....W.......",
  ".......W....O....W.......",
  "......W.....O.....W......",
  ".....W......O......W.....",
  ".....W......O......W.....",
  "....W.......W.......W....",
  "....W......WWW......W....",
  "...W......GGWBB......W...",
  "...W....GG.....BB....W...",
  "..W...GG.........BB...W..",
  "..W..G.............B..W..",
  ".W.GG...............BB.W.",
  ".GG...................BB.",
  "GWWWWWWWWWWWWWWWWWWWWWWWB",
}
splash.PIXEL = { W = 0xe6eaee, O = 0xff9f43, B = 0x5eb4ff, G = 0x4fd17a }

local ART_W, ART_H = #splash.ART[1], #splash.ART

local function pixel(px, py)
  local row = splash.ART[py]
  return row and splash.PIXEL[row:sub(px, px)] or Gui.C.bg
end

function splash.rows(scale)
  local out = {}
  for r = 1, math.ceil(ART_H * scale / 2) do
    local runs, prev = {}, nil
    for c = 1, ART_W * scale do
      local px = (c - 1) // scale + 1
      local top, bottom = pixel(px, (2 * r - 2) // scale + 1), pixel(px, (2 * r - 1) // scale + 1)
      local ch, fg = "▀", top
      if top == bottom then ch, fg = " ", Gui.C.text end
      if prev and prev.ch == ch and prev.fg == fg and prev.bg == bottom then
        prev.n = prev.n + 1
      else
        prev = { x = c, ch = ch, fg = fg, bg = bottom, n = 1 }
        runs[#runs + 1] = prev
      end
    end
    for i, run in ipairs(runs) do runs[i] = { run.x, string.rep(run.ch, run.n), run.fg, run.bg } end
    out[r] = runs
  end
  return out
end

function splash.show(gpu, w, h, name, version, accent)
  local ui = Gui.new(gpu, w, h)
  local C = ui.C
  local scale = (w >= 2 * ART_W + 10 and h >= ART_H + 8) and 2 or 1
  local art = splash.rows(scale)
  local top = math.max(1, (h - (#art + 4)) // 2 + 1)
  local left = (w - ART_W * scale) // 2 + 1
  ui.fill(1, 1, w, h, C.bg)
  for r, runs in ipairs(art) do
    for _, run in ipairs(runs) do ui.put(left + run[1] - 1, top + r - 1, run[2], run[3], run[4]) end
  end
  local function centered(y, parts)
    local width = 0
    for _, p in ipairs(parts) do width = width + Gui.len(p[1]) end
    local x = (w - width) // 2 + 1
    for _, p in ipairs(parts) do ui.put(x, y, p[1], p[2], C.bg); x = x + Gui.len(p[1]) end
  end
  centered(top + #art + 1, { { "S P E C T R A", C.text } })
  centered(top + #art + 3, { { name, accent }, { "  v" .. tostring(version), C.dim } })
end

return splash
