# Open saved conversations

A saved Pi conversation opens in an independent read-only observer. Manual refresh handles unchanged, changed, and invalid files without taking over the parent session.

## Sub-features

- `saved-open` opens a linked child conversation in another window.
- `saved-quit` closes only the observer and preserves the parent and draft.
- `saved-refresh` rereads unchanged and changed files with native `g`.
- `saved-failure` retains the last good observer when the saved file becomes invalid.

## How to get to it (user POV)

- Move to a saved-conversation link with `C-c ]` and press `RET`.
- Press `g` in the observer to reread its saved file.
- Press `q` in the observer to close it.

## Driving it with Pilish harnesses

Preconditions:

- The Doctor check passed. `RUN_DIR` is a new empty evidence directory.

- **Open and quit.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-snapshot-keyboard-other-window 2>&1 | tee "$RUN_DIR/open.log"`. Record `open.exit`. Native `RET` opens a read-only observer in another window, and native `q` closes only that observer. The parent process and unsent draft survive.
- **Refresh and fail safely.** Run `G1_CAPTURE="$RUN_DIR/capture" ./test/run-gui-tests.sh --headless pilish-gui-test-large-snapshot-refresh 2>&1 | tee "$RUN_DIR/refresh.log"`. Record `refresh.exit`. Native `g` preserves an unchanged view, publishes changed content to two windows, and retains the last good content after a failed read.
- **Check the proof.** Require zero statuses and nonempty logs. Require `observer-104-unchanged.png`, `observer-54-unchanged.png`, `observer-changed.png`, `observer-failed.png`, and their matching `.el` files under `$RUN_DIR/capture`. Use `test -s` for every file.

## Gotchas

- `pilish-open-session-file` resumes a live session. It is not the observer entry point covered here.
- The observer reads valid Pi-v3 fixture records. It does not infer a child from a tool name or output text. It shows saved data, not unsaved parent output.
- PNG capture requires `x-export-frames`. A test pass without the required PNGs does not satisfy a screenshot claim.
