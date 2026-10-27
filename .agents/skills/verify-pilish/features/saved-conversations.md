# Open saved conversations

A saved Pi conversation opens in an independent read-only observer. Manual refresh handles unchanged, changed, and invalid files without taking over the parent session. Completed replies, thinking, and tools have explicit metadata inspection instead of automatic metadata hover. Native hover help is unchanged.

## Sub-features

- `saved-open` opens a linked child conversation in another window.
- `saved-quit` closes only the observer and preserves the parent and draft.
- `saved-refresh` rereads unchanged and changed files with native `g`.
- `saved-failure` retains the last good observer when the saved file becomes invalid.
- `saved-block-details` shows saved reply, thinking, and tool details through quick help or Help and returns to the observer.

## How to get to it (user POV)

- Move to a saved-conversation link with `C-c ]` and press `RET`.
- Press `g` in the observer to reread its saved file.
- Place point on a completed reply, thinking block, or tool block and run `M-x pilish-describe-reply` to inspect its saved details. No snapshot menu is added.
- Press `C-h .` for quick help in the echo area. Native link and control help keeps priority.
- Press `q` in Help to return to the observer. Press `q` in the observer to close it.

## Driving it with Pilish harnesses

Preconditions:

- The Doctor check passed. `RUN_DIR` is a new empty evidence directory.

- **Open, inspect, and quit.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-snapshot-keyboard-other-window 2>&1 | tee "$RUN_DIR/open.log"`. Record `open.exit`. Native `C-h .` describes the session link and `RET` opens a read-only observer in another window. Real `C-h .` and `M-x pilish-describe-reply` inspect saved reply, thinking, and tool details. Help is selected and read-only. Reports omit live measurements and private content. Each Help `q` returns to the observer. The final `q` closes only that observer. The parent process, draft, and saved-file bytes survive.
- **Refresh and fail safely.** Run `G1_CAPTURE="$RUN_DIR/capture" ./test/run-gui-tests.sh --headless pilish-gui-test-large-snapshot-refresh 2>&1 | tee "$RUN_DIR/refresh.log"`. Record `refresh.exit`. Native `g` preserves an unchanged view, publishes changed content to two windows, and retains the last good content after a failed read.
- **Check the proof.** Require zero statuses and nonempty logs. Require `observer-104-unchanged.png`, `observer-54-unchanged.png`, `observer-changed.png`, `observer-failed.png`, and their matching `.el` files under `$RUN_DIR/capture`. Use `test -s` for every file.

## Gotchas

- `pilish-open-session-file` resumes a live session. It is not the observer entry point covered here.
- The observer reads valid Pi-v3 fixture records. It does not infer a child from a tool name or output text. It shows saved data, not unsaved parent output.
- All saved block reports use detached metadata and need no live observer process. They omit live stream estimates and tool execution times.
- Native control help retains priority for `C-h .` and keeps its hover properties. Unit tests check that custom block metadata is absent from native hover properties. The headless keyboard journey does not prove physical PGTK hover.
- PNG capture requires `x-export-frames`. A test pass without the required PNGs does not satisfy a screenshot claim.
