local root = vim.fn.getcwd()
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

local Actions = require("kiss-sorcar.actions").Actions
local Controller = require("kiss-sorcar.controller").Controller
local TabLifecycle = require("kiss-sorcar.tab_lifecycle").TabLifecycle

local socket_path = assert(vim.env.KISS_TEST_SOCKET, "KISS_TEST_SOCKET required")
local work_dir = assert(vim.env.KISS_TEST_WORK_DIR, "KISS_TEST_WORK_DIR required")
local tab_id = string.format("nvim-control-%d-%s", vim.fn.getpid(), tostring(vim.uv.hrtime()))
local errors = {}
local snapshots = {}

local controller = Controller.new({
  path = socket_path,
  work_dir = work_dir,
  on_error = function(err)
    errors[#errors + 1] = tostring(err)
  end,
})
local lifecycle = TabLifecycle.new(controller)
local actions = Actions.new(controller)
controller:add_listener(function(event)
  if event.type == "tabs_state" then
    snapshots[#snapshots + 1] = vim.deepcopy(event.tabs)
  end
end)

local function wait_for(predicate, context)
  if not vim.wait(10000, predicate, 10) then
    error("timeout: " .. context .. "; errors=" .. vim.inspect(errors), 2)
  end
end

local function registry_has(target)
  for _, tab in ipairs(controller.state.registry or {}) do
    if tab.tabId == target then
      return true
    end
  end
  return false
end

local ok, err = xpcall(function()
  assert(controller:connect())
  wait_for(function()
    return #snapshots >= 1
  end, "initial tabs_state after setWorkDir + ready")
  assert(not registry_has(tab_id), "disposable tab unexpectedly exists before openTab")

  local opened, open_err = lifecycle:open(tab_id, {
    title = "Neovim control-plane integration",
    workDir = work_dir,
  })
  assert(opened, open_err)
  wait_for(function()
    return lifecycle:status(tab_id).state == "confirmed" and registry_has(tab_id)
  end, "tabs_state confirmation for openTab")

  local closed, close_err = actions:close_tab(tab_id)
  assert(closed, close_err)
  wait_for(function()
    return not registry_has(tab_id)
  end, "tabs_state removal after closeTab")
  assert(#errors == 0, "controller errors: " .. vim.inspect(errors))
end, debug.traceback)

lifecycle:close()
controller:close()
vim.wait(50)

if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
print(string.format(
  "PASS real daemon control plane: %d tabs_state snapshots; tab %s confirmed then removed",
  #snapshots,
  tab_id
))
vim.cmd("quit")
