# Compose and send

Pilish opens a chat and input pair, then sends consecutive prompts without losing the later submission. With a fitted input height, the input window follows the draft. Integrations can submit separate text without consuming the user's draft, image or history; a user send during API preflight queues as a local follow-up.

## Sub-features

- `compose-layout` opens a live session with chat and input windows.
- `compose-header` renders the session header line at the top of the chat window by default, keeps it out of the input window, moves it between the live windows when `pilish-header-line-location` is set to `input`, and removes it from both windows when set to `none`.
- `compose-send` submits a prompt and displays its reply.
- `compose-sequential` submits a second prompt after the first turn and returns to idle.
- `compose-api-draft` submits API text and steering while preserving a typed draft, attached PNG, point, modified flag, history and selected input window.
- `compose-api-preflight` sends API text before `agent_start`, queues an interleaved user send locally, and preserves the newer draft while both requests complete.
- `compose-fit-input` sizes a `fit` input window to the typed draft, stops at its cap, refits on frame-width changes, and shrinks after sending.
- `compose-fit-display` preserves a fitted draft when reopening the input, hides after sending in both `on-demand` and `hidden` styles, and reopens empty at one text line. Pressing `i` in the chat window opens or focuses the input in every display style, without the Evil integration.

## How to get to it (user POV)

- Run `M-x pilish` from a project directory.
- Read the model, thinking level, activity, cost, and context status in the header line above the chat, and click model or thinking level there.
- Set `pilish-header-line-location` to `input` to move the header line above the input window, as in earlier Pilish versions, or to `none` to remove it, in existing sessions without restarting them.
- Enter a prompt in the input buffer and press `C-c C-c`.
- Enter and send another prompt after the first reply.
- From Lisp, call `(pilish-submit-prompt CHAT TEXT CALLBACK &optional BEHAVIOR)` with a live chat buffer. `BEHAVIOR` is `"followUp"` (default) or `"steer"`; the callback reports acceptance, not completion. Keep editing the input while API text runs, or press `C-c C-c` before the API run starts to queue your user text.
- Set the global `pilish-input-window-height` option to `fit`, type a multi-line draft, resize the frame, and press `C-c C-c`.
- Set `pilish-input-window-display` to `on-demand` or `hidden`. Press `i` in the chat window (or run `M-x pilish-open-input`) to compose or reopen the input after sending.

## Driving it with Pilish harnesses

Preconditions:

- The Doctor check passed. `RUN_DIR` is a new empty evidence directory.

- **Open the session.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-session-starts 2>&1 | tee "$RUN_DIR/layout.log"`. Record `layout.exit`. A passing, non-skipped result proves the fake process and stacked chat and input windows.
- **Place the header line.** Run `G1_CAPTURE="$RUN_DIR/header" ./test/run-gui-tests.sh --headless pilish-gui-test-session-header-line-lives-in-chat-window 2>&1 | tee "$RUN_DIR/header.log"`. Record `header.exit`. The test starts a session, asserts the header line renders in the chat window and not the input window, sets `pilish-header-line-location` to `input` through the Customize setter, and asserts the header line moved to the input window in the same live session. It then sets `none` and asserts both windows lose the header. It writes `header-in-chat` and `header-in-input` observations and PNG frames; `none` is an assertion-only state.
- **Send two prompts.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-send-waits-for-turn-start 2>&1 | tee "$RUN_DIR/send.log"`. Record `send.exit`. The test sends through `pilish-send`, displays the fake reply to the second prompt, and returns to idle.
- **Protect a draft during API submission.** Run `G1_CAPTURE="$RUN_DIR/api-draft" ./test/run-gui-tests.sh --headless pilish-gui-test-submit-prompt-preserves-draft 2>&1 | tee "$RUN_DIR/api-draft.log"`. Record `api-draft.exit`. The journey types a multiline draft, attaches a real PNG through `pilish-attach-image`, calls the public API, observes accepted steering and a reported queue, and waits for both fake replies plus prompt-start cleanup. It compares draft text, point, modified flag, image bytes/metadata, history and selected window before/after. It writes `api-draft-before`, `api-draft-with-queue` and `api-draft-after` observations and PNG frames.
- **Interleave an ordinary send before API run start.** Run `G1_CAPTURE="$RUN_DIR/api-preflight" ./test/run-gui-tests.sh --headless pilish-gui-test-submit-prompt-interleaves-user-send 2>&1 | tee "$RUN_DIR/api-preflight.log"`. Record `api-preflight.exit`. A fake pre-start window lets the journey invoke the API then press `C-c C-c`. The user text must enter the local FIFO before `agent_start`, rather than competing as a direct prompt. It types a newer draft, waits for the API and local follow-up replies and complete prompt ownership release, then verifies the new draft and focus are unchanged. It writes `api-pre-start-user-queued` and `api-interleaved-after` observations and PNG frames.
- **Fit the input to a draft.** Run `G1_CAPTURE="$RUN_DIR/fit" ./test/run-gui-tests.sh --headless pilish-gui-test-input-window-fits-draft 2>&1 | tee "$RUN_DIR/fit.log"`. Record `fit.exit`. The test types three lines and then more lines than the cap with real keys, sends with `C-c C-c`, and asserts one draft line at start, three lines, the capped height ending at point's line, and one line after the reply. It writes `fit-empty`, `fit-three-lines`, `fit-capped`, and `fit-after-send` observations and PNG frames.
- **Resize an unchanged draft.** Run `G1_CAPTURE="$RUN_DIR/resize" ./test/run-gui-tests.sh --headless pilish-gui-test-input-fit-refits-on-frame-resize 2>&1 | tee "$RUN_DIR/resize.log"`. Record `resize.exit`. The graphical frame changes from 104 to 54 columns and back. Without another edit, the same draft grows from two to four text rows and returns to two. It writes `fit-wide`, `fit-narrow`, and `fit-wide-again` observations and PNG frames.
- **Compose on demand.** Run `G1_CAPTURE="$RUN_DIR/display" ./test/run-gui-tests.sh --headless pilish-gui-test-input-fit-with-hide-after-send 2>&1 | tee "$RUN_DIR/display.log"`. Record `display.exit`. The test checks both display styles at launch, closes and reopens a three-line draft with keys, sends with `C-c C-c`, verifies the input disappears, and reopens an empty one-line input by pressing `i` in the chat window. It writes `fit-on-demand-draft`, `fit-on-demand-sent`, `fit-on-demand-reopened`, and the corresponding `fit-hidden-*` observations and PNG frames.
- **Check the logs.** Require zero statuses, `PASS: TEST-NAME` for each named test, and `0 skipped` in every log. For each stem `layout`, `header`, `send`, `api-draft`, `api-preflight`, `fit`, `resize`, and `display`, run `test "$(cat "$RUN_DIR/STEM.exit")" -eq 0` and `test -s "$RUN_DIR/STEM.log"`, replacing `STEM` with the stem.
- **Check the API captures.** Run `test -s "$RUN_DIR/api-draft/api-draft-with-queue.el"`, `test -s "$RUN_DIR/api-draft/api-draft-with-queue.png"`, `test -s "$RUN_DIR/api-draft/api-draft-after.el"`, `test -s "$RUN_DIR/api-draft/api-draft-after.png"`, `test -s "$RUN_DIR/api-preflight/api-pre-start-user-queued.el"`, `test -s "$RUN_DIR/api-preflight/api-pre-start-user-queued.png"`, `test -s "$RUN_DIR/api-preflight/api-interleaved-after.el"`, and `test -s "$RUN_DIR/api-preflight/api-interleaved-after.png"`.
- **Check the captures.** Run `test -s "$RUN_DIR/header/header-in-chat.el"`, `test -s "$RUN_DIR/header/header-in-chat.png"`, `test -s "$RUN_DIR/header/header-in-input.el"`, `test -s "$RUN_DIR/header/header-in-input.png"`, `test -s "$RUN_DIR/fit/fit-capped.el"`, `test -s "$RUN_DIR/fit/fit-capped.png"`, `test -s "$RUN_DIR/resize/fit-narrow.el"`, `test -s "$RUN_DIR/resize/fit-narrow.png"`, `test -s "$RUN_DIR/resize/fit-wide-again.el"`, `test -s "$RUN_DIR/resize/fit-wide-again.png"`, `test -s "$RUN_DIR/display/fit-on-demand-reopened.el"`, `test -s "$RUN_DIR/display/fit-on-demand-reopened.png"`, `test -s "$RUN_DIR/display/fit-hidden-reopened.el"`, and `test -s "$RUN_DIR/display/fit-hidden-reopened.png"`.

## Gotchas

- The fake supplies deterministic replies. It does not prove provider authentication or model output.
- The layout and send tests provide assertion logs, not PNG captures. The header-placement and fitted-input tests require graphical Emacs with `x-export-frames` for the named PNG proof.
- The header location is a global option; the placement test resets it to `chat` before exiting. A failed run can leave it at `input` or `none`, which changes later sessions' layout in the same Emacs.
- Input height and maximum height are global options, not session-local settings. `fit` may shrink the input below `window-min-height`; the chat window keeps its minimum.
- Edits share a pending fit timer until it runs. Commands that yield may allow several fits, so this is not a once-per-command guarantee.
- The echo area can change the pair's height during the fit test, so the cap is checked against the pair height at that moment.
- The API draft journey uses the fake's single steering slot and handled-input interception. The fake rejects busy `followUp` requests; that rejection is checked rather than hidden. It does not prove real Pi queues, providers, extensions or remote compatibility. Successful busy follow-up command/response routing has unit coverage, not this GUI coverage.
- API requests can overtake unsent local user follow-ups. The two queues do not share a global order. Accepted API requests keep local follow-ups guarded until the existing fallback state probe confirms idle with no pending input; observed runs must first settle.
- The API preflight fixture's one-second start delay is pacing, not a completion deadline. Each journey waits for observed state and replies, not for a fixed sleep to finish.
- The API draft journey proves attachment preservation, not image submission or model vision. Steering is exercised only through that API journey. Interactive steering, abort and completion are outside this entry.
