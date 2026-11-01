# Answer extension editor prompts

An extension's multiline editor prompt opens a separate prefilled buffer. Submit sends the edited text; cancel sends one cancellation. Closing an editor restores the session windows without changing the prompt text or its major mode. Emacs stays usable while the editor is open.

## Sub-features

- `editor-open` opens a `*pilish-editor: TITLE*` buffer with the request's prefill.
- `editor-submit` sends edited text with `C-c C-c`, closes the editor, and shows the extension's follow-up.
- `editor-cancel` sends one cancellation with `C-c C-k` and restores the session windows.
- `editor-kill` cancels once when the editor buffer is killed.
- `editor-stop-exit` closes that session's editors on Stop or process exit and restores its windows.
- `editor-mode` cancels before a major-mode change or reinitialization, closes editor windows, and retains the text buffer without editor cleanup hooks.
- `editor-draft` retains the input draft and its major mode on every path. Process exit also recovers any unacknowledged command ahead of that draft.

## How to get to it (user POV)

- Run an extension command or tool that calls `ctx.ui.editor`, for example the fake `/test-editor` command.
- Edit the editor text and press `C-c C-c`, or press `C-c C-k` to cancel.
- Use `M-x kill-buffer` in the editor, or `C-c C-k` in the session input to Stop.
- Change the editor's mode with `M-x text-mode`, or reinitialize it with `M-x pilish-editor-mode`.
- If Pi exits while the editor is open, its window closes automatically.

## Driving it with Pilish harnesses

Preconditions:

- Launch and Doctor passed. Use a fresh `RUN_DIR` for each run. Retain stdout, stderr, and the exit status as described in the verification skill.
- Set `G1_CAPTURE="$RUN_DIR/capture"` for each command below.

Run these commands and retain each run's output and exit status:

- `./test/run-gui-tests.sh --headless pilish-gui-test-extension-editor-submits-edited-text` checks prefill, real typed edits, one response, `EDITOR SUBMITTED`, and two restored session windows.
- `./test/run-gui-tests.sh --headless pilish-gui-test-extension-editor-cancel-keeps-draft` uses `C-c C-k` and checks one cancellation, `EDITOR CANCELLED`, and the restored layout.
- `./test/run-gui-tests.sh --headless pilish-gui-test-extension-editor-kill-restores-layout` uses `M-x kill-buffer` and checks the same cancellation and layout.
- `./test/run-gui-tests.sh --headless pilish-gui-test-extension-editor-stop-restores-layout` uses the input's Stop key while the non-streaming extension command is waiting. It requires a killed editor, one cancellation, the extension follow-up, and two session windows.
- `./test/run-gui-tests.sh --headless pilish-gui-test-extension-editor-exit-restores-layout` terminates the test-owned subprocess. It requires a killed editor and two session windows, with no response attempted to the dead process. The unacknowledged command is recovered ahead of the retained draft.
- `./test/run-gui-tests.sh --headless pilish-gui-test-extension-editor-mode-change-keeps-text` uses `M-x text-mode`. It requires one cancellation, retained editor text in Text mode, no editor windows, and no editor lifecycle hooks.
- `./test/run-gui-tests.sh --headless pilish-gui-test-extension-editor-reinitialize-keeps-text` uses `M-x pilish-editor-mode` and checks the same release and retention behavior.

Every test checks the prompt's major mode and retained draft text. Process exit also checks the existing recovery of the unacknowledged `/test-editor` command ahead of that draft. Other paths require the exact unchanged prompt text. Require `PASS: TEST-NAME`, `0 skipped`, and exit status zero. For each run, use `test -s` on both `.el` and `.png` captures named `ACTION-before` and `ACTION-after`, where ACTION is `submit`, `cancel`, `kill`, `stop`, `exit`, `mode`, or `reinitialize`. The traces include response payloads, window buffers, prompt hashes, major mode, and loaded source and dependency paths.

## Gotchas

- Fake-backed proof does not show that a real extension executed. A real `ctx.ui.editor` exchange needs a separate compatibility check.
- Pi editor requests have no timeout or abort signal. The fake matches this behavior. Pilish Stop sends editor cancellation even while the extension command is non-streaming; it is not a no-op.
- Changing or reinitializing the editor's major mode cancels the request rather than continuing it in the new mode. The retained buffer is ordinary text and killing it sends no second response.
- Process ownership isolation is covered by `pilish-test-extension-ui-editor-cleanup-is-process-owned` in `make test-render SELECTOR=extension-ui-editor`. A single-session GUI run does not prove another session's behavior.
