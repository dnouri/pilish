# A future md-ts upgrade silently disables hook suspension, and resuming a session starts taking seconds

## What you see

Months from now you upgrade md-ts. Nothing warns you; the upgrade looks clean. From that day, resuming a session takes several seconds instead of an instant, every time. Emacs gives no error and no hint of why.

## What happens

Pilish keeps history replay and stream flushing cheap by removing md-ts's per-change hooks from the buffer while it rebuilds text. Which hooks to remove is decided by a name allowlist, `pilish--md-ts-known-change-hooks` (pilish-render.el:114-118): four function names, copied from md-ts 0.4. `Package-Requires` pins only a lower bound, `(md-ts-mode "0.4.0")` (pilish.el:14), so package.el upgrades md-ts freely.

That allowlist is a snapshot of md-ts internals, but the dependency it snapshots floats. Today the installed md-ts (md-ts-mode-20260823.1701) still uses those four names (md-ts-mode.el:2016, 2032, 3859, 3872), so the bug is latent. If a future md-ts renames hooks, the allowlist stops matching the renamed ones. Suspension of each unmatched hook quietly becomes a no-op: it stays installed and runs on every change. No version probe, no warning.

The replay path suspends all four hooks around the whole rebuild (pilish-render.el:7538); stream flushes suspend the expensive subset (pilish-render.el:828). Measured on a 250-message replay (tmp/qa-hover/spike4b-timing.el, spike4d-mechanism.el):

- Suspension working: 0.005-0.035s.
- Allowlist matching nothing (skew): 3.3-5.8s — 120-850x, depending on machine and run.
- Worse: one skewed replay leaves the same buffer permanently degraded. Later replays with the working allowlist still took ~0.9-1.2s in that buffer, against 0.005-0.006s fresh (tmp/qa-review/t4-persist.el). The unsuspended pass left ~1004 treesit parser overlays and ~2005 md-ts dirty-side-effect-bounds entries behind (spike4d, spike4e); the suspended path never cleans them. Killing the buffer restores full speed: the pollution is per-buffer.

The defect is the silence. When skew arrives, every resume becomes a multi-second hang, and nothing connects it to an md-ts upgrade months earlier.

## How to reproduce

1. Clone dnouri/pilish, check out ccbbb5e, and work from the repo root. Save the script below to tmp/qa-filings/scratch/repro-008.el, run the batch command, and read the four timing lines.

```elisp
mkdir -p tmp/qa-filings/scratch
cat > tmp/qa-filings/scratch/repro-008.el <<'EOF'
(require 'package) (package-initialize) (require 'cl-lib) (require 'pilish)

(defun r8-msgs (n)
  (let ((m (make-vector (* 2 n) nil)))
    (dotimes (i n)
      (aset m (* 2 i) (list :role "user" :timestamp (+ 1700000000000 (* i 1000))
                            :content (vector (list :type "text" :text (format "Question %d with some prose body text to render." i)))))
      (aset m (1+ (* 2 i)) (list :role "assistant" :timestamp (+ 1700000000500 (* i 1000))
                                 :provider "ollama" :model "qwen3:1.7b"
                                 :content (vector (list :type "text" :text (format "Answer %d: reply prose with **bold** and `code` spans.\n\nSecond line %d." i i)))
                                 :usage (list :input 100 :output 50 :cacheRead 0 :cacheWrite 0 :totalTokens 150 :total 0.0))))
    m))

(defun r8-replay (buf msgs)                  ; one timed display pass
  (let ((t0 (float-time)))
    (with-current-buffer buf (pilish--display-session-history msgs buf))
    (- (float-time) t0)))

(defun r8-state (buf)                        ; leftover overlays + md-ts dirty bounds
  (with-current-buffer buf
    (format "overlays=%d dirty-bounds=%d" (length (overlays-in (point-min) (point-max)))
            (length md-ts--font-lock-dirty-side-effect-bounds))))

(let* ((msgs (r8-msgs 250)) (buf (generate-new-buffer " *r8-main*")))
  (with-current-buffer buf (pilish-chat-mode))
  (let ((t1 (r8-replay buf msgs)))           ; 1. fresh buffer, working allowlist
    ;; 2. cl-letf empties the allowlist, simulating an md-ts rename: all four hooks then stay installed.
    (let ((t2 (cl-letf (((default-value 'pilish--md-ts-known-change-hooks) nil))
                (r8-replay buf msgs)))
          (t3 (r8-replay buf msgs))          ; 3. same buffer, allowlist restored
          (state (r8-state buf)))
      (kill-buffer buf)
      (let* ((buf2 (generate-new-buffer " *r8-fresh*")) (t4 (with-current-buffer buf2 (pilish-chat-mode) (r8-replay buf2 msgs))))
        (kill-buffer buf2)
        (princ (format "STATE left in *r8-main* by steps 2-3: %s\n" state))
        (princ (format "T1 fresh buffer, working allowlist (suspended):   %.3fs\n" t1))
        (princ (format "T2 same buffer, empty allowlist (skewed replay):    %.3fs\n" t2))
        (princ (format "T3 same buffer, working allowlist again (damaged):  %.3fs\n" t3))
        (princ (format "T4 fresh buffer, working allowlist (recovered):     %.3fs\n" t4))))))
EOF
PACKAGE_USER_DIR=$PWD/.cache/elpa/30 emacs --batch -Q -L . \
  --eval '(setq package-user-dir (expand-file-name (getenv "PACKAGE_USER_DIR")))' \
  --eval "(add-to-list 'treesit-extra-load-path (expand-file-name \"~/.emacs.d/tree-sitter\"))" \
  --eval '(package-initialize)' \
  -l tmp/qa-filings/scratch/repro-008.el
```

One honest limit: step 2 empties the allowlist directly. A real rename leaves the list populated but unmatched for the renamed hook; the effect on that hook is identical, because `pilish--md-ts-change-hook-p` is a `memq` on those names (pilish-render.el:140-150). Verified output:

```text
STATE left in *r8-main* by steps 2-3: overlays=1004 dirty-bounds=2005
T1 fresh buffer, working allowlist (suspended):   0.007s
T2 same buffer, empty allowlist (skewed replay):    3.983s
T3 same buffer, working allowlist again (damaged):  0.981s
T4 fresh buffer, working allowlist (recovered):     0.005s
```

T2 is over 500x T1; T3 shows the damage survives even after suspension works again; T4 shows a fresh buffer recovers.

## Why it happens

The suspension wrapper strips hooks whose names the predicate accepts and puts them back afterwards (pilish-render.el:157-192). It cannot notice that md-ts installed hooks the list does not name. That failure mode was chosen as correctness-safe: unknown hooks keep running, which is slow but not wrong. The cost is that nothing signals.

The damage then compounds. When the hooks run over a full-buffer rebuild, md-ts records dirty bounds and tree-sitter leaves parser overlays. A later suspended replay never removes them; suspension only restores hook lists and does no cleanup. So one unlucky resume slows every later resume in that buffer. Resume is the biggest replay a user normally triggers, so a few seconds there reads as Emacs freezing.

## Fixing it

- Probe and warn. At load or on the first replay, compare md-ts's actually-installed change hooks against the allowlist; emit one message when they no longer match. Cheap, needs nothing from md-ts, and turns silent degradation into a visible one-line explanation.
- Discover the hooks from md-ts itself instead of a pinned name list, if md-ts exposes or adds a stable seam (a declared variable naming its per-change hooks). Robust to renames; depends on an upstream API change.
- Clean leftover parser overlays and dirty bounds after each replay, regardless of suspension. The natural seam is `pilish--clear-render-artifacts` (pilish-render.el:1735), which already runs at the start of every rebuild and deliberately leaves tree-sitter overlays alone; a fix revisits that skip. Bounds the damage of any skew; costs a little bookkeeping on the hot path.

Recommendation: do 1 now as the minimum. Do 2 if md-ts exposes the seam. Add 3 to contain the same-buffer pollution even once a warning exists.

## References

1. pilish-render.el:114-118 — `pilish--md-ts-known-change-hooks`, the pinned name allowlist. https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-render.el#L114-L118
2. pilish-render.el:828 — stream-flush suspension of the expensive subset. https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-render.el#L828
3. pilish-render.el:7538 — full-history replay suspension of all known hooks. https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-render.el#L7538
4. pilish-render.el:157-192 — the suspension macro: strip by predicate, restore, no cleanup. https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-render.el#L157-L192
5. pilish.el:14 — `Package-Requires` pins `(md-ts-mode "0.4.0")`, a lower bound only. https://github.com/dnouri/pilish/blob/ccbbb5e/pilish.el#L14
6. Evidence: tmp/qa-hover/spike4b-timing.el (timing matrix; logs/spike4b-timing.log), spike4d-mechanism.el and spike4e-overlays.el (1004 leftover overlays, 2005 dirty bounds), tmp/qa-review/t4-persist.el (per-buffer pollution, recovery on kill).

*Bug report generated by GLM-5.3 during an automated QA pass (2026-09-19); not human-written.*
