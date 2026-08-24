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
local event_log = assert(vim.env.KISS_TEST_EVENT_LOG, "KISS_TEST_EVENT_LOG required")
local model = vim.env.KISS_TEST_MODEL
local tab_id = string.format("nvim-run-%d-%s", vim.fn.getpid(), tostring(vim.uv.hrtime()))
local client_task_id = string.format("nvim-task-%d-%s", vim.fn.getpid(), tostring(vim.uv.hrtime()))
local errors = {}
local events = {}
local run_events = {}
local initial_snapshot_seen = false
local run_submitted = false

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
  events[#events + 1] = vim.deepcopy(event)
  if event.type == "tabs_state" then
    initial_snapshot_seen = true
  end
  if run_submitted and event.tabId == tab_id then
    run_events[#run_events + 1] = vim.deepcopy(event)
  end
end)

local function wait_for(predicate, timeout, context)
  if not vim.wait(timeout, predicate, 10) then
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

local function event_index(event_type, predicate)
  for index, event in ipairs(run_events) do
    if event.type == event_type and (not predicate or predicate(event)) then
      return index
    end
  end
  return nil
end

local function write_event_log()
  local output = assert(io.open(event_log, "w"))
  for index, event in ipairs(events) do
    output:write(vim.json.encode({ index = index, event = event }), "\n")
  end
  output:close()
end

local ok, err = xpcall(function()
  assert(controller:connect())
  wait_for(function()
    return initial_snapshot_seen
  end, 10000, "initial tabs_state after setWorkDir + ready")

  local opened, open_err = lifecycle:open(tab_id, {
    title = "Neovim read-only run integration",
    workDir = work_dir,
  })
  assert(opened, open_err)
  wait_for(function()
    return lifecycle:status(tab_id).state == "confirmed" and registry_has(tab_id)
  end, 10000, "tabs_state confirmation for openTab")

  run_submitted = true
  local options = {
    autoCommit = false,
    maxBudget = 0.25,
    taskId = client_task_id,
    useParallel = false,
    useWorktree = false,
    webTools = false,
    workDir = work_dir,
  }
  if type(model) == "string" and model ~= "" then
    options.model = model
  end
  local submitted, submit_err = actions:run(
    tab_id,
    "Read-only repository inspection. Run `pwd; git status --short; git log -1 --oneline` exactly once. Do not create, edit, delete, stage, commit, or otherwise modify any file. Then call finish exactly once with success=true, is_continue=false, and command output in summary.",
    options
  )
  assert(submitted, submit_err)

  wait_for(function()
    local tab = controller.state.tabs[tab_id]
    return event_index("status", function(event)
      return event.running == true
    end) ~= nil and tab and tab.running == false and event_index("status", function(event)
      return event.running == false
    end) ~= nil
  end, 300000, "terminal status running=false")

  local start_index = assert(event_index("status", function(event)
    return event.running == true
  end), "missing status running=true")
  local result_index = assert(event_index("result"), "missing result")
  assert(run_events[result_index].success ~= false, "task result reported failure: " .. vim.inspect(run_events[result_index]))
  local lifecycle_index = event_index("task_done") or event_index("task_error")
    or event_index("task_stopped") or event_index("task_interrupted")
  assert(lifecycle_index, "missing task lifecycle event")
  local end_index = assert(event_index("status", function(event)
    return event.running == false
  end), "missing status running=false")
  assert(start_index < result_index, "result preceded running=true")
  assert(result_index < lifecycle_index, "lifecycle did not follow result")
  assert(lifecycle_index < end_index, "running=false did not follow lifecycle")
  local tool_call_index = event_index("tool_call")
  local tool_result_index = event_index("tool_result")
  assert(
    (tool_call_index and tool_result_index) or (not tool_call_index and not tool_result_index),
    "tool_call/tool_result pair incomplete"
  )

  local tab = assert(controller.state.tabs[tab_id], "missing tab state after task")
  assert(tab.result ~= nil, "state did not retain result")
  assert(tab.lifecycle ~= nil, "state did not retain lifecycle")
  assert(tab.running == false, "state did not terminate running state")

  local closed, close_err = actions:close_tab(tab_id)
  assert(closed, close_err)
  wait_for(function()
    return not registry_has(tab_id)
  end, 10000, "tabs_state removal after closeTab")
  assert(#errors == 0, "controller errors: " .. vim.inspect(errors))
end, debug.traceback)

write_event_log()
lifecycle:close()
controller:close()
vim.wait(50)

if not ok then
  io.stderr:write(err .. "\n")
  io.stderr:write("EVENT_LOG=" .. event_log .. "\n")
  vim.cmd("cquit 1")
end

local types = {}
for _, event in ipairs(run_events) do
  types[#types + 1] = event.type .. (event.type == "status" and "(" .. tostring(event.running) .. ")" or "")
end
print("PASS real daemon read-only run: " .. table.concat(types, " -> "))
print("EVENT_LOG=" .. event_log)
vim.cmd("quit")
