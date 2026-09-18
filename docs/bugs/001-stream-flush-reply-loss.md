# A failed stream-delta flush silently deletes part of the reply

## What you see

Part of the assistant's reply is missing from the chat. A phrase, a sentence, sometimes a whole closing paragraph, is simply not there. The model wrote it; the session file on disk still has it; the buffer does not. The only warning is one line in the echo area, `pilish: stream delta flush failed: ...`, easy to miss, and nothing after the gap looks wrong. Waiting, sending another message, toggling the thinking display — none of it brings the text back, and nothing tells you text is missing.

## What happens

While the model streams, Pilish does not insert each token as it arrives. It queues text and thinking deltas and flushes them in batches: from a timer (`pilish--schedule-stream-delta-flush`, pilish-render.el:781) and synchronously before every non-delta event. The flush, `pilish--flush-stream-deltas` (pilish-render.el:802), stages the batch, clears the queue, then renders it inside one `condition-case` (pilish-render.el:827). If anything signals while the batch is being inserted, the handler (pilish-render.el:842-845) prints one line and returns; the rest of the batch is thrown away. The docstring calls this deliberate: discarding is held to beat risking duplicated partial output, and "canonical history or reload is the recovery path".

That recovery path does not exist. The one function that could repaint the buffer from the canonical record, `pilish--rerender-canonical-history` (pilish-render.el:7437), has no production callers; only tests call it. `agent_end` stores the full message but never repaints it — `pilish--display-agent-end` (pilish-render.el:867) only trims a trailing partial and inserts `[Aborted]` after an abort. So the hole stays for the life of the buffer, and only `pilish-reload` or `/resume`, which rebuild history from disk, restores the text.

What can signal during a flush? More than you might expect. The flush suspends only one allowlisted md-ts hook (pilish-render.el:828-829); jit-lock, md-ts's other change hooks, and every before/after-change hook installed by the user or a minor mode still run inside the batch loop. Any of them that signals drops the reply text.

One trigger needs nothing exotic. `pilish--ensure-treesit-queries` (pilish-table.el:160-171) calls `treesit-query-compile` with no guard, asking for a `pipe_table` node. With a markdown tree-sitter grammar that has no `pipe_table`, every table-adjacent flush raises `treesit-query-error`, and whatever text was queued with the table is discarded. Session setup already warns once about exactly this (`pilish--maybe-warn-incompatible-markdown-grammar`, pilish-ui.el:2381), but a one-time warning neither guards decoration nor repeats when flushes start failing.

## How to reproduce

The repro runs against a clone of `dnouri/pilish` at `ccbbb5e` with dependencies installed (`make deps` — `.cache/elpa/30` is not in git, and `(require 'pilish)` fails without it because pilish-ui.el hard-requires `md-ts-mode`) and drives the same display path a live session uses: three delta batches stream in, a change hook fails during the second batch's flush, and the model then delivers its full text at `message_end`, as it does in reality.

1. Save this as `repro.el` in the repository root:

```elisp
;;; repro.el --- a failed flush deletes part of the reply -*- lexical-binding: t; -*-
(package-initialize)
(require 'pilish)
(add-to-list 'load-path (expand-file-name "test"))
(require 'pilish-test-common)

(defun repro-glitch (_beg _end)
  (error "repro: simulated per-change hook failure"))

(with-temp-buffer
  (pilish-chat-mode)
  (pilish--handle-display-event '(:type "agent_start"))
  (pilish--handle-display-event '(:type "message_start" :message (:role "assistant")))
  (dolist (c '("ONE-a " "ONE-b "))   ; batch 1: flushes normally
    (pilish-test--send-assistant-message-update `(:type "text_delta" :delta ,c)))
  (pilish--flush-stream-deltas)
  (dolist (c '("TWO-a " "TWO-b "))   ; batch 2: its flush will fail
    (pilish-test--send-assistant-message-update `(:type "text_delta" :delta ,c)))
  (add-hook 'before-change-functions #'repro-glitch nil 'local)
  (pilish--flush-stream-deltas)
  ;; The flush restores the hook list it saved, so unhook from here.
  (remove-hook 'before-change-functions #'repro-glitch 'local)
  (dolist (c '("THREE-a " "THREE-b ")) ; batch 3: flushes normally
    (pilish-test--send-assistant-message-update `(:type "text_delta" :delta ,c)))
  (pilish--flush-stream-deltas)
  ;; message_end carries the full text, as it does in a live session.
  (pilish--handle-display-event
   `(:type "message_end" :message (:role "assistant"
                                   :content ,(vector (list :type "text"
                                                           :text "ONE-a ONE-b TWO-a TWO-b THREE-a THREE-b\n"))
                                   :stopReason "stop")))
  (pilish--handle-display-event '(:type "agent_end" :messages []))
  (let ((final (buffer-substring-no-properties (point-min) (point-max))))
    (message "FINAL BUFFER:\n%s" final)
    (message "RESULT: one=%s two=%s three=%s"
             (and (string-match-p "ONE-b" final) t)
             (and (string-match-p "TWO-a" final) t)
             (and (string-match-p "THREE-b" final) t))))
```

2. From the repository root, run:

```bash
PACKAGE_USER_DIR=$PWD/.cache/elpa/30 emacs --batch -Q -L . --eval '(setq package-user-dir (expand-file-name (getenv "PACKAGE_USER_DIR")))' --eval '(package-initialize)' -l repro.el
```

3. The buffer keeps ONE and THREE and loses TWO, even though `message_end` carried the full text:

```
pilish: stream delta flush failed: repro: simulated per-change hook failure
FINAL BUFFER:

Assistant
=========

ONE-a ONE-b THREE-a THREE-b 

RESULT: one=t two=nil three=t
```

The failure is deterministic and needs no timers or sleeps: the flush is called synchronously. An automated QA harness demonstrated the same loss end-to-end with a real `test/support/fake_pi.py` subprocess, streaming a table reply through md-ts mode with a one-shot failing change hook installed mid-reply.

## Why it happens

The flush treats any error as unrecoverable and empties the queue. That is the safe choice against duplicated text, but only if something repaints the canonical copy afterwards. Nothing does. The canonical record is complete — the disk session file keeps everything — yet the display layer never goes back to it after an error. So a display-layer hiccup permanently changes what the user thinks the model said.

## Fixing it

Three directions, in increasing order of ambition.

- **(a) Guard the query compile.** Wrap `pilish--ensure-treesit-queries` in a `condition-case`; on `treesit-query-error`, cache a "no queries" result and let table decoration fall back to raw text. The grammar smoke test `pilish--markdown-grammar-compatible-p` (pilish-grammars.el:133) is a ready-made detector to reuse. Smallest change, and it removes the one deterministic trigger — but a signaling user hook would still discard text.
- **(b) Retain and retry.** On flush error, push the unrendered remainder back onto the pending queue and retry on the next tick, with a cap. The tradeoff is the one the discard was chosen to avoid: a partially inserted chunk can come through twice unless the queue is tracked per chunk.
- **(c) Canonical repaint on error.** Set a buffer-local flag when a flush fails; when the message finishes, give `pilish--rerender-canonical-history` its first production caller, scoped to the just-finished message. Timing note: `pilish--canonical-messages` is populated only at `agent_end` (pilish-render.el:1638), so a repaint at `message_end` cannot read the just-finished message from the store — repaint at `agent_end` after the store, or use the `message_end` payload directly. This is the structural fix, and it doubles as the backstop for the related history-replay truncation bug.

Recommend (c) plus (a). (a) closes the known deterministic hole now; (c) makes the display converge on stored truth after any flush error, whatever its source, repainting only when an error was actually recorded.

## References

- `pilish--flush-stream-deltas`, pilish-render.el:802 — https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-render.el#L802
- Its `condition-case`, pilish-render.el:827 — https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-render.el#L827
- The discard handler, pilish-render.el:842-845 — https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-render.el#L842
- `pilish--rerender-canonical-history`, pilish-render.el:7437 — https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-render.el#L7437
- `pilish--ensure-treesit-queries`, pilish-table.el:160-171 — https://github.com/dnouri/pilish/blob/ccbbb5e/pilish-table.el#L160
- Related: 006-history-replay-truncation.md (same missing-recovery family)

*Bug report generated by GLM-5.3 during an automated QA pass (2026-09-19); not human-written.*
