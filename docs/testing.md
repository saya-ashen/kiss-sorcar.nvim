# Protocol test harness

## Scope

Harness tests client protocol behavior before UI or full client implementation. Normal tests do not start or import KISS Sorcar daemon. They use Neovim's built-in Lua runtime, `vim.json`, and `vim.uv`.

Run all tests:

```sh
nvim --headless -u NONE -l tests/run.lua
```

Run one independent test, useful for split execution:

```sh
SORCAR_TEST=3 nvim --headless -u NONE -l tests/run.lua
```

No test framework or external Lua dependency is required.

## Components

```text
tests/fake_daemon.lua
  real vim.uv Unix-domain listener
  raw chunk writes and NDJSON event writes
  received-command capture

lua/kiss-sorcar/transport.lua
  connection-scoped byte buffer
  newline framing
  Unix-domain client generations
  connected-only writes; no reconnect queue

lua/kiss-sorcar/protocol.lua
  JSON object decoding
  client command guards and NDJSON encoding
  explicit replay-safe allowlist; unknown commands unsafe

lua/kiss-sorcar/controller.lua
  one handshake per transport generation
  ordered fresh setWorkDir and ready
  generation-gated event dispatch
  caller-driven reconnect; no outbound replay queue

lua/kiss-sorcar/actions.lua
  connected-only task command facade
  exact canonical-tab routing
  known running/question stale-target guards
  one direct controller send; no queue, retry, or replay
  worktree mutation fails closed without daemon ownership proof

lua/kiss-sorcar/tab_lifecycle.lua
  connected-only openTab submission
  pending/rejected/stale attempt tracking outside canonical state
  usability only after current-generation tabs_state confirmation

lua/kiss-sorcar/state.lua
  per-tab event routing
  result, lifecycle, and running-state separation
  pending-question state
  bounded unknown-event diagnostics
  per-task worktree state
```

Tests use a real Unix-domain stream between fake daemon and client. Only daemon behavior is fake. This catches stream-boundary and handle-lifecycle errors that direct parser calls cannot catch.

## Tested invariants

1. Stream reads do not define frames. One frame can arrive across writes; several frames can arrive in one write.
2. Buffer stores bytes until newline. A write may split a multibyte UTF-8 code point without corrupting decoded JSON.
3. Empty lines are ignored. Oversized complete or incomplete frames fail explicitly.
4. Events route by their wire `tabId`; arrival order can interleave tabs.
5. `result` records agent output but does not set lifecycle or end `running` state.
6. `task_done`, `task_error`, `task_stopped`, and `task_interrupted` record lifecycle outcome. Later `status{running:false}` independently ends running state.
7. `appendUserMessage` and `userAnswer` retain exact target tab. `askUserDone` clears only its routed tab.
8. Unknown events are nonfatal and retained only in a bounded diagnostic ring.
9. Worktree state is keyed by persisted task identity, not prompt, active tab, or client submission ID.
10. Disconnect marks retained state stale, discards partial frame bytes, and creates a new connection generation on explicit reconnect.
11. Each successful generation sends fresh `setWorkDir` followed by exactly one `ready`. These commands are controller-owned; stale or duplicate connect callbacks cannot repeat them.
12. `tabs_state` replaces canonical registry membership. Replayed `task_events` replaces each addressed transcript and derives result/lifecycle state; terminal replay clears stale running state.
13. Frames and disconnect callbacks from stale generations cannot mutate current state. No global replay-complete flag exists.
14. Disconnected commands are rejected. No command queue exists, so `run`, `appendUserMessage`, `userAnswer`, `worktreeAction`, and other effectful commands cannot replay automatically.
15. Task actions accept only canonical tabs from a `tabs_state` received in current connection generation; absent or prior-generation tabs are rejected as unknown or stale before encoding or transport writes.
16. `stop` and `appendUserMessage` require a tab currently known as running from a `status` event received in current connection generation. Fresh canonical membership alone cannot refresh retained running evidence. `userAnswer` requires a pending question received or replayed in current generation. These checks reject targets state can prove stale; they do not claim daemon ownership.
17. `worktreeAction` validates action, canonical tab, and exact persisted task, then fails closed. Neither replayed nor standalone `worktree_done` grants mutation permission because wire protocol cannot prove live daemon ownership.
18. Every accepted task-facade call performs one direct controller send and produces one wire frame. Rejected calls produce none.
19. `openTab` is connected-only and submitted once. Pending attempts do not create canonical tab state and cannot become task-action targets.
20. Only `tabs_state` from attempt's current connection generation confirms opened tab. Duplicate snapshots are idempotent; disconnect makes pending attempt stale.
21. `openTabRejected{tabId,text}` rejects matching current pending attempt without creating tab state. Stale-generation confirmations and rejection callbacks are ignored.

## Fake-daemon boundaries

Fake daemon verifies transport and state semantics, not backend implementation. It does not model persistence, canonical tab registry rules, model execution, tool execution, Git operations, sub-agent threads, or daemon shutdown recovery. Event fixtures represent wire shapes verified in `docs/protocol.md`.

Harness intentionally does not add retry logic. Current protocol has no generic request ID, delivery acknowledgment, idempotency key, daemon-instance ID, event cursor, or replay-complete marker. After a successful local write followed by disconnect, client cannot know whether daemon dispatched an effectful command. Automatic retry would risk duplicate work or misroute context-sensitive input.

## Remaining protocol limitations

- Reconnect reconstruction through `ready`, `tabs_state`, and per-tab `task_events` has no global completion boundary. Harness verifies generation isolation, not completeness of daemon replay.
- Running replay can duplicate an event around subscription/snapshot timing. Events have no stable event ID, so safe content deduplication is unavailable.
- `appendUserMessage` and `userAnswer` have no acknowledgment. Unroutable commands can be silently dropped.
- `userAnswer` and `askUserDone` carry no question ID. A client cannot prove an answer belongs to a specific replayed question across races.
- Client `run.taskId`, persisted `task_id`, event `taskId`, and tab identity are not one namespace. Harness preserves separate submission and history task fields but cannot negotiate malformed or future wire variants.
- Worktree action commands have no request ID. Historical worktree events do not prove current daemon owns a live action handle after restart.
- Protocol lacks version and capability negotiation. Unknown events are tolerated, but changed meaning of known events cannot be detected automatically.
- Daemon and VS Code client use different practical frame-limit accounting. Harness defaults to daemon's 64 MiB byte ceiling; it does not claim parity with JavaScript UTF-16 counting.
- Invalid UTF-8 behavior is delegated to supported Neovim's `vim.json.decode`; harness verifies valid code points split across stream chunks, not every malformed byte sequence.

## Controller boundary

Reconnect remains explicit and caller-driven. Controller reports local encode/write errors but cannot prove daemon dispatch: current protocol provides no acknowledgment for `setWorkDir`, `ready`, or effectful commands. Receiving `tabs_state` or any set of `task_events` also cannot prove global replay completion because daemon emits no replay boundary.

## Command facade boundary

Facade supports `run`, `stop`, `appendUserMessage`, `userAnswer`, and `closeTab`. It validates `worktreeAction` inputs but always fails closed before send: current wire command carries only `tabId` and `action`, while `worktree_done` can be historical replay and carries no daemon-instance or ownership token. `run` accepts only source-verified optional fields and does not permit routing-field overrides. Local acceptance is not daemon acknowledgment. Between state event receipt and command dispatch, backend ownership can change. `closeTab` intentionally does not imply stop.

## Tab lifecycle boundary

`TabLifecycle` tracks open attempts separately from canonical application state. `open()` sends one connected-only `openTab`; it never inserts requested ID into `state.registry` or `state.tabs`. Matching `openTabRejected`, asynchronous write failure, or disconnect is terminal for attempt. Only current-generation `tabs_state` containing requested ID confirms it. Protocol has no open request ID, so same `tabId` gets at most one local attempt of any outcome per generation; caller must use new ID or reconnect explicitly rather than risk binding delayed response to retry. Existing-ID `openTab` produces no response; facade rejects already canonical IDs instead of creating unresolvable attempt.

## Real-daemon integration

Real-daemon coverage is separate and opt-in. Default invocation skips without starting a process:

```sh
./tests/integration/run_control_plane.sh
```

Run isolated control-plane test explicitly:

```sh
KISS_REAL_DAEMON_TEST=1 ./tests/integration/run_control_plane.sh
```

`KISS_SOURCE_REPO` may override the source checkout; the default is the sibling directory `../kiss_ai`. The runner creates disposable `KISS_HOME`, workspace, database, tab registry, TLS files, logs, and Unix socket below ignored `./tmp/`. It starts `RemoteAccessServer` with explicit `uds_path`, no tunnel, loopback-only ephemeral HTTPS port, then terminates the daemon. Normal `~/.kiss` state is never selected.

Test performs only:

1. connect and send controller-owned `setWorkDir`, then one `ready`;
2. receive initial `tabs_state`;
3. send one `openTab` with unique ID, without retry;
4. receive `tabs_state` containing ID;
5. send `closeTab`;
6. receive `tabs_state` without ID.

It sends no `run`, stop, steering, answer, or worktree command. Successful fixture leaves `tabs.json` empty and `task_history` with zero rows.

### Real/fake differences observed

- Real daemon emits one global `tabs_state` for initial `ready`, another after successful `openTab`, and another after `closeTab`. This matches fake fixtures and protocol documentation.
- Successful `openTab` has no dedicated acknowledgment; confirmation still depends on later global `tabs_state`.
- Successful `closeTab` has no dedicated acknowledgment; removal still depends on later global `tabs_state`.
- Real daemon creates unrelated isolated service state during startup (`sorcar.db`, `tabs.json`, cron lock, TLS certificate, remote URL metadata, injection template, and ntfy topic). Isolation must cover all of `KISS_HOME`, not only history DB.
- Linux Unix-domain socket pathname limit rejected an initial absolute path nested under deep worktree. Runner uses short repo-relative pathname. Transport semantics did not differ; fixture path setup did.

## Real-daemon read-only run

Run integration remains separate and opt-in:

```sh
./tests/integration/run_task.sh
KISS_REAL_DAEMON_RUN_TEST=1 KISS_TEST_MODEL=codex/gpt-5.6-sol ./tests/integration/run_task.sh
```

Runner creates a committed disposable Git repository and isolated `KISS_HOME` under `./tmp/`, sends one `run`, writes every received event as NDJSON, closes the canonical tab only after `status{running:false}`, and verifies:

- disposable Git tree and porcelain status are unchanged;
- final `tabs.json` registry is empty;
- isolated history contains exactly one completed row;
- `result` precedes task lifecycle, which precedes terminal running state;
- any native `tool_call` has a matching `tool_result`.

Successful `codex/gpt-5.6-sol` addressed sequence was:

```text
setTaskText
clear
status(true)
system_prompt(early)
prompt(early)
task_settings
system_prompt
prompt
text_delta
thinking_start
thinking_delta
thinking_end
thinking_start
thinking_delta
thinking_end
text_delta
usage_info
text_delta
thinking_start
thinking_delta
thinking_end
thinking_start
thinking_delta
thinking_end
text_delta
usage_info
text_end
result
task_done
status(false)
```

Complete observed wire order, including global events, was:

```text
connection_connected
models
inputHistory
configData
tasks_updated
focusInput
remote_url
tabs_state(initial)
tabs_state(open confirmed)
setTaskText
tabs_state(run registry update)
clear
status(true)
system_prompt(early)
prompt(early)
tasks_updated
task_settings
system_prompt
prompt
text_delta
thinking_start
thinking_delta
thinking_end
thinking_start
thinking_delta
thinking_end
text_delta
usage_info
text_delta
thinking_start
thinking_delta
thinking_end
thinking_start
thinking_delta
thinking_end
text_delta
usage_info
text_end
result
tasks_updated
task_done
status(false)
tabs_state(close confirmed)
```

No ordering guarantee is inferred from this single trace beyond assertions sourced from daemon code and enforced by test.

### Real-run findings

- Core state assumption held: `result` did not end running state. `task_done` followed it, then `status{running:false}` ended running state.
- Client-supplied task ID appeared only on start/end status. Persisted task ID appeared on `task_settings`, normal stream events, and `result`. Early prompt events carried `taskId:""`.
- Codex CLI shell execution surfaced as paired `thinking_start` / `thinking_delta` / `thinking_end`, not `tool_call` / `tool_result`. Provider adapter therefore does not guarantee native tool event visibility even when real tool work occurs.
- Codex emitted a successful `result` with no `success`, `is_continue`, or `summary` fields because output was not parseable finish YAML. Explicit `success:false` identifies observed failures; missing `success` does not identify failure.
- Despite prompt saying execute command exactly once, Codex performed it twice across two steps. Protocol provides no tool invocation identity or backend-enforced read-only/tool-count constraint.
- `task_done` followed explicit failed results in authentication test runs. This matches documented backend behavior: normal agent return selects `task_done` even when parsed result says `success:false`.
- Initial run exposed an application-state gap: real `task_settings` was unknown. Current state handling now retains live and replayed settings as documented below.
- First fixture attempt inherited parent Git repository because archived files alone do not form a repository. Runner now initializes and commits an independent disposable repository before daemon launch.
- Real provider credentials are outside isolated `KISS_HOME`. Test initially exposed revoked Claude OAuth and malformed empty Codex auth; Codex device login restored execution. KISS history/state isolation does not imply provider-credential isolation.

No steering, stop, reconnect, or worktree action is exercised.

## Real-daemon live actions

Steering and stop coverage remains separate and opt-in:

```sh
./tests/integration/run_live_actions.sh
KISS_REAL_DAEMON_LIVE_ACTIONS_TEST=1 KISS_TEST_MODEL=codex/gpt-5.6-sol \
  ./tests/integration/run_live_actions.sh
```

Runner uses one isolated daemon and two unique disposable tabs in an independently committed disposable Git repository. It sends each `run`, `appendUserMessage`, and `stop` once, never reconnects or retries, records addressed wire events as NDJSON, closes tabs only after terminal state, and verifies empty final registry, two terminal history rows, and unchanged Git tree/status. It performs no worktree action.

Application state now treats `task_settings` as normal transcript metadata. Live and replayed events retain full event plus observed `settings`; `settings.task_id` and `settings.chat_id` populate persisted identities. `clear` removes previous settings. Observed payload fields are:

```text
model, work_dir, is_parallel, is_worktree, start_ts,
chat_id, task_id, is_subagent, max_budget
```

`max_budget` is optional in source. Sub-agent payloads may additionally include `parent_task_id`; state preserves fields without provider-specific interpretation. Outer live event carries `tabId`, persisted `taskId`, and `ts`.

### Steering trace

Exact addressed order from successful `codex/gpt-5.6-sol` run, with repeated stream groups collapsed only here for readability:

```text
setTaskText
clear
status(true)
system_prompt(early)
prompt(early)
task_settings
prompt(steering echo)
system_prompt
prompt
text_delta / thinking_* groups / usage_info
text_delta / thinking_* groups / usage_info
text_end
result
task_done
status(false)
```

Full uncollapsed order is written by fixture to `events.ndjson`. Test asserts steering echo arrives after `task_settings` and before `result`, exact unique marker reaches result, then `result < task_done < status(false)`. Daemon emits no steering acknowledgment. Echo proves daemon routed command to task transcript, while result marker proves model consumed instruction in this run; neither creates generic delivery guarantee for races. Queued steering forced another model step after first apparent finish output, so streamed text can contain provisional answer before final result.

### Stop trace

Exact addressed order from successful stop run:

```text
setTaskText
clear
status(true)
system_prompt(early)
prompt(early)
task_settings
stop_ack(true)
result{success:false,text:"Task stopped by user"}
task_stopped
status(false)
```

State retains `stop_ack` separately. Acknowledgment does not end running state or assign lifecycle. Semantic agent outcome remains `result.success == false`; execution lifecycle becomes `task_stopped`; final `status(false)` independently ends running state. Test does not assume stop always happens before first stream delta: timing/provider latency may put streaming events between `task_settings` and `stop_ack`.

### Live-action findings

- `appendUserMessage` has no acknowledgment. Real daemon immediately echoed routed input as persisted-task `prompt`, but an idle/racing target can still drop silently.
- `stop_ack{accepted:true}` arrived before cancellation result and lifecycle, matching backend source. It means target was found and signaled, not that cancellation completed.
- A stopped task emits semantic failure result before `task_stopped`, then terminal false status. `task_stopped` and `task_done` are execution lifecycle labels; neither alone should substitute for semantic success.
- Steering run's successful `result` again omitted `success`. Missing semantic-success field remains unknown, not failure or success.
- Codex emitted shell work only through `thinking_*`; neither scenario emitted native `tool_call` / `tool_result`. Tests accept either provider shape and parse no provider-specific thinking text.
- Client submission ID remained on status events. Persisted task ID appeared on `task_settings`, steering echo, stream, and result. Lifecycle events did not carry persisted task ID in these traces.
- Observed `task_settings.settings.work_dir` was the outer repository path, not disposable task cwd, because fixture itself lives below a `.kiss-worktrees/<name>` path and backend applies `strip_worktree_suffix()` even though `useWorktree=false`. Clients must preserve payload as reported; it is display metadata, not reliable execution-cwd identity for paths coincidentally nested below `.kiss-worktrees`.
- Wire has no steering request ID, stop request ID, or correlation ID on `stop_ack` beyond `tabId`. Exactly-once local sends do not establish exactly-once daemon effects after ambiguous connection loss.

User-answer, worktree mutation, and UI remain untested here.

## Real-daemon reconnect during running task

Reconnect coverage remains separate and opt-in:

```sh
./tests/integration/run_reconnect.sh
KISS_REAL_DAEMON_RECONNECT_TEST=1 KISS_TEST_MODEL=codex/gpt-5.6-sol \
  ./tests/integration/run_reconnect.sh
```

Runner uses isolated daemon state and independently committed disposable Git workspace. Test opens one tab, submits one bounded read-only task, waits for persisted `task_settings` plus live command streaming, closes only Neovim transport, leaves daemon and task running, reconnects manually, and lets controller send fresh `setWorkDir` then `ready`. It injects old-generation frame and disconnect callbacks after reconnect; neither may alter current state. It waits for canonical registry, replay, later live output, `task_done`, and `status(false)`, then closes tab.

Effect audit records facade submissions. Successful run sent exactly one `openTab`, one `run`, and one final `closeTab`. It sent no `stop`, `appendUserMessage`, `userAnswer`, or `worktreeAction`; handshake commands remain controller-owned and are freshly created once per connection generation rather than replayed from queue.

### Observed reconnect sequence

Exact successful event-type order was:

```text
g1: connection_connected
    models, inputHistory, configData, tasks_updated, focusInput, remote_url
    tabs_state(initial)
    tabs_state(open confirmation)
    setTaskText
    tabs_state(run registry update)
    clear
    status(true)
    system_prompt(early)
    prompt(early)
    tasks_updated
    task_settings
    system_prompt
    prompt
    text_delta
    thinking_start
    thinking_delta(command start)
    connection_disconnected

g3: connection_connected
    models, inputHistory, configData, tasks_updated, focusInput, remote_url
    tabs_state
    status(true)
    task_events
    thinking_start
    thinking_delta(command output)
    thinking_end
    text_delta
    text_delta
    usage_info
    thinking_start / thinking_delta / thinking_end
    thinking_start / thinking_delta / thinking_end
    text_delta
    usage_info
    text_end
    result
    tasks_updated
    task_done
    status(false)
    tabs_state(close confirmation)
    connection_disconnected
```

Generation changed from 1 to 3 because explicit `Transport.Client:close()` invalidates generation 1 by incrementing once, then next `connect()` allocates another generation. No assumption requires contiguous connected-generation numbers.

Observed `task_events` envelope reconstructed same persisted task ID and chat ID seen before disconnect. Its seven nested events were:

```text
task_settings
system_prompt
prompt
text_delta
thinking_start
thinking_delta(command start)
thinking_end
```

Daemon sent `status(true)` before `task_events`. Client therefore did not infer running state from retained tab or replay contents: current-generation status supplied evidence. Fresh `tabs_state` alone remained insufficient to authorize stop or steering. After replay, live command output and terminal events continued normally. Replay had no lifecycle terminal, so it did not lower running state; final live `task_done` and later live `status(false)` remained separate transitions.

No exact replay/live duplicate occurred in this trace. Comparison by full event object and by `(type, ts, text, taskId)` found zero duplicates. Test adds no event deduplication: protocol supplies no event ID, cursor, or safe replay boundary, and source still permits overlap around recording snapshot plus subscription. Repeated Codex command execution later in trace had different timestamps and was provider behavior, not duplicate wire delivery.

### Reconnect findings

- Disconnect leaves retained display state marked stale. It does not guess task completion or stop daemon execution.
- `tabs_state` confirms canonical membership for current generation, but does not prove task running state. `status` now records `running_generation`; stop and steering require that generation to match active connection.
- Before fresh registry, actions reject target as unknown or stale. After registry but before current-generation running evidence, running-task actions reject stale running state. Rejected actions produce no wire command.
- Old-generation event injection returned `stale connection generation`; old disconnect callback left current connection connected. Listener dispatch likewise remains generation-gated.
- Replay replaced transcript with persisted/live recording snapshot. Subsequent live events appended. No replay-complete state was invented, and terminal replay would still be authoritative evidence if present.
- Same task/chat identity survived disconnect and reconstruction. Client submission ID remains separate from persisted task ID.
- Semantic result and execution lifecycle remain independent. Successful result omitted no assumptions here; fixture waited for `task_done` and independently for `status(false)`.
- Disposable Git tree/status remained unchanged, isolated history contained one terminal row, and final isolated tab registry was empty.

## Minimal Neovim UI dogfood

Native UI and multiline composer are covered by eight focused fake-daemon end-to-end tests plus an isolated real-daemon test:

```sh
./tests/integration/run_ui.sh
KISS_REAL_DAEMON_UI_TEST=1 KISS_TEST_MODEL=codex/gpt-5.6-sol \
  ./tests/integration/run_ui.sh
```

`:Sorcar` opens one normal `nofile`, unlisted, read-only client buffer. In that view, `i` opens editable `nofile` task composer and `a` opens same composer for steering. `<C-s>` submits and `<C-c>` cancels in Normal or Insert mode; Normal-mode `<CR>` is terminal-safe submit fallback. Steering composer closes when `Actions:steer` accepts. New-task composer stays open through pending `openTab` and closes only after deferred `Actions:run` accepts. Cancel is blocked while that submission outcome is pending, avoiding hidden uncertain work. Rejected submission leaves exact draft open for correction. `I` retains `vim.ui.input` as one-line task fallback. `:Sorcar {task}` remains direct one-line path.

Task composer text joins buffer lines with literal newlines, opens a unique daemon tab when needed, waits for current-generation `tabs_state` confirmation, then calls `Actions:run` once. Steering composer text calls guarded `Actions:steer`. `:SorcarStop` and `s` call guarded `Actions:stop`; `:SorcarSteer {message}` remains a guarded command-line steering path. Composer and UI never call transport or controller `send` directly.

Header shows connection generation, client workspace, canonical tab freshness, current task status with evidence generation, and transcript freshness. Disconnect keeps visible content but labels it retained/stale. `result` has an explicit “not lifecycle completion” heading. Lifecycle gets a separate section, and running stays true until independent `status(false)` evidence arrives.

Real dogfood composes and submits one multiline read-only task, then composes and submits one multiline steering message. It checks editable composer state, accepted-submit closure, prompt, thinking, streamed response, result, `task_done`, terminal status, and no client errors. It then closes tab. Isolated persistence must contain one terminal task row, final tab registry must be empty, and Git tree/status must remain unchanged.

### UX findings

- Full-buffer redraw is adequate for first UI but scales poorly with long transcripts. Scheduled redraw coalescing prevents one redraw per delta and cursor row is preserved, but incremental extmark blocks remain later work.
- Real provider text included carriage returns. Passing those directly to `nvim_buf_set_lines` failed rendering; UI now normalizes CRLF at buffer boundary, with fake regression coverage.
- Showing replayed/live daemon prompt bodies made the view dominated by internal instructions, and current wire metadata cannot safely prove prompt origin. Minimal UI retains `prompt`/`system_prompt` in state but displays only locally submitted task/steering text, labeled as locally submitted with daemon delivery/completion unconfirmed.
- `usage_info` remains raw `vim.inspect` output. Useful, but noisy and unstable as user-facing formatting.
- Composer is a full editable buffer, but it currently replaces the client in current window rather than opening a dedicated split. This keeps window management minimal; side-by-side transcript reference remains unavailable while drafting.
- No reconnect automation exists. Disconnect is visible and actions fail closed, but user must recreate client connection through setup/reload.
- UI owns one generated tab. Existing daemon tabs are displayed only through freshness/state effects, not selectable; this is intentional for first increment.

### Next smallest useful increment

Add a small split composer buffer with multiline editing and explicit submit mapping, preserving current `TabLifecycle`/`Actions` route and fail-closed freshness checks. This fixes biggest daily-use problem without introducing history, model picker, completion, worktree controls, or another framework. Incremental/extmark transcript rendering should follow only when measured transcript size makes full redraw disruptive.

## Agent Workbench backend integration

Sorcar's `kiss-sorcar.backend` composes existing `Controller`, `State`, `TabLifecycle`, and `Actions`; Agent Workbench receives semantic events and never implements Sorcar transport or protocol. Backend events produced by `vim.uv` callbacks are scheduled onto Neovim's main loop before entering the Workbench sink, so downstream buffer, option, and workspace refresh APIs never run in fast-event context. The adapter owns caller-driven reconnect with delays capped at 5 seconds (`250`, `500`, `1000`, `2000`, then `5000` ms). Each recovered transport generation still performs only the controller's fresh reconstruction handshake; effectful commands are never replayed. Repeated identical connection failures render once until recovery, and `ENOENT`/`ECONNREFUSED` diagnostics include the resolved socket path and a recovery action. Tests can override `backend_options.reconnect_delays`; `backend_options.reconnect = false` disables retries.

Focused contract test:

```sh
cd agent-workbench.nvim
PLENARY_PATH=$(nix eval --raw nixpkgs#vimPlugins.plenary-nvim.outPath) \
  nvim --headless -i NONE -u tests/minimal_init.lua \
  -c "lua require('plenary.test_harness').test_file('../tests/backend_spec.lua', { minimal_init = 'tests/minimal_init.lua' })"
```

Opt-in isolated real-daemon dogfood:

```sh
./tests/integration/run_agent_workbench.sh
KISS_REAL_DAEMON_AGENT_WORKBENCH_TEST=1 KISS_TEST_MODEL=codex/gpt-5.6-sol \
  ./tests/integration/run_agent_workbench.sh
```

Observed successful normalized order was initial `state_changed` freshness snapshots, `run_started`, running-state confirmation, provider text/thinking groups, cumulative `usage_changed`, `semantic_result`, `execution_finished{reason="completed"}`, then `run_settled`. Agent Workbench remained busy through result and lifecycle; only daemon `status(false)` emitted `run_settled`. Real test ended with empty isolated tabs, one terminal history row, and unchanged disposable Git workspace.

Sorcar history uses paginated `getHistory` reads and exact `resumeSession{chatId,taskId,tabId}` loads through Agent Workbench's backend-owned history contract. Workspace filtering accepts exact/descendant paths plus same-basename legacy paths such as `./kiss-sorcar/`; empty-path and running rows remain visible. Resume is fail-closed while the current tab is running or awaiting daemon status, rejects running history entries, validates both returned chat and task IDs, pins the selected task instead of silently taking the latest chat task, and converts persisted prompt, reasoning, and final result into staged Workbench replay messages. Historical tool events remain omitted because Sorcar does not provide stable tool-call IDs for safe correlation.

Sorcar usage remains opaque cumulative `{total_tokens,cost,total_steps}` because Agent Workbench's Pi statusline accumulator expects per-message input/output/cache token splits and numeric cost. Provider thinking text is never parsed as tools. Sorcar tool events lack stable call IDs, so the live adapter does not project them into Agent Workbench tool blocks and disables changed-file attribution, quickfix side effects, and diff review. Pi-only models, thinking levels, slash commands, compaction, direct bash, attachments, tree, stats, and changed-file review remain capability-disabled.

## Core/UI readiness

Core plus minimal UI now have fake and real-daemon coverage for transport, generation isolation, canonical tab reconstruction, one task, streaming display, history listing/exact resume, steering, stop routing, result/lifecycle separation, and stale-state presentation.

UI still must not claim replay completion, exactly-once delivery, semantic success when `result.success` is absent, universal native tool events, or safe worktree mutation. User-answer and richer formatting for remaining provider-specific display events remain later focused increments.
