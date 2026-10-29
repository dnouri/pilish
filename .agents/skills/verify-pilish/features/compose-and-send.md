# Compose and send

Pilish opens a chat and input pair, then sends consecutive prompts without losing the later submission.

## Sub-features

- `compose-layout` opens a live session with chat and input windows.
- `compose-send` submits a prompt and displays its reply.
- `compose-sequential` submits a second prompt after the first turn and returns to idle.
- `compose-header-toggles` hides the input header's activity phase, cost, and context usage when their options are customized off.

## How to get to it (user POV)

- Run `M-x pilish` from a project directory.
- Enter a prompt in the input buffer and press `C-c C-c`.
- Enter and send another prompt after the first reply.
- Customize `pilish-header-activity-phase`, `pilish-header-cost`, or `pilish-header-context-usage` with `setopt` or `M-x customize-group RET pilish`.

## Driving it with Pilish harnesses

Preconditions:

- The Doctor check passed. `RUN_DIR` is a new empty evidence directory.

- **Open the session.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-session-starts 2>&1 | tee "$RUN_DIR/layout.log"`. Record `layout.exit`. A zero status proves the fake process, chat window, input window, and two-window layout.
- **Send two prompts.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-send-waits-for-turn-start 2>&1 | tee "$RUN_DIR/send.log"`. Record `send.exit`. The test sends through `pilish-send`, displays the fake reply to the second prompt, and returns to idle.
- **Hide header fields.** Run `G1_CAPTURE="$RUN_DIR/header" ./test/run-gui-tests.sh --headless pilish-gui-test-input-header-field-toggles 2>&1 | tee "$RUN_DIR/header.log"`. Record `header.exit`. After a fake turn reports session stats, the displayed input header shows `idle`, `$0.25`, and `25.0%/200k`. Turning the three options off with `setopt` repaints it without them, and turning cost back on restores only the cost. The test writes `header-default` and `header-hidden` traces and PNG frames.
- **Check the proof.** Require zero statuses and nonempty logs with `test "$(cat "$RUN_DIR/layout.exit")" -eq 0`, `test "$(cat "$RUN_DIR/send.exit")" -eq 0`, `test "$(cat "$RUN_DIR/header.exit")" -eq 0`, `test -s "$RUN_DIR/layout.log"`, `test -s "$RUN_DIR/send.log"`, `test -s "$RUN_DIR/header.log"`, `test -s "$RUN_DIR/header/header-default.png"`, and `test -s "$RUN_DIR/header/header-hidden.png"`.

## Gotchas

- The fake supplies deterministic replies. It does not prove provider authentication or model output.
- Only the header toggle test writes PNG captures; the others provide assertion logs.
- Steering, abort, completion, and image attachment are outside this seed entry. Do not claim them from this run.
