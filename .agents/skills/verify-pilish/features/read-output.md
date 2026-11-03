# Read streamed output

The chat renders streamed Markdown, reveals or hides its source markup on demand, and changes thinking display without losing the reader's place. It preserves reading positions, follows the tail on request, and rewraps hot tables after a resize. Completed thinking uses a margin caret and TAB; thinking shorter than `pilish-thinking-fold-min-lines` non-blank lines stays expanded without a caret. Long tool output uses bottom continuation controls. Bash and subagent footers, including resumed subagent calls, show live elapsed time, then Pi's recorded duration when available. A settled run adds a transient right-aligned return timestamp and whole-run duration. Completed replies, thinking, and tools expose literal details through explicit Help and echo-area commands. This metadata does not appear on automatic hover; other hover behavior is unchanged.

## Sub-features

- `output-stream` renders streamed write-tool content without exposing fence markers.
- `output-markup` reveals emphasis delimiters and link destinations, then hides them again.
- `output-thinking` changes completed thinking display in two windows and toggles one block with its caret or TAB.
- `output-short-thinking` keeps a short thinking summary expanded and caretless in hidden display, while longer thinking collapses.
- `output-duration` advances live bash and subagent timing, including resumed calls, then restores the same recorded duration after reload or resume.
- `output-return-receipt` records when the current run returned control and its total observed duration, aligns the receipt in unequal windows, retains earlier receipts, and omits them after reload or resume.
- `output-scroll` preserves a scrolled-back view while output arrives and keeps tail-following windows at the end.
- `output-table` rewraps a hot table after a frame resize.
- `output-table-kill` keeps the cursor at the visual end of a wrapped row after `C-k`.
- `output-block-details` inspects completed reply, thinking, and tool details without changing the session or draft.
- `output-link-copy` copies a URL destination or a shell-local file path from a chat link with `w`.
- `output-image-before-gui` displays images prepared before a graphical client connects, without a history reload.

## How to get to it (user POV)

- Read write-tool content as it streams into the chat.
- Press `C-c C-p v` in a live chat to show or hide Markdown source through the menu.
- Run `M-x pilish-toggle-thinking-display` to change completed thinking display.
- Press `TAB` inside completed thinking or click its left-margin caret. Press `TAB` or `RET` on a tool footer, or click its left-margin caret.
- Watch `Elapsed` advance during bash or subagent execution, including resumed calls, and change to `Took …` on completion. Live labels use whole seconds below a minute and minutes or hours above it.
- When Pi returns control, read the right-aligned `Returned YYYY-MM-DD HH:MM · Took …` receipt below the run. Below a minute it shows one decimal, like recorded tool times. The neutral receipt also follows aborted and failed runs. Continue with another prompt to retain separate receipts. Reload or resume to omit these transient observations while keeping recorded tool durations.
- Scroll back with ordinary Emacs scrolling commands while new output arrives.
- Stay at the stream tail across consecutive turns.
- Resize the frame while viewing a table in recent history.
- Press `C-k` on a wrapped table row in the read-only chat.
- In a live chat, place point on a completed reply, thinking block, or tool block and press `C-c C-p d` to open its details in standard Help. In a saved snapshot, run `M-x pilish-describe-reply`.
- Press `C-h .` for an echo-area peek. Native link and control help keeps priority.
- Place point on a Markdown link label and press `w` to copy the URL destination, or the shell-local path for a local file link.
- Press `q` in Help to return to the chat or saved snapshot.
- Open a chat prepared before a graphical client connected. Its image previews appear without a tool toggle or history reload; terminal frames keep the labels.
- Native chat links and controls retain their hover help and click actions. Input headers, browsers, and menus keep their existing hover behavior.

## Driving it with Pilish harnesses

Preconditions:

- The Doctor check passed. `RUN_DIR` is a new empty evidence directory.

- **Stream Markdown.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-streaming-no-fences 2>&1 | tee "$RUN_DIR/stream.log"`. Record `stream.exit`. The rendered write-tool content contains no Markdown fence markers.
- **Toggle Markdown markup.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-markup-toggle-through-menu 2>&1 | tee "$RUN_DIR/markup.log"`. Record `markup.exit`. Real `C-c C-p v` key sequences reveal bold delimiters and a link destination, then restore the hidden-markup display without changing the source text.
- **Toggle thinking.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-thinking-display-toggle-restores-each-visible-window 2>&1 | tee "$RUN_DIR/thinking.log"`. Record `thinking.exit`. The tail keeps following output while the scrolled-back window preserves its context.
- **Keep short thinking expanded.** Run `G1_CAPTURE="$RUN_DIR/short-thinking" ./test/run-gui-tests.sh --headless pilish-gui-test-short-thinking-stays-visible-without-caret 2>&1 | tee "$RUN_DIR/short-thinking.log"`. Record `short-thinking.exit`. In hidden display a one-line summary stays readable with no margin caret, and `TAB` on it reaches the turn outline without changing the buffer, while three-line thinking collapses to a stub with a caret. Check the PNG and matching Elisp captures under `$RUN_DIR/short-thinking`.
- **Start thinking with whitespace.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-thinking-initial-whitespace-keeps-point 2>&1 | tee "$RUN_DIR/thinking-initial.log"`. Record `thinking-initial.exit`. Initial whitespace and the first visible text leave point at its original position.
- **Scroll back.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-scroll-preserved-streaming 2>&1 | tee "$RUN_DIR/scroll.log"`. Record `scroll.exit`. Streaming does not pull the scrolled-back window to the tail.
- **Follow the tail.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-scroll-auto-when-at-end 2>&1 | tee "$RUN_DIR/tail.log"`. Record `tail.exit`. Consecutive turns leave window point and the viewport at the end.
- **Grow a full tail by one line.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-append-keeps-tail-filled 2>&1 | tee "$RUN_DIR/append.log"`. Record `append.exit`. Then run `./test/run-gui-tests.sh --headless pilish-gui-test-streaming-delta-keeps-tail-filled 2>&1 | tee "$RUN_DIR/delta.log"` and record `delta.exit`. Both cases leave the new end visible and the window substantially filled instead of recentering it into an empty lower half.
- **Resize a table.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-table-resize-refreshes-hot-tail-only 2>&1 | tee "$RUN_DIR/table.log"`. Record `table.exit`. The hot table rewraps and its surrounding content survives.
- **Kill part of a wrapped table row.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-table-kill-line-moves-cursor-to-visual-end 2>&1 | tee "$RUN_DIR/table-kill.log"`. Record `table-kill.exit`. Ordinary `C-k` copies the same source text, leaves canonical text unchanged, keeps point at raw end-of-line, and places the visible cursor on the last continuation line.
- **Inspect completed blocks.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-reply-details-keyboard-help-and-safe-quit 2>&1 | tee "$RUN_DIR/reply-details.log"`. Record `reply-details.exit`. Real `C-h .` and `C-c C-p d` inspect a fake reply, synthetic completed thinking before and after `TAB`, and a synthetic tool before and after output folds and cooling. The reply opens selected read-only Help both fresh and in an existing Help window. Reports contain metadata, not private thinking or tool output. `q` returns to the chat with the same live process, draft, and session-file bytes.
- **Observe duration and restoration.** Run `G1_CAPTURE="$RUN_DIR/duration" ./test/run-gui-tests.sh --headless pilish-gui-test-fake-duration-live-reload-and-resume 2>&1 | tee "$RUN_DIR/duration.log"`. Record `duration.exit`. The fake bash stream advances through real `Elapsed` timers, settles on `Took 2m 5s`, and keeps that recorded value through bottom-control actions, browser resume, and process reload. The final timer stays stopped.
- **Read run-return receipts.** Run `G1_CAPTURE="$RUN_DIR/return-receipt" ./test/run-gui-tests.sh --headless pilish-gui-test-run-return-receipt-responsive-and-transient 2>&1 | tee "$RUN_DIR/return-receipt.log"`. Record `return-receipt.exit`. The test sends through `C-c C-c`, checks the recorded tool duration and the receipt's own label, aligns the receipt at 104 and 54 columns and in unequal sibling windows, sends a second run, then reloads. The two live receipts remain in order until reload; recorded tool time survives it, but return receipts do not.
- **Copy link targets.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-copy-link-targets-with-w 2>&1 | tee "$RUN_DIR/link-copy.log"`. Record `link-copy.exit`. Real `w` presses on `https:`, `file:`, and absolute-path link labels push the URL, the `file:` URL, and the absolute pathname into the kill ring.
- **Show previously prepared images.** Run `G1_CAPTURE="$RUN_DIR/images" ./test/run-gui-tests.sh --headless pilish-gui-test-image-render-before-graphical-display 2>&1 | tee "$RUN_DIR/images.log"`. Record `images.exit`. With graphical-window detection temporarily disabled, real PNG and standalone read-SVG results are prepared in hidden buffers. `switch-to-buffer` then shows the same display specs using real decoders, without a tool toggle or history reload. Require `image-before-gui-png.png`, `image-before-gui-svg.png`, and their matching `.el` files under `$RUN_DIR/images`.
- **Check the proof.** Require zero statuses and nonempty logs for all sixteen commands. Require `fake-duration-elapsed-1.png`, `fake-duration-recorded.png`, `fake-duration-resumed.png`, `fake-duration-reloaded.png`, and their matching `.el` files under `$RUN_DIR/duration`. Under `$RUN_DIR/short-thinking`, require `short-thinking-hidden.png`, `short-thinking-visible.png`, and their matching `.el` files. Under `$RUN_DIR/return-receipt`, require `run-return-wide.png`, `run-return-narrow.png`, `run-return-independent-edges.png`, `run-return-second.png`, `run-return-reloaded.png`, and their matching `.el` files. Use the evidence pattern from the skill.

## Gotchas

- The markup test inserts a deterministic assistant message, then uses the real menu key sequence in both directions. It checks visible-text projections and Markdown properties, not PNG pixels.
- The image journey simulates the absence of graphical windows only while preparing previews; it is not a real daemon/client or terminal-protocol test. It checks both real decoders and the retained display specs. Unit tests separately check that terminal windows never supply pixel dimensions.
- The thinking test invokes the real toggle command directly. Do not describe it as a keystroke test.
- Most tests in this feature assert text, properties, and window state without PNG evidence. The duration, return-receipt and image journeys save the required frames listed above.
- Cold tables intentionally remain unchanged during the hot-tail resize test.
- The table `C-k` test uses a real key sequence and cursor coordinates. It does not save PNG evidence.
- The `details` menu suffix appears only for transcript-origin menus. It does not appear in the input-origin menu.
- Completed replies, thinking, and tools are inspector targets. Shared headings, outcome notices, unfinished blocks, return receipts, and trailing separators are not targets.
- Receipt geometry is verified at 104 and 54 columns and in unequal sibling windows. Very narrow layouts are outside this recipe.
- Saved reports omit live stream estimates and transient return receipts. Saved tool results with `durationMs` restore recorded execution times. The saved-conversations recipe drives the snapshot inspector.
- A return receipt measures local wall-clock observation from the first `agent_start` through accepted `agent_settled`, not Pi's monotonic tool clock. The fake scenario paces both clocks but executes no real tool.
- Unit tests check that custom metadata is absent from native hover properties, native chat help still works, and provisional thinking details survive finalization. These keyboard journeys do not prove physical PGTK hover.
