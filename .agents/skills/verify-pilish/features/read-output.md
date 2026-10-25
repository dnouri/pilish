# Read streamed output

The chat renders streamed Markdown and changes thinking display without losing the reader's place. It preserves reading positions, follows the tail on request, and rewraps hot tables after a resize.

## Sub-features

- `output-stream` renders streamed write-tool content without exposing fence markers.
- `output-thinking` changes completed thinking display in two windows.
- `output-scroll` preserves a scrolled-back view while output arrives and keeps tail-following windows at the end.
- `output-table` rewraps a hot table after a frame resize.

## How to get to it (user POV)

- Read write-tool content as it streams into the chat.
- Run `M-x pilish-toggle-thinking-display` to change completed thinking display.
- Scroll back with ordinary Emacs scrolling commands while new output arrives.
- Stay at the stream tail across consecutive turns.
- Resize the frame while viewing a table in recent history.

## Driving it with Pilish harnesses

Preconditions:

- The Doctor check passed. `RUN_DIR` is a new empty evidence directory.

- **Stream Markdown.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-streaming-no-fences 2>&1 | tee "$RUN_DIR/stream.log"`. Record `stream.exit`. The rendered write-tool content contains no Markdown fence markers.
- **Toggle thinking.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-thinking-display-toggle-restores-each-visible-window 2>&1 | tee "$RUN_DIR/thinking.log"`. Record `thinking.exit`. The tail keeps following output while the scrolled-back window preserves its context.
- **Scroll back.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-scroll-preserved-streaming 2>&1 | tee "$RUN_DIR/scroll.log"`. Record `scroll.exit`. Streaming does not pull the scrolled-back window to the tail.
- **Follow the tail.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-scroll-auto-when-at-end 2>&1 | tee "$RUN_DIR/tail.log"`. Record `tail.exit`. Consecutive turns leave window point and the viewport at the end.
- **Resize a table.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-table-resize-refreshes-hot-tail-only 2>&1 | tee "$RUN_DIR/table.log"`. Record `table.exit`. The hot table rewraps and its surrounding content survives.
- **Check the proof.** Require zero statuses and nonempty logs for all five commands. Use the evidence pattern from the skill.

## Gotchas

- The thinking test invokes the real toggle command directly. Do not describe it as a keystroke test.
- These tests assert text, properties, and window state. They do not save PNG evidence.
- Cold tables intentionally remain unchanged during the hot-tail resize test.
