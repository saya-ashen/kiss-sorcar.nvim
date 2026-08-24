local Actions = require("kiss-sorcar.actions").Actions
local Controller = require("kiss-sorcar.controller").Controller
local TabLifecycle = require("kiss-sorcar.tab_lifecycle").TabLifecycle

local Backend = {}
Backend.__index = Backend

local LIFECYCLE_REASON = {
  task_done = "completed",
  task_error = "error",
  task_interrupted = "interrupted",
  task_stopped = "stopped",
}

local DEFAULT_RECONNECT_DELAYS = { 250, 500, 1000, 2000, 5000 }

local function reconnect_delays(options)
  if options.reconnect == false then
    return {}
  end
  local configured = options.reconnect_delays or DEFAULT_RECONNECT_DELAYS
  assert(type(configured) == "table", "reconnect_delays must be a table")
  local delays = {}
  for index, delay in ipairs(configured) do
    assert(type(delay) == "number" and delay >= 0, "reconnect delay must be a non-negative number")
    delays[index] = delay
  end
  return delays
end

local function socket_path(options)
  if type(options.path) == "string" and options.path ~= "" then
    return options.path
  end
  local kiss_home = vim.env.KISS_HOME
  if type(kiss_home) ~= "string" or kiss_home == "" then
    kiss_home = vim.fn.expand("~/.kiss")
  end
  return vim.env.KISS_SORCAR_SOCK or (kiss_home .. "/sorcar.sock")
end

local function canonical(state, tab_id)
  if not state.connection.connected or state.registry_generation ~= state.connection.generation then
    return false
  end
  for _, tab in ipairs(state.registry or {}) do
    if tab.tabId == tab_id then
      return true
    end
  end
  return false
end

local function normalize_history_path(path)
  if type(path) ~= "string" then
    return ""
  end
  local normalized = path:gsub("\\", "/"):gsub("^%./", ""):gsub("/+$", "")
  return normalized == "." and "" or normalized
end

local function history_matches_workspace(item, cwd)
  if item.is_running == true then
    return true
  end
  local history_path = normalize_history_path(item.work_dir)
  if history_path == "" then
    return true
  end
  local workspace = normalize_history_path(cwd)
  if history_path == workspace or history_path:sub(1, #workspace + 1) == workspace .. "/" then
    return true
  end
  local history_name = history_path:match("([^/]+)$")
  local workspace_name = workspace:match("([^/]+)$")
  return history_name ~= nil and history_name == workspace_name
end

local function history_messages(envelope)
  local events = type(envelope.events) == "table" and envelope.events or {}
  local prompt = type(envelope.task) == "string" and envelope.task or ""
  local prompt_ts
  local assistant_ts
  local thinking = {}
  local text = {}
  local result_text = ""
  for _, event in ipairs(events) do
    if event.type == "prompt" and type(event.text) == "string" then
      prompt = event.text
      prompt_ts = event.ts or prompt_ts
    elseif event.type == "thinking_delta" and type(event.text) == "string" and event.text ~= "" then
      thinking[#thinking + 1] = event.text
      assistant_ts = assistant_ts or event.ts
    elseif event.type == "text_delta" and type(event.text) == "string" and event.text ~= "" then
      text[#text + 1] = event.text
      assistant_ts = assistant_ts or event.ts
    elseif event.type == "result" then
      if type(event.text) == "string" and event.text ~= "" then
        result_text = event.text
      elseif type(event.summary) == "string" and event.summary ~= "" then
        result_text = event.summary
      end
      assistant_ts = assistant_ts or event.ts
    end
  end

  local messages = {}
  if prompt ~= "" then
    messages[#messages + 1] = { role = "user", content = prompt, timestamp = prompt_ts }
  end
  local assistant_content = {}
  local thinking_text = table.concat(thinking)
  if thinking_text ~= "" then
    assistant_content[#assistant_content + 1] = { type = "thinking", thinking = thinking_text }
  end
  local answer = table.concat(text)
  if answer == "" then
    answer = result_text
  end
  if answer ~= "" then
    assistant_content[#assistant_content + 1] = { type = "text", text = answer }
  end
  if #assistant_content > 0 then
    messages[#messages + 1] = { role = "assistant", content = assistant_content, timestamp = assistant_ts }
  end
  return messages
end

---Create Agent Workbench BackendSession from tested Sorcar core.
---@param options table
---@return table
function Backend.new(options)
  assert(type(options) == "table", "backend options required")
  assert(type(options.id) == "number", "backend id required")
  assert(type(options.cwd) == "string" and options.cwd ~= "", "backend cwd required")

  local path = socket_path(options)
  local self
  local function on_error(err)
    if options.on_error then
      options.on_error(err)
    end
    if self then
      self:_handle_error(err)
    end
  end
  local controller = options.controller or Controller.new({
    path = path,
    work_dir = options.cwd,
    on_error = on_error,
  })
  self = setmetatable({
    actions = options.actions or Actions.new(controller),
    closed = false,
    controller = controller,
    cwd = options.cwd,
    history_generation = 0,
    history_list_request = nil,
    history_load_request = nil,
    last_connection_error = nil,
    lifecycle = options.tab_lifecycle or TabLifecycle.new(controller),
    on_error = on_error,
    open_confirmed = false,
    path = path,
    phase = "unknown",
    reconnect_attempt = 0,
    reconnect_delays = reconnect_delays(options),
    reconnect_timer = nil,
    run_options = options.run_options or {},
    run_pending = false,
    sink = nil,
    tab_id = options.tab_id or ("agent-workbench-" .. tostring(options.id)),
  }, Backend)
  return self
end

---Return verified Sorcar feature capabilities.
---@return table
function Backend:capabilities()
  return {
    attachments = false,
    changed_files = false,
    commands = false,
    compaction = false,
    direct_bash = false,
    follow_up = false,
    history = true,
    models = false,
    raw_rpc = false,
    thinking = false,
    tree = false,
  }
end

function Backend:_emit(event)
  local sink = self.sink
  if not sink then
    return
  end
  local function deliver()
    if not self.closed and self.sink == sink then
      sink(event)
    end
  end
  if vim.in_fast_event() then
    vim.schedule(deliver)
  else
    deliver()
  end
end

function Backend:_callback(callback, ...)
  local args = { ... }
  local function deliver()
    if not self.closed then
      callback(unpack(args))
    end
  end
  if vim.in_fast_event() then
    vim.schedule(deliver)
  else
    deliver()
  end
end

function Backend:_finish_history_list(items, err)
  local request = self.history_list_request
  self.history_list_request = nil
  if request then
    self:_callback(request.callback, items, err)
  end
end

function Backend:_request_history_page(offset)
  local request = self.history_list_request
  if not request then
    return false, "history request is not pending"
  end
  local ok, err = self.controller:send({
    type = "getHistory",
    generation = request.generation,
    offset = offset,
    query = "",
  })
  if not ok then
    self:_finish_history_list(nil, err)
  end
  return ok, err
end

function Backend:_try_history_list()
  local request = self.history_list_request
  if not request or request.started_generation == self.controller.state.connection.generation then
    return
  end
  if not canonical(self.controller.state, self.tab_id) then
    return
  end
  request.started_generation = self.controller.state.connection.generation
  request.items = {}
  self:_request_history_page(0)
end

function Backend:_history_page(event)
  local request = self.history_list_request
  if not request or event.generation ~= request.generation then
    return
  end
  local page = type(event.sessions) == "table" and event.sessions or {}
  for _, item in ipairs(page) do
    if
      type(item) == "table"
      and type(item.id) == "string"
      and item.id ~= ""
      and type(item.task_id) == "string"
      and item.task_id ~= ""
      and history_matches_workspace(item, self.cwd)
    then
      request.items[#request.items + 1] = vim.deepcopy(item)
    end
  end
  if #page == 50 then
    self:_request_history_page((tonumber(event.offset) or 0) + 50)
  else
    self:_finish_history_list(request.items, nil)
  end
end

function Backend:_finish_history_load(result, err)
  local request = self.history_load_request
  self.history_load_request = nil
  if request then
    self:_callback(request.callback, result, err)
  end
end

function Backend:_try_history_load()
  local request = self.history_load_request
  if not request or request.sent_generation then
    return
  end
  if not canonical(self.controller.state, self.tab_id) then
    return
  end
  local tab = self.controller.state.tabs[self.tab_id]
  if self.run_pending or (tab and tab.running == true) then
    self:_finish_history_load(nil, "cannot resume history while the current Sorcar task is running")
    return
  end
  local ok, err = self.controller:send({
    type = "resumeSession",
    chatId = request.item.id,
    taskId = request.item.task_id,
    tabId = self.tab_id,
    workDir = self.cwd,
  })
  if not ok then
    self:_finish_history_load(nil, err)
    return
  end
  request.sent_generation = self.controller.state.connection.generation
end

function Backend:_cancel_reconnect()
  local timer = self.reconnect_timer
  self.reconnect_timer = nil
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

function Backend:_schedule_reconnect()
  if
    self.closed
    or self.controller.state.connection.connected
    or self.reconnect_timer
    or #self.reconnect_delays == 0
  then
    return false
  end

  self.reconnect_attempt = self.reconnect_attempt + 1
  local delay = self.reconnect_delays[math.min(self.reconnect_attempt, #self.reconnect_delays)]
  local timer = assert(vim.uv.new_timer())
  self.reconnect_timer = timer
  timer:start(delay, 0, vim.schedule_wrap(function()
    if self.reconnect_timer ~= timer then
      if not timer:is_closing() then
        timer:close()
      end
      return
    end
    self.reconnect_timer = nil
    if not timer:is_closing() then
      timer:close()
    end
    if self.closed or self.controller.state.connection.connected then
      return
    end
    local ok, err = self.controller:connect()
    if not ok then
      if err == "already connected or connecting" then
        self:_schedule_reconnect()
      elseif err then
        self.on_error(err)
      end
    end
  end))
  return true
end

function Backend:_connection_error_message(err)
  local suffix = #self.reconnect_delays > 0 and "; retrying automatically." or "."
  if err == "ENOENT" then
    return "Sorcar socket not found at "
      .. self.path
      .. " (ENOENT). Start or restart kiss-web after the socket directory is mounted"
      .. suffix
  elseif err == "ECONNREFUSED" then
    return "Sorcar socket refused the connection at "
      .. self.path
      .. " (ECONNREFUSED). Restart kiss-web to replace the stale socket"
      .. suffix
  end
  return "Sorcar connection failed at " .. self.path .. ": " .. err .. suffix
end

function Backend:_handle_error(err)
  local raw = tostring(err)
  if not self.controller.state.connection.connected then
    self:_schedule_reconnect()
    local message = self:_connection_error_message(raw)
    if message ~= self.last_connection_error then
      self.last_connection_error = message
      self:_emit({ type = "error", message = message })
    end
    return
  end
  self:_emit({ type = "error", message = raw })
end

function Backend:_state_event(phase)
  local connection = self.controller.state.connection
  if phase then
    self.phase = phase
  end
  self:_emit({
    type = "state_changed",
    connection = connection.connected and "connected" or "disconnected",
    fresh = connection.connected and self.controller.state.registry_generation == connection.generation,
    generation = connection.generation,
    phase = self.phase,
    tab_id = self.tab_id,
  })
end

function Backend:_wire_event(event, generation)
  if event.type == "connection_connected" then
    self:_cancel_reconnect()
    self.last_connection_error = nil
    self.open_confirmed = false
    self.reconnect_attempt = 0
    self:_state_event("unknown")
    return
  elseif event.type == "connection_disconnected" then
    self.open_confirmed = false
    vim.schedule(function()
      if not self.closed then
        if self.history_load_request and self.history_load_request.sent_generation then
          self:_finish_history_load(nil, "connection lost after resumeSession; outcome unknown")
        end
        self:_schedule_reconnect()
        self:_state_event(#self.reconnect_delays > 0 and "reconnecting" or "unknown")
      end
    end)
    return
  elseif event.type == "tabs_state" then
    self.open_confirmed = canonical(self.controller.state, self.tab_id)
    if not self.open_confirmed and self.open_generation ~= generation then
      local opened, err = self.lifecycle:open(self.tab_id, { title = "Agent Workbench", workDir = self.cwd })
      if opened then
        self.open_generation = generation
      else
        self:_emit({ type = "error", message = err or "Sorcar tab open rejected" })
      end
    end
    if self.open_confirmed then
      self:_try_history_list()
      self:_try_history_load()
    end
    self:_state_event("unknown")
    return
  elseif event.type == "history" then
    self:_history_page(event)
    return
  end
  if event.tabId ~= self.tab_id then
    return
  end

  if event.type == "status" then
    self.run_pending = false
    if event.running == true then
      self:_emit({ type = "run_started", timestamp = event.ts, raw = event })
      self:_state_event("running")
    else
      self:_emit({ type = "run_settled", raw = event })
      self:_state_event("idle")
    end
  elseif event.type == "thinking_start" then
    self:_emit({ type = "thinking_started", raw = event })
  elseif event.type == "thinking_delta" then
    self:_emit({ type = "thinking_delta", delta = event.text or "", raw = event })
  elseif event.type == "thinking_end" then
    self:_emit({ type = "thinking_finished", raw = event })
  elseif event.type == "text_delta" then
    self:_emit({ type = "text_delta", delta = event.text or "", raw = event })
  elseif event.type == "usage_info" then
    self:_emit({
      type = "usage_changed",
      usage = {
        total_tokens = event.total_tokens,
        cost = event.cost,
        total_steps = event.total_steps,
      },
      raw = event,
    })
  elseif event.type == "result" then
    self:_emit({
      type = "semantic_result",
      text = event.text,
      success = event.success,
      summary = event.summary,
      raw = event,
    })
  elseif LIFECYCLE_REASON[event.type] then
    self.run_pending = false
    self:_emit({ type = "execution_finished", reason = LIFECYCLE_REASON[event.type], raw = event })
  elseif event.type == "error" then
    self:_emit({ type = "error", message = event.text or event.message or "Sorcar error", raw = event })
  elseif event.type == "task_events" then
    local request = self.history_load_request
    if request then
      if event.task_id ~= request.item.task_id then
        self:_finish_history_load(nil, "daemon resumed a different Sorcar task than requested")
      elseif event.chat_id ~= request.item.id then
        self:_finish_history_load(nil, "daemon resumed a different Sorcar chat than requested")
      else
        self:_finish_history_load({
          chat_id = event.chat_id,
          messages = history_messages(event),
          task_id = event.task_id,
        }, nil)
      end
      return
    end
    for _, replayed in ipairs(type(event.events) == "table" and event.events or {}) do
      local nested = vim.deepcopy(replayed)
      nested.tabId = nested.tabId or self.tab_id
      self:_wire_event(nested, generation)
    end
  end
end

---List Sorcar history for this backend workspace.
---@param callback fun(items:table[]|nil,error:string|nil)
---@return boolean accepted
---@return string|nil error
function Backend:list_history(callback)
  assert(type(callback) == "function", "history list callback required")
  if self.history_list_request then
    return false, "Sorcar history request already in progress"
  end
  self.history_generation = self.history_generation + 1
  self.history_list_request = {
    callback = callback,
    generation = self.history_generation,
    items = {},
  }
  self:_try_history_list()
  return true, nil
end

---Resume one exact Sorcar task and return normalized Workbench replay messages.
---@param item table
---@param callback fun(result:table|nil,error:string|nil)
---@return boolean accepted
---@return string|nil error
function Backend:load_history(item, callback)
  assert(type(callback) == "function", "history load callback required")
  if self.history_load_request then
    return false, "Sorcar history load already in progress"
  end
  if
    type(item) ~= "table"
    or type(item.id) ~= "string"
    or item.id == ""
    or type(item.task_id) ~= "string"
    or item.task_id == ""
  then
    return false, "Sorcar history item requires chat and task IDs"
  end
  if item.is_running == true then
    return false, "running Sorcar history cannot be resumed safely"
  end
  local tab = self.controller.state.tabs[self.tab_id]
  if self.run_pending or (tab and tab.running == true) then
    return false, "cannot resume history while the current Sorcar task is running"
  end
  self.history_load_request = { callback = callback, item = vim.deepcopy(item) }
  self:_try_history_load()
  return true, nil
end

---Connect and open one Sorcar tab. Run remains deferred until canonical confirmation.
---@param sink fun(event: table)
---@return boolean
---@return string?
function Backend:start(sink)
  assert(type(sink) == "function", "backend sink required")
  self.sink = sink
  self.unsubscribe = self.controller:add_listener(function(event, generation)
    self:_wire_event(event, generation)
  end)
  local ok, err = self.controller:connect()
  if not ok then
    return false, err
  end
  return true, nil
end

---Close owned tab when current; never stop shared daemon.
function Backend:close()
  if self.closed then
    return
  end
  self.closed = true
  self.history_list_request = nil
  self.history_load_request = nil
  self:_cancel_reconnect()
  if canonical(self.controller.state, self.tab_id) then
    self.actions:close_tab(self.tab_id)
  end
  if self.unsubscribe then
    self.unsubscribe()
    self.unsubscribe = nil
  end
  self.lifecycle:close()
  self.controller:close()
end

---Submit run exactly once after canonical confirmation.
---@param text string
---@return boolean
---@return string?
function Backend:prompt(text)
  if not canonical(self.controller.state, self.tab_id) then
    return false, "Sorcar tab is not current-generation confirmed"
  end
  local options = vim.tbl_extend("force", {}, self.run_options, { workDir = self.cwd })
  local accepted, err = self.actions:run(self.tab_id, text, options)
  if accepted then
    self.run_pending = true
  end
  return accepted, err
end

---Steer current fresh running task.
---@param text string
---@return boolean
---@return string?
function Backend:steer(text)
  return self.actions:steer(self.tab_id, text)
end

---Stop current fresh running task.
---@return boolean
---@return string?
function Backend:stop()
  return self.actions:stop(self.tab_id)
end

---Return whether backend connection remains live.
---@return boolean
function Backend:is_running()
  return self.controller.state.connection.connected == true
end

return Backend
