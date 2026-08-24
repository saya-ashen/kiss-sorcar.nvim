local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")
package.path = table.concat({ root .. "/lua/?.lua", root .. "/lua/?/init.lua", package.path }, ";")

local SorcarBackend = require("kiss-sorcar.backend")

local function fake_core()
  local listeners = {}
  local sent = {}
  local state = {
    connection = { connected = false, generation = 0 },
    registry = {},
    registry_generation = 0,
    tabs = {},
  }
  local controller = {
    active_generation = 0,
    state = state,
    add_listener = function(_, listener)
      listeners[#listeners + 1] = listener
      return function() end
    end,
    connect = function(self)
      self.active_generation = 1
      state.connection = { connected = true, generation = 1, stale = false }
      for _, listener in ipairs(listeners) do
        listener({ type = "connection_connected" }, 1)
      end
      return true
    end,
    close = function()
      state.connection.connected = false
    end,
  }
  local tabs = {
    add_listener = function(_, listener)
      listeners[#listeners + 1] = function(event)
        if event.type == "tabs_state" then
          listener("agent-workbench-7", { state = "confirmed", generation = 1 })
        end
      end
      return function() end
    end,
    open = function()
      sent[#sent + 1] = { type = "openTab" }
      return true
    end,
    close = function() end,
  }
  local actions = {}
  for _, method in ipairs({ "run", "steer", "stop", "close_tab" }) do
    actions[method] = function(_, ...)
      sent[#sent + 1] = { type = method, args = { ... } }
      return true
    end
  end
  return controller, tabs, actions, listeners, sent
end

describe("Sorcar BackendSession", function()
  it("uses core lifecycle/actions and preserves semantic lifecycle separation", function()
    local controller, tabs, actions, listeners, sent = fake_core()
    local backend = SorcarBackend.new({
      id = 7,
      cwd = "/tmp/workbench",
      path = "/tmp/sorcar.sock",
      controller = controller,
      tab_lifecycle = tabs,
      actions = actions,
    })
    local events = {}
    assert.is_true(backend:start(function(event)
      events[#events + 1] = event
    end))

    state = controller.state
    state.registry = {}
    state.registry_generation = 1
    for _, listener in ipairs(listeners) do
      listener({ type = "tabs_state", tabs = {} }, 1)
    end
    state.registry = { { tabId = "agent-workbench-7" } }
    state.registry_generation = 1
    state.tabs["agent-workbench-7"] = { running = false, running_generation = 1, transcript = {} }
    for _, listener in ipairs(listeners) do
      listener({ type = "tabs_state", tabs = state.registry }, 1)
    end
    assert.is_true(backend:prompt("inspect"))
    state.tabs["agent-workbench-7"].running = true
    assert.is_true(backend:steer("focus"))

    local wire = {
      { type = "status", tabId = "agent-workbench-7", running = true },
      { type = "thinking_start", tabId = "agent-workbench-7" },
      { type = "thinking_delta", tabId = "agent-workbench-7", text = "why" },
      { type = "thinking_end", tabId = "agent-workbench-7" },
      { type = "text_delta", tabId = "agent-workbench-7", text = "answer" },
      { type = "usage_info", tabId = "agent-workbench-7", total_tokens = 12, cost = "$0.0010" },
      { type = "result", tabId = "agent-workbench-7", text = "answer", success = false },
      { type = "task_done", tabId = "agent-workbench-7" },
      { type = "status", tabId = "agent-workbench-7", running = false },
    }
    for _, event in ipairs(wire) do
      for _, listener in ipairs(listeners) do
        listener(event, 1)
      end
    end

    local types = {}
    for _, event in ipairs(events) do
      types[#types + 1] = event.type
    end
    assert.are.same({
      "state_changed",
      "state_changed",
      "state_changed",
      "run_started",
      "state_changed",
      "thinking_started",
      "thinking_delta",
      "thinking_finished",
      "text_delta",
      "usage_changed",
      "semantic_result",
      "execution_finished",
      "run_settled",
      "state_changed",
    }, types)
    assert.are.same({ total_tokens = 12, cost = "$0.0010" }, {
      total_tokens = events[10].usage.total_tokens,
      cost = events[10].usage.cost,
    })
    assert.is_false(events[11].success)
    assert.are.equal("completed", events[12].reason)
    assert.are.equal("idle", events[14].phase)
    assert.are.same({
      { type = "openTab" },
      { type = "run", args = { "agent-workbench-7", "inspect", { workDir = "/tmp/workbench" } } },
      { type = "steer", args = { "agent-workbench-7", "focus" } },
    }, sent)

    backend:close()
    assert.are.equal("close_tab", sent[#sent].type)
  end)

  it("fails closed before canonical fresh tab evidence", function()
    local controller, tabs, actions = fake_core()
    local backend = SorcarBackend.new({
      id = 8,
      cwd = "/tmp/workbench",
      path = "/tmp/sorcar.sock",
      controller = controller,
      tab_lifecycle = tabs,
      actions = actions,
    })
    assert.is_true(backend:start(function() end))
    local ok, err = backend:prompt("too early")
    assert.is_false(ok)
    assert.are.equal("Sorcar tab is not current-generation confirmed", err)
    backend:close()
  end)
end)
