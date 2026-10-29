# Compose and send

Pilish opens a chat and input pair, then sends consecutive prompts without losing the later submission. With a fitted input height, the input window follows the draft.

## Sub-features

- `compose-layout` opens a live session with chat and input windows.
- `compose-send` submits a prompt and displays its reply.
- `compose-sequential` submits a second prompt after the first turn and returns to idle.
- `compose-fit-input` sizes a `fit` input window to the typed draft, stops at its cap, and shrinks after sending.

## How to get to it (user POV)

- Run `M-x pilish` from a project directory.
- Enter a prompt in the input buffer and press `C-c C-c`.
- Enter and send another prompt after the first reply.
- Set `pilish-input-window-height` to `fit`, type a multi-line draft, and press `C-c C-c`.

## Driving it with Pilish harnesses

Preconditions:

- The Doctor check passed. `RUN_DIR` is a new empty evidence directory.

- **Open the session.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-session-starts 2>&1 | tee "$RUN_DIR/layout.log"`. Record `layout.exit`. A zero status proves the fake process, chat window, input window, and two-window layout.
- **Send two prompts.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-send-waits-for-turn-start 2>&1 | tee "$RUN_DIR/send.log"`. Record `send.exit`. The test sends through `pilish-send`, displays the fake reply to the second prompt, and returns to idle.
- **Fit the input to a draft.** Run `G1_CAPTURE="$RUN_DIR/fit" ./test/run-gui-tests.sh --headless pilish-gui-test-input-window-fits-draft 2>&1 | tee "$RUN_DIR/fit.log"`. Record `fit.exit`. The test types three lines and then more lines than the cap with real keys, sends with `C-c C-c`, and asserts one draft line at start, three lines, the capped height ending at point's line, and one line after the reply. It writes `fit-empty`, `fit-three-lines`, `fit-capped`, and `fit-after-send` observations, plus PNG frames where `x-export-frames` exists.
- **Check the proof.** Require zero statuses and nonempty logs with `test "$(cat "$RUN_DIR/layout.exit")" -eq 0`, `test "$(cat "$RUN_DIR/send.exit")" -eq 0`, `test "$(cat "$RUN_DIR/fit.exit")" -eq 0`, `test -s "$RUN_DIR/layout.log"`, `test -s "$RUN_DIR/send.log"`, `test -s "$RUN_DIR/fit.log"`, and `test -s "$RUN_DIR/fit/fit-capped.el"`.

## Gotchas

- The fake supplies deterministic replies. It does not prove provider authentication or model output.
- The layout and send tests provide assertion logs, not PNG captures. Only the fit test writes captures.
- The echo area can change the pair's height during the fit test, so the cap is checked against the pair height at that moment.
- Steering, abort, completion, and image attachment are outside this seed entry. Do not claim them from this run.
