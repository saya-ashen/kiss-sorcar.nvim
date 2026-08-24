# kiss-sorcar.nvim

[![CI](https://github.com/saya-ashen/kiss-sorcar.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/saya-ashen/kiss-sorcar.nvim/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-green.svg?logo=neovim)](https://neovim.io)

An experimental Neovim client for the local [KISS Sorcar](https://github.com/ksenxx/kiss_ai) daemon. It provides a small standalone UI and a Sorcar backend for [Agent Workbench](https://github.com/saya-ashen/agent-workbench.nvim).

This is an independent community project. It is not an official KISS client.

## Features

- Pure Lua NDJSON client over Sorcar's Unix-domain socket
- Split/coalesced frame and UTF-8-safe stream handling
- Connection-generation isolation and bounded automatic reconnect
- Canonical tab lifecycle, task submission, steering, and stop actions
- Fail-closed handling for stale tabs, questions, and worktree actions
- Workspace-filtered history with exact chat/task resume
- Native Agent Workbench transcript and session integration
- A dependency-free headless test harness plus opt-in real-daemon tests

## Compatibility

The protocol implementation and research notes are pinned to KISS commit [`74af9b7`](https://github.com/ksenxx/kiss_ai/commit/74af9b738adeef91448790015cf8f416da71566c) (release `2026.8.14`). Sorcar currently exposes no protocol-version or capability-negotiation handshake, so later KISS releases may require adapter updates.

Requirements:

- Neovim 0.10+
- A local KISS Sorcar daemon with an accessible Unix socket
- Agent Workbench when using the integrated backend

## Installation

### Agent Workbench backend

With `lazy.nvim`:

```lua
{
    "saya-ashen/agent-workbench.nvim",
    dependencies = {
        "OXY2DEV/markview.nvim",
        {
            "saya-ashen/kiss-sorcar.nvim",
            config = function()
                require("kiss-sorcar.agent_workbench").register()
            end,
        },
    },
    opts = {
        backend = "sorcar",
        backend_options = {
            -- Defaults to $KISS_SORCAR_SOCK, then $KISS_HOME/sorcar.sock.
            path = vim.fn.expand("~/.kiss/sorcar.sock"),
            -- Optional; omit to use the daemon's selected model.
            -- run_options = { model = "provider/model" },
        },
    },
}
```

Start or restart `kiss-web` after the directory containing the socket is mounted. Then run `:AgentWorkbench`.

### Standalone client

```lua
{
    "saya-ashen/kiss-sorcar.nvim",
    config = function()
        require("kiss-sorcar").setup()
    end,
}
```

Commands:

- `:Sorcar` opens the client.
- `:Sorcar {prompt}` opens the client and submits a task.
- `:SorcarSteer {message}` steers the current running task.
- `:SorcarStop` requests that the current task stop.

## Configuration

Standalone setup accepts:

```lua
require("kiss-sorcar").setup({
    socket_path = vim.fn.expand("~/.kiss/sorcar.sock"),
    work_dir = vim.fn.getcwd(),
    tab_id = nil,
    connect = true,
    run_options = {},
})
```

The Agent Workbench backend accepts `path`, `tab_id`, `run_options`, `reconnect`, and `reconnect_delays`. Effectful commands are never queued or replayed after an uncertain disconnect.

## Security boundary

This plugin is a same-user client of the KISS daemon. Review [SECURITY.md](SECURITY.md) before using CLI-backed KISS models on a real workspace.

Do not commit or attach KISS databases, daemon logs, TLS keys, auth logs, or generated `tmp/` fixtures to bug reports.

## Development

Clone dependencies and initialize the submodule:

```sh
git clone --recurse-submodules https://github.com/saya-ashen/kiss-sorcar.nvim
cd kiss-sorcar.nvim
```

Run the dependency-free suite:

```sh
nvim --headless -u NONE -l tests/run.lua
```

Real-daemon tests are opt-in. Clone KISS separately and set `KISS_SOURCE_REPO`:

```sh
KISS_SOURCE_REPO=/path/to/kiss_ai KISS_REAL_DAEMON_TEST=1 \
  ./tests/integration/run_control_plane.sh
```

See [docs/testing.md](docs/testing.md) for the complete matrix and [docs/protocol.md](docs/protocol.md) for the pinned protocol inventory.

## License

MIT. The `pi2.nvim` submodule has its own license and history in the Agent Workbench repository.
