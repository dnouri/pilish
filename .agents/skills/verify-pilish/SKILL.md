---
name: verify-pilish
description: Verify Pilish through its graphical Emacs UI, deterministic fake Pi, and existing integration harnesses. Use to reproduce a user-visible bug, prove a changed feature before a PR, or audit the feature map.
---

# Verify Pilish

Use this skill to prove user-visible Pilish behavior. Read [the feature index](features/README.md), then load the feature file for the behavior under test. Keep ordinary unit, lint, and integration checks in their existing lanes. This skill adds the user-action and evidence pass before a PR.

Verification is headless by default. Omit `--headless` only when the user asks for a visible Emacs run.

## Launch

Run the startup canary from the repository root:

```bash
make test-gui-ci SELECTOR=pilish-gui-test-session-starts
```

This target installs missing project-local dependencies, starts a real graphical Emacs under xvfb with a fake Pi subprocess, checks the two-window layout, and exits. It does not attach to your interactive display. Ready means one passing test and no failures.

There is no persistent verification server. Each drive starts a fresh Emacs and isolated session fixtures. Never attach a verification driver to your interactive Emacs or your saved Pi sessions.

## Doctor

Before each feature run, and after any failed drive, run:

```bash
./test/run-gui-tests.sh --headless pilish-gui-test-session-starts
```

This direct invocation uses the already provisioned project package tree. A pass proves a live fake subprocess, usable chat and input windows, and the expected window layout. Stop on a failure. Do not continue with a different feature to obtain a green result.

For an alternate dependency tree, provision it first and invoke the direct runner with `PACKAGE_USER_DIR` set. Do not use a Make target with dependency prerequisites against that tree. Make can install packages and change the environment under test. Missing dependencies make the run blocked.

When investigating loaded-code drift, record `package-user-dir`, `window-system`, resolved libraries, and definition owners inside the affected Emacs. An intended load path or installed version does not identify the running code. Treat a clean `-Q` run and a full-init run as separate observations.

## Drive

1. State the behavior and the observations required to prove it.
2. Read the matching feature file and run its literal commands from the repository root.
3. Use the ordinary command, key, click, or scroll action named by the feature. Assert the resulting buffer, file, process, or viewport state. No-error is not proof.
4. Preserve stdout, stderr, and the exit status for every command.
5. Record unrun entry points and failed or blocked checks. A related green workload does not prove that an unreproduced symptom is fixed.

The GUI tests use real Emacs frames and production Pilish commands. The fake replaces the Pi subprocess at its existing executable boundary. It does not prove a real model, tool, or extension ran. Use `make test-integration-fake` for deterministic subprocess contracts. Use `make test-integration-real` only when real Pi compatibility is the question. The local real target starts Ollama.

Prefer exact GUI test names. The direct runner embeds its selector in generated Elisp and does not preserve regexp backslashes. Use the unit and integration Make targets for regexp selectors.

## Evidence

Create a unique evidence directory before the run:

```bash
mkdir -p "$PWD/tmp/verification"
RUN_DIR=$(mktemp -d "$PWD/tmp/verification/pilish.XXXXXX")
export RUN_DIR
set -o pipefail
```

Retain each command's output and status. This example preserves the Doctor evidence:

```bash
./test/run-gui-tests.sh --headless pilish-gui-test-session-starts 2>&1 | tee "$RUN_DIR/doctor.log"
status=${PIPESTATUS[0]}
printf '%s\n' "$status" > "$RUN_DIR/doctor.exit"
test "$status" -eq 0
```

Large GUI scenarios accept `G1_CAPTURE`. They write test-owned Elisp observations and, when `x-export-frames` is available, PNG frames:

```bash
G1_CAPTURE="$RUN_DIR/capture" \
  ./test/run-gui-tests.sh --headless pilish-gui-test-large-snapshot-refresh
```

Match the evidence to the claim:

- Capture the user action and the resulting state, not only the final screen.
- Check external effects such as session files, process state, and protected-input hashes when the feature mutates them.
- For tool output, identify the owning tool block. Distinguish raw text, visible text, hot overlays, and cold `pilish-cold-tool-block` properties.
- For Markdown and layout, inspect the relevant properties and window state. Request PNG evidence when pixels matter, then verify that the PNG exists.
- State whether a result came from an isolated feature or a full suite. Do not interchange those observations.

The GUI runner deletes its temporary result file after printing it. Keep the `tee` logs. For every required test, require `PASS: TEST-NAME` and `0 skipped` in the log. A zero exit with a skipped required test is blocked. Tests without `G1_CAPTURE` support provide assertion logs, not screenshots. Do not claim that a log proves pixels.

## Cleanup

Let each runner tear down the Emacs process and fixtures it created. Put an outer deadline around exploratory drives, for example `timeout 180s ./test/run-gui-tests.sh --headless pilish-gui-test-session-starts`. After a timeout or failure, check for remaining processes and stop only those owned by the run. Never kill Emacs, Pi, tmux, or Ollama by a broad process-name pattern.

Keep evidence outside disposable fixture directories. Benchmark runners replace their output directories on later runs, so give each run a new directory. If your run started Ollama, stop it with `make ollama-stop`. Do not stop an instance that was already running.

After cleanup, confirm that the required evidence remains:

```bash
find "$RUN_DIR" -type f -size +0 -print
test -s "$RUN_DIR/doctor.log"
test "$(cat "$RUN_DIR/doctor.exit")" -eq 0
```

When a feature requires captures, also run its named `test -s` checks. Missing required evidence makes the verification incomplete.

## Helpers

This skill adds no scripts. It uses these existing entry points:

- `./test/run-gui-tests.sh --headless TEST-NAME` runs one exact fake-backed GUI regression. The file is executable.
- `G1_CAPTURE="$RUN_DIR/capture"` enables existing large-scenario trace and PNG capture. It has no effect on tests that do not call the capture helper.
- `./bench/run-reload-resume-bench.sh --scenario smoke -c 1 --out-dir "$RUN_DIR/reload-resume"` drives browser-based resume under xvfb and writes correctness artifacts. It does not establish a performance claim.
- `make check` runs byte compilation, lint, and unit tests. `make help` lists the other supported lanes.
- [The fake Pi contract](../../../test/support/fake-pi-contract.md) defines supported scenarios and the subprocess boundary.

When user-facing behavior changes, run `/maintain-verification-skill`. Its source review and live pass keep this skill and the feature map aligned with the application. Product regressions belong in a separate fix, not in a documentation-only maintenance change.
