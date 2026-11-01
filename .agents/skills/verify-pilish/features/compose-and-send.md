# Compose and send

Pilish opens a chat and input pair, then sends consecutive prompts without losing the later submission. With a fitted input height, the input window follows the draft.

## Sub-features

- `compose-layout` opens a live session with chat and input windows.
- `compose-send` submits a prompt and displays its reply.
- `compose-sequential` submits a second prompt after the first turn and returns to idle.
- `compose-fit-input` sizes a `fit` input window to the typed draft, stops at its cap, refits on frame-width changes, and shrinks after sending.
- `compose-fit-display` preserves a fitted draft when reopening the input, hides after sending in both `on-demand` and `hidden` styles, and reopens empty at one text line.

## How to get to it (user POV)

- Run `M-x pilish` from a project directory.
- Enter a prompt in the input buffer and press `C-c C-c`.
- Enter and send another prompt after the first reply.
- Set the global `pilish-input-window-height` option to `fit`, type a multi-line draft, resize the frame, and press `C-c C-c`.
- Set `pilish-input-window-display` to `on-demand` or `hidden`. Use `M-x pilish-open-input` to compose or reopen the input after sending.

## Driving it with Pilish harnesses

Preconditions:

- The Doctor check passed. `RUN_DIR` is a new empty evidence directory.

- **Open the session.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-session-starts 2>&1 | tee "$RUN_DIR/layout.log"`. Record `layout.exit`. A passing, non-skipped result proves the fake process and stacked chat and input windows.
- **Send two prompts.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-send-waits-for-turn-start 2>&1 | tee "$RUN_DIR/send.log"`. Record `send.exit`. The test sends through `pilish-send`, displays the fake reply to the second prompt, and returns to idle.
- **Fit the input to a draft.** Run `G1_CAPTURE="$RUN_DIR/fit" ./test/run-gui-tests.sh --headless pilish-gui-test-input-window-fits-draft 2>&1 | tee "$RUN_DIR/fit.log"`. Record `fit.exit`. The test types three lines and then more lines than the cap with real keys, sends with `C-c C-c`, and asserts one draft line at start, three lines, the capped height ending at point's line, and one line after the reply. It writes `fit-empty`, `fit-three-lines`, `fit-capped`, and `fit-after-send` observations and PNG frames.
- **Resize an unchanged draft.** Run `G1_CAPTURE="$RUN_DIR/resize" ./test/run-gui-tests.sh --headless pilish-gui-test-input-fit-refits-on-frame-resize 2>&1 | tee "$RUN_DIR/resize.log"`. Record `resize.exit`. The graphical frame changes from 104 to 54 columns and back. Without another edit, the same draft grows from two to four text rows and returns to two. It writes `fit-wide`, `fit-narrow`, and `fit-wide-again` observations and PNG frames.
- **Compose on demand.** Run `G1_CAPTURE="$RUN_DIR/display" ./test/run-gui-tests.sh --headless pilish-gui-test-input-fit-with-hide-after-send 2>&1 | tee "$RUN_DIR/display.log"`. Record `display.exit`. The test checks both display styles at launch, closes and reopens a three-line draft with keys, sends with `C-c C-c`, verifies the input disappears, and reopens an empty one-line input. It writes `fit-on-demand-draft`, `fit-on-demand-sent`, `fit-on-demand-reopened`, and the corresponding `fit-hidden-*` observations and PNG frames.
- **Check the logs.** Require zero statuses, `PASS: TEST-NAME` for each named test, and `0 skipped` in every log. For each stem `layout`, `send`, `fit`, `resize`, and `display`, run `test "$(cat "$RUN_DIR/STEM.exit")" -eq 0` and `test -s "$RUN_DIR/STEM.log"`, replacing `STEM` with the stem.
- **Check the captures.** Run `test -s "$RUN_DIR/fit/fit-capped.el"`, `test -s "$RUN_DIR/fit/fit-capped.png"`, `test -s "$RUN_DIR/resize/fit-narrow.el"`, `test -s "$RUN_DIR/resize/fit-narrow.png"`, `test -s "$RUN_DIR/resize/fit-wide-again.el"`, `test -s "$RUN_DIR/resize/fit-wide-again.png"`, `test -s "$RUN_DIR/display/fit-on-demand-reopened.el"`, `test -s "$RUN_DIR/display/fit-on-demand-reopened.png"`, `test -s "$RUN_DIR/display/fit-hidden-reopened.el"`, and `test -s "$RUN_DIR/display/fit-hidden-reopened.png"`.

## Gotchas

- The fake supplies deterministic replies. It does not prove provider authentication or model output.
- The layout and send tests provide assertion logs, not PNG captures. The fitted-input tests require graphical Emacs with `x-export-frames` for the named PNG proof.
- Input height and maximum height are global options, not session-local settings. `fit` may shrink the input below `window-min-height`; the chat window keeps its minimum.
- Edits share a pending fit timer until it runs. Commands that yield may allow several fits, so this is not a once-per-command guarantee.
- The echo area can change the pair's height during the fit test, so the cap is checked against the pair height at that moment.
- Steering, abort, completion, and image attachment are outside this seed entry. Do not claim them from this run.
