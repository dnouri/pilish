# Browse and resume sessions

The session and tree browsers support native folding, searching, copying, and scrolling. The session browser can resume a selected saved session and rebuild its history.

## Sub-features

- `session-browser` folds, searches, copies, and scrolls saved-session rows. Opening gathers metadata only. The first valid nonblank search gathers full text asynchronously; later queries reuse it, and refreshes and scope changes keep collecting it until buffer death or mode reset.
- `sessions-dir-env` selects a nonempty `PI_CODING_AGENT_SESSION_DIR` as flat local storage without a linked chat. Current project filters by saved cwd; All projects lists only that custom directory, not the default archive tree.
- `tree-browser` applies the same native actions to projected conversation nodes.
- `session-resume` selects a saved session in the real browser, invokes its switch command, and rebuilds the chat history.
- `session-state-ownership` keeps a newly selected session's identity and header state when an older startup or thinking-level state response arrives.
- `background-start` starts a new and a resumed session with `pilish-start-session`. Neither changes the window layout or sends a prompt; `pilish-show-session` later shows the resumed history.

## How to get to it (user POV)

- Use the margin, `TAB`, `S-TAB`, `/`, `M-w`, and ordinary scrolling in an open session or tree browser.
- Export `PI_CODING_AGENT_SESSION_DIR`, open `M-x pilish-session-browser` from a local project without starting Pi, and press `t` for All projects.
- Select a saved session and run `M-x pilish-session-browser-switch` to resume it.
- Use `C-c C-n` for a new session while a background state query is outstanding.
- Call `pilish-start-session` from Lisp, then show the session with `pilish-show-session`.

## Driving it with Pilish harnesses

Preconditions:

- The Doctor check passed. `RUN_DIR` is a new empty evidence directory.

- **Drive both browsers.** Run `G1_CAPTURE="$RUN_DIR/browser-capture" ./test/run-gui-tests.sh --headless pilish-gui-test-large-browser-fold-and-copy 2>&1 | tee "$RUN_DIR/browsers.log"`. Record `browsers.exit`. Both browser modes preserve canonical folds, copied text, search state, and viewport behavior.
- **Browse environment-selected storage without a chat.** Run `G1_CAPTURE="$RUN_DIR/env-capture" ./test/run-gui-tests.sh --headless pilish-gui-test-session-browser-env-directory-without-chat 2>&1 | tee "$RUN_DIR/env-browser.log"`. Record `env-browser.exit`. Native `M-x pilish-session-browser` shows only the current cwd's custom-directory session; native `t` shows both custom-directory projects and excludes the default-tree decoy. Both observations require no linked chat and no process start. Require `env-browser-current` and `env-browser-all` `.el` and `.png` files under `$RUN_DIR/env-capture`.
- **Search saved text for the first time.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-session-browser-first-search-from-disk 2>&1 | tee "$RUN_DIR/first-search.log"`. Record `first-search.exit`. Opening has no search corpus; `/` finds late saved text, a later missing query shows no matches, and clearing then refreshing retains full text.
- **Resume through the browser.** Run `./bench/run-reload-resume-bench.sh --scenario smoke -c 1 --out-dir "$RUN_DIR/reload-resume" 2>&1 | tee "$RUN_DIR/resume.log"`. Record `resume.exit`. The resume lane selects the target section, calls `pilish-session-browser-switch`, and checks rebuilt history.
- **Keep the switched session current.** Run `G1_CAPTURE="$RUN_DIR/state-capture" ./test/run-gui-tests.sh --headless pilish-gui-test-session-switch-ignores-delayed-state 2>&1 | tee "$RUN_DIR/state-ownership.log"`. Record `state-ownership.exit`. Two native `C-c C-n` actions retain their current saved file and header state when older startup/thinking replies are released; the final prompt still receives a reply and preserves the unsent draft. Require `delayed-startup-state`, `delayed-thinking-state` and `switched-session-current` `.el` and `.png` evidence under `$RUN_DIR/state-capture`.
- **Start sessions in the background.** Run `G1_CAPTURE="$RUN_DIR/background-capture" ./test/run-gui-tests.sh --headless pilish-gui-test-background-session-start-and-resume 2>&1 | tee "$RUN_DIR/background.log"`. Record `background.exit`. The layout and selected window stay unchanged, the background processes send no `prompt`, and the resumed chat shows the saved prompt once displayed. Require `.png` and `.el` files for `background-layout-unchanged` and `background-resumed-shown`.
- **Check the proof.** Require zero statuses and nonempty logs. Require `.png` and `.el` files for `browser-pilish-session-browser-mode-folded`, `browser-pilish-session-browser-mode-unfolded`, `browser-pilish-tree-browser-mode-folded`, and `browser-pilish-tree-browser-mode-unfolded` under `$RUN_DIR/browser-capture`. Require at least one nonempty `result.json` under `$RUN_DIR/reload-resume`.

## Gotchas

- Environment discovery applies only to local cwds; remote projects retain munged per-host storage. An empty variable keeps default storage. Pi's standalone `sessionDir` settings file is still unread without a linked chat. A linked chat's saved-file directory remains authoritative, including for the menu's own session listing; this change does not add settings-file discovery there.
- The env-browser journey uses isolated local JSONL files and never starts Pi; it proves browser discovery and scope filtering, not CLI storage configuration or remote access.
- The state-ownership journey controls delivery of real fake-Pi `get_state` responses to reproduce the interleaving. It calls the background thinking refresh directly; it does not cover the thinking selector's completion UI or claim that Pi replies out of order in every runtime.
- The large browser scenario uses 2,000 synthetic rows in each browser. It enters the modes directly with session search already enabled and does not prove first-search disk loading or resume those rows.
- PNG capture requires `x-export-frames`. Missing PNGs make the screenshot requirement blocked even when the assertions pass.
- The resume bench calls `pilish-session-browser-switch` directly. These recipes do not cover the `C-c C-r`, `/resume`, or `C-c C-p w` opening aliases, or `RET` key dispatch.
- The background journey passes no per-session arguments or environment, because the fake accepts no extra arguments. Unit tests prove both at the process boundary.
- The reload and resume scenario proves correctness only. Do not cite its timings as a performance result.
- The benchmark runner replaces its marked output directory on a later run. Always give it a new feature-owned directory.
