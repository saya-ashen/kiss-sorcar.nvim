# Architecture of `kiss-sorcar.nvim`

> Backend source studied: [KISS commit `74af9b7`](https://github.com/ksenxx/kiss_ai/commit/74af9b738adeef91448790015cf8f416da71566c).
> This began as the implementation proposal. The labels below preserve design provenance; current code and tests are authoritative where they differ.

## Labels

- **FACT**: observed in current KISS Sorcar source.
- **INFERENCE**: conclusion supported by multiple source locations, not declared protocol contract.
- **PROPOSAL**: design choice for `kiss-sorcar.nvim`.

Full backend facts and citations: [protocol.md](protocol.md). Unknowns and upstream concerns: [open-questions.md](open-questions.md).

## Constraints from backend

- **FACT:** Local protocol is newline-delimited UTF-8 JSON over Unix-domain stream socket. Daemon defaults to `$KISS_HOME/sorcar.sock`. Python and VS Code clients also honor `KISS_SORCAR_SOCK`, but production `kiss-web` `main()` does not; custom client path works only when daemon was separately constructed/launched with matching `RemoteAccessServer(uds_path=...)`. (`src/kiss/server/web_server.py`, `_default_uds_path`, `RemoteAccessServer.__init__`, `main`; `src/kiss/agents/sorcar/daemon_client.py`, `_resolve_sock_path`; `src/kiss/agents/vscode/src/AgentClient.ts`, `AgentClient.constructor`.)
- **FACT:** Stream reads do not align to frames. One line can span reads, including within UTF-8 sequence; one read can contain multiple lines. (`src/kiss/server/web_server.py`, `_uds_handler`; `src/kiss/agents/vscode/src/AgentClient.ts`, `AgentClient._handleData`.)
- **FACT:** Daemon owns live task execution, persistent task/event history, canonical top-level tab registry, model execution, and live worktree action handles. Git worktree artifacts can survive loss of live handle. (`src/kiss/server/server.py`, `VSCodeServer`; `src/kiss/server/tab_registry.py`, `TabRegistry`; `src/kiss/agents/sorcar/persistence.py`; `src/kiss/agents/sorcar/worktree_sorcar_agent.py`.)
- **INFERENCE:** Current wire surface has no protocol version, server version handshake, daemon-instance ID, feature negotiation, generic request ID, delivery acknowledgment, idempotency key, event replay cursor, or replay-complete marker. (`src/kiss/server/sorcar.py`, `API`, `validate_command`, `ServerApi.dispatch`; `src/kiss/server/web_server.py`, `_uds_handler`, `_handle_ready`; event emitters cataloged in [protocol.md](protocol.md).)
- **PROPOSAL:** Pure Lua is practical. Use Neovim built-ins `vim.uv` and `vim.json`; no Python or Node bridge.
- **PROPOSAL:** Keep transport, protocol decoding, application state, and Neovim UI logically separate.

## Layers

```text
┌───────────────────────────────────────────────────────┐
│ Neovim UI                                             │
│ chat · composer · models · history · tools · review  │
└──────────────────────────▲────────────────────────────┘
                           │ actions / view data
┌──────────────────────────┴────────────────────────────┐
│ Application state                                    │
│ canonical tabs · per-tab task view · reconnect state │
└──────────────────────────▲────────────────────────────┘
                           │ commands / routed events
┌──────────────────────────┴────────────────────────────┐
│ Protocol                                              │
│ command builders · JSON decode · field validation     │
└──────────────────────────▲────────────────────────────┘
                           │ complete NDJSON frames
┌──────────────────────────┴────────────────────────────┐
│ Transport                                             │
│ vim.uv pipe · byte buffer · direct writes · backoff   │
└──────────────────────────▲────────────────────────────┘
                           │ Unix-domain stream
                     KISS Sorcar daemon
```

UI never parses raw JSON or writes socket. Transport never knows tabs, tasks, models, or buffers.

## 1. Transport

### Responsibilities

**PROPOSAL:**

1. Resolve socket path: explicit plugin option, then `KISS_SORCAR_SOCK`, then `${KISS_HOME:-~/.kiss}/sorcar.sock`. Warn that env override affects current clients but not production daemon `main()`.
2. Create pipe with `vim.uv.new_pipe(false)`, then `pipe:connect(path, callback)`.
3. On successful connect, call `read_start(function(err, chunk) ... end)`. Treat `chunk == nil` as EOF. Reject callbacks from stale connection generation.
4. Keep raw Lua string buffer per connection. Lua strings are bytes; split only on literal `\n`, emit each complete nonempty line in order, retain suffix.
5. Append `\n` to every `vim.json.encode(command)` result.
6. Clear buffer on disconnect. New connection never completes old partial frame.
7. Bound total buffered frame data. Current compatibility ceiling is 64 MiB because daemon/Python client use that byte limit; check complete frame and incomplete suffix. Allow lower user-configured cap if clearly reported.
8. Write directly while connected and report write-callback errors. No disconnected command queue. Add bounded connected backpressure queue only if measurements require it.
9. Reconnect with capped exponential delay plus jitter; prevent overlapping connect attempts.
10. Close handles/timers idempotently.
11. Schedule state/UI dispatch with `vim.schedule` or `vim.schedule_wrap`; never call Neovim buffer/window APIs from libuv callback.

- **FACT:** Daemon/Python client cap lines at 67,108,864 bytes. VS Code instead compares decoded JavaScript buffer against 33,554,432 UTF-16 code units. (`src/kiss/server/web_server.py`, `_MAX_LINE_BYTES`, `_setup_server`; `src/kiss/agents/sorcar/daemon_client.py`, `_MAX_LINE_BYTES`; `src/kiss/agents/vscode/src/AgentClient.ts`, `MAX_LINE_BUFFER_BYTES`, `_handleData`.)
- **PROPOSAL:** Malformed complete JSON produces protocol diagnostic and connection remains open. Invalid UTF-8 behavior of `vim.json.decode` must be pinned by supported-Neovim tests before assigning distinct error class.

### Delivery policy

| Class | Examples | Connection loss behavior |
|---|---|---|
| Fresh reads/reconstruction | `ready`, `getHistory`, `getModels`, `getConfig`, `getInputHistory`, `activeTasksQuery` | Recreate from current state after reconnect; send once per connection generation where applicable. |
| Effectful/context-sensitive | `run`, `stop`, `appendUserMessage`, `userAnswer`, `selectModel`, tab mutations, worktree/main-tree actions | Never replay automatically. Report unsent or outcome-unknown action. |

- **FACT:** Existing VS Code client queues every disconnected command for up to 10 seconds, including `run`; daemon has no generic acknowledgment or deduplication. (`src/kiss/agents/vscode/src/AgentClient.ts`, `sendCommand`, connect flush, `PENDING_SEND_TTL_MS`.)
- **INFERENCE:** Completed local write callback cannot establish daemon dispatch. After disconnect, client cannot distinguish dispatched command from undelivered command. Retrying effectful command may duplicate intent.
- **PROPOSAL:** Never silently retry `run`, steering, answer, stop, model selection, tab mutation, or Git action. Keep at most bounded visible record for action awaiting first observable consequence; no durable queue.

## 2. Protocol

### Responsibilities

**PROPOSAL:**

- Decode one complete line using `vim.json.decode`.
- Require JSON object and nonempty string `type` before state dispatch.
- Build commands with exact wire names and stricter local validation than daemon's shallow presence check.
- Route event using event-specific identity fields; do not apply every event to active tab.
- Preserve unknown fields in current event. Keep bounded diagnostic ring for unknown/malformed events; do not retain unbounded payloads.
- Treat missing and empty `tabId` according to each event. Empty `tabId` is used for global canonical events; missing route on stream output must not be guessed into active tab.
- Keep identifier aliases explicit: `tabId` versus `tab_id`, `chatId` versus `chat_id`, `taskId` versus `task_id`.
- Expose no Neovim UI operations.

### Initial command builders

- connection: `setWorkDir`, `ready`, `activeTasksQuery`;
- tabs/chats: `openTab`, `closeTab`, `newChat`, `resumeSession`;
- tasks: `run`, `stop`;
- interaction: `appendUserMessage`, `userAnswer`;
- models/config read: `getModels`, `selectModel`, `getConfig`;
- history: `getHistory`, `getAdjacentTask`, `getInputHistory`;
- review: `worktreeAction`, `mainTreeAction`, `autocommitAction`.

**PROPOSAL:** Defer voice, sharing, autocomplete, config mutation, frequent-task mutation, update/reset, and WSS. Decoder still tolerates their events.

### Identity rules

Never merge these:

- `tabId`: frontend route/view ID;
- `chatId` / `chat_id`: conversation grouping ID;
- `run.taskId`: optional client submission-correlation ID;
- task event `taskId` / replay `task_id`: persisted history task ID, except `status.taskId` can echo submission ID;
- `parent_task_id`: persisted child-task ancestry;
- `parent_tab_id`: UI relation.

- **FACT:** Client `run.taskId` is optional and echoed on status; persisted task ID allocates later. (`src/kiss/server/task_runner.py`, `_client_task_id_of`, `_run_task`, `_on_run_task_id_allocated`.)
- **PROPOSAL:** Internally name `submission_id` and `history_task_id` separately.
- **FACT:** `resumeSession` is chat/task replay command; no separate persisted session entity or session ID exists. (`src/kiss/agents/sorcar/persistence.py`, task/event schema and replay helpers; `src/kiss/server/server.py`, `_replay_session`.)

### Compatibility stance

**PROPOSAL:** Unknown event is nonfatal. Malformed expected event disables only affected transition and logs compact diagnostic. Added fields pass through. Do not infer capability from silence. Health output must state missing negotiation explicitly.

## 3. Application state

### Minimal state

**PROPOSAL:** One state module owns mutations of plain Lua tables:

```text
connection
  generation, phase, last_error, pending_action

workspace
  work_dir

registry
  ordered top-level tab IDs
  entries[tab_id] = {chat_id, title, work_dir, scope_work_dir, pinned_task_id}

tabs[tab_id]
  kind, parent_tab_id, chat_id, history_task_id
  running, start_ts, stop_pending
  user_model, displayed_model
  transcript blocks
  pending_question and answer draft
  worktree review state

models
  entries, daemon_selected

history
  query, generation, offset, sessions
```

No duplicate transcript copy and no client “session” entity. Add indexes only when needed.

### Event rules

- `tabs_state`: replace canonical top-level registry snapshot. Derived sub-agent tabs remain separate.
- `clear`: reset addressed transcript and bind `chat_id`.
- `task_events`: replacement baseline for one addressed task/tab; replay nested events into fresh transcript. It is not global or atomic snapshot.
- stream/tool/result events: update addressed transcript block only.
- `status running:true`: mark task active. `status running:false`: unlock task UI and clear stop-pending.
- lifecycle events: record `task_done`, `task_error`, `task_stopped`, or `task_interrupted`. Never treat `result` alone as lifecycle end.
- `askUser`: set current pending question for routed tab without forced tab switch. Preserve draft across duplicate/reconnect only while same tab has no intervening `askUserDone` or task-terminal transition; protocol has no question ID.
- `askUserDone`: clear current pending question for routed tab; no stronger question matching is possible.
- `models`: replace daemon model list/default. `models.selected` is daemon default, not necessarily every tab's user selection.
- `modelPick`: update transient displayed model; keep user's tab model separate.
- sub-agent events: create/close/mark derived tab; never insert into canonical top-level registry.
- worktree/main-tree events: update review state only. Historical replay alone never authorizes destructive action.
- unknown events: bounded diagnostic only.

- **FACT:** Running replay subscribes tab, then snapshots in-memory recording; source documents duplicate-delivery micro-window and nested events have no wire event IDs. (`src/kiss/server/server.py`, `_replay_session`.)
- **PROPOSAL:** Treat `task_events` as replacement barrier. Do not content-deduplicate later live events because identical deltas can be legitimate.

### Reconnect

**PROPOSAL:**

1. On disconnect, keep rendered content but mark stale. Disable actions whose target state cannot be trusted. Mark ambiguous written action outcome unknown.
2. Reconnect transport; increment generation.
3. Send `setWorkDir`.
4. Send exactly one `ready` for generation. `restoredTabs` is legacy migration input only: daemon adopts it only when registry empty. Never treat client list as authority.
5. Reconcile only from received canonical `tabs_state`.
6. Track transcript freshness per tab as each `task_events` arrives; track running/pending-question state from current-generation replay/live events.
7. If history surface is open, issue fresh `getHistory` generation.
8. Do not invent global “replay complete.” Daemon has no marker. Connection can be connected and registry synchronized while individual tab replay remains pending.
9. Never replay effectful commands.

`ready` broadcasts canonical snapshot and replay events through shared printer, so reconnect from one client can repaint already-connected clients. Prevent duplicate handshakes in one generation. Do not discard valid global broadcasts merely because another client caused them.

- **FACT:** Client disconnect does not stop running execution. In-memory execution survives client disconnect while daemon lives. Registry/history are persisted separately and can survive daemon restart subject to successful writes. (`src/kiss/server/web_server.py`, `_uds_handler`; `src/kiss/server/tab_registry.py`; `src/kiss/agents/sorcar/persistence.py`.)
- **FACT:** Graceful daemon shutdown interrupts active task as `task_interrupted`; startup orphan sweep rewrites eligible abrupt-failure sentinel rows. Old process execution, question queue, steering queue, subscriptions, and worktree handle do not resume. (`src/kiss/server/task_runner.py`, `_cancel_outcome`; `src/kiss/server/server.py`, `_run_orphan_sweep`; `src/kiss/agents/sorcar/persistence.py`, orphan/shutdown recovery.)

## 4. Neovim UI

### Streaming chat

**PROPOSAL:** Use non-file scratch buffer per Sorcar tab. State owns ordered blocks; extmarks anchor mutable streaming block. Batch deltas into one scheduled render tick instead of one buffer edit per token. Keep transcript non-modifiable outside renderer and preserve cursor/window view. Fold thinking, tools, and system output after basic plain-text correctness.

Show connection phase, running state, model, client-side workspace path, tokens/cost/steps, and worktree status.

### Composer, stop, steering, ask-user

- Idle submit uses active/new registered `tabId`; mint optional per-submission `taskId` to distinguish stale status.
- Running submit sends `appendUserMessage` only after current-generation state confirms task accepts input. Backend can still silently drop near lifecycle races; UI must not claim durable acceptance.
- Stop sends `stop{tabId}`. `stop_ack.accepted` confirms daemon found/signaled target, not completion. False clears pending-stop and triggers resynchronization; true waits for lifecycle/status false.
- `askUser` opens answer input without destroying composer draft. Send `userAnswer` only while current-generation pending question exists. Never auto-replay answer; no question ID and unroutable answer is silently dropped.

### Models

Use `vim.ui.select` first. Ordinary model fields are `name`, `inp`, `out`, `uses`, `vendor`; custom entry additionally includes sensitive `endpoint`, plaintext `api_key`, and `extra_headers`. Never log, persist, or display raw sensitive fields. Treat model name as opaque. Keep daemon default, per-tab user choice, and agent `modelPick` override separate.

Daemon `models` list is already availability-filtered and function-calling-ranked; client should not recreate provider discovery. `MY_MODELS.json` catalog additions and one config custom endpoint are different backend mechanisms.

### Workspace

Neovim has global/tab/window current directories. **PROPOSAL:** default to tab-local cwd when set, else global cwd; allow explicit plugin workspace override. Display chosen path. Changing chosen path sends `setWorkDir`.

- **FACT:** Canonical tabs expose `scopeWorkDir` and `workDir`; current clients fall back to `workDir` when scope empty. (`src/kiss/server/tab_registry.py`; `src/kiss/agents/vscode/media/main.js`, tab workspace helpers.)
- **PROPOSAL:** Match this tab filter. History grouping/filtering is client-side because daemon returns global top-level history. For VS Code parity, provisional filter includes matching/descendant paths, empty `work_dir`, and running rows; exact path normalization policy remains unresolved.

Workspace is client-side path group, not persisted backend entity.

### History browser

```text
client-side workspace path group
└── chat_id
    ├── top-level task_id
    │   └── child task_id
    └── top-level task_id
```

- **FACT:** `getHistory` returns top-level rows only because persistence filters nonempty `parent_task_id`; each `sessions` entry represents one top-level task row and repeats chat ID as `id`. Child rows arrive through parent replay/sub-agent APIs, not root history list. (`src/kiss/agents/sorcar/persistence.py`, `_HISTORY_NOT_SUBAGENT`, `_load_history`, `_search_history`; `src/kiss/server/server.py`, `_get_history`, `_open_persisted_subagent_tabs`.)
- **PROPOSAL:** Group root rows by exact `id` chat ID and task by exact `task_id`; never group by prompt text. `resumeSession{chatId,taskId,tabId}` requests exact task but backend falls back to latest chat task if lookup fails. Keep unresolved synthetic `parent_task_id` as explicit orphan node.

### Tool and trajectory inspection

Two features differ:

1. **PROPOSAL:** UDS transcript/tool inspector reads normalized `thinking_*`, `tool_call`, `system_output`, `tool_result`, `usage_info`, result, and lifecycle events from same transcript store.
2. **FACT:** Full trajectory jobs are currently HTTP data endpoints backed by `ServerApi.trajectory_jobs` and `ServerApi.job_trajectories`, not UDS commands. (`src/kiss/server/sorcar.py`, these symbols; `src/kiss/server/web_server.py`, trajectory HTTP handlers.)

**PROPOSAL:** Defer full trajectory viewer until HTTP URL/auth/task association is manually established or backend exposes UDS commands. Do not add second bridge to hide this gap.

### Worktree diff/review

Render worktree lifecycle events. For candidate file, combine `worktreeWorkDir` with relative `changedFiles`; reject absolute path and traversal outside resolved worktree root, verify existence, then open native diff against corresponding main-tree path. Handle deletion, rename representation, binary/untracked file, missing original, and stale worktree gracefully.

Require explicit confirmation for `merge` and `discard`. Expose `nothing` as preserve/detach choice. Send `worktreeAction`; never run client-side Git merge/discard. Enable action only from current daemon presentation, not replayed historical event or history `is_worktree`, because restart loses live ownership.

### `:checkhealth sorcar`

Use temporary UDS connection:

1. report Neovim version and `vim.uv`/`vim.json` availability;
2. report resolved socket path and resolution source;
3. report advisory pathname type/permissions;
4. connect, send only `activeTasksQuery`, require valid `activeTasksResponse` before timeout, then close;
5. report framing/schema/connect errors;
6. warn about missing protocol/server version, daemon instance ID, capabilities, generic request IDs, and replay-complete marker;
7. warn when `KISS_SORCAR_SOCK` differs from daemon default because production daemon entry point ignores it.

Do not send `ready`, tab mutations, `run`, model selection, config writes, update, or reset.

## Minimal module boundaries

```text
lua/kiss-sorcar/
  transport.lua   UDS lifecycle and framing
  protocol.lua    command builders and event routing
  state.lua       canonical registry and per-tab state
  ui.lua          buffers, composer, pickers, browser, review entry points
  health.lua      :checkhealth sorcar
```

**PROPOSAL:** Keep four logical layers. Split UI only after independent behavior warrants files. No framework, event-bus dependency, local DB, Python bridge, Node bridge, offline queue, or duplicate transcript store.

## Invariants

1. One UDS frame is one complete UTF-8 JSON object plus newline.
2. Buffer and generation are connection-scoped.
3. Only protocol layer knows wire spellings and event routes.
4. Only state layer mutates application state.
5. Tab, chat, submission, persisted task, and parent IDs remain distinct.
6. `tabs_state` replaces canonical top-level registry.
7. `task_events` replaces one transcript baseline.
8. Disconnect never means task stopped.
9. `result` alone never means lifecycle ended.
10. Effectful command never auto-replays after uncertain delivery.
11. Unknown event never crashes transport/UI and never grows memory unbounded.
12. Historical worktree state never enables destructive action.
13. Neovim APIs run on main thread.
14. Backend bug or missing contract remains visible; client does not silently compensate.

## Deferred

Autocomplete/file mentions, voice, sharing, config/API-key editing, frequent-task mutation, update/reset controls, WSS, full HTTP trajectory viewer, richer picker dependency, offline persistence.
