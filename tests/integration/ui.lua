local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
package.path = table.concat({ root .. "/lua/?.lua", root .. "/lua/?/init.lua", package.path }, ";")

local socket_path = assert(vim.env.KISS_TEST_SOCKET, "KISS_TEST_SOCKET required")
local work_dir = assert(vim.env.KISS_TEST_WORK_DIR, "KISS_TEST_WORK_DIR required")
local snapshot_path = assert(vim.env.KISS_TEST_UI_SNAPSHOT, "KISS_TEST_UI_SNAPSHOT required")
local model = vim.env.KISS_TEST_MODEL
local tab_id = "nvim-ui-" .. vim.fn.getpid() .. "-" .. tostring(vim.uv.hrtime())
local errors = {}

local sorcar = require("kiss-sorcar")
local client = sorcar.setup({
  socket_path = socket_path,
  work_dir = work_dir,
  tab_id = tab_id,
  run_options = {
    autoCommit = false,
    maxBudget = 0.25,
    model = model ~= "" and model or nil,
    useParallel = false,
    useWorktree = false,
    webTools = false,
  },
})
client.controller.on_error = function(err)
  errors[#errors + 1] = tostring(err)
  client.ui:_schedule_update()
end
vim.cmd("runtime plugin/kiss-sorcar.lua")

local function wait_for(predicate, timeout, context)
  if not vim.wait(timeout, predicate, 10) then
    error("timeout: " .. context .. "; errors=" .. vim.inspect(errors), 2)
  end
end

local function registry_has(target)
  for _, tab in ipairs(client.controller.state.registry or {}) do
    if tab.tabId == target then
      return true
    end
  end
  return false
end

local function buffer_text()
  return table.concat(vim.api.nvim_buf_get_lines(client.ui.buffer, 0, -1, false), "\n")
end

local ok, err = xpcall(function()
  wait_for(function()
    return client.controller.state.connection.connected
      and client.controller.state.registry_generation == client.controller.state.connection.generation
  end, 10000, "fresh initial tabs_state")

  vim.cmd("Sorcar")
  assert(vim.bo.buftype == "nofile", ":Sorcar did not open scratch buffer")
  assert(vim.bo.filetype == "kiss-sorcar", "wrong Sorcar filetype")
  assert(vim.bo.modifiable == false, "Sorcar client buffer remained modifiable")
  local task_composer = assert(client.ui:compose("task"))
  assert(vim.api.nvim_get_current_buf() == task_composer, "task composer did not receive focus")
  assert(vim.bo[task_composer].modifiable == true, "task composer is not editable")
  vim.api.nvim_buf_set_lines(task_composer, 0, -1, false, {
    "Read-only multiline UI dogfood.",
    "Run `pwd; git status --short` exactly once. Do not modify files.",
    "Then finish with concise command output.",
  })
  local submitted, submit_err = client.ui:submit_composer()
  assert(submitted, submit_err)
  assert(client.ui.composer_buffer == task_composer, "task draft closed before deferred run acceptance")

  wait_for(function()
    local tab = client.controller.state.tabs[tab_id]
    return registry_has(tab_id) and tab and tab.running == true
      and client.ui.composer_buffer == nil
      and buffer_text():find("Task:       running (current-generation confirmed)", 1, true) ~= nil
  end, 15000, "openTab confirmation, run acceptance, composer closure, and running status")

  local steering_composer = assert(client.ui:compose("steer"))
  vim.api.nvim_buf_set_lines(steering_composer, 0, -1, false, {
    "Keep final answer to one short paragraph.",
    "Include command output only once.",
  })
  local steered, steer_err = client.ui:submit_composer()
  assert(steered, steer_err)
  assert(client.ui.composer_buffer == nil, "accepted steering composer remained open")
  wait_for(function()
    local tab = client.controller.state.tabs[tab_id]
    return tab and tab.lifecycle ~= nil and tab.running == false
  end, 300000, "lifecycle plus status(false)")

  client.ui:render()
  local final_view = buffer_text()
  assert(final_view:find("## Prompt", 1, true), "prompt absent from UI")
  assert(final_view:find("## Thinking", 1, true), "thinking absent from UI")
  assert(final_view:find("## Response", 1, true), "streamed text absent from UI")
  assert(final_view:find("## Result (not lifecycle completion)", 1, true), "result absent from UI")
  assert(final_view:find("## Lifecycle", 1, true), "lifecycle absent from UI")
  assert(final_view:find("task_done", 1, true), "task_done absent from UI")
  assert(final_view:find("Transcript: current-generation confirmed", 1, true), "fresh transcript marker absent")
  assert(#errors == 0, "controller errors: " .. vim.inspect(errors))

  local output = assert(io.open(snapshot_path, "w"))
  output:write(final_view, "\n")
  output:close()

  local closed, close_err = client.actions:close_tab(tab_id)
  assert(closed, close_err)
  wait_for(function()
    return not registry_has(tab_id)
  end, 10000, "closeTab confirmation")
end, debug.traceback)

sorcar.close()
vim.wait(50)
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
print("PASS real daemon minimal UI dogfood; snapshot=" .. snapshot_path)
vim.cmd("quit")
