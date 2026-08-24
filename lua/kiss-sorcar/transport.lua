local uv = vim.uv

local M = {}

local Framer = {}
Framer.__index = Framer

---Create connection-scoped NDJSON byte framer.
---@param on_frame fun(line:string)
---@param max_bytes? integer
---@return table
function Framer.new(on_frame, max_bytes)
  return setmetatable({ buffer = "", max_bytes = max_bytes or 64 * 1024 * 1024, on_frame = on_frame }, Framer)
end

---Consume arbitrary stream bytes and emit complete frames in order.
---@param chunk string
---@return boolean ok
---@return string|nil error
function Framer:feed(chunk)
  self.buffer = self.buffer .. chunk
  if #self.buffer > self.max_bytes and not self.buffer:find("\n", 1, true) then
    return false, "NDJSON frame exceeds byte limit"
  end

  while true do
    local newline = self.buffer:find("\n", 1, true)
    if not newline then
      break
    end
    local line = self.buffer:sub(1, newline - 1)
    self.buffer = self.buffer:sub(newline + 1)
    if #line > self.max_bytes then
      return false, "NDJSON frame exceeds byte limit"
    end
    if line ~= "" then
      self.on_frame(line)
    end
  end
  if #self.buffer > self.max_bytes then
    return false, "NDJSON frame exceeds byte limit"
  end
  return true, nil
end

---Discard incomplete bytes from closed connection.
function Framer:reset()
  self.buffer = ""
end

M.Framer = Framer

local Client = {}
Client.__index = Client

---Create disconnected Unix-socket client.
---@param options table {path,on_frame,on_connect,on_disconnect,on_error,max_frame_bytes}
---@return table
function Client.new(options)
  assert(type(options) == "table", "options required")
  assert(type(options.path) == "string" and options.path ~= "", "socket path required")
  assert(type(options.on_frame) == "function", "on_frame required")
  return setmetatable({
    connected = false,
    connecting = false,
    generation = 0,
    on_connect = options.on_connect or function() end,
    on_disconnect = options.on_disconnect or function() end,
    on_error = options.on_error or function() end,
    on_frame = options.on_frame,
    max_frame_bytes = options.max_frame_bytes,
    path = options.path,
    pipe = nil,
  }, Client)
end

local function close_pipe(pipe)
  if pipe and not pipe:is_closing() then
    pipe:close()
  end
end

---Connect once. Caller owns reconnect policy.
function Client:connect()
  if self.connected or self.connecting then
    return false, "already connected or connecting"
  end

  self.generation = self.generation + 1
  local generation = self.generation
  local pipe = uv.new_pipe(false)
  local framer = Framer.new(function(line)
    if generation == self.generation then
      self.on_frame(line, generation)
    end
  end, self.max_frame_bytes)
  self.pipe = pipe
  self.connecting = true

  pipe:connect(self.path, function(err)
    if generation ~= self.generation then
      close_pipe(pipe)
      return
    end
    self.connecting = false
    if err then
      self.pipe = nil
      close_pipe(pipe)
      self.on_error(err)
      return
    end

    self.connected = true
    pipe:read_start(function(read_err, chunk)
      if generation ~= self.generation then
        return
      end
      if read_err then
        self.on_error(read_err)
        self:_lost(generation)
      elseif chunk == nil then
        self:_lost(generation)
      else
        local ok, frame_err = framer:feed(chunk)
        if not ok then
          self.on_error(frame_err)
          self:_lost(generation)
        end
      end
    end)
    if generation == self.generation and self.connected and self.pipe == pipe then
      self.on_connect(generation)
    end
  end)
  return true, nil
end

---Close connection and invalidate callbacks from its generation.
function Client:close()
  local was_active = self.connected or self.connecting
  local generation = self.generation
  self.generation = self.generation + 1
  self.connected = false
  self.connecting = false
  local pipe = self.pipe
  self.pipe = nil
  if pipe and not pipe:is_closing() then
    pcall(pipe.read_stop, pipe)
    pipe:close()
  end
  if was_active then
    self.on_disconnect("closed", generation)
  end
end

---Write frame only on current connection. Nothing queues for reconnect.
---@param frame string
---@param callback? fun(error:string|nil)
---@return boolean accepted
---@return string|nil error
function Client:send(frame, callback)
  if not self.connected or not self.pipe or self.pipe:is_closing() then
    return false, "disconnected; command not queued"
  end
  local generation = self.generation
  self.pipe:write(frame, function(err)
    if callback and generation == self.generation then
      callback(err)
    end
  end)
  return true, nil
end

---Handle EOF/read failure once for current generation.
---@param generation integer
function Client:_lost(generation)
  if generation ~= self.generation or (not self.connected and not self.connecting) then
    return
  end
  self.connected = false
  self.connecting = false
  local pipe = self.pipe
  self.pipe = nil
  close_pipe(pipe)
  self.on_disconnect("lost", generation)
end

M.Client = Client

return M
