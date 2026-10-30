# Answer extension editor prompts

An extension's multiline editor prompt opens a separate prefilled buffer. Submitting sends the edited text to Pi and cancelling sends one cancellation. Neither touches the session's prompt draft, and Emacs stays usable while the editor is open.

## Sub-features

- `editor-open` opens a `*pilish-editor: TITLE*` buffer in another window with the request's prefill.
- `editor-submit` sends the edited text with `C-c C-c`, closes the editor, and shows the extension's follow-up.
- `editor-cancel` sends one cancellation with `C-c C-k` and closes the editor.
- `editor-draft` leaves a draft typed into the input buffer while the editor is open unchanged.

## How to get to it (user POV)

- Run an extension command or tool that calls `ctx.ui.editor`, for example the fake `/test-editor` command.
- Edit the text in the editor buffer and press `C-c C-c`.
- Press `C-c C-k` in the editor buffer to cancel instead.

## Driving it with Pilish harnesses

Preconditions:

- The Doctor check passed. `RUN_DIR` is a new empty evidence directory.

- **Submit edited text.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-extension-editor-submits-edited-text 2>&1 | tee "$RUN_DIR/editor-submit.log"`. Record `editor-submit.exit`. The fake sends an `editor` request for `/test-editor`. The test types a draft into the input buffer, selects the editor window, checks the prefill, types a line with real keys, and presses `C-c C-c`. It requires one sent response with the edited text, the fake's `EDITOR SUBMITTED` follow-up in chat, a killed editor buffer, and an unchanged draft hash.
- **Cancel.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-extension-editor-cancel-keeps-draft 2>&1 | tee "$RUN_DIR/editor-cancel.log"`. Record `editor-cancel.exit`. After typing into the editor, `C-c C-k` sends exactly one cancellation for the fake's request ID. The fake shows `EDITOR CANCELLED`, the editor buffer is gone, and the draft hash is unchanged.
- **Check the proof.** Require zero statuses, nonempty logs, and `PASS: TEST-NAME` with `0 skipped` in each log, with `test "$(cat "$RUN_DIR/editor-submit.exit")" -eq 0`, `test "$(cat "$RUN_DIR/editor-cancel.exit")" -eq 0`, `test -s "$RUN_DIR/editor-submit.log"`, and `test -s "$RUN_DIR/editor-cancel.log"`.

## Gotchas

- The fake replays the request and response wire shape. It does not run an extension, so it does not prove a real `ctx.ui.editor` caller resumed.
- The fake waits for an extension command without streaming, so `pilish-abort` is a no-op there. Unit tests cover cancellation on Stop and on process exit; this journey does not.
- Killing the editor buffer also cancels. Unit tests cover it; this journey uses `C-c C-k`.
- These tests provide assertion logs, not PNG captures.
