local TabLifecycle = {}
TabLifecycle.__index = TabLifecycle

local OPEN_OPTIONS = { title = true, workDir = true }

local function canonical_tab(state, tab_id)
  if state.registry_generation ~= state.connection.generation then
    return false
  end
  for _, tab in ipairs(state.registry or {}) do
    if tab.tabId == tab_id then
      return true
    end
  end
  return false
end

---Create connected-only open-tab lifecycle manager.
---@param controller table Connection controller owning state, send(), and add_listener().
---@return table
function TabLifecycle.new(controller)
  assert(type(controller) == "table", "controller required")
  assert(type(controller.state) == "table", "controller state required")
  assert(type(controller.send) == "function", "controller send required")
  assert(type(controller.add_listener) == "function", "controller listener support required")
  local self = setmetatable({ attempts = {}, controller = controller, listeners = {} }, TabLifecycle)
  self.unsubscribe = controller:add_listener(function(event, generation)
    self:_event(event, generation)
  end)
  return self
end

---Observe open-attempt state changes.
---@param listener fun(tab_id:string,status:table)
---@return function unsubscribe
function TabLifecycle:add_listener(listener)
  assert(type(listener) == "function", "listener required")
  local entry = { callback = listener }
  self.listeners[#self.listeners + 1] = entry
  return function()
    entry.callback = nil
  end
end

function TabLifecycle:_notify(tab_id)
  local status = self:status(tab_id)
  for _, entry in ipairs(self.listeners) do
    if entry.callback then
      local ok, err = pcall(entry.callback, tab_id, status)
      if not ok and type(self.controller.on_error) == "function" then
        self.controller.on_error(err)
      end
    end
  end
end

---Submit one connected openTab command without creating canonical local state.
---@param tab_id string
---@param options? table Verified optional fields: title and workDir.
---@return boolean accepted
---@return string|nil error
function TabLifecycle:open(tab_id, options)
  local state = self.controller.state
  if not state.connection.connected then
    return false, "disconnected; command not submitted"
  end
  if type(tab_id) ~= "string" or tab_id == "" then
    return false, "tab_id must be a non-empty string"
  end
  if options ~= nil and (type(options) ~= "table" or vim.islist(options)) then
    return false, "options must be a table"
  end
  if canonical_tab(state, tab_id) then
    return false, "tab already canonical: " .. tab_id
  end
  local attempt = self.attempts[tab_id]
  if attempt and attempt.generation == state.connection.generation then
    return false, "openTab already attempted in this generation: " .. tab_id
  end

  local command = { type = "openTab", tabId = tab_id }
  for key, value in pairs(options or {}) do
    if not OPEN_OPTIONS[key] then
      return false, "unsupported openTab option: " .. tostring(key)
    end
    if type(value) ~= "string" or (key == "workDir" and value == "") then
      return false, key .. " must be " .. (key == "workDir" and "a non-empty string" or "a string")
    end
    command[key] = value
  end
  attempt = {
    confirmations = 0,
    generation = state.connection.generation,
    state = "pending",
  }
  self.attempts[tab_id] = attempt
  local accepted, err = self.controller:send(command, function(write_err)
    if write_err and self.attempts[tab_id] == attempt and attempt.state == "pending" then
      attempt.state = "write_failed"
      attempt.text = write_err
      self:_notify(tab_id)
    end
  end)
  if not accepted then
    self.attempts[tab_id] = nil
    return false, err
  end
  return true, nil
end

---Return open attempt state without making tab canonical.
---@param tab_id string
---@return table
function TabLifecycle:status(tab_id)
  local attempt = self.attempts[tab_id]
  if not attempt then
    return { confirmations = 0, state = "none" }
  end
  return vim.deepcopy(attempt)
end

---Stop observing controller events.
function TabLifecycle:close()
  if self.unsubscribe then
    self.unsubscribe()
    self.unsubscribe = nil
  end
end

function TabLifecycle:_event(event, generation)
  if event.type == "connection_disconnected" then
    for _, attempt in pairs(self.attempts) do
      if attempt.generation == generation and attempt.state == "pending" then
        attempt.state = "stale"
      end
    end
    return
  end

  if event.type == "openTabRejected" then
    local attempt = self.attempts[event.tabId]
    if attempt and attempt.generation == generation and attempt.state == "pending" then
      attempt.state = "rejected"
      attempt.text = event.text
    end
    return
  end

  if event.type ~= "tabs_state" then
    return
  end
  for tab_id, attempt in pairs(self.attempts) do
    if attempt.generation == generation and attempt.state == "pending"
        and canonical_tab(self.controller.state, tab_id) then
      attempt.state = "confirmed"
      attempt.confirmations = 1
    end
  end
end

return { TabLifecycle = TabLifecycle }
