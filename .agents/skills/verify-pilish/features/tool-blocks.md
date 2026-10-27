# Work with tool blocks

Tool output stays inside its owning block. Live updates keep readers on surviving text, arguments and child output fold independently, and completed blocks retain readable content and explicit details after cooling. Tool metadata does not appear on automatic hover. Native control hover is unchanged.

## Sub-features

- `tool-output` displays fake tool output in its tool block.
- `tool-fold` toggles output and argument folds with native actions.
- `tool-viewport` preserves two-window scroll and point positions during folds and scrolling.
- `tool-point` keeps a reader on text after a live block while its content grows and contracts.
- `tool-cooling` retains output and literal protection after older blocks cool.
- `tool-details` exposes a completed tool's timestamp and literal command hint through the same inspector as replies and thinking.

## How to get to it (user POV)

- Run a prompt that produces tool output.
- Press `TAB` on tool output, argument rows, and child output.
- Scroll and recenter the chat in two windows.
- Read text after a live tool block while its output updates.
- Continue the conversation until older tool blocks cool.
- Press `C-h .` on a completed tool for quick help, or `C-c C-p d` in a live chat for selected Help. Saved observers use `M-x pilish-describe-reply`.

## Driving it with Pilish harnesses

Preconditions:

- The Doctor check passed. `RUN_DIR` is a new empty evidence directory.

- **Display output.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-content-tool-output-shown 2>&1 | tee "$RUN_DIR/output.log"`. Record `output.exit`. The fake read result appears inside the owning tool block.
- **Check the block boundary.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-tool-overlay-bounded 2>&1 | tee "$RUN_DIR/boundary.log"`. Record `boundary.exit`. The later assistant reply remains outside the tool overlay.
- **Exercise folds and cooling.** Run `G1_CAPTURE="$RUN_DIR/tool-capture" ./test/run-gui-tests.sh --headless pilish-gui-test-large-arguments-scroll-and-cool 2>&1 | tee "$RUN_DIR/cooling.log"`. Record `cooling.exit`. The trace contains native `TAB`, scroll, and recenter commands. The final state retains bounded arguments, child output, and cold literal guards.
- **Check child controls.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-output-button-keyboard-child 2>&1 | tee "$RUN_DIR/child.log"`. Record `child.exit`. Native `TAB` changes child output without changing its argument fold.
- **Keep the reader's place.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-tool-streaming-preserves-point-after-block 2>&1 | tee "$RUN_DIR/cursor.log"`. Record `cursor.exit`. Point stays on the sentinel after the block through streaming growth and final contraction.
- **Inspect through folds and cooling.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-reply-details-keyboard-help-and-safe-quit 2>&1 | tee "$RUN_DIR/details.log"`. Record `details.exit`. Real `C-h .` and `C-c C-p d` show the same literal tool report on the header, collapsed output, expanded output, and cold block. Help `q` preserves the live process, draft, and session file.
- **Check the proof.** Require zero statuses and nonempty logs for all six commands. Require `chat-104.png`, `chat-54.png`, `chat-cooled.png`, and their matching `.el` files under `$RUN_DIR/tool-capture`. Use `test -s` for every file.

## Gotchas

- The large scenario uses synthetic tool data. It does not execute real tools or prove a model selected them.
- The cursor-stability test checks a selected reader in a synthetic chat buffer. It does not provide fake-subprocess or PNG evidence.
- PNG capture requires `x-export-frames`. Missing PNGs make a screenshot requirement blocked even when the assertions pass.
- Judge output within its owning block. A matching string elsewhere in the transcript is not evidence.
- The details journey uses synthetic saved tool data inside a live fake-backed chat. Unit tests separately check live execution timing, the absence of custom metadata from native hover properties, and native-help coexistence. Headless PGTK cannot prove physical hover.
