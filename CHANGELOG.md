# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html) for tagged releases.

## [Unreleased]

### Added

- Pure Lua Sorcar UDS transport, protocol, state, lifecycle, and standalone UI.
- Agent Workbench backend with normalized streaming and lifecycle events.
- Workspace-filtered history listing and exact chat/task resume.
- Bounded reconnect with actionable `ENOENT` and `ECONNREFUSED` diagnostics.
- Fake-daemon, headless UI, and opt-in isolated real-daemon test coverage.
- Public installation, compatibility, contribution, and security documentation.

### Changed

- Renamed the bundled Agent Workbench submodule directory from `pi2.nvim` to `agent-workbench.nvim` and pinned it to the canonical `saya-ashen/agent-workbench.nvim` upstream.
- Development launches opt into Agent Workbench's recommended keymap preset while keeping production defaults unchanged.

### Fixed

- Agent Workbench's workspace explorer no longer exposes Pi JSONL history while the Sorcar backend is active.
- `scripts/nvim-dev` again honors `KISS_SORCAR_MODEL` and forwards all command-line arguments to Neovim.

### Security

- Effectful commands fail closed across disconnects and are never replayed automatically.
- Sorcar events enter Agent Workbench on Neovim's main loop rather than a libuv fast-event context.
- Documentation now states that provider CLI execution is outside this plugin's sandbox and approval boundary.
