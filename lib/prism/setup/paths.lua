-- prism.setup.paths: where prism-setup reads and writes. PRISM_PREFIX lets the tests use a temp dir.
local PREFIX = os.getenv("PRISM_PREFIX") or ""
local HOME = PREFIX .. "/home"
return {
  HOME        = HOME,
  ROUTER_CFG  = HOME .. "/prism.cfg",
  CONTROL_CFG = HOME .. "/prism-control.cfg",
  RULES_PATH  = HOME .. "/prism-rules.cfg",
  SHRC        = HOME .. "/.shrc",
}
