local Actions = {}
Actions.__index = Actions

local RUN_OPTIONS = {
  activeFile = true,
  agentPath = true,
  appendBasicTools = true,
  appendToPrompt = true,
  appendToSystemPrompt = true,
  attachments = true,
  autoCommit = true,
  chatId = true,
  maxBudget = true,
  model = true,
  modelConfig = true,
  systemPrompt = true,
  tabScopeWorkDir = true,
  taskId = true,
  toolsFile = true,
  useParallel = true,
  useWorktree = true,
  webTools = true,
  workDir = true,
}

local WORKTREE_ACTIONS = { discard = true, merge = true, nothing = true }

local function nonempty(value, name)
  if type(value) ~= "string" or value == "" then
    return false, name .. " must be a non-empty string"
  end
  return true, nil
end

local function has_registry_tab(state, tab_id)
  for _, tab in ipairs(state.registry or {}) do
    if tab.tabId == tab_id then
      return true
    end
  end
  return false
end

---Create connected-only task action facade.
---@param controller table Connection controller owning state and send().
---@return table
function Actions.new(controller)
  assert(type(controller) == "table", "controller required")
  assert(type(controller.state) == "table", "controller state required")
  assert(type(controller.send) == "function", "controller send required")
  return setmetatable({ controller = controller }, Actions)
end

function Actions:_target(tab_id)
  if not self.controller.state.connection.connected then
    return nil, "disconnected; command not submitted"
  end
  local valid, err = nonempty(tab_id, "tab_id")
  if not valid then
    return nil, err
  end
  local state = self.controller.state
  if state.registry_generation ~= state.connection.generation or not has_registry_tab(state, tab_id) then
    return nil, "unknown or stale tab: " .. tab_id
  end
  return self.controller.state.tabs[tab_id], nil
end

function Actions:_send(command)
  return self.controller:send(command)
end

---Start task in exact canonical tab. Command is submitted once and never queued.
---@param tab_id string
---@param prompt string
---@param options? table Additional verified run fields; routing fields cannot be overridden.
---@return boolean accepted
---@return string|nil error
function Actions:run(tab_id, prompt, options)
  local _, target_err = self:_target(tab_id)
  if target_err then
    return false, target_err
  end
  local valid, prompt_err = nonempty(prompt, "prompt")
  if not valid then
    return false, prompt_err
  end
  if options ~= nil and (type(options) ~= "table" or vim.islist(options)) then
    return false, "options must be a table"
  end

  local command = { type = "run", tabId = tab_id, prompt = prompt }
  for key, value in pairs(options or {}) do
    if not RUN_OPTIONS[key] then
      return false, "unsupported run option: " .. tostring(key)
    end
    command[key] = value
  end
  return self:_send(command)
end

---Stop task currently known to run in exact tab.
---@param tab_id string
---@return boolean accepted
---@return string|nil error
function Actions:stop(tab_id)
  local tab, target_err = self:_target(tab_id)
  if target_err then
    return false, target_err
  end
  if not tab or tab.running ~= true then
    return false, "tab is not known to be running: " .. tab_id
  end
  if tab.running_generation ~= self.controller.state.connection.generation then
    return false, "tab running state is stale: " .. tab_id
  end
  return self:_send({ type = "stop", tabId = tab_id })
end

---Append live user message to task currently known to run in exact tab.
---@param tab_id string
---@param prompt string
---@return boolean accepted
---@return string|nil error
function Actions:steer(tab_id, prompt)
  local tab, target_err = self:_target(tab_id)
  if target_err then
    return false, target_err
  end
  if not tab or tab.running ~= true then
    return false, "tab is not known to be running: " .. tab_id
  end
  if tab.running_generation ~= self.controller.state.connection.generation then
    return false, "tab running state is stale: " .. tab_id
  end
  local valid, prompt_err = nonempty(prompt, "prompt")
  if not valid then
    return false, prompt_err
  end
  return self:_send({ type = "appendUserMessage", tabId = tab_id, prompt = prompt })
end

---Answer question currently known to be pending in exact tab.
---@param tab_id string
---@param answer string
---@return boolean accepted
---@return string|nil error
function Actions:answer(tab_id, answer)
  local tab, target_err = self:_target(tab_id)
  if target_err then
    return false, target_err
  end
  if not tab or tab.pending_question == nil then
    return false, "tab has no known pending question: " .. tab_id
  end
  if tab.question_generation ~= self.controller.state.connection.generation then
    return false, "tab question state is stale: " .. tab_id
  end
  if type(answer) ~= "string" then
    return false, "answer must be a string"
  end
  return self:_send({ type = "userAnswer", tabId = tab_id, answer = answer })
end

---Close exact canonical tab without stopping its task.
---@param tab_id string
---@return boolean accepted
---@return string|nil error
function Actions:close_tab(tab_id)
  local _, target_err = self:_target(tab_id)
  if target_err then
    return false, target_err
  end
  return self:_send({ type = "closeTab", tabId = tab_id })
end

---Apply supported action to worktree known for exact current persisted task.
---Task ID is a local stale-target guard; current wire command routes only by tabId.
---@param tab_id string
---@param task_id string
---@param action "merge"|"discard"|"nothing"
---@return boolean accepted
---@return string|nil error
function Actions:worktree_action(tab_id, task_id, action)
  local tab, target_err = self:_target(tab_id)
  if target_err then
    return false, target_err
  end
  local valid, task_err = nonempty(task_id, "task_id")
  if not valid then
    return false, task_err
  end
  if not tab or tab.history_task_id ~= task_id then
    return false, "task is not current for tab: " .. task_id
  end
  local worktree = tab.worktrees and tab.worktrees[task_id]
  if not worktree then
    return false, "tab has no known worktree for task: " .. task_id
  end
  if not WORKTREE_ACTIONS[action] then
    return false, "invalid worktree action: " .. tostring(action)
  end
  -- No wire ownership token, daemon identity, or replay/live marker exists. Mutation cannot be routed safely.
  return false, "worktree action ownership cannot be proven by current protocol"
end

return { Actions = Actions }
