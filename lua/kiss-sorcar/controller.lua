local Protocol = require("kiss-sorcar.protocol")
local State = require("kiss-sorcar.state").State
local Transport = require("kiss-sorcar.transport")

local Controller = {}
Controller.__index = Controller

---Create connection controller. Reconnect remains caller-driven.
---@param options table {path:string,work_dir:string,state?:table,on_error?:function,transport_factory?:function}
---@return table
function Controller.new(options)
  assert(type(options) == "table", "options required")
  assert(type(options.path) == "string" and options.path ~= "", "socket path required")
  assert(type(options.work_dir) == "string" and options.work_dir ~= "", "work_dir required")

  local self = setmetatable({
    active_generation = 0,
    handshake_generation = 0,
    listeners = {},
    on_error = options.on_error or function() end,
    state = options.state or State.new(),
    work_dir = options.work_dir,
  }, Controller)
  local factory = options.transport_factory or Transport.Client.new
  self.transport = factory({
    path = options.path,
    on_connect = function(generation)
      self:_connected(generation)
    end,
    on_disconnect = function(reason, generation)
      self:_disconnected(reason, generation)
    end,
    on_error = function(err)
      self.on_error(err)
    end,
    on_frame = function(line, generation)
      self:receive(line, generation)
    end,
  })
  return self
end

---Start one transport connection attempt.
---@return boolean started
---@return string|nil error
function Controller:connect()
  return self.transport:connect()
end

---Close current connection.
function Controller:close()
  self.transport:close()
end

---Send command only on current live connection. Commands are never queued.
---@param command table
---@param callback? fun(error:string|nil)
---@return boolean accepted
---@return string|nil error
function Controller:send(command, callback)
  if command.type == "setWorkDir" or command.type == "ready" then
    return false, command.type .. " is controller-owned"
  end
  return self:_send(command, callback)
end

function Controller:_send(command, callback)
  local frame, encode_err = Protocol.encode(command)
  if not frame then
    return false, encode_err
  end
  return self.transport:send(frame, callback)
end

---Register lifecycle observer. Observer receives only current-generation callbacks.
---@param listener fun(event:table,generation:integer)
---@return function unsubscribe
function Controller:add_listener(listener)
  assert(type(listener) == "function", "listener required")
  local entry = { callback = listener }
  self.listeners[#self.listeners + 1] = entry
  return function()
    entry.callback = nil
  end
end

---Notify lifecycle observers only for current generation.
---@param event table
---@param generation integer
function Controller:_notify(event, generation)
  if generation ~= self.active_generation or not self.state.connection.connected then
    return
  end
  for _, entry in ipairs(self.listeners) do
    if entry.callback then
      local ok, err = pcall(entry.callback, event, generation)
      if not ok then
        self.on_error(err)
      end
    end
  end
end

---Decode and apply one frame only when it belongs to current live generation.
---@param line string
---@param generation integer
---@return boolean accepted
---@return string|nil error
function Controller:receive(line, generation)
  if generation ~= self.active_generation or not self.state.connection.connected then
    return false, "stale connection generation"
  end
  local event, decode_err = Protocol.decode(line)
  if not event then
    self.on_error(decode_err)
    return false, decode_err
  end
  self.state:apply(event)
  self:_notify(event, generation)
  return true, nil
end

function Controller:_connected(generation)
  if generation <= self.handshake_generation then
    return
  end
  self.active_generation = generation
  self.handshake_generation = generation
  self.state:connected(generation)
  self:_notify({ type = "connection_connected" }, generation)

  local function report_write_error(err)
    if err then
      self.on_error(err)
    end
  end
  local work_dir_ok, work_dir_err = self:_send(
    { type = "setWorkDir", workDir = self.work_dir },
    report_write_error
  )
  if not work_dir_ok then
    self.on_error(work_dir_err)
    return
  end
  local ready_ok, ready_err = self:_send({ type = "ready", workDir = self.work_dir }, report_write_error)
  if not ready_ok then
    self.on_error(ready_err)
  end
end

function Controller:_disconnected(_, generation)
  if generation == self.active_generation then
    self:_notify({ type = "connection_disconnected" }, generation)
    self.state:disconnected()
  end
end

return { Controller = Controller }
