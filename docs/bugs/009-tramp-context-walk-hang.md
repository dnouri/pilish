# Expanding the session summary re-stats every ancestor directory on every TAB, and hangs on remote sessions

## What you see

You open a session whose directory is on a remote host and press TAB to expand the session summary. Emacs freezes for seconds, then the summary appears. It happens every time you expand the banner, because nothing is remembered from the last time.

## What happens

The expanded banner lists the context files pi would load. To find them, `pilish--startup-context-files` (pilish-ui.el:2618-2641) probes five candidate names (`AGENTS.override.md`, `AGENTS.md`, `AGENTS.MD`, `CLAUDE.md`, `CLAUDE.MD`, pilish-ui.el:2603-2606) in `~/.pi/agent` and then in the session directory and every ancestor directory up to `/`. Each probe is `(file-exists-p path) (file-regular-p path)` (pilish-ui.el:2615). There is no cache. The logo SVG has one (`pilish--logo-svg-cache`, pilish-ui.el:2513, filled at 2525-2526); the context walk has nothing. The walk runs whenever the expanded banner is rendered: `pilish--format-startup-banner-expanded` calls it at pilish-render.el:4043, reached from TAB via `pilish--toggle-startup-banner-at-point` (pilish-render.el:4103, entered from `pilish-toggle-tool-section`, pilish-render.el:4177).

Measured locally (QA, tmp/qa-menu/spike1-context.log): a 15-level-deep tree with context files costs 106 `file-exists-p` plus 5 `file-regular-p` calls per expansion; with no context files in the tree, nothing short-circuits and the count is 117; a shallow tree costs 39. Collapse then expand again and the whole walk runs from scratch. Frequency, stated honestly: this is not on every header refresh. The refresh paths (the get_commands callback, pilish-ui.el:1847, and the version probe, pilish-ui.el:2496) re-render only the compact line and are no-ops while the banner is expanded (pilish-ui.el:2695-2697), so they never touch the walk. During ordinary turns the walk does not run at all; the counts above are for expansions. Locally this is tens of stat calls, which is negligible.

The teeth are remote sessions. Pilish supports sessions on remote hosts, and the walk probes with plain `file-exists-p` and `file-regular-p` on names under the session directory. On a TRAMP path those are synchronous network round-trips, one per probe, taken sequentially. Nothing here has been measured over TRAMP; the amplification is a code read. But the arithmetic is plain: roughly 100 probes per expansion, each a round-trip, is a multi-second freeze on any ordinary network, every time the user expands the banner. The walk itself is correct — precedence (override before AGENTS.md before CLAUDE.md), nearest directory first, user file first, duplicates removed, labels right; QA verified all of it. The defect is cost, not results.

## How to reproduce

1. Clone dnouri/pilish, check out ccbbb5e, run `make deps` once to fill .cache/elpa/30, and work from the repo root. Save the script below to tmp/qa-filings/scratch/repro-009.el, run the batch command, and read the per-expansion counts. The second expansion in each pair repeats the full walk.

```bash
mkdir -p tmp/qa-filings/scratch
cat > tmp/qa-filings/scratch/repro-009.el <<'EOF'
(require 'cl-lib) (require 'package) (package-initialize)
(add-to-list 'load-path (locate-dominating-file load-file-name "AGENTS.md"))
(add-to-list 'treesit-extra-load-path (expand-file-name "~/.emacs.d/tree-sitter"))
(require 'pilish)
(defvar q9-fe 0) (defvar q9-fr 0)
(defun q9-advice-fe (orig fn &rest args) (cl-incf q9-fe) (apply orig fn args))
(defun q9-advice-fr (orig fn &rest args) (cl-incf q9-fr) (apply orig fn args))
(advice-add 'file-exists-p :around #'q9-advice-fe)
(advice-add 'file-regular-p :around #'q9-advice-fr)
(defun q9-reset () (setq q9-fe 0 q9-fr 0))
(defconst q9-base (make-temp-file "qa009-" t))
(defun q9-mkdeep (root)
  (let ((d root)) (dotimes (i 15)
    (setq d (expand-file-name (format "l%02d" (1+ i)) d)))
    (make-directory d t) d))
(defun q9-plant (base)            ; six candidates as in the QA fixture
  (dolist (spec '(("with/l01/l02/l03" "AGENTS.md")
                  ("with/l01/l02/l03/l04/l05/l06" "AGENTS.md")
                  ("with/l01/l02/l03/l04/l05/l06" "CLAUDE.md")
                  ("with/l01/l02/l03/l04/l05/l06/l07/l08/l09/l10" "CLAUDE.md")
                  ("with/l01/l02/l03/l04/l05/l06/l07/l08/l09/l10/l11/l12" "AGENTS.override.md")
                  ("with/l01/l02/l03/l04/l05/l06/l07/l08/l09/l10/l11/l12" "CLAUDE.md")))
    (make-directory (expand-file-name (nth 0 spec) base) t)
    (with-temp-file (expand-file-name (nth 1 spec) (expand-file-name (nth 0 spec) base))
      (insert "x\n"))))
(defun q9-new-banner-buffer (session-dir)
  (let ((buf (generate-new-buffer " *qa009*")))
    (with-current-buffer buf
      (pilish-chat-mode)
      (setq default-directory session-dir)
      (pilish--set-chat-session-identity session-dir nil)
      (let ((inhibit-read-only t))
        (insert (pilish--format-startup-banner-compact)) (goto-char (point-min))))
    buf))
(defun q9-toggle (buf label)
  (with-current-buffer buf (goto-char (point-min)) (q9-reset)
    (pilish-toggle-tool-section)          ; the real user path: TAB
    (princ (format "%s: file-exists-p=%d file-regular-p=%d\n" label q9-fe q9-fr))))
(q9-plant q9-base)
(princ "=== deep tree (15 levels) WITH context files ===\n")
(let ((buf (q9-new-banner-buffer (q9-mkdeep (expand-file-name "with" q9-base)))))
  (q9-toggle buf "expand") (q9-toggle buf "collapse") (q9-toggle buf "expand") (kill-buffer buf))
(princ "=== deep tree (15 levels) WITHOUT context files (worst case) ===\n")
(let ((buf (q9-new-banner-buffer (q9-mkdeep (expand-file-name "without" q9-base)))))
  (q9-toggle buf "expand") (q9-toggle buf "collapse") (q9-toggle buf "expand") (kill-buffer buf))
(princ "REPRO-009-DONE\n")
EOF
PACKAGE_USER_DIR=$PWD/.cache/elpa/30 emacs --batch -Q -L . \
  --eval '(setq package-user-dir (expand-file-name (getenv "PACKAGE_USER_DIR")))' \
  --eval "(add-to-list 'treesit-extra-load-path (expand-file-name \"~/.emacs.d/tree-sitter\"))" \
  --eval '(package-initialize)' \
  -l tmp/qa-filings/scratch/repro-009.el
```

Verified output (counts scale with ancestor depth, so absolute numbers vary with where the tree is created):

```text
=== deep tree (15 levels) WITH context files ===
expand: file-exists-p=86 file-regular-p=5
collapse: file-exists-p=0 file-regular-p=0
expand: file-exists-p=86 file-regular-p=5
=== deep tree (15 levels) WITHOUT context files (worst case) ===
expand: file-exists-p=97 file-regular-p=1
collapse: file-exists-p=0 file-regular-p=0
expand: file-exists-p=97 file-regular-p=1
REPRO-009-DONE
```

The expansion pays the full probe bill every time; the collapse and the refresh paths pay nothing. Each probe is a synchronous TRAMP round-trip when the session directory is remote, so these counts translate to that many network waits per expansion.

## Why it happens

The five-candidate loop exists because pi honors several file names and precedence matters, and the ancestor loop exists because pi loads context from every level. Rendering the expanded banner re-derives the list instead of consulting a cache, and only the logo got a cache.

## Fixing it

Cache the discovered list per session directory, the way `pilish--logo-svg-cache` works, and invalidate when the session directory changes. The tradeoff: a context file added mid-session will not appear until the user re-enters the session or asks for a refresh. That is acceptable for a display list. Separately, replace the five per-candidate probes with one `directory-files` call per directory, which turns five round-trips per ancestor into one and also simplifies precedence handling to a lookup in the returned listing. Do both.

## References

- pilish-ui.el:2615 — the per-candidate probe: `file-exists-p` then `file-regular-p`. https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-ui.el#L2615
- pilish-ui.el:2618-2641 — `pilish--startup-context-files`: user dir plus every ancestor, uncached. https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-ui.el#L2618-L2641
- pilish-render.el:4043 — the walk call inside the expanded banner render; TAB expansion reaches it at :4103. https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-render.el#L4043
- pilish-ui.el:2513-2526 — the logo cache the walk lacks. https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-ui.el#L2513-L2526
- pilish-ui.el:2695-2697 — refresh is a no-op while expanded; refresh paths never walk. https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-ui.el#L2695-L2697
- tmp/qa-menu/spike1-context.log — measured counts: 106+5 per expansion, 117 with nothing found, 39 shallow, zero during turns.

*Bug report generated by GLM-5.3 during an automated QA pass (2026-09-19); not human-written.*
