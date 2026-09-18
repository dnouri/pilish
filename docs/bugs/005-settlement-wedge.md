# If agent_settled never arrives, the session is stuck in sending forever and nothing can be sent

## What you see

A turn ends, but the header keeps showing the busy "thinking" phase and never clears. You type and send; Pilish answers "Pi: Message queued (will send when Pi is ready)" and the header shows `queued 1`. Nothing is ever sent. Stop (`C-c C-k`) empties the queue, but the session stays busy and nothing you type is ever sent.

## What happens

`agent_end` always leaves the session status at `sending`, and only `agent_settled` releases it to `idle` (pilish-core.el:812-823). Any send made while `sending` is queued with a promise (pilish-input.el:450-453). If settlement never arrives, `sending` has no other exit: every send queues, and nothing ever drains.

`pilish-abort` (pilish-input.el:465-478) sets its latch, clears the queue, and sends `clear_queue` then `abort` — that is all. It deliberately leaves status and latch to the settlement that never comes, so the user still cannot send, and a second abort changes nothing. Clearing the queue also destroys the queued text (report 003); in the wedge that text could never have drained anyway. And the inactivity warning, the one signal meant for a silent Pi, does not cover this state: it arms only while the status is `streaming` or `compacting` (pilish-ui.el:1377-1382), so a wedged session shows a frozen "thinking" phase with no hint anything is wrong.

Honest scope: the trigger is out-of-contract backend behavior. Real pi always settles. Extensions can delay settlement, and AGENTS.md documents that ambiguity and forbids inventing timer-based settlement guarantees, so no timeout exists by design. This is a robustness gap, not a protocol bug. Severity is moderate because recovery exists (`pilish-reload`, or process death) and the trigger is rare. But when it hits, the session is dead, and nothing on screen says why.

## How to reproduce

1. Clone dnouri/pilish, check out ccbbb5e, work from the repo root, save the script below to tmp/qa-filings/scratch/repro-005.el, run the batch command, read the labeled lines, and rerun once to confirm it is deterministic.

```elisp
mkdir -p tmp/qa-filings/scratch && cat > tmp/qa-filings/scratch/repro-005.el <<'EOF'
(require 'json) (require 'pilish)
(defconst r5-root (file-name-as-directory (locate-dominating-file (or load-file-name default-directory) "AGENTS.md")))
(defconst r5-dir (expand-file-name "tmp/qa-filings/scratch/" r5-root)) (make-directory r5-dir t)
(defconst r5-wire (expand-file-name "wire-005.jsonl" r5-dir))
(with-temp-file (expand-file-name "fast.json" r5-dir) ; streamed turn on the committed fake backend
  (insert (json-encode '((commands . []) (prompt . ((type . "text_stream") (assistant_text . "Reply to: {message}")
                         (chunk_count . 3) (delay_ms . 60) (echo_user . t))))))) (ignore (delete-file r5-wire))
(defun r5-swallow (orig proc event) (unless (equal (plist-get event :type) "agent_settled") (funcall orig proc event)))
(advice-add 'pilish--handle-event :around #'r5-swallow) ; the dispatch seam; misbehaving backend/extension swallows agent_settled
(defvar r5-note nil)
(advice-add 'message :around (lambda (o f &rest a) (setq r5-note (apply #'format f a)) (apply o f a)))
(defun r5-wait (pred timeout what) (let ((start (float-time)) (ok (funcall pred)))
    (while (and (not ok) (< (- (float-time) start) timeout)) (accept-process-output nil 0.1) (setq ok (funcall pred)))
    (or ok (error "timeout: %s" what))))
(defvar r5-ref nil) (defun r5-chat () (buffer-local-value 'pilish--chat-buffer r5-ref))
(defun r5-on-wire (s) (and (file-exists-p r5-wire) (with-temp-buffer (insert-file-contents r5-wire)
  (goto-char (point-min)) (re-search-forward s nil t))))
(let* ((dir (make-temp-file "r5-" t))
       (pilish-executable (list (or (executable-find "python3") "python3") (expand-file-name "test/support/fake_pi.py" r5-root)))
       (pilish-extra-args (list "--scenario" "fast" "--scenario-dir" r5-dir "--log-file" r5-wire))
       (chat (with-current-buffer (generate-new-buffer " *r5*") (pilish--setup-session dir)))
       (input (buffer-local-value 'pilish--input-buffer chat))
       (st (lambda () (buffer-local-value 'pilish--status (r5-chat))))
       (q (lambda () (length (buffer-local-value 'pilish--followup-queue (r5-chat))))))
  (setq r5-ref input) (r5-wait (lambda () (plist-get (buffer-local-value 'pilish--state chat) :model)) 10 "state")
  (with-current-buffer input (erase-buffer) (insert "turn one") (pilish-send))
  (r5-wait (lambda () (eq (funcall st) 'sending)) 15 "agent_end") ; turn over, settlement swallowed
  (sit-for 2) ; nothing releases the status
  (with-current-buffer (r5-chat)
    (princ (format "STUCK: status=%s phase=%S inactivity-warning-armed=%S\n" (funcall st)
                   pilish--activity-phase (pilish--inactivity-eligible-p))))
  (with-current-buffer input (erase-buffer) (insert "second prompt") (pilish-send))
  (princ (format "QUEUED: status=%s queue=%d promise=%S\n" (funcall st) (funcall q) r5-note))
  (sit-for 1.5) ; nothing drains
  (princ (format "STILL-QUEUED: status=%s queue=%d on-wire=%S\n" (funcall st) (funcall q) (not (null (r5-on-wire "second prompt")))))
  (with-current-buffer input (pilish-abort)) ; clears the queue, keeps the status
  (princ (format "ABORT: status=%s queue=%d latch=%S\n"
                 (funcall st) (funcall q) (buffer-local-value 'pilish--aborted (r5-chat))))
  (with-current-buffer input (erase-buffer) (insert "third prompt") (pilish-send))
  (princ (format "THIRD: status=%s queue=%d on-wire=%S\n"
                 (funcall st) (funcall q) (not (null (r5-on-wire "third prompt")))))
  (with-current-buffer input (pilish-abort))
  (princ (format "DOUBLE-ABORT: status=%s queue=%d\n" (funcall st) (funcall q)))
  ;; Only a fresh process recovers: drop the swallowing advice, then reload.
  (advice-remove 'pilish--handle-event #'r5-swallow)
  (with-current-buffer (r5-chat) (pilish-reload))
  (r5-wait (lambda () (and (eq (funcall st) 'idle)
                           (not (buffer-local-value 'pilish--session-transition-active (r5-chat))))) 20 "reload")
  (setq input (buffer-local-value 'pilish--input-buffer (r5-chat)) r5-ref input)
  (with-current-buffer input (erase-buffer) (insert "after reload") (pilish-send))
  (r5-wait (lambda () (and (r5-on-wire "after reload") (eq (funcall st) 'idle))) 20 "post-reload turn")
  (princ (format "RECOVERED: status=%s after-reload-on-wire=%S\n" (funcall st) t)))
EOF
PACKAGE_USER_DIR=$PWD/.cache/elpa/30 emacs --batch -Q -L . \
  --eval '(setq package-user-dir (expand-file-name (getenv "PACKAGE_USER_DIR")))' \
  --eval "(add-to-list 'treesit-extra-load-path (expand-file-name \"~/.emacs.d/tree-sitter\"))" --eval '(package-initialize)' -l tmp/qa-filings/scratch/repro-005.el
```

The committed fake backend (test/support/fake_pi.py) always settles, so the script advice-filters `agent_settled` out of the event dispatch, the seam every backend event crosses, and stands in for an extension or backend that swallows settlement. Verified output:

```text
STUCK: status=sending phase="thinking" inactivity-warning-armed=nil
QUEUED: status=sending queue=1 promise="Pi: Message queued (will send when Pi is ready)"
STILL-QUEUED: status=sending queue=1 on-wire=nil
ABORT: status=sending queue=0 latch=t
THIRD: status=sending queue=1 on-wire=nil
DOUBLE-ABORT: status=sending queue=0
RECOVERED: status=idle after-reload-on-wire=t
```

## Why it happens

The state machine has exactly one `sending` -> `idle` edge, tied to an event Pilish does not control and must not synthesize: the wire has no run identity, and AGENTS.md rules out timers and settlement guarantees. Right for the protocol, but it leaves no fallback for a settlement that is lost. Abort was written assuming settlement always comes. In the wedge, that assumption is the bug.

## Fixing it

(a) After abort completes, probe `get_state` and release `sending` if nothing is running. Precedent exists: `pilish--finish-prompt-without-agent-start` (pilish-ui.el:3051-3061) already probes and releases the status and the abort latch this way. The tradeoff: the probe races a settlement arriving concurrently, so it needs the pending-RPC correlation care AGENTS.md calls for.

(b) Include `sending` in the inactivity-warning condition (pilish-ui.el:1381). The tradeoff: legitimately slow extension hooks raise false alarms, absorbed by the existing silence threshold. Recommend both: (a) unwedges the session; (b) makes any wedge that remains visible.

## References

1. pilish-core.el:816-823 — `agent_end` leaves `sending` (812-815); only `agent_settled` releases it to `idle`. https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-core.el#L812-L823
2. pilish-input.el:465-478 — `pilish-abort`: latch, clear queue, clear_queue+abort; release left to settlement. https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-input.el#L465-L478
3. pilish-ui.el:1377-1382 — the inactivity warning arms only for `streaming`/`compacting`, never `sending`. https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-ui.el#L1377-L1382
4. pilish-ui.el:3051-3061 — precedent: the probe releases `sending` to `idle` and clears the latch (probe at 3069). https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-ui.el#L3051-L3061
5. `003-queue-promise-text-loss.md` — abort destroys the queued text; in this wedge the loss is certain, because the queue can never drain.

*Bug report generated by GLM-5.3 during an automated QA pass (2026-09-19); not human-written.*
