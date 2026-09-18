# Enabling evil-mode after a Pilish session exists wedges the input buffer; nothing repairs it, not even a reload

## What you see

You turn on `M-x evil-mode` partway through the day, with a Pilish session already open. The chat buffer stops honoring Pilish's keys: `n` runs an evil search instead of jumping to the next message. The input buffer is worse. You type and no text appears; letters move the cursor or delete characters. You press RET to send and Emacs beeps "End of buffer". Nothing is sent.

## What happens

Pilish loads its Evil integration at exactly one moment: while setting up a session, and only if evil is already loaded (pilish.el:124-131, called at pilish.el:135). A session created before evil exists gets no evil setup at all. When evil turns on later, its global defaults take over the existing buffers. The chat buffer lands in normal state. The input buffer, whose documented initial state is `insert` (pilish-evil.el:157), lands in normal state too: letters are motions, and RET runs `evil-ret`, which errors and does not send.

Nothing repairs the buffers afterwards. `M-x pilish-evil-setup` only registers initial states for the five pilish modes (pilish-evil.el:279-292); `evil-set-initial-state` shapes buffers created later and never touches a live buffer's current state or keymap. `pilish-reload` restarts the backend but reuses the same buffers, so the wrong states survive a full restart (pilish-menu.el:541). The honest scope: the trigger is niche — deferred-loading configs and manual toggling — no data is lost, and a per-buffer escape exists. Press `i` (evil insert) or `C-z` (emacs state) in the input buffer and typing works again; `C-c C-c` still sends (pilish-ui.el:947). Sessions opened after evil is active are fine; the integration auto-loads for them.

## How to reproduce

1. Clone dnouri/pilish, check out ccbbb5e, and work from the repo root. Evil is required for this repro — it is an optional Pilish integration, and the bug cannot exist without it — so install it into the package directory first if your clone lacks it.
2. Save the script below to tmp/qa-filings/scratch/repro-004.el and run the batch command. Read the PROBE, SEND, AFTER, and CONTROL lines.

```elisp
mkdir -p tmp/qa-filings/scratch && cat > tmp/qa-filings/scratch/repro-004.el <<'EOF'
(require 'json) (require 'pilish)
(defconst r4-root (file-name-as-directory (locate-dominating-file (or load-file-name default-directory) "AGENTS.md")))
(defconst r4-dir (expand-file-name "tmp/qa-filings/scratch/" r4-root)) (make-directory r4-dir t)
(setq pilish-executable (list (or (executable-find "python3") "python3") (expand-file-name "test/support/fake_pi.py" r4-root)))
(make-directory (expand-file-name "r4-sessions" r4-dir) t)
(setq pilish-extra-args (list "--scenario" "prompt-lifecycle" "--session-dir" (expand-file-name "r4-sessions" r4-dir)))
(defvar r4-sent nil)
(advice-add 'pilish--send-prompt :before (lambda (text &optional _a _b _c _i) (setq r4-sent (append r4-sent (list text)))))
(defun r4-wait (pred timeout what) (let ((start (float-time)) (ok (funcall pred)))
  (while (and (not ok) (< (- (float-time) start) timeout)) (accept-process-output nil 0.1) (setq ok (funcall pred)))
  (or ok (error "timeout: %s" what))))
(let ((dir (make-temp-file "r4-" t)))            ; 1. session WITHOUT evil: the load check
  (defvar r4-chat (pilish--setup-session dir)))  ;    (pilish.el:124-131) at setup (pilish.el:135) skips
(r4-wait (lambda () (plist-get (buffer-local-value 'pilish--state r4-chat) :model)) 10 "state")
(defvar r4-input (buffer-local-value 'pilish--input-buffer r4-chat))
(require 'evil) (evil-mode 1) (sit-for 0.3)      ; 2. late evil: deferred-load config / M-x evil-mode
(with-current-buffer r4-input                    ; 3. probe the buffers that already exist
  (princ (format "PROBE input: state=%S j=%S x=%S RET=%S\n" evil-state (key-binding "j") (key-binding "x") (key-binding "\r"))))
(with-current-buffer r4-chat (princ (format "PROBE chat: state=%S n=%S (pilish-next-message expected)\n" evil-state (key-binding "n"))))
(with-current-buffer r4-input                    ; 4. attempt a send: type text, press RET
  (erase-buffer) (insert "late evil hello") (setq r4-sent nil)
  (let ((err nil))
    (condition-case e (let ((cmd (key-binding "\r"))) (setq this-command cmd) (call-interactively cmd))
      (error (setq err (error-message-string e))))
    (princ (format "SEND: RET-ran=%S error=%S sent=%S input-now=%S\n" (key-binding "\r")
                   err r4-sent (string-trim (buffer-string))))))
(require 'pilish-evil) (pilish-evil-setup)       ; 5. repair attempt 1: the user-facing command
(with-current-buffer r4-input (princ (format "AFTER-SETUP input: state=%S x=%S\n" evil-state (key-binding "x"))))
(with-current-buffer r4-chat (princ (format "AFTER-SETUP chat: state=%S n=%S\n" evil-state (key-binding "n"))))
(require 'pilish-menu)                           ; 6. repair attempt 2: full backend restart
(with-current-buffer r4-chat (pilish-reload))
(r4-wait (lambda () (plist-get (buffer-local-value 'pilish--state r4-chat) :model)) 10 "reload")
(sit-for 0.5)
(with-current-buffer r4-chat (princ (format "AFTER-RELOAD chat: state=%S n=%S\n" evil-state (key-binding "n"))))
(with-current-buffer (buffer-local-value 'pilish--input-buffer r4-chat)
  (princ (format "AFTER-RELOAD input: state=%S x=%S RET=%S\n" evil-state (key-binding "x") (key-binding "\r"))))
(let* ((dir2 (make-temp-file "r4b-" t))          ; control: a NEW session works (auto-load)
       (chat2 (pilish--setup-session dir2)))
  (r4-wait (lambda () (plist-get (buffer-local-value 'pilish--state chat2) :model)) 10 "state2")
  (with-current-buffer (buffer-local-value 'pilish--input-buffer chat2)
    (princ (format "CONTROL new-session input: state=%S RET=%S\n" evil-state (key-binding "\r"))))
  (let ((p (buffer-local-value 'pilish--process chat2)))
    (when (process-live-p p) (set-process-query-on-exit-flag p nil) (delete-process p)))
  (with-current-buffer chat2 (setq kill-buffer-query-functions nil) (kill-buffer)))
(let ((proc (buffer-local-value 'pilish--process r4-chat)))
  (when (process-live-p proc) (set-process-query-on-exit-flag proc nil) (delete-process proc)))
(dolist (b (list r4-input r4-chat))
  (when (buffer-live-p b) (with-current-buffer b (setq kill-buffer-query-functions nil)) (kill-buffer b)))
(princ "R4 DONE\n")
EOF
PACKAGE_USER_DIR=$PWD/.cache/elpa/30 emacs --batch -Q -L . \
  --eval '(setq package-user-dir (expand-file-name (getenv "PACKAGE_USER_DIR")))' \
  --eval "(add-to-list 'treesit-extra-load-path (expand-file-name \"~/.emacs.d/tree-sitter\"))" \
  --eval '(package-initialize)' \
  -l tmp/qa-filings/scratch/repro-004.el
```

The script starts a session on the committed fake backend (test/support/fake_pi.py, launched the way test/pilish-test-common.el launches it) with evil absent, then enables evil, probes the existing buffers, attempts a send, tries both repair paths, and opens a new session as a control. Verified output, identical on a second run:

```text
PROBE input: state=normal j=evil-next-line x=evil-delete-char RET=evil-ret
PROBE chat: state=normal n=evil-search-next (pilish-next-message expected)
SEND: RET-ran=evil-ret error="End of buffer" sent=nil input-now="late evil hello"
AFTER-SETUP input: state=normal x=evil-delete-char
AFTER-SETUP chat: state=normal n=evil-search-next
AFTER-RELOAD chat: state=normal n=evil-search-next
AFTER-RELOAD input: state=normal x=evil-delete-char RET=evil-ret
CONTROL new-session input: state=insert RET=newline
R4 DONE
```

The send failed: RET ran `evil-ret`, which signaled "End of buffer"; nothing reached the backend and the typed text sat untouched in the input buffer. Neither `pilish-evil-setup` nor `pilish-reload` changed a single state or binding. The control session, created after evil was active, started in insert state as designed.

## Why it happens

The load decision is a one-time check. `pilish--maybe-load-evil-integration` runs once per session setup and requires `(featurep 'evil)` to already be true; nothing re-runs it when evil arrives later. The buffers are created with no evil registration at all, so enabling evil-mode applies evil's global defaults to them: normal state everywhere, because no pilish initial state was ever registered. The repair command cannot help by design: `pilish-evil-setup` only calls `evil-set-initial-state`, which evil consults when a buffer's major mode starts, plus keymap registrations that only matter once a buffer is in the right state. And `pilish-reload` rebuilds the process and session state but keeps the existing buffers, so their broken evil states ride through the restart.

## Fixing it

Make `pilish-evil-setup` sweep existing buffers. Iterate live buffers in `pilish-chat-mode`, `pilish-input-mode`, or one of the browse modes, and apply the same per-buffer work the integration applies at creation: register the initial state, put the buffer in it, and activate the state keymaps. This gives the explicit command real repair semantics. The tradeoff: a sweep of live buffers must not fight evil's current state — only repair pilish-owned buffers whose modes match and that still sit in a default-derived state, and skip one the user has deliberately placed elsewhere.

Second, fire that sweep when evil becomes active later, through `evil-after-load-hook` or advice on `evil-mode`, so the user never hits the wedge at all. The tradeoff: a hook keyed to another package's activation must be idempotent and must respect `pilish-evil-integration` set to nil (pilish.el:117). A minimal alternative is documenting the limitation in the README and the menu, but that leaves the user to connect a wedged input buffer with a command they have no reason to know exists. Recommendation: do the sweep (a), triggered by (b).

## References

- pilish.el:124-135 — `pilish--maybe-load-evil-integration` and its single call site at the top of `pilish--setup-session`. https://github.com/dnouri/pilish/blob/ccbbb5e/pilish.el#L124-L135
- pilish-evil.el:157, 268-292 — `pilish-evil-input-state` defaults to `insert`, and `pilish-evil-setup` only makes `evil-set-initial-state` registrations, which affect future buffers. https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-evil.el#L268-L292
- pilish-evil.el:351-353, 365-366 — the normal-state RET → `pilish-send` binding a wedged buffer never receives, and the load-time activation whose late-arrival case has no equivalent. https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-evil.el#L351-L353
- pilish-ui.el:947 — `C-c C-c` → `pilish-send`, the binding that still works once the user escapes to insert or emacs state. https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-ui.el#L947

*Bug report generated by GLM-5.3 during an automated QA pass (2026-09-19); not human-written.*
