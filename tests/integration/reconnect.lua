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
local events = {}
local sent_commands = {}

local controller = Controller.new({
  path = socket_path,
  work_dir = work_dir,
  on_error = function(err)
    errors[#errors + 1] = tostring(err)
  end,
})
local lifecycle = TabLifecycle.new(controller)
local actions = Actions.new(controller)
local original_send = controller.send
controller.send = function(self, command, callback)
  sent_commands[#sent_commands + 1] = vim.deepcopy(command)
  return original_send(self, command, callback)
end
controller:add_listener(function(event, generation)
  events[#events + 1] = { event = vim.deepcopy(event), generation = generation }
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

local function count_commands(command_type)
  local count = 0
  for _, command in ipairs(sent_commands) do
    if command.type == command_type then
      count = count + 1
    end
  end
  return count
end

local function run_options()
  local options = {
    autoCommit = false,
    maxBudget = 0.25,
    taskId = string.format("nvim-reconnect-task-%d-%s", vim.fn.getpid(), tostring(vim.uv.hrtime())),
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

local function write_log(metadata)
  local output = assert(io.open(event_log, "w"))
  output:write(vim.json.encode({ metadata = metadata }), "\n")
  for index, item in ipairs(events) do
    output:write(vim.json.encode({ index = index, generation = item.generation, event = item.event }), "\n")
  end
  output:close()
end

local metadata = {}
local ok, err = xpcall(function()
  assert(controller:connect())
  wait_for(function()
    return controller.state.connection.connected
      and controller.state.registry_generation == controller.state.connection.generation
  end, 10000, "initial tabs_state")

  local tab_id = string.format("nvim-reconnect-%d-%s", vim.fn.getpid(), tostring(vim.uv.hrtime()))
  metadata.tab_id = tab_id
  local opened, open_err = lifecycle:open(tab_id, {
    title = "Neovim reconnect integration",
    workDir = work_dir,
  })
  assert(opened, open_err)
  wait_for(function()
    return lifecycle:status(tab_id).state == "confirmed" and registry_has(tab_id)
  end, 10000, "openTab confirmation")

  local submitted, submit_err = actions:run(tab_id, table.concat({
    "Read-only repository inspection.",
    "Run one command: `sleep 8; git status --short; git log -1 --oneline`.",
    "Do not create, edit, delete, stage, commit, or otherwise modify files.",
    "After command completes, report exact output and finish immediately.",
  }, " "), run_options())
  assert(submitted, submit_err)
  wait_for(function()
    local tab = controller.state.tabs[tab_id]
    if not (tab and tab.running == true and tab.task_settings ~= nil) then
      return false
    end
    for _, event in ipairs(tab.transcript) do
      if event.type == "thinking_delta" then
        return true
      end
    end
    return false
  end, 30000, "running task with persisted settings and live stream state")

  local old_generation = controller.state.connection.generation
  local old_tab = assert(controller.state.tabs[tab_id])
  local old_task_id = assert(old_tab.history_task_id, "missing pre-disconnect persisted task ID")
  local old_chat_id = assert(old_tab.chat_id, "missing pre-disconnect chat ID")
  local disconnect_event_index = #events
  metadata.old_generation = old_generation
  metadata.task_id = old_task_id
  metadata.chat_id = old_chat_id
  metadata.pre_disconnect_events = disconnect_event_index

  controller:close()
  wait_for(function()
    return controller.state.connection.stale and not controller.state.connection.connected
  end, 5000, "intentional client-only disconnect")
  assert(controller.state.tabs[tab_id].running == true, "disconnect invented terminal running state")
  assert(controller.state.tabs[tab_id].running_generation == old_generation, "disconnect refreshed running evidence")
  local disconnected_stop, disconnected_stop_err = actions:stop(tab_id)
  assert(disconnected_stop == false and disconnected_stop_err == "disconnected; command not submitted",
    "stop did not fail closed while disconnected: " .. tostring(disconnected_stop_err))

  assert(controller:connect())
  wait_for(function()
    return controller.state.connection.connected and controller.state.connection.generation ~= old_generation
  end, 10000, "fresh reconnect generation")
  local new_generation = controller.state.connection.generation
  metadata.new_generation = new_generation
  local reconnect_event_index = #events
  metadata.reconnect_event_index = reconnect_event_index

  assert(controller.state.tabs[tab_id].running_generation ~= new_generation,
    "running state guessed current before daemon evidence")
  local pre_snapshot_stop, pre_snapshot_stop_err = actions:stop(tab_id)
  assert(pre_snapshot_stop == false and pre_snapshot_stop_err == "unknown or stale tab: " .. tab_id,
    "action did not fail closed before fresh tabs_state: " .. tostring(pre_snapshot_stop_err))

  local stale_accepted = controller:receive(vim.json.encode({
    type = "status",
    tabId = tab_id,
    running = false,
  }), old_generation)
  assert(stale_accepted == false, "stale-generation event accepted")
  controller:_disconnected("late", old_generation)
  assert(controller.state.connection.connected and controller.state.connection.generation == new_generation,
    "stale disconnect callback mutated current connection")

  wait_for(function()
    return controller.state.registry_generation == new_generation and registry_has(tab_id)
  end, 10000, "reconnected tabs_state")
  if controller.state.tabs[tab_id].running_generation ~= new_generation then
    local stale_stop, stale_stop_err = actions:stop(tab_id)
    assert(stale_stop == false and stale_stop_err == "tab running state is stale: " .. tab_id,
      "fresh registry authorized stale running state: " .. tostring(stale_stop_err))
  end

  wait_for(function()
    local tab = controller.state.tabs[tab_id]
    return tab and tab.running == true and tab.running_generation == new_generation
  end, 10000, "current-generation running evidence")
  wait_for(function()
    for index = reconnect_event_index + 1, #events do
      local item = events[index]
      if item.generation == new_generation and item.event.type == "task_events" and item.event.tabId == tab_id then
        return true
      end
    end
    return false
  end, 20000, "replayed task_events")

  local reconstructed = assert(controller.state.tabs[tab_id])
  assert(reconstructed.history_task_id == old_task_id, "replayed task identity mismatch")
  assert(reconstructed.chat_id == old_chat_id, "replayed chat identity mismatch")
  assert(reconstructed.running == true, "running replay caused unsafe terminal transition")
  assert(reconstructed.lifecycle == nil, "running replay invented terminal lifecycle")

  wait_for(function()
    local tab = controller.state.tabs[tab_id]
    return tab and tab.running == false and tab.lifecycle ~= nil
  end, timeout, "final lifecycle and status(false)")
  local final_tab = assert(controller.state.tabs[tab_id])
  assert(final_tab.history_task_id == old_task_id, "final task identity changed")
  assert(final_tab.chat_id == old_chat_id, "final chat identity changed")
  assert(final_tab.lifecycle == "task_done", "unexpected final lifecycle: " .. tostring(final_tab.lifecycle))
  assert(final_tab.running_generation == new_generation, "terminal status lacked current-generation evidence")

  assert(count_commands("run") == 1, "run replayed across reconnect")
  assert(count_commands("openTab") == 1, "openTab replayed across reconnect")
  assert(count_commands("stop") == 0, "rejected stop reached wire")
  assert(count_commands("appendUserMessage") == 0, "unexpected steering command")
  assert(count_commands("userAnswer") == 0, "unexpected answer command")
  assert(count_commands("worktreeAction") == 0, "unexpected worktree command")

  local closed, close_err = actions:close_tab(tab_id)
  assert(closed, close_err)
  wait_for(function()
    return not registry_has(tab_id)
  end, 10000, "close confirmation")
  assert(#errors == 0, "controller errors: " .. vim.inspect(errors))
end, debug.traceback)

metadata.sent_commands = sent_commands
write_log(metadata)
lifecycle:close()
controller:close()
vim.wait(50)

if not ok then
  io.stderr:write(err .. "\nEVENT_LOG=" .. event_log .. "\n")
  vim.cmd("cquit 1")
end

local labels = {}
for _, item in ipairs(events) do
  local event = item.event
  local label = event.type
  if event.type == "status" then
    label = "status(" .. tostring(event.running) .. ")"
  end
  labels[#labels + 1] = string.format("g%d:%s", item.generation, label)
end
print("PASS real daemon reconnect: " .. table.concat(labels, " -> "))
print("EVENT_LOG=" .. event_log)
vim.cmd("quit")
