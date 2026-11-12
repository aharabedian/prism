--[[ prism.setup.autostart: start on boot, through /home/.shrc (run by the OpenOS shell at boot).

  step(program) -> new .shrc text | nil when nothing changes
    Asks whether to start `program` ("prism" or "prism-control") on boot. A computer is either the
    router or the screen, so the other program's line is removed.
  read(program) -> { present, other? }   whether .shrc starts `program`, and the other program if it's there
  text(program, want) -> new .shrc text | nil when nothing changes   (no questions; for the setup editor)
]]

local files = require("prism.files")
local input = require("prism.setup.input")
local paths = require("prism.setup.paths")

local A = {}

-- The program a .shrc line runs: "prism" for "/home/bin/prism.lua -v".
local function programOf(line)
  local word = line:match("^%s*(%S+)")
  return word and (word:gsub("^.*/", ""):gsub("%.lua$", ""))
end

local function lines()
  local text = files.read(paths.SHRC) or ""
  local out = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do out[#out + 1] = line end
  if out[#out] == "" then out[#out] = nil end
  return out
end

function A.read(program)
  local present, other = false, nil
  for _, line in ipairs(lines()) do
    local p = programOf(line)
    if p == program then present = true
    elseif p == "prism" or p == "prism-control" then other = p end
  end
  return { present = present, other = other }
end

function A.text(program, want)
  local now = A.read(program)
  if want == now.present and not now.other then return nil end
  local out = {}
  for _, line in ipairs(lines()) do
    local p = programOf(line)
    if p ~= "prism" and p ~= "prism-control" then out[#out + 1] = line end
  end
  if want then out[#out + 1] = program end
  return #out > 0 and (table.concat(out, "\n") .. "\n") or ""
end

function A.step(program)
  input.header("Start on boot")
  local now = A.read(program)
  print("  /home/.shrc runs when the computer boots into its shell; Ctrl+C in " .. program .. " gets you the shell")
  local want = input.yes(("  start %s when this computer boots?"):format(program), true)
  if now.other then print(("  (removing %s from .shrc - this computer is now the %s)"):format(now.other,
    program == "prism" and "router" or "control screen")) end
  return A.text(program, want)
end

return A
