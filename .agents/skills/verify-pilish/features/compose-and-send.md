# Compose and send

Pilish opens a chat and input pair, then sends consecutive prompts without losing the later submission. With a fitted input height, the input window follows the draft.

## Sub-features

- `compose-layout` opens a live session with chat and input windows.
- `compose-header` renders the session header line at the top of the chat window by default, keeps it out of the input window, moves it between the live windows when `pilish-header-line-location` is set to `input`, and removes it from both windows when set to `none`.
- `compose-status-clicks` sends model and thinking actions to the clicked session, including an input window linked to that session, without changing the selected window. Keyboard commands still act on the selected session.
- `compose-header-metadata` updates the header line's session name and thinking level when Pi reports a change Pilish did not request, such as an extension renaming the session or raising the thinking level.
- `compose-send` submits a prompt and displays its reply.
- `compose-sequential` submits a second prompt after the first turn and returns to idle.
- `compose-send-while-busy` steers the running turn with `C-c C-c` when `pilish-send-while-busy` is `steer`, and queues a follow-up with Alt+Enter (`M-RET`, `pilish-queue-followup`) that Pilish sends as the next prompt after the run returns control.
- `compose-fit-input` sizes a `fit` input window to the typed draft, stops at its cap, refits on frame-width changes, and shrinks after sending.
- `compose-fit-display` preserves a fitted draft when reopening the input, hides after sending in both `on-demand` and `hidden` styles, and reopens empty at one text line. Pressing `i` in the chat window opens or focuses the input in every display style, without the Evil integration.
- `compose-submit-to-end` returns a scrolled-back chat to its end when a draft is submitted with `pilish-jump-to-end-on-submit` non-nil, keeping input focus. Typing alone leaves the chat where it is. With the default nil, the reader keeps its position, as the scroll-preservation tests assert.

## How to get to it (user POV)

- Run `M-x pilish` from a project directory.
- Read the model, thinking level, activity, cost, and context status in the header line above the chat, and click model or thinking level there.
- Set `pilish-header-line-location` to `input` to move the header line above the input window, as in earlier Pilish versions, or to `none` to remove it, in existing sessions without restarting them.
- Enter a prompt in the input buffer and press `C-c C-c`.
- Enter and send another prompt after the first reply.
- Set `pilish-send-while-busy` to `steer`. While Pi replies, type text and press `C-c C-c` to steer, then type more and press Alt+Enter to queue a follow-up.
- Set the global `pilish-input-window-height` option to `fit`, type a multi-line draft, resize the frame, and press `C-c C-c`.
- Set `pilish-input-window-display` to `on-demand` or `hidden`. Press `i` in the chat window (or run `M-x pilish-open-input`) to compose or reopen the input after sending.
- Set `pilish-jump-to-end-on-submit` to `t`, scroll the chat back to earlier text, type a draft, and press `C-c C-c`.

## Driving it with Pilish harnesses

Preconditions:

- The Doctor check passed. `RUN_DIR` is a new empty evidence directory.

- **Open the session.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-session-starts 2>&1 | tee "$RUN_DIR/layout.log"`. Record `layout.exit`. A passing, non-skipped result proves the fake process and stacked chat and input windows.
- **Place the header line.** Run `G1_CAPTURE="$RUN_DIR/header" ./test/run-gui-tests.sh --headless pilish-gui-test-session-header-line-lives-in-chat-window 2>&1 | tee "$RUN_DIR/header.log"`. Record `header.exit`. The test starts a session, asserts the header line renders in the chat window and not the input window, sets `pilish-header-line-location` to `input` through the Customize setter, and asserts the header line moved to the input window in the same live session. It then sets `none` and asserts both windows lose the header. It writes `header-in-chat` and `header-in-input` observations and PNG frames; `none` is an assertion-only state.
- **Route status actions.** Run `make test-input SELECTOR=header-click 2>&1 | tee "$RUN_DIR/status-routing.log"`. Record `status-routing.exit`. These batch tests pass synthetic events naming session B while A is selected, check both fields and mouse buttons in header and mode lines, check linked input routing, and invoke the keyboard commands from A. They assert the RPC target and restored selection. Native dispatch needs a separate X11/Xvfb pointer pass: keep A selected, click B's model and thinking fields with buttons 1 and 2, record B at command entry and the RPC boundary, and check that selection returns to A. Preserve the driver, logs, exit status, and frame captures. The batch tests alone do not prove native dispatch.
- **Follow Pi's metadata changes.** Run `G1_CAPTURE="$RUN_DIR/metadata" ./test/run-gui-tests.sh --headless pilish-gui-test-extension-session-metadata-updates-header 2>&1 | tee "$RUN_DIR/metadata.log"`. Record `metadata.exit`. The test sends the fake extension command `/test-session-metadata` from the input window. Pi's `session_info_changed` and `thinking_level_changed` events then show `Named by extension` and `high` in the live chat header. It writes `session-metadata-before` and `session-metadata-after` observations and PNG frames.
- **Send two prompts.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-send-waits-for-turn-start 2>&1 | tee "$RUN_DIR/send.log"`. Record `send.exit`. The test sends through `pilish-send`, displays the fake reply to the second prompt, and returns to idle.
- **Steer and queue while busy.** Run `G1_CAPTURE="$RUN_DIR/busy" ./test/run-gui-tests.sh --headless pilish-gui-test-send-while-busy-steers-and-meta-return-queues 2>&1 | tee "$RUN_DIR/busy.log"`. Record `busy.exit`. With `pilish-send-while-busy` set to `steer`, the test types a prompt and sends it with real keys, waits for streaming, steers with `C-c C-c` and queues a follow-up with `M-<return>`. It asserts the steering left no local follow-up, the follow-up is queued, the steering and its reply precede the first run's return receipt, and the follow-up starts the next run. It writes `busy-sends` and `after-run` observations and PNG frames.
- **Fit the input to a draft.** Run `G1_CAPTURE="$RUN_DIR/fit" ./test/run-gui-tests.sh --headless pilish-gui-test-input-window-fits-draft 2>&1 | tee "$RUN_DIR/fit.log"`. Record `fit.exit`. The test types three lines and then more lines than the cap with real keys, sends with `C-c C-c`, and asserts one draft line at start, three lines, the capped height ending at point's line, and one line after the reply. It writes `fit-empty`, `fit-three-lines`, `fit-capped`, and `fit-after-send` observations and PNG frames.
- **Resize an unchanged draft.** Run `G1_CAPTURE="$RUN_DIR/resize" ./test/run-gui-tests.sh --headless pilish-gui-test-input-fit-refits-on-frame-resize 2>&1 | tee "$RUN_DIR/resize.log"`. Record `resize.exit`. The graphical frame changes from 104 to 54 columns and back. Without another edit, the same draft grows from two to four text rows and returns to two. It writes `fit-wide`, `fit-narrow`, and `fit-wide-again` observations and PNG frames.
- **Compose on demand.** Run `G1_CAPTURE="$RUN_DIR/display" ./test/run-gui-tests.sh --headless pilish-gui-test-input-fit-with-hide-after-send 2>&1 | tee "$RUN_DIR/display.log"`. Record `display.exit`. The test checks both display styles at launch, closes and reopens a three-line draft with keys, sends with `C-c C-c`, verifies the input disappears, and reopens an empty one-line input by pressing `i` in the chat window. It writes `fit-on-demand-draft`, `fit-on-demand-sent`, `fit-on-demand-reopened`, and the corresponding `fit-hidden-*` observations and PNG frames.
- **Submit while reading earlier text.** Run `G1_CAPTURE="$RUN_DIR/submit" ./test/run-gui-tests.sh --headless pilish-gui-test-submit-returns-chat-to-end 2>&1 | tee "$RUN_DIR/submit.log"`. Record `submit.exit`. With `pilish-jump-to-end-on-submit` on, the test scrolls the chat back, types a draft with real keys and asserts the chat's top line is unchanged, then presses `C-c C-c`. It asserts that the input keeps focus and is empty, and that the chat window is at its end showing the fake reply. It writes `submit-draft-while-reading` and `submit-returned-to-end` observations and PNG frames. `make test-input SELECTOR='submit\|queued-delivery'` covers steering, follow-ups, refused or empty drafts, automatic queue delivery, hidden chats and the default.
- **Check the logs.** Require zero statuses, `PASS: TEST-NAME` for each named test, and `0 skipped` in every log. For each stem `layout`, `header`, `metadata`, `send`, `busy`, `fit`, `resize`, `display`, and `submit`, run `test "$(cat "$RUN_DIR/STEM.exit")" -eq 0` and `test -s "$RUN_DIR/STEM.log"`, replacing `STEM` with the stem.
- **Check the captures.** Run `test -s "$RUN_DIR/header/header-in-chat.el"`, `test -s "$RUN_DIR/header/header-in-chat.png"`, `test -s "$RUN_DIR/header/header-in-input.el"`, `test -s "$RUN_DIR/header/header-in-input.png"`, `test -s "$RUN_DIR/metadata/session-metadata-after.el"`, `test -s "$RUN_DIR/metadata/session-metadata-after.png"`, `test -s "$RUN_DIR/busy/busy-sends.el"`, `test -s "$RUN_DIR/busy/after-run.el"`, `test -s "$RUN_DIR/busy/after-run.png"`, `test -s "$RUN_DIR/fit/fit-capped.el"`, `test -s "$RUN_DIR/fit/fit-capped.png"`, `test -s "$RUN_DIR/resize/fit-narrow.el"`, `test -s "$RUN_DIR/resize/fit-narrow.png"`, `test -s "$RUN_DIR/resize/fit-wide-again.el"`, `test -s "$RUN_DIR/resize/fit-wide-again.png"`, `test -s "$RUN_DIR/display/fit-on-demand-reopened.el"`, `test -s "$RUN_DIR/display/fit-on-demand-reopened.png"`, `test -s "$RUN_DIR/display/fit-hidden-reopened.el"`, `test -s "$RUN_DIR/display/fit-hidden-reopened.png"`, `test -s "$RUN_DIR/submit/submit-draft-while-reading.png"`, and `test -s "$RUN_DIR/submit/submit-returned-to-end.png"`.

## Gotchas

- Native XTest pointer injection is not physical mouse input. A recorded RPC boundary proves routing, not a provider request or completed model selection.
- The fake supplies deterministic replies. It does not prove provider authentication or model output.
- The metadata journey replays the events an extension's `pi.setSessionName` and `pi.setThinkingLevel` produce; no extension runs. Model-switch clamping emits the same thinking event but is not driven here, because the fake has no model catalog.
- The layout and send tests provide assertion logs, not PNG captures. The header-placement and fitted-input tests require graphical Emacs with `x-export-frames` for the named PNG proof.
- The header location is a global option; the placement test resets it to `chat` before exiting. A failed run can leave it at `input` or `none`, which changes later sessions' layout in the same Emacs.
- Input height and maximum height are global options, not session-local settings. `fit` may shrink the input below `window-min-height`; the chat window keeps its minimum.
- Edits share a pending fit timer until it runs. Commands that yield may allow several fits, so this is not a once-per-command guarantee.
- The echo area can change the pair's height during the fit test, so the cap is checked against the pair height at that moment.
- The busy-send journey uses the fake's single text-stream steering slot. It proves key dispatch, the steer RPC and local follow-up delivery, not real-model steering timing. Explicit `C-c C-s` steering, abort, completion, and image attachment are outside this entry. Do not claim them from this run.
