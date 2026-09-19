# Deleting a session another Emacs holds open succeeds — the open-session guard only sees the current instance

## What you see

You press `d` on a session that looks closed, answer y at the "Permanently delete" prompt, and pilish reports it deleted. In another Emacs window that same session was still open — and the next thing you send there goes to a file that no longer exists.

## What happens

The delete command refuses sessions that are open, but "open" means open in this Emacs only. The detection helpers `pilish--browse-live-session-paths` and `pilish--browse-live-session-chat-buffer` (pilish-browse.el:2627-2658) walk `(process-list)` (pilish-browse.el:2640, :2653), which holds this instance's processes and nothing else. `pilish--browse-ensure-session-closed` (pilish-browse.el:2660) inherits that, and `pilish-session-browser-delete` (pilish-browse.el:2816) calls it before the prompt and again after confirmation (pilish-browse.el:2856, :2864). In a second instance both checks pass, and `(delete-file raw-path trash-p)` runs (pilish-browse.el:2878), honoring `delete-by-moving-to-trash`, which is off by default.

The code is honest about the boundary: the docstrings state that detection covers only this Emacs, not another instance or a process outside pilish (pilish-browse.el:2635, :2834-2835), and AGENTS.md records independent-writer races as a documented constraint (AGENTS.md:70). So this is not an unknown bug. It is a documented best-effort that is not enough for the action it guards: the check answers "open in this instance?" with a hard refusal ("Session is open in ... — close it first", pilish-browse.el:2663), and nothing in the prompt hints that the check only covered this instance. The failure is destructive because pi appends by path: after the unlink, the other instance's next append recreates the file with a fresh header and no past — history forks. Severity is moderate, since it takes two windows on one session, but when it happens the loss is real and silent.

## How to reproduce

1. Fresh clone of dnouri/pilish, checkout ccbbb5e, from the repo root, two terminals. Run `make deps` once first — the batch invocation below loads `magit-section`, `transient`, `md-ts-mode`, and `color` from `.cache/elpa/30`, which a fresh clone does not have. Both run this batch invocation, only the `-l` argument differs. The backend is the committed fake (test/support/fake_pi.py), launched the way test/pilish-test-common.el launches it. Terminal 1 saves script A and runs it; it holds a live session for 120 seconds.

```elisp
mkdir -p tmp/qa-filings/scratch
cat > tmp/qa-filings/scratch/repro-007-a.el <<'EOF'
(require 'json) (require 'pilish) (require 'pilish-browse) (require 'pilish-menu)
(defconst qa7-root (file-name-as-directory default-directory)) ; run from repo root
(setenv "PI_CODING_AGENT_DIR" (concat qa7-root "tmp/qa-filings/scratch/repro-007/piroot/")) (make-directory "/tmp/qa-007-proj" t)
(defun qa7-wait (p to what) (let ((s (float-time))) ; bounded wait for one condition
  (while (and (not (funcall p)) (< (- (float-time) s) to)) (accept-process-output nil 0.1))
  (or (funcall p) (error "timeout: %s" what))))
(let* ((chat (with-current-buffer (generate-new-buffer " *qa7-hold*")
               (let ((pilish-executable
                      (list (executable-find "python3")
                            (expand-file-name "test/support/fake_pi.py" qa7-root)))
                     (pilish-extra-args (list "--scenario" "prompt-lifecycle")))
                 (pilish--setup-session "/tmp/qa-007-proj"))))
       (input (buffer-local-value 'pilish--input-buffer chat))
       (sf (lambda () (plist-get (buffer-local-value 'pilish--state chat) :session-file))))
  (qa7-wait (lambda () (plist-get (buffer-local-value 'pilish--state chat) :model)) 10 "hello")
  (with-current-buffer input (erase-buffer) (insert "hold question") (pilish-send))
  (qa7-wait (lambda () (and (eq (buffer-local-value 'pilish--status chat) 'idle) (funcall sf) (file-exists-p (funcall sf)))) 25 "session")
  (let* ((hold (expand-file-name
                "hold.jsonl" (pilish-jsonl-session-dir-for-cwd "/tmp/qa-007-proj")))
         (proc (buffer-local-value 'pilish--process chat)))
    (make-directory (file-name-directory hold) t)
    (copy-file (funcall sf) hold t)
    (pilish--resume-selected-session proc chat hold)
    (qa7-wait (lambda () (equal (funcall sf) hold)) 15 "switch")
    (message "A READY: pid=%s session-file=%s live-paths-in-this-instance=%d"
             (process-id proc) hold
             (hash-table-count (pilish--browse-live-session-paths)))
    (sleep-for 120))) ; idle, holding the session open for Emacs B
EOF
PACKAGE_USER_DIR=$PWD/.cache/elpa/30 emacs --batch -Q -L . --eval '(setq package-user-dir (expand-file-name (getenv "PACKAGE_USER_DIR")))' --eval '(package-initialize)' -l tmp/qa-filings/scratch/repro-007-a.el
```

2. While terminal 1 idles, terminal 2 saves script B and runs the same command with `-l tmp/qa-filings/scratch/repro-007-b.el`. The browser lists the session; the guard returns nil; the delete command runs with `delete-file` advised to record-and-skip, so the fixture survives.

```elisp
cat > tmp/qa-filings/scratch/repro-007-b.el <<'EOF'
(require 'json) (require 'pilish) (require 'pilish-browse)
(defconst qa7-root (file-name-as-directory default-directory)) ; run from repo root
(setenv "PI_CODING_AGENT_DIR" (concat qa7-root "tmp/qa-filings/scratch/repro-007/piroot/"))
(let* ((hold (expand-file-name "hold.jsonl" (pilish-jsonl-session-dir-for-cwd "/tmp/qa-007-proj")))
       (buf (with-current-buffer (generate-new-buffer "*qa7-browser*")
              (setq default-directory "/tmp/qa-007-proj")
              (pilish-session-browser-mode) (current-buffer))))
  (princ (format "B live-session-paths: %d\nB guard for hold.jsonl: %S\n"
                 (hash-table-count (pilish--browse-live-session-paths))
                 (pilish--browse-live-session-chat-buffer hold)))
  (cl-letf (((symbol-function 'run-at-time)
             (lambda (_s _r fn &rest args) (apply fn args))))
    (with-current-buffer buf (pilish--session-browser-fetch-and-render))
    (with-current-buffer buf
      (goto-char (point-min)) (search-forward "hold question") (beginning-of-line)
      (let (called prompt)
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (q) (setq prompt q) t))
                  ((symbol-function 'delete-file)
                   (lambda (p &optional _t) (setq called p) nil)))
          (setq this-command 'pilish-session-browser-delete)
          (call-interactively #'pilish-session-browser-delete))
        (princ (format "B PROMPT: %s\n"
                       (substring prompt 0 (min 92 (length prompt)))))
        (princ (format "B GUARD RESULT: delete-file %S (record only, skipped)\n"
                       called))))))
EOF
```

3. Verified output from both terminals — guard nil in terminal 2, prompt shown, delete-file called with the exact path terminal 1 holds; without the recording advice the file would be gone under its running session:

```text
A READY: pid=1501379 session-file=.../piroot/sessions/--tmp-qa-007-proj--/hold.jsonl live-paths-in-this-instance=1
B live-session-paths: 0
B guard for hold.jsonl: nil
B PROMPT: Permanently delete session file in project "qa-007-proj" — session "hold question". Continue
B GUARD RESULT: delete-file ".../piroot/sessions/--tmp-qa-007-proj--/hold.jsonl" (record only, skipped)
```

With both sessions in ONE Emacs, the same delete is correctly refused — "Session is open in *pilish-chat:/tmp/qa-007-proj/* — close it first"; QA verified that control too.

## Why it happens

Emacs keeps no process registry across instances, and pilish keeps no cross-instance state. `pilish--session-live-process-p` (pilish-ui.el:1873-1875) is just `process-live-p`, and the browser rows come from a disk scan. Nothing on the delete path looks at the file itself: no mtime, no size, no lock — the re-checks after confirmation (pilish-browse.el:2856, :2864) consult the same per-instance table and a canonical-path comparison. The guard truthfully answers "is it open here?"; the prompt presents the answer as "is it open at all?".

## Fixing it

Three directions, cheapest first. (a) Say so in the confirmation prompt — "this check only covers this Emacs instance": one line, removes the false assurance. (b) Compare the file's mtime and size against a reading taken before the prompt and refuse if changed: catches a writer that was active moments before; the race window narrows but remains. (c) Have live sessions write a claim sidecar and refuse deletes on an unexpired claim: strongest, but adds on-disk state, stale-lock handling, and more TRAMP non-atomicity. Recommend (a) and (b): the prompt must stop overstating the check, and a cheap stat picks up the common case of a still-running writer.

## References

- pilish-browse.el:2627-2664 — the live-detection helpers (`(process-list)` at :2640 and :2653, instance boundary documented at :2635) and `pilish--browse-ensure-session-closed` with its refusal at :2663. https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-browse.el#L2627-L2664
- pilish-browse.el:2816 — `pilish-session-browser-delete`; boundary docstring at :2834-2835, checks at :2856 and :2864, `delete-file` at :2878. https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-browse.el#L2816
- pilish-ui.el:1873-1875 — `pilish--session-live-process-p` is `process-live-p` and nothing more (https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-ui.el#L1873-L1875); AGENTS.md:70 — "TRAMP non-atomicity and independent-writer races are documented constraints" (https://github.com/dnouri/pilish/blob/ccbbb5e/AGENTS.md#L70).

*Bug report generated by GLM-5.3 during an automated QA pass (2026-09-19); not human-written.*
