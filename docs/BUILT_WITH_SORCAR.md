# Built with KISS Sorcar

## Overview

`kiss-sorcar.nvim` was developed through dogfooding KISS Sorcar itself.
The goal was not to build another chat interface, but to integrate KISS Sorcar
as a backend for a backend-agnostic coding-agent workbench.

## Development Approach

KISS Sorcar was used throughout development for:

- protocol investigation;
- architecture design;
- implementation tasks;
- regression test development;
- code review and refinement.

## Architecture

The integration separates frontend interaction from backend execution:

```
Agent Workbench UI
        |
 BackendSession abstraction
        |
 Sorcar backend
        |
 KISS Sorcar daemon
```

The client keeps backend-native identities separate:

- Agent Workbench session identity;
- Sorcar tab identity;
- chat identity;
- task identity;
- connection generation.

## Reliability Findings

Dogfooding exposed several challenges for long-running coding agents:

- effectful commands may not have generic acknowledgments or idempotency keys;
- reconnect may not provide replay cursors or stable event identifiers;
- semantic results and execution lifecycle completion are separate concepts;
- retained state and current confirmed state should not be treated as identical.

The client therefore adopts fail-closed behavior instead of unsafe retries or
implicit state reconstruction.

## Verification

The backend was tested with:

- fake daemon protocol tests;
- real KISS daemon integration tests;
- task execution;
- steering;
- stop handling;
- reconnect during active execution.

