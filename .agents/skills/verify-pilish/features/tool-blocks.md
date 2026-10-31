# Work with tool blocks

Tool output stays inside its owning block. Output and completed thinking use bottom continuation controls. Bash and subagent footers show live elapsed time and retain Pi's recorded final duration. Arguments and child output fold independently. Completed blocks retain readable content, inert timing, and explicit details after cooling. Tool metadata does not appear on automatic hover. Native control hover is unchanged.

## Sub-features

- `tool-output` displays fake tool output in its tool block.
- `tool-bottom-control` expands and collapses output from its bottom button or left-margin caret.
- `tool-duration` advances live timing and keeps the recorded final value beside output in all fold states and window sizes.
- `tool-fold` toggles output and argument folds independently with native actions.
- `tool-viewport` preserves independent readers and keeps a following window filled as tool output grows and contracts.
- `tool-point` keeps a reader on surviving text and uses the body start when replacement deletes the text under point.
- `tool-cooling` retains output, literal protection, and inert recorded durations after older blocks cool.
- `tool-details` exposes a completed tool's timestamp, literal command hint, and recorded execution time through the same inspector as replies and thinking.

## How to get to it (user POV)

- Run a prompt that produces tool output.
- Press `TAB` or `RET` on a bottom output control, or click its left-margin caret. Use the argument-row controls independently.
- Watch `Elapsed` advance during bash or subagent execution and change to `Took …` on completion. Live labels use whole seconds below a minute and minutes or hours above it. Resize the frame or show the chat in unequal windows.
- Scroll and recenter the chat in two windows.
- Read text after a live tool block while its output updates.
- Place point inside preview text that a later preview or final result replaces.
- Continue the conversation until older tool blocks cool.
- Press `C-h .` on a completed tool for quick help, or `C-c C-p d` in a live chat for selected Help. Saved observers use `M-x pilish-describe-reply`.

## Driving it with Pilish harnesses

Preconditions:

- The Doctor check passed. `RUN_DIR` is a new empty evidence directory.

- **Display output.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-content-tool-output-shown 2>&1 | tee "$RUN_DIR/output.log"`. Record `output.exit`. The fake read result appears inside the owning tool block.
- **Check the block boundary.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-tool-overlay-bounded 2>&1 | tee "$RUN_DIR/boundary.log"`. Record `boundary.exit`. The later assistant reply remains outside the tool overlay.
- **Exercise folds and cooling.** Run `G1_CAPTURE="$RUN_DIR/tool-capture" ./test/run-gui-tests.sh --headless pilish-gui-test-large-arguments-scroll-and-cool 2>&1 | tee "$RUN_DIR/cooling.log"`. Record `cooling.exit`. The trace contains native `TAB`, scroll, and recenter commands. The final state retains bounded arguments, child output, and cold literal guards.
- **Check child controls.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-output-button-keyboard-child 2>&1 | tee "$RUN_DIR/child.log"`. Record `child.exit`. Native `TAB` changes child output without changing its argument fold.
- **Exercise bottom controls.** Run `G1_CAPTURE="$RUN_DIR/bottom-controls" ./test/run-gui-tests.sh --headless pilish-gui-test-tool-toggle-expand-collapse-cycle 2>&1 | tee "$RUN_DIR/bottom-controls.log"`. Record `bottom-controls.exit`. Native `TAB`, `RET`, and margin clicks toggle the bottom output and thinking controls. Cold output keeps one inert continuation and drops active `Show less` text.
- **Observe live timing.** Run `G1_CAPTURE="$RUN_DIR/live-duration" ./test/run-gui-tests.sh --headless pilish-gui-test-live-duration-advances-and-settles 2>&1 | tee "$RUN_DIR/live-duration.log"`. Record `live-duration.exit`. Real one-second timers advance `Elapsed`, then a deliberately different recorded value replaces it. Fold controls and output stay unchanged between ticks. Then run `G1_CAPTURE="$RUN_DIR/long-elapsed" ./test/run-gui-tests.sh --headless pilish-gui-test-live-duration-formats-long-values 2>&1 | tee "$RUN_DIR/long-elapsed.log"` and record `long-elapsed.exit`. Real scheduled ticks show `Elapsed 4m 28s` and `Elapsed 1h 1m 1s` at standard and narrow widths.
- **Check responsive final timing.** Run `G1_CAPTURE="$RUN_DIR/duration-geometry" ./test/run-gui-tests.sh --headless pilish-gui-test-recorded-duration-responsive-footer-geometry 2>&1 | tee "$RUN_DIR/duration-geometry.log"`. Record `duration-geometry.exit`. Final durations align to each window's right edge at 104 and 54 columns, stack intact in a narrow sibling, and survive cooling.
- **Drive timing through fake Pi.** Run `G1_CAPTURE="$RUN_DIR/fake-duration" ./test/run-gui-tests.sh --headless pilish-gui-test-fake-duration-live-reload-and-resume 2>&1 | tee "$RUN_DIR/fake-duration.log"`. Record `fake-duration.exit`. The subprocess supplies `durationMs: 125000`. The display advances locally, settles on `Took 2m 5s`, and restores that value after browser resume and process reload.
- **Keep the reader's place.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-tool-streaming-preserves-point-after-block 2>&1 | tee "$RUN_DIR/cursor.log"`. Record `cursor.exit`. Point stays on the sentinel after the block through streaming growth and final contraction.
- **Restore point after replaced preview text.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-tool-streaming-restores-deleted-point-to-body-start 2>&1 | tee "$RUN_DIR/preview-point.log"`. Record `preview-point.exit`. Then run `./test/run-gui-tests.sh --headless pilish-gui-test-tool-completion-restores-deleted-point-to-body-start 2>&1 | tee "$RUN_DIR/final-point.log"` and record `final-point.exit`. Both replacements leave point at the final body start.
- **Keep independent views after completion.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-tool-completion-keeps-independent-views-filled 2>&1 | tee "$RUN_DIR/completion-view.log"`. Record `completion-view.exit`. The follower stays filled through contraction and the next append, while the other reader keeps its exact start and point.
- **Inspect through folds and cooling.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-reply-details-keyboard-help-and-safe-quit 2>&1 | tee "$RUN_DIR/details.log"`. Record `details.exit`. Real `C-h .` and `C-c C-p d` show the same literal tool report on the header, collapsed output, expanded output, and cold block. Help `q` preserves the live process, draft, and session file.
- **Check the proof.** Require zero statuses and nonempty logs for all fourteen commands. Require `chat-104.png`, `chat-54.png`, `chat-cooled.png`, and their matching `.el` files under `$RUN_DIR/tool-capture`. Require `bottom-54-collapsed.png` under `$RUN_DIR/bottom-controls`, `elapsed-compound-independent-edges.png` under `$RUN_DIR/live-duration`, `elapsed-minutes.png` and `elapsed-hours-narrow.png` under `$RUN_DIR/long-elapsed`, `duration-narrow-sibling.png` under `$RUN_DIR/duration-geometry`, and `fake-duration-resumed.png` plus `fake-duration-reloaded.png` under `$RUN_DIR/fake-duration`, with matching `.el` files. Use `test -s` for every file.

## Gotchas

- The large scenario and synthetic duration journeys do not execute real tools or prove a model selected them. The fake duration scenario proves the subprocess and persistence contract without executing a command.
- The cursor-stability and replacement-view tests use synthetic chat buffers. They do not provide fake-subprocess or PNG evidence.
- PNG capture requires `x-export-frames`. Missing PNGs make a screenshot requirement blocked even when the assertions pass.
- Judge output within its owning block. A matching string elsewhere in the transcript is not evidence.
- Only bash and subagent show inline duration rows. Read, edit, write, and other tools stay quiet. Missing recorded values stay quiet rather than falling back to the local clock.
- A narrow sibling can stack a shared footer in wider sibling windows too. Each duration still aligns to its own window's right edge.
- The details journey uses synthetic saved tool data inside a live fake-backed chat. Unit and fake-backed tests separately check live and recorded timing, the absence of custom metadata from native hover properties, and native-help coexistence. Headless PGTK cannot prove physical hover.
