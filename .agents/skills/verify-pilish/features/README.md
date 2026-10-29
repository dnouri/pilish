# Pilish verification map

This directory maps user-facing Pilish features to their existing verification commands. Read [the verification skill](../SKILL.md) before driving a feature. Run its Doctor check, create `RUN_DIR`, and then load one feature file.

## Baseline preconditions

- Run from the repository root with Bash and `set -o pipefail`.
- Keep `--headless` on every direct GUI command. Remove it only when the user asks for a visible run.
- Complete the Launch and Doctor checks in the skill. Use a fresh `RUN_DIR` for each feature run.
- Use isolated test fixtures. Never point a driver at your interactive Emacs or saved Pi sessions.
- Use the fake backend for deterministic behavior. Choose real Pi only for a compatibility claim that needs it.
- Keep baseline and candidate evidence in separate directories.

## Driving conventions

- Treat every command as literal. Preserve its output and exit status.
- Run every listed entry point before calling the feature verified. One entry point does not prove another.
- Exercise the user action named in the recipe. Do not replace it with a state setter or a more convenient test.
- Do not weaken a journey when a prerequisite is missing. Record the failed command and unmet prerequisite.
- Record full-suite and isolated-feature results separately.

## Proof and skip reporting

- A passing command must produce its named assertion logs, artifacts, and external effects.
- For every required GUI test, require `PASS: TEST-NAME` and `0 skipped` in the log. A zero exit with a skipped required test is blocked, not passed.
- Tests with `G1_CAPTURE` support write Elisp traces and, where supported, PNG frames. Check every required file with `test -s` after cleanup.
- Tests without capture support provide assertion logs only. Do not claim screenshot evidence for them.
- Fake-backed tests do not prove real model or tool behavior. Correctness smoke runs do not prove performance.
- Reply, thinking, and tool metadata is explicit-only. Unit tests check that it is absent from native hover properties and that native chat help coexists with inspection. Other hover behavior is unchanged. Headless PGTK journeys prove explicit actions, not physical hover.
- Report an unreachable path as `verified-unreachable` only with the attempted route and concrete prerequisite. Report a deliberately unrun path as `not run`.
- Keep proof artifacts after deleting scratch state.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph about the user-visible behavior. It then has exactly four H2 sections in this order.

1. `Sub-features` lists short IDs and observable behaviors.
2. `How to get to it (user POV)` lists the entry points covered by the recipes.
3. `Driving it with Pilish harnesses` starts with `Preconditions:` and pairs exact commands with observable results.
4. `Gotchas` records limits and conditions that can invalidate a run.

Keep implementation ownership out of the map. The feature file names user paths, stable test names, commands, and proof.

## Features

- [Compose and send](./compose-and-send.md) covers session layout, consecutive prompt submission, and input header field toggles.
- [Read streamed output](./read-output.md) covers streaming, thinking display, scrolling, table resizing, and completed-block inspection.
- [Work with tool blocks](./tool-blocks.md) covers tool output, explicit tool details, native folds, child arguments, cursor stability, and cooling.
- [Browse and resume sessions](./sessions.md) covers session and tree browser actions plus browser-based resume.
- [Open saved conversations](./saved-conversations.md) covers independent observers, completed-block inspection, refresh, failure retention, and observer-only quit.
