-- test_setup_screen.lua: prism-setup's full-screen editor on the router: lists what's found and configured,
-- assigning, naming, dropping, feeders, general settings, review and save, quitting, falling back to text.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check

local home = H.TMP .. "/root/home"
os.execute('mkdir -p "' .. home .. '"')
local realGetenv = os.getenv
os.getenv = function(k) if k == "PRISM_PREFIX" then return H.TMP .. "/root" end return realGetenv(k) end
local ROUTER_CFG, SHRC = home .. "/prism.cfg", home .. "/.shrc"

-- World: a tier 2 screen; two cable blocks with three buses; an interface + transposer for a feeder;
-- a stocking bus and a GT machine.
M.resize(80, 25)
M.proxies["sc000000-ssss"] = { address = "sc000000-ssss", type = "screen" }
M.busHosts["eb111111-1111"][2][1] = { name = "minecraft:cobblestone", damage = 0, label = "Cobblestone" }
M.proxies["if000000-iiii"] = { address = "if000000-iiii", type = "me_interface",
  setInterfaceConfiguration = function() return true end }
M.proxies["tp000000-tttt"] = { address = "tp000000-tttt", type = "transposer",
  getInventorySize = function(s) if s == 4 then return 9 elseif s == 5 then return 3 end return nil, "no inventory" end,
  getInventoryName = function(s) return s == 4 and "appliedenergistics2:tile.BlockInterface" or "gregtech:gt.blockmachines" end }
M.machine("gm010000-aaaa", { isMachineActive = true, isWorkAllowed = true })
M.stocker("st010000-ssss", { advanced = true })

local function read(path) local f = io.open(path); if not f then return nil end; local s = f:read("*a"); f:close(); return s end
local function write(path, s) local f = assert(io.open(path, "w")); f:write(s); f:close() end
local function loadCfg(path) return assert(loadfile(path, "t", { sides = require("sides") }))() end

local ORIGINAL = [[
return { network = "me000000-cccc", database = "db000000-aaaa", modemPort = 4242, interval = 7,
         rules = { { pattern = "^Crushed .+ Ore$", process = "wash" }, { pattern = "Ore$", process = "crush" } },
         buses = { { address = "eb111111", side = sides.north, process = "wash", name = "Washer 1" } },
         machines = { { address = "gm990000-zzzz", process = "wash", name = "Old washer" } } }
]]
write(ROUTER_CFG, ORIGINAL)
write(SHRC, "prism\n")

-- Events for the editor: tap text on screen (at or below row minY), type, press a key.
local function tap(text, minY, minX)
  local x, y = M.find(text, minY, minX)
  assert(x, "not on screen: " .. text)
  return { "touch", "sc000000-ssss", x + 1, y, 0, "Aaron" }
end
local function key(code, ch) return { "key_down", "kb", ch or 0, code, "Aaron" } end
local function chars(s) local t = {} for c in s:gmatch(".") do t[#t + 1] = { "key_down", "kb", string.byte(c), 0, "Aaron" } end return t end
local function screenHas(text) return M.find(text) ~= nil end

-- Run prism-setup; each step looks at the screen and returns the next event (or a list of them).
local function drive(steps, ...)
  local queue, i = {}, 0
  M.onPull = function()
    while #queue == 0 do
      i = i + 1
      local s = steps[i]
      if not s then return { "interrupted" } end
      local ev = s()
      if ev then
        if type(ev[1]) == "table" then for _, e in ipairs(ev) do queue[#queue + 1] = e end else queue[1] = ev end
      end
    end
    return table.remove(queue, 1)
  end
  local out = {}
  local realPrint = print
  print = function(...) out[#out + 1] = table.concat({ ... }, "\t") end
  local realRead, realWrite = io.read, io.write
  io.read = function() return nil end
  io.write = function(...) out[#out + 1] = table.concat({ ... }) end
  local ok, err = pcall(H.run, "prism-setup.lua", ...)
  print, io.read, io.write = realPrint, realRead, realWrite
  M.onPull = nil
  if not ok then error(err, 0) end
  return table.concat(out, "\n")
end

---------------------------------------------------------------- editing and saving
M.oob = 0
drive({
  function()
    check(screenHas("PRISM setup") and screenHas("BUSES 1") and screenHas("MACHINES 1!"),
      "opens on the buses tab; tabs count what is in use and flag entries not found")
    local _, y = M.find("north")
    check(M.row(y):find("wash", 1, true) and M.row(y):find("Washer 1", 1, true) and M.row(y):find("Cobblestone", 1, true),
      "a configured bus shows its process, name and slot 1 marker")
    local _, y2 = M.find("south")
    check(M.row(y2):find("not used", 1, true), "a bus that isn't in the config shows as not used")
    H.screen("setup-buses")
    return tap("south")
  end,
  function()
    check(screenHas("Export bus eb111111-1111, south side"), "tapping a row shows it in the panel")
    local _, py = M.find("Process", 17)
    return tap("crush", py)
  end,
  function()
    local _, y = M.find("south")
    check(M.row(y):find("crush", 1, true), "tapping a process uses the bus for it")
    check(screenHas("unsaved changes"), "the header says there are unsaved changes")
    local _, ny = M.find("Name", 17)
    return tap("    ", ny, 13)
  end,
  function() local t = chars("Mac 1"); t[#t + 1] = key(28); return t end,
  function()
    local _, y = M.find("south")
    check(M.row(y):find("Mac 1", 1, true), "typing a name and pressing Enter names it")
    H.screen("setup-bus-named")
    return tap("MACHINES")
  end,
  function()
    local _, y = M.find("gm990000")
    check(M.row(y):find("not found", 1, true), "a configured machine that isn't attached is flagged")
    local _, y2 = M.find("gm010000")
    check(M.row(y2):find("working", 1, true), "an attached machine shows its state")
    return tap("gm990000")
  end,
  function()
    check(screenHas("Not found: check its adapter"), "the panel explains a missing entry")
    return tap("DROP", 17)
  end,
  function()
    check(not screenHas("gm990000"), "DROP removes it")
    return tap("FEEDERS")
  end,
  function()
    check(screenHas("west: tile.BlockInterface") or screenHas("west: BlockInterface"), "an unused transposer shows what it touches")
    return tap("tp000000")
  end,
  function() return tap("+ NEW", 17) end,
  function() local t = chars("centrifuge"); t[#t + 1] = key(28); return t end,
  function()
    local _, y = M.find("tp000000")
    check(M.row(y):find("centrifuge", 1, true) and M.row(y):find("from if000000, west -> east", 1, true),
      "a new process name makes the transposer a feeder, with an interface and the guessed sides")
    H.screen("setup-feeder")
    local _, fy = M.find("machine side", 17)
    return tap("east", fy)
  end,
  function()
    local _, y = M.find("tp000000")
    check(M.row(y):find("west -> west", 1, true), "tapping a side cycles it")
    local _, fy = M.find("machine side", 17)
    return tap("west", fy, 50)
  end,
  function() return tap("GENERAL") end,
  function()
    check(screenHas("me000000") and screenHas("db000000"), "general shows the network and database")
    H.screen("setup-general")
    local _, y = M.find("Wireless port")
    return tap("4242", y)
  end,
  function()
    return { key(14), key(14), key(14), key(14), chars("5555")[1], chars("5555")[2], chars("5555")[3], chars("5555")[4], key(28) }
  end,
  function()
    local _, y = M.find("Wireless port")
    check(M.row(y):find("5555", 1, true), "the port can be typed")
    local _, ly = M.find("LENS hub port")
    check(M.row(ly):find("name", 1, true) and M.row(ly):find("secret", 1, true), "LENS port, name and secret on one row")
    return { { "touch", "sc000000-ssss", 21, ly, 0, "Aaron" }, chars("5555")[1], chars("5555")[2], chars("5555")[3],
      chars("5555")[4], key(28) }
  end,
  function()
    check(screenHas("that's the control screen's port - LENS needs its own"), "LENS can't take the control screen's port")
    local _, ly = M.find("LENS hub port")
    return tap("OFF", ly, 20)
  end,
  function()
    local _, ly = M.find("LENS hub port")
    check(M.row(ly):find("4243", 1, true), "turning LENS on fills in the hub's usual port")
    local nx = M.find("name", ly, 20)
    local t = { { "touch", "sc000000-ssss", nx + 6, ly, 0, "Aaron" } }
    for _, e in ipairs(chars("prism-ore")) do t[#t + 1] = e end
    t[#t + 1] = key(28)
    return t
  end,
  function()
    local _, ly = M.find("LENS hub port")
    check(M.row(ly):find("prism-ore", 1, true), "the LENS name can be typed")
    H.screen("setup-general-lens")
    return tap("ON", select(2, M.find("Start on boot")))
  end,
  function() return tap("SAVE", 25) end,
  function()
    check(screenHas("+ bus eb111111 south: crush (Mac 1)"), "review lists a new bus")
    check(screenHas("- machine gm990000: wash (Old washer)"), "review lists a dropped machine")
    check(screenHas("+ feeder tp000000: centrifuge"), "review lists a new feeder")
    check(screenHas("~ modemPort: 4242 -> 5555"), "review lists general changes")
    check(screenHas("~ lensPort: none -> 4243") and screenHas("~ lensNode: none -> prism-ore"), "review lists LENS changes")
    check(screenHas("no rule sends anything to \"centrifuge\""), "review warns about a process no rule feeds")
    H.screen("setup-review")
    return tap("SAVE", 25)
  end,
  function()
    check(screenHas("Saved") and screenHas("port 5555"), "says it saved, and what the control screen needs")
    return tap("QUIT", 25)
  end,
})
check(M.oob == 0, "nothing drawn off the 80x25 screen")
check(read(ROUTER_CFG .. ".bak") == ORIGINAL, "the old prism.cfg is kept as .bak")
local c = loadCfg(ROUTER_CFG)
check(#c.buses == 2 and c.buses[1].address == "eb111111" and c.buses[1].name == "Washer 1"
  and c.buses[2].address == "eb111111-1111" and c.buses[2].side == 3 and c.buses[2].process == "crush"
  and c.buses[2].name == "Mac 1", "buses saved: the old one as it was, the new one with its full address")
check(#c.machines == 0, "the dropped machine is gone")
local f = c.feeders[1]
check(f and f.interface == "if000000-iiii" and f.transposer == "tp000000-tttt" and f.interfaceSide == 4
  and f.machineSide == 5 and f.process == "centrifuge", "feeder saved with its sides")
check(c.modemPort == 5555 and c.interval == 7 and #c.rules == 2, "port saved; settings and rules it doesn't edit are kept")
check(c.lensPort == 4243 and c.lensNode == "prism-ore" and c.lensToken == nil, "LENS settings saved from the editor")
check(read(SHRC) == "prism\n", ".shrc unchanged when start on boot didn't change")

---------------------------------------------------------------- quitting with unsaved changes
local saved = read(ROUTER_CFG)
drive({
  function() return tap("not used") end,
  function() return tap("wash", 17) end,
  function() return tap("QUIT", 25) end,
  function()
    check(screenHas("tap QUIT again"), "QUIT with unsaved changes asks again")
    return tap("QUIT", 25)
  end,
  function() error("still running after the second QUIT") end,
})
check(read(ROUTER_CFG) == saved, "quitting without saving writes nothing")

---------------------------------------------------------------- text setup
local out = drive({ function() return tap("TEXT SETUP", 25) end })
check(out:find("What is this computer?", 1, true) and out:find("cancelled", 1, true), "TEXT SETUP runs the guided setup")
out = drive({}, "--text")
check(out:find("What is this computer?", 1, true), "--text skips the editor")
M.proxies["sc000000-ssss"] = nil
out = drive({})
check(out:find("What is this computer?", 1, true), "without a screen it runs the guided setup")
M.proxies["sc000000-ssss"] = { address = "sc000000-ssss", type = "screen" }
M.resize(50, 16)
out = drive({})
check(out:find("What is this computer?", 1, true), "a tier 1 screen is too small: guided setup")

---------------------------------------------------------------- tier 3
M.resize(160, 50)
M.oob = 0
drive({
  function()
    check(screenHas("BUSES 2/3"), "a tier 3 screen uses its full size, with room for used/found counts")
    H.screen("setup-buses-t3")
    return tap("FEEDERS")
  end,
  function() return tap("tp000000") end,
  function() H.screen("setup-feeder-t3"); return { "interrupted" } end,
})
check(M.oob == 0, "nothing drawn off the 160x50 screen")
H.done()
