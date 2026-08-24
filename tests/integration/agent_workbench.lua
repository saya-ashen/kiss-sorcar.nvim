local root = assert(vim.env.KISS_TEST_REPO)
local workbench_root = root .. "/pi2.nvim"
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  workbench_root .. "/lua/?.lua",
  workbench_root .. "/lua/?/init.lua",
  package.path,
}, ";")
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(workbench_root)

local socket_path = assert(vim.env.KISS_TEST_SOCKET)
local work_dir = assert(vim.env.KISS_TEST_WORK_DIR)
local model = assert(vim.env.KISS_TEST_MODEL)
local trace_path = assert(vim.env.KISS_TEST_EVENT_LOG)

local Backend = require("kiss-sorcar.backend")
local Sessions = require("agent-workbench.sessions.manager")
local Workbench = require("agent-workbench")

local observed = {}
Workbench.register_backend("sorcar", function(options)
  local backend = Backend.new(options)
  local start = backend.start
  function backend:start(sink)
    return start(self, function(event)
      observed[#observed + 1] = vim.deepcopy(event)
      sink(event)
    end)
  end
  return backend
end)

Workbench.setup({
  backend = "sorcar",
  backend_options = { path = socket_path, run_options = { model = model } },
  render = { markdown = { enabled = false } },
  prompt = { history = { enabled = false }, draft = { enabled = false } },
})

local session = assert(Sessions.get_or_create({ layout = "buffer" }))
assert(vim.wait(30000, function()
  local state = session.backend.controller.state
  return state.connection.connected and state.registry_generation == state.connection.generation
    and session.backend.open_confirmed
end, 20), "Sorcar tab did not become canonical")

local prompt = table.concat({
  "Read-only task. Inspect this disposable Git repository.",
  "Run `git status --short` and `git log -1 --oneline`.",
  "Do not modify files. Reply with one short sentence summarizing repository state.",
}, "\n")
session.chat._prompt:set_text(prompt)
session.chat:submit()
assert(vim.wait(60000, function()
  return session.chat:is_streaming()
end, 20), "Sorcar task did not start")
assert(vim.wait(300000, function()
  return not session.chat:is_streaming()
end, 50), "Sorcar task did not settle")
assert(vim.wait(5000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(session.chat:history_buf(), 0, -1, false), "\n")
  return text:find("󰚩", 1, true) ~= nil and #text > #prompt
end, 20), "Agent Workbench History did not render response")

local types = {}
for _, event in ipairs(observed) do
  types[#types + 1] = event.type
end
local function index_of(event_type)
  for index, value in ipairs(types) do
    if value == event_type then
      return index
    end
  end
end
local result_index = assert(index_of("semantic_result"), "semantic result missing")
local lifecycle_index = assert(index_of("execution_finished"), "execution lifecycle missing")
local settled_index = assert(index_of("run_settled"), "settled state missing")
assert(result_index < lifecycle_index and lifecycle_index < settled_index, "result/lifecycle/settled ordering mismatch")

local file = assert(io.open(trace_path, "w"))
for _, event in ipairs(observed) do
  file:write(vim.json.encode(event), "\n")
end
file:close()

Sessions._reset()
print("PASS real Agent Workbench Sorcar backend: " .. table.concat(types, ","))
vim.cmd("qa!")
