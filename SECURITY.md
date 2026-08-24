# Security policy

## Supported versions

Security fixes are applied to the latest revision on the default branch. The Sorcar protocol adapter is currently pinned to KISS `2026.8.14` / commit `74af9b738adeef91448790015cf8f416da71566c`.

## Reporting a vulnerability

Please do not open a public issue for an unpatched vulnerability. Use [GitHub's private vulnerability reporting](https://github.com/saya-ashen/kiss-sorcar.nvim/security/advisories/new) and include:

- the affected revision;
- a minimal reproduction;
- expected and observed behavior;
- the security impact;
- sanitized logs only.

Never attach API keys, OAuth data, KISS databases, daemon auth logs, TLS private keys, or a real conversation history.

For vulnerabilities in KISS itself, coordinate with the KISS maintainers. This repository can track client-side mitigations, but it cannot fix the daemon or provider adapters.

## Trust boundaries

### Local socket

The Sorcar Unix-domain socket is a same-user local interface and does not authenticate clients. Socket permissions and the containing directory are part of the security boundary. Any process that can connect may be able to observe task state or submit commands supported by the daemon.

### Model execution

`kiss-sorcar.nvim` transports commands and renders events. It does not execute models and does not provide a filesystem, process, network, or provider-tool sandbox.

At the pinned KISS revision, native Codex and Claude adapters can launch their official CLIs with approval/permission and sandbox bypass flags. KISS worktrees isolate Git changes but are not an operating-system sandbox, and the plugin cannot add approval checks after a provider CLI has already executed a tool.

Before using a CLI-backed model on a real workspace, use an independently enforced sandbox that matches the provider CLI's documented requirements, or choose a KISS configuration whose tool execution and credentials you explicitly trust. Do not treat the Neovim UI, KISS skill permissions, or a Git worktree as containment.

### Secrets and history

KISS databases and event logs may contain prompts, responses, filesystem paths, model metadata, and other private material. Some daemon model-discovery responses may also contain custom endpoint credentials. The plugin must not log or persist raw credentials; users should still treat daemon diagnostics and captured wire events as sensitive.
