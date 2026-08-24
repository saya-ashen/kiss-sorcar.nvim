# Open questions and upstream concerns

Source inspected: [KISS Sorcar commit `74af9b7`](https://github.com/ksenxx/kiss_ai/commit/74af9b738adeef91448790015cf8f416da71566c).

- **FACT**: directly observed in source.
- **INFERENCE**: conclusion from cited source locations.
- **UNRESOLVED**: current source does not establish answer or intended compatibility contract.

## Compatibility risk matrix

| Missing mechanism | Verified current state | Third-party risk |
|---|---|---|
| Protocol version | No command, handshake field, or event | Client cannot preflight schema compatibility. |
| Server version handshake | No UDS handshake response; `update_available.current` is update UI metadata | Client cannot identify daemon release from protocol. |
| Capability negotiation | No feature/capability request or response | “Accepted” command may still be host-owned or transport no-op. |
| Daemon-instance ID | None | Reconnect cannot tell same daemon from replacement. |
| Generic request/command ID | None; `run.taskId` is status correlation only | Replies and silence cannot generally correlate to command. |
| Idempotency key/deduplication | None | Retrying effectful command can duplicate intent. |
| Delivery acknowledgment | Command-specific only; many commands none | Disconnect after write leaves outcome unknown. |
| Replay cursor/event IDs | Persisted DB has task-local sequence, wire replay events do not expose it | Snapshot/live duplicate cannot be reliably deduplicated. |
| Replay-complete marker | None | Client cannot prove global reconstruction finished. |

Sources: `src/kiss/server/sorcar.py:API`, `validate_command`, `ServerApi.dispatch`; `src/kiss/server/web_server.py:RemoteAccessServer._uds_handler`, `_handle_ready`; `src/kiss/server/server.py:VSCodeServer._replay_session`; `src/kiss/server/task_runner.py:_client_task_id_of`.

## Unresolved questions

### 1. Supported compatibility contract

- **FACT:** `API` is central command allowlist and `validate_command()` checks name plus required fields. Events have no equivalent central schema; emitters span server and agent modules. (`src/kiss/server/sorcar.py:API`; `src/kiss/server/{server.py,commands.py,task_runner.py,json_printer.py,merge_flow.py,web_server.py}`; `src/kiss/agents/sorcar/{chat_sorcar_agent.py,sorcar_agent.py,worktree_sorcar_agent.py}`.)
- **UNRESOLVED:** Which older/newer daemon releases intend wire compatibility? Which event fields/orderings are public contract rather than implementation detail?

### 2. Command success and ambiguous delivery

- **FACT:** `appendUserMessage` silently drops when no eligible live task; `userAnswer` silently drops when no queue; `selectModel` has no direct response. `stop` is exception: nonempty routed/unrouted target receives `stop_ack`. (`src/kiss/server/commands.py:_cmd_append_user_message`, `_cmd_user_answer`, `_cmd_select_model`; `src/kiss/server/task_runner.py:_stop_task`.)
- **UNRESOLVED:** How should independent client prove steering, answer, or model selection took effect after race/disconnect?
- **UNRESOLVED:** No safe generic retry rule for ambiguously delivered state-changing command can be established.

### 3. Replay boundary and state completeness

- **FACT:** `ready` requests models, input history, and config; broadcasts canonical tabs; then replays each chat-bound registry tab. (`src/kiss/server/web_server.py:RemoteAccessServer._handle_ready`; `src/kiss/server/server.py:VSCodeServer.ready_tab_sync`.)
- **FACT:** Running replay subscribes first, snapshots in-memory recording, then continues live fan-out. Source explicitly documents duplicate-delivery micro-window. Nested wire events have no sequence IDs. (`src/kiss/server/server.py:VSCodeServer._replay_session`.)
- **UNRESOLVED:** No explicit replay-complete signal or atomic snapshot/live boundary exists. Client cannot prove no event was missed or duplicated.
- **FACT:** One client's `ready` causes `tabs_state` and bound-tab replay broadcasts through shared printer, so already-connected clients can receive repaint/replay caused by reconnecting peer. (`src/kiss/server/web_server.py:_handle_ready`; `src/kiss/server/server.py:_replay_session`.)
- **UNRESOLVED:** Whether this cross-client replay is intended stable behavior is not declared.

### 4. Workspace identity

- **FACT:** Backend workspace is path text, not entity/table. Connection `setWorkDir` stamps later commands; history query is global and rows carry `work_dir`. (`src/kiss/server/sorcar.py:ServerApi.dispatch`; `src/kiss/agents/sorcar/persistence.py:_load_history`, `_search_history`.)
- **FACT:** Current webview history filter uses `applyHistoryFilterVisibility`; path normalization converts separators, strips trailing slash, and lowercases Windows-style paths. It does not resolve `.`, `..`, symlinks, relative paths, or realpaths. Empty `work_dir` and running rows pass workspace filter. (`src/kiss/agents/vscode/media/main.js:normalizeHistoryWorkDir`, `applyHistoryFilterVisibility`, `tabMatchesWorkspace`.)
- **UNRESOLVED:** Canonical equality policy: lexical path, absolute normalization, realpath, repo root, case folding, or filesystem identity?

### 5. Concurrent tab authority

- **FACT:** Daemon registry is canonical; nonempty chat binds at most one top-level tab, newest bind displaces prior tab. `closeTab` mutates all clients' canonical UI but does not stop busy task. (`src/kiss/server/tab_registry.py:TabRegistry.update_tab`; `src/kiss/server/server.py:ready_tab_sync`, `_drop_tab_state`.)
- **UNRESOLVED:** Product authority rules for two clients concurrently opening, binding, navigating, or closing same tab are not stated beyond current last-mutation behavior.

### 6. Custom model contract

- **FACT:** Ordinary `models` entries have `name`, `inp`, `out`, `uses`, `vendor`. Config custom entry also includes `endpoint`, plaintext `api_key`, and `extra_headers`; whole entry is sent to requesting client. (`src/kiss/server/server.py:_get_models`; `src/kiss/core/vscode_config.py:get_custom_model_entry`.)
- **FACT:** `selectModel` accepts arbitrary string, updates per-tab/default state, records model usage, and `_record_model_usage` persists `last_model`; no validation response occurs. (`src/kiss/server/commands.py:_cmd_select_model`; `src/kiss/agents/sorcar/persistence.py:_record_model_usage`, `_save_last_model`.)
- **UNRESOLVED:** Which custom fields are stable wire contract? Should selection be validated before durable preference mutation?

### 7. Feature ownership

- **FACT:** Eleven catalog commands are dropped before validation because host/handshake owns them. UDS `openFile` and `checkPaths` are deliberate daemon no-ops. (`src/kiss/server/sorcar.py:API`, `DROPPED_COMMANDS`, `ServerApi.dispatch`, `open_file`, `check_paths`.)
- **UNRESOLVED:** No capability advertises daemon-serviced, VS Code-host-serviced, WSS-only, UDS-only, or unsupported behavior to third-party local client.

### 8. Full trajectory inspection

- **FACT:** Tool/transcript events are available over UDS. Full job trajectory lists are exposed through HTTP endpoints backed by `ServerApi.trajectory_jobs` and `job_trajectories`, not UDS commands. (`src/kiss/server/sorcar.py`, those methods; `src/kiss/server/web_server.py`, trajectory HTTP route handlers.)
- **UNRESOLVED:** Which local URL/auth flow and task-to-job association should native Neovim client use? Upstream UDS API may be preferable.

## Upstream concerns and likely bugs

### 1. Duplicate-run and command-loss ambiguity

- **FACT:** VS Code queues every disconnected command, capped 256, TTL 10 seconds, then sends fresh entries to next daemon without command-type filtering. Expired/overflow commands emit extension-local `commandDropped`, not daemon event. (`src/kiss/agents/vscode/src/AgentClient.ts:sendCommand`, connect callback, `PENDING_SEND_TTL_MS`, `MAX_PENDING_SENDS`.)
- **FACT:** No request ID, daemon epoch, delivery acknowledgment, or deduplication key exists.
- **INFERENCE — LIKELY BUG:** If original `run` executes but client loses evidence, user/reconnect retry can start second task when tab no longer has installed worker. If original remains installed on same tab, duplicate nonblank `run` becomes steering instead. TTL limits age, not ambiguity. Commands can also expire or overflow and never execute.

### 2. Frame-limit drift

- **FACT:** Daemon/Python client enforce 67,108,864 input bytes. VS Code checks 33,554,432 UTF-16 code units in decoded buffer before splitting lines. Effective wire-byte limit varies by text and chunk composition. (`src/kiss/server/web_server.py:_MAX_LINE_BYTES`; `src/kiss/agents/sorcar/daemon_client.py:_MAX_LINE_BYTES`; `src/kiss/agents/vscode/src/AgentClient.ts:MAX_LINE_BUFFER_BYTES`, `_handleData`.)
- **INFERENCE — LIKELY BUG:** A daemon-legal event can force VS Code reconnect. Limits and units are protocol drift.

### 3. Invalid UTF-8 closes UDS without wire error

- **FACT:** `_uds_handler()` passes bytes to `json.loads`, catches `JSONDecodeError` at parse site, then outer generic catch logs debug and cleanup closes connection. (`src/kiss/server/web_server.py:RemoteAccessServer._uds_handler`.)
- **INFERENCE — LIKELY BUG:** Invalid UTF-8 raises `UnicodeDecodeError`; peer receives disconnect, no protocol `error`, unlike malformed JSON which is skipped.

### 4. Steering/answer silently drop

- **FACT:** Unresolvable `appendUserMessage` and `userAnswer` have no sender response. (`src/kiss/server/commands.py:_cmd_append_user_message`, `_cmd_user_answer`.)
- **INFERENCE — DESIGN ISSUE:** UI cannot distinguish accepted input from dropped input near terminal/reconnect races. Question has no ID.

### 5. `activeTasksResponse.tabs` is display text

- **FACT:** Response is `count` plus strings formatted `"<tabId>(task=<task_id>)"`, not structured objects. (`src/kiss/server/web_server.py:_handle_active_tasks_query`, `_snapshot_active_tabs`.)
- **INFERENCE — DESIGN ISSUE:** It is coarse health signal, not safe reconstruction anchor.

### 6. Shallow validation

- **FACT:** `validate_command()` checks object, nonempty string type, known command, and required fields being non-`None`; types/enums are handler-specific. (`src/kiss/server/sorcar.py:validate_command`; `src/kiss/server/commands.py:_CommandsMixin`.)
- **INFERENCE — DESIGN ISSUE:** Malformed third-party payload can produce silent no-op, coercion, broad default, or handler-specific error rather than stable validation response.

### 7. Client-defined workspace history

- **FACT:** Daemon history query is global top-level history; VS Code filters locally and includes empty-path/running rows in every workspace. (`src/kiss/agents/sorcar/persistence.py:_load_history`, `_search_history`; `src/kiss/agents/vscode/media/main.js:applyHistoryFilterVisibility`.)
- **INFERENCE — DESIGN ISSUE:** Clients can disagree on “current workspace” and legacy rows appear in every workspace.

### 8. Custom-model credentials on wire

- **FACT:** Requester-scoped `models` event can contain plaintext custom `api_key` and headers. Any same-user UDS client or authenticated WSS client requesting models receives them. (`src/kiss/core/vscode_config.py:get_custom_model_entry`; `src/kiss/server/server.py:_get_models`; `src/kiss/server/web_server.py:WebPrinter.broadcast` connection routing.)
- **INFERENCE — SECURITY/DESIGN ISSUE:** Model discovery response exposes credentials beyond display needs. Client must never log/persist raw payload; upstream should omit secrets.

### 9. Durable invalid model selection

- **FACT:** `selectModel` accepts arbitrary string and records/persists preference before next-run availability validation. (`src/kiss/server/commands.py:_cmd_select_model`; `src/kiss/agents/sorcar/persistence.py:_record_model_usage`, `_save_last_model`; `src/kiss/server/task_runner.py:_run_task_inner`.)
- **INFERENCE — DESIGN ISSUE:** Invalid model name can become durable `last_model` and usage entry with no direct error.

### 10. `KISS_SORCAR_SOCK` client/server mismatch

- **FACT:** Python/VS Code clients honor `KISS_SORCAR_SOCK`; `_default_uds_path()` and production `main()` do not. Daemon override exists only as constructor `uds_path`. (`src/kiss/agents/sorcar/daemon_client.py:_resolve_sock_path`; `src/kiss/agents/vscode/src/AgentClient.ts:constructor`; `src/kiss/server/web_server.py:_default_uds_path`, `RemoteAccessServer.__init__`, `main`.)
- **INFERENCE — LIKELY BUG/DOCUMENTATION ISSUE:** Setting env var alone points clients away from normal daemon listener.

### 11. Worktree restoration docstring contradicts body

- **FACT:** `_handle_worktree_action` docstring says it restores Git state after restart. Body immediately requires live tab state, `state.use_worktree`, live agent, and `agent._wt_pending`; no restoration code runs otherwise. (`src/kiss/server/merge_flow.py:_handle_worktree_action`.)
- **INFERENCE — LIKELY BUG OR STALE DOCSTRING:** Restarted client can replay historical worktree UI but cannot act on it through current handler.

### 12. `MY_MODELS.json` ignores `KISS_HOME`

- **FACT:** Model registry uses literal `Path.home() / ".kiss" / "MY_MODELS.json"`, while DB/config paths honor `KISS_HOME`. (`src/kiss/core/models/model_info.py:USER_MY_MODELS_PATH`; `src/kiss/core/config.py:kiss_home`; persistence/config path helpers.)
- **INFERENCE — DESIGN ISSUE:** Custom registry and daemon state split across homes under nondefault `KISS_HOME`.

## Manual verification before implementation

Record raw NDJSON with timestamps against exact revision.

1. **Framing/Unicode:** coalesced commands; split command and split multibyte code point; invalid UTF-8; ASCII/BMP/astral payloads around both clients' effective limits.
2. **Ambiguous `run`:** disconnect before/during/after write; inspect `activeTasksQuery`, `ready`, and history without replay; test VS Code queue against replacement daemon.
3. **Live reconnect:** disconnect all clients during run, reconnect/send `ready`, compare canonical `tabs_state`, per-tab `task_events`, live fan-out, persisted events, terminal status, and known duplicate window.
4. **Cross-client `ready`:** keep one client connected while second reconnects; verify repaint/replay behavior and drafts/questions remain correct.
5. **Stop:** empty/unroutable tab, startup, model call, tool, pending question, worktree merge/autocommit; verify `stop_ack`, lifecycle, persisted result.
6. **Ask/answer races:** owner/viewer answer, disconnect/replay, concurrent answers. Observe last-writer/overwrite behavior; do not assume exactly one handler emission.
7. **Steering timing:** startup, model step, tool, finalization, after terminal; determine accepted/persisted/dropped cases.
8. **Concurrent tabs:** VS Code plus candidate client concurrently open/bind/navigate/close same chat; verify displacement and task survival.
9. **Workspace:** symlink/realpath, relative path, parent/child, linked worktree, case variants, empty history path; compare VS Code filter.
10. **Daemon restart:** separately test graceful interruption and abrupt orphan recovery during run, pending question, pending worktree, merge.
11. **Version skew:** one older and newer daemon; unknown commands/events and changed fields; ensure unsupported mutations fail closed.
12. **Worktree restart:** verify historical `worktree_done` replay cannot authorize action and current handler returns no-pending/mode error.
13. **Custom model secrecy:** capture `models` response and verify client redacts secrets from logs, diagnostics, and UI.
14. **Trajectory HTTP:** verify local URL, TLS/auth, job/task association, and whether pure UDS client can avoid this feature initially.

## Verified documentation contradictions

### README: “services every client command … over its socket”

- **Documentation:** root `README.md`, daemon section, says `kiss-web` “services every client command … over its socket.”
- **FACT:** Eleven commands are silently dropped by normal daemon dispatch; UDS `openFile` and `checkPaths` are explicit no-ops. (`src/kiss/server/sorcar.py:DROPPED_COMMANDS`, `ServerApi.dispatch`, `open_file`, `check_paths`.)
- **CONTRADICTION:** Not every catalogued client command is serviced by daemon over local socket. Some are host-local, handshake-only, or transport-specific.

### README: history filtered to current workspace

- **Documentation:** root `README.md` says history is filtered to current workspace by default.
- **FACT:** Backend history query is global; VS Code performs local UI filter, intentionally includes empty `work_dir` and all running rows. (`src/kiss/agents/sorcar/persistence.py:_load_history`, `_search_history`; `src/kiss/agents/vscode/media/main.js:applyHistoryFilterVisibility`.)
- **NO STRICT CONTRADICTION:** Statement describes UI default, but must not be interpreted as daemon-side filtering, access control, or exact workspace isolation.

No other verified README/source contradiction relevant to requested protocol investigation was established. Model count and socket mode statements match inspected source.

## Five decisions requiring acceptance or upstream answer

1. Compatibility without protocol/server version or capability negotiation.
2. Effectful delivery semantics without generic identity/idempotency/acknowledgment; `stop` already has command-specific `stop_ack`.
3. Reconnect reconstruction without event IDs or replay-complete boundary.
4. Canonical workspace path/filter semantics shared by third-party clients.
5. Stable daemon API boundary versus VS Code-host/WSS/HTTP-only behavior, especially trajectories and editor-local file actions.
