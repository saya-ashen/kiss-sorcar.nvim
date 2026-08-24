# Contributing

Thanks for helping improve `kiss-sorcar.nvim`.

## Before opening a change

- Keep the adapter compatible with the pinned KISS revision unless the change explicitly updates the protocol research.
- Preserve the transport/protocol/state/UI boundaries described in [docs/architecture.md](docs/architecture.md).
- Do not add automatic retries for effectful commands.
- Do not commit real daemon state, logs, databases, credentials, certificates, or conversation history.
- Update user-facing documentation with behavior changes.

## Setup

Clone with the Agent Workbench submodule:

```sh
git clone --recurse-submodules https://github.com/saya-ashen/kiss-sorcar.nvim
cd kiss-sorcar.nvim
```

Run the core suite:

```sh
nvim --headless -u NONE -l tests/run.lua
```

Optional real-daemon tests require a separate KISS checkout. Set `KISS_SOURCE_REPO` rather than copying it into this repository. The tests create isolated state below ignored `tmp/` and must not use your normal `~/.kiss` directory.

See [docs/testing.md](docs/testing.md) for focused and integration commands.

## Pull requests

Describe:

1. the protocol or UI behavior being changed;
2. the failure mode or invariant covered;
3. the tests run;
4. any remaining compatibility or security uncertainty.

Use sanitized fixtures. If a report could expose an unpatched vulnerability, follow [SECURITY.md](SECURITY.md) instead of opening a public pull request or issue.
