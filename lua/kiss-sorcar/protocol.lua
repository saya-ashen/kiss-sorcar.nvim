local M = {}

local REPLAY_SAFE = {
  activeTasksQuery = true,
  getAdjacentTask = true,
  getConfig = true,
  getDefaultModel = true,
  getFrequentTasks = true,
  getHistory = true,
  getInputHistory = true,
  getModels = true,
  getWelcomeSuggestions = true,
  readKissConfig = true,
  ready = true,
  setWorkDir = true,
}

local REQUIRED = {
  appendUserMessage = { "prompt", "tabId" },
  openTab = { "tabId" },
  resumeSession = { "chatId", "tabId", "taskId" },
  run = { "prompt", "tabId" },
  userAnswer = { "answer", "tabId" },
  worktreeAction = { "action", "tabId" },
}

---Decode one complete NDJSON payload.
---@param line string JSON bytes without trailing newline
---@return table|nil event
---@return string|nil error
function M.decode(line)
  if type(line) ~= "string" or line == "" then
    return nil, "empty frame"
  end

  local ok, value = pcall(vim.json.decode, line)
  if not ok then
    return nil, "invalid JSON: " .. tostring(value)
  end
  if type(value) ~= "table" or vim.islist(value) then
    return nil, "frame must be a JSON object"
  end
  if type(value.type) ~= "string" or value.type == "" then
    return nil, "frame.type must be a non-empty string"
  end
  return value, nil
end

---Encode one command as an NDJSON frame.
---@param command table
---@return string|nil frame
---@return string|nil error
function M.encode(command)
  local valid, err = M.validate_command(command)
  if not valid then
    return nil, err
  end
  local ok, json = pcall(vim.json.encode, command)
  if not ok then
    return nil, "cannot encode command: " .. tostring(json)
  end
  return json .. "\n", nil
end

---Return whether command is explicitly safe to recreate after reconnect.
---Transport still stores no commands; caller must build a fresh read request.
---@param command table|string
---@return boolean
function M.is_replay_safe(command)
  local command_type = type(command) == "table" and command.type or command
  return REPLAY_SAFE[command_type] == true
end

---Return whether automatic replay must be forbidden.
---Unknown commands default unsafe so protocol additions cannot gain replay implicitly.
---@param command table|string
---@return boolean
function M.is_effectful(command)
  return not M.is_replay_safe(command)
end

---Validate fields needed by harness command builders.
---@param command table
---@return boolean valid
---@return string|nil error
function M.validate_command(command)
  if type(command) ~= "table" or vim.islist(command) then
    return false, "command must be a table"
  end
  if type(command.type) ~= "string" or command.type == "" then
    return false, "command.type must be a non-empty string"
  end
  for _, field in ipairs(REQUIRED[command.type] or {}) do
    if command[field] == nil then
      return false, command.type .. "." .. field .. " is required"
    end
  end
  return true, nil
end

return M
