local UI = {}
UI.__index = UI

local DISPLAY_EVENTS = {
  result = "Result (not lifecycle completion)",
  system_output = "System output",
  text_delta = "Response",
  thinking_delta = "Thinking",
  tool_call = "Tool call",
  tool_result = "Tool result",
}

local function add_text(lines, text)
  text = tostring(text or "")
  local parts = vim.split(text, "\n", { plain = true })
  vim.list_extend(lines, parts)
end

local function event_text(event)
  for _, key in ipairs({ "text", "summary", "content", "prompt", "question", "error", "message" }) do
    if event[key] ~= nil then
      return type(event[key]) == "string" and event[key] or vim.inspect(event[key])
    end
  end
  return ""
end

local function generation_label(generation, current)
  if generation == current then
    return "current-generation confirmed"
  end
  if generation and generation > 0 then
    return "retained/stale from generation " .. generation
  end
  return "unconfirmed"
end

local function task_status(tab, generation)
  if not tab then
    return "none (unconfirmed)"
  end
  if tab.running then
    return "running (" .. generation_label(tab.running_generation, generation) .. ")"
  end
  if tab.running_generation == generation then
    if tab.lifecycle_generation == generation and tab.lifecycle then
      return tab.lifecycle .. " (current-generation confirmed)"
    end
    return "idle (current-generation confirmed)"
  end
  if tab.lifecycle then
    return tab.lifecycle .. " (" .. generation_label(tab.lifecycle_generation, generation) .. ")"
  end
  return "unknown (retained state insufficient)"
end

---Create minimal native scratch-buffer UI.
---@param options table {controller:table,actions:table,tab_lifecycle:table,work_dir:string,errors?:table,tab_id?:string}
---@return table
function UI.new(options)
  assert(type(options) == "table", "options required")
  assert(type(options.controller) == "table", "controller required")
  assert(type(options.actions) == "table", "actions required")
  assert(type(options.tab_lifecycle) == "table", "tab_lifecycle required")
  local self = setmetatable({
    actions = options.actions,
    controller = options.controller,
    errors = options.errors or {},
    local_prompts = {},
    pending_prompt = nil,
    render_pending = false,
    run_options = options.run_options or {},
    tab_id = options.tab_id or ("nvim-" .. vim.fn.getpid() .. "-" .. tostring(vim.uv.hrtime())),
    tab_lifecycle = options.tab_lifecycle,
    work_dir = options.work_dir,
  }, UI)
  self.unsubscribe = self.controller:add_listener(function()
    self:_schedule_update()
  end)
  self.unsubscribe_lifecycle = self.tab_lifecycle:add_listener(function(tab_id)
    if tab_id == self.tab_id then
      self:_schedule_update()
    end
  end)
  return self
end

---Open or focus normal scratch-buffer client view.
---@return integer buffer
function UI:open()
  if not self.buffer or not vim.api.nvim_buf_is_valid(self.buffer) then
    self.buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(self.buffer, "kiss-sorcar://client/" .. self.tab_id)
    vim.bo[self.buffer].buftype = "nofile"
    vim.bo[self.buffer].bufhidden = "hide"
    vim.bo[self.buffer].swapfile = false
    vim.bo[self.buffer].filetype = "kiss-sorcar"
    vim.keymap.set("n", "i", function()
      self:compose("task")
    end, { buffer = self.buffer, desc = "Compose Sorcar task" })
    vim.keymap.set("n", "a", function()
      self:compose("steer")
    end, { buffer = self.buffer, desc = "Compose Sorcar steering message" })
    vim.keymap.set("n", "I", function()
      self:prompt()
    end, { buffer = self.buffer, desc = "Start Sorcar task with one-line fallback" })
    vim.keymap.set("n", "s", function()
      self:stop()
    end, { buffer = self.buffer, desc = "Stop Sorcar task" })
  end
  vim.api.nvim_set_current_buf(self.buffer)
  self:render()
  return self.buffer
end

---Open editable multiline composer for task or steering text.
---@param kind? "task"|"steer"
---@return integer|nil buffer
---@return string|nil error
function UI:compose(kind)
  kind = kind or "task"
  if kind ~= "task" and kind ~= "steer" then
    return nil, "composer kind must be task or steer"
  end
  if self.composer_buffer and vim.api.nvim_buf_is_valid(self.composer_buffer) then
    if self.composer_kind ~= kind then
      return nil, "composer already open for " .. self.composer_kind
    end
    vim.api.nvim_set_current_buf(self.composer_buffer)
    return self.composer_buffer, nil
  end

  local buffer = vim.api.nvim_create_buf(false, true)
  self.composer_buffer = buffer
  self.composer_kind = kind
  self.composer_return_buffer = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(buffer, "kiss-sorcar://compose/" .. kind .. "/" .. self.tab_id)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].filetype = "kiss-sorcar-compose"
  vim.bo[buffer].modifiable = true
  vim.bo[buffer].readonly = false
  local function submit_mapping()
    local accepted, err = self:submit_composer()
    if not accepted and err then
      vim.notify("Sorcar: " .. err, vim.log.levels.ERROR)
    end
  end
  vim.keymap.set({ "n", "i" }, "<C-s>", submit_mapping,
    { buffer = buffer, desc = "Submit Sorcar composer" })
  vim.keymap.set("n", "<CR>", submit_mapping,
    { buffer = buffer, desc = "Submit Sorcar composer" })
  vim.keymap.set({ "n", "i" }, "<C-c>", function()
    local closed, err = self:cancel_composer()
    if not closed and err then
      vim.notify("Sorcar: " .. err, vim.log.levels.ERROR)
    end
  end, { buffer = buffer, desc = "Cancel Sorcar composer" })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buffer,
    callback = function()
      if self.composer_buffer == buffer then
        self.composer_buffer = nil
        self.composer_kind = nil
        self.composer_pending = nil
        self.composer_return_buffer = nil
      end
    end,
    once = true,
  })
  vim.api.nvim_set_current_buf(buffer)
  vim.cmd("startinsert")
  return buffer, nil
end

---Submit current composer text through task lifecycle or guarded steering action.
---@return boolean accepted
---@return string|nil error
function UI:submit_composer()
  local buffer = self.composer_buffer
  if not buffer or not vim.api.nvim_buf_is_valid(buffer) then
    return false, "composer is not open"
  end
  local text = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
  if text:match("^%s*$") then
    local err = "prompt must be a non-empty string"
    self:_error(err)
    self:render()
    return false, err
  end
  local accepted, err
  if self.composer_kind == "steer" then
    accepted, err = self:steer(text)
  else
    accepted, err = self:submit(text)
  end
  if accepted then
    if self.composer_kind == "task" and self.pending_prompt then
      self.composer_pending = true
    else
      self:_close_composer()
    end
  end
  return accepted, err
end

---Cancel current composer without submitting text.
---@return boolean closed
---@return string|nil error
function UI:cancel_composer()
  if not self.composer_buffer or not vim.api.nvim_buf_is_valid(self.composer_buffer) then
    return false, "composer is not open"
  end
  if self.composer_pending then
    return false, "task submission is pending; draft cannot be cancelled"
  end
  self:_close_composer()
  return true, nil
end

---Prompt for one-line task text fallback, then submit through lifecycle/actions.
function UI:prompt()
  vim.ui.input({ prompt = "Sorcar task: " }, function(value)
    if value and value ~= "" then
      self:submit(value)
    end
  end)
end

---Start one task, opening canonical daemon tab first when needed.
---@param prompt string
---@return boolean accepted
---@return string|nil error
function UI:submit(prompt)
  if type(prompt) ~= "string" or prompt == "" then
    return false, "prompt must be a non-empty string"
  end
  if self.pending_prompt then
    return false, "task submission already pending"
  end
  local state = self.controller.state
  local canonical = state.registry_generation == state.connection.generation
  if canonical then
    for _, entry in ipairs(state.registry or {}) do
      if entry.tabId == self.tab_id then
        local tab = state.tabs[self.tab_id]
        if tab and tab.running then
          return false, "task already running: " .. self.tab_id
        end
        if tab and tab.running_generation ~= state.connection.generation then
          return false, "task state is stale: " .. self.tab_id
        end
        local options = vim.tbl_extend("force", self.run_options, { workDir = self.work_dir })
        local accepted, err = self.actions:run(self.tab_id, prompt, options)
        if accepted then
          self:_record_prompt(prompt, "task submitted locally; daemon delivery not inferred")
        else
          self:_error(err)
        end
        self:render()
        return accepted, err
      end
    end
  end

  self.pending_prompt = prompt
  local accepted, err = self.tab_lifecycle:open(self.tab_id, {
    title = "Sorcar · " .. vim.fn.fnamemodify(self.work_dir, ":t"),
    workDir = self.work_dir,
  })
  if not accepted then
    self.pending_prompt = nil
    self:_error(err)
  end
  self:render()
  return accepted, err
end

---Stop current task through guarded action facade.
---@return boolean accepted
---@return string|nil error
function UI:stop()
  local accepted, err = self.actions:stop(self.tab_id)
  if not accepted then
    self:_error(err)
  end
  self:render()
  return accepted, err
end

---Steer current task through guarded action facade.
---@param prompt string
---@return boolean accepted
---@return string|nil error
function UI:steer(prompt)
  local accepted, err = self.actions:steer(self.tab_id, prompt)
  if accepted then
    self:_record_prompt(prompt, "steering submitted locally; daemon delivery unconfirmed")
  else
    self:_error(err)
  end
  self:render()
  return accepted, err
end

---Render complete state snapshot into scratch buffer.
function UI:render()
  if not self.buffer or not vim.api.nvim_buf_is_valid(self.buffer) then
    return
  end
  local state = self.controller.state
  local connection = state.connection
  local tab = state.tabs[self.tab_id]
  local connection_text = connection.connected
      and ("connected · generation " .. connection.generation)
      or ("disconnected · retained state stale · generation " .. connection.generation)
  local current_generation = connection.connected and connection.generation or -1
  local registry_text = state.registry_generation == connection.generation and connection.connected
      and "current-generation confirmed"
      or "retained/stale or awaiting tabs_state"
  local transcript_text = tab and generation_label(tab.transcript_generation, current_generation) or "unconfirmed"
  local lines = {
    "KISS Sorcar",
    "Connection: " .. connection_text,
    "Workspace:  " .. self.work_dir,
    "Tab state:  " .. registry_text,
    "Task:       " .. task_status(tab, current_generation),
    "Transcript: " .. transcript_text,
    "",
    "Commands: :Sorcar {task}  :SorcarStop  :SorcarSteer {message}",
    "Keys: i compose task  a compose steering  I one-line task  s stop",
    "Composer: <C-s> submit  <CR> submit (Normal)  <C-c> cancel",
    "",
  }

  if self.pending_prompt then
    lines[#lines + 1] = "[opening daemon tab; task not submitted yet]"
    lines[#lines + 1] = ""
  end
  for _, prompt in ipairs(self.local_prompts) do
    lines[#lines + 1] = "## Prompt"
    add_text(lines, prompt.text)
    lines[#lines + 1] = "[" .. prompt.status .. "]"
  end
  local last_label
  for _, event in ipairs((tab and tab.transcript) or {}) do
    local label = DISPLAY_EVENTS[event.type]
    if label then
      if label ~= last_label then
        lines[#lines + 1] = "## " .. label
        last_label = label
      end
      local text = event_text(event)
      add_text(lines, text ~= "" and text or vim.inspect(event))
    elseif event.type == "thinking_start" then
      lines[#lines + 1] = "## Thinking"
      last_label = "Thinking"
    elseif event.type == "thinking_end" or event.type == "text_end" then
      lines[#lines + 1] = ""
      last_label = nil
    elseif event.type == "usage_info" then
      lines[#lines + 1] = "[usage] " .. vim.inspect(event)
      last_label = nil
    end
  end
  if tab and tab.lifecycle_event then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Lifecycle"
    lines[#lines + 1] = tab.lifecycle
    local text = event_text(tab.lifecycle_event)
    if text ~= "" then
      add_text(lines, text)
    end
  end
  if tab and tab.stop_ack then
    lines[#lines + 1] = "[stop acknowledgment] " .. vim.inspect(tab.stop_ack)
  end
  if tab and tab.error then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Errors"
    add_text(lines, event_text(tab.error))
  end
  if #self.errors > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Errors"
    for _, message in ipairs(self.errors) do
      lines[#lines + 1] = tostring(message)
    end
  end

  local safe_lines = {}
  for _, line in ipairs(lines) do
    add_text(safe_lines, line:gsub("\r", ""))
  end
  local cursors = {}
  for _, window in ipairs(vim.fn.win_findbuf(self.buffer)) do
    cursors[window] = vim.api.nvim_win_get_cursor(window)
  end
  vim.bo[self.buffer].modifiable = true
  vim.api.nvim_buf_set_lines(self.buffer, 0, -1, false, safe_lines)
  vim.bo[self.buffer].modifiable = false
  for window, cursor in pairs(cursors) do
    if vim.api.nvim_win_is_valid(window) then
      cursor[1] = math.min(cursor[1], #safe_lines)
      vim.api.nvim_win_set_cursor(window, cursor)
    end
  end
end

function UI:_close_composer()
  local buffer = self.composer_buffer
  local return_buffer = self.composer_return_buffer
  self.composer_buffer = nil
  self.composer_kind = nil
  self.composer_pending = nil
  self.composer_return_buffer = nil
  if buffer and vim.api.nvim_buf_is_valid(buffer) then
    vim.api.nvim_buf_delete(buffer, { force = true })
  end
  if return_buffer and vim.api.nvim_buf_is_valid(return_buffer) then
    vim.api.nvim_set_current_buf(return_buffer)
  elseif self.buffer and vim.api.nvim_buf_is_valid(self.buffer) then
    vim.api.nvim_set_current_buf(self.buffer)
  end
end

---Dispose listeners and scratch buffers.
function UI:close()
  if self.composer_buffer and vim.api.nvim_buf_is_valid(self.composer_buffer) then
    self:_close_composer()
  end
  if self.unsubscribe then
    self.unsubscribe()
    self.unsubscribe = nil
  end
  if self.unsubscribe_lifecycle then
    self.unsubscribe_lifecycle()
    self.unsubscribe_lifecycle = nil
  end
  if self.buffer and vim.api.nvim_buf_is_valid(self.buffer) then
    vim.api.nvim_buf_delete(self.buffer, { force = true })
  end
  self.buffer = nil
end

function UI:_error(err)
  if err then
    self.errors[#self.errors + 1] = tostring(err)
  end
end

function UI:_record_prompt(text, status)
  self.local_prompts[#self.local_prompts + 1] = { status = status, text = text }
end

function UI:_schedule_update()
  if self.render_pending then
    return
  end
  self.render_pending = true
  vim.schedule(function()
    self.render_pending = false
    local status = self.tab_lifecycle:status(self.tab_id)
    if self.pending_prompt and status.state == "confirmed" then
      local prompt = self.pending_prompt
      self.pending_prompt = nil
      local options = vim.tbl_extend("force", self.run_options, { workDir = self.work_dir })
      local accepted, err = self.actions:run(self.tab_id, prompt, options)
      if accepted then
        self:_record_prompt(prompt, "task submitted locally; daemon delivery not inferred")
        if self.composer_pending then
          self:_close_composer()
        end
      else
        self:_error(err)
        self.composer_pending = nil
      end
    elseif self.pending_prompt and status.state ~= "pending" and status.state ~= "none" then
      self.pending_prompt = nil
      self.composer_pending = nil
      self:_error(status.text or ("openTab " .. status.state))
    end
    self:render()
  end)
end

return { UI = UI }
