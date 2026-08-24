local root = vim.fn.getcwd()
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/tests/?.lua",
  package.path,
}, ";")

local Actions = require("kiss-sorcar.actions").Actions
local Backend = require("kiss-sorcar.backend")
local Controller = require("kiss-sorcar.controller").Controller
local FakeDaemon = require("fake_daemon")
local Protocol = require("kiss-sorcar.protocol")
local State = require("kiss-sorcar.state").State
local TabLifecycle = require("kiss-sorcar.tab_lifecycle").TabLifecycle
local Transport = require("kiss-sorcar.transport")
local UI = require("kiss-sorcar.ui").UI

local passed = 0
local failed = 0
local cleanup = {}
local selected_test = vim.env.SORCAR_TEST
if selected_test and selected_test ~= "" and (not tonumber(selected_test) or tonumber(selected_test) < 1) then
  error("SORCAR_TEST must be a positive test index")
end

local function equal(actual, expected, context)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s\nexpected: %s\nactual:   %s", context, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local function truthy(value, context)
  if not value then
    error(context, 2)
  end
end

local function wait_for(predicate, context)
  truthy(vim.wait(2000, predicate, 5), "timeout: " .. context)
end

local test_index = 0

local function test(name, body)
  test_index = test_index + 1
  if selected_test and selected_test ~= "" and tonumber(selected_test) ~= test_index then
    return
  end
  local ok, err = xpcall(body, debug.traceback)
  if ok then
    passed = passed + 1
    print("PASS " .. name)
  else
    failed = failed + 1
    print("FAIL " .. name .. "\n" .. err)
  end
end

local function temp_socket()
  local path = vim.fn.tempname() .. ".sock"
  cleanup[#cleanup + 1] = function()
    pcall(vim.uv.fs_unlink, path)
  end
  return path
end

local function connected_controller()
  local path = temp_socket()
  local daemon = FakeDaemon.new(path)
  daemon:start()
  local controller = Controller.new({ path = path, work_dir = "/workspace" })
  cleanup[#cleanup + 1] = function()
    controller:close()
    daemon:stop()
  end
  truthy(controller:connect(), "controller connect starts")
  wait_for(function()
    return #daemon.commands == 2
  end, "controller handshake")
  return controller, daemon
end

local function connected_harness()
  local path = temp_socket()
  local daemon = FakeDaemon.new(path)
  daemon:start()
  local state = State.new({ unknown_limit = 2 })
  local decode_errors = {}
  local disconnects = 0
  local client = Transport.Client.new({
    path = path,
    on_connect = function(generation)
      state:connected(generation)
    end,
    on_disconnect = function()
      disconnects = disconnects + 1
      state:disconnected()
    end,
    on_error = function(err)
      decode_errors[#decode_errors + 1] = err
    end,
    on_frame = function(line)
      local event, err = Protocol.decode(line)
      if event then
        state:apply(event)
      else
        decode_errors[#decode_errors + 1] = err
      end
    end,
  })
  truthy(client:connect(), "client connect starts")
  wait_for(function()
    return client.connected and #daemon.clients == 1
  end, "initial connection")
  cleanup[#cleanup + 1] = function()
    client:close()
    daemon:stop()
  end
  return {
    client = client,
    daemon = daemon,
    decode_errors = decode_errors,
    disconnects = function()
      return disconnects
    end,
    state = state,
  }
end

test("framer handles split, coalesced, empty, and oversized frames", function()
  local frames = {}
  local framer = Transport.Framer.new(function(line)
    frames[#frames + 1] = line
  end, 8)
  truthy(framer:feed('{"a"'))
  truthy(framer:feed(':1}\n\n{}\n'))
  equal(frames, { '{"a":1}', "{}" }, "split and coalesced frames")
  local ok, err = framer:feed("123456789")
  equal(ok, false, "unterminated oversized frame rejected")
  equal(err, "NDJSON frame exceeds byte limit", "oversize diagnostic")
  framer:reset()
  equal(framer.buffer, "", "reset drops partial frame")
  local complete_ok, complete_err = framer:feed("123456789\n")
  equal(complete_ok, false, "complete oversized frame rejected")
  equal(complete_err, "NDJSON frame exceeds byte limit", "complete oversize diagnostic")
end)

test("protocol validates frames and classifies reconnect-unsafe commands", function()
  local event = assert(Protocol.decode('{"type":"status","running":true}'))
  equal(event.type, "status", "object decoded")
  local _, empty_err = Protocol.decode("")
  equal(empty_err, "empty frame", "empty rejected")
  local _, array_err = Protocol.decode("[]")
  equal(array_err, "frame must be a JSON object", "array rejected")
  local _, type_err = Protocol.decode("{}")
  equal(type_err, "frame.type must be a non-empty string", "missing type rejected")
  local _, json_err = Protocol.decode("{")
  truthy(json_err:find("invalid JSON", 1, true), "malformed JSON rejected")

  local frame = assert(Protocol.encode({ type = "run", prompt = "go", tabId = "a" }))
  truthy(frame:sub(-1) == "\n", "command newline encoded")
  local _, required_err = Protocol.encode({ type = "userAnswer", tabId = "a" })
  equal(required_err, "userAnswer.answer is required", "required field checked")
  local _, open_err = Protocol.encode({ type = "openTab" })
  equal(open_err, "openTab.tabId is required", "openTab target required")
  for _, command_type in ipairs({ "run", "appendUserMessage", "userAnswer", "worktreeAction", "futureCommand" }) do
    truthy(Protocol.is_effectful(command_type), command_type .. " is reconnect-unsafe")
  end
  equal(Protocol.is_replay_safe("getModels"), true, "read command explicitly replay-safe")
  equal(Protocol.is_effectful("getModels"), false, "read command not effectful")
end)

test("fake daemon exercises UTF-8 byte splits and coalesced interleaved tabs", function()
  local harness = connected_harness()
  local first = vim.json.encode({ type = "text_delta", tabId = "tab-a", text = "猫" }) .. "\n"
  local marker = assert(first:find("猫", 1, true))
  harness.daemon:send_chunks({ first:sub(1, marker), first:sub(marker + 1) })
  harness.daemon:send_events({
    { type = "status", tabId = "tab-b", running = true, taskId = "submit-b" },
    { type = "status", tabId = "tab-a", running = true, taskId = "submit-a" },
    { type = "result", tabId = "tab-a", text = "answer" },
  }, true)
  wait_for(function()
    return harness.state.tabs["tab-a"] and harness.state.tabs["tab-a"].result ~= nil
  end, "UTF-8 and coalesced events")
  equal(harness.state.tabs["tab-a"].transcript[1].text, "猫", "split UTF-8 survives")
  equal(harness.state.tabs["tab-a"].submission_id, "submit-a", "tab A identity")
  equal(harness.state.tabs["tab-b"].submission_id, "submit-b", "tab B identity")
  equal(harness.state.tabs["tab-a"].running, true, "result does not complete task")
  equal(harness.state.tabs["tab-a"].lifecycle, nil, "result is not lifecycle")

  for _, lifecycle in ipairs({ "task_error", "task_stopped", "task_interrupted", "task_done" }) do
    harness.daemon:send_events({ { type = lifecycle, tabId = "tab-a", endTs = 2 } })
    wait_for(function()
      return harness.state.tabs["tab-a"].lifecycle == lifecycle
    end, lifecycle .. " terminal")
  end
  equal(harness.state.tabs["tab-a"].running, true, "lifecycle and status remain distinct")
  harness.daemon:send_events({ { type = "status", tabId = "tab-a", running = false } })
  wait_for(function()
    return harness.state.tabs["tab-a"].running == false
  end, "outer status terminal")
  equal(harness.state.tabs["tab-b"].running, true, "other tab remains active")
end)

test("steering and answer route exactly once by tab", function()
  local harness = connected_harness()
  local commands = {
    { type = "appendUserMessage", tabId = "tab-a", prompt = "steer A" },
    { type = "userAnswer", tabId = "tab-b", answer = "yes" },
  }
  for _, command in ipairs(commands) do
    local frame = assert(Protocol.encode(command))
    truthy(harness.client:send(frame), "connected command accepted")
  end
  wait_for(function()
    return #harness.daemon.commands == 2
  end, "routed commands received")
  equal(harness.daemon.commands, commands, "routing fields remain exact")

  harness.daemon:send_events({
    { type = "askUser", tabId = "tab-b", question = "Proceed?" },
    { type = "askUser", tabId = "tab-a", question = "Change A?" },
    { type = "askUserDone", tabId = "tab-b" },
  }, true)
  wait_for(function()
    return harness.state.tabs["tab-a"] and harness.state.tabs["tab-a"].pending_question ~= nil
  end, "question events")
  equal(harness.state.tabs["tab-a"].pending_question, "Change A?", "A question retained")
  equal(harness.state.tabs["tab-b"].pending_question, nil, "B answer clears only B")
end)

test("unknown wire events are nonfatal and bounded", function()
  local harness = connected_harness()
  harness.daemon:send_events({
    { type = "future", tabId = "a", value = 1 },
    { type = "future", tabId = "b", value = 2 },
    { type = "future", tabId = "c", value = 3 },
    { type = "status", tabId = "a", running = true },
  }, true)
  wait_for(function()
    return harness.state.tabs.a and harness.state.tabs.a.running
  end, "known event after unknown wire events")
  equal(#harness.state.unknown, 2, "diagnostics bounded")
  equal(harness.state.unknown[1].value, 2, "oldest diagnostic evicted")
  equal(harness.state.tabs.b, nil, "unknown event does not create tab")
  equal(harness.state.tabs.c, nil, "unknown event does not create tab")
  equal(#harness.decode_errors, 0, "unknown event does not break decoder")
  equal(harness.client.connected, true, "unknown event does not disconnect")
end)

test("task_settings retains observed live payload and reconstructs replay state", function()
  local state = State.new()
  local settings = {
    chat_id = "chat-settings",
    is_parallel = false,
    is_subagent = false,
    is_worktree = false,
    max_budget = 0.25,
    model = "codex/gpt-5.6-sol",
    start_ts = 1787552685470,
    task_id = "history-settings",
    work_dir = "/workspace",
  }
  local live = {
    type = "task_settings",
    tabId = "tab-settings",
    taskId = "history-settings",
    settings = settings,
  }
  truthy(state:apply(live), "live task_settings handled")
  local tab = state.tabs["tab-settings"]
  equal(tab.task_settings, settings, "settings payload retained")
  equal(tab.task_settings_event, live, "full settings event retained")
  equal(tab.history_task_id, "history-settings", "persisted task identity retained")
  equal(tab.chat_id, "chat-settings", "chat identity retained")
  equal(tab.transcript, { live }, "display event retained in transcript")
  equal(#state.unknown, 0, "known settings event not diagnostic")

  state:apply({
    type = "task_events",
    tabId = "tab-settings",
    task_id = "history-replay",
    chat_id = "chat-replay",
    events = {
      {
        type = "task_settings",
        taskId = "history-replay",
        settings = vim.tbl_extend("force", settings, {
          chat_id = "chat-replay",
          task_id = "history-replay",
        }),
      },
      { type = "result", text = "done", success = false },
      { type = "task_done" },
    },
  })
  tab = state.tabs["tab-settings"]
  equal(tab.task_settings.task_id, "history-replay", "replay settings reconstructed")
  equal(tab.history_task_id, "history-replay", "envelope remains replay identity")
  equal(tab.chat_id, "chat-replay", "replay chat retained")
  equal(tab.result.success, false, "semantic failure retained separately")
  equal(tab.lifecycle, "task_done", "execution lifecycle remains separate")

  truthy(state:apply({ type = "stop_ack", tabId = "tab-settings", accepted = true }), "stop_ack handled")
  equal(tab.stop_ack.accepted, true, "stop acceptance retained")
  equal(tab.running, false, "stop acknowledgment does not invent running state")
  equal(tab.lifecycle, "task_done", "stop acknowledgment does not invent lifecycle")

  state:apply({ type = "clear", tabId = "tab-settings", chat_id = "chat-next" })
  equal(tab.task_settings, nil, "new run clears prior settings")
  equal(tab.task_settings_event, nil, "new run clears prior settings event")
  equal(tab.stop_ack, nil, "new run clears prior stop acknowledgment")
end)

test("replay and worktree state preserve persisted task identity", function()
  local state = State.new()
  state:apply({
    type = "task_events",
    tabId = "tab-a",
    task_id = "history-1",
    chat_id = "chat",
    events = { { type = "result", text = "done" }, { type = "task_error", text = "failed" } },
  })
  equal(state.tabs["tab-a"].result.text, "done", "replay derives result")
  equal(state.tabs["tab-a"].lifecycle, "task_error", "replay derives distinct lifecycle")
  state:apply({ type = "worktree_created", tabId = "tab-a", taskId = "history-1", worktreeDir = "/one" })
  state:apply({ type = "worktree_done", tabId = "tab-a", taskId = "history-2", worktreeDir = "/two" })
  equal(state.tabs["tab-a"].worktrees["history-1"].worktree_dir, "/one", "first task worktree")
  equal(state.tabs["tab-a"].worktrees["history-2"].worktree_dir, "/two", "second task worktree")
  equal(state.tabs["tab-a"].history_task_id, "history-1", "view identity not overwritten")
  state:apply({ type = "clear", tabId = "tab-a", chat_id = "new-chat" })
  equal(state.tabs["tab-a"].history_task_id, nil, "new run clears stale task identity")
  equal(state:apply({ type = "worktree_done", tabId = "tab-a" }), false, "taskless worktree not misattributed")
  equal(state.tabs["tab-a"].worktrees[""], nil, "empty task key never created")
end)

test("reconnect drops partial input and never replays effectful commands", function()
  local harness = connected_harness()
  local run = assert(Protocol.encode({ type = "run", tabId = "tab-a", prompt = "once" }))
  truthy(harness.client:send(run), "initial run sent")
  wait_for(function()
    return #harness.daemon.commands == 1
  end, "initial run received")

  harness.daemon:send_chunks({ '{"type":"text_delta","tabId":"tab-a","text":"old' })
  harness.daemon:disconnect_client()
  wait_for(function()
    return not harness.client.connected and harness.disconnects() == 1
  end, "disconnect observed")
  equal(harness.state.connection.stale, true, "retained state marked stale")
  for _, command in ipairs({
    { type = "run", tabId = "tab-a", prompt = "again" },
    { type = "appendUserMessage", tabId = "tab-a", prompt = "steer" },
    { type = "userAnswer", tabId = "tab-a", answer = "yes" },
    { type = "worktreeAction", tabId = "tab-a", action = "nothing" },
  }) do
    local sent, err = harness.client:send(assert(Protocol.encode(command)))
    equal(sent, false, command.type .. " rejected while disconnected")
    equal(err, "disconnected; command not queued", command.type .. " never queued")
  end

  truthy(harness.client:connect(), "manual reconnect starts")
  wait_for(function()
    return harness.client.connected and #harness.daemon.clients == 2
  end, "manual reconnect")
  harness.daemon:send_events({ { type = "status", tabId = "tab-a", running = true } })
  wait_for(function()
    return harness.state.tabs["tab-a"] and harness.state.tabs["tab-a"].running
  end, "new generation event")
  equal(#harness.daemon.commands, 1, "run not replayed")
  equal(#harness.state.tabs["tab-a"].transcript, 0, "old partial frame discarded")
  equal(harness.state.connection.generation, 2, "new connection generation recorded")
end)

test("controller connects with one ordered reconstruction handshake", function()
  local path = temp_socket()
  local daemon = FakeDaemon.new(path)
  daemon:start()
  local errors = {}
  local controller = Controller.new({
    path = path,
    work_dir = "/workspace/猫",
    on_error = function(err)
      errors[#errors + 1] = err
    end,
  })
  cleanup[#cleanup + 1] = function()
    controller:close()
    daemon:stop()
  end

  truthy(controller:connect(), "controller connection starts")
  wait_for(function()
    return #daemon.commands == 2
  end, "initial reconstruction handshake")
  equal(daemon.commands, {
    { type = "setWorkDir", workDir = "/workspace/猫" },
    { type = "ready", workDir = "/workspace/猫" },
  }, "setWorkDir precedes exactly one ready")
  equal(controller.state.connection, { connected = true, generation = 1, stale = false }, "generation connected")
  controller:_connected(1)
  vim.wait(20)
  equal(#daemon.commands, 2, "duplicate callback cannot repeat ready")
  local extra_ready, extra_ready_err = controller:send({ type = "ready" })
  equal(extra_ready, false, "caller cannot send extra ready")
  equal(extra_ready_err, "ready is controller-owned", "extra ready diagnostic")
  equal(#errors, 0, "handshake has no errors")
end)

test("controller marks disconnect stale and reconnects with fresh handshake only", function()
  local path = temp_socket()
  local daemon = FakeDaemon.new(path)
  daemon:start()
  local controller = Controller.new({ path = path, work_dir = "/workspace" })
  cleanup[#cleanup + 1] = function()
    controller:close()
    daemon:stop()
  end

  truthy(controller:connect(), "first connect starts")
  wait_for(function()
    return #daemon.commands == 2
  end, "first handshake")
  truthy(controller:send({ type = "run", tabId = "tab-a", prompt = "once" }), "effect sent once")
  wait_for(function()
    return #daemon.commands == 3
  end, "effect received")
  daemon:disconnect_client()
  wait_for(function()
    return controller.state.connection.stale and not controller.transport.connected
  end, "disconnect stale state")

  truthy(controller:connect(), "reconnect starts")
  wait_for(function()
    return #daemon.commands == 5 and controller.state.connection.generation == 2
  end, "second handshake")
  equal(daemon.commands[4], { type = "setWorkDir", workDir = "/workspace" }, "fresh work directory")
  equal(daemon.commands[5], { type = "ready", workDir = "/workspace" }, "one fresh ready")
  local run_count = 0
  for _, command in ipairs(daemon.commands) do
    if command.type == "run" then
      run_count = run_count + 1
    end
  end
  equal(run_count, 1, "effectful command never replayed")
end)

test("controller rejects stale generation events and disconnect callbacks", function()
  local path = temp_socket()
  local daemon = FakeDaemon.new(path)
  daemon:start()
  local controller = Controller.new({ path = path, work_dir = "/workspace" })
  cleanup[#cleanup + 1] = function()
    controller:close()
    daemon:stop()
  end

  truthy(controller:connect(), "first connect starts")
  wait_for(function()
    return #daemon.commands == 2
  end, "first generation")
  daemon:disconnect_client()
  wait_for(function()
    return controller.state.connection.stale
  end, "first disconnect")
  truthy(controller:connect(), "second connect starts")
  wait_for(function()
    return #daemon.commands == 4 and controller.state.connection.generation == 2
  end, "second generation")

  local accepted, stale_err = controller:receive(vim.json.encode({
    type = "status",
    tabId = "stale-tab",
    running = true,
  }), 1)
  equal(accepted, false, "stale event rejected")
  equal(stale_err, "stale connection generation", "stale diagnostic")
  equal(controller.state.tabs["stale-tab"], nil, "stale event cannot mutate state")
  controller:_disconnected("lost", 1)
  equal(controller.state.connection.connected, true, "stale disconnect cannot mark current connection stale")
  controller:_connected(1)
  vim.wait(20)
  equal(#daemon.commands, 4, "stale connect cannot send handshake")
  equal(controller.state.connection.generation, 2, "current generation preserved")
end)

test("actions route exact tabs and submit each command once", function()
  local controller, daemon = connected_controller()
  controller.state:apply({
    type = "tabs_state",
    tabs = {
      { tabId = "tab-a", chatId = "chat-a" },
      { tabId = "tab-b", chatId = "chat-b" },
    },
  })
  controller.state:apply({ type = "status", tabId = "tab-a", running = true })
  controller.state:apply({ type = "askUser", tabId = "tab-b", question = "Continue?" })
  local actions = Actions.new(controller)

  truthy(actions:run("tab-a", "build", { taskId = "client-task", useWorktree = false }), "run accepted")
  truthy(actions:stop("tab-a"), "stop accepted")
  truthy(actions:steer("tab-a", "focus tests"), "steering accepted")
  truthy(actions:answer("tab-b", "yes"), "answer accepted")
  truthy(actions:close_tab("tab-b"), "close accepted")
  wait_for(function()
    return #daemon.commands == 7
  end, "five task actions received")

  equal(vim.list_slice(daemon.commands, 3), {
    { type = "run", tabId = "tab-a", prompt = "build", taskId = "client-task", useWorktree = false },
    { type = "stop", tabId = "tab-a" },
    { type = "appendUserMessage", tabId = "tab-a", prompt = "focus tests" },
    { type = "userAnswer", tabId = "tab-b", answer = "yes" },
    { type = "closeTab", tabId = "tab-b" },
  }, "commands preserve exact targets and fields")
  equal(#daemon.commands - 2, 5, "one wire frame per accepted action")
end)

test("actions reject disconnected submissions without calling controller", function()
  local calls = 0
  local controller = {
    state = State.new(),
    send = function()
      calls = calls + 1
      return true, nil
    end,
  }
  controller.state.registry = { { tabId = "tab-a" } }
  controller.state.tabs["tab-a"] = { running = true, pending_question = "Q?", worktrees = {} }
  local actions = Actions.new(controller)

  for _, invoke in ipairs({
    function() return actions:run("tab-a", "go") end,
    function() return actions:stop("tab-a") end,
    function() return actions:steer("tab-a", "more") end,
    function() return actions:answer("tab-a", "yes") end,
    function() return actions:close_tab("tab-a") end,
    function() return actions:worktree_action("tab-a", "task-a", "discard") end,
  }) do
    local accepted, err = invoke()
    equal(accepted, false, "disconnected action rejected")
    equal(err, "disconnected; command not submitted", "disconnected diagnostic")
  end
  equal(calls, 0, "disconnected actions never reach controller")
end)

test("actions reject prior-generation tabs until fresh registry snapshot", function()
  local controller, daemon = connected_controller()
  controller.state:apply({ type = "tabs_state", tabs = { { tabId = "tab-old" } } })
  local actions = Actions.new(controller)
  truthy(actions:run("tab-old", "first"), "current-generation tab accepted")
  wait_for(function()
    return #daemon.commands == 3
  end, "first action received")

  daemon:disconnect_client()
  wait_for(function()
    return controller.state.connection.stale
  end, "disconnect observed")
  truthy(controller:connect(), "reconnect starts")
  wait_for(function()
    return #daemon.commands == 5 and controller.state.connection.generation == 2
  end, "second handshake received")

  local accepted, err = actions:run("tab-old", "stale")
  equal(accepted, false, "prior-generation registry target rejected")
  equal(err, "unknown or stale tab: tab-old", "prior-generation target diagnostic")
  equal(#daemon.commands, 5, "stale target creates no wire command")

  controller.state:apply({ type = "tabs_state", tabs = { { tabId = "tab-old" } } })
  truthy(actions:run("tab-old", "fresh"), "freshly confirmed target accepted")
  wait_for(function()
    return #daemon.commands == 6
  end, "fresh action received")
end)

test("actions reject invalid and stale contextual targets", function()
  local calls = 0
  local controller = {
    state = State.new(),
    send = function()
      calls = calls + 1
      return true, nil
    end,
  }
  controller.state:connected(1)
  controller.state:apply({ type = "tabs_state", tabs = { { tabId = "tab-a" }, { tabId = "tab-b" } } })
  controller.state:apply({ type = "status", tabId = "tab-a", running = false })
  controller.state:apply({
    type = "task_events",
    tabId = "tab-b",
    task_id = "task-current",
    events = {},
  })
  controller.state:apply({
    type = "worktree_done",
    tabId = "tab-b",
    taskId = "task-current",
    worktreeDir = "/tmp/wt",
  })
  local actions = Actions.new(controller)

  local _, missing_err = actions:run("missing", "go")
  equal(missing_err, "unknown or stale tab: missing", "unknown tab rejected")
  local _, override_err = actions:run("tab-a", "go", { tabId = "tab-b" })
  equal(override_err, "unsupported run option: tabId", "run target cannot be overridden")
  local _, future_err = actions:run("tab-a", "go", { futureField = true })
  equal(future_err, "unsupported run option: futureField", "unverified run field rejected")
  local _, stop_err = actions:stop("tab-a")
  equal(stop_err, "tab is not known to be running: tab-a", "idle stop rejected")
  local _, steer_err = actions:steer("tab-a", "more")
  equal(steer_err, "tab is not known to be running: tab-a", "idle steering rejected")
  local _, answer_err = actions:answer("tab-a", "yes")
  equal(answer_err, "tab has no known pending question: tab-a", "stale answer rejected")
  local _, task_err = actions:worktree_action("tab-b", "task-old", "merge")
  equal(task_err, "task is not current for tab: task-old", "stale worktree task rejected")
  local _, action_err = actions:worktree_action("tab-b", "task-current", "retry")
  equal(action_err, "invalid worktree action: retry", "unknown worktree action rejected")
  equal(calls, 0, "invalid targets never reach controller")
end)

test("worktree action fails closed despite exact current task identity", function()
  local sent = {}
  local controller = {
    state = State.new(),
    send = function(_, command)
      sent[#sent + 1] = vim.deepcopy(command)
      return true, nil
    end,
  }
  controller.state:connected(1)
  controller.state:apply({ type = "tabs_state", tabs = { { tabId = "tab-w" } } })
  controller.state:apply({
    type = "task_events",
    tabId = "tab-w",
    task_id = "persisted-task",
    events = {},
  })
  controller.state:apply({
    type = "worktree_done",
    tabId = "tab-w",
    taskId = "persisted-task",
    worktreeDir = "/tmp/worktree",
  })
  local actions = Actions.new(controller)

  local accepted, err = actions:worktree_action("tab-w", "persisted-task", "nothing")
  equal(accepted, false, "current-looking worktree still fails closed")
  equal(err, "worktree action ownership cannot be proven by current protocol", "ownership diagnostic")
  equal(#sent, 0, "worktree command not sent without ownership proof")

  controller.state:apply({ type = "worktree_result", tabId = "tab-w", success = true })
  local completed, completed_err = actions:worktree_action("tab-w", "persisted-task", "discard")
  equal(completed, false, "completed action remains rejected")
  equal(completed_err, "worktree action ownership cannot be proven by current protocol", "completed diagnostic")
  equal(#sent, 0, "rejected resubmission adds no local send")
end)

test("openTab stays unusable until current-generation canonical confirmation", function()
  local controller, daemon = connected_controller()
  controller.state:apply({ type = "tabs_state", tabs = {} })
  local lifecycle = TabLifecycle.new(controller)
  local actions = Actions.new(controller)

  truthy(lifecycle:open("tab-new", { title = "New", workDir = "/workspace/project" }), "open submitted")
  wait_for(function()
    return #daemon.commands == 3
  end, "openTab received")
  equal(daemon.commands[3], {
    type = "openTab",
    tabId = "tab-new",
    title = "New",
    workDir = "/workspace/project",
  }, "open command exact")
  equal(lifecycle:status("tab-new").state, "pending", "attempt pending")
  local accepted, err = actions:run("tab-new", "too soon")
  equal(accepted, false, "pending tab unusable")
  equal(err, "unknown or stale tab: tab-new", "canonical guard remains authoritative")

  daemon:send_events({ { type = "tabs_state", tabs = { { tabId = "tab-new" } } } })
  wait_for(function()
    return lifecycle:status("tab-new").state == "confirmed"
  end, "canonical confirmation")
  truthy(actions:run("tab-new", "now usable"), "confirmed tab usable")
  wait_for(function()
    return #daemon.commands == 4
  end, "run after confirmation")

  daemon:send_events({ { type = "tabs_state", tabs = { { tabId = "tab-new" } } } })
  vim.wait(20)
  equal(lifecycle:status("tab-new").state, "confirmed", "duplicate snapshot is idempotent")
  equal(lifecycle:status("tab-new").confirmations, 1, "duplicate callback not counted")
end)

test("openTab handles rejection, disconnect, and stale-generation callbacks", function()
  local controller, daemon = connected_controller()
  controller.state:apply({ type = "tabs_state", tabs = {} })
  local lifecycle = TabLifecycle.new(controller)

  truthy(lifecycle:open("tab-rejected"), "rejected attempt submitted")
  wait_for(function()
    return #daemon.commands == 3
  end, "first open received")
  daemon:send_events({ { type = "openTabRejected", tabId = "tab-rejected", text = "tab limit" } })
  wait_for(function()
    return lifecycle:status("tab-rejected").state == "rejected"
  end, "rejection handled")
  equal(lifecycle:status("tab-rejected").text, "tab limit", "rejection reason retained")
  equal(controller.state.tabs["tab-rejected"], nil, "rejection creates no canonical tab")
  local retry, retry_err = lifecycle:open("tab-rejected")
  equal(retry, false, "same-generation rejected ID cannot retry ambiguously")
  equal(retry_err, "openTab already attempted in this generation: tab-rejected", "rejected retry diagnostic")

  truthy(lifecycle:open("tab-pending"), "second attempt submitted")
  wait_for(function()
    return #daemon.commands == 4
  end, "second open received")
  daemon:disconnect_client()
  wait_for(function()
    return controller.state.connection.stale
  end, "disconnect observed")
  equal(lifecycle:status("tab-pending").state, "stale", "pending attempt invalidated")
  truthy(controller:connect(), "reconnect starts")
  wait_for(function()
    return #daemon.commands == 6 and controller.state.connection.generation == 2
  end, "new generation handshake")

  local stale_snapshot = vim.json.encode({ type = "tabs_state", tabs = { { tabId = "tab-pending" } } })
  equal(controller:receive(stale_snapshot, 1), false, "stale confirmation rejected by controller")
  equal(lifecycle:status("tab-pending").state, "stale", "stale confirmation cannot revive attempt")
  controller:_notify({ type = "openTabRejected", tabId = "tab-pending", text = "late" }, 1)
  equal(lifecycle:status("tab-pending").state, "stale", "stale rejection callback ignored")
  equal(controller.state.tabs["tab-pending"], nil, "stale callback cannot create tab")
end)

test("openTab validates targets and submits exactly once while connected", function()
  local controller, daemon = connected_controller()
  controller.state:apply({ type = "tabs_state", tabs = {} })
  local lifecycle = TabLifecycle.new(controller)

  local accepted, err = lifecycle:open("")
  equal(accepted, false, "empty ID rejected")
  equal(err, "tab_id must be a non-empty string", "empty ID diagnostic")
  equal(#daemon.commands, 2, "invalid open not sent")
  truthy(lifecycle:open("tab-once"), "valid open accepted")
  local duplicate, duplicate_err = lifecycle:open("tab-once")
  equal(duplicate, false, "duplicate pending attempt rejected")
  equal(duplicate_err, "openTab already attempted in this generation: tab-once", "duplicate diagnostic")
  wait_for(function()
    return #daemon.commands == 3
  end, "one open command")
  equal(#daemon.commands - 2, 1, "accepted attempt submitted exactly once")
  local status = lifecycle:status("tab-once")
  status.state = "confirmed"
  equal(lifecycle:status("tab-once").state, "pending", "status snapshot cannot mutate lifecycle")

  daemon:disconnect_client()
  wait_for(function()
    return controller.state.connection.stale
  end, "disconnect")
  local offline, offline_err = lifecycle:open("tab-offline")
  equal(offline, false, "disconnected open rejected")
  equal(offline_err, "disconnected; command not submitted", "disconnected diagnostic")
  equal(#daemon.commands, 3, "disconnected open not queued")
end)

test("openTab write failure is terminal and never retried automatically", function()
  local send_callback
  local sends = 0
  local listener
  local state = State.new()
  state:connected(1)
  state:apply({ type = "tabs_state", tabs = {} })
  local controller = {
    state = state,
    add_listener = function(_, callback)
      listener = callback
      return function() listener = nil end
    end,
    send = function(_, _, callback)
      sends = sends + 1
      send_callback = callback
      return true, nil
    end,
  }
  local lifecycle = TabLifecycle.new(controller)
  truthy(lifecycle:open("tab-write"), "open locally accepted")
  send_callback("EPIPE")
  equal(lifecycle:status("tab-write").state, "write_failed", "asynchronous write failure retained")
  equal(lifecycle:status("tab-write").text, "EPIPE", "write failure diagnostic retained")
  local retry, retry_err = lifecycle:open("tab-write")
  equal(retry, false, "same-generation retry forbidden")
  equal(retry_err, "openTab already attempted in this generation: tab-write", "ambiguous retry diagnostic")
  equal(sends, 1, "write failure causes no automatic or manual same-generation replay")
  lifecycle:close()
  equal(listener, nil, "lifecycle observer disposed")
end)

test("controller observers isolate failures and support disposal", function()
  local errors = {}
  local transport_options
  local controller = Controller.new({
    path = "/unused",
    work_dir = "/workspace",
    on_error = function(err)
      errors[#errors + 1] = err
    end,
    transport_factory = function(options)
      transport_options = options
      return {
        connect = function() return true, nil end,
        close = function() end,
        send = function() return true, nil end,
      }
    end,
  })
  local calls = 0
  controller:add_listener(function()
    error("observer broke")
  end)
  local unsubscribe = controller:add_listener(function()
    calls = calls + 1
  end)
  transport_options.on_connect(1)
  controller:receive(vim.json.encode({ type = "tabs_state", tabs = {} }), 1)
  equal(calls, 2, "later observer runs after earlier observer failure")
  truthy(#errors >= 2 and tostring(errors[#errors]):find("observer broke", 1, true), "observer errors reported")
  unsubscribe()
  controller:receive(vim.json.encode({ type = "tabs_state", tabs = {} }), 1)
  equal(calls, 2, "disposed observer no longer called")
end)

test("replayed worktree_done never authorizes worktreeAction", function()
  local calls = 0
  local controller = {
    state = State.new(),
    send = function()
      calls = calls + 1
      return true, nil
    end,
  }
  controller.state:connected(1)
  controller.state:apply({ type = "tabs_state", tabs = { { tabId = "tab-w" } } })
  controller.state:apply({
    type = "task_events",
    tabId = "tab-w",
    task_id = "historical-task",
    events = { { type = "worktree_done", taskId = "historical-task", worktreeDir = "/tmp/old" } },
  })
  equal(controller.state.tabs["tab-w"].worktrees["historical-task"], nil,
    "nested historical worktree event alone grants no state")
  controller.state.tabs["tab-w"].worktrees["historical-task"] = {
    task_id = "historical-task",
    pending_action = true,
  }
  controller.state:disconnected()
  controller.state:connected(2)
  controller.state:apply({ type = "tabs_state", tabs = { { tabId = "tab-w" } } })
  controller.state:apply({
    type = "task_events",
    tabId = "tab-w",
    task_id = "historical-task",
    events = {},
  })
  controller.state:apply({
    type = "worktree_done",
    tabId = "tab-w",
    taskId = "historical-task",
    worktreeDir = "/tmp/old",
  })
  local actions = Actions.new(controller)
  for _, action in ipairs({ "merge", "discard", "nothing" }) do
    local accepted, err = actions:worktree_action("tab-w", "historical-task", action)
    equal(accepted, false, action .. " fails closed")
    equal(err, "worktree action ownership cannot be proven by current protocol", action .. " diagnostic")
  end
  equal(calls, 0, "historical replay cannot cause mutation")
  equal(controller.state.tabs["tab-w"].worktrees["historical-task"].pending_action, false,
    "standalone replay-shaped event grants no permission")
  controller.state:apply({ type = "status", tabId = "tab-w", running = true })
  controller.state:apply({
    type = "worktree_done",
    tabId = "tab-w",
    taskId = "historical-task",
    worktreeDir = "/tmp/live-looking",
  })
  local live_accepted, live_err = actions:worktree_action("tab-w", "historical-task", "merge")
  equal(live_accepted, false, "identical event during running task also fails closed")
  equal(live_err, "worktree action ownership cannot be proven by current protocol", "live-looking diagnostic")
  equal(calls, 0, "no worktree mutation sent in any generation")
end)

test("reconnect running actions fail closed until current-generation status evidence", function()
  local controller, daemon = connected_controller()
  controller.state:apply({ type = "tabs_state", tabs = { { tabId = "tab-live" } } })
  controller.state:apply({ type = "status", tabId = "tab-live", running = true })
  controller.state:apply({ type = "askUser", tabId = "tab-live", question = "Continue?" })
  local actions = Actions.new(controller)
  truthy(actions:steer("tab-live", "before disconnect"), "fresh running target accepted")
  wait_for(function()
    return #daemon.commands == 3
  end, "initial steering received")

  daemon:disconnect_client()
  wait_for(function()
    return controller.state.connection.stale
  end, "disconnect observed")
  truthy(controller:connect(), "reconnect starts")
  wait_for(function()
    return #daemon.commands == 5 and controller.state.connection.generation == 2
  end, "new generation handshake")

  equal(controller.state.tabs["tab-live"].running, true, "retained running display value preserved")
  equal(controller.state.tabs["tab-live"].running_generation, 1, "running evidence remains prior-generation")
  controller.state:apply({ type = "tabs_state", tabs = { { tabId = "tab-live" } } })
  local stale_stop, stale_stop_err = actions:stop("tab-live")
  equal(stale_stop, false, "fresh registry alone cannot authorize stop")
  equal(stale_stop_err, "tab running state is stale: tab-live", "stale running diagnostic")
  local stale_steer, stale_steer_err = actions:steer("tab-live", "unsafe")
  equal(stale_steer, false, "fresh registry alone cannot authorize steering")
  equal(stale_steer_err, "tab running state is stale: tab-live", "stale steering diagnostic")
  local stale_answer, stale_answer_err = actions:answer("tab-live", "yes")
  equal(stale_answer, false, "fresh registry alone cannot authorize retained question answer")
  equal(stale_answer_err, "tab question state is stale: tab-live", "stale question diagnostic")
  equal(#daemon.commands, 5, "stale actions produce no effectful wire commands")

  controller.state:apply({ type = "status", tabId = "tab-live", running = true })
  truthy(actions:steer("tab-live", "after evidence"), "current-generation running evidence authorizes steering")
  wait_for(function()
    return #daemon.commands == 6
  end, "post-evidence steering received")
end)

test("controller reconstructs registry and per-tab replay without completion fiction", function()
  local path = temp_socket()
  local daemon = FakeDaemon.new(path)
  daemon:start()
  local controller = Controller.new({ path = path, work_dir = "/workspace" })
  cleanup[#cleanup + 1] = function()
    controller:close()
    daemon:stop()
  end

  controller.state:apply({ type = "status", tabId = "removed-tab", running = true })
  controller.state:apply({ type = "status", tabId = "tab-a", running = true })
  truthy(controller:connect(), "connect starts")
  wait_for(function()
    return #daemon.commands == 2
  end, "ready sent")
  daemon:send_events({
    {
      type = "tabs_state",
      tabs = {
        { tabId = "tab-a", chatId = "chat-a", taskId = "task-a" },
        { tabId = "tab-b", chatId = "chat-b", taskId = "task-b" },
      },
    },
    {
      type = "task_events",
      tabId = "tab-a",
      task_id = "task-a",
      chat_id = "chat-a",
      events = {
        { type = "prompt", text = "A" },
        { type = "result", text = "answer A" },
        { type = "task_done", endTs = 2 },
      },
    },
    {
      type = "task_events",
      tabId = "tab-b",
      task_id = "task-b",
      chat_id = "chat-b",
      events = {},
    },
    { type = "askUser", tabId = "tab-b", question = "B?" },
  }, true)
  wait_for(function()
    return controller.state.tabs["tab-b"] ~= nil
  end, "replay state applied")

  equal(controller.state.registry[1].tabId, "tab-a", "canonical registry replaced")
  equal(controller.state.tabs["tab-a"].history_task_id, "task-a", "task identity reconstructed")
  equal(controller.state.tabs["tab-a"].result.text, "answer A", "result reconstructed")
  equal(controller.state.tabs["tab-a"].lifecycle, "task_done", "lifecycle reconstructed separately")
  equal(controller.state.tabs["tab-a"].running, false, "terminal replay clears stale running state")
  equal(controller.state.tabs["tab-b"].pending_question, "B?", "pending question reconstructed")
  equal(controller.state.tabs["removed-tab"], nil, "canonical snapshot removes stale tab")
  equal(controller.state.replay_complete, nil, "no global replay-complete state invented")
  equal(controller.state.connection.replay_complete, nil, "connection has no completion fiction")
end)

test("minimal UI opens scratch view and renders distinct stream, result, lifecycle, and freshness", function()
  local controller, daemon = connected_controller()
  controller.state:apply({ type = "tabs_state", tabs = { { tabId = "ui-tab" } } })
  local lifecycle = TabLifecycle.new(controller)
  local ui = UI.new({
    actions = Actions.new(controller),
    controller = controller,
    tab_id = "ui-tab",
    tab_lifecycle = lifecycle,
    work_dir = "/workspace",
  })
  cleanup[#cleanup + 1] = function()
    ui:close()
    lifecycle:close()
  end

  local buffer = ui:open()
  equal(vim.bo[buffer].buftype, "nofile", "UI uses scratch buffer")
  equal(vim.bo[buffer].modifiable, false, "rendered UI remains read-only")
  controller.state:apply({ type = "status", tabId = "ui-tab", running = true })
  controller.state:apply({ type = "prompt", tabId = "ui-tab", text = "inspect repo" })
  controller.state:apply({ type = "thinking_start", tabId = "ui-tab" })
  controller.state:apply({ type = "thinking_delta", tabId = "ui-tab", text = "checking\r\nsecond line" })
  controller.state:apply({ type = "thinking_end", tabId = "ui-tab" })
  controller.state:apply({ type = "system_output", tabId = "ui-tab", text = "command output" })
  controller.state:apply({ type = "tool_call", tabId = "ui-tab", name = "shell", args = { command = "pwd" } })
  controller.state:apply({ type = "text_delta", tabId = "ui-tab", text = "answer" })
  controller.state:apply({ type = "result", tabId = "ui-tab", text = "semantic result" })
  ui:render()
  local before_lifecycle = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
  truthy(before_lifecycle:find("Task:       running (current-generation confirmed)", 1, true),
    "result leaves running status visible")
  truthy(before_lifecycle:find("## Result (not lifecycle completion)", 1, true),
    "result explicitly differs from lifecycle")
  truthy(before_lifecycle:find("checking\nsecond line", 1, true), "CRLF event text renders as legal buffer lines")
  truthy(before_lifecycle:find("## System output\ncommand output", 1, true), "system output renders")
  truthy(before_lifecycle:find("## Tool call", 1, true) and before_lifecycle:find('name = "shell"', 1, true),
    "nontext tool payload has visible fallback")
  equal(controller.state.tabs["ui-tab"].lifecycle, nil, "stream and result do not invent lifecycle")
  truthy(before_lifecycle:find("System prompt", 1, true) == nil, "internal system prompt stays hidden")

  controller.state:apply({ type = "task_done", tabId = "ui-tab" })
  ui:render()
  local after_lifecycle = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
  truthy(after_lifecycle:find("## Lifecycle\ntask_done", 1, true), "lifecycle rendered separately")
  truthy(after_lifecycle:find("Task:       running (current-generation confirmed)", 1, true),
    "lifecycle does not replace independent running status")
  controller.state:apply({ type = "status", tabId = "ui-tab", running = false })
  controller.state:apply({ type = "error", tabId = "ui-tab", text = "daemon refused follow-up" })
  ui:render()
  local completed = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
  truthy(completed:find("Task:       task_done (current-generation confirmed)", 1, true),
    "lifecycle shown after independent status false")
  truthy(completed:find("## Errors\ndaemon refused follow-up", 1, true), "daemon error renders")

  daemon:disconnect_client()
  wait_for(function()
    return controller.state.connection.stale
  end, "UI disconnect")
  ui:render()
  local stale = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
  truthy(stale:find("disconnected · retained state stale", 1, true), "connection staleness explicit")
  truthy(stale:find("retained/stale from generation 1", 1, true), "task freshness becomes retained")

  controller.state:connected(2)
  controller.state:apply({ type = "tabs_state", tabs = { { tabId = "ui-tab" } } })
  controller.state:apply({ type = "status", tabId = "ui-tab", running = false })
  ui:render()
  local fresh_idle = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
  truthy(fresh_idle:find("Task:       idle (current-generation confirmed)", 1, true),
    "fresh idle evidence overrides retained lifecycle")
end)

test("minimal UI opens tab before one run and routes stop and steering through actions", function()
  local controller, daemon = connected_controller()
  controller.state:apply({ type = "tabs_state", tabs = {} })
  local lifecycle = TabLifecycle.new(controller)
  local ui = UI.new({
    actions = Actions.new(controller),
    controller = controller,
    tab_id = "ui-new",
    tab_lifecycle = lifecycle,
    work_dir = "/workspace",
  })
  cleanup[#cleanup + 1] = function()
    ui:close()
    lifecycle:close()
  end
  ui:open()

  truthy(ui:submit("do work"), "UI open accepted")
  wait_for(function()
    return #daemon.commands == 3
  end, "UI openTab command")
  equal(daemon.commands[3].type, "openTab", "UI starts through openTab lifecycle")
  local early_run_count = 0
  for _, command in ipairs(daemon.commands) do
    if command.type == "run" then early_run_count = early_run_count + 1 end
  end
  equal(early_run_count, 0, "run waits for canonical confirmation")

  daemon:send_events({ { type = "tabs_state", tabs = { { tabId = "ui-new" } } } })
  wait_for(function()
    return #daemon.commands == 4
  end, "one run after confirmation")
  equal(daemon.commands[4], { type = "run", tabId = "ui-new", prompt = "do work", workDir = "/workspace" },
    "UI run uses action facade exact wire fields")
  local submitted_view = table.concat(vim.api.nvim_buf_get_lines(ui.buffer, 0, -1, false), "\n")
  truthy(submitted_view:find("## Prompt\ndo work", 1, true), "local submitted prompt renders")
  truthy(submitted_view:find("daemon delivery not inferred", 1, true), "local submission avoids delivery fiction")

  daemon:send_events({ { type = "status", tabId = "ui-new", running = true } })
  wait_for(function()
    local tab = controller.state.tabs["ui-new"]
    return tab and tab.running
  end, "running evidence")
  local second_run, second_run_err = ui:submit("unsafe second run")
  equal(second_run, false, "UI rejects second run while task is active")
  equal(second_run_err, "task already running: ui-new", "running-run diagnostic")
  truthy(ui:steer("focus tests"), "UI steering accepted by guard")
  truthy(ui:stop(), "UI stop accepted by guard")
  wait_for(function()
    return #daemon.commands == 6
  end, "guarded UI effects")
  equal(daemon.commands[5], { type = "appendUserMessage", tabId = "ui-new", prompt = "focus tests" },
    "steering routes through action facade")
  equal(daemon.commands[6], { type = "stop", tabId = "ui-new" }, "stop routes through action facade")

  daemon:disconnect_client()
  wait_for(function()
    return controller.state.connection.stale
  end, "disconnect before stale actions")
  local stale_stop = ui:stop()
  local stale_steer = ui:steer("unsafe")
  equal(stale_stop, false, "disconnected UI stop fails closed")
  equal(stale_steer, false, "disconnected UI steering fails closed")
  equal(#daemon.commands, 6, "failed-closed UI sends no effects")
end)

test("multiline composer edits, submits task through lifecycle, and cancels explicitly", function()
  local controller, daemon = connected_controller()
  controller.state:apply({ type = "tabs_state", tabs = {} })
  local lifecycle = TabLifecycle.new(controller)
  local ui = UI.new({
    actions = Actions.new(controller),
    controller = controller,
    tab_id = "ui-compose-task",
    tab_lifecycle = lifecycle,
    work_dir = "/workspace",
  })
  cleanup[#cleanup + 1] = function()
    ui:close()
    lifecycle:close()
  end
  local client_buffer = ui:open()

  local composer = ui:compose("task")
  truthy(composer and vim.api.nvim_buf_is_valid(composer), "task composer opens")
  equal(vim.bo[composer].buftype, "nofile", "composer uses scratch buffer")
  equal(vim.bo[composer].modifiable, true, "composer remains editable")
  equal(vim.bo[composer].readonly, false, "composer is not read-only")
  equal(vim.bo[composer].filetype, "kiss-sorcar-compose", "composer has dedicated filetype")
  equal(vim.api.nvim_get_current_buf(), composer, "composer receives focus")
  truthy(vim.fn.maparg("<C-s>", "n", false, true).buffer == 1, "Normal-mode submit mapping is buffer-local")
  truthy(vim.fn.maparg("<C-s>", "i", false, true).buffer == 1, "Insert-mode submit mapping is buffer-local")
  truthy(vim.fn.maparg("<C-c>", "n", false, true).buffer == 1, "Normal-mode cancel mapping is buffer-local")
  truthy(vim.fn.maparg("<C-c>", "i", false, true).buffer == 1, "Insert-mode cancel mapping is buffer-local")
  vim.api.nvim_buf_set_lines(composer, 0, -1, false, { "inspect repository", "then report" })
  truthy(ui:submit_composer(), "multiline task open accepted")
  wait_for(function() return #daemon.commands == 3 end, "composed task openTab command")
  equal(daemon.commands[3].type, "openTab", "composer task starts through lifecycle")
  equal(ui.composer_buffer, composer, "draft remains until deferred run is accepted")
  local pending_cancel, pending_cancel_err = ui:cancel_composer()
  equal(pending_cancel, false, "pending task cannot hide uncertain submission")
  equal(pending_cancel_err, "task submission is pending; draft cannot be cancelled", "pending cancel diagnostic")
  equal(ui.composer_buffer, composer, "pending cancel leaves draft visible")
  daemon:send_events({ { type = "tabs_state", tabs = { { tabId = "ui-compose-task" } } } })
  wait_for(function() return #daemon.commands == 4 end, "composed task run command")
  equal(daemon.commands[4], {
    type = "run",
    tabId = "ui-compose-task",
    prompt = "inspect repository\nthen report",
    workDir = "/workspace",
  }, "composer task uses action facade with exact multiline text")
  wait_for(function() return ui.composer_buffer == nil end, "composer closes after run acceptance")
  equal(vim.api.nvim_get_current_buf(), client_buffer, "successful submit returns to client")

  controller.state:apply({ type = "status", tabId = "ui-compose-task", running = false })
  local cancelled = ui:compose("task")
  vim.api.nvim_buf_set_lines(cancelled, 0, -1, false, { "must not send" })
  truthy(ui:cancel_composer(), "cancel accepted")
  equal(ui.composer_buffer, nil, "cancel closes composer")
  equal(#daemon.commands, 4, "cancel sends no command")
end)

test("multiline steering composer preserves failed-closed text for correction", function()
  local controller, daemon = connected_controller()
  controller.state:apply({ type = "tabs_state", tabs = { { tabId = "ui-compose-steer" } } })
  controller.state:apply({ type = "status", tabId = "ui-compose-steer", running = false })
  local lifecycle = TabLifecycle.new(controller)
  local ui = UI.new({
    actions = Actions.new(controller),
    controller = controller,
    tab_id = "ui-compose-steer",
    tab_lifecycle = lifecycle,
    work_dir = "/workspace",
  })
  cleanup[#cleanup + 1] = function()
    ui:close()
    lifecycle:close()
  end
  ui:open()

  local composer = ui:compose("steer")
  vim.api.nvim_buf_set_lines(composer, 0, -1, false, { "focus tests", "avoid docs" })
  local accepted, err = ui:submit_composer()
  equal(accepted, false, "idle steering fails closed")
  equal(err, "tab is not known to be running: ui-compose-steer", "action guard diagnostic preserved")
  equal(ui.composer_buffer, composer, "failed submission leaves draft open")
  equal(vim.api.nvim_buf_get_lines(composer, 0, -1, false), { "focus tests", "avoid docs" },
    "failed submission preserves exact draft")
  equal(#daemon.commands, 2, "failed steering reaches no wire command")

  controller.state:apply({ type = "status", tabId = "ui-compose-steer", running = true })
  truthy(ui:submit_composer(), "fresh running evidence accepts steering")
  wait_for(function() return #daemon.commands == 3 end, "composed steering command")
  equal(daemon.commands[3], {
    type = "appendUserMessage",
    tabId = "ui-compose-steer",
    prompt = "focus tests\navoid docs",
  }, "steering composer uses action facade exact multiline text")
end)

test("composer rejects ambiguity and clears state after external wipe", function()
  local controller, _ = connected_controller()
  controller.state:apply({ type = "tabs_state", tabs = {} })
  local lifecycle = TabLifecycle.new(controller)
  local ui = UI.new({
    actions = Actions.new(controller),
    controller = controller,
    tab_id = "ui-compose-lifecycle",
    tab_lifecycle = lifecycle,
    work_dir = "/workspace",
  })
  cleanup[#cleanup + 1] = function()
    ui:close()
    lifecycle:close()
  end
  ui:open()

  local invalid, invalid_err = ui:compose("other")
  equal(invalid, nil, "invalid composer kind rejected")
  equal(invalid_err, "composer kind must be task or steer", "invalid kind diagnostic")
  local composer = ui:compose("task")
  local conflict, conflict_err = ui:compose("steer")
  equal(conflict, nil, "different mode cannot reuse draft")
  equal(conflict_err, "composer already open for task", "mode conflict diagnostic")
  vim.api.nvim_buf_set_lines(composer, 0, -1, false, { "   ", "\t" })
  local blank, blank_err = ui:submit_composer()
  equal(blank, false, "whitespace-only draft rejected")
  equal(blank_err, "prompt must be a non-empty string", "blank draft diagnostic")
  equal(ui.composer_buffer, composer, "blank draft remains editable")

  vim.api.nvim_buf_delete(composer, { force = true })
  wait_for(function() return ui.composer_buffer == nil end, "external wipe clears composer state")
  equal(ui.composer_kind, nil, "external wipe clears composer mode")
  local cancel, cancel_err = ui:cancel_composer()
  equal(cancel, false, "cancel after external wipe is harmless")
  equal(cancel_err, "composer is not open", "closed composer diagnostic")
end)

test("UI clears pending task on asynchronous openTab write failure", function()
  local send_callback
  local state = State.new()
  state:connected(1)
  state:apply({ type = "tabs_state", tabs = {} })
  local controller = {
    state = state,
    add_listener = function()
      return function() end
    end,
    send = function(_, _, callback)
      send_callback = callback
      return true, nil
    end,
  }
  local lifecycle = TabLifecycle.new(controller)
  local ui = UI.new({
    actions = Actions.new(controller),
    controller = controller,
    tab_id = "ui-write-fail",
    tab_lifecycle = lifecycle,
    work_dir = "/workspace",
  })
  cleanup[#cleanup + 1] = function()
    ui:close()
    lifecycle:close()
  end
  ui:open()
  local composer = ui:compose("task")
  vim.api.nvim_buf_set_lines(composer, 0, -1, false, { "never run", "keep this draft" })
  truthy(ui:submit_composer(), "openTab accepted before async failure")
  equal(ui.composer_buffer, composer, "pending open retains composer")
  send_callback("EPIPE")
  wait_for(function()
    return ui.pending_prompt == nil
  end, "write failure updates UI without unrelated event")
  local view = table.concat(vim.api.nvim_buf_get_lines(ui.buffer, 0, -1, false), "\n")
  truthy(view:find("EPIPE", 1, true), "write failure shown")
  equal(ui.composer_buffer, composer, "failed deferred run retains composer")
  equal(vim.api.nvim_buf_get_lines(composer, 0, -1, false), { "never run", "keep this draft" },
    "failed open preserves exact draft")
  equal(#ui.local_prompts, 0, "failed open never records task as submitted")
end)

test("Agent Workbench backend diagnoses missing socket and reconnects when daemon appears", function()
  local path = temp_socket()
  local daemon
  local events = {}
  local raw_errors = {}
  local sink_fast_contexts = {}
  local backend = Backend.new({
    id = 99,
    cwd = "/workspace",
    path = path,
    reconnect_delays = { 10, 20 },
    on_error = function(err)
      raw_errors[#raw_errors + 1] = tostring(err)
    end,
  })
  cleanup[#cleanup + 1] = function()
    backend:close()
    if daemon then
      daemon:stop()
    end
  end

  truthy(backend:start(function(event)
    events[#events + 1] = event
    sink_fast_contexts[#sink_fast_contexts + 1] = vim.in_fast_event()
  end), "backend connect attempt starts")
  wait_for(function()
    return #events > 0 and events[#events].type == "error"
  end, "missing socket diagnostic")
  local diagnostic = events[#events].message
  truthy(diagnostic:find(path, 1, true), "diagnostic includes resolved socket path")
  truthy(diagnostic:find("ENOENT", 1, true), "diagnostic preserves error code")
  truthy(diagnostic:find("retrying automatically", 1, true), "diagnostic explains recovery")

  daemon = FakeDaemon.new(path)
  daemon:start()
  wait_for(function()
    return backend:is_running() and #daemon.commands == 2
  end, "backend reconnect and fresh handshake")
  equal(raw_errors[1], "ENOENT", "raw observer retains libuv error")
  equal(#events, 2, "duplicate connect failures are not rendered repeatedly")
  equal(events[2].type, "state_changed", "successful reconnect updates frontend state")
  equal(sink_fast_contexts, { false, false }, "backend sink never enters Workbench from a fast event")
end)

test("Agent Workbench backend lists and resumes exact Sorcar history", function()
  local path = temp_socket()
  local daemon = FakeDaemon.new(path)
  daemon:start()
  local events = {}
  local backend = Backend.new({ id = 100, cwd = "/workspace/kiss-sorcar", path = path })
  cleanup[#cleanup + 1] = function()
    backend:close()
    daemon:stop()
  end

  truthy(backend:start(function(event)
    events[#events + 1] = event
  end), "history backend connect starts")
  wait_for(function()
    return #daemon.commands == 2
  end, "history backend handshake")
  daemon:send_events({ { type = "tabs_state", tabs = {} } })
  wait_for(function()
    return #daemon.commands == 3 and daemon.commands[3].type == "openTab"
  end, "history backend opens tab")
  daemon:send_events({ { type = "tabs_state", tabs = { { tabId = "agent-workbench-100" } } } })
  wait_for(function()
    return backend.open_confirmed
  end, "history backend canonical tab")

  local listed
  local list_err
  truthy(backend:list_history(function(items, err)
    listed = items
    list_err = err
  end), "history list accepted")
  wait_for(function()
    return #daemon.commands == 4 and daemon.commands[4].type == "getHistory"
  end, "getHistory command")
  local generation = daemon.commands[4].generation
  local first_page = {
    {
      id = "chat-exact",
      task_id = "task-exact",
      title = "historical prompt",
      timestamp = 1787570000,
      work_dir = "/workspace/kiss-sorcar",
      has_events = true,
    },
    {
      id = "chat-legacy",
      task_id = "task-legacy",
      title = "legacy prompt",
      timestamp = 1787560000,
      work_dir = "./kiss-sorcar/",
      has_events = true,
    },
    {
      id = "chat-other",
      task_id = "task-other",
      title = "other project",
      timestamp = 1787550000,
      work_dir = "/workspace/other",
      has_events = true,
    },
  }
  for index = 1, 47 do
    first_page[#first_page + 1] = {
      id = "chat-page-" .. index,
      task_id = "task-page-" .. index,
      title = "page item " .. index,
      timestamp = 1787540000 - index,
      work_dir = "/workspace/kiss-sorcar",
      has_events = true,
    }
  end
  daemon:send_events({ {
    type = "history",
    generation = generation,
    offset = 0,
    sessions = first_page,
  } })
  wait_for(function()
    return #daemon.commands == 5 and daemon.commands[5].type == "getHistory"
  end, "second history page request")
  equal(daemon.commands[5].offset, 50, "history pagination advances by daemon page size")
  daemon:send_events({ {
    type = "history",
    generation = generation,
    offset = 50,
    sessions = { {
      id = "chat-final-page",
      task_id = "task-final-page",
      title = "final page item",
      timestamp = 1787530000,
      work_dir = "/workspace/kiss-sorcar",
      has_events = true,
    } },
  } })
  wait_for(function()
    return listed ~= nil
  end, "history list callback")
  equal(list_err, nil, "history list succeeds")
  equal(#listed, 50, "history list paginates and keeps workspace plus legacy records")
  equal(listed[1].task_id, "task-exact", "history remains newest first")

  daemon:send_events({ { type = "status", tabId = "agent-workbench-100", running = true } })
  wait_for(function()
    local tab = backend.controller.state.tabs["agent-workbench-100"]
    return tab and tab.running
  end, "running tab before history rejection")
  local busy_ok, busy_err = backend:load_history(listed[1], function() end)
  equal(busy_ok, false, "history resume rejects an active current task")
  equal(busy_err, "cannot resume history while the current Sorcar task is running", "busy resume diagnostic")
  equal(#daemon.commands, 5, "busy history resume sends no command")
  daemon:send_events({ { type = "status", tabId = "agent-workbench-100", running = false } })
  wait_for(function()
    local tab = backend.controller.state.tabs["agent-workbench-100"]
    return tab and not tab.running
  end, "idle tab before history resume")

  local loaded
  local load_err
  truthy(backend:load_history(listed[1], function(result, err)
    loaded = result
    load_err = err
  end), "history load accepted")
  wait_for(function()
    return #daemon.commands == 6 and daemon.commands[6].type == "resumeSession"
  end, "resumeSession command")
  equal(daemon.commands[6].chatId, "chat-exact", "resume targets exact chat")
  equal(daemon.commands[6].taskId, "task-exact", "resume pins exact task")
  equal(daemon.commands[6].tabId, "agent-workbench-100", "resume keeps backend tab")
  daemon:send_events({ {
    type = "task_events",
    tabId = "agent-workbench-100",
    task_id = "task-exact",
    chat_id = "chat-wrong",
    task = "wrong chat",
    events = {},
  } })
  wait_for(function()
    return load_err ~= nil
  end, "wrong-chat history rejection")
  equal(loaded, nil, "wrong-chat history never renders")
  equal(load_err, "daemon resumed a different Sorcar chat than requested", "wrong-chat resume diagnostic")

  loaded = nil
  load_err = nil
  truthy(backend:load_history(listed[1], function(result, err)
    loaded = result
    load_err = err
  end), "exact history retry accepted")
  wait_for(function()
    return #daemon.commands == 7 and daemon.commands[7].type == "resumeSession"
  end, "exact resumeSession retry")
  daemon:send_events({ {
    type = "task_events",
    tabId = "agent-workbench-100",
    task_id = "task-exact",
    chat_id = "chat-exact",
    task = "historical prompt",
    events = {
      { type = "prompt", text = "historical prompt", ts = 1000 },
      { type = "thinking_start", ts = 1001 },
      { type = "thinking_delta", text = "historical reasoning", ts = 1002 },
      { type = "thinking_end", ts = 1003 },
      { type = "result", text = "historical answer", ts = 1004, success = true },
      { type = "task_done", ts = 1005 },
    },
  } })
  wait_for(function()
    return loaded ~= nil
  end, "history load callback")
  equal(load_err, nil, "history load succeeds")
  equal(loaded.task_id, "task-exact", "loaded result preserves task identity")
  equal(loaded.messages[1].role, "user", "history replay restores user turn")
  equal(loaded.messages[1].content, "historical prompt", "history replay restores prompt text")
  equal(loaded.messages[2].role, "assistant", "history replay restores assistant turn")
  equal(loaded.messages[2].content[1], { type = "thinking", thinking = "historical reasoning" },
    "history replay restores reasoning")
  equal(loaded.messages[2].content[2], { type = "text", text = "historical answer" },
    "history replay restores final answer")
  for _, event in ipairs(events) do
    truthy(event.type ~= "text_delta", "history replay is returned once instead of streaming duplicate text")
  end
  truthy(backend:prompt("continue restored chat"), "restored history accepts a new turn")
  wait_for(function()
    return #daemon.commands == 8 and daemon.commands[8].type == "run"
  end, "restored history follow-on run")
  equal(daemon.commands[8].tabId, "agent-workbench-100", "continued turn stays on resumed tab")
  equal(daemon.commands[8].prompt, "continue restored chat", "continued turn keeps exact prompt")
  local pending_ok, pending_err = backend:load_history(listed[1], function() end)
  equal(pending_ok, false, "history resume rejects a locally accepted run awaiting daemon status")
  equal(pending_err, "cannot resume history while the current Sorcar task is running", "pending run diagnostic")
  equal(#daemon.commands, 8, "pending-run history resume sends no command")
end)

test("plugin setup preserves filesystem root workspace", function()
  local client = require("kiss-sorcar").setup({
    connect = false,
    socket_path = "/unused",
    work_dir = "/",
  })
  equal(client.controller.work_dir, "/", "root workspace remains nonempty")
  require("kiss-sorcar").close()
end)

test("plugin commands load and Sorcar opens one normal scratch buffer", function()
  local path = temp_socket()
  local daemon = FakeDaemon.new(path)
  daemon:start()
  vim.env.KISS_SORCAR_SOCK = path
  cleanup[#cleanup + 1] = function()
    require("kiss-sorcar").close()
    daemon:stop()
    vim.env.KISS_SORCAR_SOCK = nil
    pcall(vim.api.nvim_del_user_command, "Sorcar")
    pcall(vim.api.nvim_del_user_command, "SorcarStop")
    pcall(vim.api.nvim_del_user_command, "SorcarSteer")
    vim.g.loaded_kiss_sorcar = nil
  end
  vim.cmd("source " .. vim.fn.fnameescape(root .. "/plugin/kiss-sorcar.lua"))
  truthy(vim.fn.exists(":Sorcar") == 2, ":Sorcar registered")
  truthy(vim.fn.exists(":SorcarStop") == 2, ":SorcarStop registered")
  truthy(vim.fn.exists(":SorcarSteer") == 2, ":SorcarSteer registered")
  vim.cmd("Sorcar")
  local first = vim.api.nvim_get_current_buf()
  truthy(vim.api.nvim_buf_get_name(first):find("kiss-sorcar://client/", 1, true) ~= nil,
    ":Sorcar opens named scratch view")
  vim.cmd("Sorcar")
  equal(vim.api.nvim_get_current_buf(), first, "repeated :Sorcar focuses same client buffer")
  wait_for(function()
    return #daemon.commands == 2
  end, "plugin controller handshake")
  local plugin_client = require("kiss-sorcar").get()
  daemon:send_events({
    { type = "tabs_state", tabs = { { tabId = plugin_client.ui.tab_id } } },
    { type = "status", tabId = plugin_client.ui.tab_id, running = true },
  }, true)
  wait_for(function()
    local tab = plugin_client.controller.state.tabs[plugin_client.ui.tab_id]
    return tab and tab.running
  end, "plugin command running evidence")
  vim.cmd("SorcarSteer command route")
  vim.cmd("SorcarStop")
  wait_for(function()
    return #daemon.commands == 4
  end, "plugin stop and steer commands")
  equal(daemon.commands[3], {
    type = "appendUserMessage",
    tabId = plugin_client.ui.tab_id,
    prompt = "command route",
  }, ":SorcarSteer forwards exact argument")
  equal(daemon.commands[4], { type = "stop", tabId = plugin_client.ui.tab_id },
    ":SorcarStop routes guarded action")
end)

if selected_test and selected_test ~= "" and passed + failed == 0 then
  failed = 1
  print("FAIL no test at SORCAR_TEST=" .. selected_test)
end

for index = #cleanup, 1, -1 do
  local ok, err = pcall(cleanup[index])
  if not ok then
    failed = failed + 1
    print("FAIL cleanup\n" .. tostring(err))
  end
end
vim.wait(50)
print(string.format("RESULT %d passed, %d failed", passed, failed))
if failed > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("quit")
end
