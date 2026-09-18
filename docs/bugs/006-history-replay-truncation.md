# A render error during resume silently truncates the rebuilt transcript

## What you see

You resume a long session. The transcript comes back, but it quietly ends
early: older messages are simply gone from view. Nothing tells you that
history is missing.

## What happens

Resume, reload, and branch rebuild the chat with `pilish--display-session-history` (pilish-render.el:7518). It erases the buffer first (pilish-render.el:7541), then renders the messages one by one (`pilish--display-history-messages`, pilish-render.el:7545).
Nothing contains an error around that loop, and neither caller catches one: the resume RPC callback (pilish-menu.el:431) and the canonical repaint path (pilish-render.el:7446) both call it bare.

If any render step signals mid-replay — a malformed entry, a tree-sitter query error, a plain render bug — the replay stops there, leaving only the messages rendered so far.
The marker resets after the loop (pilish-render.el:7548-7550) never run: QA measured `(:message-start 1 :streaming 245 :hot-tail 1 :point-max 245)` on a partially built buffer.
The only trace is one low-level dispatch log line (pilish-core.el:538-541), and a later live turn renders normally, completing the disguise.
The disk file is intact — silent display truncation, not data loss.
Honest scope: a render error must trigger it — rare but real; report 001 documents an unguarded `treesit-query-compile` (pilish-table.el:169-171) in exactly this code family, one known trigger.

## How to reproduce

1. Clone dnouri/pilish, check out ccbbb5e, run `make deps`, work from the repo root. Save the script below to tmp/qa-filings/scratch/repro-006.el and run the batch command.
   It builds a three-message session JSONL (fixture shapes per test/pilish-jsonl-test.el / test/pilish-fake-pi-test.el), projects it as the resume RPC carries messages, and calls the production `pilish--display-session-history` in a buffer with markers set as a live session leaves them.
   A `cl-letf` makes the render of the SECOND message signal — injected on purpose, standing in for any mid-replay error. Rerun once; it is deterministic.

```bash
mkdir -p tmp/qa-filings/scratch
cat > tmp/qa-filings/scratch/repro-006.el <<'EOF'
(require 'json) (require 'pilish)
(defconst r6-file (expand-file-name "tmp/qa-filings/scratch/repro-006-session.jsonl" default-directory))
(with-temp-file r6-file
  (insert (json-encode '((type . "session") (version . 3) (id . "qa-replay-1") (cwd . "/tmp"))) "\n")
  (dolist (s '(("e1" nil "user" "First question") ("e2" "e1" "assistant" "History reply ONE") ("e3" "e2" "assistant" "History reply TWO")))
    (insert (json-encode `((type . "message") (id . ,(nth 0 s)) (parentId . ,(nth 1 s))
                           (message . ((role . ,(nth 2 s)) (content . [((type . "text") (text . ,(nth 3 s)))]))))) "\n")))
(defconst r6-messages
  (let (msgs)
    (dolist (line (split-string (with-temp-buffer (insert-file-contents r6-file) (buffer-string)) "\n" t))
      (let ((e (json-parse-string line :object-type 'plist :array-type 'array :null-object nil :false-object :json-false)))
        (when (plist-get e :message) (push (plist-get e :message) msgs))))
    (vconcat (nreverse msgs))))
(let ((buf (generate-new-buffer " *r6-fault*")) (calls 0))
  (with-current-buffer buf                ; markers as a live session leaves them
    (pilish-chat-mode)
    (let ((inhibit-read-only t)) (insert "Live turn before the resume.\n"))
    (pilish--set-message-start-marker (copy-marker (point-max) nil)) (pilish--set-streaming-marker (copy-marker (point-max) t))
    (pilish--update-hot-tail-boundary))
  (with-current-buffer buf                ; render of the SECOND message signals:
    (cl-letf (((symbol-function 'pilish--render-history-assistant-content) ; stand-in for any mid-replay error
               (lambda (message _results) (setq calls (1+ calls))
                 (if (= calls 2) (error "repro: simulated mid-replay render error")
                   (pilish--append-to-chat (concat (plist-get (aref (plist-get message :content) 0) :text) "\n"))))))
      (message "AFTER: error=%S" (condition-case e (progn (pilish--display-session-history r6-messages buf) nil) (error (error-message-string e))))
      (message "AFTER: buffer=%S" (string-replace "\n" "\\n" (buffer-substring-no-properties (point-min) (point-max))))
      (message "AFTER: markers=%S" (list :message-start (and pilish--message-start-marker (marker-position pilish--message-start-marker)) :streaming (and pilish--streaming-marker (marker-position pilish--streaming-marker))
                 :hot-tail (and pilish--hot-tail-start (marker-position pilish--hot-tail-start)) :point-max (point-max)))))
  (kill-buffer buf))
EOF
PACKAGE_USER_DIR=$PWD/.cache/elpa/30 emacs --batch -Q -L . --eval "(progn (setq package-user-dir (expand-file-name (getenv \"PACKAGE_USER_DIR\"))) (add-to-list 'treesit-extra-load-path (expand-file-name \"~/.emacs.d/tree-sitter\")) (package-initialize))" -l tmp/qa-filings/scratch/repro-006.el
```

Verified output (buffer newlines appear escaped, exactly as printed):

```text
AFTER: error="repro: simulated mid-replay render error"
AFTER: buffer="Pilish\\n======\\n\\nC-c C-c   send prompt\\nC-c C-k   abort\\nC-c C-r   sessions\\nC-c C-p   menu\\n\\npilish 3.1.0 · TAB details\\n\\n\\nYou\\n===\\n\\nFirst question\\n\\nAssistant\\n=========\\n\\nHistory reply ONE\\n"
AFTER: markers=(:message-start 1 :streaming 182 :hot-tail 1 :point-max 182)
```

The replay ended at "History reply ONE"; "History reply TWO" is nowhere in the buffer, and the markers are stale — a healthy rebuild resets `:message-start` and `:streaming` to `nil`.
QA also verified this shape end-to-end: a real fake-pi resume flow whose replay was interrupted left the transcript truncated on display with stale markers (`message-start=1, streaming=245, hot-tail=1`) and a healthy live turn after; an xvfb GUI lane confirmed it (tmp/qa-hover/README.md, result 5).

## Why it happens

The rebuild is written as if rendering cannot fail, and it does destructive work before it can be wrong: erase everything, render, and only at the end make the buffer consistent (pilish-render.el:7548-7555).
But rendering runs change hooks, tree-sitter queries, overlay work; it can signal. A shorter but plausible transcript is the worst outcome: nothing looks broken.

## Fixing it

(a) Wrap the per-message render in a `condition-case`: skip the offending message, log visibly, keep going. Tradeoff: a skipped message is hidden history, so the skip must be loud, not a quiet gap.

(b) Wrap the whole rebuild in a `condition-case` that, on error, restores a sane empty-but-marked state — re-initialize the markers to point-min/point-max — and surfaces the failure to the user.
Tradeoff: the buffer ends up empty, but honestly empty instead of silently short.

(c) The canonical-repaint backstop from report 001 doubles as recovery here.
Recommend (a) plus (b): per-message containment, plus a visible failure state if the rebuild still fails.

## References

- pilish-render.el:7518 — `pilish--display-session-history`, the rebuild entry point. https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-render.el#L7518
- pilish-render.el:7541 and :7545 — the `erase-buffer`, then the uncontained `pilish--display-history-messages` call. https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-render.el#L7541 https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-render.el#L7545
- pilish-render.el:7446 — the canonical repaint caller, also without a catch. https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-render.el#L7446
- pilish-menu.el:431 — the resume RPC callback caller, also without a catch. https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-menu.el#L431
- `001-stream-flush-reply-loss.md` — same missing-recovery family; its unguarded treesit query compile (pilish-table.el:169-171) is a real trigger for this one.

*Bug report generated by GLM-5.3 during an automated QA pass (2026-09-19); not human-written.*
