--[[ prism.setup.input: asking questions on the terminal.

  CANCEL                       raised (as an error value) when input ends (Ctrl+D)
  ask(prompt, default)         a line; blank -> default
  yes(prompt, default)         y/n -> boolean
  choose(labels, default)      numbered menu -> index
  begin(steps), header(text)   numbered step headings ("3/9 Export buses")
  processHint(procs)           print the numbered process list
  askProcess(what, old, procs) -> process, name | nil (skip); a new name is added to procs
  askPort(old)                 -> port | false (wireless off)
  askToken(old)                -> token | nil
  pickOne(list, oldPrefix)     one address: automatically when there's one, else a menu
  askSide(what, inventories)   -> side
]]

local U = require("prism.util")

local I = {}

I.CANCEL = {}

function I.ask(prompt, default)
  io.write(prompt .. (default and (" [" .. default .. "]") or "") .. ": ")
  local line = io.read()
  if line == nil then error(I.CANCEL, 0) end
  line = U.trim(line)
  if line == "" then return default end
  return line
end

function I.yes(prompt, default)
  return I.ask(prompt .. " (y/n)", default and "y" or "n"):lower():sub(1, 1) == "y"
end

function I.choose(labels, default)
  for i, l in ipairs(labels) do print(("  %d) %s"):format(i, l)) end
  while true do
    local n = tonumber(I.ask(("  choose 1-%d"):format(#labels), default and tostring(default)))
    if n and labels[n] then return n end
    print("  enter a number from the list")
  end
end

local step, steps = 0, 0
function I.begin(n) step, steps = 0, n end
function I.header(text) step = step + 1; print(""); print(("%d/%d %s"):format(step, steps, text)) end
function I.skipStep() step = step + 1 end

function I.processHint(procs)
  local parts = {}
  for i, p in ipairs(procs) do parts[i] = i .. ") " .. p end
  print("  processes: " .. table.concat(parts, "  "))
end

function I.askProcess(what, old, procs)
  local default = old and old.process
  local a = I.ask(("  process for %s (number or name, %s)"):format(what, default and "- skips" or "Enter skips"), default)
  if a == nil or a == "-" then return nil end
  local n = tonumber(a)
  if n and procs[n] then a = procs[n]
  elseif n then print("  (no process " .. a .. " in the list; using it as a name)") end
  local known = false
  for _, p in ipairs(procs) do if p == a then known = true end end
  if not known then procs[#procs + 1] = a end
  local name = I.ask("  name (optional)", old and old.name)
  if name == "-" then name = nil end
  return a, name
end

-- false, not nil, for wireless off: the screen treats a missing port as the default port.
function I.askPort(old)
  local default = old == nil and "4242" or tostring(old or 0)
  while true do
    local port = tonumber(I.ask("  wireless port (0 turns wireless off)", default))
    if port and port == math.floor(port) and port >= 0 and port <= 65535 then
      return port > 0 and math.floor(port) or false
    end
    print("  enter a port from 1 to 65535, or 0")
  end
end

function I.askToken(old)
  local token = I.ask("  shared secret (optional, - for none)", type(old) == "string" and old or nil)
  if token == "-" then token = nil end
  return token
end

local function sameAddr(full, prefix)
  return type(prefix) == "string" and prefix ~= "" and full:sub(1, #prefix) == prefix
end
I.sameAddr = sameAddr

function I.pickOne(list, old)
  if #list == 1 then return list[1] end
  local default
  for i, a in ipairs(list) do if sameAddr(a, old) then default = i end end
  return list[I.choose(list, default)]
end

function I.askSide(what, inv)
  print("    which side is the " .. what .. "?")
  local labels = {}
  for i, s in ipairs(inv) do labels[i] = ("%-6s %s (%d slots)"):format(U.sideName(s.side), s.name, s.size) end
  return inv[I.choose(labels)].side
end

return I
