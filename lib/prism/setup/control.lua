--[[ prism.setup.control: prism-setup for the control screen computer -> /home/prism-control.cfg.
  run()   wireless, beep, start on boot; then review and save.
]]

local component  = require("component")
local filesystem = require("filesystem")
local files      = require("prism.files")
local probe      = require("prism.probe")
local input      = require("prism.setup.input")
local paths      = require("prism.setup.paths")
local render     = require("prism.setup.render")
local autostart  = require("prism.setup.autostart")
local save       = require("prism.setup.save")

local C = {}

function C.run()
  input.begin(3)
  local cfgPath = paths.CONTROL_CFG
  local old = files.loadLua(cfgPath, {}) or {}
  if filesystem.exists(cfgPath) then print("Editing " .. cfgPath) end
  local c = {}
  for k, v in pairs(old) do c[k] = v end

  input.header("Wireless link to the router")
  if not probe.isWireless() then print("  no Wireless Network Card found - the control screen needs one") end
  print("  use the same port and secret as the router (prism-setup printed them there)")
  c.modemPort = input.askPort(old.modemPort)
  c.token = c.modemPort and input.askToken(old.token) or nil

  input.header("Alerts")
  c.beep = input.yes("  beep when a new alert appears?", old.beep ~= false)

  local shrc = autostart.step("prism-control")
  local text = render.control(c)
  save.review(cfgPath, text, shrc)
  if not c.modemPort then print("warning: with wireless off the screen can't reach the router") end
  if component.isAvailable("gpu") then
    local w, h = component.gpu.maxResolution()
    if w < 160 or h < 50 then print(("warning: this GPU/screen gives %dx%d; prism-control wants a tier 3 (160x50)"):format(w, h)) end
  else
    print("warning: no GPU found - prism-control needs a tier 3 GPU and screen")
  end
  if not input.yes("Save?", true) then print("nothing saved"); return end
  if not save.commit(cfgPath, text, shrc) then return end
  print("saved. Start prism-control to use it.")
end

return C
