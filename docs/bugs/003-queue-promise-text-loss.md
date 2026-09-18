# Pilish promises "will send when Pi is ready", then silently discards the message

## What you see

You stop a run with `C-c C-k`. Pi is still winding down, so you type a follow-up and send it. Pilish answers "Pi: Message queued (will send when Pi is ready)" and the input header shows `queued 1`. A few seconds later the text is gone: not sent, not in the transcript, no explanation.

## What happens

When Pi is busy, a send goes to a local follow-up queue and the input buffer is cleared (pilish-input.el:448-453). Stopping a run sets an abort latch, and the end of the stopped turn clears that queue: once in `pilish--display-agent-end` (pilish-render.el:879-886) and again in the `agent_settled` branch (pilish-render.el:1442-1443). So a message sent in the seconds between Stop and settlement is accepted with a promise, then destroyed. A unit test pins abort-clears-queue as intended (test/pilish-input-test.el:1165), and for messages queued before the stop it is right: stop means stop everything. It says nothing about messages queued after the stop, which Pilish has just promised to send.

Steering has the same shape one step earlier (call it face (b); the queued follow-up above is face (a)). `pilish-queue-steering` accepts the text and clears the input the moment `pilish--send-steer-message` returns t (pilish-input.el:715-723). t means only that the RPC was written to the pipe. If pi rejects the steer, the failure callback prints "Pi: Steering failed: ..." and does nothing else (pilish-input.el:676-684). The text stays gone.

Two honest limits keep this at moderate severity. The text is recoverable from input history; `M-p` recalls it (verified). And real pi essentially never rejects plain steering text; its `session.steer` throws only for extension-command text, so face (b) bites mainly on transport errors and edge backends. The harm is the false promise and the silent vanishing, not unrecoverable loss.

## How to reproduce

1. Clone dnouri/pilish, check out ccbbb5e, and work from the repo root. Save the script below to tmp/qa-filings/scratch/repro-003.el, run the batch command, read the AFTER and FINAL lines, and rerun once to confirm it is deterministic.

```elisp
mkdir -p tmp/qa-filings/scratch
cat > tmp/qa-filings/scratch/repro-003.el <<'EOF'
(require 'json) (require 'pilish) (require 'pilish-input)
(defconst r3-root (file-name-as-directory
                   (locate-dominating-file (or load-file-name default-directory) "AGENTS.md")))
(defconst r3-dir (expand-file-name "tmp/qa-filings/scratch/" r3-root))
(defconst r3-wire (expand-file-name "wire.jsonl" r3-dir)) (make-directory r3-dir t)
;; One ~2.4s streamed turn, so the abort lands mid-turn.
(with-temp-file (expand-file-name "slow.json" r3-dir)
  (insert (json-encode '((commands . []) (prompt . ((type . "text_stream")
                         (assistant_text . "Reply to: {message}")
                         (chunk_count . 6) (delay_ms . 400) (echo_user . t))))))) (ignore (delete-file r3-wire))
(defvar r3-sent nil) (defvar r3-note nil)
(advice-add 'pilish--send-prompt :before (lambda (text &optional _a _b _c _i) (setq r3-sent (append r3-sent (list text)))))
(advice-add 'message :around (lambda (orig fmt &rest a) (setq r3-note (apply #'format fmt a)) (apply orig fmt a)))
(defun r3-wait (pred timeout what)
  (let ((start (float-time)) (ok (funcall pred)))
    (while (and (not ok) (< (- (float-time) start) timeout))
      (accept-process-output nil 0.1) (setq ok (funcall pred)))
    (or ok (error "timeout: %s" what))))
(let* ((dir (make-temp-file "r3-" t))
       (pilish-executable (list (or (executable-find "python3") "python3")
                                (expand-file-name "test/support/fake_pi.py" r3-root)))
       (pilish-extra-args (list "--scenario" "slow" "--scenario-dir" r3-dir "--log-file" r3-wire))
       (chat (with-current-buffer (generate-new-buffer " *r3*") (pilish--setup-session dir)))
       (input (buffer-local-value 'pilish--input-buffer chat))
       (st (lambda () (buffer-local-value 'pilish--status chat)))
       (q (lambda () (length (buffer-local-value 'pilish--followup-queue chat)))))
  (r3-wait (lambda () (plist-get (buffer-local-value 'pilish--state chat) :model)) 10 "state")
  (with-current-buffer input (erase-buffer) (insert "turn one") (pilish-send))
  (r3-wait (lambda () (memq (funcall st) '(sending streaming))) 10 "turn busy")
  (with-current-buffer input (pilish-abort)) ; stop mid-turn
  (r3-wait (lambda () (buffer-local-value 'pilish--aborted chat)) 5 "abort latch")
  (with-current-buffer input (erase-buffer) (insert "post-abort followup") (pilish-send))
  (with-current-buffer input
    (princ (format "AFTER: status=%s queue=%d input=%S promise=%S\n"
                   (funcall st) (funcall q) (buffer-string) r3-note)))
  (r3-wait (lambda () (eq (funcall st) 'idle)) 20 "settle") ; let the turn end
  (sit-for 1)
  (with-current-buffer chat
    (let ((tail (buffer-substring-no-properties (max (point-min) (- (point-max) 300)) (point-max)))
          (on-wire (and (file-exists-p r3-wire)
                        (with-temp-buffer (insert-file-contents r3-wire)
                          (goto-char (point-min)) (re-search-forward "post-abort followup" nil t)))))
      (princ (format "FINAL: queue=%d second-prompt-on-wire=%S in-transcript=%S sent=%S\n"
                     (funcall q) (not (null on-wire))
                     (string-match-p "post-abort followup" tail) r3-sent))))
  (let ((proc (buffer-local-value 'pilish--process chat)))
    (when (process-live-p proc)
      (set-process-query-on-exit-flag proc nil) (delete-process proc)))
  (dolist (b (list input chat))
    (when (buffer-live-p b) (with-current-buffer b (setq kill-buffer-query-functions nil))
      (kill-buffer b))))
EOF
PACKAGE_USER_DIR=$PWD/.cache/elpa/30 emacs --batch -Q -L . \
  --eval '(setq package-user-dir (expand-file-name (getenv "PACKAGE_USER_DIR")))' \
  --eval "(add-to-list 'treesit-extra-load-path (expand-file-name \"~/.emacs.d/tree-sitter\"))" \
  --eval '(package-initialize)' \
  -l tmp/qa-filings/scratch/repro-003.el
```

The script writes its own slow scenario, starts a real session on the committed fake backend (test/support/fake_pi.py, launched the way test/pilish-test-common.el launches it), sends a prompt, aborts mid-turn, sends a second prompt while the status still reads `sending`, and lets the turn settle. Verified output:

```text
AFTER: status=sending queue=1 input="" promise="Pi: Message queued (will send when Pi is ready)"
FINAL: queue=0 second-prompt-on-wire=nil in-transcript=nil sent=("turn one")
```

The promise was made and the input emptied; at settlement the queue is empty, the wire log holds no second prompt, the transcript has none, and nothing was sent. The text is not beyond recall: input history still holds it, and `M-p` in the input buffer brings it back.

## Why it happens

Discarding the queue on abort is correct stop-everything semantics, and the test that pins it is right. The defect is the other side of the race. The send command makes its promise without consulting the abort latch, so it happily promises delivery in the seconds between Stop and settlement, and the latch then kills the promise without a word. Steering optimistically treats "written to the pipe" as "delivered"; success and failure of the RPC arrive later, in a callback that only complains, and no code path gives the text back.

## Fixing it

For face (a), when the abort path drains a non-empty queue, return the queued text to the input buffer, or at least announce "Abort discarded 1 queued message". That keeps stop-everything semantics without silent loss. The tradeoff: restoring clobbers what the user typed since the stop, so restore only into an empty input buffer and message otherwise.

For face (b), move steering's input acceptance into the RPC success callback, or restore the text in the failure callback. The cost is a slightly later input clear, and any restore must not clobber newer typing. Gating the "will send" wording on the abort latch would also make the promise honest. Recommendation: restore-or-notify for (a) and success-callback acceptance for (b). Fixes must keep `pilish-test-abort-clears-followup-queue` green: text queued before the stop stays discarded and is never sent.

## References

1. pilish-input.el:448-453 — the busy branch queues and clears, promising "will send when Pi is ready". https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-input.el#L448-L453
2. pilish-input.el:715-723 — steering accepted the moment the pipe write succeeds. https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-input.el#L715-L723
3. pilish-input.el:676-684 — steering failure callback: message only, no restore. https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-input.el#L676-L684
4. pilish-render.el:879-886 — abort latch clears the follow-up queue at turn end. https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-render.el#L879-L886
5. pilish-render.el:1442-1443 — the agent_settled branch clears the queue again. https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-render.el#L1442-L1443
6. test/pilish-input-test.el:1165 — `pilish-test-abort-clears-followup-queue` pins abort-clears-queue. https://github.com/dnouri/pilish/blob/ccbbb5e/test/pilish-input-test.el#L1165
7. `005-settlement-wedge.md` — a wedged `sending` session queues every send, and its only exit, abort, then destroys the queue; it compounds this bug.

*Bug report generated by GLM-5.3 during an automated QA pass (2026-09-19); not human-written.*
