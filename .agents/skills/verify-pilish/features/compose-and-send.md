# Compose and send

Pilish opens a chat and input pair, then sends consecutive prompts without losing the later submission.

## Sub-features

- `compose-layout` opens a live session with chat and input windows.
- `compose-send` submits a prompt and displays its reply.
- `compose-sequential` submits a second prompt after the first turn and returns to idle.

## How to get to it (user POV)

- Run `M-x pilish` from a project directory.
- Enter a prompt in the input buffer and press `C-c C-c`.
- Enter and send another prompt after the first reply.

## Driving it with Pilish harnesses

Preconditions:

- The Doctor check passed. `RUN_DIR` is a new empty evidence directory.

- **Open the session.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-session-starts 2>&1 | tee "$RUN_DIR/layout.log"`. Record `layout.exit`. A zero status proves the fake process, chat window, input window, and two-window layout.
- **Send two prompts.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-send-waits-for-turn-start 2>&1 | tee "$RUN_DIR/send.log"`. Record `send.exit`. The test sends through `pilish-send`, displays the fake reply to the second prompt, and returns to idle.
- **Check the proof.** Require zero statuses and nonempty logs with `test "$(cat "$RUN_DIR/layout.exit")" -eq 0`, `test "$(cat "$RUN_DIR/send.exit")" -eq 0`, `test -s "$RUN_DIR/layout.log"`, and `test -s "$RUN_DIR/send.log"`.

## Gotchas

- The fake supplies deterministic replies. It does not prove provider authentication or model output.
- These tests provide assertion logs, not PNG captures.
- Steering, abort, completion, and image attachment are outside this seed entry. Do not claim them from this run.
