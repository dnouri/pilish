# Read streamed output

The chat renders streamed Markdown and changes thinking display without losing the reader's place. It preserves reading positions, follows the tail on request, can show a finished turn's final answer from its start, and rewraps hot tables after a resize. Completed replies, thinking, and tools expose literal details through explicit Help and echo-area commands. This metadata does not appear on automatic hover; other hover behavior is unchanged.

## Sub-features

- `output-stream` renders streamed write-tool content without exposing fence markers.
- `output-thinking` changes completed thinking display in two windows.
- `output-scroll` preserves a scrolled-back view while output arrives and keeps tail-following windows at the end.
- `output-jump-to-answer` shows a finished turn's long final answer from its first line when `pilish-jump-to-answer` is on, follows the next turn again, and stays at the end once the session is toggled off.
- `output-table` rewraps a hot table after a frame resize.
- `output-table-kill` keeps the cursor at the visual end of a wrapped row after `C-k`.
- `output-block-details` inspects completed reply, thinking, and tool details without changing the session or draft.

## How to get to it (user POV)

- Read write-tool content as it streams into the chat.
- Run `M-x pilish-toggle-thinking-display` to change completed thinking display.
- Scroll back with ordinary Emacs scrolling commands while new output arrives.
- Stay at the stream tail across consecutive turns.
- Set `pilish-jump-to-answer`, send prompts whose final answers are taller than the chat window, and run `M-x pilish-toggle-jump-to-answer` to turn it off for the session.
- Resize the frame while viewing a table in recent history.
- Press `C-k` on a wrapped table row in the read-only chat.
- In a live chat, place point on a completed reply, thinking block, or tool block and press `C-c C-p d` to open its details in standard Help. In a saved snapshot, run `M-x pilish-describe-reply`.
- Press `C-h .` for an echo-area peek. Native link and control help keeps priority.
- Press `q` in Help to return to the chat or saved snapshot.
- Native chat links and controls retain their hover help and click actions. Input headers, browsers, and menus keep their existing hover behavior.

## Driving it with Pilish harnesses

Preconditions:

- The Doctor check passed. `RUN_DIR` is a new empty evidence directory.

- **Stream Markdown.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-streaming-no-fences 2>&1 | tee "$RUN_DIR/stream.log"`. Record `stream.exit`. The rendered write-tool content contains no Markdown fence markers.
- **Toggle thinking.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-thinking-display-toggle-restores-each-visible-window 2>&1 | tee "$RUN_DIR/thinking.log"`. Record `thinking.exit`. The tail keeps following output while the scrolled-back window preserves its context.
- **Start thinking with whitespace.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-thinking-initial-whitespace-keeps-point 2>&1 | tee "$RUN_DIR/thinking-initial.log"`. Record `thinking-initial.exit`. Initial whitespace and the first visible text leave point at its original position.
- **Scroll back.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-scroll-preserved-streaming 2>&1 | tee "$RUN_DIR/scroll.log"`. Record `scroll.exit`. Streaming does not pull the scrolled-back window to the tail.
- **Follow the tail.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-scroll-auto-when-at-end 2>&1 | tee "$RUN_DIR/tail.log"`. Record `tail.exit`. Consecutive turns leave window point and the viewport at the end.
- **Grow a full tail by one line.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-append-keeps-tail-filled 2>&1 | tee "$RUN_DIR/append.log"`. Record `append.exit`. Then run `./test/run-gui-tests.sh --headless pilish-gui-test-streaming-delta-keeps-tail-filled 2>&1 | tee "$RUN_DIR/delta.log"` and record `delta.exit`. Both cases leave the new end visible and the window substantially filled instead of recentering it into an empty lower half.
- **Jump to the answer.** Run `G1_CAPTURE="$RUN_DIR/capture" ./test/run-gui-tests.sh --headless pilish-gui-test-jump-to-answer-lands-on-final-answer 2>&1 | tee "$RUN_DIR/jump-to-answer.log"`. Record `jump-to-answer.exit`. After each of two turns with a tool call and an 80-line answer, the chat window's start and point are the answer's first line. After the toggle command, the third turn leaves point and the viewport at the end. Check `test -s "$RUN_DIR/capture/jump-to-answer-first.el"` and `test -s "$RUN_DIR/capture/jump-to-answer-second.el"`; the matching PNG files exist when `x-export-frames` is available.
- **Resize a table.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-table-resize-refreshes-hot-tail-only 2>&1 | tee "$RUN_DIR/table.log"`. Record `table.exit`. The hot table rewraps and its surrounding content survives.
- **Kill part of a wrapped table row.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-table-kill-line-moves-cursor-to-visual-end 2>&1 | tee "$RUN_DIR/table-kill.log"`. Record `table-kill.exit`. Ordinary `C-k` copies the same source text, leaves canonical text unchanged, keeps point at raw end-of-line, and places the visible cursor on the last continuation line.
- **Inspect completed blocks.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-reply-details-keyboard-help-and-safe-quit 2>&1 | tee "$RUN_DIR/reply-details.log"`. Record `reply-details.exit`. Real `C-h .` and `C-c C-p d` inspect a fake reply, synthetic completed thinking before and after `TAB`, and a synthetic tool before and after output folds and cooling. The reply opens selected read-only Help both fresh and in an existing Help window. Reports contain metadata, not private thinking or tool output. `q` returns to the chat with the same live process, draft, and session-file bytes.
- **Check the proof.** Require zero statuses and nonempty logs for all eleven commands. Use the evidence pattern from the skill.

## Gotchas

- The thinking test invokes the real toggle command directly. Do not describe it as a keystroke test.
- These tests assert text, properties, and window state. Only the jump-to-answer test saves PNG evidence, and only with `G1_CAPTURE`.
- The jump-to-answer test sends prompts with the real send command but runs the toggle with `call-interactively`, not a keystroke. Scrolled-back windows, short answers, stopped turns, and windows shown later are covered by `make test-answer`, not by a GUI journey.
- Cold tables intentionally remain unchanged during the hot-tail resize test.
- The table `C-k` test uses a real key sequence and cursor coordinates. It does not save PNG evidence.
- The `details` menu suffix appears only for transcript-origin menus. It does not appear in the input-origin menu.
- Completed replies, thinking, and tools are inspector targets. Shared headings, outcome notices, unfinished blocks, and trailing separators are not targets.
- Saved reports omit live stream estimates and tool execution times. The saved-conversations recipe drives the snapshot inspector.
- Unit tests check that custom metadata is absent from native hover properties, native chat help still works, and provisional thinking details survive finalization. These keyboard journeys do not prove physical PGTK hover.
