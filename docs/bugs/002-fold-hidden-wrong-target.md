# Session browser: evil's j lands inside folded rows, and d can then delete a session you cannot see

## What you see

You fold a family in the session browser and its rows disappear, as they should. You press `j` to move down one row and the cursor seems to freeze. It has actually moved onto a row that is folded away. Press `d` and Emacs offers to delete that hidden session — not any row on your screen.

## What happens

Folds are invisible overlays marked with the `cursor-intangible` property (pilish-browse.el:1685). That property exists to keep point out of hidden text, but Emacs honors it only in buffers that enable `cursor-intangible-mode`. `pilish-browse-mode` never does (pilish-browse.el:2058-2069), so the marking is inert. The docstring of `pilish--browse-repair-folded-points` still promises to move points "out of folded row extents" (pilish-browse.el:1713), yet that repair runs only when the fold display is refreshed — never after ordinary motion.

The guard that does work, `pilish--browse-skip-folded-section` (pilish-browse.el:1790), hangs on `magit-section-movement-hook`. Magit's own section commands pass through it. So do plain Emacs motions on a real display: `next-line`, `previous-line`, isearch, and mouse clicks were all verified under a GUI, and all of them skip the fold. This bug bites evil users. Evil binds `j` and `k` to its own line commands, which never run magit's hook. Pressing `j` on a folded header puts point inside the invisible extent, `magit-current-section` then reports the hidden child session, and the position survives redisplay. Evil users do keep one safe path: `pilish-evil.el` binds `n` and `p` to magit's section commands — only `j` and `k` fall through.

From there the browser trusts point: `d` offers to delete the hidden session and `RET` would switch to it. The `y-or-n-p` prompt does name its target; that prompt is the only protection.

## How to reproduce

1. Save this script as `repro-fold-evil.el` in the project root. It builds a parent session and one fork under temporary directories (fixture layout per `test/pilish-browse-test.el`), opens the real session browser over them, folds the family, and presses `j`:

```elisp
;;; repro-fold-evil.el --- evil j enters folded browser rows -*- lexical-binding: t; -*-
(require 'package)
(package-initialize)
(require 'evil) (require 'pilish)

(defvar repro-buf nil "Browser buffer under test.")

(defun repro-report (label)
  (with-current-buffer repro-buf
    (let* ((sec (ignore-errors (magit-current-section)))
           (val (and sec (slot-exists-p sec 'value) (oref sec value))))
      (princ (format "%-16s point=%d invisible=%s line=%S session=%S cursor-intangible-mode=%s\n"
                     label (point) (invisible-p (point))
                     (string-trim (buffer-substring-no-properties
                                   (line-beginning-position) (line-end-position)))
                     (and (stringp val) (file-name-nondirectory val))
                     cursor-intangible-mode)))))

;; Build a fake tree under temp dirs: parent session p1 with fork child c1.
(let* ((proj (make-temp-file "pilish-repro-proj" 'directory))
       (piroot (or (getenv "PI_CODING_AGENT_DIR") (make-temp-file "pilish-repro-pi" 'directory)))
       (sessdir (pilish-jsonl-session-dir-for-cwd proj (concat (expand-file-name piroot) "/sessions/")))
       (ts "2026-09-18T10:00:00.000Z")
       (p1 (expand-file-name "p1.jsonl" sessdir))
       (c1 (expand-file-name "c1.jsonl" sessdir))
       (hdr (lambda (id extra) (json-encode (append (list :type "session" :version 3 :id id :timestamp ts :cwd proj) extra))))
       (msg (lambda (id parent role text) (json-encode (list :type "message" :id id :parentId parent :timestamp ts :message (if (equal role "user") `(:role "user" :content ,text) `(:role "assistant" :content [((type . "text") (text . ,text))] :stopReason "end_turn"))))))
       (put (lambda (path lines) (with-temp-file path (insert (mapconcat #'identity lines "\n") "\n")))))
  (make-directory sessdir t)
  (funcall put p1 (list (funcall hdr "sess-p1" nil)
                        (json-encode (list :type "session_info" :id "p1-i" :parentId nil :timestamp ts :name "Parent one"))
                        (funcall msg "p1-u1" nil "user" "parent question") (funcall msg "p1-a1" "p1-u1" "assistant" "parent answer")))
  (funcall put c1 (list (funcall hdr "sess-c1" (list :parentSession p1))
                        (funcall msg "c1-u1" "p1-a1" "user" "child question") (funcall msg "c1-a1" "c1-u1" "assistant" "child answer")))
  ;; Open the real session browser over that tree, fold the family, press j.
  (setenv "PI_CODING_AGENT_DIR" piroot)
  (setq repro-buf (with-current-buffer (generate-new-buffer " *repro-browser*")
                    (setq default-directory proj) (evil-local-mode 1)
                    (pilish-session-browser-mode) (current-buffer)))
  (switch-to-buffer repro-buf)
  (cl-letf (((symbol-function 'run-at-time) (lambda (_s _r fn &rest a) (apply fn a))))
    (with-current-buffer repro-buf (pilish--session-browser-fetch-and-render)))
  (with-current-buffer repro-buf
    (goto-char (point-min)) (search-forward "Parent one") (beginning-of-line)
    (setq this-command 'pilish-browse-toggle-fold)
    (call-interactively #'pilish-browse-toggle-fold)
    (evil-normal-state) (repro-report "on folded header")
    (setq this-command 'evil-next-line) (call-interactively #'evil-next-line)
    (repro-report "after j (evil)") (redisplay)
    (repro-report "after redisplay") (kill-buffer repro-buf)))
```

2. Run it from the project root:

```bash
PACKAGE_USER_DIR=$PWD/.cache/elpa/30 emacs --batch -Q -L . \
  --eval '(setq package-user-dir (expand-file-name (getenv "PACKAGE_USER_DIR")))' --eval '(package-initialize)' -l repro-fold-evil.el
```

3. Read the output. `j` leaves point inside the invisible extent, on the hidden child, and the position survives redisplay:

```text
on folded header point=1 invisible=nil line="▸ Parent one" session="p1.jsonl" cursor-intangible-mode=nil
after j (evil)   point=14 invisible=t line="└─ child question" session="c1.jsonl" cursor-intangible-mode=nil
after redisplay  point=14 invisible=t line="└─ child question" session="c1.jsonl" cursor-intangible-mode=nil
```

By hand, on any project with a branched session: open the browser, put point on a family header, press TAB to fold it, press `j`, then press `d` — the prompt names a session that is not on the screen.

An automated QA harness reproduced the same state under a real GUI (xvfb) and confirmed that it survives redisplay.

## Why it happens

The fold design carries its own point discipline, written twice. At the property level, every fold overlay sets `cursor-intangible` (pilish-browse.el:1685) — inert without `cursor-intangible-mode`, which nothing turns on. At the hook level, `pilish--browse-skip-folded-section` (pilish-browse.el:1790) repairs point only for callers of magit's movement hook, and evil's motions are not among them. The repair in `pilish--browse-repair-folded-points` (pilish-browse.el:1713) runs only inside the fold refresh path, so a stray position is never revisited. The consumer commands close the circle: `pilish-session-browser-delete`, `-rename`, and `-switch` take the section at point and act on it, without checking that the section is visible. Every layer assumes some other layer keeps point honest. For evil users, no layer does.

## Fixing it

- Enable `cursor-intangible-mode` in `pilish-browse-mode`. This is what the property at pilish-browse.el:1685 was written for, and it is a one-line change; the tradeoff is that it reshapes motion across browser buffers, so magit's section commands need a pass to confirm they still behave.
- Run point repair on `post-command-hook`, buffer-locally. This catches every path, including isearch and programmatic jumps; the tradeoff is work on every keystroke, so it must exit early when no fold overlays exist.
- Make `d`, `r`, and `RET` verify that the section at point is visible before acting. This catches the harm at the moment it happens, however point got there; the tradeoff is that it treats consequences, not the stuck cursor.

Recommended: the first and the last together. The property already exists in the code, and the command-level check covers every path the property cannot.

## References

- `pilish-browse.el:1685` — fold overlays get `cursor-intangible t`: https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-browse.el#L1685
- `pilish-browse.el:2058-2069` — `pilish-browse-mode` body, which never enables `cursor-intangible-mode`: https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-browse.el#L2058
- `pilish-browse.el:1790` — `pilish--browse-skip-folded-section`, installed on `magit-section-movement-hook` only: https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-browse.el#L1790

*Bug report generated by GLM-5.3 during an automated QA pass (2026-09-19); not human-written.*
