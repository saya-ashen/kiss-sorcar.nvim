# KISS Sorcar daemon protocol

> Verified source revision: [KISS commit `74af9b7`](https://github.com/ksenxx/kiss_ai/commit/74af9b738adeef91448790015cf8f416da71566c)
> Scope: facts observed in source at this revision. Paths below are relative to the KISS repository root unless stated otherwise.

## Contents

- [Protocol surface and stability](#protocol-surface-and-stability)
- [Transport](#transport)
- [Client-to-daemon command catalog](#client-to-daemon-command-catalog)
- [Daemon-to-client event catalog](#daemon-to-client-event-catalog)
- [Identities and persistent/runtime state](#identities-and-persistentruntime-state)
- [Long-running task lifecycle](#long-running-task-lifecycle)

## Protocol surface and stability

The command allowlist at this revision contains **53 command names: 42 routed commands and 11 commands accepted then silently dropped by normal authenticated dispatch**. This count comes from every entry in `API`; `validate_command` rejects names outside that mapping, while `DROPPED_COMMANDS` identifies catalog entries whose `handler` is `"drop"`. (`src/kiss/server/sorcar.py`, `ApiCommand`, `API`, `DROPPED_COMMANDS`, and `validate_command`, lines 194–338; `ServerApi.dispatch`, lines 545–597.)

UDS connection setup begins directly with NDJSON command reads. `ready` performs model/config/input-history/tab synchronization. Command validation and authenticated dispatch use the `API` catalog. These cited paths emit no protocol-version field, server-version handshake, feature list, capability list, or schema negotiation. Third-party client therefore cannot negotiate compatibility before using command/event features. (`src/kiss/server/web_server.py`, `RemoteAccessServer._uds_handler`, lines 3766–3843, and `_handle_ready`, lines 4972–5036; `src/kiss/server/sorcar.py`, `API`, `validate_command`, and `ServerApi.dispatch`, lines 227–338 and 545–597.)

## Existing client implementations

- **FACT:** Current source contains no general interactive daemon-backed terminal chat client and no `sorcar` console entry point. `pyproject.toml` registers `kiss-web` plus channel/cron programs; none is an interactive Sorcar chat CLI. `src/kiss/server/sorcar.py` is server protocol/API plus re-export of synchronous Python client, not interactive CLI. (`pyproject.toml`, `[project.scripts]`, lines 357–396; `src/kiss/server/sorcar.py`, module documentation and client re-exports, lines 1–118.)
- **FACT:** Current Python client is `src/kiss/agents/sorcar/daemon_client.py:run`: one blocking run, no exposed stream callback, stop handle, steering method, answer callback, reconnect, or session browser. It drains daemon events internally and returns `TaskResult` after running status ends. (`src/kiss/agents/sorcar/daemon_client.py`, `run`, lines 230–549.)
- **FACT:** Current first-class interactive local client is VS Code extension under `src/kiss/agents/vscode`; its UDS transport is `AgentClient`, command facade is `SorcarApi`, host bridge/state owner is `SorcarSidebarView`, and browser/webview UI reducer is `media/main.js`. (`src/kiss/agents/vscode/src/AgentClient.ts`; `SorcarApi.ts`; `SorcarSidebarView.ts`; `src/kiss/agents/vscode/media/main.js`.)



## Transport

Source revision inspected: `74af9b738adeef91448790015cf8f416da71566c`.

Scope: local daemon transport, socket configuration, framing/encoding, connection/authentication/reconnection, synchronous daemon client, and VS Code `AgentClient`. Line numbers refer to this revision.

## Local transport and socket configuration

- **FACT:** Local clients use an `AF_UNIX` / stream Unix-domain socket. Python client constructs `socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)` and calls `connect(str(path))`; VS Code uses Node `net.createConnection({path: this._sockPath})`; daemon binds with `asyncio.start_unix_server(...)`. Sources: `src/kiss/agents/sorcar/daemon_client.py:431-440`, symbol `run`; `src/kiss/agents/vscode/src/AgentClient.ts:73-84`, method `AgentClient.connect`; `src/kiss/server/web_server.py:5877-5881`, method `RemoteAccessServer._setup_server`.
- **FACT:** Client socket-path precedence is explicit constructor/function argument, then `KISS_SORCAR_SOCK`, then `$KISS_HOME/sorcar.sock`. Python implements this in `_resolve_sock_path`; VS Code constructor implements same order with nullish coalescing. Sources: `src/kiss/agents/sorcar/daemon_client.py:78-95`, `_resolve_sock_path`; `src/kiss/agents/vscode/src/AgentClient.ts:61-70`, `AgentClient.constructor`.
- **FACT:** `KISS_HOME` defaults to `~/.kiss`. Python resolves it lazily with `Path.home() / ".kiss"`; VS Code uses `path.join(os.homedir(), '.kiss')`. Sources: `src/kiss/core/config.py:73-80`, `kiss_home`; `src/kiss/agents/vscode/src/userAssets.ts:10-12`, `kissHomeDir`.
- **FACT:** `_default_uds_path` returns `$KISS_HOME/sorcar.sock` and does not read `KISS_SORCAR_SOCK`; `RemoteAccessServer.__init__(uds_path=...)` accepts a daemon-side override. Source: `src/kiss/server/web_server.py:416-429`, `_default_uds_path`; `src/kiss/server/web_server.py:RemoteAccessServer.__init__:3455-3477`.
- **FACT:** Daemon creates socket parent directories, checks/waits for a live predecessor, removes a stale path, binds, then chmods socket pathname to `0o600`. It records socket inode and only unlinks pathname later if inode still matches, preventing an old daemon from unlinking a successor's socket. Sources: `src/kiss/server/web_server.py:5864-5895`, `_setup_server`; `src/kiss/server/web_server.py:5907-5963`, `_wait_for_uds_release` and `_uds_socket_is_live`; `src/kiss/server/web_server.py:5976-6001`, `_unlink_own_uds_socket`.
- **FACT:** If UDS setup fails, daemon logs warning, sets `_uds_server = None`, and continues into remaining server setup; comment says local extension clients will fall back to WSS, but `AgentClient` itself contains only UDS logic. Source: `src/kiss/server/web_server.py:5886-5895`, `_setup_server`; `src/kiss/agents/vscode/src/AgentClient.ts:6-241`, `AgentClient`.

## Framing and encoding

- **FACT:** UDS protocol is newline-delimited JSON (NDJSON): one JSON object serialized on one line, terminated by byte `0x0a`. Daemon writes `data.encode("utf-8") + b"\n"`; Python client writes `json.dumps(cmd).encode("utf-8") + b"\n"`; VS Code writes `JSON.stringify(cmd) + '\n'`. Sources: `src/kiss/server/web_server.py:2354-2369`, `WebPrinter._uds_send`; `src/kiss/server/web_server.py:4897-4902`, `RemoteAccessServer._endpoint_send`; `src/kiss/agents/sorcar/daemon_client.py:445-468`, `run`; `src/kiss/agents/vscode/src/AgentClient.ts:136-150`, `AgentClient.sendCommand`.
- **FACT:** Local protocol has no length prefix, envelope, or handshake framing. Newline is sole UDS frame delimiter. At framing layer, WSS uses one JSON object per WebSocket frame; WSS additionally performs password authentication before dispatch, and several commands are transport-gated. Sources: `src/kiss/server/sorcar.py:7-29` module documentation and `ServerApi.authenticate:619-743`; `src/kiss/server/web_server.py:3766-3776`, `_uds_handler`.
- **FACT:** Multiple protocol messages may arrive in one stream read. VS Code appends each chunk, splits on every newline, preserves final incomplete suffix, and parses every complete line. Source: `src/kiss/agents/vscode/src/AgentClient.ts:214-239`, `AgentClient._handleData`.
- **FACT:** One message may be split across multiple reads, including within a multibyte UTF-8 code point. VS Code preserves incomplete line text in `_buffer` and uses one connection-scoped `StringDecoder('utf8')`, which preserves split UTF-8 code points. Source: `src/kiss/agents/vscode/src/AgentClient.ts:76-84,106-109,214-239`, `AgentClient.connect` and `_handleData`.
- **FACT:** Python synchronous client uses binary `readline(_MAX_LINE_BYTES)`, so stream chunk boundaries are hidden and each call waits for newline, EOF, timeout, or size cap. It then explicitly decodes UTF-8 and parses JSON. Source: `src/kiss/agents/sorcar/daemon_client.py:468-504`, `run`.
- **FACT:** Daemon uses `StreamReader.readline()` and passes resulting bytes directly to `json.loads`; Python JSON decoding accepts UTF-8 JSON bytes. Empty reads mean EOF. Malformed JSON and non-object JSON values are silently ignored. Source: `src/kiss/server/web_server.py:3799-3810`, `_uds_handler`.
- **FACT:** Empty lines are ignored in effect: daemon's `json.loads(b'\n')` fails and is skipped; VS Code explicitly skips lines whose `.trim()` is empty. Malformed complete JSON lines are skipped without closing connection (daemon silently; VS Code logs warning). Sources: `src/kiss/server/web_server.py:3799-3810`, `_uds_handler`; `src/kiss/agents/vscode/src/AgentClient.ts:226-238`, `_handleData`.
- **FACT:** Daemon configures asyncio stream limit to 64 MiB (`_MAX_LINE_BYTES = 64 * 1024 * 1024`). Python client uses matching 64 MiB cap and fails loudly if `readline(size)` returns a full-size unterminated fragment. Sources: `src/kiss/server/web_server.py:345`, `_MAX_LINE_BYTES`; `src/kiss/server/web_server.py:5877-5881`, `_setup_server`; `src/kiss/agents/sorcar/daemon_client.py:36-47,468-500`, `_MAX_LINE_BYTES` and `run`.
- **FACT:** VS Code compares decoded JavaScript `_buffer.length` against `33,554,432`; this counts UTF-16 code units, not UTF-8 wire bytes despite constant name `MAX_LINE_BUFFER_BYTES`. Check occurs after appending chunk and before splitting complete lines, so buffer may contain multiple complete frames as well as incomplete suffix. Exceeding limit clears buffer and destroys socket. Source: `src/kiss/agents/vscode/src/AgentClient.ts:13,214-224`, `MAX_LINE_BUFFER_BYTES` and `_handleData`.
- **FACT:** Send ordering to one endpoint is guarded by per-endpoint send lock; direct responses cannot overtake earlier broadcasts delayed by backpressure. Source: `src/kiss/server/web_server.py:4876-4902`, `RemoteAccessServer._endpoint_send`.

## Authentication and trust boundary

- **FACT:** Local UDS connections perform no protocol-level authentication or initial auth handshake. Access control relies on POSIX socket pathname mode `0o600`, limiting access to owning user. Sources: `src/kiss/server/web_server.py:416-429`, `_default_uds_path`; `src/kiss/server/web_server.py:3766-3777`, `_uds_handler`; `src/kiss/server/sorcar.py:619-644`, `ServerApi.authenticate` documentation.
- **FACT:** Password `auth` applies only to remote WSS before normal dispatch. If an `auth` command reaches normal authenticated dispatch, catalog marks it `handler="drop"` and daemon silently discards it. Sources: `src/kiss/server/sorcar.py:273-298`, `API`; `src/kiss/server/sorcar.py:619-740`, `ServerApi.authenticate`.
- **FACT:** Each accepted UDS connection gets daemon-generated `conn_id` and initially empty per-connection `work_dir`; every dispatched command is stamped with this `connId`, overwriting any client value. `setWorkDir` pins connection work directory, and commands without explicit `workDir` inherit it. Sources: `src/kiss/server/web_server.py:3795-3798`, `_uds_handler`; `src/kiss/server/sorcar.py:545-597`, `ServerApi.dispatch`.

## Connection and disconnection behavior

### Daemon

- **FACT:** On accept, daemon registers writer for broadcasts and binds `conn_id` to endpoint. It loops until EOF; command-handler errors generally log and keep connection alive. On exit it stops connection-owned voice wake, unregisters local tab memberships, drops connection state, unbinds printer routing, removes writer, and closes writer. Source: `src/kiss/server/web_server.py:3783-3843`, `_uds_handler`.
- **FACT:** Disconnect does not itself stop running agent tasks or delete canonical shared tabs. UDS cleanup shown above removes connection-specific state and local tab registrations only. Canonical reconstruction is handled through `ready`/registry replay, not transport replay. Sources: `src/kiss/server/web_server.py:3825-3843`, `_uds_handler`; `src/kiss/server/web_server.py:4972-5036`, `_handle_ready`.
- **FACT:** During daemon shutdown, listener closes and owned pathname is unlinked; already accepted UDS writers are explicitly closed because `asyncio.Server.close()` alone does not close them. Handler tasks are then drained. Source: `src/kiss/server/web_server.py:6635-6671`, `RemoteAccessServer.stop_async` shutdown block.

### Python daemon client API

- **FACT:** `run()` performs one immediate connect with connect timeout `min(timeout, 10.0)` and has no retry/reconnect loop or outbound queue. Connect failure raises `ConnectionError`; EOF before terminal task state also raises `ConnectionError`. Sources: `src/kiss/agents/sorcar/daemon_client.py:431-444,472-489`, `run`.
- **FACT:** It creates fresh synthetic `tabId` (`api-<uuid>`) and fresh command `taskId`, sends exactly one `run`, then filters all incoming broadcasts by matching `tabId`. It returns only after observing `status.running == true`, then later `status.running == false`; latest `result` event supplies outcome. Source: `src/kiss/agents/sorcar/daemon_client.py:432,445-467,469-518`, `run`.
- **FACT:** Invalid JSON/UTF-8 event lines and events for other tabs are ignored. Source: `src/kiss/agents/sorcar/daemon_client.py:501-506`, `run`.
- **FACT:** On every exit path, client best-effort sends `closeTab`, closes file reader, then socket. If timeout occurs while task remains active, documented semantics say `closeTab` marks frontend closed but task keeps running and state is disposed after completion. Sources: `src/kiss/agents/sorcar/daemon_client.py:420-425,519-548`, `run`.
- **FACT:** Because client has no reconnect/replay, connection loss cannot duplicate its `run`; caller retrying `run()` is a new command with a new task ID and may start a second task. No idempotency recovery appears in this client. Source: `src/kiss/agents/sorcar/daemon_client.py:432-467`, `run`.

### VS Code `AgentClient`

- **FACT:** `connect()` is idempotent while socket exists, client is disposed, or connection attempt is active. Each new connection clears old partial frame state and creates fresh UTF-8 decoder. Source: `src/kiss/agents/vscode/src/AgentClient.ts:73-84`, `AgentClient.connect`.
- **FACT:** Socket `connect` emits `connect`; socket `close` clears connection/buffer state, emits `disconnect`, and schedules reconnect unless disposed. `ENOENT` and `ECONNREFUSED` errors are intentionally not logged; all close paths drive retry. Source: `src/kiss/agents/vscode/src/AgentClient.ts:86-133`, `AgentClient.connect`.
- **FACT:** Reconnect uses exponential backoff from 500 ms to 15 s with delay uniformly jittered over latter half of each capped interval. Counter resets only after connection lasted at least 5 s, avoiding rapid reconnect loops resetting backoff. Source: `src/kiss/agents/vscode/src/AgentClient.ts:15-27,118-132,190-212`, constants and `_scheduleReconnect`.
- **FACT:** Commands sent while socket is unavailable are queued, capped at 256 entries. Oldest overflow entries are dropped. On next connect, entries older than 10 s are dropped; remaining commands are written FIFO. Drops emit `commandDropped(cmd, 'expired' | 'overflow')`. Source: `src/kiss/agents/vscode/src/AgentClient.ts:17-22,94-103,136-171`, pending-send logic.
- **FACT:** Queue protects only commands not written to socket. Once `sock.write(line)` occurs, client records no acknowledgement and does not replay that command after disconnect. Thus transport provides neither delivery acknowledgement nor exactly-once guarantee: command may have reached daemon before connection loss even though client cannot know. Source: `src/kiss/agents/vscode/src/AgentClient.ts:94-103,136-150`, `connect` and `sendCommand`.
- **FACT:** Fresh queued `run` may be delivered to daemon process that answers within 10 s, including replacement daemon. Source comment explicitly recognizes stale replay risk and uses TTL rather than daemon identity or idempotency token. Source: `src/kiss/agents/vscode/src/AgentClient.ts:17-21,94-103`.
- **FACT:** Dropped `run` emits notification consumed by `SorcarSidebarView`, which clears optimistic running state and warns user to resend. Other dropped commands receive generic warning. Sources: `src/kiss/agents/vscode/src/SorcarSidebarView.ts:399-430` and following `_handleDroppedCommand`; `src/kiss/agents/vscode/src/AgentClient.ts:167-172`.
- **FACT:** `dispose()` cancels reconnect timer, ends socket, empties queue, and removes listeners; reconnect cannot restart disposed client. Source: `src/kiss/agents/vscode/src/AgentClient.ts:174-188`, `dispose`.

## Reconnect and state reconstruction

- **FACT:** `AgentClient` reconnect restores transport only; it does not itself replay received events or already-written commands. Its owner handles application re-pin/refresh. Source: `src/kiss/agents/vscode/src/AgentClient.ts:46-241`, class implementation.
- **FACT:** On each VS Code connection, `SorcarSidebarView` sends `setWorkDir`; if view exists, it also requests models, input history, and config. Disconnect marks daemon offline and resolves pending worktree actions. Source: `src/kiss/agents/vscode/src/SorcarSidebarView.ts:373-398`, `_getClient`.
- **FACT:** Full tab/transcript state reconstruction is initiated by protocol `ready`, not automatically by raw UDS connect. Daemon `_handle_ready` sends initial model/input-history/config commands, nudges `tasks_updated`, synchronizes restored tabs against canonical shared registry, broadcasts canonical state through registry handling, and invokes `resumeSession` for each bound chat tab (including pinned `taskId` when present). Source: `src/kiss/server/web_server.py:4972-5036`, `_handle_ready`.
- **FACT:** VS Code forwards `ready` when its webview sends a `ready` message. Its raw socket reconnect handler sends `setWorkDir` plus, when view exists, `getModels`, `getInputHistory`, and `getConfig`; that handler contains no `ready` send. Sources: `src/kiss/agents/vscode/src/SorcarSidebarView.ts:383-392`, `_getClient`; `src/kiss/agents/vscode/src/SorcarSidebarView.ts:975-994`, webview-message `ready` case.
- **FACT:** Daemon's ready-time tab synchronization reconciles local UDS tab bookkeeping exactly, adding missing IDs and removing stale IDs. Source: `src/kiss/server/web_server.py:2082-2104`, `WebPrinter.sync_local_uds_tabs`.
- **FACT:** Client-side partial frame is discarded on disconnect and cannot contaminate new connection. This is correct because bytes from old stream cannot be completed by new stream. Source: `src/kiss/agents/vscode/src/AgentClient.ts:76-78,118-123`.

## Client-to-daemon command catalog

Inspected source revision: `74af9b738adeef91448790015cf8f416da71566c`.

Scope: commands accepted by daemon command API and their dispatch paths. Everything below is observed in source. “Required” means catalog validation rejects field when absent or `null`; it does not imply type validation. “Optional/consumed” lists fields read by server path, excluding private fields generated inside server. Unknown extra fields generally survive forwarding and are ignored unless downstream code reads them.

## Dispatch invariants applying to all commands

Source: `src/kiss/server/sorcar.py:ApiCommand:194-212`, `API:227-289`, `validate_command:314-335`, `ServerApi.dispatch:545-597`; `src/kiss/server/server.py:VSCodeServer._handle_command:603-618`; `src/kiss/server/commands.py:_CommandsMixin._HANDLERS:1311-1338`.

- Frame must decode to JSON object. `type` must be non-empty string and name catalog entry. Invalid command receives direct `{"type":"error","text":...}`; non-empty string `tabId` is echoed. Catalog-required fields are checked with `cmd.get(field) is None`; empty strings and wrong types pass this layer.
- Before backend forwarding, dispatcher records non-empty string `tabId`, overwrites client `connId` with connection-owned ID, and stamps connection `work_dir` as `workDir` when command has no truthy `workDir`. `setWorkDir` instead updates connection state when supplied value is non-empty string.
- Backend `_handle_command` normalizes non-string `tabId`, `workDir`, and `connId` to `""`. Unknown backend type emits connection-scoped `error`, but API catalog normally prevents that path.
- Commands marked `handler="drop"` are silently discarded before required-field validation.
- Backend-forwarded handlers run through `RemoteAccessServer._run_cmd` executor; special API handlers may reply directly to requesting endpoint.

## Command catalog and exact behavior

### Task lifecycle

#### `run`

- Catalog: `src/kiss/server/sorcar.py:API:228`. Required: `prompt`.
- Optional/consumed: `tabId`, `chatId`, `taskId`, `model`, `workDir`, `tabScopeWorkDir`, `activeFile`, `attachments`, `useWorktree`, `useParallel`, `autoCommit`, `maxBudget`, `webTools`, `appendBasicTools`, `modelConfig`, `toolsFile`, `agentPath`, `systemPrompt`, `appendToSystemPrompt`, `appendToPrompt`; stamped `connId`. `agentPath` can override run fields before use. Sources: `src/kiss/server/commands.py:_cmd_run:330-477`; `src/kiss/server/task_runner.py:_run_task:442-582`, `_run_task_inner:815-1087`; `src/kiss/server/agent_file.py:apply_agent_overrides:176-245`.
- Immediate response/lifecycle: always broadcasts `setTaskText{text,tabId}`. Missing/empty `tabId` then stops without task. Merge-in-progress refusal emits `status{running:false}` then `error`. If tab already owns installed task thread, nonblank prompt is queued as live input and echoed as `prompt`; no second task starts. Otherwise creates/reuses chat ID, registers tab, broadcasts `tabs_state` through registry update and then `clear{chat_id,tabId}`, starts daemon worker.
- Worker emits `status{running:true,tabId,startTs[,taskId]}`. Normal inner lifecycle then emits early `system_prompt` and `prompt`, streamed agent/tool events, allocates persisted task ID, subscribes viewers, persists one task-end event (`task_done`, `task_error`, `task_stopped`, or `task_interrupted`), emits `tasks_updated`, optional worktree/main-tree/autocommit events, live lifecycle terminal with timestamps, then outer `status{running:false[,taskId]}`. Pre-allocation/setup failures caught by outer runner can instead emit failure `result` then `status running:false` without persisted task end or `tasks_updated`. Client `taskId` is correlation echoed on start/end/viewer status; persisted task ID is allocated separately.
- Defaults: absent `useWorktree`, `useParallel`, and `autoCommit` are truthy through `bool(cmd.get(..., True))`; supplied malformed values receive Python truth coercion. `appendBasicTools` defaults true when absent or non-Boolean. `submit` builds reduced `run` shape separately.

#### `submit`

- Catalog: `src/kiss/server/sorcar.py:API:229`; API route `ServerApi.submit:815-826`; implementation `src/kiss/server/web_server.py:RemoteAccessServer._handle_submit:5038-5095`. Required: `prompt`.
- Optional/consumed: `tabId`, `model`, `workDir`, `attachments`, `useWorktree`, `useParallel`, `autoCommit`; stamped `connId`.
- Browser-oriented adapter. If daemon shutdown started, emits `status{running:false}` and `error`, no run. Otherwise truncates prompt by byte cap, caps attachments, broadcasts optimistic `status{running:true}`, translates to `run` carrying fields above, then accepted worker later emits second start `status` with `startTs`. Adapter defaults three booleans true. It does not carry advanced `run` fields.

#### `appendUserMessage`

- Catalog: `src/kiss/server/sorcar.py:API:230`; handler `src/kiss/server/commands.py:_cmd_append_user_message:760-815`. Required: `prompt`. Optional/consumed: `tabId`.
- Non-string, blank prompt ignored. Routes first to live task owned by tab, then to live task whose subscriber set contains viewer tab. If none, silently drops. Otherwise appends pending message and broadcasts `prompt{text,tabId[,taskId]}`; agent drains before next model step. No terminal acknowledgment.

#### `stop`

- Catalog: `src/kiss/server/sorcar.py:API:231`; handlers `src/kiss/server/commands.py:_cmd_stop:479-481`, `src/kiss/server/task_runner.py:_stop_task:1716-1793`. Required: none. Optional/consumed: `tabId`.
- Empty tab ID ignored. Resolves owned live task or task viewed through subscriber mapping. Emits `stop_ack{accepted,tabId}`. Accepted path sets cooperative event; after one second watchdog injects `KeyboardInterrupt` if thread remains, with one later retry. Normal task cleanup emits failed `result`, `task_stopped`, and `status running:false`. Unroutable stop emits only `stop_ack{accepted:false}`.

#### `userAnswer`

- Catalog: `src/kiss/server/sorcar.py:API:232`; handler `src/kiss/server/commands.py:_cmd_user_answer:584-623`, routing `_resolve_user_answer_state:669-719`. Required: `answer`. Optional/consumed: `tabId`.
- Resolves question queue owned by tab or by subscribed live task. No owner means silent drop. Clears pending question, replaces any queued answer with supplied answer (non-string converted to string; `null` cannot pass catalog), then emits `askUserDone{tabId}` to current subscribers of answered task; when task ID or subscriber set is empty, it emits to answering tab. Waiting agent resumes.

### Tabs, chats, replay, initialization

#### `newChat`

- Catalog `src/kiss/server/sorcar.py:API:233`; handler `src/kiss/server/commands.py:_cmd_new_chat:875-877`; implementation `src/kiss/server/server.py:_new_chat:1126-1159`. Required: none. Optional/consumed: `tabId`.
- Empty tab ignored. Resets tab-local chat/history view and printer state, refreshes default model, emits `showWelcome{tabId,model}`. Does not allocate chat ID until a run.

#### `openTab`

- Catalog `src/kiss/server/sorcar.py:API:234`; handler `src/kiss/server/commands.py:_cmd_open_tab:831-867`. Required: `tabId`. Optional/consumed: `title`, `workDir`; stamped `connId`.
- Valid non-empty string ID opens canonical registry entry. Success broadcasts canonical `tabs_state`; existing ID is idempotent/no response. Capacity rejection sends requester-scoped `openTabRejected{tabId,text}`.

#### `closeTab`

- Catalog `src/kiss/server/sorcar.py:API:235`; handler `src/kiss/server/commands.py:_cmd_close_tab:869-873`; implementation `src/kiss/server/server.py:_close_tab:961-970`, `_drop_tab_state:990-1055`, `_teardown_tab_resources:1057-1124`. Required: `tabId`.
- Removes registry tab and broadcasts `tabs_state` if removal occurred. Closing does not stop busy task; marks frontend closed and defers cleanup. Idle pending worktree is released/preserved per state. Sub-agent close additionally broadcasts `closeSubagentTab`.

#### `resumeSession`

- Catalog `src/kiss/server/sorcar.py:API:236`; API translation `translate_webview_command:337-362`, `ServerApi.resume_session:759-771`; backend handler `src/kiss/server/commands.py:_cmd_resume_session:817-829`; replay `src/kiss/server/server.py:_replay_session:1161-1386`. Required: none. Optional/consumed: backend `chatId`, `taskId`, `tabId`; webview alias `id` renamed to `chatId` only when `chatId` absent.
- No chat ID and no valid task ID means no-op. Empty tab ID means no-op. With `taskId`, replay first attempts that row; failed lookup falls back to latest top-level task in `chatId`. Without `taskId`, it loads latest top-level task in chat. Rebinds canonical tab for non-subagent chat; emits registry state as needed, `status running:true` when reattaching, `task_events{events,task,task_id,chat_id,extra,tabId}`, pending `askUser`, pending worktree state, and persisted sub-agent tab/event broadcasts. Running task replay uses live recording and subscribes tab to future events. Missing DB result may still reattach live task; otherwise establishes empty chat view without `task_events` unless live.

#### `ready`

- Catalog `src/kiss/server/sorcar.py:API:237`; API handler `ServerApi.ready:773-813`; sanitization and implementation `src/kiss/server/web_server.py:_sanitized_restored_tabs:4905-4970`, `_handle_ready:4972-5036`. Required: none. Optional/consumed: `tabId`, `restoredTabs` list entries `{tabId,chatId,title,workDir}`, `workDir`; stamped `connId`.
- Sanitizes/caps restored tabs. Reconciles local UDS tab bookkeeping. Runs requester-scoped `getModels`, `getInputHistory`, `getConfig`; direct-sends `tasks_updated`; broadcasts welcome URL/update state; direct-sends `focusInput{tabId}`. Adopts restored tabs only through canonical registry sync, broadcasts canonical tab snapshot, then internally resumes each chat-bound registry tab (including pinned task ID). This command is reconnect/state reconstruction handshake, not transport authentication.

### History and task lists

#### `getHistory`

- Catalog `src/kiss/server/sorcar.py:API:238`; handler `src/kiss/server/commands.py:_cmd_get_history:508-520`; implementation `src/kiss/server/server.py:_get_history:779-887`. Required: none. Optional/consumed: `query`, `offset`, `generation`; stamped `connId`.
- Loads/searches up to 50 rows and responds requester-scoped `history{sessions,offset,generation,dateRange:{min,max}}`. Session fields are constructed at lines 807-878, including chat `id`, persisted `task_id`, title/timestamp/status/metrics/workspace/model/mode/timestamps and optional subagent metadata. Invalid integer-like paging fields become zero. Live rows receive current metrics and `is_running`.

#### `getAdjacentTask`

- Catalog `src/kiss/server/sorcar.py:API:239`; handler `src/kiss/server/commands.py:_cmd_get_adjacent_task:952-983`; implementation `src/kiss/server/server.py:_get_adjacent_task:1785-1818`. Required: `direction`. Optional/consumed: `tabId`, `taskId`.
- Derives chat from tab state/view map, asks persistence for adjacent row using supplied direction (server does not catalog-enforce `prev|next`), broadcasts `adjacent_task_events{direction,task,task_id,events,tabId}`; empty values when none.

#### `getFrequentTasks`

- Catalog `src/kiss/server/sorcar.py:API:240`; handler `src/kiss/server/commands.py:_cmd_get_frequent_tasks:522-527`; implementation `src/kiss/server/server.py:_get_frequent_tasks:919-936`. Required: none. Optional/consumed: `limit`; stamped `connId`.
- Invalid limit defaults 50. Sends requester-scoped `frequentTasks{tasks}` where entries come directly from persistence as task/count/timestamp records.

#### `deleteFrequentTask`

- Catalog `src/kiss/server/sorcar.py:API:241`; handler `src/kiss/server/commands.py:_cmd_delete_frequent_task:529-533`; implementation `src/kiss/server/server.py:_handle_delete_frequent_task:902-917`. Required: `task`.
- Non-empty string deletes exact task. Successful delete broadcasts refreshed `frequentTasks` globally (`connId` omitted); failed/no-op delete emits nothing.

#### `setFavorite`

- Catalog `src/kiss/server/sorcar.py:API:242`; handler `src/kiss/server/commands.py:_cmd_set_favorite:535-541`; implementation `src/kiss/server/server.py:_handle_set_favorite:889-900`. Required: `taskId`, `isFavorite` (false is valid). Optional: none.
- Non-empty string task ID required by handler; persists Boolean coercion of `isFavorite`. No response; frontend is optimistic, next history refresh reflects value.

#### `getInputHistory`

- Catalog `src/kiss/server/sorcar.py:API:243`; handler `src/kiss/server/commands.py:_cmd_get_input_history:948-950`; implementation `src/kiss/server/server.py:_get_input_history:938-959`. Required: none.
- Sends requester-scoped `inputHistory{tasks}` containing unique nonblank task texts in persistence load order.

#### `getWelcomeSuggestions`

- Catalog `src/kiss/server/sorcar.py:API:244-246`; API handler `ServerApi.get_welcome_suggestions:1053-1062`; implementation `src/kiss/server/web_server.py:_send_welcome_info:4817-4884`. Required/consumed: none.
- Despite name, broadcasts `remote_url{url,tunnelActive[,ntfyUrl]}` and, if cached version exists, `update_available{available,latest,current}`. It deliberately emits no `welcome_suggestions` event.

#### `activeTasksQuery`

- Catalog `src/kiss/server/sorcar.py:API:247`; API handler `ServerApi.active_tasks_query:1042-1051`; implementation `src/kiss/server/web_server.py:_handle_active_tasks_query:4724-4758`. Required/consumed: none.
- Direct reply only: `activeTasksResponse{count,tabs}`, where `tabs` contains formatted active tab/task strings.

### Models and configuration

#### `getModels`

- Catalog `src/kiss/server/sorcar.py:API:248`; handler `src/kiss/server/commands.py:_cmd_get_models:483-485`; response builder `src/kiss/server/server.py:_get_models:666-723`. Required: none.
- Sends requester-scoped `models{models,selected}`. Each built-in entry has `{name,inp,out,uses,vendor}`. Optional custom entry is constructed by `get_custom_model_entry` with those fields plus `endpoint`, plaintext `api_key`, and `extra_headers`, then prepended. Refreshes daemon default from persisted selection and available models.

#### `selectModel`

- Catalog `src/kiss/server/sorcar.py:API:249`; handler `src/kiss/server/commands.py:_cmd_select_model:487-506`. Required: `model`. Optional/consumed: `tabId`.
- String model updates per-tab selection when tab present and daemon-wide default; records model usage. Catalog does not verify model availability. No response.

#### `getConfig`

- Catalog `src/kiss/server/sorcar.py:API:250`; handler `src/kiss/server/commands.py:_cmd_get_config:1150-1176`. Required: none. Optional/consumed: stamped/explicit `workDir`; stamped `connId`.
- Loads config, replaces reported `work_dir` with command workspace when truthy, reads current API key presence/values per config helper, broadcasts requester-scoped `configData{config,apiKeys}`.

#### `saveConfig`

- Catalog `src/kiss/server/sorcar.py:API:251`; handler `src/kiss/server/commands.py:_cmd_save_config:1178-1262`. Required: `config`. Optional/consumed: `apiKeys`; stamped `connId`.
- Non-dict config becomes `{}`, sanitized and atomically merged under lock; non-empty string API-key values saved to shell config; work-dir fallback/cache may update. Responds by requester-scoped `models`, then requester-scoped `configData{config}`. Changed non-empty remote password schedules daemon restart; no dedicated acknowledgment.

#### `getDefaultModel`

- Catalog `src/kiss/server/sorcar.py:API:252`; API handler `ServerApi.get_default_model:927-943`; implementation `src/kiss/server/web_server.py:_handle_get_default_model:4233-4254`. Required/consumed: none.
- Direct reply `defaultModel{model}` from daemon environment/key-derived selector.

#### `readKissConfig`

- Catalog `src/kiss/server/sorcar.py:API:253`; API handler `ServerApi.read_kiss_config:945-966`; implementation `src/kiss/server/web_server.py:_handle_read_kiss_config:4256-4278`. Required/consumed: none.
- UDS only; WSS silently ignored. Direct reply `kissConfig{config}` with merged config, including sensitive fields.

#### `writeKissConfig`

- Catalog `src/kiss/server/sorcar.py:API:254-256`; API handler `ServerApi.write_kiss_config:968-991`; implementation `src/kiss/server/web_server.py:_handle_write_kiss_config:4280-4324`. Required: `config`.
- UDS only; WSS silently ignored. Non-object config directly replies `kissConfigSaved{ok:false,error}`. Save/apply success replies `{type:"kissConfigSaved",ok:true}`; `OSError` replies false/error.

### Workspace, files, autocomplete

#### `setWorkDir`

- Catalog `src/kiss/server/sorcar.py:API:259`; API connection-state behavior `ServerApi.dispatch:545-597`; backend handler `src/kiss/server/commands.py:_cmd_set_work_dir:1264-1309`. Required: `workDir`.
- Non-empty string updates connection work directory before backend. Backend updates daemon fallback, invalidates that connection's active-file/completion state and global file cache when fallback changes. No response.

#### `getFiles`

- Catalog `src/kiss/server/sorcar.py:API:260`; handler `src/kiss/server/commands.py:_cmd_get_files:543-568`; implementation `src/kiss/server/autocomplete.py:_get_files:708-760`, `_emit_files:664-706`. Required: `prefix`. Optional/consumed: `workDir`, `tabId`; stamped `connId`.
- Uses per-workspace cache and usage ranking. Cache hit emits requester/tab-scoped `files{files,prefix}`. Cache miss immediately emits same with `files:[]`, `loading:true`, then background scan emits populated event only if request remains latest.

#### `recordFileUsage`

- Catalog `src/kiss/server/sorcar.py:API:261`; handler `src/kiss/server/commands.py:_cmd_record_file_usage:570-582`. Required: `path`. Optional/stamped but informational: `workDir`.
- Non-empty string records global workspace-relative usage ranking. No response.

#### `openFile`

- Catalog `src/kiss/server/sorcar.py:API:262`; API handler `ServerApi.open_file:828-845`; implementation `src/kiss/server/web_server.py:_handle_open_file:4419-4490`. Required: `path`. Optional/consumed: `workDir`, `tabId`, documented `line` is accepted but not read by daemon.
- UDS silently ignored (extension host consumes it). WSS resolves regular file against workspace and pending worktree; direct `fileContent{path,name,tabId,content}` or same with `error`. Invalid/empty path can pass catalog only if empty and then yields no response. Size/binary/read failures return error.

#### `checkPaths`

- Catalog `src/kiss/server/sorcar.py:API:263`; API handler `ServerApi.check_paths:847-865`; implementation `src/kiss/server/web_server.py:_handle_check_paths:4663-4722`. Required: `paths`. Optional/consumed: `workDir`, `tabId`.
- UDS silently ignored. WSS non-list becomes empty list; invalid entries skipped. Direct reply `pathsExist{results,workDir,tabId}`.

#### `complete`

- Catalog `src/kiss/server/sorcar.py:API:268`; handler `src/kiss/server/commands.py:_cmd_complete:879-946`; emitters `src/kiss/server/autocomplete.py:_emit_completions:431-461`, `_emit_ghost:463-490`. Required: `query`. Optional/consumed: `activeFile`, `activeFileContent`, `tabId`; stamped `connId`.
- Empty/non-string query launches no work and emits nothing. Non-empty query queues per-connection latest-only background completion. Depending worker path, emits requester/tab-scoped `completions{completions:[{type,text}],query}` and/or `ghost{suggestion,query}`; late stale requests are suppressed.

### Sharing and voice

#### `shareChat`

- Catalog `src/kiss/server/sorcar.py:API:264`; API handler `ServerApi.share_chat:867-885`; implementation `src/kiss/server/web_server.py:_handle_share_chat:4492-4571`. Required: `chatId`, `html`. Optional/consumed: `title`, `workDir`, `tabId`.
- Both transports. Writes atomic `reports/chat-<sanitized-id>.html`. Direct reply `share_done{tabId,ok:true,path}` or `{tabId,ok:false,error}`. Empty required strings pass catalog but produce error reply.

#### `shareChatTasks`

- Catalog `src/kiss/server/sorcar.py:API:265-267`; API handler `ServerApi.share_chat_tasks:887-906`; implementation `src/kiss/server/web_server.py:RemoteAccessServer._handle_share_chat_tasks:4573-4661`. Required: `chatId`. Optional/consumed: `tabId`.
- Direct reply `share_tasks{tabId,chatId,tasks:[{task,task_id,events}],truncated}`; DB failure adds `error`. Empty/unknown chat returns empty list. Reply byte cap drops oldest task transcripts and sets truncation.

#### `voiceTranscribe`

- Catalog `src/kiss/server/sorcar.py:API:276-278`; API handler `ServerApi.voice_transcribe:908-925`; implementation `src/kiss/server/web_server.py:RemoteAccessServer._handle_voice_transcribe:4165-4231`. Required: `audio`.
- Intended WSS, but API handler does not gate transport. Accepts bounded base64 PCM; transcribes and best-effort identifies speaker. Direct reply always `voiceSpeech{text,speaker,language}`; malformed/failed input gives empty text and null metadata.

#### `voiceWakeStart`

- Catalog `src/kiss/server/sorcar.py:API:257`; API handler `ServerApi.voice_wake_start:993-1021`; implementation `src/kiss/server/web_server.py:_handle_voice_wake_start:4326-4359`. Required: none. Optional/consumed: `sensitivity` numeric finite, rounded.
- UDS only; WSS silently ignored. Starts/replaces listener owned by connection. Streams direct `voiceWakeEvent` / `voiceWakeState` events from controller. Listener stops on connection disconnect.

#### `voiceWakeStop`

- Catalog `src/kiss/server/sorcar.py:API:258`; API handler `ServerApi.voice_wake_stop:1023-1040`; implementation `src/kiss/server/web_server.py:_handle_voice_wake_stop:4361-4375`. Required/consumed: none.
- UDS only; WSS silently ignored. Stops connection-owned listener; no explicit reply beyond controller state event behavior.

### Git/worktree actions

#### `worktreeAction`

- Catalog `src/kiss/server/sorcar.py:API:269`; handler `src/kiss/server/commands.py:_cmd_worktree_action:1114-1125`; implementation `src/kiss/server/merge_flow.py:_handle_worktree_action:1329-1521`. Required: `action`. Optional/consumed: `tabId`.
- Accepted `action` values are exactly `merge`, `discard`, and `nothing`; other values return `success:false` with `Unknown action`. `nothing` preserves and detaches worktree (`kept:true`), `merge` emits `worktree_progress` before synchronous merge handling, and `discard` may return `retryable:true` when deferred. Handler has state/dirty-tree conflict checks, catches exceptions, then broadcasts one `worktree_result{tabId,success,message,...}`. Command is not request-ID correlated.

#### `mainTreeAction`

- Catalog `src/kiss/server/sorcar.py:API:270`; handler `src/kiss/server/commands.py:_cmd_main_tree_action:1127-1148`; implementation `src/kiss/server/merge_flow.py:_handle_main_tree_action:1523-1640`. Required: `action`. Optional/consumed: `tabId`, `workDir`.
- Accepted `action` values are exactly `discard` and `nothing`; other values return `success:false` with `Unknown action`. `nothing` leaves changes uncommitted. `discard` runs `git reset --hard` and `git clean -fd`, with repository/task guards and dirty-tree verification. Auto-commit uses separate command. Catches every exception and always broadcasts `main_tree_result{tabId,success,message,...}`.

#### `generateCommitMessage`

- Catalog `src/kiss/server/sorcar.py:API:271`; handler `src/kiss/server/commands.py:_cmd_generate_commit_message:985-1019`; implementation `src/kiss/server/server.py:_generate_commit_message:1820-1886`. Required: none. Optional/consumed: `tabId`, `workDir`.
- Single-flight per tab; duplicate silently dropped. Background job emits `commitMessage{message,tabId}` or `{message:"",error,tabId}` for non-repo, no staged changes, or generation failure.

#### `autocommitAction`

- Catalog `src/kiss/server/sorcar.py:API:272`; handler `src/kiss/server/commands.py:_cmd_autocommit_action:1039-1094`; implementation `src/kiss/server/merge_flow.py:_autocommit_changes:380-541`. Required: none. Optional/consumed: `tabId`, `workDir`.
- Manual stage-all/commit background flow, single-flight per tab. Refuses while non-worktree task runs in same repo and emits failure via autocommit result/notification path. Duplicate in flight silently drops with no event. Started operation stages via `git add -A`, generates commit message, and commits. Non-manual paths emit `autocommit_progress`; manual path emits `notification`. Every started operation emits `autocommit_done{success,committed,message,tabId[,commitMessage,manual,workDir]}` through `_broadcast_autocommit_done` (`src/kiss/server/merge_flow.py:_broadcast_autocommit_done:313-378`).

### Maintenance

#### `runUpdate`

- Catalog `src/kiss/server/sorcar.py:API:274`; API handler `ServerApi.run_update:1064-1073`; implementation `src/kiss/server/web_server.py:_handle_run_update:4033-4091`. Required/consumed: none; stamped `connId`.
- Single-flight. Requester-scoped `notice` when already running or accepted; missing installer emits requester-scoped `error`; spawn failure also emits `error`. Accepted installer runs detached and may restart daemon. No completion event from installer.

#### `serverReset`

- Catalog `src/kiss/server/sorcar.py:API:275`; API handler `ServerApi.server_reset:1075-1086`; implementation `src/kiss/server/web_server.py:_handle_server_reset:3896-3928`. Required/consumed: none; stamped `connId`.
- Emits requester-scoped `notification{id:"server-reset-restarting",severity:"info",message}`, writes reset marker, schedules self-`SIGTERM`. Graceful shutdown interrupts tasks. Supervisor is expected to restart daemon; new daemon broadcasts `notification{id:"server-reset-complete",...}` after finding marker (`_maybe_schedule_server_reset_complete:3950-3982`). Connection necessarily drops.

### Accepted but daemon-discarded host/handshake commands

Source: catalog `src/kiss/server/sorcar.py:API:273-289`, derived `DROPPED_COMMANDS:291-304`, early drop `ServerApi.dispatch:571-572`.

These commands produce no daemon response and are discarded before required-field validation. Listed required fields describe catalog only; missing fields are still silently accepted because drop occurs first.

| command | catalog-required fields | catalog line | intended consumer recorded in source |
|---|---|---:|---|
| `auth` | `password` | 273 | WSS pre-dispatch handshake; post-auth dispatch drops it |
| `voiceToggle` | `enabled` | 279 | extension/webview voice bridge |
| `voiceSensitivity` | `value` | 280 | extension/webview voice bridge |
| `voiceAck` | none | 281 | extension/webview voice bridge |
| `voiceDropped` | `text` | 282 | extension/webview voice bridge |
| `focusEditor` | none | 283 | extension host |
| `webviewFocusChanged` | none | 284 | extension host |
| `activeTabChanged` | `tabId` | 285 | extension host |
| `notificationAction` | `id` | 286 | extension host/webview |
| `sizeReport` | none | 287 | extension host/webview |
| `resolveDroppedPaths` | `uris` | 288 | extension host |

`auth` has separate WSS handshake lifecycle in `src/kiss/server/sorcar.py:ServerApi.authenticate:619-743`: first correct auth receives `auth_ok`; first wrong attempt receives `auth_required`; lockout receives `auth_locked{retry_after}` then close; second wrong receives `error{"text":"Authentication failed"}` then close; first non-auth message closes without ordinary command dispatch. UDS skips auth.

## Exhaustiveness check

At inspected revision, `API` contains 53 command names: 42 routed commands and 11 dropped commands. Backend `_HANDLERS` contains 26 forwarded command handlers. Remaining routed commands use explicit `ServerApi` handlers (`submit`, `resume_session`, `ready`, welcome/active-task/config/default-model/voice/file/share/update/reset handlers). No other command can pass `validate_command`; unknown names receive `error`.

## Daemon-to-client event catalog

Source inspected: `../../kiss_ai`, commit `74af9b738adeef91448790015cf8f416da71566c`.

Scope: every outbound event found in Python daemon/server code, plus inbound handling in Python daemon API, VS Code host, shared VS Code/remote browser client, and WebSocket auth shim. Facts only. `path:symbol:line` references use inspected revision.

## Common wire and routing behavior

- `JsonPrinter.broadcast` stamps absent `ts` with Unix epoch milliseconds. Existing `ts` survives. It injects thread-local `taskId` only when event has no non-`None` `taskId`. `src/kiss/server/json_printer.py:stamp_event_ts:90-104`; `JsonPrinter._inject_task_id:787-805`; `JsonPrinter.broadcast:1235-1267`.
- `WebPrinter.broadcast` routes an event carrying `connId` only to that connection and removes `connId` before wire send. Explicit `tabId` events otherwise go to all connections; clients select matching tab. Task-bound events without explicit `tabId` are recorded/persisted and copied to each subscribed tab with that tab's `tabId`. Events with neither task nor tab identity are global. `src/kiss/server/server.py:broadcast_to_conn:216-237`; `src/kiss/server/web_server.py:WebPrinter.broadcast:1922-2010`.
- Explicit-tab events are transient, except `prompt` and `result` with nonempty `taskId`: printer records a copy with `tabId` removed. `recordOnly` is removed and suppresses live send. `src/kiss/server/json_printer.py:JsonPrinter.broadcast:1235-1267`.
- `broadcast_transient` resolves task watchers and emits one explicit-`tabId` copy per watcher; fallback emits one copy using supplied tab ID, possibly empty. These are not task-recorded. `src/kiss/server/json_printer.py:JsonPrinter._transient_targets:603-654`; `JsonPrinter.broadcast_transient:656-690`.
- Recorded order is append order. Adjacent `thinking_delta`, `text_delta`, and `system_output` records coalesce by text concatenation; no other event coalesces. No sequence number exists and code defines no total order across concurrent threads. `src/kiss/server/json_printer.py:_coalesce_events:107-135`; `JsonPrinter._record_event:1178-1192`.
- VS Code socket client buffers split reads, splits multiple newline frames, JSON-decodes each frame, then emits each parsed message. `src/kiss/agents/vscode/src/AgentClient.ts:AgentClient._handleData:209-235`.
- VS Code host performs selected native actions, then forwards every parsed daemon message unchanged to webview. Unknown types still reach webview; webview switch has no default action. `src/kiss/agents/vscode/src/SorcarSidebarView.ts:SorcarSidebarView._installClientListener:461-640`; `src/kiss/agents/vscode/media/main.js:handleEvent:6215-7332`.

## Event catalog

“Terminal” names exact boundary: task, request, interaction, or UI operation. It does not imply socket closure unless stated.

### Task stream and lifecycle

#### `task_settings`

- Fields: `type`, `settings`, `taskId`; live agent construction initially has `type`, `settings`, then printer routing adds identity. Settings contain `model`, `work_dir`, `is_parallel`, `is_worktree`, `chat_id`, `task_id`, `is_subagent`; optional `start_ts`, positive `max_budget`, nonempty `parent_task_id`. `src/kiss/server/json_printer.py:_task_settings_event_from_session:138-196`; `src/kiss/agents/sorcar/chat_sorcar_agent.py:ChatSorcarAgent._task_settings_payload:332-377`, `ChatSorcarAgent.run:574-590`.
- Replay helper prepends synthesized event only when replay has none and session `extra` decodes to object. Intermediate. `src/kiss/server/json_printer.py:with_task_settings_event:199-224`.
- Client: transcript renders execution settings. `src/kiss/agents/vscode/media/main.js:handleOutputEvent:4981-5023`.

#### `prompt`

- Agent stream fields: `type`, `text`; printer converts content with `str`. Deferred live-steering persistence uses internal `recordOnly:true`, removed before storage. `src/kiss/server/json_printer.py:JsonPrinter.drain_pending_user_messages:536-570`, `JsonPrinter.print:1343-1345`.
- Early run form: `type,text,tabId,taskId:"",early:true`; occurs after start status and immediately after early `system_prompt`. `src/kiss/server/task_runner.py:_broadcast_early_prompts:682-746`.
- Live-steering echo: `type,text,tabId`, optional owning `taskId`; emitted after queue append succeeds. `src/kiss/server/commands.py:_echo_injected_prompt:716-758`, `_cmd_append_user_message:760-819`.
- Intermediate. Client renders prompt panel. `src/kiss/agents/vscode/media/main.js:handleOutputEvent:4924-4966`.

#### `system_prompt`

- Normal fields: `type,text`; early form adds `tabId,taskId:"",early:true`. `src/kiss/server/json_printer.py:JsonPrinter.print:1343-1345`; `src/kiss/server/task_runner.py:_broadcast_early_prompts:682-746`.
- Early form precedes early `prompt`; intermediate. Client renders prompt panel. `src/kiss/agents/vscode/media/main.js:handleOutputEvent:4924-4966`.

#### `thinking_start`

- Fields: `type`. Sets thinking mode before send and opens a thinking block. Intermediate. Client creates the thinking panel. `src/kiss/server/json_printer.py:JsonPrinter.thinking_callback:1496-1511`; `src/kiss/agents/vscode/media/main.js:handleOutputEvent:4542-4595`.

#### `thinking_delta`

- Fields: `type,text`. Nonempty thinking tokens emit deltas after `thinking_start` and before `thinking_end`. Intermediate. Client appends text to the thinking panel. `src/kiss/server/json_printer.py:JsonPrinter.token_callback:1483-1494`, `JsonPrinter.thinking_callback:1496-1511`; `src/kiss/agents/vscode/media/main.js:handleOutputEvent:4542-4595`.

#### `thinking_end`

- Fields: `type`. Clears thinking mode before send and closes the thinking block. Terminal for one thinking block, not task-terminal. Client flushes and closes the thinking panel. `src/kiss/server/json_printer.py:JsonPrinter.thinking_callback:1496-1511`; `src/kiss/agents/vscode/media/main.js:handleOutputEvent:4542-4595`.

#### `text_delta`

- Fields: `type,text`. Rich-rendered `print(type="text")` suppresses whitespace-only output; token callback suppresses empty tokens. Intermediate. Client buffers delta text. `src/kiss/server/json_printer.py:JsonPrinter.print:1332-1342`, `JsonPrinter.token_callback:1483-1494`; `src/kiss/agents/vscode/media/main.js:handleOutputEvent:4596-4646`.

#### `text_end`

- Fields: `type`. Immediately precedes `tool_call`; direct `print(type="result")` also emits it immediately before `result`. Message-object result path does not add it. Terminal for one text block, not task-terminal. Client flushes and Markdown-renders buffered text. `src/kiss/server/json_printer.py:JsonPrinter.print:1387-1395,1421-1429`, `JsonPrinter._handle_message:1542-1548`; `src/kiss/agents/vscode/media/main.js:handleOutputEvent:4596-4646`.

#### `system_output`

- Fields: `type,text`. Bash fragments buffer and flush in order at roughly 0.1-second scheduling boundaries. Pending output flushes before tool call/result. Message subtype `tool_output` emits nonempty content directly. `src/kiss/server/json_printer.py:JsonPrinter._flush_bash:1058-1098`, `JsonPrinter.print:1349-1386`, `JsonPrinter._handle_message:1536-1541`.
- Intermediate. Client renders system output. `src/kiss/agents/vscode/media/main.js:handleOutputEvent:4856-4880`.

#### `tool_call`

- Always: `type,name`. Conditional: paired `path,lang` when extracted path is truthy; truthy string `description`, `command`, `content`; `old_string`/`new_string` when input is not `None`, including empty strings; truthy `extras`. `src/kiss/server/json_printer.py:JsonPrinter._format_tool_call:1513-1534`.
- Pending bash flush, then `text_end`, then `tool_call`. Intermediate. `src/kiss/server/json_printer.py:JsonPrinter.print:1387-1395`.
- Client renders tool panel and special handling for Bash, `run_parallel`, `summary`, report paths. `src/kiss/agents/vscode/media/main.js:handleOutputEvent:4647-4804`.

#### `tool_result`

- Always: `type,content,is_error,tool_name`. Optional `path` from truthy `tool_input.file_path`, else `tool_input.path`; optional integer `start_line >= 1`. Bash content becomes empty when already streamed. `src/kiss/server/json_printer.py:JsonPrinter._emit_tool_result:1432-1481`.
- Pending bash flushes first. No event for `tool_name == "finish"`. Intermediate. Client attaches result to tool state. `src/kiss/agents/vscode/media/main.js:handleOutputEvent:4805-4855`.

#### `usage_info`

- Fields: `type,text,total_tokens,cost,total_steps`. Task offsets are added. Parseable dollar cost receives budget offset and four-decimal formatting; malformed/non-dollar text remains unchanged. `src/kiss/server/json_printer.py:JsonPrinter._cost_with_offset:1269-1287`, `JsonPrinter.print:1404-1420`.
- Intermediate metrics. Client updates token/cost/step display. `src/kiss/agents/vscode/media/main.js:handleOutputEvent:4967-4980`.

#### `result`

- Agent result fields: `type,text,total_tokens,cost,step_count`; empty text becomes `(no result)`. Parsed finish YAML conditionally adds `success,is_continue,summary`. `src/kiss/server/json_printer.py:JsonPrinter._broadcast_result:1289-1311`.
- Runner failure forms contain `type,text,success:false,total_tokens,cost,step_count`, plus route identity (`tabId` or `taskId`) according to path. `src/kiss/server/task_runner.py:_run_task:537-558`, `_run_task_inner:866-885,1148-1176,1197-1234`.
- Final agent-result signal, but not task lifecycle terminal: persistence/tree handling and lifecycle event follow; setup failure can instead go directly to end status. Client renders result and metrics. `src/kiss/agents/vscode/media/main.js:handleOutputEvent:4881-4923`.

#### `warning`

- Fields: `type,message`; printer adds task/tab route. Worktree warning order is stash warning first, merge warning second when present. `src/kiss/agents/sorcar/worktree_sorcar_agent.py:WorktreeSorcarAgent._flush_warnings:1240-1300`.
- Intermediate. Client renders nested or top-level warning. `src/kiss/agents/vscode/media/main.js:handleOutputEvent:5040-5046`, `handleEvent:6512-6520`.

#### `tasks_updated`

- Fields: `type`; some agent-start path explicitly adds `taskId:""`; normal bound runner path receives injected task identity. `src/kiss/agents/sorcar/chat_sorcar_agent.py:ChatSorcarAgent.run:552-559`; `src/kiss/server/task_runner.py:_run_task_inner:1326`, `_persist_subtask_row:1547`.
- Refresh/invalidation signal. Normal completion emits it after result persistence and before tree presentation and live lifecycle terminal. Client refreshes history. `src/kiss/agents/vscode/media/main.js:handleEvent:6637-6641`.

#### `task_done`

- Persisted form has `type`; live form adds `tabId,startTs,endTs`. Selected when agent call returns normally, including parsed finish payload with `success:false`; that failure flag affects post-task Git policy but does not change terminal event to `task_error`. Persisted before `tasks_updated` and optional tree presentation; live event precedes file refresh and outer `status{running:false}`. Task-terminal. Client marks task terminal, clears progress, labels/focuses tab, and opens completed reports. `src/kiss/server/task_runner.py:_run_task_inner:1108-1136,1238-1438`, `_run_task:442-604`; `src/kiss/agents/vscode/media/main.js:handleEvent:7070-7131`.

#### `task_error`

- Persisted form has `type,text`; live form adds `tabId,startTs,endTs`. Selected for failed task outcome. Persisted before `tasks_updated` and optional tree presentation; live event precedes file refresh and outer `status{running:false}`. Task-terminal. Client marks task terminal, clears progress, labels/focuses tab, and opens completed reports. `src/kiss/server/task_runner.py:_run_task_inner:1108-1136,1200-1214,1284-1438`, `_run_task:442-604`; `src/kiss/agents/vscode/media/main.js:handleEvent:7070-7131`.

#### `task_stopped`

- Persisted form has `type`; live form adds `tabId,startTs,endTs`. Selected for user-stop outcome. Persisted before `tasks_updated` and optional tree presentation; live event precedes file refresh and outer `status{running:false}`. Task-terminal. Client marks task terminal, clears progress, labels/focuses tab, and opens completed reports. `src/kiss/server/task_runner.py:_cancel_outcome:1611-1646`, `_run_task_inner:1284-1438`, `_run_task:442-604`; `src/kiss/agents/vscode/media/main.js:handleEvent:7070-7131`.

#### `task_interrupted`

- Persisted form has `type`; live form adds `tabId,startTs,endTs`. Selected for daemon shutdown/restart interruption. Persisted before `tasks_updated` and optional tree presentation; live event precedes file refresh and outer `status{running:false}`. Task-terminal. Client marks task terminal, clears progress, labels/focuses tab, and opens completed reports. `src/kiss/server/task_runner.py:_cancel_outcome:1611-1646`, `_run_task_inner:1284-1438`, `_run_task:442-604`; `src/kiss/agents/vscode/media/main.js:handleEvent:7070-7131`.

#### `followup_suggestion`

- Fields: `type,text`; task route fields added by printer. Asynchronous after lifecycle terminal scheduling; subscriber linger releases immediately after broadcast. Ordering against outer end status is not synchronized. `src/kiss/server/server.py:VSCodeServer._generate_followup_async:1714-1769`; launch `src/kiss/server/task_runner.py:_run_task_inner:1406-1422`.
- Post-task, not lifecycle terminal. Client appends clickable suggestion to addressed transcript. `src/kiss/agents/vscode/media/main.js:handleEvent:6616-6636`.

### Run control, replay, tabs, and interaction

#### `setTaskText`

- Fields: `type,text,tabId`. Unconditional first run acknowledgement, before validation/state checks/clear/worker start. `src/kiss/server/commands.py:_cmd_run:331-359`.
- Intermediate. Client updates addressed task title/panel. `src/kiss/agents/vscode/media/main.js:handleEvent:6835-6870`.

#### `clear`

- Fields: `type,chat_id,tabId`. New accepted run: registry update and possible `tabs_state` precede clear; worker starts after. Viewer attach emits clear then running status. `src/kiss/server/commands.py:_cmd_run:434-468`; `src/kiss/server/task_runner.py:_run_task:474-533`, `_subscribe_chat_viewers:1699-1715`.
- Intermediate transcript reset. Client resets task/transcript and binds backend chat ID. `src/kiss/agents/vscode/media/main.js:handleEvent:6523-6569`.

#### `status`

- Fields: `type,running,tabId`; start forms add `startTs`; some client-origin start/end forms carry client `taskId`. `src/kiss/server/task_runner.py:_run_task:442-604`, `_broadcast_status_end_to_viewers:627-680`, `_subscribe_chat_viewers:1650-1715`; `src/kiss/server/server.py:VSCodeServer._replay_session:1212-1243,1350-1365`.
- Normal run: running true precedes inner execution. Lifecycle terminal occurs before guaranteed outer running false. Resume emits running true before `task_events`. Running false is UI-running terminal, separate from lifecycle terminal.
- VS Code host maintains running-tab set and resolves pending commit wait on stop. Browser updates timestamps, controls, tab/history state. `src/kiss/agents/vscode/src/SorcarSidebarView.ts:_installClientListener:622-639`; `src/kiss/agents/vscode/media/main.js:handleEvent:6345-6384`.

#### `stop_ack`

- Fields: `type,accepted,tabId`. False sends immediately when no routable live task. True sends before cooperative stop event is set and watchdog starts. `src/kiss/server/task_runner.py:_stop_task:1717-1793`, `_broadcast_stop_ack:1795-1812`.
- Terminal acknowledgement for stop command, not task. Client clears stale stopping/running UI on rejection. `src/kiss/agents/vscode/media/main.js:handleEvent:6405-6416`.

#### `tabs_state`

- Fields: `type,tabs,tabId:""`. Global transient canonical snapshot after changed registry mutation and during ready synchronization. `src/kiss/server/server.py:VSCodeServer._broadcast_tabs_state:458-474`, `_registry_update_tab:476-515`, `ready_tab_sync:517-546`, `_close_tab:962-969`.
- Not task terminal. Host reconciles ownership/resources; browser reconciles when `tabs` is array. `src/kiss/agents/vscode/src/SorcarSidebarView.ts:_installClientListener:518-540`; `src/kiss/agents/vscode/media/main.js:handleEvent:6871-6876`.

#### `showWelcome`

- Fields: `type,tabId,model`. Emitted after new-chat tab reset/printer cleanup. `src/kiss/server/server.py:VSCodeServer._new_chat:1123-1162`.
- UI state, not task terminal. Client displays welcome. `src/kiss/agents/vscode/media/main.js:handleEvent:6581-6602`.

#### `task_events`

- Fields: `type,events,task,task_id,chat_id,extra,tabId`. Replay response. Running resume optionally sends running status first; pending `askUser`, pending worktree UI, and persisted subagent opening can follow. `src/kiss/server/server.py:VSCodeServer._replay_session:1164-1385`.
- Not terminal; nested list may include persisted lifecycle terminals. Host recovers worktree paths. Browser replaces transcript, replays nested events through output handler, restores IDs/settings/metrics. `src/kiss/agents/vscode/src/SorcarSidebarView.ts:_installClientListener:507-517`; `src/kiss/agents/vscode/media/main.js:handleEvent:6642-6820`.

#### `adjacent_task_events`

- Fields: `type,direction,task,task_id,events,tabId`; no result uses empty task, null task ID, empty list. `src/kiss/server/server.py:VSCodeServer._get_adjacent_task:1790-1818`.
- Terminal response for navigation request, not task. Client renders only for visible conversation. `src/kiss/agents/vscode/media/main.js:handleEvent:6821-6834`.

#### `askUser`

- Initial fields: `type,question`; task routing adds `taskId,tabId`. Replay form explicitly has `tabId` and no `taskId`. Pending assignment and initial broadcast occur under same state lock before answer wait. Replay emits after `task_events`; lock prevents replayed ask from following corresponding done. `src/kiss/server/task_runner.py:_ask_user_question:1974-2020`; `src/kiss/server/server.py:VSCodeServer._emit_pending_ask:1388-1427`.
- Blocking intermediate interaction. Client records/deduplicates question and displays input. `src/kiss/agents/vscode/media/main.js:handleEvent:6446-6462`.

#### `askUserDone`

- Fields: `type,tabId`; one explicit copy per current subscriber of answered task, or answering tab when task ID/subscriber set is empty. Emitted after pending question clears and answer queues, outside state lock. `src/kiss/server/commands.py:_cmd_user_answer:581-665`.
- Terminal for one question, not task. Client clears pending question UI. `src/kiss/agents/vscode/media/main.js:handleEvent:6463-6469`.

#### `modelPick`

- Fields: `type,model,source,tabId`; source values constructed here are `agent` and `restore`. Agent selection may fan out to watchers; new subscription can receive catch-up. Restore only sends for overridden tab. `src/kiss/server/json_printer.py:JsonPrinter.subscribe_tab:377-406`, `broadcast_model_pick:692-722`, `broadcast_agent_model_pick:724-768`, `restore_model_pick:770-785`.
- Transient picker state, not terminal. Client applies override/restore. `src/kiss/agents/vscode/media/main.js:handleEvent:6417-6420`.

### Subagents

#### `new_tab`

- Fields: `type,task_id,parent_tab_id,taskId:""`. Emitted after subagent task ID allocation, before recording starts and before start `tasks_updated`/`task_settings`. `src/kiss/agents/sorcar/chat_sorcar_agent.py:ChatSorcarAgent.run:536-590`.
- Intermediate. Client deduplicates/creates subagent tab and sends `resumeSession`. `src/kiss/agents/vscode/media/main.js:handleEvent:7132-7189`.

#### `openSubagentTab`

- Fields: `type,tab_id,parent_tab_id,description,task_id,isSubagentTab,isDone`; persisted-child enumeration also adds `taskIndex`. `src/kiss/server/server.py:VSCodeServer._replay_session:1326-1345`, `_open_persisted_subagent_tabs:1510-1589`.
- Precedes corresponding child `task_events`; intermediate. Host adopts ownership; browser places/deduplicates tab and binds parallel panel. `src/kiss/agents/vscode/src/SorcarSidebarView.ts:_installClientListener:476-486`; `src/kiss/agents/vscode/media/main.js:handleEvent:7190-7279`.

#### `subagentDone`

- Fields: `type,tab_id,tabId:""`. Runtime emits per registered viewer after completion cleanup; replay emits race correction when child changed from running to done during replay. `src/kiss/agents/sorcar/sorcar_agent.py:SorcarAgent._broadcast_subagent_done:224-251`; `src/kiss/server/server.py:_open_persisted_subagent_tabs:1579-1589`.
- Terminal for subagent-tab running indicator, not parent lifecycle. Client marks tab done. `src/kiss/agents/vscode/media/main.js:handleEvent:7313-7332`.

#### `closeSubagentTab`

- Fields: `type,tab_id,tabId:""`. Global transient after backend drops subagent state. `src/kiss/server/server.py:VSCodeServer._drop_tab_state:1007-1040`, `_broadcast_subagent_close:1042-1059`.
- UI-terminal for tab. Client closes matching tab. `src/kiss/agents/vscode/media/main.js:handleEvent:7280-7286`.

#### `openTabRejected`

- Wire fields: `type,tabId,text`; temporary `connId` removed. Only requesting connection when present. Emitted when registry rejects open and tab remains absent. `src/kiss/server/commands.py:_cmd_open_tab:836-867`.
- Terminal for open attempt. Client removes optimistic tab and surfaces error. `src/kiss/agents/vscode/media/main.js:handleEvent:7287-7312`.

### Models, config, history, completion

#### `models`

- Fields: `type,models,selected`. Built-in entries: `name,inp,out,uses,vendor`; custom entry comes from `get_custom_model_entry`. Connection-targeted response. `src/kiss/server/server.py:VSCodeServer._get_models:671-722`.
- Single `getModels` response; also precedes `configData` after save. Host caches selected; browser replaces model list/default. `src/kiss/agents/vscode/src/SorcarSidebarView.ts:_installClientListener:473-475`; `src/kiss/agents/vscode/media/main.js:handleEvent:6385-6404`.

#### `configData`

- `getConfig`: `type,config,apiKeys`. `saveConfig`: `type,config`. Connection target removed before wire. Save sends `models` first, then config event. `src/kiss/server/commands.py:_cmd_get_config:1152-1176`, `_cmd_save_config:1178-1262`.
- Terminal config response. Host overwrites `config.work_dir` with current VS Code workspace before forwarding. Browser populates form. `src/kiss/agents/vscode/src/SorcarSidebarView.ts:_installClientListener:463-465`; `src/kiss/agents/vscode/media/main.js:handleEvent:6421-6423`.

#### `history`

- Fields: `type,sessions,offset,generation,dateRange`; `dateRange={min,max}`. Every session: `id,task_id,title,timestamp,preview,has_events,failed,is_running,tokens,cost,steps,is_favorite,work_dir,model,is_worktree,is_parallel,auto_commit_mode,startTs,endTs`; conditional `is_subagent,parent_task_id`. `src/kiss/server/server.py:VSCodeServer._get_history:779-887`.
- Connection-targeted paginated/search response. Client renders sessions/range. `src/kiss/agents/vscode/media/main.js:handleEvent:6424-6427`.

#### `frequentTasks`

- Fields: `type,tasks`; entries documented/constructed as task text, count, timestamp. Requested response is connection-targeted; delete refresh without connection ID is global. `src/kiss/server/server.py:_handle_delete_frequent_task:906-916`, `_get_frequent_tasks:918-936`.
- Snapshot response. Client renders list. `src/kiss/agents/vscode/media/main.js:handleEvent:6428-6430`.

#### `inputHistory`

- Fields: `type,tasks`; tasks is deduplicated task-text list. Connection-targeted response. `src/kiss/server/server.py:VSCodeServer._get_input_history:938-959`.
- Client replaces prompt-history cache. `src/kiss/agents/vscode/media/main.js:handleEvent:6923-6926`.

#### `ghost`

- Fields: `type,suggestion,query`; optional source routing `connId,tabId` when nonempty (`connId` removed on wire). `src/kiss/server/autocomplete.py:_emit_ghost:469-491`.
- Request response. For completion, emitted before `completions`; stale worker results are suppressed under lock. Client requires active tab/current query. `src/kiss/server/autocomplete.py:_complete:295-360`; `src/kiss/agents/vscode/media/main.js:handleEvent:6927-6934`.

#### `completions`

- Fields: `type,completions,query`; optional routing IDs. Each item has `type,text`; producers include task, trick, identifier entries. `src/kiss/server/autocomplete.py:_complete_many:369-430`, `_emit_completions:436-461`.
- Follows `ghost`; request response. Client requires active tab/current query. `src/kiss/agents/vscode/media/main.js:handleEvent:6935-6945`.

#### `files`

- Fields: `type,files,prefix`; optional `loading:true`, routing IDs. Loading response may precede final ranked result. `src/kiss/server/autocomplete.py:_emit_files:681-710`.
- Client checks active tab/prefix then renders picker. `src/kiss/agents/vscode/media/main.js:handleEvent:6431-6445`.

### Worktree, main-tree, and commit flow

#### `worktree_created`

- Fields before route: `type,worktreeDir,worktreeWorkDir,branch`. Emitted after worktree fields assigned, before worktree task execution. `src/kiss/agents/sorcar/worktree_sorcar_agent.py:WorktreeSorcarAgent.run:1302-1410`.
- Intermediate. Host caches path/opens SCM; browser rechecks links. `src/kiss/agents/vscode/src/SorcarSidebarView.ts:_installClientListener:487-506`; `src/kiss/agents/vscode/media/main.js:handleEvent:6972`.

#### `worktree_done`

- Fields: `type,branch,worktreeDir,worktreeWorkDir,originalBranch,changedFiles,hasConflict,tabId` in current construction. Emitted only when changed-file list nonempty; means pending worktree ready for review, not merge/discard completion. `src/kiss/server/merge_flow.py:_present_pending_worktree:977-1060`.
- Host caches path/opens SCM. Browser installs action bar. `src/kiss/agents/vscode/src/SorcarSidebarView.ts:_installClientListener:487-506`; `src/kiss/agents/vscode/media/main.js:handleEvent:6973-6989`.

#### `worktree_progress`

- Fields: `type,message`; optional `tabId` when nonempty. Current merge path message is `Generating commit message…`. `src/kiss/server/merge_flow.py:_MergeFlowMixin._handle_worktree_action:1329-1521`.
- Intermediate. Host updates progress UI; browser replaces action-progress line. `src/kiss/agents/vscode/src/SorcarSidebarView.ts:_installClientListener:541-550`; `src/kiss/agents/vscode/media/main.js:handleOutputEvent:5024-5028`.

#### `worktree_result`

- Fields: `type,tabId`, plus action-result mapping. Current result branches supply `success,message` and conditionally `kept` or `retryable`. `src/kiss/server/commands.py:_cmd_worktree_action:1114-1126`; `src/kiss/server/merge_flow.py:_MergeFlowMixin._finalize_pending_worktree:930-975`, `_handle_worktree_action:1329-1521`.
- Terminal for worktree action, not task. Automatic post-task form occurs after `tasks_updated` and before task lifecycle terminal. Host retires merged/discarded worktree, resolves action, notifies; browser clears progress/action bar and renders result. `src/kiss/agents/vscode/src/SorcarSidebarView.ts:_installClientListener:551-589`; `src/kiss/agents/vscode/media/main.js:handleEvent:7007-7031`.

#### `main_tree_done`

- Fields: `type,tabId,workDir,changedFiles`. Emitted post-task for non-worktree run when main tree remains dirty, after `tasks_updated`, before lifecycle terminal. `src/kiss/server/task_runner.py:_run_task_inner:1351-1386`.
- Intermediate action-bar presentation. Client installs main-tree action bar. `src/kiss/agents/vscode/media/main.js:handleEvent:6990-7006`.

#### `main_tree_result`

- Fields: `type,tabId`, plus action-result mapping. `src/kiss/server/commands.py:_cmd_main_tree_action:1128-1150`.
- Terminal action response. Host shows owned-tab notification; browser clears/renders result. `src/kiss/agents/vscode/src/SorcarSidebarView.ts:_installClientListener:590-600`; `src/kiss/agents/vscode/media/main.js:handleEvent:7007-7031`.

#### `autocommit_progress`

- Fields: `type,message,tabId`. Non-manual path messages are `Staging changes…`, `Generating commit message…`, `Committing…`; cross-repository path can use `Committing changes in {repo.name}…`. Manual path suppresses these events and uses `notification`. `src/kiss/server/merge_flow.py:_autocommit_changes:439-504`, `_autocommit_paths_in_repo:746-750`.
- Intermediate. Client replaces action-progress line. `src/kiss/agents/vscode/media/main.js:handleOutputEvent:5024-5028`.

#### `autocommit_done`

- Fields: `type,success,committed,message,tabId`; optional `commitMessage`, `manual:true`, and `workDir`. Emitted for success, no-change, and failure outcomes of started operation. `src/kiss/server/merge_flow.py:_broadcast_autocommit_done:313-378`.
- Terminal for autocommit attempt. Host handles owned non-manual notification; browser clears progress/bar and renders outcome. `src/kiss/agents/vscode/src/SorcarSidebarView.ts:_installClientListener:601-614`; `src/kiss/agents/vscode/media/main.js:handleEvent:7032-7069`.

#### `commitMessage`

- Success: `type,message,tabId`. Failure/no-op: same plus `error`. Exactly one result on non-repo, no staged changes, generated message, or exception path. `src/kiss/server/server.py:VSCodeServer._generate_commit_message:1820-1886`.
- Terminal request response. VS Code host resolves owned callback; browser deliberately no-ops. `src/kiss/agents/vscode/src/SorcarSidebarView.ts:_installClientListener:466-472`; `src/kiss/agents/vscode/media/main.js:handleEvent:6946-6947`.

#### `notification`

- Generic fields: `type,id,severity,message`; optional `tabId`. Worktree-agent generating stage adds `sticky:true`. Manual commit uses stable `manual-commit:{tab_id}` ID for start/outcome. `src/kiss/server/merge_flow.py:_broadcast_autocommit_done:313-363`, `_autocommit_changes:380-541`; `src/kiss/agents/sorcar/worktree_sorcar_agent.py:WorktreeSorcarAgent._broadcast_commit_notification:262-335`.
- Start intermediate; matching outcome terminal for operation. Client renders/deduplicates by ID. `src/kiss/agents/vscode/media/main.js:handleEvent:6253-6271`.

### Errors and speech

#### `error`

- Unknown command: `type,text`, optional copied `tabId`, requesting-connection route. Run refusal: `type,text,tabId`. Auth failure: `type,text:"Authentication failed"`. Other web endpoint errors use same top-level `type,text` and may include request-specific route fields. `src/kiss/server/server.py:VSCodeServer._handle_command:607-618`; `src/kiss/server/commands.py:_cmd_run:371-388`; `src/kiss/server/task_runner.py:_run_task_inner:884-930`; `src/kiss/server/sorcar.py:ServerApi.dispatch:570-584`, `ServerApi.authenticate:731-736`.
- Error notification is not universally task-terminal. Browser routes addressed background errors to transcript, otherwise active UI. `src/kiss/agents/vscode/media/main.js:handleEvent:6490-6501`.

#### `notice`

- Fields: `type,text` in remote web server responses; route may be added by caller. `src/kiss/server/web_server.py:RemoteAccessServer._handle_run_update:4033-4096`.
- Informational, not task terminal. Browser routes like error then renders notice. `src/kiss/agents/vscode/media/main.js:handleEvent:6502-6511`.

#### `talk`

- Fields: `type,language,text,emotion,talkId`; synthesized audio conditionally adds `audioB64,audioMime`; local endpoint fan-out can add `muted:true`. `talkId` is `uuid.uuid4().hex`; route identity is added by printer context. `src/kiss/agents/sorcar/sorcar_agent.py:SorcarAgent._build_tools/talk:1073-1110`; `src/kiss/server/web_server.py:WebPrinter._fanout_talk`.
- Intermediate tool event. Client ignores muted, empty, orphan, duplicate events; queues audio otherwise. `src/kiss/agents/vscode/media/main.js:handleEvent:6470-6489`.

#### `voiceWakeEvent`

- `ready`, `wake`, `transcribing`, `no_speech`: `type,event`. `speech`: adds `text,speaker,language`; latter two may be null. `src/kiss/server/voice_wake_control.py:parse_protocol_line:52-100`.
- Connection-local listener event. Client handler processes wake/transcription state and speech. `src/kiss/agents/vscode/media/main.js:handleEvent:6678-6692`.

#### `voiceWakeState`

- Fields: `type,listening`; optional `error`. Already-running start returns true. Spawn failure returns false/error. READY sends state true before `voiceWakeEvent ready`; process exit sends false, optional error. `src/kiss/server/voice_wake_control.py:VoiceWakeController.start:149-203`, `_pump_stdout:243-284`.
- Connection-local operation state. Client updates voice-wake UI. `src/kiss/agents/vscode/media/main.js:handleEvent:6693-6710`.

### WebSocket authentication events

These occur only on authenticated remote WebSocket transport; local UDS skips authentication.

#### `auth_ok`

- Fields: `type`. Sent after constant-time password comparison succeeds; connection remains open. `src/kiss/server/sorcar.py:ServerApi.authenticate:700-704`.

#### `auth_required`

- Fields: `type`. Sent after first failed auth attempt as retry prompt. `src/kiss/server/sorcar.py:ServerApi.authenticate:705-733`.

#### `auth_locked`

- Fields: `type,retry_after`, where retry is ceiling integer seconds. Sent then connection closes. May occur before receive, while awaiting credentials, or after failure triggers limiter. `src/kiss/server/sorcar.py:ServerApi.authenticate:661-695,717-729`.

Auth shim consumes all three before normal event forwarding. `src/kiss/server/web_server.py:_WS_SHIM_JS:3092-3250`.

### Direct and global endpoint events

These events originate in remote/local endpoint handlers rather than task-stream formatting. `welcome_suggestions` is not in this event catalog: `_send_welcome_info` explicitly no longer broadcasts it, although browser code still has a handler for that name. (`src/kiss/server/web_server.py`, `RemoteAccessServer._send_welcome_info`, lines 4817–4874; `src/kiss/agents/vscode/media/main.js`, `handleEvent`, lines 6603–6605.)

#### `voiceSpeech`

- Fields: `type,text,speaker,language`; `speaker` and `language` may be null, and failed or malformed transcription produces empty `text`. Direct response to requesting endpoint; terminal response to `voiceTranscribe`, not task-terminal. Browser voice code consumes it. (`src/kiss/server/web_server.py`, `RemoteAccessServer._handle_voice_transcribe`, lines 4165–4231; `src/kiss/agents/vscode/media/voice.js`, inbound `voiceSpeech` handling.)

#### `defaultModel`

- Fields: `type,model`. Direct, requester-only, terminal response to `getDefaultModel`. VS Code extension resolves its pending request from this event. (`src/kiss/server/web_server.py`, `RemoteAccessServer._handle_get_default_model`, lines 4233–4254; `src/kiss/agents/vscode/src/SorcarSidebarView.ts`, daemon-message handling.)

#### `kissConfig`

- Fields: `type,config`. Direct, requester-only, terminal response to UDS `readKissConfig`. VS Code extension resolves its pending config-read request. (`src/kiss/server/web_server.py`, `RemoteAccessServer._handle_read_kiss_config`, lines 4256–4278; `src/kiss/agents/vscode/src/SorcarSidebarView.ts`, daemon-message handling.)

#### `kissConfigSaved`

- Fields: `type,ok`; failure adds `error`. Direct, requester-only, terminal response to UDS `writeKissConfig`; exactly one reply occurs on invalid input, save failure, or success. VS Code extension resolves its pending config-write request. (`src/kiss/server/web_server.py`, `RemoteAccessServer._handle_write_kiss_config`, lines 4280–4324; `src/kiss/agents/vscode/src/SorcarSidebarView.ts`, daemon-message handling.)

#### `fileContent`

- Fields always include `type,path,name,tabId`; success adds `content`, failure adds `error`. Direct, requester-only, terminal response to nonempty WSS `openFile`; empty/invalid path produces no reply. Browser opens content or displays error. (`src/kiss/server/web_server.py`, `RemoteAccessServer._handle_open_file`, lines 4419–4490; `src/kiss/agents/vscode/media/main.js`, `handleEvent`, lines 6272–6284.)

#### `share_tasks`

- Fields: `type,tabId,chatId,tasks,truncated`; DB failure adds `error`. Each task has `task,task_id,events`. Direct, requester-only, terminal response to `shareChatTasks`; oldest transcripts may be omitted under reply cap and then `truncated` is true. Browser builds export or reports error. (`src/kiss/server/web_server.py`, `RemoteAccessServer._handle_share_chat_tasks`, lines 4573–4661; `src/kiss/agents/vscode/media/main.js`, `handleEvent`, lines 6288–6307.)

#### `share_done`

- Fields: `type,tabId,ok`; success adds `path`, failure adds `error`. Direct, requester-only, terminal response to `shareChat`. Browser shows result or link. (`src/kiss/server/web_server.py`, `RemoteAccessServer._handle_share_chat`, lines 4492–4571; `src/kiss/agents/vscode/media/main.js`, `handleEvent`, lines 6308–6344.)

#### `pathsExist`

- Fields: `type,results,workDir,tabId`; `results` maps each accepted input path to Boolean existence. Direct, requester-only, terminal response to WSS `checkPaths`. Browser updates file-link state. (`src/kiss/server/web_server.py`, `RemoteAccessServer._handle_check_paths`, lines 4663–4722; `src/kiss/agents/vscode/media/main.js`, `handleEvent`, lines 6285–6287.)

#### `activeTasksResponse`

- Fields: `type,count,tabs`; `tabs` is list of formatted active tab/task strings and `count` is list length. Direct, requester-only, terminal response to `activeTasksQuery`. Daemon-health client consumes it. (`src/kiss/server/web_server.py`, `RemoteAccessServer._handle_active_tasks_query`, lines 4724–4758; `src/kiss/agents/vscode/src/daemonHealth.js`, `queryActiveTasks`, lines 57–109.)

#### `remote_url`

- Fields: `type,url,tunnelActive`; optional `ntfyUrl` appears only when URL and ntfy topic are present. Global broadcast during welcome-info and tunnel-state changes; not task-terminal. Browser updates remote URL display. (`src/kiss/server/web_server.py`, `RemoteAccessServer._broadcast_remote_url`, lines 4760–4780, and `_send_welcome_info`, lines 4817–4874; `src/kiss/agents/vscode/media/main.js`, `handleEvent`, lines 6606–6608.)

#### `update_available`

- Fields: `type,available,latest,current`. `_broadcast_update_available` emits nothing until a latest version is cached; afterward it globally broadcasts current comparison state, including when `available` is false. Not task-terminal. Browser updates update state. (`src/kiss/server/web_server.py`, `RemoteAccessServer._broadcast_update_available`, lines 4782–4802; `src/kiss/agents/vscode/media/main.js`, `handleEvent`, lines 6609–6615.)

#### `focusInput`

- Fields: `type,tabId`. Direct to requester near end of `ready` handling, after initialization requests and welcome-info call; UI instruction, not task-terminal. Browser focuses addressed input. (`src/kiss/server/web_server.py`, `RemoteAccessServer._handle_ready`, lines 4972–5036; `src/kiss/agents/vscode/media/main.js`, `handleEvent`, focus-input branch.)

## Exact client terminal behavior

- Python `daemon_client.run` ignores malformed UTF-8/JSON, non-object values, and other-tab messages. `clear` captures chat ID. Any non-status event with `taskId` captures task ID. Latest `result` is retained. First `status running:true` arms completion; first later `status running:false` returns retained result. No other event type changes control flow. Thus Python API terminates on status transition, not `result` or task lifecycle event. `src/kiss/agents/sorcar/daemon_client.py:run:457-499`; `_to_task_result:116-143`.
- Browser treats `task_done`, `task_error`, `task_stopped`, and `task_interrupted` as task lifecycle terminal UI events. It separately uses `status running:false` for controls/running state. `src/kiss/agents/vscode/media/main.js:handleEvent:6345-6384,7070-7131`.
- VS Code host consumes native worktree/commit/config/tab state listed above, then forwards messages. Browser handles remaining event semantics. `src/kiss/agents/vscode/src/SorcarSidebarView.ts:_installClientListener:461-640`.

## Verified normal-run ordering

1. `setTaskText` sends synchronously before admission checks. `src/kiss/server/commands.py:_cmd_run:331-359`.
2. Accepted new run may send `tabs_state`, then sends `clear`, then starts worker. `src/kiss/server/commands.py:_cmd_run:434-468`.
3. Worker sends `status {running:true}`. `src/kiss/server/task_runner.py:_run_task:520-533`.
4. Worker sends early `system_prompt`, then early `prompt`. `src/kiss/server/task_runner.py:_broadcast_early_prompts:682-746`.
5. Agent/runtime stream events occur.
6. Result signal occurs; runner persists metrics/lifecycle outcome.
7. `tasks_updated` occurs.
8. Optional `worktree_result` or `main_tree_done` occurs.
9. One live lifecycle event occurs when inner lifecycle was reached: `task_done`, `task_error`, `task_stopped`, or `task_interrupted`.
10. Outer `finally` sends launcher `status {running:false}`, optional restore `modelPick`, then viewer end states. `src/kiss/server/task_runner.py:_run_task:442-680`, `_run_task_inner:1284-1438`.
11. Optional asynchronous `followup_suggestion` may arrive after lifecycle terminal; source does not synchronize it against outer end status. `src/kiss/server/server.py:VSCodeServer._generate_followup_async:1714-1769`.

Exception: setup failures caught by outer runner send failure `result`, then `status running:false`; they do not traverse inner lifecycle-event emission. `src/kiss/server/task_runner.py:_run_task:537-604`.

## Names accepted by client but not core daemon events

Shared browser handler also accepts extension-host/local UI bridge messages: `daemonStatus`, `workspaceWorkDir`, `triggerStop`, `appendToInput`, `insertAndSubmit`, `focusInput`, `measureSize`, `droppedPaths`. `daemonStatus` is generated by host socket lifecycle, not daemon protocol. Remaining origins depend on web/host bridge path noted above. `src/kiss/agents/vscode/media/main.js:handleEvent:6218-6252,6877-6922,6948-6971`.

`clearChat` is a host/local UI control: browser focuses existing empty welcome tab when possible, otherwise creates new tab. It is not daemon wire event. `src/kiss/agents/vscode/media/main.js:handleEvent:6570-6580`.

## Identities and persistent/runtime state

Source revision inspected: `74af9b738adeef91448790015cf8f416da71566c`.

Scope: source-backed facts only. Paths below are relative to `../../kiss_ai`.

## Identity map

| Name | Source-backed meaning | Persistence and relationships |
|---|---|---|
| **task** | One invocation persisted as one `task_history` row. Canonical `task_history.id` is an independently generated lowercase 32-hex UUID (`uuid.uuid4().hex`). | Row stores task text, `chat_id`, result, model/work-dir/settings/metrics, and optional `parent_task_id`. Transcript events reference task ID. Sources: `src/kiss/agents/sorcar/persistence.py`: `_init_tables`, `_add_task`, `is_task_history_id` (around lines 498–675, 1116–1193). |
| **chat** | Multi-turn conversation grouping. `ChatSorcarAgent._chat_id == ""` means no chat allocated yet; first run allocates a UUID. Each task row stores its chat ID. Follow-up context is loaded from top-level task rows sharing that ID. | Chat is not a separate DB row/table. It exists as repeated `task_history.chat_id` values and agent/tab bindings. Chat ID is independent from task ID, though both use UUID4 hex strings. Sources: `src/kiss/agents/sorcar/chat_sorcar_agent.py`: `ChatSorcarAgent.__init__`, `chat_id`, `new_chat`, `resume_chat_by_id`, `run` (lines 140–223, 459–513); `src/kiss/agents/sorcar/persistence.py`: `_add_task`, `_allocate_chat_id`, `_load_chat_context` (lines 1116–1210, 2907–2941). |
| **session** | Persistence replay helpers use “session” for a dict containing one task plus its events, chat ID, and metadata. History wire response calls each top-level task row a `session`, setting `session.id = chat_id` and `session.task_id = task_history.id`. | Persisted schema declares task and event rows; replay/session builders cited here derive session dictionaries from those rows. Sources: `src/kiss/agents/sorcar/persistence.py`: `_events_session_dict`, `_load_latest_chat_events_by_chat_id`, `_load_chat_events_by_task_id` (lines 2605–2718); `src/kiss/server/server.py`: `VSCodeServer._get_history` (around lines 785–889). |
| **tab** | Frontend routing/view identity, separate from chat and task. Top-level tabs live in daemon-canonical ordered `TabRegistry`; each record has `tabId`, `chatId`, `title`, `workDir`, `scopeWorkDir`, and `taskId`. | `TabRegistry` persists to `KISS_HOME/tabs.json`. At most one top-level tab may bind a given nonempty chat ID; newest bind displaces prior binding. `taskId` pins a resumed tab to one historical task; empty means latest task in chat. Tab ID need not equal chat/task ID. Sources: `src/kiss/server/tab_registry.py`: module contract, `_load`, `bound_tabs`, `open_tab`, `update_tab` (lines 1–40, 84–126, 173–197, 223–258, 278–368). |
| **live agent state** | `AgentState` represents one running/retained top-level or sub-agent task. Process-global `agent_states` maps task key to state. Before persistence, key may be client-minted/provisional; `rekey` replaces it with persisted task ID. | State explicitly carries `task_id`, `chat_id`, `tab_id`, `conn_id`, optional `parent_task_id`, agent object, threads/stop/ask queues, worktree flags, and lifecycle flags. Closing connection alone does not dispose tab state. Sources: `src/kiss/server/agent_state.py`: module contract, `AgentState`, `register`, `rekey` (lines 1–18, 35–146, 160–200). |
| **sub-agent** | Independent `ChatSorcarAgent` spawned by `run_tasks_parallel`, with own task row/task ID and synthetic tab ID. When parent has nonempty chat ID, child resumes that chat; otherwise child allocates its own chat ID during persistence. | Every child records `parent_task_id`: persisted parent row ID when available, otherwise shared UUID-shaped synthetic ID naming no row. Child rows are excluded from top-level history/chat context. Sources: `src/kiss/agents/sorcar/sorcar_agent.py`: `run_tasks_parallel` (lines 1740–2001); `src/kiss/agents/sorcar/chat_sorcar_agent.py`: `_build_extra_payload`, sub-agent `new_tab` emission (lines 280–313, 532–550); `src/kiss/agents/sorcar/persistence.py`: `_HISTORY_NOT_SUBAGENT`, `_load_chat_context`, `_load_subagent_rows_by_parent_task_id` (lines 507–526, 2769–2820, 2907–2941). |
| **worktree** | Git isolation resource owned in memory by `WorktreeSorcarAgent` (`self._wt`, `_wt_dir`, `_wt_branch`, pending/review flags). One run may request worktree, but setup can fall back to direct execution. | `task_history` stores Boolean `is_worktree` and normalized original work dir; live events expose actual worktree path/branch. Pending worktree agent can outlive task completion and is retained in tab state until merge/discard/release. Sources: `src/kiss/agents/sorcar/worktree_sorcar_agent.py`: `_try_setup_worktree`, `run`, `merge`, `new_chat` (around lines 918–1000, 1085–1140, 1320–1420); `src/kiss/agents/sorcar/chat_sorcar_agent.py`: `_dir_inside_worktree`, `_build_extra_payload` (lines 42–72, 280–313); `src/kiss/server/agent_state.py`: `AgentState` contract (lines 38–52). |
| **workspace** | Runtime workspace values are filesystem directory strings: daemon fallback `VSCodeServer.work_dir`, per-connection `workDir`, per-command/per-tab `workDir`, and tab visibility `scopeWorkDir`. | VS Code sends current workspace folder as `setWorkDir`; connection dispatcher stamps each connection's work dir on commands. Tab visibility is path-scoped locally. History workspace filtering is optional UI filter; backend history remains global. Hidden tabs remain intact. Sources: `src/kiss/server/server.py:VSCodeServer.__init__`; `src/kiss/server/commands.py:_cmd_set_work_dir`; `src/kiss/agents/vscode/src/SorcarSidebarView.ts:_getClient`; `src/kiss/agents/vscode/media/main.js:tabMatchesWorkspace`, `applyHistoryFilterVisibility`. |

## Exact relations

### Chat and task

- One chat can contain multiple top-level tasks: rows share `chat_id`; `_load_chat_context` orders them by `(timestamp, rowid)` and excludes rows with nonempty `parent_task_id`. Source: `src/kiss/agents/sorcar/persistence.py:_load_chat_context` (lines 2907–2941).
- One task row belongs to one stored chat through `task_history.chat_id`. Source: `src/kiss/agents/sorcar/persistence.py:_init_tables` (lines 638–675).
- New task and chat IDs are independently allocated. `_add_task` allocates chat only when supplied `chat_id == ""`, then separately allocates task ID. Source: `src/kiss/agents/sorcar/persistence.py:_add_task` (lines 1116–1193).
- `resume_from_task_id` is distinct from chat resume: next prompt loads that task’s `parent_task_id` chain once, then later prompts return to whole-chat context. Sources: `src/kiss/agents/sorcar/chat_sorcar_agent.py:resume_from_task_id`, `build_chat_prompt` (lines 224–275); `src/kiss/agents/sorcar/persistence.py:_load_task_chain_context` (lines 2943–2986).

### Tab, chat, and task

- Tab is routing/view key. `VSCodeServer._replay_session(chat_id, tab_id, task_id)` does not change tab ID. Exact task ID loads that row; absent/failed exact load falls back to latest top-level task in chat. Source: `src/kiss/server/server.py:_replay_session` (around lines 1128–1370).
- Top-level registry binding is one chat to at most one tab. Registry retains optional historical `taskId`; ready replay uses it to avoid silently switching pinned tab to latest task. Source: `src/kiss/server/tab_registry.py` module contract and `bound_tabs` (lines 1–40, 173–197).
- On new run, server chooses chat in order: previous tab state’s chat, command `chatId`, resumed `_tab_chat_views` binding, fresh UUID. It registers a provisional state key, updates tab registry, clears historical `taskId`, and broadcasts `clear` with chat ID before worker starts. Source: `src/kiss/server/commands.py:_cmd_run` (around lines 360–471).
- Multiple tabs can view one running task through printer subscriptions, despite canonical registry’s one-top-level-tab-per-chat binding. Replay calls `_reattach_running_chat`; events fan out stamped to viewer tab IDs. Source: `src/kiss/server/server.py:_replay_session`, `_reattach_running_chat` and `src/kiss/server/task_runner.py:_on_run_task_id_allocated`.
- Closing top-level tab does not stop active task. Server marks state `frontend_closed` and disposes after task/merge ceases. Source: `src/kiss/server/server.py:_drop_tab_state`, `_dispose_if_closed` (around lines 966–1090).

### Sub-agent relations

- Every child gets own `ChatSorcarAgent`, own task ID, own task events, and synthetic tab ID `task-{routing_key}__sub_{idx}` during live fan-out. Source: `src/kiss/agents/sorcar/sorcar_agent.py:run_tasks_parallel` (around lines 1870–1925).
- When parent chat ID is nonempty, child receives it via `resume_chat_by_id(chat_id)`; otherwise child allocates own chat ID during persistence. Child persists `parent_task_id` in typed column via `_subagent_info` → `_build_extra_payload` → `_add_task`. Sources: `src/kiss/agents/sorcar/sorcar_agent.py:run_tasks_parallel`; `src/kiss/agents/sorcar/chat_sorcar_agent.py:_build_extra_payload`; `src/kiss/agents/sorcar/persistence.py:_add_task`.
- `parent_task_id` can be synthetic valid-shaped UUID when fan-out parent has no persisted history row. Source explicitly says it then names no row, hiding children from root list. Source: `src/kiss/agents/sorcar/sorcar_agent.py:run_tasks_parallel` around `fanout_parent_id` (roughly lines 1865–1892).
- Sub-agent tabs are not in `TabRegistry`; clients derive them from `openSubagentTab` and replay. Persisted replay regenerates deterministic ID `{parent_tab_id}__sub_{sub_task_id}`. Sources: `src/kiss/server/tab_registry.py` module contract (lines 21–25); `src/kiss/server/server.py:_open_persisted_subagent_tabs` (around lines 1450–1535).
- Nested ancestry is task-to-parent-task, not tab ancestry. `parent_tab_id` is frontend routing metadata and is not stored in `task_history`; persisted child tabs reconstruct parent tab from replay context. Sources: `src/kiss/agents/sorcar/sorcar_agent.py:run_tasks_parallel`; `src/kiss/agents/sorcar/persistence.py` schema; `src/kiss/server/server.py:_resolve_parent_tab_id_for_sub`.

## History and replay state

- Persistent DB is `KISS_HOME/sorcar.db`, WAL mode, with `task_history`, `events`, `model_usage`, `file_usage`, and `frequent_tasks`. Source: `src/kiss/agents/sorcar/persistence.py` module docstring, `_DB_PATH`, `_init_tables` (lines 1–16, 147–153, 638 onward).
- Events use integer DB row ID plus `(task_id, seq, event_json, timestamp)`; replay orders by `seq`. Source: `src/kiss/agents/sorcar/persistence.py:_init_tables`, `_fetch_events_for_task_id` (around lines 670–676, 2575–2603).
- Main history list/search excludes sub-agent rows and returns top-level task rows newest first. Source: `src/kiss/agents/sorcar/persistence.py:_load_history`, `_search_history` (lines 1212–1260, 1290–1325).
- `_get_history` appends one `session` per loaded top-level task row. Multiple rows sharing `chat_id` produce entries sharing `id` and carrying distinct `task_id` values. Source: `src/kiss/server/server.py:_get_history` loop over `_load_history` entries (around lines 785–889).
- Chat-ID replay returns latest non-sub-agent task only. Task-ID replay returns exact row, including a sub-agent row. Whole-chat export separately loads all top-level tasks. Source: `src/kiss/agents/sorcar/persistence.py:_load_latest_chat_events_by_chat_id`, `_load_chat_events_by_task_id`, `_load_all_chat_events_by_chat_id` (lines 2658–2767).
- Replay restores persisted sub-agent tabs by querying rows whose `parent_task_id` equals replayed parent task ID. Source: `src/kiss/agents/sorcar/persistence.py:_load_subagent_rows_by_parent_task_id`; `src/kiss/server/server.py:_open_persisted_subagent_tabs`.
- Tab registry survives daemon restart; live agent-state registry is process memory. Startup reloads tab/chat bindings. Abandoned task rows begin with `Agent Failed Abruptly` and orphan sweep can rewrite dead-process rows. Sources: `src/kiss/server/tab_registry.py` module contract; `src/kiss/server/server.py:VSCodeServer.__init__`, `_run_orphan_sweep`; `src/kiss/agents/sorcar/persistence.py:_add_task`, `_recover_orphaned_tasks`.

## Workspace/work-dir semantics

- Backend identity is path string, not named workspace. `VSCodeServer.work_dir` initializes from `KISS_WORKDIR` or process cwd. Source: `src/kiss/server/server.py:VSCodeServer.__init__`.
- `setWorkDir` changes daemon fallback and cache state. Server comment states each connection has own work dir stamped by `ServerApi.dispatch`, preventing two windows from resolving against one another’s folder. Source: `src/kiss/server/commands.py:_cmd_set_work_dir`; `src/kiss/server/sorcar.py:ServerApi.dispatch`.
- Run uses `cmd.workDir` or server fallback. Tab registry pins effective `workDir`. A separate `scopeWorkDir` exists for tasks executing in scratch directories but shown under calling workspace. Sources: `src/kiss/server/task_runner.py:_run_task_inner` around line 833; `src/kiss/server/commands.py:_cmd_run`; `src/kiss/server/tab_registry.py:update_tab` documentation.
- History stores `work_dir` per task. Worktree runs normalize it with `strip_worktree_suffix`, preserving user-visible original workspace path rather than transient worktree path. Sources: `src/kiss/agents/sorcar/chat_sorcar_agent.py:_build_extra_payload`, `_task_settings_payload`; `src/kiss/agents/sorcar/git_worktree.py:strip_worktree_suffix`.
- VS Code workspace scoping is client-local rendering. Hidden tabs continue receiving broadcasts and retain drafts/transcripts/sub-agent state. Source: `src/kiss/agents/vscode/media/main.js:isTabHidden`, `applyWorkspaceScope` (around lines 2144–2190).
- No DB foreign key or workspace table associates history with workspace. Backend returns global top-level history. Existing frontend optionally filters stored `work_dir`; filter keeps running rows, empty paths, exact paths, and descendants. Sources: `src/kiss/agents/sorcar/persistence.py:_init_tables`, `_load_history`, `_search_history`; `src/kiss/agents/vscode/media/main.js:applyHistoryFilterVisibility`.

## Model state

- Catalog `MODEL_INFO` loads bundled `src/kiss/core/models/MODEL_INFO.json`, then merges `~/.kiss/MY_MODELS.json`; matching user keys override, new keys add. Source: `src/kiss/core/models/model_info.py:_load_model_info` (lines 293–305).
- `get_available_models` returns catalog models that support generation and whose routed provider credential/executable is available. Server picker further restricts to `ranked_function_calling_models`, then sends name, input/output pricing, usage count, and vendor. Sources: `src/kiss/core/models/model_info.py:get_available_models`, `_configured_providers` (lines 881–929); `src/kiss/server/autocomplete.py:ranked_function_calling_models`; `src/kiss/server/server.py:_get_models` (around lines 674–733).
- Optional custom endpoint entry is constructed outside `MODEL_INFO` and prepended to wire list. `get_custom_model_entry` names it `custom/<last endpoint path segment>` and includes zero prices/usage, vendor `Custom`, `endpoint`, plaintext `api_key`, and parsed `extra_headers`. Source: `src/kiss/core/vscode_config.py:get_custom_model_entry` (lines 466–490); insertion: `src/kiss/server/server.py:_get_models` (lines 671–722).
- `_tab_models` is in-memory per-tab selection. `_default_model` initializes from `_load_last_model()`, then `KISS_MODEL`, then `get_default_model()`. `selectModel` updates tab selection and daemon default and records usage. Sources: `src/kiss/server/server.py:VSCodeServer.__init__`; `src/kiss/server/commands.py:_cmd_select_model`; persistence model-usage schema/comment.
- Agent can switch model during run (`set_model`), but server restores user’s tab pick when run ends; agent switch does not define next-run user selection. Source: `src/kiss/server/task_runner.py:_restore_user_model_pick`.
- Task row persists resolved launch/final model metadata. Source: `src/kiss/agents/sorcar/chat_sorcar_agent.py:run`, `_build_extra_payload` (around lines 459–667).

## Worktree state and ownership

- Worktree is attempted only when requested and Git prerequisites permit. Non-repo, no commits, detached HEAD, setup failures, or explicit `use_worktree=False` cause direct execution. Source: `src/kiss/agents/sorcar/worktree_sorcar_agent.py:run`, `_try_setup_worktree` (around lines 1085–1140, 1320–1410).
- Worktree branch names and directories come from `worktree_pool.new_task_branch(repo)` and `<repo>/.kiss-worktrees/<branch-with-slash-replaced>`. Branch is not derived from chat ID. Sources: `src/kiss/agents/sorcar/worktree_sorcar_agent.py:_acquire_task_worktree` (around lines 1010–1083); `src/kiss/agents/sorcar/git_worktree.py:_WORKTREE_SUBDIR` (line 311).
- Successful setup emits `worktree_created` with actual `worktreeDir`, effective `worktreeWorkDir`, and branch. Task then runs with effective worktree path. Source: `src/kiss/agents/sorcar/worktree_sorcar_agent.py:run` (around lines 1390–1408).
- Worktree agent can remain attached to tab state after task ends while `_wt_pending` is true, enabling later merge/discard. New task carries previous agent into new state; new worktree setup retires previous worktree first. Sources: `src/kiss/server/task_runner.py:_run_task` cleanup; `src/kiss/server/commands.py:_cmd_run`; `src/kiss/agents/sorcar/worktree_sorcar_agent.py:_retire_previous_worktree`.
- `new_chat` retires pending worktree before clearing chat ID. Closing idle tab releases/preserves pending worktree; closing busy tab defers teardown. Sources: `src/kiss/agents/sorcar/worktree_sorcar_agent.py:new_chat`; `src/kiss/server/server.py:_teardown_tab_resources`, `_drop_tab_state`.
- Persisted task history records `is_worktree` and normalized work directory, but not worktree branch, directory, or pending ownership. A worktree action requires live `AgentState` whose agent has `_wt_pending`; replayed transcript events do not reconstruct that state. Sources: `src/kiss/server/merge_flow.py:_handle_worktree_action:1329-1382`; `src/kiss/agents/sorcar/persistence.py:_init_tables`; `src/kiss/agents/sorcar/chat_sorcar_agent.py:_build_extra_payload`.

## Compact cardinality summary

- Workspace path → zero or more visible history rows/tabs by client-side path matching; no backend workspace entity.
- Chat → zero or more top-level task rows; may also contain sub-agent task rows.
- Top-level task → exactly one stored chat ID; zero or more direct child rows via `parent_task_id`.
- Top-level canonical tab → zero or one chat binding and zero or one pinned historical task ID.
- Nonempty chat binding → at most one canonical top-level tab.
- Running task → one `AgentState`; may have multiple subscribed viewer tabs.
- Sub-agent task → one own task row and one parent task ID. It inherits nonempty parent chat ID; otherwise its `ChatSorcarAgent` allocates chat ID. Live and replay UI use synthetic tabs; no canonical tab-registry row.
- Worktree → zero or one current/pending worktree held by a `WorktreeSorcarAgent` instance; retained through tab state as lifecycle requires, with no DB identity.

## Long-running task lifecycle

Source inspected: KISS Sorcar commit `74af9b738adeef91448790015cf8f416da71566c`.

Citation format uses repository-relative source path plus symbol and inspected line range. Facts below come from source, not README.

## Streaming and terminal ordering

- Agent output streams as discrete JSON events. Model tokens become `text_delta` or `thinking_delta`; thinking boundaries emit `thinking_start` / `thinking_end`; tool transitions emit `text_end`, `tool_call`, and `tool_result`; bash output is buffered and flushed at most about every 100 ms as `system_output`. Stop checks run before ordinary printer output and token output. (`src/kiss/server/json_printer.py`, `JsonPrinter.print`, `token_callback`, `thinking_callback`, `_check_stop`, lines 1313–1510.)
- Events acquire thread-local `taskId`, enter a task-keyed in-memory recording, and eligible display events are asynchronously persisted. Tab-stamped transient events generally bypass recording; task-stamped `prompt` and `result` are special-cased for persistence without `tabId`. (`src/kiss/server/json_printer.py`, `JsonPrinter.broadcast`, `_record_event`, `_persist_event`, lines 1194–1280 and 785–823.)
- A normal top-level run broadcasts `status(running=true)`, streams intermediate events, emits/persists result and task-end data, then broadcasts a terminal lifecycle event (`task_done`, `task_error`, `task_stopped`, or `task_interrupted`). Outer `finally` always emits `status(running=false)`, including early setup failures. Viewer tabs receive their own terminal status copy. (`src/kiss/server/task_runner.py`, `_run_task`, `_run_task_inner`, `_broadcast_status_end_to_viewers`, lines 430–630 and 830–1714.)
- `result` is not the sole lifecycle terminator for UI state; existing code lowers running state on `status(running=false)`. Worktree/main-tree follow-up events can occur around task teardown, and asynchronous follow-up suggestions can occur after task cleanup. (`src/kiss/server/task_runner.py`, `_run_task` and `_run_task_inner`, lines 430–630 and 1380–1580.)

## Stop and interruption

- `stop` has no catalog-required fields, but routing needs nonempty `tabId`. Empty `tabId` produces no acknowledgment. Nonempty but unroutable `tabId` produces `stop_ack {accepted:false}`. Routed target produces `stop_ack {accepted:true}` before cooperative stop is signaled. (`src/kiss/server/commands.py`, `_cmd_stop`, lines 479–481; `src/kiss/server/task_runner.py`, `_stop_task`, `_find_viewer_task_states`, lines 1716–1850.)
- Stop first sets task's cooperative `threading.Event`. If worker remains alive, watchdog waits one second, injects asynchronous `KeyboardInterrupt` using `PyThreadState_SetAsyncExc`, then may retry after five seconds. Ownership guard prevents injection into reused thread after original task ended. (`src/kiss/server/task_runner.py`, `_stop_task`, `_force_stop_thread`, lines 1716–1900.)
- Model/printer paths poll same thread-bound stop event. Parent and parallel child stop behavior is linked: each child has own `_SubagentStopEvent`, but its `is_set()` and `wait()` also observe ancestors. Stopping one child need not stop siblings; stopping parent propagates through child event chains. (`src/kiss/server/json_printer.py`, `_PrinterThreadLocal.stop_event`, `_check_stop`, lines 253–275 and 1313–1317; `src/kiss/agents/sorcar/sorcar_agent.py`, `_SubagentStopEvent`, lines 255–340.)
- User stop persists result `Task stopped by user` and lifecycle event `task_stopped`. Graceful shutdown sets `interrupted_by_shutdown` first, yielding `Task interrupted by server restart/shutdown` and `task_interrupted`. (`src/kiss/server/task_runner.py`, `_cancel_outcome`, lines 1608–1660.)

## Live steering

- `appendUserMessage` validates nonblank string, then routes to tab-owned active state or first input-accepting running state subscribed by viewer tab. No live target means silent drop except debug log. Accepted text appends under shared state lock and is immediately echoed as `prompt`. (`src/kiss/server/commands.py`, `_cmd_append_user_message`, `_echo_injected_prompt`, lines 708–815.)
- Sending another `run` while tab already has installed worker does **not** start a second worker: prompt is appended to same pending-message queue. This includes worker startup window before `is_task_active` is raised. (`src/kiss/server/commands.py`, `_cmd_run`, lines 330–478.)
- Agent drains queued messages only at top of model step and inserts each as user conversation text: `User says: ... Take the message into account and finish your task.` Queue drain is once-only. A tool guard rejects `finish` if steering arrived after last drain, forcing another step. (`src/kiss/agents/sorcar/sorcar_agent.py`, `_drain_pending_user_messages`, `_block_finish_when_user_message_pending`, lines 1622–1705; `src/kiss/server/json_printer.py`, `drain_pending_user_messages`, `has_pending_user_messages`, lines 536–583.)
- Steering enters the conversation at the next pre-step drain. The append path does not mutate an in-flight model request.

## Ask-user / answer

- `ask_user_question` stores question on task state and broadcasts `askUser` while holding shared state lock, then blocks on task's max-size-one answer queue. Stop watcher inserts sentinel and raises `KeyboardInterrupt` if stopped while waiting. (`src/kiss/server/task_runner.py`, `_ask_user_question`, `_await_user_response`, lines 1901–2025.)
- `userAnswer` resolves exact tab-owned queue first, otherwise task state reached through subscriber mapping. Under lock it clears pending question, drains stale answer, and nonblocking-inserts newest answer. It emits `askUserDone` to current task subscribers, falling back to answering tab when task ID or subscriber set is empty. Missing queue causes silent drop except debug log. (`src/kiss/server/commands.py`, `_cmd_user_answer`, `_resolve_user_answer_state`, `_user_answer_clear_tabs`, lines 596–711.)
- Resume/replay calls `_emit_pending_ask` after transcript replay. It re-emits still-pending question under same lock used by answer path, preventing `askUser` from being ordered after `askUserDone`. (`src/kiss/server/server.py`, `_emit_pending_ask`, lines 1388–1434.)

## Resume and live reattachment

- `resumeSession` accepts `chatId`, optional `taskId`, and `tabId`. With `taskId`, replay first attempts exact row; failed lookup falls back to latest top-level task in `chatId`. Without `taskId`, it loads latest top-level task in chat. It never changes toolbar-owned worktree/parallel/auto-commit/model toggles. (`src/kiss/server/commands.py`, `_cmd_resume_session`, lines 817–829; `src/kiss/server/server.py`, `_replay_session`, lines 1161–1386.)
- Running task reattachment subscribes new tab without stealing source ownership. Exact task ID is preferred; chat fallback excludes subagents. Running replay emits `status(running=true)`, `task_events`, pending ask, and pending worktree handling. (`src/kiss/server/server.py`, `_replay_session`, `_reattach_running_chat`, lines 1161–1386 and 1627 onward.)
- While task runs, in-memory recording is authoritative because DB event writer can lag. Server snapshots recording after subscribing, then live fan-out continues. Source explicitly acknowledges micro-window where event can appear in both snapshot and live fan-out, producing duplicate rendering. (`src/kiss/server/server.py`, `_replay_session`, lines 1250–1280; `src/kiss/server/json_printer.py`, `peek_recording_for_task`, lines 1144–1180.)
- Shared tab registry persists tab/chat/task bindings. `ready_tab_sync` merges legacy restored tabs only if registry empty, broadcasts canonical `tabs_state`, and returns bindings for replay. (`src/kiss/server/server.py`, `ready_tab_sync`, lines 517–548.)

## Client disconnect and reconnect

- Connection loss does not stop task. UDS cleanup stops connection-owned voice wake, unregisters local UDS tab bookkeeping, drops per-connection autocomplete state, unbinds endpoint routing, removes writer, and closes stream; task ownership is task/tab based, not socket-lifetime based. Explicit `closeTab` marks frontend closed and defers state disposal while task/merge remains busy. (`src/kiss/server/web_server.py`, `_uds_handler`, lines 3766–3843; `src/kiss/server/server.py`, `drop_connection_state`, `_close_tab`, `_dispose_if_closed`.)
- VS Code `AgentClient` reconnects with exponential capped jitter: base 500 ms, max 15 s; connection must survive 5 s before retry counter resets. Partial UTF-8 and line buffer are connection-scoped and discarded on close. (`src/kiss/agents/vscode/src/AgentClient.ts`, constants, `connect`, `_scheduleReconnect`, lines 12–28 and 72–219.)
- Commands sent while disconnected are queued in memory, capped at 256, and replayed on next connection only if younger than 10 seconds. Expired/overflow commands emit local `commandDropped`, allowing UI rollback. Queue is not persisted across extension process death. (`src/kiss/agents/vscode/src/AgentClient.ts`, `sendCommand`, `_announceDropped`, lines 130–172.)
- On each raw socket connection, extension sends `setWorkDir` and, when view exists, `getModels`, `getInputHistory`, and `getConfig`; raw reconnect does not send `ready`. Extension forwards `ready` only when webview sends its separate `ready` message. Daemon handles that command by returning canonical tab state and replaying bound chats/tasks. (`src/kiss/agents/vscode/src/SorcarSidebarView.ts`, `_getClient`, lines 373–398, and webview-message `ready` case, lines 975–994; `src/kiss/server/web_server.py`, `_handle_ready`, lines 4972–5036.)

## Daemon restart and hard failure

- Graceful SIGTERM/SIGHUP shutdown stops active worker threads before event loop exit, marks shutdown interruption, preemptively persists in-flight result labels, sets stop events, injects `KeyboardInterrupt` when needed, and joins within aggregate 12-second budget. Interactive worktree merges are not interrupted; shutdown waits up to 30 seconds because interruption mid-git rewrite is unsafe. (`src/kiss/server/web_server.py`, `_shutdown_on_sigterm`, `_stop_active_agent_tasks`, `_await_active_merges`, lines 6244–6505.)
- If process is killed before cleanup, history row may retain `Agent Failed Abruptly`. New server asynchronously recovers pre-boot orphan rows to `Task terminated unexpectedly (process killed)`, exempting task states still live in same process. (`src/kiss/server/server.py`, `VSCodeServer.__init__`, `_run_orphan_sweep`, lines 327–435.)
- Replacement daemon process has no live agent, pending ask, steering queue, subscriber map, or pending worktree object from old process. `TabRegistry` data and DB history survive, so replay can reconstruct persisted transcript state, but cannot continue old execution or restore pending worktree ownership. Worktree action requires live state/agent with `_wt_pending`. (`src/kiss/server/server.py`, `VSCodeServer.__init__`, lines 327–390; `src/kiss/server/merge_flow.py`, `_handle_worktree_action`, lines 1329–1382.)

## Duplicate submission and race assessment

- Protocol has no server-side idempotency key or seen-submission registry for `run`. Client-provided `taskId` is only echoed on start/end `status` so frontend can reject stale status; persisted task row ID is allocated later and replaces state key. Replaying same stale `run` after original task ended can start another task. (`src/kiss/server/task_runner.py`, `_client_task_id_of`, lines 116–138; `_run_task`, lines 430–590; `src/kiss/server/commands.py`, `_cmd_run`, lines 330–478.)
- VS Code keeps queued commands for up to 10 seconds and writes surviving commands to the next connected socket. Source comments identify stale `run` delivery to a replacement daemon as the reason for the TTL. (`src/kiss/agents/vscode/src/AgentClient.ts`, `PENDING_SEND_TTL_MS`, connect flush, lines 16–23 and 86–105.)
- If duplicate `run` reaches same tab while original worker exists, daemon converts it to steering instead of second task. If original completed before duplicate dispatch, new run starts. Lock serializes state test/install, preventing two concurrent dispatch handlers from both installing workers on same tab. (`src/kiss/server/commands.py`, `_cmd_run`, lines 362–445.)
- Running replay has a duplicate-delivery window: subscription plus recording snapshot can duplicate an event. Backend provides no per-event wire sequence or resume cursor in this replay path. (`src/kiss/server/server.py`, `_replay_session`, lines 1250–1280.)

## Model switching

- `selectModel` stores model per tab and also updates daemon-wide default to nonempty choice; malformed/empty behavior falls back to existing tab/default model. Model usage is recorded and `last_model` preference persisted. Existing running task already captured launch model, so picker selection affects later run, not current executor. (`src/kiss/server/commands.py`, `_cmd_select_model`, lines 487–507; `src/kiss/agents/sorcar/persistence.py`, `_record_model_usage`, `_save_last_model`; `src/kiss/server/task_runner.py`, `_run_task_inner`, lines 830–875.)
- Agent tool `set_model` replaces live model while preserving conversation, usage metadata, callbacks, relevant provider config/API key, and Gemini thought signatures. It broadcasts transient `modelPick(source="agent")` to all task viewers. On task/subagent completion picker restores user's selected launch/default model with `source="restore"`; switch does not persist user's preference. (`src/kiss/agents/sorcar/sorcar_agent.py`, nested `set_model`, `_show_model_in_picker`, lines 1208–1345; `src/kiss/server/json_printer.py`, `broadcast_agent_model_pick`, `restore_model_pick`, lines 692–782; `src/kiss/server/task_runner.py`, `_restore_user_model_pick`, lines 590–620.)

## Subagents

- Each parallel subagent allocates own task row, live `AgentState`, worker thread, and chained stop event. Subagent metadata is stored in `extra`; canonical ancestry is also stored in `task_history.parent_task_id`. Child inherits parent chat only when parent chat ID is nonempty. Non-server-owned subagent state unregisters on completion. (`src/kiss/server/json_printer.py`, `agent_task_allocated`, `agent_task_finished`, lines 458–535; `src/kiss/agents/sorcar/sorcar_agent.py`, `run_tasks_parallel`, lines 1740–2001.)
- Live subagent output uses ordinary task-stamped event fan-out. Replay uses `openSubagentTab`, then child `task_events`; completion uses `subagentDone`. Deterministic persisted sub-tab IDs avoid duplicate tabs. Race check emits `subagentDone` if child finishes between replay and live-state check. (`src/kiss/server/server.py`, `_replay_session`, `_open_persisted_subagent_tabs`, lines 1325–1385 and 1504–1588; `src/kiss/agents/sorcar/sorcar_agent.py`, `_broadcast_subagent_done`, lines 224–253.)
- Parent stop is polled while waiting for futures. After 15-second child stop grace, parent can abandon wedged child and unwind; Python cannot kill child thread, so agent retains abandoned child record to avoid deleting worktree it still uses and to account later spend. (`src/kiss/agents/sorcar/sorcar_agent.py`, `_await_subagents`, `_AbandonedSubagent`, `_register_abandoned`, lines 340–525.)

## Worktree completion

- Successful worktree task with auto-commit enabled chooses merge when changed files exist, otherwise discard; emits `worktree_result`. Failed/stopped/interrupted task sets pending-review and is presented through `worktree_done` rather than silently merged. Auto-commit off also presents manual action. (`src/kiss/server/task_runner.py`, `_run_task_inner` finalization, lines 1380–1535; `src/kiss/server/merge_flow.py`, `_emit_pending_worktree`, `_finalize_pending_worktree`, lines 806–976.)
- `worktree_done` includes worktree paths and changed files for Merge/Discard UI. `worktreeAction` returns `worktree_result`. Busy guards refuse actions while task writes worktree or another conflicting non-worktree task occupies relevant tree. Merge/discard ownership is claimed under shared lock to prevent concurrent resume/action races. (`src/kiss/server/merge_flow.py`, `_present_pending_worktree`, `_check_worktree_busy`, `_handle_worktree_action`, lines 977–1055 and 1254 onward; `src/kiss/server/commands.py`, `_cmd_worktree_action`, lines 1114–1127.)
- Pending worktree is transient agent-owned state. Session load can re-present/finalize only while state/agent survives. Explicit action handler requires live tab `AgentState`, worktree-enabled state, live agent, and `_wt_pending`; despite its docstring mentioning restoration, current body implements no Git reconstruction fallback after process restart. (`src/kiss/server/merge_flow.py`, `_emit_pending_worktree`, lines 806–844; `_handle_worktree_action`, lines 1329–1382.)
