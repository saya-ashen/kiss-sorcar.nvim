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
local timeout = tonumber(vim.env.KISS_TEST_TIMEOUT_MS) or 300000
local errors = {}
local all_events = {}
local initial_snapshot_seen = false

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
  all_events[#all_events + 1] = vim.deepcopy(event)
  if event.type == "tabs_state" then
    initial_snapshot_seen = true
  end
end)

local function wait_for(predicate, wait_timeout, context)
  if not vim.wait(wait_timeout, predicate, 10) then
    error("timeout: " .. context .. "; errors=" .. vim.inspect(errors), 2)
  end
end

local function registry_has(tab_id)
  for _, tab in ipairs(controller.state.registry or {}) do
    if tab.tabId == tab_id then
      return true
    end
  end
  return false
end

local function events_for(tab_id, first_index)
  local events = {}
  for index = first_index, #all_events do
    local event = all_events[index]
    if event.tabId == tab_id then
      events[#events + 1] = event
    end
  end
  return events
end

local function index_of(events, event_type, predicate)
  for index, event in ipairs(events) do
    if event.type == event_type and (predicate == nil or predicate(event)) then
      return index
    end
  end
  return nil
end

local function open_tab(name)
  local tab_id = string.format("nvim-%s-%d-%s", name, vim.fn.getpid(), tostring(vim.uv.hrtime()))
  local opened, open_err = lifecycle:open(tab_id, {
    title = "Neovim " .. name .. " integration",
    workDir = work_dir,
  })
  assert(opened, open_err)
  wait_for(function()
    return lifecycle:status(tab_id).state == "confirmed" and registry_has(tab_id)
  end, 10000, name .. " tabs_state confirmation")
  return tab_id
end

local function run_options(name)
  local options = {
    autoCommit = false,
    maxBudget = 0.35,
    taskId = string.format("nvim-%s-task-%d-%s", name, vim.fn.getpid(), tostring(vim.uv.hrtime())),
    useParallel = false,
    useWorktree = false,
    webTools = false,
    workDir = work_dir,
  }
  if type(model) == "string" and model ~= "" then
    options.model = model
  end
  return options
end

local function wait_running(tab_id)
  wait_for(function()
    local tab = controller.state.tabs[tab_id]
    return tab and tab.running == true
  end, 10000, tab_id .. " status running=true")
end

local function wait_terminal(tab_id)
  wait_for(function()
    local tab = controller.state.tabs[tab_id]
    return tab and tab.running == false and tab.lifecycle ~= nil
  end, timeout, tab_id .. " terminal lifecycle and running=false")
end

local function close_tab(tab_id)
  local closed, close_err = actions:close_tab(tab_id)
  assert(closed, close_err)
  wait_for(function()
    return not registry_has(tab_id)
  end, 10000, tab_id .. " close confirmation")
end

local function assert_common_order(events, expected_lifecycle)
  local start_index = assert(index_of(events, "status", function(event) return event.running == true end),
    "missing status running=true")
  local settings_index = assert(index_of(events, "task_settings"), "missing task_settings")
  local result_index = assert(index_of(events, "result"), "missing result")
  local lifecycle_index = assert(index_of(events, expected_lifecycle), "missing " .. expected_lifecycle)
  local end_index = assert(index_of(events, "status", function(event) return event.running == false end),
    "missing status running=false")
  assert(start_index < settings_index, "task_settings preceded running=true")
  assert(settings_index < result_index, "result preceded task_settings")
  assert(result_index < lifecycle_index, expected_lifecycle .. " did not follow result")
  assert(lifecycle_index < end_index, "running=false did not follow " .. expected_lifecycle)
  return {
    start_index = start_index,
    settings_index = settings_index,
    result_index = result_index,
    lifecycle_index = lifecycle_index,
    end_index = end_index,
  }
end

local function steering_test()
  local first_index = #all_events + 1
  local tab_id = open_tab("steering")
  local marker = "STEERING_ACK_" .. tostring(vim.uv.hrtime())
  local submitted, submit_err = actions:run(tab_id, table.concat({
    "Read-only repository inspection.",
    "Inspect README.md and run only read-only shell commands.",
    "Do not create, edit, delete, stage, commit, or otherwise modify files.",
    "Summarize repository purpose, then finish.",
  }, " "), run_options("steering"))
  assert(submitted, submit_err)
  wait_running(tab_id)
  wait_for(function()
    local tab = controller.state.tabs[tab_id]
    return tab and tab.task_settings ~= nil
  end, 20000, "live task_settings before steering")

  local steered, steer_err = actions:steer(tab_id,
    "Live steering instruction: include exact marker " .. marker .. " in final response.")
  assert(steered, steer_err)
  wait_terminal(tab_id)

  local events = events_for(tab_id, first_index)
  local order = assert_common_order(events, "task_done")
  local prompt_index = assert(index_of(events, "prompt", function(event)
    return type(event.text) == "string" and event.text:find(marker, 1, true) ~= nil
  end), "daemon did not echo steering prompt")
  assert(order.settings_index < prompt_index, "steering echo preceded task_settings")
  assert(prompt_index < order.result_index, "steering echo arrived after result")
  local result = events[order.result_index]
  local result_text = table.concat({
    type(result.text) == "string" and result.text or "",
    type(result.summary) == "string" and result.summary or "",
  }, "\n")
  assert(result_text:find(marker, 1, true), "result did not reflect steering marker: " .. vim.inspect(result))

  local tab = assert(controller.state.tabs[tab_id], "missing steering state")
  assert(tab.task_settings.task_id == tab.history_task_id, "task_settings task identity mismatch")
  assert(vim.deep_equal(tab.result, result), "state result differs from wire result")
  assert(tab.lifecycle == "task_done", "steering lifecycle mismatch")
  assert(tab.running == false, "steering task still running")
  close_tab(tab_id)
  return tab_id, events
end

local function stop_test()
  local first_index = #all_events + 1
  local tab_id = open_tab("stop")
  local submitted, submit_err = actions:run(tab_id, table.concat({
    "Read-only repository inspection.",
    "Inspect repository files carefully using read-only commands.",
    "Do not create, edit, delete, stage, commit, or otherwise modify files.",
    "Continue examining distinct files and do not finish until you have inspected at least 20 files.",
  }, " "), run_options("stop"))
  assert(submitted, submit_err)
  wait_running(tab_id)
  wait_for(function()
    local tab = controller.state.tabs[tab_id]
    return tab and tab.task_settings ~= nil
  end, 20000, "live task_settings before stop")

  local stopped, stop_err = actions:stop(tab_id)
  assert(stopped, stop_err)
  wait_terminal(tab_id)

  local events = events_for(tab_id, first_index)
  local order = assert_common_order(events, "task_stopped")
  local ack_index = assert(index_of(events, "stop_ack"), "missing stop_ack")
  assert(events[ack_index].accepted == true, "stop was not accepted: " .. vim.inspect(events[ack_index]))
  assert(order.settings_index < ack_index, "stop_ack preceded task_settings")
  assert(ack_index < order.result_index, "stop result preceded stop_ack")
  local result = events[order.result_index]
  assert(result.success == false, "stopped result must report semantic failure: " .. vim.inspect(result))

  local tab = assert(controller.state.tabs[tab_id], "missing stopped state")
  assert(tab.stop_ack and tab.stop_ack.accepted == true, "state lost accepted stop acknowledgment")
  assert(tab.result.success == false, "state lost stopped semantic result")
  assert(tab.lifecycle == "task_stopped", "state lifecycle is not task_stopped")
  assert(tab.running == false, "stopped task still running")
  close_tab(tab_id)
  return tab_id, events
end

local function event_label(event)
  if event.type == "status" then
    return "status(" .. tostring(event.running) .. ")"
  end
  if event.type == "stop_ack" then
    return "stop_ack(" .. tostring(event.accepted) .. ")"
  end
  return event.type
end

local function write_event_log(results)
  local output = assert(io.open(event_log, "w"))
  for scenario, result in pairs(results) do
    for index, event in ipairs(result.events) do
      output:write(vim.json.encode({ scenario = scenario, index = index, event = event }), "\n")
    end
  end
  output:close()
end

local results = {}
local ok, err = xpcall(function()
  assert(controller:connect())
  wait_for(function() return initial_snapshot_seen end, 10000, "initial tabs_state")
  local steering_tab, steering_events = steering_test()
  results.steering = { tab_id = steering_tab, events = steering_events }
  local stop_tab, stop_events = stop_test()
  results.stop = { tab_id = stop_tab, events = stop_events }
  assert(#errors == 0, "controller errors: " .. vim.inspect(errors))
end, debug.traceback)

write_event_log(results)
lifecycle:close()
controller:close()
vim.wait(50)

if not ok then
  io.stderr:write(err .. "\nEVENT_LOG=" .. event_log .. "\n")
  vim.cmd("cquit 1")
end

for _, scenario in ipairs({ "steering", "stop" }) do
  local labels = {}
  for _, event in ipairs(results[scenario].events) do
    labels[#labels + 1] = event_label(event)
  end
  print("PASS real daemon " .. scenario .. ": " .. table.concat(labels, " -> "))
end
print("EVENT_LOG=" .. event_log)
vim.cmd("quit")
