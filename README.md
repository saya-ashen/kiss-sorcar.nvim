# kiss-sorcar.nvim

[![CI](https://github.com/saya-ashen/kiss-sorcar.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/saya-ashen/kiss-sorcar.nvim/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-green.svg?logo=neovim)](https://neovim.io)

An experimental Neovim client for the local [KISS Sorcar](https://github.com/ksenxx/kiss_ai) daemon. It provides a small standalone UI and a Sorcar backend for [Agent Workbench](https://github.com/saya-ashen/agent-workbench.nvim).

This is an independent community project. It is not an official KISS client.

## Demo

KISS Sorcar running as an Agent Workbench backend:

- native daemon integration;
- streamed execution and lifecycle tracking;
- live steering and guarded actions;
- reconnect-aware state handling.

Full demonstration video:

[Watch the 57-second demo (MP4, 1080p)](https://github.com/saya-ashen/kiss-sorcar.nvim/releases/download/demo-2026-08-25/kiss-sorcar-agent-workbench-demo.mp4)

## Features

- Pure Lua NDJSON client over Sorcar's Unix-domain socket
- Split/coalesced frame and UTF-8-safe stream handling
- Connection-generation isolation and bounded automatic reconnect
- Canonical tab lifecycle, task submission, steering, and stop actions
- Fail-closed handling for stale tabs, questions, and worktree actions
- Workspace-filtered history with exact chat/task resume
- Native Agent Workbench transcript and session integration
- A dependency-free headless test harness plus opt-in real-daemon tests

## Built with KISS Sorcar

This project was developed through extensive dogfooding of KISS Sorcar itself.

The client was built by using Sorcar for protocol investigation, implementation,
testing, and review. The integration focuses on making a coding-agent frontend
work with a backend that has a different execution and state model.

Key design principles:

- separate frontend sessions from backend-native identities;
- preserve task, chat, and execution lifecycle semantics;
- avoid unsafe retries or inferred state after uncertain disconnects;
- represent freshness explicitly instead of hiding stale state.

See [Built with KISS Sorcar](docs/BUILT_WITH_SORCAR.md) for development notes and reliability findings.

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
            path = vim.fn.expand("~/.kiss/sorcar.sock"),
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

## Development

See [docs/testing.md](docs/testing.md) for the integration matrix and [docs/protocol.md](docs/protocol.md) for the pinned protocol inventory.

## License

MIT.
