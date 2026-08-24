local uv = vim.uv
local Transport = require("kiss-sorcar.transport")

local FakeDaemon = {}
FakeDaemon.__index = FakeDaemon

local function unlink(path)
  pcall(uv.fs_unlink, path)
end

---Create fake NDJSON daemon bound to socket path when started.
---@param path string
---@return table
function FakeDaemon.new(path)
  return setmetatable({
    clients = {},
    commands = {},
    errors = {},
    path = path,
    server = nil,
  }, FakeDaemon)
end

---Start listening on Unix-domain socket.
function FakeDaemon:start()
  assert(not self.server or self.server:is_closing(), "fake daemon already started")
  unlink(self.path)
  self.server = assert(uv.new_pipe(false))
  assert(self.server:bind(self.path))
  self.server:listen(16, function(err)
    assert(not err, err)
    local client = assert(uv.new_pipe(false))
    assert(self.server:accept(client))
    self.clients[#self.clients + 1] = client
    local framer = Transport.Framer.new(function(line)
      local ok, value = pcall(vim.json.decode, line)
      if ok then
        self.commands[#self.commands + 1] = value
      else
        self.errors[#self.errors + 1] = value
      end
    end)
    client:read_start(function(read_err, chunk)
      local close_client = read_err ~= nil or chunk == nil
      if read_err then
        self.errors[#self.errors + 1] = read_err
      elseif chunk then
        local ok, frame_err = framer:feed(chunk)
        if not ok then
          self.errors[#self.errors + 1] = frame_err
          close_client = true
        end
      end
      if close_client and not client:is_closing() then
        pcall(client.read_stop, client)
        client:close()
      end
    end)
  end)
end

---Write raw byte chunks to selected client, defaulting to most recent.
---@param chunks string[]
---@param client_index? integer
function FakeDaemon:send_chunks(chunks, client_index)
  local client = assert(self.clients[client_index or #self.clients], "no connected client")
  for _, chunk in ipairs(chunks) do
    client:write(chunk)
  end
end

---Encode and send daemon events, optionally coalesced into one write.
---@param events table[]
---@param coalesce? boolean
---@param client_index? integer
function FakeDaemon:send_events(events, coalesce, client_index)
  local frames = {}
  for _, event in ipairs(events) do
    frames[#frames + 1] = vim.json.encode(event) .. "\n"
  end
  if coalesce then
    self:send_chunks({ table.concat(frames) }, client_index)
  else
    self:send_chunks(frames, client_index)
  end
end

---Disconnect most recently connected client.
function FakeDaemon:disconnect_client()
  local client = self.clients[#self.clients]
  if client and not client:is_closing() then
    client:shutdown(function()
      if not client:is_closing() then
        client:close()
      end
    end)
  end
end

---Stop daemon, close handles, and remove socket pathname.
function FakeDaemon:stop()
  for _, client in ipairs(self.clients) do
    if not client:is_closing() then
      pcall(client.read_stop, client)
      client:close()
    end
  end
  if self.server and not self.server:is_closing() then
    self.server:close()
  end
  unlink(self.path)
end

return FakeDaemon
