local M = {}

local LIFECYCLE = {
  task_done = true,
  task_error = true,
  task_interrupted = true,
  task_stopped = true,
}

local WORKTREE = {
  worktree_created = true,
  worktree_done = true,
  worktree_progress = true,
  worktree_result = true,
}

local ROUTED = {
  askUser = true,
  askUserDone = true,
  clear = true,
  error = true,
  prompt = true,
  result = true,
  status = true,
  stop_ack = true,
  system_output = true,
  system_prompt = true,
  task_events = true,
  task_settings = true,
  text_delta = true,
  text_end = true,
  thinking_delta = true,
  thinking_end = true,
  thinking_start = true,
  tool_call = true,
  tool_result = true,
  usage_info = true,
}
for event_type in pairs(LIFECYCLE) do
  ROUTED[event_type] = true
end
for event_type in pairs(WORKTREE) do
  ROUTED[event_type] = true
end

local State = {}
State.__index = State

---Create empty protocol state.
---@param options? table {unknown_limit=integer}
---@return table
function State.new(options)
  options = options or {}
  return setmetatable({
    connection = { connected = false, generation = 0, stale = true },
    registry_generation = 0,
    tabs = {},
    unknown = {},
    unknown_limit = options.unknown_limit or 32,
  }, State)
end

local function tab_for(self, tab_id)
  local tab = self.tabs[tab_id]
  if not tab then
    tab = {
      lifecycle = nil,
      pending_question = nil,
      result = nil,
      running = false,
      running_generation = 0,
      transcript = {},
      worktrees = {},
    }
    self.tabs[tab_id] = tab
  end
  return tab
end

local function route(event)
  if type(event.tabId) == "string" and event.tabId ~= "" then
    return event.tabId
  end
  return nil
end

local function remember_unknown(self, event)
  self.unknown[#self.unknown + 1] = event
  if #self.unknown > self.unknown_limit then
    table.remove(self.unknown, 1)
  end
end

local function reset_task(tab)
  tab.error = nil
  tab.history_task_id = nil
  tab.lifecycle = nil
  tab.lifecycle_event = nil
  tab.lifecycle_generation = nil
  tab.pending_question = nil
  tab.result = nil
  tab.submission_id = nil
  tab.stop_ack = nil
  tab.task_settings = nil
  tab.task_settings_event = nil
  tab.transcript = {}
end

local function apply_task_settings(tab, event)
  tab.task_settings_event = event
  tab.task_settings = type(event.settings) == "table" and event.settings or {}
  local settings = tab.task_settings
  if type(settings.task_id) == "string" and settings.task_id ~= "" then
    tab.history_task_id = settings.task_id
  elseif type(event.taskId) == "string" and event.taskId ~= "" then
    tab.history_task_id = event.taskId
  end
  if type(settings.chat_id) == "string" and settings.chat_id ~= "" then
    tab.chat_id = settings.chat_id
  end
end

local function derive_replay(tab, events, generation)
  tab.result = nil
  tab.lifecycle = nil
  tab.lifecycle_event = nil
  tab.lifecycle_generation = nil
  tab.transcript_generation = generation
  tab.pending_question = nil
  tab.stop_ack = nil
  tab.task_settings = nil
  tab.task_settings_event = nil
  for _, nested in ipairs(events) do
    if nested.type == "task_settings" then
      apply_task_settings(tab, nested)
    elseif nested.type == "error" then
      tab.error = nested
    elseif nested.type == "stop_ack" then
      tab.stop_ack = nested
    elseif nested.type == "result" then
      tab.result = nested
    elseif LIFECYCLE[nested.type] then
      tab.lifecycle = nested.type
      tab.lifecycle_event = nested
      tab.lifecycle_generation = generation
      tab.running = false
    elseif nested.type == "askUser" then
      tab.pending_question = nested.question
      tab.question_generation = generation
    elseif nested.type == "askUserDone" then
      tab.pending_question = nil
      tab.question_generation = generation
    end
  end
end

---Mark current transport generation connected.
---@param generation integer
function State:connected(generation)
  self.connection = { connected = true, generation = generation, stale = false }
end

---Mark retained state stale without changing task lifecycle.
function State:disconnected()
  self.connection.connected = false
  self.connection.stale = true
end

---Apply one decoded daemon event.
---@param event table
---@return boolean handled
function State:apply(event)
  local event_type = event.type
  local tab_id = route(event)

  if event_type == "tabs_state" then
    local tabs = type(event.tabs) == "table" and event.tabs or {}
    local retained = {}
    for _, registry_tab in ipairs(tabs) do
      if type(registry_tab.tabId) == "string" and self.tabs[registry_tab.tabId] then
        retained[registry_tab.tabId] = self.tabs[registry_tab.tabId]
      end
    end
    self.registry = tabs
    self.registry_generation = self.connection.generation
    self.tabs = retained
    return true
  end
  if event_type == "openTabRejected" or event_type == "history" then
    return true
  end
  if not ROUTED[event_type] then
    remember_unknown(self, event)
    return false
  end
  if not tab_id then
    remember_unknown(self, event)
    return false
  end

  local tab = tab_for(self, tab_id)
  if event_type == "status" then
    tab.running = event.running == true
    tab.running_generation = self.connection.generation
    tab.submission_id = event.taskId or tab.submission_id
  elseif event_type == "stop_ack" then
    tab.stop_ack = event
  elseif event_type == "error" then
    tab.error = event
  elseif event_type == "result" then
    tab.result = event
    tab.transcript[#tab.transcript + 1] = event
    tab.transcript_generation = self.connection.generation
  elseif event_type == "task_settings" then
    apply_task_settings(tab, event)
    tab.transcript[#tab.transcript + 1] = event
    tab.transcript_generation = self.connection.generation
  elseif LIFECYCLE[event_type] then
    tab.lifecycle = event_type
    tab.lifecycle_event = event
    tab.lifecycle_generation = self.connection.generation
    tab.pending_question = nil
  elseif event_type == "askUser" then
    tab.pending_question = event.question
    tab.question_generation = self.connection.generation
  elseif event_type == "askUserDone" then
    tab.pending_question = nil
    tab.question_generation = self.connection.generation
  elseif event_type == "task_events" then
    tab.chat_id = event.chat_id
    tab.history_task_id = event.task_id
    tab.transcript = type(event.events) == "table" and event.events or {}
    derive_replay(tab, tab.transcript, self.connection.generation)
  elseif event_type == "clear" then
    tab.chat_id = event.chat_id
    reset_task(tab)
    tab.transcript_generation = self.connection.generation
  elseif event_type == "thinking_start" or event_type == "thinking_delta" or event_type == "thinking_end"
      or event_type == "text_delta" or event_type == "text_end" or event_type == "prompt"
      or event_type == "system_output" or event_type == "system_prompt"
      or event_type == "tool_call" or event_type == "tool_result"
      or event_type == "usage_info" then
    tab.transcript[#tab.transcript + 1] = event
    tab.transcript_generation = self.connection.generation
  elseif WORKTREE[event_type] then
    local task_id = event.taskId
    if type(task_id) ~= "string" or task_id == "" then
      task_id = tab.history_task_id
    end
    if type(task_id) ~= "string" or task_id == "" then
      remember_unknown(self, event)
      return false
    end
    local worktree = tab.worktrees[task_id] or { task_id = task_id }
    worktree.last_event = event
    worktree.status = event_type
    -- Protocol supplies no replay/live marker or ownership token; historical worktree_done must fail closed.
    worktree.pending_action = false
    worktree.worktree_dir = event.worktreeDir or worktree.worktree_dir
    worktree.worktree_work_dir = event.worktreeWorkDir or worktree.worktree_work_dir
    tab.worktrees[task_id] = worktree
  else
    remember_unknown(self, event)
    return false
  end
  return true
end

M.State = State

return M
