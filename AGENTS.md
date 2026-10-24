# Pilish — Development Guide

Pilish is an Emacs frontend for the [Pi coding agent](https://pi.dev).
A session has a Markdown chat window and an ordinary prompt-editing window.
Pilish communicates with the Pi CLI through JSON-over-stdio RPC.

## Start here

- Read [README.org](README.org) for installation and user-visible behavior.
- Run `make help` for supported test, integration, benchmark, and quality targets. The [Makefile](Makefile) owns prerequisites and command details.
- Use [the verification skill](.agents/skills/verify-pilish/SKILL.md), or `/skill:verify-pilish`, to drive user-facing behavior and capture evidence. Its feature map selects the relevant journey.
- Read [the fake Pi contract](test/support/fake-pi-contract.md) before changing deterministic subprocess fixtures.
- Read each module's `Commentary` and owning tests before changing its behavior. The source tree, not this guide, is the file inventory.

## Architecture and ownership

- `pilish.el` starts sessions. `pilish-core.el` owns the process protocol. `pilish-ui.el` owns shared session state and disclosure behavior. `pilish-render.el` owns streaming, tool display, and cooling.
- `pilish-jsonl.el` reads Pi's saved data. `pilish-browse.el` owns session and tree browsers. `pilish-snapshot.el` owns independent read-only saved-conversation observers.
- Keep internal `require` dependencies acyclic. `pilish-ui.el` does not depend on `pilish-jsonl.el`. `pilish-menu.el` and `pilish-input.el` are siblings. `pilish-evil.el` is an optional leaf integration.
- Use the accessors in `pilish-ui.el` for cross-module state mutations. Direct `setq` is fine for state owned within a module.
- Loading Pilish must not make `md-ts-mode` claim unrelated Markdown buffers.
- Protocol settlement, owner-scoped rendering, cold-tool retention, and saved-conversation identity have local contracts in their owning modules and tests. Read those contracts instead of inferring behavior from event names, tool names, or output text.

## Workflow

1. Choose the owning module and the narrowest existing test. Add regressions to that suite rather than creating a parallel test layout.
2. Run focused tests during development, then `make check` before committing. Run the fake or real integration lane when the subprocess contract changes.
3. Before opening a PR, use `/skill:verify-pilish` for every changed user-facing feature and preserve its evidence. Standard tests do not replace this user-action pass.
4. When a user-facing journey changes, update the verification feature map through `/maintain-verification-skill`. Report product regressions separately from documentation drift.
5. Treat benchmark smoke targets as correctness checks. Use the primary benchmark lanes and their evidence rules for performance claims.

The unit suite runs in batch Emacs. Do not run the full unit suite inside an interactive Emacs. The GUI suite uses real frames with a deterministic fake backend. The real integration target starts Ollama.

For RPC changes, consult the Pi source that matches `PI_VERSION` in the Makefile. Its `packages/coding-agent/docs/rpc.md` and RPC implementation are the protocol reference.

## Conventions

- Prefix public symbols with `pilish-` and internal symbols with `pilish--`.
- Name tests after their owning suite, such as `pilish-test-...` or `pilish-gui-test-...`.
- Require `pilish-test-common` in module test files that use shared fixtures.
- Install the pre-commit hook with `make install-hooks`. It runs `make check`.
- Stage files explicitly with `git add <specific-files>`. Run `git status` before committing and keep test artifacts out of the commit.
