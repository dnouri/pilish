# Browse and resume sessions

The session and tree browsers support native folding, searching, copying, and scrolling. The session browser can resume a selected saved session and rebuild its history.

## Sub-features

- `session-browser` folds, searches, copies, and scrolls saved-session rows. Opening gathers metadata only. The first valid nonblank search gathers full text asynchronously; later queries reuse it, and refreshes and scope changes keep collecting it until buffer death or mode reset.
- `tree-browser` applies the same native actions to projected conversation nodes.
- `session-resume` selects a saved session in the real browser, invokes its switch command, and rebuilds the chat history.
- `background-start` starts a new and a resumed session with `pilish-start-session`. Neither changes the window layout or sends a prompt; `pilish` with the name later shows the resumed history.

## How to get to it (user POV)

- Use the margin, `TAB`, `S-TAB`, `/`, `M-w`, and ordinary scrolling in an open session or tree browser.
- Select a saved session and run `M-x pilish-session-browser-switch` to resume it.
- Call `pilish-start-session` from Lisp, then show the session with `C-u M-x pilish`.

## Driving it with Pilish harnesses

Preconditions:

- The Doctor check passed. `RUN_DIR` is a new empty evidence directory.

- **Drive both browsers.** Run `G1_CAPTURE="$RUN_DIR/browser-capture" ./test/run-gui-tests.sh --headless pilish-gui-test-large-browser-fold-and-copy 2>&1 | tee "$RUN_DIR/browsers.log"`. Record `browsers.exit`. Both browser modes preserve canonical folds, copied text, search state, and viewport behavior.
- **Search saved text for the first time.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-session-browser-first-search-from-disk 2>&1 | tee "$RUN_DIR/first-search.log"`. Record `first-search.exit`. Opening has no search corpus; `/` finds late saved text, a later missing query shows no matches, and clearing then refreshing retains full text.
- **Resume through the browser.** Run `./bench/run-reload-resume-bench.sh --scenario smoke -c 1 --out-dir "$RUN_DIR/reload-resume" 2>&1 | tee "$RUN_DIR/resume.log"`. Record `resume.exit`. The resume lane selects the target section, calls `pilish-session-browser-switch`, and checks rebuilt history.
- **Start sessions in the background.** Run `G1_CAPTURE="$RUN_DIR/background-capture" ./test/run-gui-tests.sh --headless pilish-gui-test-background-session-start-and-resume 2>&1 | tee "$RUN_DIR/background.log"`. Record `background.exit`. The layout and selected window stay unchanged, the background processes send no `prompt`, and the resumed chat shows the saved prompt once displayed. Require `.png` and `.el` files for `background-layout-unchanged` and `background-resumed-shown`.
- **Check the proof.** Require zero statuses and nonempty logs. Require `.png` and `.el` files for `browser-pilish-session-browser-mode-folded`, `browser-pilish-session-browser-mode-unfolded`, `browser-pilish-tree-browser-mode-folded`, and `browser-pilish-tree-browser-mode-unfolded` under `$RUN_DIR/browser-capture`. Require at least one nonempty `result.json` under `$RUN_DIR/reload-resume`.

## Gotchas

- The large browser scenario uses 2,000 synthetic rows in each browser. It enters the modes directly with session search already enabled and does not prove first-search disk loading or resume those rows.
- PNG capture requires `x-export-frames`. Missing PNGs make the screenshot requirement blocked even when the assertions pass.
- The resume bench calls `pilish-session-browser-switch` directly. These recipes do not cover the `C-c C-r`, `/resume`, or `C-c C-p w` opening aliases, or `RET` key dispatch.
- The background journey passes no per-session arguments or environment, because the fake accepts no extra arguments. Unit tests prove both at the process boundary.
- The reload and resume scenario proves correctness only. Do not cite its timings as a performance result.
- The benchmark runner replaces its marked output directory on a later run. Always give it a new feature-owned directory.
