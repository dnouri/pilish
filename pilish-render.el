;;; pilish-render.el --- Chat rendering and tool display -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel Nouri

;; Author: Daniel Nouri <daniel.nouri@gmail.com>
;; Maintainer: Daniel Nouri <daniel.nouri@gmail.com>
;; URL: https://github.com/dnouri/pilish

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Rendering module for Pilish: streaming chat display, tool output,
;; and fontification.
;;
;; This module handles everything that appears in the chat buffer:
;; - Streaming message display (text deltas, thinking blocks)
;; - Tool call output (overlay creation, streaming preview, toggle)
;; - Event dispatching (handle-display-event)
;; - Streaming fontification (incremental syntax highlighting)
;; - Diff overlay highlighting
;; - Compaction display
;; - File navigation from strict tool rows, plain paths, and local
;;   Markdown labels
;; - Session history display and rendering
;; - Literal details on completed replies, thinking, and tools for explicit Help

;;; Code:

(require 'pilish-ui)
(require 'pilish-table)
(require 'cl-lib)
(require 'ansi-color)
(require 'image)
(require 'url-util)
(require 'help-mode)

;; Forward references for functions in other modules
(declare-function pilish-compact "pilish-menu" (&optional custom-instructions))
(declare-function pilish-open-subagent-snapshot "pilish-snapshot" (&optional target))
;; Declare the Emacs 29 minimum API.  Adding Emacs 30's optional TAG here makes
;; its byte compiler pad three-argument calls, producing incompatible bytecode.
(declare-function treesit-parser-create "treesit.c"
                  (language &optional buffer no-reuse))
(declare-function treesit-parser-delete "treesit.c" (parser))
(declare-function treesit-parser-list "treesit.c"
                  (&optional buffer language tag))
(declare-function treesit-parser-language "treesit.c" (parser))
(declare-function treesit-parser-notifiers "treesit.c" (parser))
(declare-function treesit-parser-add-notifier "treesit.c" (parser function))
(declare-function treesit-parser-included-ranges "treesit.c" (parser))
(declare-function treesit-parser-root-node "treesit.c" (parser))
(declare-function treesit-parser-set-included-ranges "treesit.c"
                  (parser ranges))
(declare-function treesit-node-descendant-for-range "treesit.c"
                  (node beg end &optional named))
(declare-function treesit-query-capture "treesit.c"
                  (node query &optional beg end node-only))
(declare-function comint-output-filter "comint" (process string))
(declare-function comint-term-environment "comint" ())
(declare-function shell-mode "shell" ())
(declare-function md-ts--remove-link-button-properties "md-ts-mode" (beg end))
(defvar sh-shell)
(defvar treesit-primary-parser)

(defconst pilish--history-replay-gc-threshold (* 64 1024 1024)
  "Minimum `gc-cons-threshold' used while replaying full session history.")

;;;; Response Display

(defvar-local pilish--defer-history-postprocessing nil
  "Non-nil while replaying history with batched display post-processing.
When set, per-message explicit fontification and table decoration are skipped.
Jit-lock fontifies visible markdown at redisplay; history post-processing only
adds display-only table overlays for the recent hot tail after insertion.")

(defvar-local pilish--streaming-table-candidate nil
  "Non-nil when recent streaming text may contain a markdown pipe table.
Streaming table decoration is comparatively expensive because it queries the
current message with tree-sitter.  Most assistant text is not table content, so
we track whether a pipe has appeared since the last decoration attempt and skip
the query when no table can be present.")

(cl-defstruct (pilish--toolcall-stream
               (:conc-name pilish--tool-stream-)
               (:constructor pilish--make-toolcall-stream))
  "Incremental preview state for one streamed tool call."
  content-index
  tool-call-id
  tool-name
  block
  arguments
  rendered-header-key
  paint-pending-p
  content-render-p
  ;; Last bounded write value that would repaint synchronously.  Partial-only
  ;; deltas may evict complete lines before painting without replacing it.
  content-to-render
  content-truncated
  (depth 0)
  (root-state 'root)
  string-role
  (string-value "")
  current-key
  escape-state
  (unicode-value 0)
  (unicode-digits 0)
  high-surrogate)

(defvar-local pilish--toolcall-streams nil
  "Tool-call generation state keyed by assistant content index.
Pi's RPC protocol streams raw argument JSON deltas without a cumulative
assistant message.  This table exists only while the current assistant message
is being generated; completed tool execution remains keyed separately by tool
call ID in `pilish--live-tool-blocks'.")

(defconst pilish--stream-delta-render-interval 0.05
  "Seconds between coalesced text, thinking and toolcall paints.
Pi emits one `message_update' per streamed token.  Rendering every token
multiplies markdown/tree-sitter change-hook work by the token rate and grows
quadratically with message size.  Pending text is concatenated and toolcall
previews are painted at this cadence, and flushed before any non-delta event,
so display order stays authoritative.  Internal constant, not a user option.")

(defvar-local pilish--pending-stream-deltas nil
  "Reversed list of (KIND . VALUE) streaming updates awaiting rendering.
KIND is `text' or `thinking' with a string VALUE, or `toolcall' with a stream
record VALUE.  Consecutive same-kind text entries are concatenated at flush
time; each toolcall stream has at most one queued paint.")

(defvar-local pilish--stream-delta-flush-timer nil
  "The one pending one-shot streaming delta flush timer, or nil.")

(defvar-local pilish--pending-tool-updates nil
  "Alist of (TOOL-CALL-ID . VALUE) awaiting coalesced rendering.
VALUE is an ordinary partial result or a compound block with retained facts.
Only the latest paint per owner is kept; superseded ordinary snapshots
are dropped.  New entries are pushed, so flushing iterates the reversed
alist to render first-queued-first.")

(defconst pilish--md-ts-known-change-hooks
  '(md-ts--font-lock-record-dirty-side-effect-bounds
    md-ts--font-lock-record-stale-side-effect-bounds
    md-ts--before-change-check-link-reference-definition
    md-ts--after-change-flush-link-reference-links)
  "Complete set of md-ts 0.4 per-change hooks known to Pilish.
Full history replay may suspend exactly these hooks; unknown hooks remain
installed because Pilish has no cost or correctness contract for them.")

(defconst pilish--md-ts-expensive-change-hooks
  '(md-ts--font-lock-record-stale-side-effect-bounds)
  "Expensive subset of `pilish--md-ts-known-change-hooks' for stream flushes.
The stale-side-effect recorder queries tree-sitter over regions that grow with
the buffer.  Coupled to md-ts internals: if md-ts renames it, streaming
suspension silently degrades to running it (correct, only slower).

The paired link-reference before/after hooks are deliberately NOT in this list.
md-ts cheaply prefilters irrelevant edits, while real definition changes must
invalidate distant fontified link buttons.

`md-ts--font-lock-record-dirty-side-effect-bounds' is deliberately NOT in
this list.  It is cheap and keeps md-ts's modified tick and bounded dirty
bounds in sync.  Removing it makes every suspended flush look like an
untracked full-buffer rewrite, so md-ts pushes a full-buffer dirty range on
the next fontification and the dirty-range list grows by one per flush.")

(defun pilish--md-ts-change-hook-p (hook)
  "Return non-nil when HOOK is a known md-ts 0.4 per-change hook.
md-ts-mode installs buffer-local before/after-change hooks that query
tree-sitter on every buffer modification.  Their cost grows with buffer size,
so bulk replay would otherwise pay it quadratically.  jit-lock's own
`jit-lock-after-change' hook is deliberately kept.

Only explicit members of `pilish--md-ts-known-change-hooks' are suspended.
Renamed or future md-ts hooks remain installed (correct, potentially slower)
rather than being suppressed without a known correctness contract."
  (memq hook pilish--md-ts-known-change-hooks))

(defun pilish--md-ts-expensive-change-hook-p (hook)
  "Return non-nil when HOOK is an expensive md-ts per-change hook.
See `pilish--md-ts-expensive-change-hooks'."
  (memq hook pilish--md-ts-expensive-change-hooks))

(defmacro pilish--with-md-ts-change-hooks-suspended (predicate &rest body)
  "Run BODY with md-ts per-change hooks matching PREDICATE removed.
PREDICATE is a function of one hook symbol.  Use
`pilish--md-ts-change-hook-p' for the single bulk history-replay epoch (one
untracked epoch, one dirty range) and
`pilish--md-ts-expensive-change-hook-p' for coalesced streaming flushes (md-ts
keeps its cheap dirty-tick bookkeeping, so repeated suspended inserts do not
accumulate full-buffer dirty ranges).

Restores the hook lists afterwards, preserving whether they were
buffer-local.  `jit-lock-after-change' stays installed, so visible text is
still marked for fontification at the next redisplay."
  (declare (indent 1) (debug t))
  `(let ((pilish--hook-buffer (current-buffer))
         (pilish--saved-before-local
          (local-variable-p 'before-change-functions))
         (pilish--saved-after-local
          (local-variable-p 'after-change-functions))
         (pilish--saved-before before-change-functions)
         (pilish--saved-after after-change-functions))
     (unwind-protect
         (progn
           (setq-local before-change-functions
                       (if (listp before-change-functions)
                           (seq-remove ,predicate before-change-functions)
                         before-change-functions))
           (setq-local after-change-functions
                       (if (listp after-change-functions)
                           (seq-remove ,predicate after-change-functions)
                         after-change-functions))
           ,@body)
       (when (buffer-live-p pilish--hook-buffer)
         (with-current-buffer pilish--hook-buffer
           (if pilish--saved-before-local
               (setq-local before-change-functions pilish--saved-before)
             (kill-local-variable 'before-change-functions))
           (if pilish--saved-after-local
               (setq-local after-change-functions pilish--saved-after)
             (kill-local-variable 'after-change-functions)))))))
(defvar-local pilish--assistant-details-clock nil
  "Current assistant boundary: saved timestamp, local start time, stream seen.
The timestamp matches the final message, never a heading/content index.  Local
samples are display-only and cleared at completion, teardown and rebuild.")

(defvar-local pilish--pending-tool-details nil
  "Call-ID associations awaiting timestamped toolResult messages this run.
Values are weak references to existing finalized tool records: details must not
retain their output, markers, or overlays after cooling.  Entries are removed
on receipt and the table is cleared at agent/session/process teardown.")

(defun pilish--history-postprocessing-deferred-p ()
  "Return non-nil when history display post-processing is currently deferred."
  pilish--defer-history-postprocessing)

(defun pilish--decorate-tables-unless-deferred (start end)
  "Decorate markdown tables between START and END unless deferred."
  (unless (pilish--history-postprocessing-deferred-p)
    (pilish--decorate-tables-in-region start end)))

(defun pilish--display-user-message
    (text &optional timestamp content track-region)
  "Display user message TEXT and optional image CONTENT in the chat buffer.
If TIMESTAMP (Emacs time value) is provided, display it in the header.  When
TRACK-REGION is non-nil, return a marker pair bounding the inserted turn."
  (let* ((chat-buffer (pilish--get-render-buffer))
         (start (with-current-buffer chat-buffer (point-max)))
         (previews (pilish--content-image-previews content)))
    (pilish--append-to-chat
     (concat "\n" (pilish--make-separator "You" timestamp) "\n"
             (or text "") "\n"
             (or (pilish--image-previews-text previews) "")))
    (with-current-buffer chat-buffer
      (pilish--decorate-tables-unless-deferred start (point-max))
      (when track-region
        (cons (copy-marker start nil) (copy-marker (point-max) nil))))))

(defun pilish--discard-local-user-message ()
  "Retract the speculative local user turn when pi handled it invisibly."
  (unwind-protect
      (when-let* ((region pilish--local-user-message-region)
                  (start (marker-position (car region)))
                  (end (marker-position (cdr region)))
                  ((<= start end)))
        (let ((inhibit-read-only t))
          (save-restriction
            (widen)
            (delete-region start end))))
    (setq pilish--local-user-message nil)
    (pilish--clear-local-user-message-region)))

(defun pilish--handle-no-turn-local-prompt ()
  "Release speculative local echo state, then process queued follow-ups."
  (unwind-protect
      (pilish--discard-local-user-message)
    (pilish--process-followup-queue)))

(defun pilish--content-has-image-p (content)
  "Return non-nil if CONTENT has an image block."
  (seq-some (lambda (block)
              (equal (plist-get block :type) "image"))
            (pilish--content-block-list content)))

(defun pilish--local-user-message-matches-p
    (local-message text content)
  "Return non-nil when LOCAL-MESSAGE exactly represents TEXT and CONTENT.
Strings retain the existing text-only echo contract.  Image turns use their
full content vector, so an authoritative image transformation cannot be lost."
  (cond
   ((vectorp local-message)
    (and (vectorp content) (equal local-message content)))
   ((stringp local-message)
    (and text
         (not (pilish--content-has-image-p content))
         (string= text local-message)))))

(defun pilish--display-agent-start ()
  "Display separator for new agent turn.
Only shows the Assistant header once per prompt, even during retries.
Note: status is set to `streaming' by the event handler."
  ;; Only show header if not already shown for this prompt.
  (unless pilish--assistant-header-shown
    (pilish--append-to-chat
     (concat "\n" (pilish--make-separator "Assistant") "\n"))
    (setq pilish--assistant-header-shown t))
  ;; Create markers at current end position
  ;; message-start-marker: where content begins (for later replacement)
  ;; streaming-marker: where new deltas are inserted
  (pilish--set-message-start-marker (copy-marker (point-max) nil))
  (pilish--set-streaming-marker (copy-marker (point-max) t))
  ;; Reset streaming parse state - content starts at line beginning, outside code/thinking block
  (setq pilish--line-parse-state 'line-start)
  (setq pilish--in-code-block nil)
  (setq pilish--in-thinking-block nil)
  (setq pilish--streaming-table-candidate nil)
  (pilish--reset-toolcall-streams)
  (pilish--set-activity-phase "thinking"))

(defun pilish--process-streaming-char (char state in-block)
  "Process CHAR with current STATE and IN-BLOCK flag.
Returns (NEW-STATE . NEW-IN-BLOCK).
STATE is one of: `line-start', `fence-1', `fence-2', `mid-line'."
  (pcase state
    ('line-start
     (cond
      ((eq char ?`) (cons 'fence-1 in-block))
      ((eq char ?\n) (cons 'line-start in-block))
      (t (cons 'mid-line in-block))))
    ('fence-1
     (cond
      ((eq char ?`) (cons 'fence-2 in-block))
      ((eq char ?\n) (cons 'line-start in-block))
      (t (cons 'mid-line in-block))))
    ('fence-2
     (cond
      ((eq char ?`) (cons 'mid-line (not in-block)))  ; Toggle code block!
      ((eq char ?\n) (cons 'line-start in-block))     ; Was just ``
      (t (cons 'mid-line in-block))))                 ; Was inline ``x
    ('mid-line
     (if (eq char ?\n)
         (cons 'line-start in-block)
       (cons 'mid-line in-block)))))

(defun pilish--transform-delta (delta)
  "Transform DELTA for display, handling code blocks and heading levels.
Uses and updates buffer-local state variables for parse state.
Returns the transformed string.

Performance: Uses a two-pass approach.  First checks if transformation
is needed (rare), then only does the work when necessary.  The common
case of no headings is O(n) with no allocations."
  (let ((state pilish--line-parse-state)
        (in-block pilish--in-code-block)
        (len (length delta))
        (needs-transform nil)
        (i 0))
    ;; First pass: check if any transformation is needed and track state
    ;; Also collect positions where we need to insert extra #
    (let ((insert-positions nil))
      (while (< i len)
        (let ((char (aref delta i)))
          ;; Check if we need to add # at this position
          (when (and (eq state 'line-start)
                     (not in-block)
                     (eq char ?#))
            (push i insert-positions)
            (setq needs-transform t))
          ;; Update state
          (let ((new-state (pilish--process-streaming-char char state in-block)))
            (setq state (car new-state))
            (setq in-block (cdr new-state)))
          (setq i (1+ i))))
      ;; Save final state
      (setq pilish--line-parse-state state)
      (setq pilish--in-code-block in-block)
      ;; Fast path: no transformation needed
      (if (not needs-transform)
          delta
        ;; Slow path: build result with extra # at marked positions
        ;; insert-positions is in reverse order (last position first)
        (let ((positions (nreverse insert-positions))
              (result nil)
              (prev-pos 0))
          (dolist (pos positions)
            ;; Add content before this position
            (when (< prev-pos pos)
              (push (substring delta prev-pos pos) result))
            ;; Add the extra #
            (push "#" result)
            (setq prev-pos pos))
          ;; Add remaining content
          (when (< prev-pos len)
            (push (substring delta prev-pos) result))
          (apply #'concat (nreverse result)))))))

(defun pilish--display-message-delta (delta)
  "Display streaming message DELTA at the streaming marker.
Transforms ATX headings (outside code blocks) by adding one # level
to keep our setext H1 separators as the top-level document structure.
During a coalesced flush, Pilish suspends the sole hook in
`pilish--md-ts-expensive-change-hooks',
`md-ts--font-lock-record-stale-side-effect-bounds'.  `jit-lock-after-change',
`md-ts--font-lock-record-dirty-side-effect-bounds', and md-ts's paired
reference-definition hooks remain installed.  Tree-sitter still re-parses at
the C level on each insertion."
  (when (and delta pilish--streaming-marker)
    (let* ((inhibit-read-only t)
           (delta (pilish--render-safe-string delta))
           ;; Strip leading newlines from first content after header
           (delta (if (and pilish--message-start-marker
                          (= (marker-position pilish--message-start-marker)
                             (marker-position pilish--streaming-marker)))
                     (string-trim-left delta "\n+")
                   delta))
           (transformed (pilish--transform-delta delta)))
      (pilish--with-scroll-preservation
        (save-excursion
          (goto-char (marker-position pilish--streaming-marker))
          (insert transformed)
          (set-marker pilish--streaming-marker (point))))
      ;; After inserting text with completed lines, check for active tables only
      ;; if recent streaming text contained a pipe.  This avoids a tree-sitter
      ;; table query on every non-table newline in long assistant messages.
      (when (string-match-p "|" delta)
        (setq pilish--streaming-table-candidate t))
      (when (and pilish--streaming-table-candidate
                 (string-match-p "\n" delta))
        (setq pilish--streaming-table-candidate nil)
        (pilish--maybe-decorate-streaming-table)))))

(defun pilish--thinking-insert-position ()
  "Return insertion position for thinking text.
Prefers `pilish--thinking-marker' when available so interleaved
tool headers do not move the thinking insertion point."
  (if (and pilish--thinking-marker
           (marker-position pilish--thinking-marker))
      (marker-position pilish--thinking-marker)
    (marker-position pilish--streaming-marker)))

(defun pilish--thinking-normalize-text (text)
  "Normalize streaming thinking TEXT for stable markdown rendering.
Removes boundary blank lines and collapses internal blank-line runs to
at most one empty paragraph separator while preserving indentation."
  (let* ((source (or text ""))
         (without-leading-blank-lines
          (replace-regexp-in-string "\\`\\(?:[ \t]*\n\\)+" "" source))
         (without-boundary-blank-lines
          (replace-regexp-in-string "\\(?:\n[ \t]*\\)+\\'" ""
                                    without-leading-blank-lines)))
    (if (string-empty-p without-boundary-blank-lines)
        ""
      (replace-regexp-in-string
       "\n\\(?:[ \t]*\n\\)\\{2,\\}" "\n\n"
       without-boundary-blank-lines))))

(defun pilish--thinking-blockquote-text (text)
  "Convert normalized thinking TEXT to markdown blockquote lines."
  (if (string-empty-p text)
      ""
    (concat "> " (replace-regexp-in-string "\n" "\n> " text))))

(defun pilish--thinking-line-count-label (count)
  "Return COUNT formatted as a singular or plural line label."
  (format "%d line%s" count (if (= count 1) "" "s")))

(defun pilish--thinking-more-lines-label (count)
  "Return COUNT formatted as a singular or plural hidden-line label."
  (format "%d more line%s" count (if (= count 1) "" "s")))

(defun pilish--thinking-first-content-line (normalized)
  "Return the first non-empty trimmed line from NORMALIZED, or nil."
  (catch 'first
    (dolist (line (split-string normalized "\n" nil))
      (let ((trimmed (string-trim line)))
        (unless (string-empty-p trimmed)
          (throw 'first trimmed))))))

(defun pilish--thinking-hidden-stub (normalized)
  "Return the collapsed completed-thinking stub for NORMALIZED."
  (let* ((line-count (length (split-string normalized "\n" nil)))
         (first-line (pilish--thinking-first-content-line normalized))
         (previewable (and pilish-thinking-hidden-preview
                           (> line-count 1)
                           first-line
                           (>= (length first-line) 3)
                           (< (length first-line) 72))))
    (if previewable
        (format "> Thinking: %s… (%s)" first-line
                (pilish--thinking-more-lines-label (1- line-count)))
      (format "> Thinking (%s)" (pilish--thinking-line-count-label line-count)))))

(defun pilish--next-thinking-block-order ()
  "Return the next monotonically increasing completed-thinking block order."
  (let ((order (or pilish--thinking-block-order-counter 0)))
    (setq pilish--thinking-block-order-counter (1+ order))
    order))

(defun pilish--propertize-completed-thinking
    (rendered order normalized display details)
  "Return RENDERED tagged with ORDER, NORMALIZED text, DISPLAY and DETAILS."
  (pilish--apply-completed-thinking-properties
   0 (length rendered) order normalized display details rendered)
  rendered)

(defun pilish--apply-completed-thinking-properties
    (start end order normalized display details &optional object)
  "Tag START..END with ORDER, NORMALIZED text, DISPLAY and literal DETAILS.
OBJECT is a rendered string, or nil for the current buffer."
  (when (< start end)
    (add-text-properties
     start end
     `(pilish-thinking-block ,order
       pilish-thinking-normalized ,normalized
       pilish-thinking-block-display ,display
       rear-nonsticky t) object)
    (pilish--set-details start end details object)
    (pilish--put-disclosure start end (eq display 'visible)
                           #'pilish--toggle-thinking-block-at-point object)))

(defun pilish--owned-span-probe-pos (pos property)
  "Return POS or its preceding character inside an owned PROPERTY span."
  (when (> (point-max) (point-min))
    (let ((probe (max (point-min) (min pos (1- (point-max))))))
      (cond ((get-text-property probe property) probe)
            ((and (> probe (point-min)) (get-text-property (1- probe) property))
             (1- probe))))))

(defun pilish--thinking-block-at-pos (pos)
  "Return completed-thinking block order at POS, or nil."
  (when-let* ((probe (pilish--owned-span-probe-pos pos 'pilish-thinking-block)))
    (get-text-property probe 'pilish-thinking-block)))

(defun pilish--thinking-block-start (block-order)
  "Return the start position of completed thinking BLOCK-ORDER, or nil."
  (when block-order
    (text-property-any (point-min) (point-max)
                       'pilish-thinking-block block-order)))

(defun pilish--thinking-block-bounds-from-probe (probe)
  "Return completed-thinking bounds around PROBE, or nil.
PROBE must already be inside a completed-thinking block."
  (when (get-text-property probe 'pilish-thinking-block)
    (cons (or (previous-single-property-change
               (1+ probe)
               'pilish-thinking-block
               nil
               (point-min))
              (point-min))
          (or (next-single-property-change
               probe
               'pilish-thinking-block
               nil
               (point-max))
              (point-max)))))

(defun pilish--thinking-block-bounds-at-pos (pos)
  "Return bounds of the completed-thinking block at POS, or nil."
  (when-let* ((probe (pilish--owned-span-probe-pos pos 'pilish-thinking-block)))
    (pilish--thinking-block-bounds-from-probe probe)))

(defun pilish--thinking-block-metadata-at-pos (pos)
  "Return completed-thinking block metadata at POS, or nil."
  (when-let* ((probe (pilish--owned-span-probe-pos pos 'pilish-thinking-block))
              (bounds (pilish--thinking-block-bounds-from-probe probe))
              (normalized (get-text-property probe
                                             'pilish-thinking-normalized)))
    (list :order (get-text-property probe 'pilish-thinking-block)
          :display (or (get-text-property probe
                                          'pilish-thinking-block-display)
                       'visible)
          :normalized normalized
          :details (get-text-property probe 'pilish-details)
          :start (car bounds)
          :end (cdr bounds))))

(defun pilish--replace-thinking-region (rendered)
  "Replace the active thinking region with RENDERED text.
RENDERED should already be the markdown to insert, or an empty string to remove
an empty placeholder block.  Returns non-nil when the resulting region is
non-empty."
  (when (and (markerp pilish--thinking-start-marker)
             (markerp pilish--thinking-marker)
             (marker-position pilish--thinking-start-marker)
             (marker-position pilish--thinking-marker))
    (let* ((start (marker-position pilish--thinking-start-marker))
           (end (marker-position pilish--thinking-marker))
           (text (or rendered ""))
           (plain-text (substring-no-properties text))
           (order (and (> (length text) 0)
                       (get-text-property 0 'pilish-thinking-block text)))
           (normalized (and order
                            (get-text-property 0
                                               'pilish-thinking-normalized
                                               text)))
           (display (and order
                         (get-text-property 0
                                            'pilish-thinking-block-display
                                            text)))
           (details (and order (get-text-property 0 'pilish-details text))))
      (when (<= start end)
        (let ((existing (buffer-substring-no-properties start end)))
          (if (equal existing plain-text)
              (when order
                (pilish--apply-completed-thinking-properties
                 start end order normalized display details))
            (goto-char start)
            (pilish--remove-table-overlays start end)
            (delete-region start end)
            (insert text)
            (set-marker pilish--thinking-marker (point))))
        (not (string-empty-p text))))))

(cl-defstruct (pilish--thinking-stream
               (:constructor pilish--make-thinking-stream))
  "Lossless deltas and unresolved whitespace for one thinking block."
  raw-rev
  (mode 'leading)
  (leading-spaces 0)
  middle-rev
  tail-rev)

(cl-defstruct (pilish--thinking-edit
               (:constructor pilish--make-thinking-edit))
  "One suffix edit and the resulting thinking stream."
  next-stream
  (delete-spaces 0)
  (text ""))

(defvar-local pilish--thinking-stream nil
  "Incremental normalization state for the active thinking block.
Only leading spaces before the first content character can retract.
Gap modes hold one, two, or at least three unresolved newlines.
Whitespace fragments are newest first and contain only ASCII spaces/tabs.")

(defun pilish--thinking-step (stream delta)
  "Return the bounded thinking edit for safe string DELTA and STREAM.
Do not mutate STREAM or its fragment lists.  Scan only DELTA, holding
unresolved whitespace until content makes its separator visible."
  (let ((next (copy-pilish--thinking-stream stream))
        (mode (pilish--thinking-stream-mode stream))
        (leading-spaces (pilish--thinking-stream-leading-spaces stream))
        (middle-rev (pilish--thinking-stream-middle-rev stream))
        (tail-rev (pilish--thinking-stream-tail-rev stream))
        (index 0)
        (delete-spaces 0)
        text-rev)
    (save-match-data
      (while (string-match "[ \t]+\\|\n\\|[^ \t\n]+" delta index)
        (let* ((end (match-end 0))
               (run (substring delta index end))
               (first (aref run 0)))
          (setq index end)
          (cond
           ((eq first ?\n)
            (pcase mode
              ('leading
               (setq delete-spaces (pilish--thinking-stream-leading-spaces stream)
                     leading-spaces 0
                     text-rev nil))
              ('line (setq mode 'gap-one))
              ('gap-one
               (setq mode 'gap-two middle-rev tail-rev tail-rev nil))
              ('gap-two
               (setq mode 'gap-many middle-rev nil tail-rev nil))
              ('gap-many (setq tail-rev nil))))
           ((memq first '(?\s ?\t))
            (pcase mode
              ('leading
               (cl-incf leading-spaces (length run))
               (push run text-rev))
              ('line (push run text-rev))
              (_ (push run tail-rev))))
           (t
            (when (memq mode '(gap-one gap-two gap-many))
              (push (concat
                     (pcase mode
                       ('gap-one "\n> ")
                       ('gap-two
                        (concat "\n> " (mapconcat #'identity (reverse middle-rev) "")
                                "\n> "))
                       ('gap-many "\n> \n> "))
                     (mapconcat #'identity (reverse tail-rev) ""))
                    text-rev))
            (push run text-rev)
            (setq mode 'line leading-spaces 0 middle-rev nil tail-rev nil))))))
    (setf (pilish--thinking-stream-mode next) mode
          (pilish--thinking-stream-leading-spaces next) leading-spaces
          (pilish--thinking-stream-middle-rev next) middle-rev
          (pilish--thinking-stream-tail-rev next) tail-rev)
    (unless (string-empty-p delta)
      (push delta (pilish--thinking-stream-raw-rev next)))
    (pilish--make-thinking-edit
     :next-stream next :delete-spaces delete-spaces
     :text (mapconcat #'identity (nreverse text-rev) ""))))

(defun pilish--materialize-thinking-raw ()
  "Return the active block's raw string, joining its deltas only when needed."
  (when (and pilish--thinking-stream (null pilish--thinking-raw))
    (setq pilish--thinking-raw
          (mapconcat #'identity
                     (reverse (pilish--thinking-stream-raw-rev pilish--thinking-stream))
                     "")))
  pilish--thinking-raw)

(defun pilish--ensure-blank-line-separator ()
  "Ensure exactly one blank line separator at point.
Normalizes any existing newline run to two newlines."
  (let ((start (point))
        (scan (point))
        (newline-count 0))
    (while (eq (char-after scan) ?\n)
      (setq newline-count (1+ newline-count))
      (setq scan (1+ scan)))
    (cond
     ((< newline-count 2)
      (insert (make-string (- 2 newline-count) ?\n)))
     ((> newline-count 2)
      (delete-region (+ start 2) (+ start newline-count))))))

(defun pilish--ensure-blank-line-before-block ()
  "Ensure point is on a fresh line with a blank line above.
Used before inserting a new block (thinking, tool) so it is visually
separated from preceding content."
  (unless (bolp)
    (insert "\n"))
  (unless (save-excursion
            (forward-line -1)
            (looking-at-p "^$"))
    (insert "\n")))

(defun pilish--reset-thinking-state ()
  "Detach and clear all thinking-stream state for the current turn."
  (when (markerp pilish--thinking-marker)
    (set-marker pilish--thinking-marker nil))
  (when (markerp pilish--thinking-start-marker)
    (set-marker pilish--thinking-start-marker nil))
  (setq pilish--thinking-marker nil
        pilish--thinking-start-marker nil
        pilish--thinking-raw nil
        pilish--thinking-stream nil))

(defmacro pilish--with-window-rewrite-preservation (&rest body)
  "Execute BODY and keep chat windows useful after a large rewrite.
This is for rewrites that can delete the text under `window-start', such as
collapsing a long thinking block or rebuilding canonical history.  Tail views
stay at the new tail; non-tail views keep their point and approximate row,
clamped so the window remains filled when possible."
  (declare (indent 0) (debug t))
  `(let ((buffer (current-buffer))
         (saved-windows (pilish--capture-window-rewrite-states))
         result)
     (unwind-protect
         (setq result (progn ,@body))
       (pilish--restore-window-rewrite-states buffer saved-windows))
     result))

(defun pilish--display-thinking-start ()
  "Insert opening marker for thinking block (blockquote)."
  (when pilish--streaming-marker
    (setq pilish--in-thinking-block t)
    (let ((inhibit-read-only t))
      (pilish--with-scroll-preservation
        (save-excursion
          (goto-char (marker-position pilish--streaming-marker))
          ;; No separator needed when this is the first content in the message.
          (when (and pilish--message-start-marker
                     (> (point)
                        (marker-position pilish--message-start-marker)))
            (pilish--ensure-blank-line-before-block))
          ;; Track thinking insertion separately so it stays anchored even if
          ;; other block types (tool headers) interleave in the same message.
          ;; Keep insertion-type nil so inserts at this exact point happen
          ;; after the marker (we then advance it explicitly per delta).
          (pilish--reset-thinking-state)
          (setq pilish--thinking-raw ""
                pilish--thinking-stream (pilish--make-thinking-stream))
          (let ((start (point)))
            (insert "> ")
            (setq pilish--thinking-start-marker
                  (copy-marker start nil))
            (setq pilish--thinking-marker
                  (copy-marker (point) nil))))))))

(defun pilish--display-thinking-delta (delta)
  "Display streaming thinking DELTA in the current thinking block.
Normalizes boundary and paragraph whitespace while streaming."
  (when (and delta pilish--streaming-marker)
    (let ((delta (pilish--render-safe-string delta))
          (inhibit-read-only t))
      (if (and pilish--thinking-stream
               (markerp pilish--thinking-start-marker)
               (markerp pilish--thinking-marker)
               (eq (marker-buffer pilish--thinking-start-marker) (current-buffer))
               (eq (marker-buffer pilish--thinking-marker) (current-buffer))
               (<= pilish--thinking-start-marker pilish--thinking-marker))
          (let* ((edit (pilish--thinking-step pilish--thinking-stream delta))
                 (delete-spaces (pilish--thinking-edit-delete-spaces edit))
                 (text (pilish--thinking-edit-text edit)))
            (setq pilish--thinking-stream (pilish--thinking-edit-next-stream edit))
            (unless (string-empty-p delta)
              (setq pilish--thinking-raw nil))
            (when (or (> delete-spaces 0) (not (string-empty-p text)))
              (pilish--with-scroll-preservation
                (save-excursion
                  (goto-char pilish--thinking-marker)
                  (when (> delete-spaces 0)
                    (delete-region (- (point) delete-spaces) (point)))
                  (unless (string-empty-p text)
                    (insert text))
                  (set-marker pilish--thinking-marker (point))))))
        ;; Fallback for malformed event streams that skip thinking_start.
        (let ((transformed (replace-regexp-in-string "\n" "\n> " delta)))
          (pilish--with-scroll-preservation
            (save-excursion
              (goto-char (pilish--thinking-insert-position))
              (insert transformed)
              (when pilish--thinking-marker
                (set-marker pilish--thinking-marker (point))))))))))

(defun pilish--display-thinking-end (_content)
  "End thinking block (blockquote).
CONTENT is ignored - we use what was already streamed."
  (when pilish--streaming-marker
    (let* ((buffer (current-buffer))
           (saved-windows (pilish--capture-window-rewrite-states))
           (old-point-max (point-max))
           (rewrite-start (and (markerp pilish--thinking-start-marker)
                               (marker-position pilish--thinking-start-marker)))
           (rewrite-end (and (markerp pilish--thinking-marker)
                             (marker-position pilish--thinking-marker))))
      (unwind-protect
          (progn
            (setq pilish--in-thinking-block nil)
            (let ((inhibit-read-only t))
              (pilish--with-scroll-preservation
                (save-excursion
                  (if (and pilish--thinking-start-marker
                           pilish--thinking-marker)
                      (when (pilish--replace-thinking-region
                             (pilish--completed-thinking-rendered-text
                              (pilish--materialize-thinking-raw)))
                        (goto-char (pilish--thinking-insert-position))
                        (pilish--ensure-blank-line-separator))
                    ;; Fallback for malformed event streams that skip thinking_start.
                    (goto-char (pilish--thinking-insert-position))
                    (pilish--ensure-blank-line-separator))
                  (pilish--reset-thinking-state)))))
        (pilish--restore-window-rewrite-states
         buffer
         saved-windows
         (when (and rewrite-start rewrite-end)
           (let ((replacements
                  (list (list rewrite-start
                              rewrite-end
                              (with-current-buffer buffer
                                (- (point-max) old-point-max))))))
             (lambda (pos)
               (pilish--adjust-pos-after-region-replacements
                pos replacements)))))))))

(defun pilish--stream-delta-kind (event)
  "Return `text', `thinking', `toolcall', or nil for streaming EVENT.
Single source of truth for the delta kinds the coalescer understands."
  (when (equal (plist-get event :type) "message_update")
    (pcase (plist-get (plist-get event :assistantMessageEvent) :type)
      ("text_delta" 'text)
      ("thinking_delta" 'thinking)
      ("toolcall_delta" 'toolcall))))

(defun pilish--schedule-stream-delta-flush ()
  "Arm the one-shot streaming delta flush timer for the current buffer."
  (setq pilish--stream-delta-flush-timer
        (run-at-time pilish--stream-delta-render-interval nil
                     #'pilish--flush-stream-deltas
                     (current-buffer))))

(defun pilish--queue-stream-delta (kind delta)
  "Queue streaming DELTA of KIND for rendering.
For `toolcall', DELTA is an incrementally assembled stream record; queue it
only once per flush.  For `text' and `thinking', normalize non-string values
with `pilish--render-safe-string' and join consecutive same-kind deltas once
at flush time, avoiding one markdown-changing insertion per token."
  (when delta
    (if (eq kind 'toolcall)
        (unless (pilish--tool-stream-paint-pending-p delta)
          (setf (pilish--tool-stream-paint-pending-p delta) t)
          (push (cons kind delta) pilish--pending-stream-deltas))
      (let ((delta (if (stringp delta) delta
                     (pilish--render-safe-string delta))))
        (unless (string-empty-p delta)
          (push (cons kind delta) pilish--pending-stream-deltas))))
    (when (and pilish--pending-stream-deltas
               (not pilish--stream-delta-flush-timer))
      (pilish--schedule-stream-delta-flush))))

(defun pilish--flush-stream-deltas (&optional buffer)
  "Stage BUFFER's pending delta batch, clear flush state, then render it.
Timer callback for `pilish--stream-delta-flush-timer'.  Also called
synchronously before any non-delta event so text, thinking, and tool blocks
keep their authoritative order.  If rendering signals, log once and discard
the rest of the staged batch rather than risk duplicating partial output;
canonical history or reload is the recovery path."
  (let ((buffer (or buffer (current-buffer))))
    ;; Cheap pre-check without switching buffers: high-frequency non-delta
    ;; events call this on every token.
    (when (and (buffer-live-p buffer)
               (or (buffer-local-value 'pilish--pending-stream-deltas buffer)
                   (buffer-local-value 'pilish--stream-delta-flush-timer buffer)))
      (with-current-buffer buffer
        (when (or pilish--pending-stream-deltas
                  pilish--stream-delta-flush-timer)
          (let ((pending pilish--pending-stream-deltas))
            ;; Own the batch before clearing timer, queue and per-stream flags.
            ;; A failed paint must not leave any staged stream marked pending.
            (pilish--cancel-stream-delta-flush)
            (setq pending (nreverse pending))
            ;; Coalesced deltas still insert into a growing transcript.  Suspend
            ;; only the explicitly allowlisted stale-side-effect hook; jit-lock
            ;; plus md-ts's dirty-tick and reference-definition hooks remain for
            ;; fontification bookkeeping and distant-link correctness.
            (condition-case err
                (pilish--with-md-ts-change-hooks-suspended
                    #'pilish--md-ts-expensive-change-hook-p
                  (while pending
                    (if (eq (caar pending) 'toolcall)
                        (pilish--render-toolcall-stream
                         (cdr (pop pending)) "toolcall_delta")
                      (let ((kind (caar pending))
                            (chunks (list (cdr (pop pending)))))
                        (while (and pending (eq (caar pending) kind))
                          (push (cdr (pop pending)) chunks))
                        (let ((text (mapconcat #'identity (nreverse chunks) "")))
                          (pcase kind
                            ('text (pilish--display-message-delta text))
                            ('thinking
                             (pilish--display-thinking-delta text))))))))
              (error
               (message "pilish: stream delta flush failed: %s"
                        (error-message-string err))
               nil))))))))

(defun pilish--cancel-stream-delta-flush ()
  "Cancel any armed streaming delta flush timer and drop pending deltas.
Idempotent.  Used for buffer kill and render-artifact teardown during session
or history reset.  `pilish--flush-stream-deltas' stages the batch before
calling this helper, leaving timer, queue and per-stream flags clear even
when rendering fails.  Process exit attempts that flush rather than dropping
the unpainted batch."
  (when (timerp pilish--stream-delta-flush-timer)
    (cancel-timer pilish--stream-delta-flush-timer))
  (dolist (entry pilish--pending-stream-deltas)
    (when (eq (car entry) 'toolcall)
      (setf (pilish--tool-stream-paint-pending-p (cdr entry)) nil)))
  (setq pilish--stream-delta-flush-timer nil
        pilish--pending-stream-deltas nil))

(defun pilish--ready-to-drain-followups-p ()
  "Return non-nil when a queued follow-up may become the next prompt."
  (and pilish--followup-queue
       (eq pilish--status 'idle)
       (not pilish--aborted)
       (not (pilish--session-busy-p))
       (null pilish--local-user-message)))

(defun pilish--display-agent-end ()
  "Finalize the low-level run, leaving queue release to agent_settled."
  (setq pilish--local-user-message nil)
  (pilish--clear-local-user-message-region)
  (setq pilish--in-thinking-block nil)
  (pilish--reset-thinking-state)
  (let ((inhibit-read-only t)
        ;; Trailing whitespace may be an empty tool's header terminator.
        ;; Keep that boundary intact for retained, late execution results.
        (last-tool-header
         (when-let* ((overlay (car (last (pilish--tool-block-overlays-in-region
                                         (point-min) (point-max)))))
                     (header (overlay-get overlay 'pilish-header-end)))
           (marker-position header))))
    (pilish--finalize-live-tool-blocks 'pilish-tool-block-error)
    (pilish--reset-toolcall-streams)
    (when pilish--tool-args-cache
      (clrhash pilish--tool-args-cache))
    ;; Keep stop intent until settlement: Pi may still start a continuation.
    (when pilish--aborted
      (pilish--with-scroll-preservation
        (save-excursion
          (goto-char (point-max))
          (skip-chars-backward " \t\n" last-tool-header)
          (delete-region (point) (point-max))
          (unless (eq (char-before) ?\n)
            (insert "\n"))
          (insert "\n" (propertize "[Aborted]" 'face 'error) "\n")))
      (pilish--clear-followup-queue))
    (pilish--with-scroll-preservation
      (save-excursion
        (goto-char (point-max))
        (skip-chars-backward "\n" last-tool-header)
        (delete-region (point) (point-max))
        (unless (eq (char-before) ?\n)
          (insert "\n")))))
  (pilish--set-activity-phase
   (if (eq pilish--status 'sending) "thinking" "idle"))
  (pilish--refresh-header))

(defun pilish--dispatch-builtin-command (text)
  "Try to dispatch TEXT as a built-in slash command.
Returns non-nil if TEXT matched a built-in command and was handled."
  (when (string-prefix-p "/" text)
    (let* ((without-slash (substring text 1))
           (words (split-string without-slash))
           (cmd-name (car words))
           (entry (assoc cmd-name pilish--builtin-commands)))
      (when entry
        (let ((handler (plist-get (cdr entry) :handler))
              (args-spec (plist-get (cdr entry) :args))
              (arg-str (let ((rest (string-trim
                                    (substring without-slash (length cmd-name)))))
                         (and (not (string-empty-p rest)) rest))))
          (pcase args-spec
            ('optional (funcall handler arg-str))
            ('required (if arg-str
                          (funcall handler arg-str)
                        (call-interactively handler)))
            (_ (funcall handler)))
          t)))))

(defun pilish--display-accepted-prompt (text &optional content)
  "Display accepted TEXT and optional CONTENT only before an observed run/echo."
  (when (pilish--prompt-local-echo-p)
    (setq pilish--local-user-message-region
          (pilish--display-user-message text (current-time) content t))
    (setq pilish--local-user-message (or content text))
    (setq pilish--assistant-header-shown nil)))

(defun pilish--prepare-and-send (text &optional queued prompt-image)
  "Prepare chat buffer state and send TEXT with optional PROMPT-IMAGE to pi.
Built-in slash commands are dispatched locally via the dispatch table.
Other slash commands (extensions, skills, prompts) are sent to pi without
local transcript display.  Regular text is displayed after prompt preflight
accepts it.
When QUEUED is non-nil, TEXT is the oldest local follow-up and is removed
from the queue only after prompt preflight succeeds.  PROMPT-IMAGE is only
valid for a direct regular prompt.
Must be called with chat buffer current.  Pi events own streaming/idle turn
transitions; prompt submission marks the local pre-event window as busy."
  (pilish--invalidate-history-loads)
  (cond
   ;; Built-in slash commands are interactive client actions, not durable queued
   ;; prompts.  Busy input refuses new ones; this guard keeps stale queued items
   ;; from running later out of context.
   ((and queued (pilish--builtin-command-text-p text))
    (pilish--restore-followup-queue-to-input)
    (message "Pi: Cannot run queued /%s command automatically"
             (pilish--builtin-command-name text)))
   ;; Built-in slash commands: dispatch locally.
   ((pilish--dispatch-builtin-command text))
   ;; Other slash commands: don't display locally, send to pi.
   ((string-prefix-p "/" text)
    (pilish--send-prompt
     text
     (when queued
       (lambda () (pilish--drop-followup text)))
     (if queued
         #'pilish--restore-followup-queue-to-input
       (lambda () (pilish--restore-input-text text)))
     #'pilish--process-followup-queue))
   ;; Regular text is displayed only after prompt preflight accepts it.  That
   ;; keeps rejected prompts out of the transcript and lets us restore them to
   ;; the input buffer for user recovery.
   (prompt-image
    (let* ((image-block
            (pilish--prompt-image-content-block prompt-image))
           (user-content
            (vector (list :type "text" :text text) image-block)))
      (pilish--send-prompt
       text
       (lambda () (pilish--display-accepted-prompt text user-content))
       (lambda () (pilish--restore-input-text text prompt-image))
       #'pilish--handle-no-turn-local-prompt
       prompt-image)))
   (queued
    (pilish--send-prompt
     text
     (lambda ()
       (when (pilish--drop-followup text)
         (pilish--display-accepted-prompt text)))
     #'pilish--restore-followup-queue-to-input
     #'pilish--handle-no-turn-local-prompt))
   (t
    (pilish--send-prompt
     text
     (lambda () (pilish--display-accepted-prompt text))
     (lambda () (pilish--restore-input-text text))
     #'pilish--handle-no-turn-local-prompt))))

(defun pilish--process-followup-queue ()
  "Send the oldest follow-up only when it is safe to become the next prompt.
Messages are processed in FIFO order and dropped only after preflight accepts
them."
  (when (pilish--ready-to-drain-followups-p)
    (when-let* ((text (pilish--peek-followup)))
      (pilish--prepare-and-send text 'queued))))

(defun pilish--display-compaction-failure (error-message)
  "Display failed compaction ERROR-MESSAGE without changing the queue."
  (let ((error-text (or (pilish--normalize-string-or-null error-message)
                        "unknown error")))
    (pilish--display-error (format "Compaction failed: %s" error-text))
    (message "Pi: Compaction failed: %s" error-text)))

(defun pilish--handle-compaction-end-event (event)
  "Display compaction EVENT without releasing surrounding run ownership.
Unreserved standalone manual compaction completes here.  Local prompt and
manual RPC reservations still own FIFO/stop effects until their responses.
Extension cancellation is not a local stop; core events own status transitions."
  (let ((result (pilish--compaction-result-from-event event))
        (cancelled (pilish--normalize-boolean (plist-get event :aborted))))
    (cond
     (cancelled (message "Pi: Compaction cancelled"))
     (result
      (pilish--handle-compaction-success
       (plist-get result :tokensBefore)
       (plist-get result :summary)
       (pilish--ms-to-time (plist-get result :timestamp))))
     (t (pilish--display-compaction-failure (plist-get event :errorMessage))))
    (pilish--set-activity-phase
     (if (memq pilish--status '(sending streaming)) "thinking" "idle"))
    (when (and (eq pilish--status 'idle) (not (pilish--session-busy-p)))
      (cond
       (pilish--aborted
        (pilish--clear-followup-queue)
        (pilish--set-aborted nil))
       ((and result (not cancelled)) (pilish--process-followup-queue))
       (t (pilish--restore-followup-queue-to-input))))))

(defun pilish--display-retry-start (event)
  "Display retry notice from auto_retry_start EVENT.
Shows attempt number, delay, and raw error message."
  (let* ((attempt (plist-get event :attempt))
         (max-attempts (plist-get event :maxAttempts))
         (delay-ms (plist-get event :delayMs))
         (error-msg (or (plist-get event :errorMessage) "transient error"))
         (delay-sec (/ (or delay-ms 0) 1000.0))
         (notice (format "⟳ Retry %d/%d in %.0fs — %s"
                         (or attempt 1)
                         (or max-attempts 3)
                         delay-sec
                         error-msg)))
    (pilish--append-to-chat
     (concat (propertize notice 'face 'pilish-retry-notice) "\n"))))

(defun pilish--display-retry-end (event)
  "Display retry result from auto_retry_end EVENT.
Shows success or final failure with raw error."
  (let* ((success (plist-get event :success))
         (attempt (plist-get event :attempt))
         (final-error (or (plist-get event :finalError) "unknown error")))
    (if (eq success t)
        (pilish--append-to-chat
         (concat (propertize (format "✓ Retry succeeded on attempt %d"
                                     (or attempt 1))
                             'face 'pilish-retry-notice)
                 "\n\n"))
      ;; Final failure
      (pilish--append-to-chat
       (concat (propertize (format "✗ Retry failed after %d attempts — %s"
                                   (or attempt 1)
                                   final-error)
                           'face 'pilish-error-notice)
               "\n\n")))))

(defun pilish--display-error (error-msg)
  "Display ERROR-MSG from the server."
  (pilish--append-to-chat
   (concat "\n" (propertize (format "[Error: %s]" (or error-msg "unknown"))
                            'face 'pilish-error-notice 'pilish-assistant-outcome t)
           "\n")))

(defconst pilish--startup-env-node-hint
  (concat "Probable cause: Pi's Node launcher cannot see `node`.\n\n"
          "Emacs found the configured Pi launcher, but it uses `/usr/bin/env node`, "
          "which searches the subprocess PATH, not only Emacs `exec-path`. "
          "Put Node's bin directory on the PATH seen by Emacs-created "
          "processes, or set `pilish-executable` to a wrapper "
          "that does.")
  "Hint shown when Pi's Node launcher cannot find node at startup.")

(defun pilish--startup-env-node-error-p (exit-code stderr)
  "Return non-nil when EXIT-CODE and STDERR look like env failing to find node."
  (and (equal exit-code 127)
       (stringp stderr)
       (let ((case-fold-search nil))
         (catch 'found
           (dolist (line (split-string stderr "[\r\n]+" t))
             (when (and (string-match-p "\\(?:\\`\\|/\\)env:" line)
                        (string-match-p
                         "\\(?:\\`\\|[^[:alnum:]_]\\)node\\(?:[^[:alnum:]_]\\|\\'\\)"
                         line))
               (throw 'found t)))))))

(defun pilish--format-process-error
    (heading error-msg &optional stderr detail)
  "Format process error HEADING and ERROR-MSG.
Include optional STDERR in a text fence and optional DETAIL before it."
  (let ((stderr (and (stringp stderr)
                     (not (string-empty-p stderr))
                     stderr)))
    (concat "\n"
            (propertize heading 'face 'pilish-error-notice)
            "\n\n"
            (or error-msg "unknown error")
            (when detail (concat "\n\n" detail))
            (when stderr
              (concat "\n\n"
                      (propertize "stderr:"
                                  'face 'pilish-retry-notice)
                      "\n```text\n"
                      stderr
                      (unless (string-suffix-p "\n" stderr) "\n")
                      "```\n")))))

(defun pilish--display-startup-error (error-msg &optional stderr exit-code)
  "Display a pi startup ERROR-MSG, optional STDERR, and EXIT-CODE."
  (pilish--append-to-chat
   (concat (pilish--format-process-error
            "✗ pi failed to start" error-msg stderr)
           (when (pilish--startup-env-node-error-p exit-code stderr)
             (concat "\n" pilish--startup-env-node-hint "\n")))))

(defun pilish--display-process-exit-error
    (error-msg &optional stderr exit-code)
  "Display a pi process exit ERROR-MSG, optional STDERR, and EXIT-CODE."
  (pilish--append-to-chat
   (pilish--format-process-error
    "✗ pi process exited" error-msg stderr
    (when exit-code
      (format "Exit code: %s" exit-code)))))

(defun pilish--display-extension-error (event)
  "Display extension error from extension_error EVENT."
  (let* ((extension-path (plist-get event :extensionPath))
         (extension-event (plist-get event :event))
         (error-msg (plist-get event :error))
         (extension-name (if extension-path (file-name-nondirectory extension-path) "unknown")))
    (pilish--append-to-chat
     (concat "\n"
             (propertize (format "[Extension error in %s (%s): %s]"
                                 extension-name
                                 (or extension-event "unknown")
                                 (or error-msg "unknown error"))
                         'face 'pilish-error-notice)
             "\n"))))

(defun pilish--extension-ui-notify (event)
  "Handle notify method from EVENT."
  (let ((msg (plist-get event :message))
        (notify-type (plist-get event :notifyType)))
    (message "Pi: %s%s"
             (pcase notify-type
               ("warning" "⚠ ")
               ("error" "✗ ")
               (_ ""))
             msg)))

(defun pilish--complete-extension-ui-dialog (event proc read-response)
  "Attempt one response to supported-dialog EVENT on PROC.
Call READ-RESPONSE with no arguments to obtain the complete
success response plist; call it even when PROC is nil, so readers
work without a process.  Mark the attempt before sending: a failed
send is neither retried nor replaced by cancellation, and delivery
is not guaranteed.  Any exit before the first attempt -- reader
error, user quit, or a throw -- tries a `:cancelled' response when
PROC is non-nil.  `error' and `quit', including from cancellation
itself, return nil.  Other nonlocal exits propagate when cleanup
completes normally."
  (let ((response-attempted nil))
    (condition-case nil
        (unwind-protect
            (let ((response (funcall read-response)))
              (when proc
                (setq response-attempted t)
                (pilish--send-extension-ui-response proc response)))
          (when (and proc (not response-attempted))
            (setq response-attempted t)
            (pilish--send-extension-ui-response
             proc
             (list :type "extension_ui_response"
                   :id (plist-get event :id)
                   :cancelled t))))
      ((error quit) nil))
    nil))

(defun pilish--extension-ui-confirm (event proc)
  "Handle confirm method from EVENT, responding via PROC."
  (pilish--complete-extension-ui-dialog
   event proc
   (lambda ()
     (let* ((id (plist-get event :id))
            (title (plist-get event :title))
            (msg (plist-get event :message))
            ;; Don't add colon if title already ends with one
            (separator (if (string-suffix-p ":" title) " " ": "))
            (prompt (format "%s%s%s " title separator msg))
            (confirmed (yes-or-no-p prompt)))
       (list :type "extension_ui_response"
             :id id
             :confirmed (if confirmed t :json-false))))))

(defun pilish--extension-ui-select-minibuffer-setup ()
  "Set up the minibuffer for an extension UI selection."
  (let ((show-native-completions
         (and (not (boundp 'completion-eager-display))
              (eq completing-read-function #'completing-read-default)
              (not (bound-and-true-p icomplete-mode))
              (eq (key-binding (kbd "RET"))
                  #'minibuffer-complete-and-exit)))
        (literal-keys (make-sparse-keymap)))
    ;; Icomplete owns candidate display, but normally hides an empty match set.
    (when (bound-and-true-p icomplete-mode)
      (set (make-local-variable 'icomplete-show-matches-on-no-input) t)
      ;; Emacs 31's native eager display would duplicate Icomplete's display.
      (when (boundp 'completion-eager-display)
        (set (make-local-variable 'completion-eager-display) nil)))
    (define-key literal-keys (kbd "SPC") #'self-insert-command)
    (define-key literal-keys (kbd "?") #'self-insert-command)
    (use-local-map
     (make-composed-keymap literal-keys (current-local-map)))
    ;; Before Emacs 31 there is no eager-display completion metadata.
    (when show-native-completions
      (minibuffer-completion-help))))

(defun pilish--extension-ui-select (event proc)
  "Handle select method from EVENT, responding via PROC."
  (pilish--complete-extension-ui-dialog
   event proc
   (lambda ()
     (let* ((id (plist-get event :id))
            (title (plist-get event :title))
            (options (append (plist-get event :options) nil))
            (completion-extra-properties
             (cons :eager-display (cons t completion-extra-properties)))
            (selected
             (minibuffer-with-setup-hook
                 (:append #'pilish--extension-ui-select-minibuffer-setup)
               (completing-read (concat title " ") options nil t))))
       (list :type "extension_ui_response"
             :id id
             :value selected)))))

(defun pilish--extension-ui-input (event proc)
  "Handle input method from EVENT, responding via PROC."
  (pilish--complete-extension-ui-dialog
   event proc
   (lambda ()
     (let* ((id (plist-get event :id))
            (title (plist-get event :title))
            (placeholder (plist-get event :placeholder))
            (prompt (if (and placeholder (not (string-empty-p placeholder)))
                        (format "%s (%s) " title placeholder)
                      (concat title " ")))
            (value (read-string prompt)))
       (list :type "extension_ui_response"
             :id id
             :value value)))))

(defun pilish--extension-ui-set-editor-text (event)
  "Handle set_editor_text method from EVENT."
  (let ((text (plist-get event :text)))
    (when-let* ((input-buf pilish--input-buffer))
      (pilish--replace-input-draft input-buf text))))

(defun pilish--extension-ui-set-status (event)
  "Handle setStatus method from EVENT."
  (let ((key (plist-get event :statusKey))
        (text (plist-get event :statusText)))
    (when text
      (setq text (ansi-color-filter-apply
                  (pilish--render-safe-string text))))
    (if text
        (setq pilish--extension-status
              (cons (cons key text)
                    (assoc-delete-all key pilish--extension-status)))
      (setq pilish--extension-status
            (assoc-delete-all key pilish--extension-status)))
    (force-mode-line-update t)))

;; Pi RPC currently suppresses this method; retain client protocol support.
(defun pilish--extension-ui-set-working-message (event)
  "Handle setWorkingMessage method from EVENT."
  (let ((msg (plist-get event :message)))
    (when msg
      (setq msg (ansi-color-filter-apply
                 (pilish--render-safe-string msg))))
    (setq pilish--working-message msg)
    (force-mode-line-update t)))

(defconst pilish--extension-ui-fire-and-forget-methods
  '("notify" "setStatus" "setWidget" "setTitle" "set_editor_text"
    "setWorkingMessage")
  "Extension UI methods that do not expect RPC responses.")

(defun pilish--extension-ui-response-required-p (method)
  "Return non-nil when unsupported extension UI METHOD may expect a response."
  (not (member method pilish--extension-ui-fire-and-forget-methods)))

(defun pilish--extension-ui-warn-unsupported-once (method)
  "Warn at most once per pi session for unsupported extension UI METHOD."
  (when (pilish--record-unsupported-extension-ui-warning method)
    (message "Pi: extension UI method `%s' not supported in Emacs" method)))

(defun pilish--extension-ui-unsupported (event proc)
  "Handle unsupported method from EVENT, using PROC to cancel when needed.
Warn at most once per method in a pi session.
Dialog-like methods receive a cancelled response so extensions do not hang;
fire-and-forget methods are only warned because they do not expect responses.
See URL `https://github.com/dnouri/pilish/issues/176'."
  (let ((method (plist-get event :method))
        (id (plist-get event :id)))
    (pilish--extension-ui-warn-unsupported-once method)
    (when (and proc
               id
               (pilish--extension-ui-response-required-p method))
      (pilish--send-extension-ui-response
       proc (list :type "extension_ui_response"
                  :id id
                  :cancelled t)))))

(defun pilish--handle-extension-ui-request (event)
  "Handle extension_ui_request EVENT from pi.
Dispatches to appropriate handler based on method."
  (let ((method (plist-get event :method))
        (proc pilish--process))
    (pcase method
      ("notify"         (pilish--extension-ui-notify event))
      ("confirm"        (pilish--extension-ui-confirm event proc))
      ("select"         (pilish--extension-ui-select event proc))
      ("input"          (pilish--extension-ui-input event proc))
      ("set_editor_text" (pilish--extension-ui-set-editor-text event))
      ("setStatus"      (pilish--extension-ui-set-status event))
      ("setWorkingMessage" (pilish--extension-ui-set-working-message event))
      (_                (pilish--extension-ui-unsupported event proc)))))

(defun pilish--display-no-model-warning ()
  "Display warning when no model is available.
Shown when the session starts without a configured model/API key."
  (pilish--append-to-chat
   (concat "\n"
           (propertize "⚠ No models available"
                       'face 'pilish-error-notice)
           "\n\n"
           (propertize "To get started, either:\n"
                       'face 'pilish-retry-notice)
           (propertize "  • Set an API key: "
                       'face 'pilish-retry-notice)
           "ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY, etc.\n"
           (propertize "  • Or run "
                       'face 'pilish-retry-notice)
           (propertize "pi --login"
                       'face 'pilish-tool-command)
           (propertize " in a terminal to authenticate via OAuth\n"
                       'face 'pilish-retry-notice)
           "\n")))

(defun pilish--cleanup-transcript-on-kill ()
  "Release only the current transcript's display resources."
  (pilish--clear-render-artifacts)
  (pilish--remove-table-overlays (point-min) (point-max))
  (pilish--cleanup-visible-string-buffer))

(defun pilish--cleanup-on-kill ()
  "Clean up resources when chat buffer is killed.
Also kills the linked input buffer and fontification cache buffers.

Note: This runs from `kill-buffer-hook', which executes AFTER the kill
decision is made.  For proper cancellation support, use `pilish-quit'
which asks upfront before any buffers are touched."
  (when (derived-mode-p 'pilish-chat-mode)
    (pilish--cancel-inactivity-timer)
    (pilish--cancel-tool-update-flush)
    (pilish--cancel-stream-delta-flush)
    (pilish--release-nested-tool-state)
    (pilish--invalidate-prompt-start-wait)
    (pilish--set-activity-phase "idle" 'teardown t)
    (dolist (proc (delete-dups (delq nil (list pilish--process
                                               pilish--session-transition-process))))
      (when (processp proc)
        (pilish--unregister-display-handler proc)
        (when (process-live-p proc)
          (delete-process proc))))
    (when (and pilish--input-buffer (buffer-live-p pilish--input-buffer))
      (let ((input-buf pilish--input-buffer))
        (pilish--set-input-buffer nil) ; break cycle before kill
        (kill-buffer input-buf)))
    (pilish--cleanup-visible-string-buffer)))

(defun pilish--cleanup-input-on-kill ()
  "Clean up when input buffer is killed.
Also kills the linked chat buffer (which handles process cleanup).

Note: This runs from `kill-buffer-hook', which executes AFTER the kill
decision is made.  For proper cancellation support, use `pilish-quit'
which asks upfront before any buffers are touched."
  (when (derived-mode-p 'pilish-input-mode)
    (when (and pilish--chat-buffer (buffer-live-p pilish--chat-buffer))
      (let* ((chat-buf pilish--chat-buffer)
             (proc (buffer-local-value 'pilish--process chat-buf)))
        (pilish--set-chat-buffer nil) ; break cycle before kill
        (when (and proc (process-live-p proc))
          (pilish--skip-process-kill-confirmation proc)
          (set-process-query-on-exit-flag proc nil))
        (kill-buffer chat-buf)))))

(defun pilish--register-display-handler (process)
  "Register display and process-exit handlers for PROCESS."
  (process-put process 'pilish-display-handler
               (pilish--make-display-handler process))
  (process-put process 'pilish-exit-handler
               (pilish--make-process-exit-handler process)))

(defun pilish--unregister-display-handler (process)
  "Unregister display and process-exit handlers for PROCESS."
  (process-put process 'pilish-display-handler nil)
  (process-put process 'pilish-exit-handler nil))

(defun pilish--make-display-handler (process)
  "Create a display event handler for PROCESS."
  (lambda (event)
    (when-let* ((chat-buf (process-get process 'pilish-chat-buffer)))
      (when (buffer-live-p chat-buf)
        (with-current-buffer chat-buf
          (when (eq process pilish--process)
            (unwind-protect
                (if (equal (plist-get event :type) "queue_update")
                    (force-mode-line-update t)
                  (pilish--handle-display-event event))
              (when (eq process pilish--process)
                (pilish--reconcile-inactivity-timer)))))))))

(defun pilish--make-process-exit-handler (process)
  "Create a frontend cleanup handler for PROCESS exit."
  (lambda (response)
    (when-let* ((chat-buf (process-get process 'pilish-chat-buffer))
                ((buffer-live-p chat-buf)))
      (with-current-buffer chat-buf
        (pilish--mark-process-exited process response)))))

(defun pilish--mark-process-exited (process response)
  "Mark current chat buffer idle after PROCESS exits with RESPONSE."
  (when (eq pilish--process process)
    (let ((error-msg (or (plist-get response :error) "Process exited")))
      (setq pilish--status 'idle)
      (setq pilish--state
            (plist-put pilish--state :last-error error-msg))
      (unwind-protect
          ;; Flush coalesced stream paints first: produced before the exit,
          ;; so it must land before the exit banner rather than after it.
          (progn
            (pilish--flush-stream-deltas)
            (unless (process-get process 'pilish-exit-error-rendered)
              (pilish--display-process-exit-error
               error-msg
               (plist-get response :stderr)
               (plist-get response :exitCode))
              (process-put process 'pilish-exit-error-rendered t)))
        (pilish--cancel-tool-update-flush)
        (pilish--finalize-live-tool-blocks
         'pilish-tool-block-error)
        (pilish--reset-toolcall-streams)
        (pilish--clear-live-details-state)
        (when pilish--tool-args-cache
          (clrhash pilish--tool-args-cache))
        (pilish--set-process nil)
        (pilish--invalidate-model-change)
        (pilish--set-activity-phase "idle")
        (setq pilish--local-user-message nil)
        (pilish--clear-local-user-message-region)
        (setq pilish--pre-compaction-status nil)
        (pilish--set-aborted nil)
        (pilish--invalidate-prompt-start-wait)
        (pilish--restore-followup-queue-to-input)
        (force-mode-line-update t)))))

(defun pilish--display-custom-message (content)
  "Display visible custom CONTENT in the current chat buffer."
  (when (and (stringp content)
             (not (string-empty-p content)))
    (let ((start (point-max)))
      (pilish--append-to-chat (concat "\n" content "\n"))
      (pilish--decorate-tables-unless-deferred start (point-max)))
    ;; Reset so next assistant message shows its header
    (setq pilish--assistant-header-shown nil)))

(defun pilish--handle-display-event (event)
  "Handle EVENT for display purposes.
Updates buffer-local state and renders display updates."
  ;; Sample before state updates or rendering, never on deltas or remote
  ;; user/toolResult lifecycle events.  Both endpoints use this local clock.
  (let ((boundary-time
         (when (or (member (plist-get event :type)
                           '("tool_execution_start" "tool_execution_end"))
                   (and (member (plist-get event :type) '("message_start" "message_end"))
                        (equal (plist-get (plist-get event :message) :role) "assistant")))
           (float-time (current-time)))))
    ;; Protocol state is authoritative and must advance before fallible display
    ;; work.  Settlement's return value says whether this event released waiting
    ;; work; preserve it from the single state update to gate completion effects.
    (let* ((settlement-released (pilish--update-state-from-event event))
           (delta-kind (pilish--stream-delta-kind event)))
      ;; Coalesced stream deltas must be painted before any handled event that can
      ;; insert chat text or start a block, so ordering between text, thinking,
      ;; and tool blocks stays authoritative.  Delta events keep accumulating
      ;; until the flush cadence.  (`queue_update' bypasses this handler and only
      ;; refreshes the mode line, so it needs no flush.)
      (unless delta-kind
        (pilish--flush-stream-deltas))
      (when (and settlement-released
                 (equal (plist-get event :type) "agent_settled"))
        (when pilish--aborted
          (pilish--clear-followup-queue))
        (pilish--set-aborted nil)
        (pilish--set-activity-phase "idle")
        (pilish--process-followup-queue))
      (when (memq delta-kind '(text thinking))
        (when (eq delta-kind 'text)
          (pilish--set-activity-phase "replying"))
        (pilish--queue-stream-delta
         delta-kind
         (plist-get (plist-get event :assistantMessageEvent) :delta))))
    ;; Explicit-parent executions belong to their root, never the ordinary
    ;; display path.  Protocol state above still sees every event.
    (pcase (plist-get event :type)
    ((and (or "tool_execution_start" "tool_execution_update" "tool_execution_end")
          (guard (plist-member event :parentToolCallId)))
     (pilish--handle-nested-tool-event event boundary-time))
    ("agent_start"
     (pilish--clear-live-details-state)
     (pilish--note-prompt-start)
     (pilish--display-agent-start)
     (when pilish--aborted
       (pilish--send-abort)))
    ("message_start"
     (let* ((message (plist-get event :message))
            (role (plist-get message :role)))
       ;; Late toolResult messages must not move assistant markers or clear
       ;; thinking.  Other new messages keep the existing context cleanup.
       (unless (equal role "toolResult")
         (setq pilish--in-thinking-block nil)
         (pilish--reset-thinking-state))
       (when (equal role "assistant")
         (setq pilish--assistant-details-clock
               (list :timestamp (plist-get message :timestamp) :time boundary-time))
         (pilish--reset-toolcall-streams))
       (pcase role
         ("user"
          (pilish--note-prompt-echo)
          ;; User message from pi - check if we displayed it locally
          (let* ((content (plist-get message :content))
                 (timestamp (plist-get message :timestamp))
                 (text (when content
                         (pilish--extract-user-message-text content)))
                 (has-images (pilish--content-has-image-p content))
                 (local-msg pilish--local-user-message))
            ;; Clear local tracking before rendering the authoritative turn.
            (setq pilish--local-user-message nil)
            (pilish--clear-local-user-message-region)
            (when (and (or text has-images)
                       (not (pilish--local-user-message-matches-p
                             local-msg text content)))
              (pilish--display-user-message
               text
               (pilish--ms-to-time timestamp)
               content)
              ;; Reset so next assistant message shows its header
              (setq pilish--assistant-header-shown nil))))
         ("custom"
          (when (plist-get message :display)
            (pilish--display-custom-message
             (plist-get message :content))))
         ("assistant"
          ;; Assistant message - show header if needed, reset markers
          (unless pilish--assistant-header-shown
            (pilish--append-to-chat
             (concat "\n" (pilish--make-separator "Assistant") "\n"))
            (setq pilish--assistant-header-shown t))
          (pilish--set-message-start-marker (copy-marker (point-max) nil))
          (pilish--set-streaming-marker (copy-marker (point-max) t))))))
    ("message_update"
     (when-let* ((msg-event (plist-get event :assistantMessageEvent))
                 (event-type (plist-get msg-event :type)))
       ;; Text/thinking deltas were queued above.  Toolcall deltas still feed
       ;; their incremental assembler here before queuing a preview paint.
       (pcase event-type
         ("text_start"
          (when pilish--assistant-details-clock
            (setq pilish--assistant-details-clock
                  (plist-put pilish--assistant-details-clock :streamed t))))
         ("text_end"
          ;; Text block ended — finalize any active table that may have
          ;; a trailing row without newline (backstop for streaming).
          (pilish--maybe-decorate-streaming-table)
          (setq pilish--streaming-table-candidate nil))
         ("thinking_start"
          (when pilish--assistant-details-clock
            (setq pilish--assistant-details-clock
                  (plist-put pilish--assistant-details-clock :streamed t)))
          (pilish--display-thinking-start))
         ("thinking_end"
          (pilish--display-thinking-end (plist-get msg-event :content)))
         ((or "toolcall_start" "toolcall_delta" "toolcall_end")
          (when (and pilish--assistant-details-clock (equal event-type "toolcall_start"))
            (setq pilish--assistant-details-clock
                  (plist-put pilish--assistant-details-clock :streamed t)))
          (pilish--set-activity-phase "running")
          (pilish--handle-toolcall-message-event msg-event))
         ("error"
          ;; Error during streaming (e.g., API error)
          (pilish--display-error (plist-get msg-event :reason))))))
    ("message_end"
     (let* ((message (plist-get event :message))
            (role (plist-get message :role))
            (assistant-p (equal role "assistant"))
            (duration
             (and assistant-p
                  (plist-get pilish--assistant-details-clock :streamed)
                  (equal (plist-get pilish--assistant-details-clock :timestamp)
                         (plist-get message :timestamp))
                  (not (member (plist-get message :stopReason) '("error" "aborted")))
                  (not pilish--aborted)
                  (pilish--details-elapsed
                   (plist-get pilish--assistant-details-clock :time) boundary-time))))
       (when assistant-p (setq pilish--assistant-details-clock nil))
       ;; Display error if message ended with error (e.g., API error)
       (when (equal (plist-get message :stopReason) "error")
         (pilish--display-error (plist-get message :errorMessage)))
       ;; The completed assistant message is authoritative over streamed
       ;; preview identities, arguments, membership, ownership, and usage.
       (when assistant-p
         (when (plist-member message :content)
           (pilish--reconcile-toolcall-previews message))
         (pilish--reset-toolcall-streams)
         (pilish--refresh-header))
       (when (equal role "toolResult")
         (pilish--update-tool-details-from-result message)
         (when-let* ((id (plist-get message :toolCallId))
                     (block (or (pilish--nested-tool-owner id)
                                (pilish--tool-block-get id)))
                     ((equal id (pilish--tool-block-tool-call-id block))))
           (pilish--merge-saved-nested-calls block (plist-get message :nestedCalls))
           (pilish--merge-codemode-calls
            block (pilish--tool-arg-get (plist-get message :details) :calls) t)
           (when (pilish--tool-block-compound-p block)
             (pilish--discard-pending-tool-update id)
             (pilish--redraw-compound-tool block))))
       (when assistant-p
         (when pilish--thinking-stream
           (pilish--materialize-thinking-raw))
         (pilish--render-complete-message)
         ;; message_end.message is authoritative; state has already cleared
         ;; :current-message before this handler runs.
         (pilish--apply-assistant-message-metadata message duration))))
    ("tool_execution_start"
     (pilish--set-activity-phase "running")
     (pilish--with-md-ts-change-hooks-suspended
         #'pilish--md-ts-expensive-change-hook-p
       (let* ((tool-call-id (plist-get event :toolCallId))
              (args (plist-get event :args))
              (block (pilish--tool-block-get tool-call-id)))
         ;; Cache args for tool_execution_end (which doesn't include args)
         (when (and tool-call-id pilish--tool-args-cache)
           (puthash tool-call-id args pilish--tool-args-cache))
         ;; Reuse the keyed preview block when it already exists.
         (unless block
           (setq block (pilish--display-tool-start
                        (plist-get event :toolName) args tool-call-id)))
         (pilish--tool-block-set-execution-start block boundary-time args)
         (pilish--argument-observe
          block nil (plist-get event :toolName) args)
         (when (equal (plist-get event :toolName) "codemode")
           (pilish--enable-compound-tool block args))
         ;; Update header and path from authoritative args.
         ;; During streaming, the header may show placeholders since delta
         ;; args can be partial.  Execution start carries the real args.
         (pilish--display-tool-update-header
          (plist-get event :toolName) args block)
         (pilish--tool-block-sync-path-metadata
          block (pilish--tool-arg-path args))
         (when (pilish--tool-block-compound-p block)
           (pilish--redraw-compound-tool block)))))
    ("tool_execution_end"
     (pilish--set-activity-phase "thinking")
     (let* ((tool-call-id (plist-get event :toolCallId))
            (result (plist-get event :result))
            ;; A keyed miss must not finalize an unrelated legacy block.
            (block (or (pilish--tool-block-get tool-call-id)
                       (pilish--nested-tool-owner tool-call-id)
                       (and (pilish--tool-call-id-p tool-call-id)
                            (pilish--display-tool-start
                             (plist-get event :toolName) nil tool-call-id))))
            ;; Compound execution args outlive the ordinary per-turn cache.
            (args (let ((cached
                         (when (and tool-call-id pilish--tool-args-cache)
                           (prog1 (gethash tool-call-id pilish--tool-args-cache)
                             (remhash tool-call-id pilish--tool-args-cache)))))
                    (if (and block (pilish--tool-block-compound-p block))
                        (pilish--tool-block-args block)
                      cached)))
            (duration (pilish--details-elapsed
                       (and block (pilish--tool-block-execution-start block))
                       boundary-time)))
       ;; The authoritative result supersedes any pending preview; discard
       ;; it first so completion renders exactly once.
       (pilish--discard-pending-tool-update tool-call-id)
       (pilish--display-tool-end (plist-get event :toolName)
                                 args
                                 (plist-get result :content)
                                 (plist-get result :details)
                                 (plist-get event :isError)
                                 block)
       (when block
         (pilish--complete-tool-details block (plist-get event :toolName) args duration))))
    ("tool_execution_update"
     (let* ((tool-call-id (plist-get event :toolCallId))
            (partial-result (plist-get event :partialResult))
            (block (or (pilish--nested-tool-owner tool-call-id)
                       (pilish--tool-block-get tool-call-id))))
       (cond
        ((and block (pilish--tool-block-compound-p block))
         ;; Retain parent facts before coalescing the same owner as children.
         ;; A late update cannot replace a finalized parent's result.
         (when (eq block (pilish--tool-block-get tool-call-id))
           (pilish--display-tool-update partial-result block)))
        (tool-call-id (pilish--queue-tool-update tool-call-id partial-result))
        (t (pilish--display-tool-update partial-result nil)))))
    ("compaction_start"
     (when pilish--aborted
       (pilish--send-abort))
     (pilish--set-activity-phase "compact")
     (message (if (equal (plist-get event :reason) "overflow")
                  "Pi: Context overflow, compacting..."
                "Pi: Compacting...")))
    ("compaction_end"
     (pilish--handle-compaction-end-event event))
    ("agent_end"
     ;; Ordinary previews end here; nested execution obligations and their
     ;; coalesced owner paints outlive the agent loop.
     (setq pilish--pending-tool-updates
           (seq-filter (lambda (entry) (pilish--tool-block-p (cdr entry)))
                       pilish--pending-tool-updates))
     (unless pilish--pending-tool-updates
       (pilish--cancel-tool-update-flush))
     (pilish--set-canonical-messages
      (plist-get pilish--state :messages))
     (pilish--display-agent-end)
     (pilish--clear-live-details-state)
     (pilish--update-hot-tail-boundary)
     (pilish--queue-tool-cooling-outside-hot-tail))
    ("agent_settled" nil)
    ("auto_retry_start"
     (pilish--display-retry-start event))
    ("auto_retry_end"
     (pilish--display-retry-end event)
     (unless (eq (plist-get event :success) t)
       (pilish--recover-followups-after-retry-failure)))
    ("extension_error"
     (pilish--display-extension-error event))
    ("extension_ui_request"
     (pilish--handle-extension-ui-request event)))))


;;;; Tool Output

(defun pilish--truncate-to-visual-lines (content max-lines width)
  "Truncate CONTENT to fit within MAX-LINES visual lines at WIDTH.
Also respects `pilish-preview-max-bytes'.
Strips blank lines for compact display but tracks original line numbers.

Returns a plist with:
  :content      - the truncated content (or original if no truncation)
  :visual-lines - number of visual lines in result
  :hidden-lines - raw lines hidden (including stripped blanks)
  :line-map     - vector mapping displayed line to original line number"
  (let* ((safe-max-lines (max 0 (or max-lines 0)))
         (safe-width (max 1 (or width 1)))
         (trimmed (string-trim-right content "\n+"))
         (all-lines (if (string-empty-p trimmed)
                        nil
                      (split-string trimmed "\n")))
         (total-raw-lines (length all-lines))
         (visual-count 0)
         (byte-count 0)
         (max-bytes pilish-preview-max-bytes)
         (result-lines nil)
         (line-map nil)  ; list of original line numbers for kept lines
         (truncated-first-line nil)
         (original-line-num 0))
    (if (= safe-max-lines 0)
        (list :content ""
              :visual-lines 0
              :hidden-lines total-raw-lines
              :line-map [])
      ;; Accumulate non-blank lines until we'd exceed limits
      (catch 'done
        (dolist (line all-lines)
          (setq original-line-num (1+ original-line-num))
          ;; Skip blank lines (they don't count toward visual limit)
          (unless (string-empty-p line)
            (let* ((line-len (length line))
                   ;; Visual lines: ceiling(length / width), minimum 1
                   (line-visual-lines (max 1 (ceiling (float line-len) safe-width)))
                   (new-visual-count (+ visual-count line-visual-lines))
                   ;; +1 for newline between lines
                   (new-byte-count (+ byte-count line-len (if result-lines 1 0))))
              ;; Check if adding this line would exceed limits
              (cond
               ;; Not first line and exceeds limits: stop
               ((and result-lines
                     (or (> new-visual-count safe-max-lines)
                         (> new-byte-count max-bytes)))
                (throw 'done nil))
               ;; First line exceeds limits: truncate it to fit
               ((and (null result-lines)
                     (or (> new-visual-count safe-max-lines)
                         (> new-byte-count max-bytes)))
                (let* ((max-chars-by-visual (* safe-max-lines safe-width))
                       (max-chars (min max-chars-by-visual max-bytes)))
                  (setq line (substring line 0 (min line-len max-chars)))
                  (setq line-len (length line))
                  (setq line-visual-lines (max 1 (ceiling (float line-len) safe-width)))
                  (setq new-visual-count line-visual-lines)
                  (setq new-byte-count line-len)
                  (setq truncated-first-line t))))
              (setq visual-count new-visual-count)
              (setq byte-count new-byte-count)
              (push line result-lines)
              (push original-line-num line-map)))))
      (let* ((kept-lines (nreverse result-lines))
             (line-map-vec (vconcat (nreverse line-map)))
             (last-displayed (if (> (length line-map-vec) 0)
                                 (aref line-map-vec (1- (length line-map-vec)))
                               0))
             (hidden (- total-raw-lines last-displayed)))
        (list :content (pilish--remove-clipped-subagent-names
                        content (string-join kept-lines "\n"))
              :visual-lines visual-count
              ;; Report hidden lines; truncated first line means there's hidden content even with 1 line
              :hidden-lines (if (and truncated-first-line (= hidden 0)) 1 hidden)
              :line-map line-map-vec)))))

(defun pilish--clear-render-artifacts ()
  "Delete pi-owned render artifacts in the current chat buffer.
This removes completed/pending tool overlays, diff overlays, and lightweight
cold-tool metadata before buffer reset or history rebuild, then clears keyed
live-tool state, cached execution args, pending coalesced tool updates,
active thinking anchors, and the compatibility pending overlay slot so
buffer and render state stay consistent.  Pending deferred cooling is
invalidated first.  Tree-sitter overlays are left alone."
  (pilish--cancel-tool-update-flush)
  (pilish--cancel-stream-delta-flush)
  (pilish--reset-thinking-state)
  (pilish--release-nested-tool-state)
  (remove-overlays (point-min) (point-max) 'pilish-tool-block t)
  (remove-overlays (point-min) (point-max) 'pilish-diff-overlay t)
  (let ((inhibit-read-only t))
    (remove-text-properties
     (point-min) (point-max) '(pilish-cold-tool-block nil)))
  (setq pilish--pending-tool-overlay nil
        pilish--tool-block-order-counter 0
        pilish--thinking-block-order-counter 0)
  (when pilish--tool-args-cache
    (clrhash pilish--tool-args-cache))
  (when pilish--live-tool-blocks
    (clrhash pilish--live-tool-blocks))
  (pilish--reset-toolcall-streams)
  (pilish--clear-live-details-state))

(cl-defstruct (pilish--tool-block
               (:constructor pilish--make-tool-block))
  tool-call-id
  overlay
  header-end
  end-marker
  order
  path
  raw-path
  path-error
  offset
  line-map
  last-tail
  image-previews
  execution-start
  details
  compound-p
  args
  result
  displayed-output                   ; Parent presentation used by the last paint.
  script-line-map                    ; Painted preview's source rows; nil when full.
  nested-calls
  folds
  history-p
  summary-incomplete-p
  saved-labels
  argument-view)

(cl-defstruct (pilish--nested-call
               (:constructor pilish--make-nested-call))
  "One nested call's live or saved facts, stored in display order."
  id
  name
  arguments
  arguments-bytes
  args-preview
  status
  error
  source
  started-at
  pending-end-p
  result
  saved-labels
  argument-rows
  argument-charge)

(defvar-local pilish--nested-tool-owners nil
  "Real root and descendant IDs mapped to their retained owning root block.
Child records live only in the root's ordered `nested-calls' list.  This
index outlives ordinary execution registration, never a transcript teardown.")

(defun pilish--nested-tool-owner (id)
  "Return the retained root owning real execution ID, or nil."
  (and pilish--nested-tool-owners
       (gethash id pilish--nested-tool-owners)))

(defun pilish--nested-call-get (block id)
  "Return BLOCK's nested call with exact ID, or nil."
  (seq-find (lambda (call) (equal id (pilish--nested-call-id call)))
            (pilish--tool-block-nested-calls block)))

(defun pilish--promote-nested-call (block call)
  "Place CALL after BLOCK's observed/saved rows and before unmatched details.
Reuse the exact record and preserve the other rows' order."
  (let* ((others (delq call (pilish--tool-block-nested-calls block)))
         (details-p (lambda (row) (eq (pilish--nested-call-source row) 'details))))
    (setf (pilish--tool-block-nested-calls block)
          (append (seq-remove details-p others) (list call)
                  (seq-filter details-p others)))))

(defun pilish--nested-pending-p (block)
  "Return non-nil when BLOCK has an observed descendant still owing an end."
  (and block
       (seq-some #'pilish--nested-call-pending-end-p
                 (pilish--tool-block-nested-calls block))))

(defun pilish--enable-compound-tool (block args &optional history-p)
  "Retain compound BLOCK's authoritative ARGS.
With HISTORY-P, do not register execution ownership; otherwise index the
live root's exact real ID."
  (setf (pilish--tool-block-compound-p block) t
        (pilish--tool-block-args block) args
        (pilish--tool-block-history-p block) history-p)
  (unless history-p
    (unless pilish--nested-tool-owners
      (setq pilish--nested-tool-owners (make-hash-table :test 'equal)))
    (when-let* ((id (pilish--tool-block-tool-call-id block))
                ((pilish--tool-call-id-p id)))
      (puthash id block pilish--nested-tool-owners)))
  block)

(defun pilish--handle-nested-tool-event (event time)
  "Ingest explicit-parent execution EVENT using local seconds TIME.
Unknown parents are ignored.  The first observed start fixes arguments;
starts/updates owe an end, and repeated events cannot reopen ended calls."
  (let* ((parent-id (plist-get event :parentToolCallId))
         (id (plist-get event :toolCallId))
         (block (or (pilish--nested-tool-owner parent-id)
                    (pilish--tool-block-get parent-id))))
    (when (and block (pilish--tool-call-id-p id))
      (unless (pilish--tool-block-compound-p block)
        (pilish--enable-compound-tool block (pilish--tool-block-args block)))
      ;; Anonymous details are a whole-snapshot fallback, never event rows.
      (setf (pilish--tool-block-nested-calls block)
            (seq-filter #'pilish--nested-call-id (pilish--tool-block-nested-calls block)))
      (let ((call (pilish--nested-call-get block id)))
        (when (or (null call) (memq (pilish--nested-call-source call) '(details saved)))
          (unless call (setq call (pilish--make-nested-call :id id)))
          (setf (pilish--nested-call-name call) (plist-get event :toolName)
                (pilish--nested-call-arguments call)
                (if (plist-member event :args) (plist-get event :args)
                  (pilish--nested-call-arguments call))
                (pilish--nested-call-source call) 'event
                (pilish--nested-call-status call)
                (if (eq (pilish--nested-call-status call) 'cancelled) 'cancelled 'running)
                (pilish--nested-call-pending-end-p call) t)
          (when (plist-member event :args)
            (pilish--argument-observe
             block call (plist-get event :toolName) (plist-get event :args)))
          (pilish--promote-nested-call block call)
          (puthash id block pilish--nested-tool-owners))
        (when (pilish--nested-call-pending-end-p call)
          (pcase (plist-get event :type)
            ("tool_execution_start"
             (unless (pilish--nested-call-started-at call)
               (setf (pilish--nested-call-started-at call) time
                     (pilish--nested-call-name call) (plist-get event :toolName)
                     (pilish--nested-call-arguments call) (plist-get event :args))
               (pilish--argument-observe
                block call (plist-get event :toolName) (plist-get event :args))))
            ("tool_execution_end"
             (setf (pilish--nested-call-pending-end-p call) nil
                   (pilish--nested-call-status call)
                   (if (eq t (plist-get event :isError))
                       (if (eq (pilish--nested-call-status call) 'cancelled) 'cancelled 'error)
                     'ok)
                   (pilish--nested-call-result call)
                   (let ((result (plist-get event :result)))
                     (if (and (listp result)
                              (vectorp (plist-get result :content)))
                         result
                       '(:content []))))
             (pilish--argument-settle
              block call (pilish--nested-call-name call)
              (list :result-present-p t
                    :is-error (eq t (plist-get event :isError))
                    :details (plist-get (plist-get event :result) :details)))
             (let ((result (pilish--nested-call-result call)))
               (setf (pilish--nested-call-saved-labels call)
                     (pilish--saved-conversation-labels
                      (pilish--nested-call-name call)
                      (plist-get result :content) (plist-get result :details))))))
          (if (equal (plist-get event :type) "tool_execution_update")
              (pilish--queue-tool-update (pilish--tool-block-tool-call-id block) block)
            (pilish--discard-pending-tool-update (pilish--tool-block-tool-call-id block))
            (pilish--redraw-compound-tool block))
          (unless (pilish--nested-pending-p block)
            (pilish--queue-tool-cooling-outside-hot-tail))))))
  nil)

(defun pilish--merge-saved-nested-calls (block nested-calls)
  "Merge saved NESTED-CALLS facts into BLOCK without execution obligations.
Exact event-backed status, arguments and received results remain authoritative.
Saved rows supply no ancestry or child output.  A valid container, even empty,
enables the shared compound presentation."
  (let ((calls (pilish--tool-arg-get nested-calls :calls)))
    (when (vectorp calls)
      (pilish--enable-compound-tool block (pilish--tool-block-args block)
                                    (pilish--tool-block-history-p block))
      (setf (pilish--tool-block-summary-incomplete-p block)
            (eq :false (pilish--tool-arg-get nested-calls :complete)))
      (dolist (row (append calls nil))
        (let* ((id (pilish--tool-arg-get row :id))
               (name (pilish--tool-arg-get row :name))
               (status (pcase (pilish--tool-arg-get row :status)
                         ("ok" 'ok) ("error" 'error) ("unfinished" 'unfinished)))
               (arguments (pilish--tool-arg-get row :arguments)))
          (when (and (pilish--tool-call-id-p id) (stringp name) status)
            (let ((call (pilish--nested-call-get block id)))
              (unless call
                (setq call (pilish--make-nested-call :id id :source 'saved)))
              (unless (eq (pilish--nested-call-source call) 'event)
                (setf (pilish--nested-call-source call) 'saved
                      (pilish--nested-call-name call) name
                      (pilish--nested-call-status call) status)
                (pilish--promote-nested-call block call))
              (when (and (null (pilish--nested-call-arguments call)) (listp arguments))
                (setf (pilish--nested-call-arguments call) arguments)
                (pilish--argument-observe block call name arguments)
                (let ((result (pilish--nested-call-result call)))
                  (pilish--argument-settle
                   block call name
                   (list :result-present-p (and result t)
                         :is-error (memq (pilish--nested-call-status call) '(error cancelled))
                         :details (plist-get result :details)))))
              (when-let* (((eq (pilish--nested-call-source call) 'saved))
                          ((not (pilish--tool-arg-member row :arguments)))
                          (bytes (pilish--tool-arg-get row :argumentsBytes))
                          ((integerp bytes)) ((>= bytes 0)))
                (setf (pilish--nested-call-arguments-bytes call) bytes))
              (when-let* ((error-text (pilish--tool-arg-get row :error)) ((stringp error-text)))
                (setf (pilish--nested-call-error call) error-text))))))))
  nil)

(defun pilish--merge-codemode-calls (block calls &optional saved-p)
  "Merge codemode metadata into BLOCK.
CALLS supplies exact-ID rows; previews are text, never arguments or output.
A calls array, even empty, enables compound presentation.
SAVED-P makes unmatched running metadata unfinished rather than live work."
  (when (and (equal (overlay-get (pilish--tool-block-overlay block) 'pilish-tool-name)
                    "codemode")
             (vectorp calls))
    (pilish--enable-compound-tool block (pilish--tool-block-args block)
                                  (pilish--tool-block-history-p block))
    (setf (pilish--tool-block-nested-calls block)
          (seq-filter #'pilish--nested-call-id (pilish--tool-block-nested-calls block)))
    (dolist (row (append calls nil))
      (let* ((id (pilish--tool-arg-get row :id))
             (anonymous-p (and (stringp id) (string-suffix-p "/?" id)))
             (name (pilish--tool-arg-get row :name))
             (status (pcase (pilish--tool-arg-get row :status)
                       ("running" 'running) ("ok" 'ok)
                       ("error" 'error) ("cancelled" 'cancelled))))
        (when (and (pilish--tool-call-id-p id) (stringp name) status
                   (not (and anonymous-p
                             (seq-some (lambda (call)
                                         (memq (pilish--nested-call-source call) '(event saved)))
                                       (pilish--tool-block-nested-calls block)))))
          (let ((call (unless anonymous-p (pilish--nested-call-get block id))))
            (unless call
              (setq call (pilish--make-nested-call :id (unless anonymous-p id)
                                                 :name name :source 'details))
              (setf (pilish--tool-block-nested-calls block)
                    (nconc (pilish--tool-block-nested-calls block) (list call))))
            (when (eq (pilish--nested-call-source call) 'details)
              (setf (pilish--nested-call-name call) name
                    (pilish--nested-call-status call)
                    (if (and saved-p (eq status 'running)) 'unfinished status)))
            ;; Cancellation is exact-ID evidence, not an execution end.  Only
            ;; pending work or an observed/saved failure can be refined; success
            ;; and saved unfinished facts remain authoritative.
            (when (and (eq status 'cancelled)
                       (or (pilish--nested-call-pending-end-p call)
                           (eq (pilish--nested-call-status call) 'error)))
              (setf (pilish--nested-call-status call) 'cancelled))
            (when-let* ((preview (pilish--tool-arg-get row :args)) ((stringp preview)))
              (setf (pilish--nested-call-args-preview call) preview))
            (when-let* ((error-text (pilish--tool-arg-get row :error)) ((stringp error-text)))
              (setf (pilish--nested-call-error call) error-text)))))))
  nil)

(defun pilish--compound-tool-details (block)
  "Return BLOCK's parent details without already presented codemode fields."
  (let ((details (plist-get (pilish--tool-block-result block) :details)))
    (if (and (listp details)
             (equal (overlay-get (pilish--tool-block-overlay block) 'pilish-tool-name) "codemode"))
        (cl-loop for (key value) on details by #'cddr
                 unless (memq key '(:calls :fullOutputPath)) append (list key value))
      details)))

(defun pilish--tool-block-face (block)
  "Return BLOCK's current background face."
  (or (overlay-get (pilish--tool-block-overlay block) 'face)
      'pilish-tool-block))

(defun pilish--tool-prefix-spaces (width &optional face)
  "Return WIDTH display-only spaces owned by a hot tool with FACE."
  (propertize (make-string width ?\s)
              'pilish-tool-prefix t 'face (or face 'pilish-tool-block)))

(defun pilish--tool-place-prefixes (start end)
  "Place owned row prefixes on adjacent hidden wrappers within START..END.
START and END delimit one tool block.  Alignment stays within argument and
section ownership.  A real heading's display envelope may include the preceding
section's contiguous hidden closing wrapper, never preceding visible content."
  (let ((position start))
    (while (< position end)
      (let* ((next (next-single-property-change position 'line-prefix nil end))
             (prefix (get-text-property position 'line-prefix)))
        (when (and (stringp prefix)
                   (or (text-property-any 0 (length prefix) 'pilish-tool-prefix t prefix)
                       (text-property-not-all 0 (length prefix) 'pilish-disclosure-hit nil prefix))
                   (not (equal (get-text-property position 'display) ""))
                   (not (invisible-p position)))
          (let* ((hit (get-text-property position 'pilish-disclosure-hit))
                 (heading (and hit (get-text-property position 'pilish-tool-fold-heading)
                               (button-at position)))
                 (lower (if heading start
                          (max start
                               (previous-single-property-change (1+ position) 'pilish-argument-address nil start)
                               (previous-single-property-change (1+ position) 'pilish-tool-section nil start))))
                 (hidden position))
            (while (and (> hidden lower)
                        (or (equal (get-text-property (1- hidden) 'display) "")
                            (invisible-p (1- hidden))))
              (setq hidden (max lower
                                (previous-single-property-change hidden 'display nil lower)
                                (previous-single-property-change hidden 'invisible nil lower))))
            (when (< hidden position)
              (if heading
                  (let ((part hidden))
                    (while (< part position)
                      (let ((end (next-single-property-change part 'line-prefix nil position)))
                        (put-text-property part end 'line-prefix
                                           (pilish--disclosure-compose-prefix
                                            (substring prefix 0 1)
                                            (get-text-property part 'line-prefix)))
                        (setq part end))))
                (put-text-property hidden (1+ hidden) 'line-prefix prefix))
              (when hit
                (add-text-properties hidden position
                                     `(pilish-disclosure-hit ,hit rear-nonsticky t))))))
        (setq position next)))))

(defun pilish--tool-prefix-update (prefix face release)
  "Return PREFIX with owned alignment FACE, or remove decoration with RELEASE."
  (let ((position 0) parts)
    (while (< position (length prefix))
      (let* ((next (next-single-property-change position 'pilish-tool-prefix prefix (length prefix)))
             (piece (substring prefix position next)))
        (when (get-text-property position 'pilish-tool-prefix prefix)
          (if release
              (remove-text-properties 0 (length piece) '(face nil pilish-tool-prefix nil) piece)
            (put-text-property 0 (length piece) 'face face piece)))
        (push piece parts)
        (setq position next)))
    (let ((text (apply #'concat (nreverse parts))))
      (unless (string-empty-p text) text))))

(defun pilish--tool-refresh-prefixes (block &optional release)
  "Refresh BLOCK's owned prefix backgrounds, or RELEASE their hot decoration."
  (when-let* ((overlay (pilish--tool-block-overlay block))
              ((overlay-buffer overlay)))
    (let ((inhibit-read-only t)
          (face (pilish--tool-block-face block))
          (end (overlay-end overlay)))
      (with-silent-modifications
        (dolist (property '(line-prefix wrap-prefix))
          (let ((position (overlay-start overlay)))
            (while (< position end)
              (let ((next (next-single-property-change position property nil end))
                    (prefix (get-text-property position property)))
                (when (stringp prefix)
                  (put-text-property position next property
                                     (pilish--tool-prefix-update prefix face release)))
                (setq position next)))))))))

(defun pilish--toggle-tool-fold-button-at-point ()
  "Activate only the real tool fold button at point."
  (when-let* ((button (button-at (point)))
              ((button-get button 'pilish-tool-toggle)))
    (button-activate button)))

(defvar pilish--tool-button-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map button-map)
    (define-key map (kbd "TAB") #'pilish-toggle-tool-section)
    (define-key map (kbd "<tab>") #'pilish-toggle-tool-section)
    (define-key map (kbd "<return>") #'push-button)
    (define-key map [left-margin down-mouse-1] #'ignore)
    (define-key map [left-margin mouse-1] #'pilish--disclosure-click)
    map)
  "Keymap for tool buttons, with TAB reserved for section folding.")

(defun pilish--insert-compound-tool-heading (label section expanded &optional suffix)
  "Insert LABEL before SECTION's content with its existing fold authority.
EXPANDED selects display.  SUFFIX is the existing collapsed diagnostic."
  (let* ((start (point))
         (text (concat label (and (not expanded) suffix))))
    (insert-text-button text
                        'face 'pilish-collapsed-indicator
                        'action #'pilish--toggle-compound-tool-section
                        'keymap pilish--tool-button-map
                        'follow-link t 'pilish-tool-toggle t
                        'pilish-tool-section section)
    (insert "\n")
    (put-text-property start (point) 'pilish-tool-fold-heading t)
    (pilish--put-disclosure start (point) expanded
                           #'pilish--toggle-tool-fold-button-at-point)))

(defun pilish--compound-tool-code (block)
  "Return authoritative JavaScript from compound codemode BLOCK, or nil."
  (when (equal (overlay-get (pilish--tool-block-overlay block) 'pilish-tool-name)
               "codemode")
    (let ((code (pilish--tool-arg-get (pilish--tool-block-args block) :code)))
      (and (stringp code) (not (string-empty-p code)) code))))

(defun pilish--insert-compound-tool-body (block &optional output-presentation)
  "Insert BLOCK's compound body at point without child tool overlays.
Reuse ordinary result selection and rich-output insertion directly.
OUTPUT-PRESENTATION folds a displayed snapshot; otherwise select current facts."
  (let* ((folds (pilish--tool-block-folds block))
         script-line-map
         (presentation
          (or output-presentation
              (when-let* ((result (pilish--tool-block-result block)))
                (pilish--tool-result-presentation
                 (overlay-get (pilish--tool-block-overlay block) 'pilish-tool-name)
                 (pilish--tool-block-args block)
                 (plist-get result :content) (pilish--compound-tool-details block)
                 (plist-get result :isError) nil (pilish--tool-block-saved-labels block))))))
    (when-let* ((code (pilish--compound-tool-code block)))
      (let* ((start (point))
             (truncation (pilish--truncate-to-visual-lines
                          code pilish-tool-preview-lines (pilish--chat-display-width)))
             (hidden (plist-get truncation :hidden-lines))
             (expanded (member 'script folds)))
        (when (> hidden 0)
          (pilish--insert-compound-tool-heading
           "Script" 'script expanded (format " (%d more lines)" hidden)))
        (pilish--insert-rendered-tool-content
         (if (or expanded (= hidden 0))
             (string-trim-right code "\n+")
           (plist-get truncation :content))
         "javascript" nil)
        (setq script-line-map
              (when (and (not expanded) (> hidden 0)) (plist-get truncation :line-map)))
        (add-text-properties start (point) '(pilish-tool-section script))))
    (when (and presentation
               (or (not (string-empty-p (plist-get presentation :text)))
                   (plist-get presentation :images)))
      (let* ((start (point))
             (text (plist-get presentation :text))
             (truncation (pilish--truncate-to-visual-lines
                          text (plist-get presentation :preview-limit)
                          (pilish--chat-display-width)))
             (hidden (plist-get truncation :hidden-lines))
             (expanded (member 'output folds)))
        (when (> hidden 0)
          (pilish--insert-compound-tool-heading "Output" 'output expanded))
        (unless (string-empty-p text)
          (pilish--insert-rendered-tool-content
           (if (or expanded (= hidden 0))
               (string-trim-right text "\n+")
             (plist-get truncation :content))
           (plist-get presentation :lang) (plist-get presentation :is-edit-diff)))
        (pilish--insert-image-previews (plist-get presentation :images))
        (setf (pilish--tool-block-offset block) (plist-get presentation :offset)
              (pilish--tool-block-line-map block)
              (when (and (not expanded) (> hidden 0)) (plist-get truncation :line-map)))
        (add-text-properties start (point) '(pilish-tool-section output))))
    (when-let* (((equal (overlay-get (pilish--tool-block-overlay block) 'pilish-tool-name) "codemode"))
                (path (pilish--tool-arg-get (plist-get (pilish--tool-block-result block) :details)
                                            :fullOutputPath))
                ((stringp path)))
      (insert (propertize (concat "Full output: " (pilish--tool-display-value-string path) "\n")
                          'pilish-no-fontify t 'pilish-tool-section 'full-output)))
    (when-let* ((calls (pilish--tool-block-nested-calls block)))
      (let* ((start (point))
             (width (max 24 (pilish--chat-display-width)))
             (expanded (member 'children folds))
             (hidden (if expanded 0 (max 0 (- (length calls) pilish-tool-preview-lines)))))
        (if (> (length calls) (max 0 pilish-tool-preview-lines))
            (pilish--insert-compound-tool-heading
             "Child calls" 'children expanded (format " (%d earlier calls)" hidden))
          (insert "Child calls\n"))
        ;; The list's bounds are stamped first; child sections override them.
        (add-text-properties start (point) '(pilish-tool-section children))
        (dolist (call (nthcdr hidden calls))
          (let* ((child-start (point))
                 (section (cons 'child (pilish--nested-call-id call)))
                 (open (member section folds))
                 (child-result (pilish--nested-call-result call))
                 (presentation
                  (when child-result
                    (pilish--tool-result-presentation
                     (pilish--nested-call-name call) (pilish--nested-call-arguments call)
                     (plist-get child-result :content) (plist-get child-result :details)
                     (not (null (memq (pilish--nested-call-status call) '(error cancelled))))
                     (not open) (pilish--nested-call-saved-labels call))))
                 (text (plist-get presentation :text))
                 (images (plist-get presentation :images))
                 (rendered (pilish--tool-call-text block call width))
                 (summary (car rendered))
                 (rows-text (cdr rendered)))
            (insert (propertize summary
                                'pilish-nested-root-id (pilish--tool-block-tool-call-id block)))
            (when rows-text
              (insert "\n" rows-text))
            (when-let* (((eq (pilish--nested-call-source call) 'saved))
                        (bytes (pilish--nested-call-arguments-bytes call)))
              (insert (propertize (format " saved arguments omitted (%d bytes)" bytes)
                                  'pilish-no-fontify t)))
            (insert "\n")
            (when (or (plist-get presentation :image-content-p)
                      images (and text (not (string-empty-p text))))
              (pilish--insert-compound-tool-heading "Output" section open))
            (when open
              (let ((output-start (point)))
                (when (and text (not (string-empty-p text)))
                  (pilish--insert-rendered-tool-content
                   (string-trim-right text "\n+") (plist-get presentation :lang)
                   (plist-get presentation :is-edit-diff)))
                (pilish--insert-image-previews images)
                (add-text-properties output-start (point) '(pilish-child-output t))))
            (add-text-properties child-start (point) (list 'pilish-tool-section section))))
        (when (pilish--tool-block-history-p block)
          (insert (propertize "Child outputs are not saved in sessions.\n"
                              'pilish-no-fontify t 'pilish-tool-section 'children)))))
    (when (pilish--tool-block-summary-incomplete-p block)
      (insert (propertize "Incomplete saved call summary\n"
                          'pilish-no-fontify t 'pilish-tool-section 'children)))
    (setf (pilish--tool-block-displayed-output block) presentation
          (pilish--tool-block-script-line-map block) script-line-map)))

(defun pilish--toggle-compound-tool-section (button)
  "Toggle only BUTTON's compound fold key."
  (when-let* ((overlay (save-excursion
                        (goto-char (button-start button))
                        (pilish--tool-overlay-at-point)))
              (block (pilish--tool-block-from-overlay overlay))
              ((pilish--tool-block-compound-p block)))
    (let* ((section (button-get button 'pilish-tool-section))
           (folds (pilish--tool-block-folds block))
           (collapsing (member section folds)))
      (setf (pilish--tool-block-folds block)
            (if collapsing (remove section folds) (cons section folds)))
      (pilish--redraw-compound-tool block section))))

(defun pilish--tool-section-bounds (start end &optional line-maps)
  "Return transient (KEY START END ROWS) section geometry in START..END.
Each content row is (SOURCE-LINE START END).  LINE-MAPS associates section
keys with preview vectors naming the original source lines; other rows
use their displayed order.  Images have section-local ordinal keys and precede
containing text sections so surviving image rows keep their exact positions.
Geometry belongs to this paint, not retained facts."
  (let ((position start) sections)
    (while (< position end)
      (let ((next (next-single-property-change position 'pilish-tool-section nil end))
            (key (get-text-property position 'pilish-tool-section)))
        (when key
          (let ((line-map (cdr (assoc key line-maps))))
            (push (list key position next
                        (seq-map-indexed
                         (lambda (line index)
                           (cons (if line-map (aref line-map index) (1+ index)) line))
                         (pilish--tool-section-content-lines (list key position next))))
                  sections)))
        (setq position next)))
    (let ((position start) counts images)
      (while (< position end)
        (let ((next (next-single-property-change position 'pilish-image-preview nil end)))
          (when (get-text-property position 'pilish-image-preview)
            (let* ((section (get-text-property position 'pilish-tool-section))
                   (ordinal (or (alist-get section counts nil nil #'equal) 0))
                   (image-end (if (and (< next end) (eq (char-after next) ?\n)) (1+ next) next)))
              (setf (alist-get section counts nil nil #'equal) (1+ ordinal))
              (push (list (list 'image section ordinal) position image-end
                          (list (list 1 position image-end))) images)))
          (setq position next)))
      (append (nreverse images) (nreverse sections)))))

(defun pilish--tool-section-content-lines (section)
  "Return transient content-line spans for SECTION as (START END).
Script and parent output exclude wrapper fences and their final newline.
A child separates its summary from its displayed body rows, so summary
width cannot change output coordinates.  The list keeps its heading."
  (let* ((start (nth 1 section))
         (end (nth 2 section))
         (bounds
          (pcase (car section)
            ((or 'script 'output) (list (pilish--tool-fenced-content-bounds start end)))
            ('children
             (list (cons start (save-excursion
                                 (goto-char start)
                                 (min end (line-beginning-position 2))))))
            (`(child . ,_)
             (let ((title-start (if (get-text-property start 'pilish-argument-guard)
                                    (next-single-property-change start 'pilish-argument-guard nil end)
                                  start))
                   (output-start (text-property-any start end 'pilish-child-output t)))
               (list (cons title-start (save-excursion
                                         (goto-char title-start)
                                         (min end (line-beginning-position 2))))
                     (when output-start (cons output-start end)))))))
         lines)
    (save-excursion
      (dolist (region bounds)
        (when region
          (goto-char (car region))
          (while (< (point) (cdr region))
            (push (list (point) (min (cdr region) (line-beginning-position 2))) lines)
            (forward-line 1)))))
    (vconcat (nreverse lines))))

(defun pilish--map-tool-section-position
    (position old-sections new-sections start old-end new-end &optional toggled-section)
  "Map POSITION through transient OLD-SECTIONS and NEW-SECTIONS.
START, OLD-END and NEW-END delimit the body rewrite.  Outside positions
use the existing cooling mapper.  Content follows its source row and
character offset in either fold direction.  Vanished characters clamp to
their section anchor, or the list header when the list hides that child.
Decoration in TOGGLED-SECTION also clamps, never impersonating source text."
  (if-let* ((old (seq-find (lambda (section)
                            (and (>= position (nth 1 section)) (< position (nth 2 section))))
                          old-sections)))
      (if-let* ((new (assoc (car old) new-sections)))
          (if-let* ((row (seq-find (lambda (row)
                                    (and (>= position (nth 1 row)) (< position (nth 2 row))))
                                  (nth 3 old))))
              (let ((offset (- position (nth 1 row)))
                    (target (assoc (car row) (nth 3 new))))
                (if (and target (< offset (- (nth 2 target) (nth 1 target))))
                    (+ (nth 1 target) offset)
                  (nth 1 new)))
            (if (equal (car old) toggled-section)
                (nth 1 new)
              (let ((offset (- position (nth 1 old))))
                (+ (nth 1 new) (if (< offset (- (nth 2 new) (nth 1 new))) offset 0)))))
        (or (nth 1 (assq 'children new-sections)) start))
    (pilish--map-tool-cooling-position position start old-end new-end)))

(defun pilish--redraw-compound-tool (block &optional toggled-section)
  "Rewrite compound BLOCK within retained bounds and preserve each reader's view.
Script and output coordinates always use the actual old and new painted
line maps.  TOGGLED-SECTION identifies an explicit fold in either direction.
Parent output folds use the last painted presentation so captured row spans
and preview line maps share one source.  Pending updates still paint newer
retained facts through the existing queue."
  (when-let* ((overlay (pilish--tool-block-overlay block))
              ((eq (overlay-buffer overlay) (current-buffer)))
              (header (pilish--tool-block-header-end block))
              (end (pilish--tool-block-end-marker block)))
    (pilish--annotate-saved-conversation-header block (pilish--tool-block-saved-labels block))
    (let* ((start (marker-position header))
           (old-end (marker-position end))
           (old-sections
            (pilish--tool-section-bounds
             start old-end
             (list (cons 'script (pilish--tool-block-script-line-map block))
                   (cons 'output (pilish--tool-block-line-map block)))))
           (displayed-output (and (eq toggled-section 'output)
                                  (pilish--tool-block-displayed-output block)))
           (view (pilish--capture-tool-cooling-view))
           (inhibit-read-only t))
      (save-excursion
        (remove-overlays start old-end 'pilish-diff-overlay t)
        (delete-region start old-end)
        (goto-char start)
        (pilish--insert-compound-tool-body block displayed-output)
        (set-marker header start)
        (set-marker end (point))
        (pilish--tool-block-refresh-overlay block)
        (pilish--font-lock-ensure-excluding-property start (point) 'pilish-no-fontify))
      (let* ((new-end (marker-position end))
             (new-sections
              (pilish--tool-section-bounds
               start new-end
               (list (cons 'script (pilish--tool-block-script-line-map block))
                     (cons 'output (pilish--tool-block-line-map block))))))
        (pilish--restore-tool-cooling-view
         view start old-end new-end
         (lambda (position)
           (pilish--map-tool-section-position
            position old-sections new-sections start old-end new-end toggled-section)))))))

(defun pilish--release-nested-tool-block (block)
  "Release BLOCK's retained routing, payloads, fold choices and markers."
  (pilish--discard-pending-tool-update (pilish--tool-block-tool-call-id block))
  (when pilish--nested-tool-owners
    (remhash (pilish--tool-block-tool-call-id block) pilish--nested-tool-owners))
  (dolist (call (pilish--tool-block-nested-calls block))
    (when pilish--nested-tool-owners
      (remhash (pilish--nested-call-id call) pilish--nested-tool-owners))
    (setf (pilish--nested-call-arguments call) nil
          (pilish--nested-call-arguments-bytes call) nil
          (pilish--nested-call-args-preview call) nil
          (pilish--nested-call-error call) nil
          (pilish--nested-call-result call) nil
          (pilish--nested-call-started-at call) nil
          (pilish--nested-call-pending-end-p call) nil
          (pilish--nested-call-argument-rows call) nil
          (pilish--nested-call-argument-charge call) nil))
  (setf (pilish--tool-block-args block) nil
        (pilish--tool-block-result block) nil
        (pilish--tool-block-argument-view block) nil
        (pilish--tool-block-displayed-output block) nil
        (pilish--tool-block-script-line-map block) nil
        (pilish--tool-block-nested-calls block) nil
        (pilish--tool-block-folds block) nil
        (pilish--tool-block-history-p block) nil
        (pilish--tool-block-summary-incomplete-p block) nil
        (pilish--tool-block-last-tail block) nil
        (pilish--tool-block-image-previews block) nil
        (pilish--tool-block-compound-p block) nil)
  (set-marker (pilish--tool-block-header-end block) nil)
  (set-marker (pilish--tool-block-end-marker block) nil)
  (pilish--tool-block-unregister block)
  (when (eq pilish--pending-tool-overlay (pilish--tool-block-overlay block))
    (setq pilish--pending-tool-overlay nil))
  nil)

(defun pilish--release-nested-tool-state (&optional keep-text)
  "Release retained execution routing and payloads at a teardown boundary.
With KEEP-TEXT, mark pending or still-running calls unfinished and freeze the
body before releasing payloads.  Idempotent; never a turn-settlement cleanup."
  (pilish--cancel-tool-cooling)
  (pilish--cancel-tool-update-flush)
  (let ((blocks (when pilish--nested-tool-owners
                  (delete-dups (hash-table-values pilish--nested-tool-owners)))))
    ;; History has display identity but no runtime owners.  Release its hot
    ;; snapshots at the same teardown boundary, before their overlays vanish.
    (dolist (overlay (pilish--tool-block-overlays-in-region (point-min) (point-max)))
      (when-let* ((block (pilish--tool-block-from-overlay overlay))
                  ((pilish--tool-block-compound-p block)))
        (cl-pushnew block blocks)))
    (dolist (block blocks)
      (let ((overlay (pilish--tool-block-overlay block)))
        (if (and keep-text (eq (overlay-buffer overlay) (current-buffer)))
            (progn
              (dolist (call (pilish--tool-block-nested-calls block))
                (when (or (pilish--nested-call-pending-end-p call)
                          (eq (pilish--nested-call-status call) 'running))
                  (setf (pilish--nested-call-status call) 'unfinished
                        (pilish--nested-call-pending-end-p call) nil)))
              (pilish--argument-settle-pending-children block)
              (pilish--redraw-compound-tool block)
              (pilish--tool-block-finalize block (overlay-get overlay 'face))
              (pilish--cool-tool-overlay-preserving-view overlay))
          (pilish--release-nested-tool-block block))))
    (when pilish--nested-tool-owners
      (clrhash pilish--nested-tool-owners)))
  nil)


(defconst pilish--argument-limit-block-chars 32768
  "Maximum retained display characters per block, keys included.")

(defconst pilish--argument-limit-block-bytes 65536
  "Maximum retained UTF-8 bytes per block, keys included.")

(defconst pilish--argument-limit-value-chars 4096
  "Maximum display characters retained for one argument value.")

(defconst pilish--argument-limit-value-bytes 8192
  "Maximum UTF-8 bytes retained for one argument value.")

(defconst pilish--argument-number-bound
  (expt 10 pilish--argument-limit-value-chars)
  "Magnitude bound before converting an integer to display text.
Derived from the value limit, so numeric conversion cannot serialize an
arbitrarily large decoded JSON integer before clipping it.")

(defconst pilish--argument-limit-key-chars 128
  "Maximum display characters retained for one argument key.")

(defconst pilish--argument-limit-depth 4
  "Maximum container nesting visited inside one argument value.")

(defconst pilish--argument-limit-nodes 1024
  "Maximum values visited per block, including container children.")

(defconst pilish--argument-limit-call-entries 64
  "Maximum top-level entries captured for one call.")

(defconst pilish--argument-limit-block-entries 256
  "Maximum object keys visited per block, children included.")

(cl-defstruct (pilish--argument-view
               (:constructor pilish--make-argument-view))
  "Block-owned allocation ledger and root rows for argument display.
ROOT-CHARGE and each nested call's `argument-charge' record one node's
share of the aggregate CHARS/BYTES/NODES/KEYS counters, so replacing one
node's observation releases exactly its own allocation.  TRUNCATED-P is
non-nil when any row or value was dropped or cut."
  root-rows
  root-charge
  (chars 0)
  (bytes 0)
  (nodes 0)
  (keys 0)
  truncated-p)

(cl-defstruct (pilish--argument-row
               (:constructor pilish--make-argument-row))
  "One bounded argument row captured from authoritative tool arguments.
KEY is the display-escaped key, or nil for the primary value and inert
omission markers.  ROLE is `primary', `ordinary', `settlement' (hidden
until the result decides), `input-needed', `input-represented', or
`omission'.  TEXT is bounded display-safe text with real newline
characters; a trailing ellipsis is baked in only when the retained text
drops original content.  CUT is nil or the reason symbol; it never
reflects literal ellipsis characters present in the original data."
  ordinal
  key
  raw-key
  role
  text
  cut)

(defconst pilish--argument-key-policy
  '((:tool "bash" :primary-key :command)
    (:tool "read" :primary-key :path :primary-alias :file_path)
    (:tool "write" :primary-key :path :primary-alias :file_path
           :settlement-keys (:content))
    (:tool "edit" :primary-key :path :primary-alias :file_path
           :settlement-keys (:edits :oldText :newText))
    (:tool "codemode" :settlement-keys (:code)))
  "Central capture and settlement policy for known tool argument keys.
:PRIMARY-KEY (plus optional :PRIMARY-ALIAS) names the keyless title
value.  :SETTLEMENT-KEYS name input that a successful result represents
elsewhere; settlement decides whether each stays hidden or becomes
bounded diagnostic input.  Every other key, known or unknown, is an
ordinary visible row.")

(defun pilish--argument-policy (tool-name)
  "Return TOOL-NAME's capture policy entry, or nil."
  (cl-find-if (lambda (entry) (equal (plist-get entry :tool) tool-name))
              pilish--argument-key-policy))

(defun pilish--argument-classify (tool-name key root-p edits-pure-p)
  "Return the capture role for KEY of TOOL-NAME.
ROOT-P limits codemode settlement to the root script.  EDITS-PURE-P
comes from the bounded visitor, not a separate schema scan."
  (cond
   ((and (equal tool-name "codemode") (not root-p)) 'ordinary)
   ((and (equal tool-name "edit") (eq key :edits) (not edits-pure-p))
    'ordinary)
   ((memq key (plist-get (pilish--argument-policy tool-name) :settlement-keys))
    'settlement)
   (t 'ordinary)))


(defun pilish--argument-escape-bounded (text preserve-newlines char-limit byte-limit
                                           &optional start)
  "Return (ESCAPED . CUT-P) for string TEXT, display-escaped and bounded.
Escape control and format characters like
`pilish--escape-control-chars-for-display', preserving real newlines only
with PRESERVE-NEWLINES, but stop once ESCAPED would exceed CHAR-LIMIT
characters or BYTE-LIMIT UTF-8 bytes.  CUT-P is non-nil when any input
character was dropped.  START skips a key's keyword prefix without
copying its unbounded name.  Never scans past the allowed prefix."
  (let ((length (length text))
        (index (or start 0))
        (chars 0)
        (bytes 0)
        (cut nil)
        (parts nil))
    (while (and (< index length) (not cut))
      (let* ((char (aref text index))
             (piece
              (cond
               ((eq char ?\n) (if preserve-newlines "\n" "\\n"))
               ((eq char ?\r) "\\r")
               ((eq char ?\t) "\\t")
               ((or (< char 32) (= char #x7f)) (format "\\x%02X" char))
               ((memq (get-char-code-property char 'general-category) '(Cc Cf))
                (pilish--unicode-escape-char char))
               (t (char-to-string char)))))
        (let ((piece-chars (length piece))
              (piece-bytes (string-bytes piece)))
          (if (or (> (+ chars piece-chars) char-limit)
                  (> (+ bytes piece-bytes) byte-limit))
              (setq cut t)
            (push piece parts)
            (setq chars (+ chars piece-chars)
                  bytes (+ bytes piece-bytes)
                  index (1+ index))))))
    (cons (apply #'concat (nreverse parts))
          (or cut (< index length)))))

(defun pilish--argument--emit (state piece)
  "Append literal display-safe PIECE to render STATE within value limits.
STATE is a plist with :parts, :chars, :bytes, :nodes and :cut counters."
  (unless (plist-get state :cut)
    (let ((chars (+ (plist-get state :chars) (length piece)))
          (bytes (+ (plist-get state :bytes) (string-bytes piece))))
      (if (or (> chars (plist-get state :char-limit))
              (> bytes (plist-get state :byte-limit)))
          (setf (plist-get state :cut)
                (if (> chars (plist-get state :char-limit)) 'value 'bytes))
        (push piece (plist-get state :parts))
        (setf (plist-get state :chars) chars
              (plist-get state :bytes) bytes)))))

(defun pilish--argument--emit-escaped (state text preserve-newlines)
  "Append bounded display-escaped TEXT to render STATE.
PRESERVE-NEWLINES keeps real newline characters (top-level values only)."
  (unless (plist-get state :cut)
    (let* ((remaining-chars (max 0 (- (plist-get state :char-limit)
                                      (plist-get state :chars))))
           (remaining-bytes (max 0 (- (plist-get state :byte-limit)
                                      (plist-get state :bytes))))
           (result (pilish--argument-escape-bounded
                    text preserve-newlines remaining-chars remaining-bytes))
           (escaped (car result)))
      (push escaped (plist-get state :parts))
      (setf (plist-get state :chars) (+ (plist-get state :chars) (length escaped))
            (plist-get state :bytes) (+ (plist-get state :bytes) (string-bytes escaped)))
      (when (cdr result)
        (setf (plist-get state :cut) 'value)))))

(defun pilish--argument--emit-scalar (state value top-p)
  "Append bounded display text for scalar VALUE to render STATE.
TOP-P preserves real newlines in strings; missing, null, false, true,
zero and the empty string keep distinct literal forms."
  (cond
   ((stringp value)
    (if (string-empty-p value)
        (pilish--argument--emit state "\"\"")
      (pilish--argument--emit-escaped state value top-p)))
   ((pilish--json-null-p value) (pilish--argument--emit state "null"))
   ((pilish--json-false-p value) (pilish--argument--emit state "false"))
   ((eq value t) (pilish--argument--emit state "true"))
   ((null value) (pilish--argument--emit state "null"))
   ((numberp value)
    (if (and (integerp value)
             (or (>= value pilish--argument-number-bound)
                 (<= value (- pilish--argument-number-bound))))
        (progn
          (pilish--argument--emit state "#<integer exceeds display limit>")
          (setf (plist-get state :cut) 'value))
      (pilish--argument--emit state (number-to-string value))))
   (t
    (pilish--argument--emit state "#<unavailable>")
    (setf (plist-get state :cut) 'malformed))))

(defun pilish--argument--visiting-p (state)
  "Return non-nil when STATE permits another bounded structural visit.
Recognized edits finish schema checks after display clipping, without
reading any further string content.  Node and key exhaustion still stop."
  (or (not (plist-get state :cut))
      (and (plist-get state :edit-schema) (plist-get state :edits-pure)
           (memq (plist-get state :cut) '(value bytes)))))

(defun pilish--argument--admit-value-p (state)
  "Admit one more value under STATE's shared node budget, or stop."
  (cond
   ((not (pilish--argument--visiting-p state)) nil)
   ((>= (plist-get state :nodes) (plist-get state :node-limit))
    (setf (plist-get state :cut) 'nodes)
    nil)
   (t t)))

(defun pilish--argument--admit-key-p (state rest seen)
  "Admit the next plist pair REST under STATE, rejecting repeats in SEEN."
  (cond
   ((or (not (consp rest)) (not (keywordp (car rest)))
        (not (consp (cdr rest))))
    (setf (plist-get state :cut) 'malformed)
    nil)
   ((gethash rest seen)
    (setf (plist-get state :cut) 'cycle)
    nil)
   ((>= (plist-get state :keys) (plist-get state :key-limit))
    (setf (plist-get state :cut) 'budget)
    nil)
   ((pilish--argument--admit-value-p state)
    (puthash rest t seen)
    (cl-incf (plist-get state :keys))
    t)))

(defun pilish--argument--emit-key (state key)
  "Append KEY's bounded display name under STATE's remaining quotas.
Reserve an ellipsis inside those quotas when the spelling is clipped.
If even that marker cannot fit, stop with the ordinary budget omission."
  (unless (plist-get state :cut)
    (let* ((char-limit (min pilish--argument-limit-key-chars
                            (max 0 (- (plist-get state :char-limit) (plist-get state :chars)))))
           (byte-limit (min pilish--argument-limit-key-chars
                            (max 0 (- (plist-get state :byte-limit) (plist-get state :bytes)))))
           (result (pilish--argument-escape-bounded (symbol-name key) nil char-limit byte-limit 1))
           (text (car result)))
      (when (cdr result)
        (setf (plist-get state :key-cut) t)
        (setq text
              (if (and (> char-limit 0) (>= byte-limit 3))
                  (concat (car (pilish--argument-escape-bounded
                                (symbol-name key) nil (1- char-limit) (- byte-limit 3) 1)) "…")
                (setf (plist-get state :cut) 'budget)
                nil)))
      (when text (pilish--argument--emit state text))
      text)))

(defun pilish--argument--emit-value (state value depth top-p)
  "Visit admitted VALUE at container DEPTH using shared capture STATE.
TOP-P preserves direct string newlines.  All container loops stop on
quota exhaustion, including malformed or cyclic plist tails."
  (cl-incf (plist-get state :nodes))
  (when (and (plist-get state :edit-schema) (= depth 2) (not (consp value)))
    (setf (plist-get state :edits-pure) nil))
  (cond
   ((or (vectorp value) (consp value))
    (let ((array-p (vectorp value)))
      (if (>= depth pilish--argument-limit-depth)
          (progn
            (pilish--argument--emit state (if array-p "[…]" "{…}"))
            (setf (plist-get state :edits-pure) nil))
        (pilish--argument--emit state (if array-p "[" "{"))
        (let ((index 0) (rest value) (seen (make-hash-table :test 'eq)))
          (while (and (pilish--argument--visiting-p state)
                      (if array-p (< index (length value)) rest))
            (if (not (if array-p (pilish--argument--admit-value-p state)
                       (pilish--argument--admit-key-p state rest seen)))
                nil
              (when (> index 0) (pilish--argument--emit state ", "))
              (unless array-p
                (when (and (plist-get state :edit-schema) (= depth 2)
                           (not (memq (car rest) '(:oldText :newText))))
                  (setf (plist-get state :edits-pure) nil))
                (pilish--argument--emit-key state (car rest))
                (pilish--argument--emit state "="))
              (when (pilish--argument--visiting-p state)
                (pilish--argument--emit-value
                 state (if array-p (aref value index) (cadr rest)) (1+ depth) nil))
              (cl-incf index)
              (unless array-p (setq rest (cddr rest)))))
          (unless (plist-get state :cut)
            (pilish--argument--emit state (if array-p "]" "}")))))))
   (t (pilish--argument--emit-scalar state value top-p))))

(defun pilish--argument-value-text (value &optional state)
  "Return bounded (TEXT . CUT) for VALUE under optional shared STATE.
Strings keep real newlines.  Containers consume the same key, node,
character and byte budgets as all preceding rows.  No raw values escape."
  (let* ((state (or state (list :chars 0 :bytes 0 :nodes 0 :keys 0
                                :node-limit pilish--argument-limit-nodes
                                :key-limit pilish--argument-limit-block-entries)))
         (chars (plist-get state :chars))
         (bytes (plist-get state :bytes)))
    (setf (plist-get state :parts) nil
          (plist-get state :cut) nil
          (plist-get state :char-limit)
          (min (+ chars pilish--argument-limit-value-chars)
               (or (plist-get state :block-chars) most-positive-fixnum))
          (plist-get state :byte-limit)
          (min (+ bytes pilish--argument-limit-value-bytes)
               (or (plist-get state :block-bytes) most-positive-fixnum)))
    (when (pilish--argument--admit-value-p state)
      (pilish--argument--emit-value state value 1 t))
    (let ((text (apply #'concat (nreverse (plist-get state :parts))))
          (cut (plist-get state :cut)))
      (when cut
        (cl-incf (plist-get state :chars))
        (cl-incf (plist-get state :bytes) 3))
      (cons (if cut (concat text "…") text) cut))))


(defun pilish--argument-charge-empty ()
  "Return a zero node charge for the block ledger."
  (list :chars 0 :bytes 0 :nodes 0 :keys 0))

(defun pilish--argument--view-apply (view charge sign)
  "Add CHARGE to VIEW's aggregate counters when SIGN is 1, else subtract."
  (setf (pilish--argument-view-chars view)
        (+ (pilish--argument-view-chars view) (* sign (plist-get charge :chars)))
        (pilish--argument-view-bytes view)
        (+ (pilish--argument-view-bytes view) (* sign (plist-get charge :bytes)))
        (pilish--argument-view-nodes view)
        (+ (pilish--argument-view-nodes view) (* sign (plist-get charge :nodes)))
        (pilish--argument-view-keys view)
        (+ (pilish--argument-view-keys view) (* sign (plist-get charge :keys)))))

(defun pilish--argument--walk (tool-name args view root-p)
  "Capture TOOL-NAME's ARGS under VIEW's remaining shared quotas.
Return (ROWS . CHARGE), including actual visited nodes and object keys.
ROOT-P selects root-only script settlement.  Prefix inspection never
validates or copies the unvisited tail."
  (let* ((state (pilish--argument-charge-empty))
         (remaining-chars (- pilish--argument-limit-block-chars
                             (pilish--argument-view-chars view)))
         (remaining-bytes (- pilish--argument-limit-block-bytes
                             (pilish--argument-view-bytes view)))
         (object-p (and (consp args) (keywordp (car args))))
         (rest args)
         (seen (make-hash-table :test 'eq))
         (ordinal 0)
         rows stop-reason)
    (setf (plist-get state :key-cut) nil
          (plist-get state :node-limit)
          (- pilish--argument-limit-nodes (pilish--argument-view-nodes view))
          (plist-get state :key-limit)
          (- pilish--argument-limit-block-entries (pilish--argument-view-keys view))
          (plist-get state :block-chars) (max 0 (1- remaining-chars))
          (plist-get state :block-bytes) (max 0 (- remaining-bytes 3)))
    (while (and rest (not stop-reason))
      (setf (plist-get state :cut) nil
            (plist-get state :parts) nil
            (plist-get state :char-limit) (plist-get state :block-chars)
            (plist-get state :byte-limit) (plist-get state :block-bytes))
      (cond
       ((>= ordinal pilish--argument-limit-call-entries) (setq stop-reason 'entries))
       ((or (>= (plist-get state :chars) (plist-get state :block-chars))
            (>= (plist-get state :bytes) (plist-get state :block-bytes)))
        (setq stop-reason 'budget))
       ((not (if object-p (pilish--argument--admit-key-p state rest seen)
               (pilish--argument--admit-value-p state)))
        (setq stop-reason (plist-get state :cut)))
       (t
        (let* ((key (and object-p (car rest)))
               (value (if object-p (cadr rest) rest))
               (key-text (and key (pilish--argument--emit-key state key)))
               (edit-schema (and (equal tool-name "edit") (eq key :edits)))
               (rendered
                (unless (plist-get state :cut)
                  (setf (plist-get state :edit-schema) edit-schema
                        (plist-get state :edits-pure) (and edit-schema (vectorp value)))
                  (pilish--argument-value-text value state))))
          (if (null rendered)
              (setq stop-reason (plist-get state :cut))
            (push (pilish--make-argument-row
                   :ordinal ordinal :key key-text :raw-key key
                   :role (pilish--argument-classify
                          tool-name key root-p
                          (and (plist-get state :edits-pure)
                               (memq (cdr rendered) '(nil value bytes))))
                   :text (car rendered) :cut (cdr rendered)) rows)
            (cl-incf ordinal)
            (setq rest (and object-p (cddr rest))))))))
    (let* ((policy (pilish--argument-policy tool-name))
           (primary (and (plist-get policy :primary-key)
                         (cl-find (plist-get policy :primary-key) rows
                                  :key #'pilish--argument-row-raw-key)))
           (alias (and (not stop-reason)
                       (plist-get policy :primary-alias)
                       (cl-find (plist-get policy :primary-alias) rows
                                :key #'pilish--argument-row-raw-key))))
      (when (or primary alias)
        (setf (pilish--argument-row-role (or primary alias)) 'primary)))
    (when stop-reason
      (push (pilish--make-argument-row
             :ordinal most-positive-fixnum :role 'omission :text "…" :cut stop-reason)
            rows))
    (when (or stop-reason (plist-get state :key-cut) (cl-some #'pilish--argument-row-cut rows))
      (setf (pilish--argument-view-truncated-p view) t))
    (cons (nreverse rows)
          (list :chars (plist-get state :chars) :bytes (plist-get state :bytes)
                :nodes (plist-get state :nodes) :keys (plist-get state :keys)))))

(defun pilish--argument-observe (block node tool-name args)
  "Capture bounded argument rows for TOOL-NAME's ARGS into BLOCK's ledger.
NODE is nil for the root call or an existing nested-call record.  A
replacement observation releases the node's previous allocation before
capturing, so repeated observation stays idempotent.  Raw ARGS are
visited under the block limits and never retained by this projection."
  (let ((view (or (pilish--tool-block-argument-view block)
                  (setf (pilish--tool-block-argument-view block)
                        (pilish--make-argument-view)))))
    (when-let* ((old-charge (if node
                                (pilish--nested-call-argument-charge node)
                              (pilish--argument-view-root-charge view))))
      (pilish--argument--view-apply view old-charge -1))
    (pcase-let ((`(,rows . ,charge)
                 (pilish--argument--walk tool-name args view (null node))))
      (pilish--argument--view-apply view charge 1)
      (if node
          (setf (pilish--nested-call-argument-rows node) rows
                (pilish--nested-call-argument-charge node) charge)
        (setf (pilish--argument-view-root-rows view) rows
              (pilish--argument-view-root-charge view) charge))
      rows)))


(defun pilish--argument-usable-diff-p (details)
  "Return non-nil when DETAILS carry a renderer-usable diff.
A usable diff is a nonblank string containing at least one numbered
added or removed row matching `pilish--apply-diff-overlays'.  Context
omissions and literal ellipses inside the diff are data, not flags."
  (let ((diff (pilish--tool-arg-get details :diff)))
    (and (stringp diff)
         (not (string-blank-p diff))
         (string-match-p "^\\([+-]\\) *[0-9]+" diff))))

(defun pilish--argument-represented-p (tool-name key outcome)
  "Return non-nil when TOOL-NAME's settlement KEY is represented.
OUTCOME supplies :result-present-p, :is-error, :details and
:script-present-p.  Capture clipping and output folding do not imply
input loss.  Bash's details.truncation describes output, not write or
edit input, so it is not an input-completeness signal."
  (let ((result-present-p (plist-get outcome :result-present-p))
        (is-error (plist-get outcome :is-error))
        (details (plist-get outcome :details)))
    (pcase tool-name
      ("write"
       (and (eq key :content)
            result-present-p
            (not is-error)))
      ("edit"
       (and (memq key '(:edits :oldText :newText))
            result-present-p
            (not is-error)
            (pilish--argument-usable-diff-p details)))
      ("codemode"
       (and (eq key :code) (plist-get outcome :script-present-p)))
      (_ nil))))

(defun pilish--argument-settle (block node tool-name outcome)
  "Reconcile BLOCK's settlement rows for TOOL-NAME at NODE against OUTCOME.
NODE is nil for the root call or a nested-call record.  Actual results
can refine `input-needed' or `input-represented'; missing-result fallback
only settles pending rows.  Repeated identical evidence is idempotent.
Return non-nil when any row's visibility changed."
  (when (and (null node) (pilish--tool-block-compound-p block)
             (pilish--tool-block-overlay block))
    (setq outcome (plist-put (copy-sequence outcome) :script-present-p
                             (and (pilish--compound-tool-code block) t))))
  (let ((rows (if node
                  (pilish--nested-call-argument-rows node)
                (when-let* ((view (pilish--tool-block-argument-view block)))
                  (pilish--argument-view-root-rows view))))
        (changed nil))
    (dolist (row rows)
      (let ((role (pilish--argument-row-role row)))
        (when (or (eq role 'settlement)
                  (and (plist-get outcome :result-present-p)
                       (memq role '(input-needed input-represented))))
          (let ((new-role (if (pilish--argument-represented-p
                              tool-name (pilish--argument-row-raw-key row) outcome)
                             'input-represented 'input-needed)))
            (setf (pilish--argument-row-role row) new-role)
            (unless (eq (eq role 'input-needed) (eq new-role 'input-needed))
              (setq changed t))))))
    changed))


(defun pilish--argument-row-visible-p (row)
  "Return non-nil when ROW's role make it visible."
  (memq (pilish--argument-row-role row) '(ordinary input-needed omission)))

(defun pilish--argument--first-line (text)
  "Return TEXT's first line."
  (if-let* ((newline (string-match-p "\n" text)))
      (substring text 0 newline)
    text))

(defun pilish--argument-row-expandable-p (row affix-width width)
  "Return non-nil when ROW cannot display completely within WIDTH.
AFFIX-WIDTH is the display width of the indent plus key= affix (or the
title prefix for a primary row).  Multiline values are always
expandable; the check reserves no columns for a control that a complete
row would not show."
  (let ((text (pilish--argument-row-text row)))
    (or (string-match-p "\n" text)
        (> (+ affix-width (string-width text)) width))))

(defun pilish--argument--control-props (text locator &optional inert)
  "Attach LOCATOR address and literal protection to TEXT.
With INERT, retain row identity for viewport mapping without a control."
  (add-text-properties 0 (length text)
                       (append (when locator
                                 (append (list 'pilish-argument-address locator)
                                         (unless inert (list 'pilish-argument-locator locator))))
                               (list 'pilish-argument-literal t 'pilish-no-fontify t 'rear-nonsticky t))
                       text)
  text)

(defun pilish--argument-shell-fontify (text)
  "Return bounded TEXT with shell faces from a hook-free isolated buffer.
Both `face' and `font-lock-face' spans are applied so Markdown repair
can re-assert them after tree-sitter cycles.  Runs only for expanded
Bash commands; failures fall back to the command face."
  (condition-case nil
      (with-temp-buffer
        (insert text)
        (let ((sh-shell "bash"))
          (delay-mode-hooks (sh-mode)))
        (font-lock-ensure (point-min) (point-max))
        (let ((result (propertize (buffer-string)
                                  'font-lock-face 'pilish-tool-command))
              (pos (point-min)))
          (while (< pos (point-max))
            (let ((next (or (next-single-property-change pos 'face nil (point-max))
                            (point-max)))
                  (face (get-text-property pos 'face)))
              (when face
                (put-text-property (- pos (point-min)) (- next (point-min))
                                   'font-lock-face face result)
                (put-text-property (- pos (point-min)) (- next (point-min))
                                   'face face result))
              (setq pos next)))
          result))
    (error
     (propertize (copy-sequence text) 'font-lock-face 'pilish-tool-command))))

(defun pilish--argument--value-faces (text tool-name raw-key)
  "Return TEXT with display faces for an expanded value.
TOOL-NAME and RAW-KEY select shell fontification: only a visible
expanded Bash command receives shell work; every other value uses the
command face."
  (if (and (equal tool-name "bash") (eq raw-key :command))
      (pilish--argument-shell-fontify text)
    (propertize (copy-sequence text) 'font-lock-face 'pilish-tool-command)))

(defun pilish--argument--paint-expanded (row locator prefix key-part tool-name &optional face)
  "Paint ROW under LOCATOR with display PREFIX, KEY-PART and TOOL-NAME.
FACE supplies the hot background for display-only alignment.  Hidden,
collision-safe fence lines contain literal Markdown without changing values."
  (let* ((text (pilish--argument-row-text row))
         (fence (pilish--markdown-fence-delimiter text))
         (indent (pilish--tool-prefix-spaces (string-width prefix) face))
         (value-indent (pilish--tool-prefix-spaces
                        (+ (string-width prefix) (string-width key-part)) face))
         (value (pilish--argument--value-faces
                 text tool-name (pilish--argument-row-raw-key row)))
         (guard (propertize (concat fence "\n") 'display "" 'pilish-argument-guard t)))
    (add-text-properties 0 (length value)
                         (list 'line-prefix value-indent 'wrap-prefix value-indent
                               'pilish-argument-value t) value)
    (let* ((painted (concat guard key-part value
                            (propertize (concat "\n" fence "\n")
                                        'display "" 'pilish-argument-guard t)))
           (start (length guard))
           (end (max (1+ start) (or (string-match-p "\n" painted start) (length painted)))))
      (put-text-property 0 end 'line-prefix indent painted)
      (put-text-property start end 'wrap-prefix value-indent painted)
      (pilish--argument--control-props painted locator)
      (pilish--put-disclosure 0 (length painted) t
                             #'pilish--toggle-tool-argument-at-point painted))))

(defun pilish--argument--paint-row (row locator prefix key-part width folds tool-name &optional face)
  "Paint ROW with display PREFIX and KEY-PART at WIDTH.
LOCATOR owns the fold selected by FOLDS.  TOOL-NAME selects shell faces;
FACE supplies the hot background.  Complete rows show no disclosure."
  (pcase (pilish--argument-row-role row)
    ('omission
     (pilish--argument--control-props
      (propertize "…" 'font-lock-face 'pilish-collapsed-indicator
                  'line-prefix (pilish--tool-prefix-spaces (string-width prefix) face)) nil t))
    (_
     (let* ((text (pilish--argument-row-text row))
            (key-part (or key-part
                          (concat (propertize (or (pilish--argument-row-key row) "")
                                              'font-lock-face 'pilish-tool-name) "=")))
            (affix (+ (string-width prefix) (string-width key-part)))
            (expandable (pilish--argument-row-expandable-p row affix width))
            (expanded (and expandable locator (member locator folds))))
       (if expanded
           (pilish--argument--paint-expanded row locator prefix key-part tool-name face)
         (let* ((first-line (pilish--argument--first-line text))
                (teaser (if expandable
                            (truncate-string-to-width
                             (if (equal first-line text) first-line (concat first-line "…"))
                             (max 1 (- width affix)) nil nil "…")
                          text)))
           (let* ((fence (pilish--markdown-fence-delimiter (concat key-part teaser)))
                  (painted (propertize
                            (concat (propertize (concat fence "\n") 'display "" 'pilish-argument-guard t)
                                    key-part (propertize teaser 'font-lock-face 'pilish-tool-command)
                                    (propertize (concat "\n" fence "\n") 'display "" 'pilish-argument-guard t))
                            'line-prefix (pilish--tool-prefix-spaces (string-width prefix) face)
                            'wrap-prefix (pilish--tool-prefix-spaces affix face))))
             (pilish--argument--control-props painted locator (not expandable))
             (pilish--put-disclosure 0 (length painted) nil
                                    (and expandable #'pilish--toggle-tool-argument-at-point)
                                    painted))))))))

(defun pilish--argument-inline-eligible-p (rows)
  "Return non-nil when every row of ROWS is named, complete and single-line."
  (and rows
       (cl-every (lambda (row)
                   (and (pilish--argument-row-key row)
                        (memq (pilish--argument-row-role row) '(ordinary input-needed))
                        (not (pilish--argument-row-cut row))
                        (not (string-match-p "\n" (pilish--argument-row-text row)))))
                 rows)))

(defun pilish--argument-inline-suffix (rows)
  "Return complete named ROWS as a single-line argument suffix."
  (mapconcat (lambda (row)
               (concat " " (propertize (pilish--argument-row-key row) 'font-lock-face 'pilish-tool-name)
                       "=" (propertize (pilish--argument-row-text row) 'font-lock-face 'pilish-tool-command)))
             rows ""))

(cl-defun pilish--tool-call-text
    (block node width &optional (inline-ordinals nil inline-ordinals-p))
  "Return BLOCK's ephemeral (HEADING-AND-PRIMARY . REMAINING-ROWS) paint.
NODE is nil for the root or an existing nested call.  WIDTH chooses layout
without retaining geometry.  A primary group owns one contiguous address.
With INLINE-ORDINALS, preserve those already packed secondary rows during a
local primary splice; other row addresses and actual output stay outside it."
  (let* ((view (pilish--tool-block-argument-view block))
         (rows (if node (pilish--nested-call-argument-rows node)
                 (and view (pilish--argument-view-root-rows view))))
         (tool-name (if node (pilish--nested-call-name node)
                      (overlay-get (pilish--tool-block-overlay block) 'pilish-tool-name)))
         (node-id (and node (pilish--nested-call-id node)))
         (folds (pilish--tool-block-folds block))
         (face (pilish--tool-block-face block))
         (primary (seq-find (lambda (row) (eq (pilish--argument-row-role row) 'primary)) rows))
         (rest (seq-filter #'pilish--argument-row-visible-p rows))
         (history-p (and node (or (pilish--tool-block-history-p block)
                                 (eq (pilish--nested-call-source node) 'saved))))
         (status (and node (pilish--nested-call-status node)))
         (title (concat (when node
                          (pcase status
                            ('ok "") ('running "… running ") ('error "✗ failed ")
                            ('cancelled "⊘ cancelled ")
                            ('unfinished (if history-p "? unfinished when saved " "? unfinished "))
                            (_ "? unknown ")))
                        (propertize (or (pilish--tool-display-value-string tool-name "tool") "tool")
                                    'font-lock-face 'pilish-tool-name)))
         (locator (and primary (list 'argument node-id (pilish--argument-row-ordinal primary))))
         (stacked (and primary (or inline-ordinals-p
                                   (pilish--argument-row-expandable-p primary (1+ (string-width title)) width))))
         (primary-expandable (and stacked (pilish--argument-row-expandable-p primary 2 width)))
         (packing (if inline-ordinals-p
                      (seq-filter (lambda (row) (memq (pilish--argument-row-ordinal row) inline-ordinals)) rest)
                    rest))
         (suffix (and (pilish--argument-inline-eligible-p packing)
                      (or (not primary)
                          (cl-every (lambda (row) (eq (pilish--argument-row-role row) 'ordinary)) packing))
                      (pilish--argument-inline-suffix packing)))
         remaining)
    (when (and primary (not stacked))
      (setq title (concat title " " (propertize (pilish--argument-row-text primary)
                                               'font-lock-face 'pilish-tool-command))))
    (when (and suffix (or inline-ordinals-p
                          (and (or (not primary) stacked (not (equal tool-name "bash")))
                               (<= (+ (string-width title) (string-width suffix)) width))))
      (setq title (concat title suffix) rest (seq-difference rest packing #'eq)))
    (when-let* (((and node (null rows)))
                (preview (pilish--nested-call-args-preview node))
                ((not (string-empty-p preview))))
      (setq title (concat title " " (pilish--truncate-string
                                    (pilish--tool-display-value-string preview) 80))))
    (setq title (pilish--saved-conversation-header-text
                 title (and node (pilish--nested-call-saved-labels node))))
    (pilish--argument--control-props title locator (not primary-expandable))
    (when (and (not primary)
               (seq-some (lambda (row)
                           (and (not (eq (pilish--argument-row-role row) 'omission))
                                (pilish--argument-row-expandable-p
                                 row (+ 3 (string-width (or (pilish--argument-row-key row) ""))) width))) rest))
      (pilish--argument--control-props title (list 'argument node-id :title)))
    (when stacked
      (setq title (concat title "\n" (pilish--argument--paint-row
                                      primary locator "  " "" width folds tool-name face)))
      (put-text-property 0 (length title) 'pilish-argument-address locator title))
    (when node
      (add-text-properties 0 (length title)
                           (list 'pilish-nested-summary t 'pilish-nested-call-id node-id
                                 'pilish-no-fontify t) title))
    (when rest
      (setq remaining
            (mapconcat (lambda (row)
                         (pilish--argument--paint-row
                          row (and (not (eq (pilish--argument-row-role row) 'omission))
                                   (list 'argument node-id (pilish--argument-row-ordinal row)))
                          "  " nil width folds tool-name face)) rest "\n")))
    (when (and node (memq status '(error cancelled)))
      (let ((error-text (or (pilish--nested-call-error node)
                            (pilish--extract-text-from-content
                             (plist-get (pilish--nested-call-result node) :content)))))
        (unless (string-empty-p error-text)
          (let* ((text (concat "Error: " (pilish--truncate-string
                                         (pilish--tool-display-value-string error-text) 80)))
                 (fence (pilish--markdown-fence-delimiter text))
                 (guard (propertize (concat fence "\n")
                                    'display "" 'pilish-tool-diagnostic-guard t))
                 (diagnostic (propertize
                              (concat guard text
                                      (propertize (concat "\n" fence "\n")
                                                  'display "" 'pilish-tool-diagnostic-guard t))
                              'pilish-nested-summary t 'pilish-no-fontify t)))
            (setq remaining (if remaining (concat remaining "\n" diagnostic) diagnostic))))))
    (cons title remaining)))

(defun pilish--argument-settle-pending-children (block)
  "Settle BLOCK's nested children lacking an observed execution end.
Their bounded diagnostic input stays visible; settled calls are left
untouched.  Idempotent."
  (dolist (call (pilish--tool-block-nested-calls block))
    (pilish--argument-settle block call (pilish--nested-call-name call)
                             (list :result-present-p nil
                                   :is-error nil :details nil))))

(defun pilish--argument-header-text (block tool-name &optional args preview-state)
  "Return BLOCK's header text for TOOL-NAME from its argument projection.
When no projection exists, fall back to `pilish--tool-header' with ARGS
and PREVIEW-STATE.  Width is chosen at paint time: the snapshot override
first, then the selected chat window, then the usual fallback."
  (if (null (pilish--tool-block-argument-view block))
      (pilish--tool-header tool-name args preview-state)
    (let ((rendered (pilish--tool-call-text block nil (max 24 (pilish--chat-display-width)))))
      (if (cdr rendered) (concat (car rendered) "\n" (cdr rendered)) (car rendered)))))


(defun pilish--argument--resolve-locator (block locator)
  "Resolve LOCATOR against BLOCK's view to a concrete fold key, or nil.
The `:title' sentinel targets the addressed call's first expandable row;
ordinary locators resolve to themselves."
  (pcase-let ((`(argument ,node-id ,ordinal) locator))
    (if (not (eq ordinal :title))
        locator
      (when-let* ((view (pilish--tool-block-argument-view block))
                  (rows (if node-id
                            (pilish--nested-call-argument-rows (pilish--nested-call-get block node-id))
                          (pilish--argument-view-root-rows view)))
                  (width (max 24 (pilish--chat-display-width)))
                  (target
                   (seq-find (lambda (row)
                               (and (pilish--argument-row-visible-p row)
                                    (not (eq (pilish--argument-row-role row) 'omission))
                                    (pilish--argument-row-expandable-p
                                     row (+ 3 (string-width (or (pilish--argument-row-key row) ""))) width)))
                             rows)))
        (list 'argument node-id (pilish--argument-row-ordinal target))))))

(defun pilish--argument--find-locator-position (locator start end)
  "Return the first position in START..END carrying LOCATOR, or START."
  (let ((pos start)
        (found nil))
    (while (and (< pos end) (not found))
      (if (and (equal (get-text-property pos 'pilish-argument-locator) locator)
               (not (get-text-property pos 'pilish-argument-guard)))
          (setq found pos)
        (setq pos (or (next-single-property-change
                       pos 'pilish-argument-locator nil end)
                      end))))
    (or found start)))

(defun pilish--argument--locator-spans (start end)
  "Return transient (LOCATOR START END) argument bounds in START..END."
  (let ((position start) spans)
    (while (< position end)
      (let ((next (min (next-single-property-change position 'pilish-argument-address nil end)
                       (next-single-property-change position 'pilish-argument-guard nil end)))
            (locator (get-text-property position 'pilish-argument-address)))
        (when (and locator (not (get-text-property position 'pilish-argument-guard)))
          (if-let* ((span (assoc locator spans)))
              (setf (nth 2 span) next)
            (push (list locator position next) spans)))
        (setq position next)))
    spans))

(defun pilish--argument--map-toggle-position
    (position start old-end new-end anchor old-spans new-spans)
  "Map POSITION through START..OLD-END to NEW-END by argument identity.
OLD-SPANS and NEW-SPANS preserve surviving row offsets.  Only removed
content clamps to ANCHOR or its surviving row's start."
  (cond
   ((< position start) position)
   ((>= position old-end) (+ position (- new-end old-end)))
   ((when-let* ((old (seq-find (lambda (span)
                                 (and (>= position (nth 1 span)) (< position (nth 2 span))))
                               old-spans))
                (new (assoc (car old) new-spans)))
      (let ((offset (- position (nth 1 old))))
        (if (< offset (- (nth 2 new) (nth 1 new)))
            (+ (nth 1 new) offset)
          (nth 1 new)))))
   (t anchor)))

(defun pilish--argument--repaint-root (block anchor-locator)
  "Repaint BLOCK's header region after an argument fold change.
ANCHOR-LOCATOR identifies the control that was toggled; every visible
window's positions map through the rewrite and clamp to the control's
new position, keeping surviving row positions when feasible."
  (let* ((ov (pilish--tool-block-overlay block))
         (start (overlay-start ov))
         (header-end (pilish--tool-block-header-end block))
         (old-end (marker-position header-end))
         (tool-name (overlay-get ov 'pilish-tool-name))
         (old-spans (pilish--argument--locator-spans start old-end))
         (view (pilish--capture-tool-cooling-view)))
    (dolist (window (plist-get view :windows))
      (setf (plist-get window :following) nil))
    (pilish--replace-tool-header
     block (pilish--argument-header-text block tool-name nil))
    (let* ((new-end (marker-position header-end))
           (new-spans (pilish--argument--locator-spans start new-end))
           (anchor (pilish--argument--find-locator-position
                    anchor-locator start new-end)))
      (pilish--restore-tool-cooling-view
       view start old-end new-end
       (lambda (position)
         (pilish--argument--map-toggle-position
          position start old-end new-end anchor old-spans new-spans))))))

(defun pilish--argument--repaint-child (block locator)
  "Splice only BLOCK's child argument span owned by LOCATOR.
The existing row painter and canonical primary summary compose new text.
Output, diff overlays and markers outside this address span stay in place."
  (pcase-let* ((`(argument ,node-id ,ordinal) locator)
               (call (pilish--nested-call-get block node-id))
               (row (cl-find ordinal (pilish--nested-call-argument-rows call)
                             :key #'pilish--argument-row-ordinal))
               (overlay (pilish--tool-block-overlay block))
               (position (marker-position (pilish--tool-block-header-end block)))
               (end (overlay-end overlay)))
    (while (and (< position end)
                (not (equal locator (get-text-property position 'pilish-argument-address))))
      (setq position (next-single-property-change position 'pilish-argument-address nil end)))
    (when (< position end)
      (let* ((start position)
             (old-end (next-single-property-change start 'pilish-argument-address nil end))
             (old-spans (pilish--argument--locator-spans start old-end))
             (view (pilish--capture-tool-cooling-view))
             (width (max 24 (pilish--chat-display-width)))
             (folds (pilish--tool-block-folds block))
             (text (if (eq (pilish--argument-row-role row) 'primary)
                       (car (pilish--tool-call-text
                             block call width
                             (let ((spans (pilish--argument--locator-spans
                                           (marker-position (pilish--tool-block-header-end block)) end)))
                               (cl-loop for secondary in (pilish--nested-call-argument-rows call)
                                        for index = (pilish--argument-row-ordinal secondary)
                                        when (and (eq (pilish--argument-row-role secondary) 'ordinary)
                                                  (not (assoc (list 'argument node-id index) spans)))
                                        collect index))))
                     (pilish--argument--paint-row
                      row locator "  " nil width folds (pilish--nested-call-name call)
                      (pilish--tool-block-face block))))
             (new-end (+ start (length text)))
             (inhibit-read-only t))
        (dolist (window (plist-get view :windows))
          (setf (plist-get window :following) nil))
        (save-excursion
          (delete-region start old-end)
          (goto-char start)
          (insert (propertize text 'pilish-tool-section (cons 'child node-id)
                              'pilish-nested-root-id (pilish--tool-block-tool-call-id block)))
          (pilish--tool-block-refresh-overlay block)
          (pilish--font-lock-ensure-excluding-property start new-end 'pilish-no-fontify))
        (let ((new-spans (pilish--argument--locator-spans start new-end))
              (anchor (pilish--argument--find-locator-position locator start new-end)))
          (pilish--restore-tool-cooling-view
           view start old-end new-end
           (lambda (point)
             (pilish--argument--map-toggle-position
              point start old-end new-end anchor old-spans new-spans))))))))

(defun pilish--argument-toggle (block locator)
  "Flip BLOCK's argument fold for LOCATOR and repaint only its region.
Root rows repaint the header; child rows splice their owned address span.
Return non-nil when toggled."
  (when-let* ((fold-key (pilish--argument--resolve-locator block locator)))
    (let ((folds (pilish--tool-block-folds block)))
      (setf (pilish--tool-block-folds block)
            (if (member fold-key folds)
                (remove fold-key folds)
              (cons fold-key folds))))
    (pcase-let ((`(argument ,node-id ,_ordinal) fold-key))
      (if node-id
          (pilish--argument--repaint-child block fold-key)
        (pilish--argument--repaint-root block locator)))
    t))

(defun pilish--toggle-tool-argument-at-point ()
  "Toggle the argument control at point, or return nil.
Explicit `pilish-argument-locator' properties are the only control
authority; actions never derive from display strings."
  (when-let* ((locator (get-text-property (point) 'pilish-argument-locator))
              (overlay (pilish--tool-overlay-at-point))
              (block (pilish--tool-block-from-overlay overlay))
              ((pilish--tool-block-argument-view block)))
    (pilish--argument-toggle block locator)))


(defun pilish--argument-release-cold (block)
  "Release BLOCK's tool decoration, argument controls and retained projection.
Alignment, visible characters and hidden literal guards survive.  The
idempotent release precedes cold capture, including for output-only blocks."
  (when-let* ((overlay (and block (pilish--tool-block-overlay block)))
              ((overlay-buffer overlay)))
    (pilish--put-disclosure (overlay-start overlay) (overlay-end overlay) nil nil)
    (pilish--tool-refresh-prefixes block t))
  (when-let* ((block block)
              ((pilish--tool-block-argument-view block))
              (ov (pilish--tool-block-overlay block))
              ((overlay-buffer ov)))
    (with-silent-modifications
      (remove-text-properties
       (overlay-start ov) (overlay-end ov)
       '(pilish-argument-locator nil pilish-argument-address nil)))
    (dolist (call (pilish--tool-block-nested-calls block))
      (setf (pilish--nested-call-argument-rows call) nil
            (pilish--nested-call-argument-charge call) nil))
    (setf (pilish--tool-block-argument-view block) nil
          (pilish--tool-block-folds block)
          (seq-remove (lambda (fold)
                        (and (consp fold) (eq (car fold) 'argument)))
                      (pilish--tool-block-folds block)))))

(defun pilish--tool-block-execution-backed-p (block)
  "Return non-nil when BLOCK represents execution rather than a pure preview."
  (and block
       (or (pilish--tool-block-execution-start block)
           (and (pilish--tool-block-compound-p block)
                (or (pilish--tool-block-result block)
                    (pilish--tool-block-nested-calls block))))))

(defun pilish--ensure-live-tool-blocks ()
  "Return the live tool block registry for the current buffer."
  (or pilish--live-tool-blocks
      (setq pilish--live-tool-blocks
            (make-hash-table :test 'equal))))

(defun pilish--next-tool-block-order ()
  "Return the next monotonically increasing live tool block order."
  (let ((order (or pilish--tool-block-order-counter 0)))
    (setq pilish--tool-block-order-counter (1+ order))
    order))

(defun pilish--reserve-tool-block-order (&optional order)
  "Return ORDER, or allocate the next implicit live tool block order.
When ORDER is non-nil, advance the monotonic counter past it so later
implicit insertions still sort after explicitly ordered preview blocks."
  (if order
      (progn
        (setq pilish--tool-block-order-counter
              (max (or pilish--tool-block-order-counter 0)
                   (1+ order)))
        order)
    (pilish--next-tool-block-order)))

(defun pilish--tool-call-id-p (tool-call-id)
  "Return non-nil when TOOL-CALL-ID is usable for event correlation."
  (and (stringp tool-call-id) (not (string-empty-p tool-call-id))))

(defun pilish--tool-block-get (tool-call-id)
  "Return the live tool block for TOOL-CALL-ID, or nil."
  (when (and (pilish--tool-call-id-p tool-call-id)
             pilish--live-tool-blocks)
    (gethash tool-call-id pilish--live-tool-blocks)))

(defun pilish--live-tool-blocks-in-order ()
  "Return all keyed and generation-owned tool blocks in display order."
  (let (blocks)
    (when pilish--live-tool-blocks
      (maphash
       (lambda (_tool-call-id block)
         (when (overlay-buffer (pilish--tool-block-overlay block))
           (push block blocks)))
       pilish--live-tool-blocks))
    (when pilish--toolcall-streams
      (maphash
       (lambda (_content-index stream)
         (when-let* ((block (pilish--tool-stream-block stream))
                     (overlay (pilish--tool-block-overlay block))
                     ((overlay-buffer overlay)))
           (unless (memq block blocks)
             (push block blocks))))
       pilish--toolcall-streams))
    (sort blocks
          (lambda (left right)
            (< (pilish--tool-block-order left)
               (pilish--tool-block-order right))))))

(defun pilish--tool-block-next-after-order (order)
  "Return the first live tool block whose order is greater than ORDER."
  (seq-find (lambda (block)
              (> (pilish--tool-block-order block) order))
            (pilish--live-tool-blocks-in-order)))

(defun pilish--tool-block-register (block)
  "Register BLOCK when it has a nonempty authoritative tool call ID."
  (when-let* ((tool-call-id (pilish--tool-block-tool-call-id block))
              ((pilish--tool-call-id-p tool-call-id)))
    (puthash tool-call-id block (pilish--ensure-live-tool-blocks)))
  block)

(defun pilish--tool-block-unregister (block)
  "Remove BLOCK from the keyed live registry."
  (when-let* ((tool-call-id (pilish--tool-block-tool-call-id block))
              (live-blocks pilish--live-tool-blocks))
    (when (eq (gethash tool-call-id live-blocks) block)
      (remhash tool-call-id live-blocks)))
  block)

(defun pilish--tool-block-from-overlay (overlay)
  "Return the tool block record attached to OVERLAY, or nil."
  (and overlay (overlay-get overlay 'pilish-tool-block-record)))

(defun pilish--current-tool-block ()
  "Return the compatibility current tool block, or nil.
This is only used by legacy single-tool rendering paths that still rely
on `pilish--pending-tool-overlay'."
  (pilish--tool-block-from-overlay pilish--pending-tool-overlay))

(defun pilish--all-live-tool-blocks ()
  "Return all distinct live tool blocks in the current buffer.
Includes keyed blocks from `pilish--live-tool-blocks' and, when
needed for compatibility, the current non-keyed pending block."
  (let ((blocks (pilish--live-tool-blocks-in-order))
        (current (pilish--current-tool-block)))
    (if (and current (not (memq current blocks)))
        (append blocks (list current))
      blocks)))

(defun pilish--finalize-live-tool-blocks (face)
  "Finalize every currently live tool block with FACE."
  (dolist (block (pilish--all-live-tool-blocks))
    (pilish--tool-block-finalize block face)))

(defun pilish--tool-block-overlays-in-region (start end)
  "Return tool block overlays overlapping START..END in buffer order."
  (sort (seq-filter (lambda (ov)
                      (overlay-get ov 'pilish-tool-block))
                    (overlays-in start end))
        (lambda (left right)
          (< (overlay-start left) (overlay-start right)))))

(defun pilish--tool-block-refresh-overlay (block)
  "Sync BLOCK metadata and bounds onto its overlay."
  (when-let* ((ov (pilish--tool-block-overlay block))
              (end-marker (pilish--tool-block-end-marker block)))
    (move-overlay ov (overlay-start ov) (marker-position end-marker))
    (overlay-put ov 'pilish-tool-block-record block)
    (overlay-put ov 'pilish-header-end
                 (pilish--tool-block-header-end block))
    (overlay-put ov 'pilish-tool-path
                 (pilish--tool-block-path block))
    (overlay-put ov 'pilish-tool-raw-path
                 (pilish--tool-block-raw-path block))
    (overlay-put ov 'pilish-tool-path-error
                 (pilish--tool-block-path-error block))
    (overlay-put ov 'pilish-tool-offset
                 (pilish--tool-block-offset block))
    (overlay-put ov 'pilish-line-map
                 (pilish--tool-block-line-map block))
    (overlay-put ov 'pilish-last-tail
                 (pilish--tool-block-last-tail block))
    (when (pilish--tool-block-details block)
      (pilish--tool-block-apply-details block)))
  block)

(defun pilish--tool-block-set-execution-start (block time args)
  "Store execution-start TIME and authoritative ARGS on BLOCK, not its preview."
  (setf (pilish--tool-block-execution-start block) time
        (pilish--tool-block-args block) args))

(defun pilish--tool-block-apply-details (block)
  "Project BLOCK's completed details onto its current owned text."
  (when-let* ((details (pilish--tool-block-details block))
              (ov (pilish--tool-block-overlay block))
              (start (overlay-start ov)))
    (pilish--set-details start (overlay-end ov) details)))

(defun pilish--tool-emacs-path (path)
  "Return Pi tool PATH normalized for Emacs in the current chat session."
  (pilish--emacs-path
   path
   (pilish--chat-session-directory)))

(defun pilish--tool-arg-get (args prop)
  "Return PROP from ARGS without signaling during passive rendering."
  (when (listp args)
    (condition-case nil
        (plist-get args prop)
      (error nil))))

(defun pilish--tool-arg-member (args prop)
  "Return non-nil when PROP is present in ARGS, without signaling."
  (when (listp args)
    (condition-case nil
        (plist-member args prop)
      (error nil))))

(defun pilish--tool-arg-path (args)
  "Extract path metadata from ARGS without signaling."
  (or (pilish--tool-arg-get args :path)
      (pilish--tool-arg-get args :file_path)))

(defun pilish--tool-path-string (path)
  "Return PATH when it is a nonempty NUL-free string, otherwise nil."
  (and (stringp path)
       (not (string-empty-p path))
       (not (pilish--path-string-contains-nul-p path))
       path))

(defun pilish--render-safe-string (value &optional nil-value)
  "Return VALUE as a string safe for render string APIs.
Nil becomes NIL-VALUE, or the empty string when NIL-VALUE is nil.
This helper does not escape display controls; callers that render metadata in
headers should also use `pilish--escape-control-chars-for-display'."
  (cond
   ((stringp value) value)
   ((null value) (or nil-value ""))
   (t
    (condition-case nil
        (format "%s" value)
      (error "#<unprintable>")))))

(defun pilish--content-block-list (content)
  "Return CONTENT as a list of plist blocks, or nil when malformed."
  (cond
   ((vectorp content)
    (cl-remove-if-not #'consp (append content nil)))
   ((and (listp content)
         (or (null content) (consp (car content))))
    (cl-remove-if-not #'consp content))
   (t nil)))

(defun pilish--unicode-escape-char (char)
  "Return a display escape for Unicode CHAR."
  (if (<= char #xffff)
      (format "\\u%04X" char)
    (format "\\U%08X" char)))

(defun pilish--escape-control-chars-for-display (text &optional preserve-newlines)
  "Return TEXT with control and format chars escaped for safe display.
When PRESERVE-NEWLINES is non-nil, leave newline separators untouched.
This helper is display-only; callers must keep raw metadata separately."
  (when (stringp text)
    (mapconcat
     (lambda (char)
       (let ((category (get-char-code-property char 'general-category)))
         (cond
          ((eq char ?\n) (if preserve-newlines "\n" "\\n"))
          ((eq char ?\r) "\\r")
          ((eq char ?\t) "\\t")
          ((or (< char 32) (= char #x7f))
           (format "\\x%02X" char))
          ((or (eq category 'Cc)
               (eq category 'Cf))
           (pilish--unicode-escape-char char))
          (t (char-to-string char)))))
     text
     "")))

(defun pilish--tool-display-value-string (value &optional placeholder)
  "Return VALUE escaped for one-line tool header display.
Nil becomes PLACEHOLDER.  Non-string values are stringified first so malformed
backend metadata cannot make passive rendering signal."
  (cond
   ((stringp value)
    (pilish--escape-control-chars-for-display value))
   ((null value) placeholder)
   (t
    (pilish--escape-control-chars-for-display
     (pilish--render-safe-string value)))))

(defun pilish--tool-display-path-string (path)
  "Return PATH escaped for one-line tool header display, or nil.
NUL-containing and non-string paths remain absent, so malformed path metadata
renders with the normal absent-path placeholder."
  (when-let* ((path (pilish--tool-path-string path)))
    (pilish--escape-control-chars-for-display path)))

;;;; Completed block details

(defun pilish--details-title (title message)
  "Return TITLE with MESSAGE's saved timestamp when available."
  (if-let* ((timestamp (plist-get message :timestamp))
            ((numberp timestamp)))
      (format "%s · %s" title
              (pilish--format-message-timestamp (pilish--ms-to-time timestamp)))
    title))

(defun pilish--details-provenance (message)
  "Return MESSAGE's provider/model line, without consulting session state."
  (string-join
   (delq nil (mapcar (lambda (key)
                     (pilish--escape-control-chars-for-display
                      (pilish--normalize-string-or-null (plist-get message key))))
                    '(:provider :model)))
   " / "))

(defun pilish--format-reply-details (message &optional duration)
  "Return literal metadata for final MESSAGE and qualified live DURATION."
  (let ((lines (list (pilish--details-title "Reply" message)))
        (provenance (pilish--details-provenance message))
        (usage (plist-get message :usage)))
    (unless (string-empty-p provenance) (push provenance lines))
    (dolist (group '(("Message tokens: " (:input . "input") (:output . "output"))
                     ("Cache: " (:cacheRead . "read") (:cacheWrite . "write"))))
      (let (fields)
        (dolist (field (cdr group))
          (when-let* ((value (plist-get usage (car field)))
                      ((numberp value)))
            (push (format "%s %s" (cdr field) (pilish--format-number value)) fields)))
        (when fields
          (push (concat (car group) (string-join (nreverse fields) " · ")) lines))))
    (when (and (numberp duration) (> duration 0))
      (push (concat (format "Stream: %.1f s" duration)
                    (when-let* ((output (plist-get usage :output))
                                ((numberp output)))
                      (format " · ~%.0f output tokens/s" (/ (float output) duration))))
            lines))
    (substring-no-properties (string-join (nreverse lines) "\n"))))

(defun pilish--format-thinking-details (message normalized)
  "Return literal thinking details for MESSAGE and NORMALIZED, without an excerpt."
  (let ((provenance (pilish--details-provenance message)))
    (substring-no-properties
     (concat (pilish--details-title "Thinking" message)
             " · " (pilish--thinking-line-count-label
                      (length (split-string normalized "\n" nil)))
             (unless (string-empty-p provenance) (concat "\n" provenance))))))

(defun pilish--format-tool-details (tool-name args &optional result duration)
  "Return literal details for TOOL-NAME, ARGS, saved RESULT and live DURATION."
  (let* ((title (if (member tool-name '("bash" "read" "write" "edit"))
                    (capitalize tool-name)
                  (pilish--tool-display-value-string tool-name "Tool")))
         (hint (pcase tool-name
                 ("bash" (pilish--tool-arg-get args :command))
                 ((or "read" "write" "edit") (pilish--tool-arg-path args)))))
    (when (and (stringp hint) (equal tool-name "read"))
      (let (range)
        (dolist (field '(:offset :limit))
          (when-let* ((value (pilish--tool-arg-get args field))
                      ((numberp value)))
            (push (format "%s %s" (substring (symbol-name field) 1) value) range)))
        (when range (setq hint (format "%s (%s)" hint (string-join (nreverse range) ", "))))))
    (substring-no-properties
     (concat (pilish--details-title title result)
             (when (and (stringp hint) (not (string-blank-p hint)))
               (concat "\n" (pilish--truncate-string
                              (pilish--escape-control-chars-for-display
                               (string-trim (replace-regexp-in-string "[ \t\n\r\f]+" " " hint)))
                              80)))
             (when (and (numberp duration) (> duration 0))
               (format "\nExecution time: %.1f s" duration))))))

(defun pilish--fontify-and-restore-tool-properties (function start end &rest args)
  "Call FUNCTION with START, END and ARGS, then repair tool properties.
Use the actual fontified bounds and return FUNCTION's result unchanged."
  (let ((result (apply function start end args)))
    (save-restriction
      (widen)
      (pcase result
        (`(jit-lock-bounds ,beg . ,limit)
         (pilish--restore-tool-properties beg limit))
        (_ (pilish--restore-tool-properties start end))))
    result))

(defun pilish--set-details (start end details &optional object)
  "Silently attach literal DETAILS to START..END of OBJECT or this buffer."
  (let ((inhibit-read-only t))
    (with-silent-modifications
      (add-text-properties start end
                           `(pilish-details ,details rear-nonsticky t) object))))

(defun pilish--details-at-point ()
  "Return completed block details at the exact accessible character, or nil."
  (when (and (derived-mode-p 'pilish-transcript-mode) (< (point) (point-max)))
    (let ((details (get-text-property (point) 'pilish-details)))
      (when (and (stringp details) (not (string-empty-p details))) details))))

(defun pilish--transcript-local-help (&optional inhibit-warning describe-button)
  "Show native local help first, then exact-point completed block details.
Pass INHIBIT-WARNING and DESCRIBE-BUTTON unchanged to native help."
  (interactive (list nil current-prefix-arg))
  (if (pilish--native-local-help-at-point-p)
      (display-local-help inhibit-warning describe-button)
    (if-let* ((details (pilish--details-at-point)))
        (message "%s" details)
      (display-local-help inhibit-warning describe-button))))

(defun pilish--show-details (details &optional interactive-p)
  "Recreate a detached DETAILS Help page.
INTERACTIVE-P is passed to standard Help history setup."
  (help-setup-xref (list #'pilish--show-details details) interactive-p)
  (let ((help-window-select t))
    (with-help-window (help-buffer)
      (insert details "\n"))))

(defun pilish-describe-reply ()
  "Describe the completed reply, thinking, or tool block at point.
Move onto completed block text in a chat or saved snapshot to open
standard Help.  Shared headings, outcome notices and unfinished blocks
have no details."
  (interactive)
  (let ((details (pilish--details-at-point)))
    (unless details
      (user-error "Move onto a completed reply, thinking, or tool block in a chat or snapshot"))
    (pilish--show-details (substring-no-properties details)
                         (called-interactively-p 'interactive))))

(defun pilish--apply-assistant-message-metadata (message &optional duration)
  "Apply final MESSAGE details and live DURATION inside its message markers."
  (when (and pilish--message-start-marker pilish--streaming-marker)
    (let* ((details (pilish--format-reply-details message duration))
           (start (marker-position pilish--message-start-marker))
           (end (marker-position pilish--streaming-marker))
           (reply-end (if (and (> end start) (eq (char-before end) ?\n))
                          (1- end)
                        end)))
      ;; Tools have their own ownership.  Work only inside this message, not
      ;; the shared Assistant heading or content indexes reused next message.
      ;; Abort/error may omit thinking_end.  Leave that active span unfinished,
      ;; without completed details, rather than assigning it reply usage.
      (dolist (range (append
                      (pilish--ranges-excluding-property
                       start (if pilish--thinking-start-marker
                                 (marker-position pilish--thinking-start-marker)
                               reply-end)
                       'pilish-thinking-block)
                      (when pilish--thinking-marker
                        (pilish--ranges-excluding-property
                         (marker-position pilish--thinking-marker) reply-end
                         'pilish-thinking-block))))
        (let ((pos (car range)))
          (dolist (ov (pilish--tool-block-overlays-in-region (car range) (cdr range)))
            (dolist (span (pilish--ranges-excluding-property
                           pos (max pos (overlay-start ov)) 'pilish-assistant-outcome))
              (pilish--set-details (car span) (cdr span) details))
            (setq pos (max pos (overlay-end ov))))
          (dolist (span (pilish--ranges-excluding-property
                         pos (cdr range) 'pilish-assistant-outcome))
            (pilish--set-details (car span) (cdr span) details))))
      (let ((pos start) (inhibit-read-only t))
        (while (< pos end)
          (let ((next (next-single-property-change pos 'pilish-thinking-block nil end)))
            (when-let* ((normalized (get-text-property pos 'pilish-thinking-normalized)))
              (pilish--set-details
               pos next (pilish--format-thinking-details message normalized)))
            (setq pos next)))))))

(defun pilish--details-elapsed (start end)
  "Return elapsed seconds for positive local START..END boundaries, or nil."
  (when (and (numberp start) (numberp end) (> end start)) (- end start)))

(defun pilish--clear-live-details-state ()
  "Clear unfinished measurements and pending result associations."
  (setq pilish--assistant-details-clock nil)
  (when pilish--live-tool-blocks
    (maphash (lambda (_id block)
               (setf (pilish--tool-block-execution-start block) nil))
             pilish--live-tool-blocks))
  (when pilish--pending-tool-details
    (clrhash pilish--pending-tool-details)))

(defun pilish--complete-tool-details (block tool-name args duration)
  "Complete BLOCK's TOOL-NAME and ARGS details with live DURATION.
Await its saved result for a timestamp."
  (setf (pilish--tool-block-details block)
        (pilish--format-tool-details tool-name args nil duration))
  (pilish--tool-block-apply-details block)
  (unless pilish--pending-tool-details
    (setq pilish--pending-tool-details
          (make-hash-table :test 'equal :weakness 'value)))
  (puthash (pilish--tool-block-tool-call-id block)
           block pilish--pending-tool-details))

(defun pilish--update-tool-details-from-result (result)
  "Attach RESULT's saved timestamp to its completed block by call ID."
  (when-let* ((pending pilish--pending-tool-details)
              (id (plist-get result :toolCallId))
              (block (gethash id pending)))
    (remhash id pending)
    (when-let* ((details (pilish--tool-block-details block)))
      (let ((split (string-match "\n" details)))
        (setf (pilish--tool-block-details block)
              (concat (pilish--details-title (substring details 0 split) result)
                      (and split (substring details split)))))
      (pilish--tool-block-apply-details block))))

(defun pilish--tool-render-path-metadata (path)
  "Return passive render metadata for backend tool PATH.
The returned plist may contain:

`:path'       normalized Emacs path safe for navigation, or nil;
`:raw-path'   original backend path string, or nil;
`:path-error' user-facing error string when PATH was present but unsafe.

Never signal for invalid backend metadata; keep strict validation inside
`pilish--tool-emacs-path' and record any failure here."
  (cond
   ((null path) nil)
   ((not (stringp path))
    (list :path-error "Tool path metadata is not a string"))
   ((string-empty-p path) nil)
   (t
    (condition-case err
        (list :path (pilish--tool-emacs-path path)
              :raw-path path)
      (error
       (list :raw-path path
             :path-error (pilish--escape-control-chars-for-display
                          (error-message-string err))))))))

(defun pilish--tool-render-path (path)
  "Return PATH normalized for passive tool rendering, or nil.
Never signal for invalid backend metadata."
  (plist-get (pilish--tool-render-path-metadata path) :path))

(defun pilish--tool-block-sync-path-metadata (block path)
  "Sync PATH-derived navigation metadata on BLOCK and its overlay.
A nil, missing, or empty PATH clears stale safe-path, raw-path, and error
metadata.  Invalid PATH values clear the safe path and store controlled raw
path/error metadata for `pilish-visit-file'."
  (when block
    (let ((metadata (pilish--tool-render-path-metadata path)))
      (setf (pilish--tool-block-path block)
            (plist-get metadata :path)
            (pilish--tool-block-raw-path block)
            (plist-get metadata :raw-path)
            (pilish--tool-block-path-error block)
            (plist-get metadata :path-error)))
    (pilish--tool-block-refresh-overlay block))
  block)

(defun pilish--tool-block-set-offset (block offset)
  "Store OFFSET metadata on BLOCK and its overlay."
  (when block
    (setf (pilish--tool-block-offset block) offset)
    (pilish--tool-block-refresh-overlay block))
  block)

(defun pilish--tool-block-set-line-map (block line-map)
  "Store LINE-MAP metadata on BLOCK and its overlay."
  (when block
    (setf (pilish--tool-block-line-map block) line-map)
    (pilish--tool-block-refresh-overlay block))
  block)

(defun pilish--tool-block-set-last-tail (block last-tail)
  "Store LAST-TAIL preview cache metadata on BLOCK and its overlay."
  (when block
    (setf (pilish--tool-block-last-tail block) last-tail)
    (pilish--tool-block-refresh-overlay block))
  block)

(defun pilish--tool-block-set-image-previews (block previews)
  "Store rendered image PREVIEWS on BLOCK for toggling and cooling."
  (when block
    (setf (pilish--tool-block-image-previews block) previews))
  block)

(defun pilish--image-type-for-mime (mime-type)
  "Return the Emacs image type for MIME-TYPE, or nil when unsupported."
  (pcase mime-type
    ((or "image/jpeg" "image/jpg") 'jpeg)
    ("image/png" 'png)
    ("image/gif" 'gif)
    ("image/webp" 'webp)
    ("image/svg+xml" 'svg)))

(defun pilish--image-preview-window ()
  "Return the window whose frame and dimensions govern image previews."
  (or (pilish--chat-display-window)
      (selected-window)))

(defun pilish--image-display-capable-p ()
  "Return non-nil when the image preview window is graphical."
  (display-images-p
   (window-frame (pilish--image-preview-window))))

(defun pilish--image-preview-pixel-limits ()
  "Return window-relative image preview size properties."
  (let* ((window (pilish--image-preview-window))
         (window-width
          (max 1 (truncate (* 0.9 (window-pixel-width window)))))
         (configured-width
          (if (natnump pilish-image-preview-max-width)
              (max 1 pilish-image-preview-max-width)
            window-width)))
    (list :max-width (min window-width configured-width)
          :max-height
          (max 1 (truncate (* 0.5 (window-pixel-height window)))))))

(defconst pilish--image-previews-per-content-limit 8
  "Maximum image blocks rendered from one message or tool result.")

(defun pilish--image-preview-byte-limit ()
  "Return the nonnegative source-byte limit for one image preview."
  (if (natnump pilish-image-preview-max-bytes)
      pilish-image-preview-max-bytes
    (* 10 1024 1024)))

(defun pilish--image-preview-safe-field (value &optional fallback)
  "Return VALUE as control-safe placeholder text, or FALLBACK when nil."
  (pilish--escape-control-chars-for-display
   (pilish--render-safe-string value fallback)))

(defun pilish--image-preview-string (fallback &optional image)
  "Return FALLBACK marked as an image preview, displaying IMAGE when non-nil."
  (apply #'propertize fallback
         (append
          (list 'face 'pilish-tool-header
                'fontified t
                'pilish-no-fontify t
                'pilish-image-preview t
                'rear-nonsticky t
                'help-echo fallback)
          (when image (list 'display image)))))

(defun pilish--image-preview-label (mime-type description)
  "Return an image placeholder for MIME-TYPE and DESCRIPTION."
  (format "Image: %s, %s"
          (pilish--image-preview-safe-field mime-type "unknown")
          description))

(defun pilish--image-too-large-description (limit)
  "Return a placeholder description for an image exceeding LIMIT bytes."
  (format "too large (limit %s)"
          (file-size-human-readable limit 'iec " " "B")))

(defun pilish--image-data-matches-type-p (data type)
  "Return non-nil when Emacs recognizes DATA as the expected image TYPE."
  (eq type (condition-case nil
               (image-type-from-data data)
             (error nil))))

(defun pilish--render-content-image-preview (block)
  "Return a rendered preview string for image content BLOCK."
  (let* ((mime-type (or (plist-get block :mimeType)
                        (plist-get block :mime-type)))
         (data (plist-get block :data))
         (type (pilish--image-type-for-mime mime-type))
         (limit (pilish--image-preview-byte-limit)))
    (cond
     ((or (null data) (and (stringp data) (string-empty-p data)))
      (pilish--image-preview-string
       (pilish--image-preview-label mime-type "empty data")))
     ((not (stringp data))
      (pilish--image-preview-string
       (pilish--image-preview-label mime-type "decode error")))
     ((> (string-bytes data) (* 2 limit))
      (pilish--image-preview-string
       (pilish--image-preview-label
        mime-type (pilish--image-too-large-description limit))))
     (t
      (condition-case nil
          (let* ((raw (base64-decode-string data))
                 (raw-bytes (length raw))
                 (size (file-size-human-readable raw-bytes 'iec " " "B")))
            (cond
             ((string-empty-p raw)
              (pilish--image-preview-string
               (pilish--image-preview-label mime-type "empty data")))
             ((> raw-bytes limit)
              (pilish--image-preview-string
               (pilish--image-preview-label
                mime-type (pilish--image-too-large-description limit))))
             ((not type)
              (pilish--image-preview-string
               (pilish--image-preview-label
                mime-type (format "%s, unsupported type" size))))
             ((not (pilish--image-data-matches-type-p raw type))
              (pilish--image-preview-string
               (pilish--image-preview-label
                mime-type (format "%s, invalid data" size))))
             ((not (pilish--image-display-capable-p))
              (pilish--image-preview-string
               (pilish--image-preview-label mime-type size)))
             ((not (image-type-available-p type))
              (pilish--image-preview-string
               (pilish--image-preview-label
                mime-type (format "%s, unavailable" size))))
             (t
              (condition-case nil
                  (let ((image (apply #'create-image raw type t
                                      (pilish--image-preview-pixel-limits))))
                    (if image
                        (pilish--image-preview-string
                         (pilish--image-preview-label mime-type size)
                         image)
                      (pilish--image-preview-string
                       (pilish--image-preview-label
                        mime-type "display error"))))
                (error
                 (pilish--image-preview-string
                  (pilish--image-preview-label
                   mime-type "display error")))))))
        (error
         (pilish--image-preview-string
          (pilish--image-preview-label mime-type "decode error"))))))))

(defun pilish--content-image-previews (content)
  "Render a bounded number of image blocks from vector or list CONTENT."
  (let* ((blocks
          (seq-filter
           (lambda (block) (equal (plist-get block :type) "image"))
           (pilish--content-block-list content)))
         (limit (max 0 pilish--image-previews-per-content-limit))
         (shown (seq-take blocks limit))
         (omitted (- (length blocks) (length shown))))
    (append
     (mapcar #'pilish--render-content-image-preview shown)
     (when (> omitted 0)
       (list
        (pilish--image-preview-string
         (format "Image: %d additional preview%s omitted"
                 omitted (if (= omitted 1) "" "s"))))))))

(defun pilish--svg-fragment-links-only-p (source)
  "Return non-nil when every href in SVG SOURCE is a local fragment."
  (let ((case-fold-search t)
        (without-local-links source)
        (local-link-re
         "\\_<\\(?:[[:alnum:]_.-]+:\\)?href[[:space:]]*=[[:space:]]*\\([\"']\\)#[^\"']*\\1"))
    (setq without-local-links
          (replace-regexp-in-string local-link-re "" without-local-links))
    (not (string-match-p
          "\\_<\\(?:[[:alnum:]_.-]+:\\)?href[[:space:]]*="
          without-local-links))))

(defun pilish--standalone-svg-p (source)
  "Return non-nil for a complete SVG SOURCE without obvious resources."
  (let ((case-fold-search t))
    (and (eq 'svg (condition-case nil
                      (image-type-from-data source)
                    (error nil)))
         (or (string-match-p "</svg[[:space:]]*>[[:space:]]*\\'" source)
             (string-match-p "<svg\\_>[^>]*?/>[[:space:]]*\\'" source))
         (not (string-match-p
               "\\(?:<[[:space:]]*\\(?:script\\|foreignobject\\|image\\|feimage\\)\\_>\\|url[[:space:]]*(\\|@import\\|<!doctype\\|<!entity\\)"
               source))
         (pilish--svg-fragment-links-only-p source))))

(defun pilish--read-svg-preview
    (tool-name args raw-output details is-error)
  "Render a complete standalone SVG returned as READ's RAW-OUTPUT.
TOOL-NAME, ARGS, DETAILS, and IS-ERROR describe the completed result."
  (when (and (equal tool-name "read")
             (not is-error)
             (not (pilish--tool-arg-get args :offset))
             (not (pilish--tool-arg-get args :limit))
             (let ((truncation
                    (pilish--tool-arg-get details :truncation)))
               (or (null truncation)
                   (pilish--json-null-p truncation)))
             (stringp raw-output)
             (pilish--standalone-svg-p raw-output))
    (let* ((bytes (string-bytes raw-output))
           (limit (pilish--image-preview-byte-limit))
           (size (file-size-human-readable bytes 'iec " " "B"))
           (fallback (pilish--image-preview-label
                      "image/svg+xml" size)))
      (cond
       ((> bytes limit)
        (pilish--image-preview-string
         (pilish--image-preview-label
          "image/svg+xml" (pilish--image-too-large-description limit))))
       ((not (pilish--image-display-capable-p))
        (pilish--image-preview-string fallback))
       ((not (image-type-available-p 'svg))
        (pilish--image-preview-string
         (pilish--image-preview-label
          "image/svg+xml" (format "%s, unavailable" size))))
       (t
        (condition-case nil
            (let ((image
                   (apply #'create-image raw-output 'svg t
                          (append (pilish--image-preview-pixel-limits)
                                  '(:base-uri "data:" :scale 1)))))
              (pilish--image-preview-string fallback image))
          (error
           (pilish--image-preview-string
            (pilish--image-preview-label
             "image/svg+xml" (format "%s, display error" size))))))))))

(defun pilish--insert-image-previews (previews)
  "Insert rendered image PREVIEWS at point, one per line."
  (dolist (preview previews)
    (insert preview "\n")))

(defun pilish--image-previews-text (previews)
  "Return rendered PREVIEWS as newline-terminated text, or nil."
  (when previews
    (concat (mapconcat #'identity previews "\n") "\n")))

(defun pilish--tool-block-create
    (tool-name args &optional tool-call-id order preview-state path-metadata-policy)
  "Insert a live tool block for TOOL-NAME with ARGS and return it.
When TOOL-CALL-ID is non-nil, register the block in the keyed live
registry.  ORDER records the intended block ordering metadata.
When PREVIEW-STATE is `streaming', generic tool headers omit ARGS.
When PATH-METADATA-POLICY is `defer', leave navigation metadata absent
until an authoritative tool execution/history event supplies it."
  (let* ((block-order (pilish--reserve-tool-block-order order))
         (next-block (and order
                          (pilish--tool-block-next-after-order
                           block-order)))
         (next-overlay (and next-block
                            (pilish--tool-block-overlay next-block)))
         (header-display (pilish--tool-header tool-name args preview-state))
         (block nil)
         (inhibit-read-only t))
    (pilish--with-scroll-preservation
      (save-excursion
        (goto-char (if next-overlay
                       (overlay-start next-overlay)
                     (point-max)))
        (pilish--ensure-blank-line-before-block)
        (let ((start (point)))
          (insert header-display "\n")
          (let* ((header-end (copy-marker (point) nil))
                 ;; Keep the body-end marker fixed on unrelated inserts at the
                 ;; block boundary.  Live updates move it explicitly.
                 (end-marker (copy-marker (point) nil)))
            ;; When inserting before an already-live later block, keep one
            ;; blank separator after the new block without making it part of
            ;; the tool block overlay itself.
            (when next-overlay
              (insert "\n")
              ;; Insertion at an overlay's front boundary normally makes the
              ;; new text part of that overlay.  Restore the later block's
              ;; start to its shifted header so the two blocks stay disjoint.
              (move-overlay next-overlay (point) (overlay-end next-overlay)))
            (let ((ov (make-overlay start (marker-position end-marker) nil nil nil)))
              (overlay-put ov 'pilish-tool-block t)
              (overlay-put ov 'pilish-tool-name tool-name)
              (overlay-put ov 'face 'pilish-tool-block)
              (setq block (pilish--make-tool-block
                           :tool-call-id tool-call-id
                           :overlay ov
                           :header-end header-end
                           :end-marker end-marker
                           :order block-order))
              (if (eq path-metadata-policy 'defer)
                  (pilish--tool-block-refresh-overlay block)
                (pilish--tool-block-sync-path-metadata
                 block (pilish--tool-arg-path args))))))))
    (setq pilish--pending-tool-overlay
          (pilish--tool-block-overlay block))
    (pilish--tool-block-register block)))

(defun pilish--tool-block-finalize (block face)
  "Finalize BLOCK with FACE and remove it from the live keyed registry."
  (when-let* ((block block)
              (ov (pilish--tool-block-overlay block)))
    (when-let* ((end-marker (pilish--tool-block-end-marker block)))
      (set-marker-insertion-type end-marker nil))
    ;; Forced finalization is not an observed execution end.  Only the event
    ;; handler may calculate a duration, before this boundary is discarded.
    (setf (pilish--tool-block-execution-start block) nil)
    (when (pilish--argument-settle
           block nil (overlay-get ov 'pilish-tool-name)
           (list :result-present-p nil :is-error nil :details nil))
      (pilish--replace-tool-header
       block (pilish--argument-header-text
              block (overlay-get ov 'pilish-tool-name) nil)))
    (unless (pilish--tool-block-compound-p block)
      (setf (pilish--tool-block-args block) nil
            (pilish--tool-block-result block) nil))
    (overlay-put ov 'face face)
    (pilish--tool-refresh-prefixes block)
    (pilish--tool-block-refresh-overlay block)
    (pilish--tool-block-unregister block)
    (when (eq pilish--pending-tool-overlay ov)
      (setq pilish--pending-tool-overlay nil)))
  block)

(defun pilish--tool-block-delete (block)
  "Delete pure preview BLOCK's text and overlay, then remove it from live state.
Execution-backed blocks must survive preview reconciliation."
  (when-let* ((block block)
              ((not (pilish--tool-block-execution-backed-p block)))
              (ov (pilish--tool-block-overlay block))
              (start (overlay-start ov))
              (end (overlay-end ov)))
    (let* ((previous-tool (and (> start (point-min))
                               (seq-find (lambda (other)
                                           (overlay-get other 'pilish-tool-block))
                                         (overlays-at (1- start)))))
           (next-tool (and (< end (point-max))
                           (seq-find (lambda (other)
                                       (overlay-get other 'pilish-tool-block))
                                     (overlays-at (1+ end)))))
           (delete-start start)
           (delete-end end)
           (inhibit-read-only t))
      (cond
       ((and next-tool (eq (char-after end) ?\n))
        (setq delete-end (1+ end)))
       ((and previous-tool (eq (char-before start) ?\n))
        (setq delete-start (1- start))))
      (pilish--with-scroll-preservation
        (pilish--with-md-ts-change-hooks-suspended
            #'pilish--md-ts-expensive-change-hook-p
          (delete-region delete-start delete-end)))
      (delete-overlay ov)
      (when-let* ((header-end (pilish--tool-block-header-end block)))
        (set-marker header-end nil))
      (when-let* ((end-marker (pilish--tool-block-end-marker block)))
        (set-marker end-marker nil))
      (pilish--tool-block-unregister block)
      (when (eq pilish--pending-tool-overlay ov)
        (setq pilish--pending-tool-overlay nil)
        (when-let* ((last-block (car (last (pilish--live-tool-blocks-in-order)))))
          (setq pilish--pending-tool-overlay
                (pilish--tool-block-overlay last-block))))
      (when (pilish--tool-block-compound-p block)
        (pilish--release-nested-tool-block block))))
  nil)

(defun pilish--tool-overlay-finalize (face &optional block)
  "Finalize BLOCK, or the current pending tool block, with FACE."
  (pilish--tool-block-finalize
   (or block (pilish--current-tool-block))
   face))

(defun pilish--pretty-print-json (plist-data)
  "Return PLIST-DATA as a 2-space indented JSON string, or nil.
Handles the plist/vector representation from `json-parse-string'
with `:object-type \\='plist'.  Returns nil when PLIST-DATA is nil."
  (when plist-data
    (require 'json)
    ;; json-serialize is fast (C) but has no pretty-print option;
    ;; json-encode supports it, but needs alists — so we round-trip.
    (let* ((compact (json-serialize plist-data))
           (parsed (json-parse-string compact :object-type 'alist))
           (json-encoding-pretty-print t)
           (json-encoding-default-indentation "  "))
      (json-encode parsed))))

(defun pilish--propertize-details-region (details-json)
  "Return DETAILS-JSON as a details section marked as metadata.
The details payload keeps tool-output styling while setting
`pilish-no-fontify' so explicit markdown fontification
can safely skip this region."
  (propertize (concat "**Details**\n" details-json)
              'font-lock-face 'pilish-tool-output
              'pilish-no-fontify t))

(defvar pilish-saved-conversation-functions nil
  "Capture-only adapters for saved Pi v3 conversations.
Each function receives TOOL-NAME, CONTENT and DETAILS, and returns nil or
an object with :version 1, :root and :items, the same declaration as
`details.savedConversations'.  The first non-nil result wins.
Callbacks must use explicit saved associations, perform no I/O, and return
only data, never resolver callbacks or display offsets.  Captured targets
remain usable after hook removal and parent buffer death.
Explicit field presence takes precedence, even for malformed declarations.
Errors and malformed declarations produce inert unavailability labels
without interrupting unrelated rendering.")

(defun pilish--snapshot-render-origin ()
  "Return the currently rendered conversation's saved origin."
  (or pilish--snapshot-source-file (plist-get pilish--state :session-file)))

(defun pilish--saved-conversation-object-p (object)
  "Return non-nil for a nonempty JSON-style plist OBJECT."
  (and (consp object) (proper-list-p object) (cl-evenp (length object))
       (cl-loop for (key _value) on object by #'cddr always (keywordp key))))

(defun pilish--saved-conversation-declaration-labels (declaration)
  "Validate DECLARATION and return small propertized saved labels.
This boundary copies identity strings and performs no disk reads."
  (unless (and (pilish--saved-conversation-object-p declaration)
               (eql (plist-get declaration :version) 1)
               (vectorp (plist-get declaration :items))
               (> (length (plist-get declaration :items)) 0))
    (user-error "Malformed or unsupported saved conversations declaration"))
  (let ((ids (make-hash-table :test #'equal))
        (files (make-hash-table :test #'equal))
        labels)
    (seq-doseq (item (plist-get declaration :items))
      (unless (pilish--saved-conversation-object-p item)
        (user-error "Malformed saved conversation item"))
      (let* ((id (plist-get item :sessionId))
             (file (plist-get item :file))
             (label (if (plist-member item :label) (plist-get item :label) id))
             (target (pilish--snapshot-target-for-pi-v3
                      (pilish--snapshot-render-origin) id (plist-get declaration :root) file)))
        (unless (and target (pilish--saved-reference-string-p label))
          (user-error "Invalid saved conversation origin, identity, path or label"))
        (when (or (gethash id ids) (gethash file files))
          (user-error "Duplicate saved conversation identity or file"))
        (puthash id t ids)
        (puthash file t files)
        (push (pilish--subagent-label
               (propertize (substring-no-properties label) 'pilish-no-fontify t)
               target) labels)))
    (mapconcat #'identity (nreverse labels) " · ")))

(defun pilish--saved-conversation-labels (tool-name content details)
  "Capture saved labels for TOOL-NAME's observed CONTENT and DETAILS.
Return nil when there is no neutral declaration.  Malformed declarations
and adapter failures return an inert label carrying the failure reason.
Historical results without declarations remain readable without inferred
links.  Do not rewrite saved files or add a legacy adapter."
  (condition-case err
      (let* ((explicit (pilish--tool-arg-member details :savedConversations))
             (declaration
              (if explicit
                  (pilish--tool-arg-get details :savedConversations)
                (run-hook-with-args-until-success
                 'pilish-saved-conversation-functions tool-name content details))))
        (when (or explicit declaration)
          (pilish--saved-conversation-declaration-labels declaration)))
    (error
     (pilish--subagent-label "unavailable" (error-message-string err)))))

(defun pilish--saved-conversation-output (text labels)
  "Append generated saved LABELS to TEXT, or return TEXT unchanged."
  (if labels
      (concat text (propertize (concat "\n\nPi sessions: " labels) 'pilish-no-fontify t))
    text))

(defun pilish--subagent-button-action (button)
  "Open only BUTTON's copied saved subagent target."
  (pilish-open-subagent-snapshot (button-get button 'pilish-subagent-name)))

(defconst pilish--subagent-button-properties
  (text-properties-at
   0 (make-text-button "name" nil
                       'action #'pilish--subagent-button-action
                       'face 'link 'mouse-face 'highlight 'follow-link t
                       'keymap pilish--tool-button-map
                       'help-echo "Open Pi session read-only in another window"
                       'rear-nonsticky t)))

(defun pilish--remove-subagent-button (start end &optional object)
  "Remove owned button behavior in START..END of OBJECT, not its characters."
  (remove-text-properties start end
                          '(button nil category nil keymap nil action nil
                            mouse-action nil follow-link nil help-echo nil mouse-face nil face nil)
                          object))

(defun pilish--restore-subagent-buttons (start end &optional object)
  "Restore owned name behavior from the canonical property in START..END.
OBJECT is a presentation string or nil for the current buffer."
  (let ((position start)
        (inhibit-read-only t))
    (with-silent-modifications
      (while (< position end)
        (let* ((value (get-text-property position 'pilish-subagent-name object))
               (next (next-single-property-change position 'pilish-subagent-name object end)))
          (cond
           ((pilish--snapshot-target-p value)
            (add-text-properties position next pilish--subagent-button-properties object))
           ((stringp value)
            (put-text-property position next 'help-echo value object)))
          (setq position next))))))

(defun pilish--clear-subagent-names (start end &optional object)
  "Clear only previously owned names in START..END of OBJECT."
  (let ((position start))
    (while (< position end)
      (let ((next (next-single-property-change position 'pilish-subagent-name object end)))
        (when (get-text-property position 'pilish-subagent-name object)
          (pilish--remove-subagent-button position next object)
          (remove-text-properties position next '(pilish-subagent-name nil) object))
        (setq position next)))))

(defun pilish--subagent-label (text target-or-reason)
  "Return a copy of TEXT annotated with TARGET-OR-REASON."
  (setq text (propertize text 'pilish-subagent-name target-or-reason))
  (pilish--restore-subagent-buttons 0 (length text) text)
  text)

(defun pilish--rebind-subagent-names (source start end)
  "Rebind owned name properties in START..END to painted SOURCE."
  (let ((position 0)
        (inhibit-read-only t))
    (with-silent-modifications
      (pilish--clear-subagent-names start end)
      (while (< position (length source))
        (let ((next (next-single-property-change position 'pilish-subagent-name source (length source)))
              (value (get-text-property position 'pilish-subagent-name source)))
          (when value (put-text-property (+ start position) (+ start next) 'pilish-subagent-name value))
          (setq position next)))
      (pilish--restore-subagent-buttons start end))))

(defun pilish--remove-clipped-subagent-names (source slice)
  "Remove incomplete owned names after truncating SOURCE to SLICE."
  (let ((position 0) complete)
    (while (< position (length source))
      (let ((next (next-single-property-change position 'pilish-subagent-name source (length source)))
            (value (get-text-property position 'pilish-subagent-name source)))
        (when value (push (cons value (substring-no-properties source position next)) complete))
        (setq position next)))
    (setq position 0)
    (while (< position (length slice))
      (let ((next (next-single-property-change position 'pilish-subagent-name slice (length slice)))
            (value (get-text-property position 'pilish-subagent-name slice)))
        (when (and value (not (member (cons value (substring-no-properties slice position next)) complete)))
          (pilish--remove-subagent-button position next slice)
          (remove-text-properties position next '(pilish-subagent-name nil) slice))
        (setq position next)))
    slice))

(defun pilish--tool-title-append (header suffix)
  "Append SUFFIX to HEADER's first visible heading line."
  (let* ((start (if (get-text-property 0 'pilish-argument-guard header)
                    (next-single-property-change 0 'pilish-argument-guard header (length header))
                  0))
         (end (or (string-match-p "\n" header start) (length header))))
    (concat (substring header 0 end) suffix (substring header end))))

(defun pilish--saved-conversation-header-text (header labels)
  "Compose captured LABELS canonically into HEADER's first visible line."
  (let (chrome)
    (while (setq chrome (text-property-any 0 (length header)
                                           'pilish-saved-conversation-chrome t header))
      (let ((end (next-single-property-change chrome 'pilish-saved-conversation-chrome
                                              header (length header))))
        (setq header (concat (substring header 0 chrome) (substring header end)))))
    (if (null labels) header
      (pilish--tool-title-append
       header (propertize (concat " · Pi session: " labels)
                          'pilish-saved-conversation-chrome t 'pilish-no-fontify t)))))

(defun pilish--annotate-saved-conversation-header (block labels)
  "Repaint BLOCK's current header with captured LABELS."
  (when block
    (setf (pilish--tool-block-saved-labels block) labels)
    (pilish--replace-tool-header
     block (buffer-substring (overlay-start (pilish--tool-block-overlay block))
                             (1- (marker-position (pilish--tool-block-header-end block)))))))

(defun pilish--move-subagent-name (backward)
  "Move to the next visible owned name, or the previous with BACKWARD."
  (let ((position (point-min)) positions)
    (while (< position (point-max))
      (when (and (pilish--snapshot-target-p (get-text-property position 'pilish-subagent-name))
                 (pilish--visible-text-span-p position)
                 (not (invisible-p position)))
        (push position positions))
      (setq position (next-single-property-change position 'pilish-subagent-name nil (point-max))))
    (let* ((current (or (and (get-text-property (point) 'pilish-subagent-name)
                             (previous-single-property-change (1+ (point)) 'pilish-subagent-name))
                        (point)))
           (destination (if backward
                            (seq-find (lambda (pos) (< pos current)) positions)
                          (seq-find (lambda (pos) (> pos (point))) (nreverse positions)))))
      (unless destination (user-error "No %s visible subagent name" (if backward "previous" "next")))
      (goto-char destination))))

(defun pilish-next-subagent-name ()
  "Move to the next visible name with an exact saved child identity."
  (interactive)
  (pilish--move-subagent-name nil))

(defun pilish-previous-subagent-name ()
  "Move to the previous visible name with an exact saved child identity."
  (interactive)
  (pilish--move-subagent-name t))

(defun pilish--tool-header (tool-name args &optional _preview-state)
  "Return the propertized title row for tool TOOL-NAME with ARGS.
The tool name prefix uses `pilish-tool-name' face and
the arguments use `pilish-tool-command' face.
Built-in tools show specialized formats (e.g., \"bash cmd\" for Bash).
Generic tools show only their name; authoritative argument presentation
is the bounded projection painted by `pilish--argument-header-text'.
_PREVIEW-STATE is retained for call-site compatibility; generic tools
no longer parse or pretty-print ARGS here.
Uses `font-lock-face' to survive tree-sitter refontification."
  (let* ((raw-tool-name tool-name)
         (tool-name (or (pilish--tool-display-value-string
                         tool-name "tool")
                        "tool"))
         (path (pilish--tool-display-path-string
                (pilish--tool-arg-path args))))
    (pcase raw-tool-name
      ("bash"
       (let ((cmd (pilish--tool-display-value-string
                   (pilish--tool-arg-get args :command)
                   "...")))
         (concat (propertize tool-name 'font-lock-face 'pilish-tool-name)
                 (propertize (concat " " cmd) 'font-lock-face 'pilish-tool-command))))
      ((or "read" "write" "edit")
       (concat (propertize tool-name 'font-lock-face 'pilish-tool-name)
               (propertize (concat " " (or path "...")) 'font-lock-face 'pilish-tool-command)))
      (_
       (propertize tool-name 'font-lock-face 'pilish-tool-name)))))

(defun pilish--display-tool-start
    (tool-name args &optional tool-call-id order preview-state path-metadata-policy)
  "Insert a tool header for TOOL-NAME with ARGS and return its live block.
When TOOL-CALL-ID is non-nil, register the block in the keyed live
registry.  ORDER records ordering metadata for future reconciliation.
When PREVIEW-STATE is `streaming', generic tool headers omit ARGS.
PATH-METADATA-POLICY is forwarded to `pilish--tool-block-create'."
  (pilish--tool-block-create
   tool-name args tool-call-id order preview-state path-metadata-policy))

(defun pilish--replace-tool-header (block new-header)
  "Replace BLOCK's header with NEW-HEADER and canonical saved-label chrome."
  (setq new-header (pilish--saved-conversation-header-text
                    new-header (pilish--tool-block-saved-labels block)))
  (let* ((ov (pilish--tool-block-overlay block))
         (start (overlay-start ov))
         (header-end (pilish--tool-block-header-end block))
         (end (1- (marker-position header-end))))
    (when (<= start end)
      (if (string= (buffer-substring-no-properties start end)
                   (substring-no-properties new-header))
          (let ((inhibit-read-only t)
                (repair-literal nil))
            (with-silent-modifications
              (dolist (property '(line-prefix wrap-prefix pilish-argument-locator pilish-argument-address
                                  pilish-argument-literal pilish-no-fontify rear-nonsticky
                                  pilish-argument-guard pilish-argument-value font-lock-face))
                (let ((position 0))
                  (while (< position (length new-header))
                    (let* ((next (min (next-single-property-change position property new-header (length new-header))
                                      (- (next-single-property-change (+ start position) property nil end) start)))
                           (value (get-text-property position property new-header)))
                      (unless (equal-including-properties value (get-text-property (+ start position) property))
                        (when (and (get-text-property position 'pilish-argument-literal new-header)
                                   (memq property '(pilish-argument-literal pilish-no-fontify
                                                    pilish-argument-guard font-lock-face)))
                          (setq repair-literal t))
                        (put-text-property (+ start position) (+ start next) property value))
                      (setq position next)))))
              (when repair-literal (pilish--restore-tool-properties start end))))
        (let ((inhibit-read-only t))
          (pilish--with-scroll-preservation
            (save-excursion
              (goto-char start)
              (delete-region start end)
              (insert new-header)
              (pilish--tool-block-refresh-overlay block)))))
      (pilish--rebind-subagent-names new-header start (1- (marker-position header-end))))))

(defun pilish--display-tool-update-header
    (tool-name args &optional block preview-state)
  "Update BLOCK's header for TOOL-NAME with ARGS.
When BLOCK is nil, fall back to the current compatibility tool block.
When PREVIEW-STATE is `streaming', generic tool headers omit ARGS.
An existing bounded argument projection takes over the composition."
  (when-let* ((block (or block (pilish--current-tool-block))))
    (pilish--replace-tool-header
     block (pilish--argument-header-text
            block tool-name args
            (if (and (pilish--tool-block-compound-p block)
                     (equal tool-name "codemode"))
                'streaming
              preview-state)))))

(defun pilish--ensure-toolcall-streams ()
  "Return the current message's tool-call stream registry."
  (or pilish--toolcall-streams
      (setq pilish--toolcall-streams
            (make-hash-table :test 'eql))))

(defun pilish--reset-toolcall-streams ()
  "Discard raw tool-call generation state and queued paints for this message."
  (setq pilish--pending-stream-deltas
        (seq-remove
         (lambda (entry)
           (when (eq (car entry) 'toolcall)
             (setf (pilish--tool-stream-paint-pending-p (cdr entry)) nil)
             t))
         pilish--pending-stream-deltas))
  (unless pilish--pending-stream-deltas
    (pilish--cancel-stream-delta-flush))
  (when pilish--toolcall-streams
    (clrhash pilish--toolcall-streams)))

(defconst pilish--toolcall-preview-metadata-limit 4096
  "Maximum characters retained for a streamed command or path preview.")

(defun pilish--toolcall-preview-property (stream)
  "Return STREAM's preview property for its current top-level JSON key."
  (let ((key (pilish--tool-stream-current-key stream)))
    (pcase (pilish--tool-stream-tool-name stream)
      ("bash" (and (equal key "command") :command))
      ((or "read" "edit")
       (pcase key
         ("path" :path)
         ("file_path" :file_path)))
      ("write"
       (pcase key
         ("path" :path)
         ("file_path" :file_path)
         ("content" :content))))))

(defun pilish--toolcall-stream-append-string (stream text)
  "Append decoded TEXT to STREAM's bounded interesting JSON string."
  (let ((role (pilish--tool-stream-string-role stream)))
    (when (memq role '(key value))
      (unless (string-empty-p text)
        (setf (pilish--tool-stream-high-surrogate stream) nil))
      (let* ((property (and (eq role 'value)
                            (pilish--toolcall-preview-property
                             stream)))
             (limit (cond
                     ((eq role 'key) 64)
                     ((eq property :content)
                      (max 1 pilish-preview-max-bytes))
                     (t pilish--toolcall-preview-metadata-limit)))
             (combined
              (concat (pilish--tool-stream-string-value stream)
                      text)))
        (when (and (eq property :content) (string-match-p "\n" text))
          (setf (pilish--tool-stream-content-render-p stream) t))
        (setf (pilish--tool-stream-string-value stream)
              (cond
               ((<= (length combined) limit) combined)
               ((eq property :content)
                (unless (pilish--tool-stream-content-truncated stream)
                  (setf (pilish--tool-stream-content-render-p stream)
                        t))
                (setf (pilish--tool-stream-content-truncated stream)
                      t)
                (substring combined (- (length combined) limit)))
               (t (substring combined 0 limit))))))))

(defun pilish--toolcall-stream-clear-value (stream)
  "Clear STREAM's preview value before consuming a later JSON value."
  (when-let* ((property (pilish--toolcall-preview-property stream)))
    (setf (pilish--tool-stream-arguments stream)
          (plist-put (pilish--tool-stream-arguments stream)
                     property nil))
    (when (eq property :content)
      (setf (pilish--tool-stream-content-render-p stream) t
            (pilish--tool-stream-content-truncated stream)
            nil))))

(defun pilish--toolcall-stream-publish-value (stream)
  "Publish STREAM's current top-level preview string into its arguments."
  (when-let* ((property (pilish--toolcall-preview-property stream)))
    (setf (pilish--tool-stream-arguments stream)
          (plist-put (pilish--tool-stream-arguments stream)
                     property
                     (pilish--tool-stream-string-value stream)))))

(defun pilish--toolcall-stream-start-string (stream role)
  "Start a JSON string with ROLE in STREAM."
  (setf (pilish--tool-stream-string-role stream) role
        (pilish--tool-stream-string-value stream) ""
        (pilish--tool-stream-escape-state stream) nil
        (pilish--tool-stream-unicode-value stream) 0
        (pilish--tool-stream-unicode-digits stream) 0
        (pilish--tool-stream-high-surrogate stream) nil)
  (when (eq role 'value)
    (pilish--toolcall-stream-publish-value stream)))

(defun pilish--toolcall-stream-finish-string (stream)
  "Finish STREAM's current JSON string and advance its root parser."
  (let ((role (pilish--tool-stream-string-role stream))
        (value (pilish--tool-stream-string-value stream)))
    (when (eq role 'value)
      (pilish--toolcall-stream-publish-value stream))
    (setf (pilish--tool-stream-string-role stream) nil
          (pilish--tool-stream-string-value stream) ""
          (pilish--tool-stream-escape-state stream) nil
          (pilish--tool-stream-high-surrogate stream) nil)
    (pcase role
      ('key
       (setf (pilish--tool-stream-current-key stream) value
             (pilish--tool-stream-root-state stream) 'colon))
      ((or 'value 'root-value)
       (setf (pilish--tool-stream-root-state stream)
             'after-value)))))

(defun pilish--json-hex-digit-value (char)
  "Return CHAR's hexadecimal value, or nil when CHAR is not hexadecimal."
  (cond
   ((and (>= char ?0) (<= char ?9)) (- char ?0))
   ((and (>= char ?a) (<= char ?f)) (+ 10 (- char ?a)))
   ((and (>= char ?A) (<= char ?F)) (+ 10 (- char ?A)))))

(defun pilish--toolcall-stream-append-codepoint (stream codepoint)
  "Append decoded Unicode CODEPOINT to STREAM's current JSON string."
  (let ((high (pilish--tool-stream-high-surrogate stream)))
    (cond
     ((and high (>= codepoint #xdc00) (<= codepoint #xdfff))
      (setf (pilish--tool-stream-high-surrogate stream) nil)
      (pilish--toolcall-stream-append-string
       stream
       (char-to-string
        (+ #x10000
           (ash (- high #xd800) 10)
           (- codepoint #xdc00)))))
     (high
      (setf (pilish--tool-stream-high-surrogate stream) nil)
      (pilish--toolcall-stream-append-codepoint stream codepoint))
     ((and (>= codepoint #xd800) (<= codepoint #xdbff))
      (setf (pilish--tool-stream-high-surrogate stream)
            codepoint))
     ((and (>= codepoint #xdc00) (<= codepoint #xdfff)))
     ((<= codepoint #x10ffff)
      (pilish--toolcall-stream-append-string
       stream (char-to-string codepoint))))))

(defun pilish--toolcall-stream-feed-string-char (stream char)
  "Consume one JSON string CHAR for STREAM."
  (pcase (pilish--tool-stream-escape-state stream)
    ('unicode
     (if-let* ((digit (pilish--json-hex-digit-value char)))
         (let ((count (1+ (pilish--tool-stream-unicode-digits
                           stream)))
               (value (+ (ash (pilish--tool-stream-unicode-value
                               stream)
                              4)
                         digit)))
           (setf (pilish--tool-stream-unicode-digits stream)
                 count
                 (pilish--tool-stream-unicode-value stream)
                 value)
           (when (= count 4)
             (setf (pilish--tool-stream-escape-state stream) nil
                   (pilish--tool-stream-unicode-digits stream) 0
                   (pilish--tool-stream-unicode-value stream) 0)
             (pilish--toolcall-stream-append-codepoint stream value)))
       ;; Pi repairs malformed provider escapes by preserving the backslash.
       ;; Publish the literal prefix and reprocess CHAR so a quote still closes
       ;; the string rather than corrupting all later top-level fields.
       (let* ((count (pilish--tool-stream-unicode-digits stream))
              (value (pilish--tool-stream-unicode-value stream))
              (digits (if (= count 0)
                          ""
                        (format (format "%%0%dX" count) value))))
         (setf (pilish--tool-stream-escape-state stream) nil
               (pilish--tool-stream-unicode-digits stream) 0
               (pilish--tool-stream-unicode-value stream) 0
               (pilish--tool-stream-high-surrogate stream) nil)
         (pilish--toolcall-stream-append-string
          stream (concat "\\u" digits))
         (pilish--toolcall-stream-feed-string-char stream char))))
    ('escape
     (if (eq char ?u)
         (setf (pilish--tool-stream-escape-state stream) 'unicode
               (pilish--tool-stream-unicode-digits stream) 0
               (pilish--tool-stream-unicode-value stream) 0)
       (setf (pilish--tool-stream-escape-state stream) nil
             (pilish--tool-stream-high-surrogate stream) nil)
       (pilish--toolcall-stream-append-string
        stream
        (pcase char
          (?\" "\"")
          (?\\ "\\")
          (?/ "/")
          (?b "\b")
          (?f "\f")
          (?n "\n")
          (?r "\r")
          (?t "\t")
          (_ (concat "\\" (char-to-string char)))))))
    (_
     (cond
      ((eq char ?\\)
       (setf (pilish--tool-stream-escape-state stream) 'escape))
      ((eq char ?\")
       (pilish--toolcall-stream-finish-string stream))
      (t
       (setf (pilish--tool-stream-high-surrogate stream) nil)
       (pilish--toolcall-stream-append-string
        stream (char-to-string char)))))))

(defun pilish--json-whitespace-char-p (char)
  "Return non-nil when CHAR is JSON whitespace."
  (memq char '(32 9 10 13)))

(defun pilish--toolcall-stream-feed-structure-char (stream char)
  "Consume one non-string JSON CHAR for STREAM's top-level object parser."
  (let ((depth (pilish--tool-stream-depth stream)))
    (cond
     ((= depth 0)
      (when (eq char ?{)
        (setf (pilish--tool-stream-depth stream) 1
              (pilish--tool-stream-root-state stream) 'key)))
     ((> depth 1)
      (cond
       ((eq char ?\")
        (pilish--toolcall-stream-start-string stream 'nested))
       ((or (eq char ?{) (eq char ?\[))
        (setf (pilish--tool-stream-depth stream) (1+ depth)))
       ((or (eq char ?}) (eq char ?\]))
        (let ((new-depth (1- depth)))
          (setf (pilish--tool-stream-depth stream) new-depth)
          (when (= new-depth 1)
            (setf (pilish--tool-stream-root-state stream)
                  'after-value))))))
     (t
      (pcase (pilish--tool-stream-root-state stream)
        ('key
         (cond
          ((eq char ?\")
           (pilish--toolcall-stream-start-string stream 'key))
          ((eq char ?})
           (setf (pilish--tool-stream-depth stream) 0
                 (pilish--tool-stream-root-state stream) 'done))))
        ('colon
         (when (eq char ?:)
           (setf (pilish--tool-stream-root-state stream) 'value)))
        ('value
         (unless (pilish--json-whitespace-char-p char)
           ;; JSON's last occurrence wins.  Clear a prior preview before
           ;; learning whether this later value is a string we can display.
           (pilish--toolcall-stream-clear-value stream)
           (cond
            ((eq char ?\")
             (pilish--toolcall-stream-start-string
              stream
              (if (pilish--toolcall-preview-property stream)
                  'value
                'root-value)))
            ((or (eq char ?{) (eq char ?\[))
             (setf (pilish--tool-stream-depth stream) 2
                   (pilish--tool-stream-root-state stream) 'nested))
            ((eq char ?,)
             (setf (pilish--tool-stream-root-state stream) 'key
                   (pilish--tool-stream-current-key stream) nil))
            ((eq char ?})
             (setf (pilish--tool-stream-depth stream) 0
                   (pilish--tool-stream-root-state stream) 'done))
            (t
             (setf (pilish--tool-stream-root-state stream)
                   'scalar)))))
        ('scalar
         (cond
          ((eq char ?,)
           (setf (pilish--tool-stream-root-state stream) 'key
                 (pilish--tool-stream-current-key stream) nil))
          ((eq char ?})
           (setf (pilish--tool-stream-depth stream) 0
                 (pilish--tool-stream-root-state stream) 'done))))
        ('after-value
         (cond
          ((eq char ?,)
           (setf (pilish--tool-stream-root-state stream) 'key
                 (pilish--tool-stream-current-key stream) nil))
          ((eq char ?})
           (setf (pilish--tool-stream-depth stream) 0
                 (pilish--tool-stream-root-state stream) 'done)))))))))

(defun pilish--toolcall-stream-feed (stream delta)
  "Append raw argument JSON DELTA to STREAM's display-only preview state."
  (when (stringp delta)
    (let ((index 0)
          (length (length delta))
          (pending-content (pilish--tool-stream-content-render-p stream))
          (header-key (pilish--toolcall-stream-header-key stream)))
      ;; Distinguish this delta's repaint trigger from an earlier queued one.
      (setf (pilish--tool-stream-content-render-p stream) nil)
      (while (< index length)
        (if (and (pilish--tool-stream-string-role stream)
                 (null (pilish--tool-stream-escape-state stream)))
            ;; Plain string runs dominate write payloads.  Append each run once
            ;; rather than repeatedly copying the accumulated value per char.
            (let ((special (string-match "[\"\\\\]" delta index)))
              (if special
                  (progn
                    (when (> special index)
                      (pilish--toolcall-stream-append-string
                       stream (substring delta index special)))
                    (pilish--toolcall-stream-feed-string-char
                     stream (aref delta special))
                    (setq index (1+ special)))
                (pilish--toolcall-stream-append-string
                 stream (substring delta index))
                (setq index length)))
          (let ((char (aref delta index)))
            (if (pilish--tool-stream-string-role stream)
                (pilish--toolcall-stream-feed-string-char stream char)
              (pilish--toolcall-stream-feed-structure-char stream char)))
          (setq index (1+ index))))
      (when (eq (pilish--tool-stream-string-role stream) 'value)
        (pilish--toolcall-stream-publish-value stream))
      (when (and (equal (pilish--tool-stream-tool-name stream) "write")
                 (pilish--tool-arg-member
                  (pilish--tool-stream-arguments stream) :content)
                 (or (pilish--tool-stream-content-render-p stream)
                     (not (equal header-key
                                 (pilish--toolcall-stream-header-key stream)))))
        ;; Keep the value at the last synchronous repaint boundary, not the
        ;; raw tail after later partial-only deltas have rolled it away.
        (setf (pilish--tool-stream-content-to-render stream)
              (pilish--tool-arg-get (pilish--tool-stream-arguments stream) :content)
              (pilish--tool-stream-content-render-p stream) t))
      (setf (pilish--tool-stream-content-render-p stream)
            (or pending-content (pilish--tool-stream-content-render-p stream)))))
  stream)

(defun pilish--tool-name-p (tool-name)
  "Return non-nil when TOOL-NAME can identify a streamed preview."
  (and (stringp tool-name) (not (string-empty-p tool-name))))

(defun pilish--toolcall-complete-content (content)
  "Return the complete-line prefix of streamed write CONTENT."
  (when (stringp content)
    (if (string-suffix-p "\n" content)
        content
      (when-let* ((last-newline (cl-position ?\n content :from-end t)))
        (substring content 0 (1+ last-newline))))))

(defun pilish--toolcall-stream-header-key (stream)
  "Return STREAM metadata whose change requires a header repaint."
  (let ((args (pilish--tool-stream-arguments stream)))
    (pcase (pilish--tool-stream-tool-name stream)
      ("bash" (pilish--tool-arg-get args :command))
      ((or "read" "write" "edit")
       (pilish--tool-arg-path args))
      (_ nil))))

(defun pilish--render-toolcall-stream (stream _event-type)
  "Render changed, visible parts of generation STREAM.
Suspend expensive md-ts hooks for immediate starts as well as queued paints."
  (pilish--with-md-ts-change-hooks-suspended
      #'pilish--md-ts-expensive-change-hook-p
    (when (pilish--tool-name-p
           (pilish--tool-stream-tool-name stream))
      (let* ((tool-name (pilish--tool-stream-tool-name stream))
             (args (pilish--tool-stream-arguments stream))
             (header-key (pilish--toolcall-stream-header-key stream))
             (block (pilish--tool-stream-block stream)))
        (unless block
          ;; Generation identity is contentIndex, not a provider ID that may be
          ;; empty, duplicated, or corrected at either authoritative end event.
          (setq block
                (pilish--display-tool-start
                 tool-name args nil
                 (pilish--tool-stream-content-index stream)
                 'streaming 'defer))
          (setf (pilish--tool-stream-block stream) block
                (pilish--tool-stream-rendered-header-key stream)
                header-key))
        (setq pilish--pending-tool-overlay
              (pilish--tool-block-overlay block))
        (unless (equal header-key
                       (pilish--tool-stream-rendered-header-key
                        stream))
          (pilish--display-tool-update-header
           tool-name args block 'streaming)
          (setf (pilish--tool-stream-rendered-header-key stream)
                header-key))
        ;; The write preview displays complete lines only.  Avoid rewriting its
        ;; fenced body for every token that merely extends a partial line.
        (when (and (equal tool-name "write")
                   (pilish--tool-arg-member args :content)
                   (pilish--tool-stream-content-render-p stream))
          (let* ((content (pilish--tool-stream-content-to-render stream))
                 (complete-content
                  (pilish--toolcall-complete-content content)))
            (if (stringp content)
                (pilish--display-tool-streaming-text
                 (or complete-content "")
                 pilish-tool-preview-lines
                 (pilish--path-to-language
                  (pilish--tool-path-string
                   (pilish--tool-arg-path args)))
                 block
                 (pilish--tool-stream-content-truncated stream))
              (pilish--clear-toolcall-preview-body block))
            (setf (pilish--tool-stream-content-render-p stream) nil
                  (pilish--tool-stream-content-to-render stream) nil)))))))

(defun pilish--tool-block-rekey (block tool-call-id)
  "Change live BLOCK's registry key to authoritative TOOL-CALL-ID."
  (when (and block (pilish--tool-call-id-p tool-call-id))
    (let* ((old-id (pilish--tool-block-tool-call-id block))
           (changed (not (equal old-id tool-call-id)))
           (owner-p (eq block (pilish--nested-tool-owner old-id))))
      (when changed
        (pilish--tool-block-unregister block)
        (when owner-p (remhash old-id pilish--nested-tool-owners))
        (setf (pilish--tool-block-tool-call-id block) tool-call-id)
        (when owner-p (puthash tool-call-id block pilish--nested-tool-owners)))
      ;; Registration may have been displaced by a colliding provisional ID.
      (pilish--tool-block-register block)
      (when changed
        (pilish--tool-block-refresh-overlay block))))
  block)

(defun pilish--reconcile-final-toolcall
    (content-index tool-call &optional stream)
  "Reconcile authoritative TOOL-CALL at CONTENT-INDEX with STREAM preview."
  (pilish--with-md-ts-change-hooks-suspended
      #'pilish--md-ts-expensive-change-hook-p
    (let* ((tool-call-id (plist-get tool-call :id))
           (tool-name (plist-get tool-call :name))
           (args (plist-get tool-call :arguments))
           (keyed-block (or (pilish--tool-block-get tool-call-id)
                            (pilish--nested-tool-owner tool-call-id)))
           ;; Execution identity is no longer a preview.  Otherwise content
           ;; index owns generation, including colliding provisional IDs.
           (block (if (pilish--tool-block-execution-backed-p keyed-block)
                      keyed-block
                    (if stream
                        (or (pilish--tool-stream-block stream)
                            (pilish--display-tool-start
                             tool-name args nil content-index nil 'defer))
                      keyed-block))))
      (when (and stream (not (eq block (pilish--tool-stream-block stream))))
        (pilish--tool-block-delete (pilish--tool-stream-block stream)))
      (when (and block (not (pilish--tool-block-execution-backed-p block)))
        (pilish--tool-block-rekey block tool-call-id))
      (setq block
            (pilish--reconcile-toolcall-preview-block
             content-index tool-call "toolcall_end" block))
      (when stream
        (setf (pilish--tool-stream-tool-call-id stream) tool-call-id
              (pilish--tool-stream-tool-name stream)
              (plist-get tool-call :name)
              (pilish--tool-stream-arguments stream)
              (plist-get tool-call :arguments)
              (pilish--tool-stream-block stream) block
              (pilish--tool-stream-content-render-p stream) nil
              (pilish--tool-stream-content-to-render stream) nil))
      block)))

(defun pilish--handle-toolcall-message-event (event)
  "Assemble toolcall EVENT, queuing delta paints and rendering boundaries."
  (let* ((event-type (plist-get event :type))
         (content-index (plist-get event :contentIndex))
         (streams (pilish--ensure-toolcall-streams)))
    (pcase event-type
      ("toolcall_start"
       (when-let* ((old-stream (gethash content-index streams))
                   (old-block (pilish--tool-stream-block
                               old-stream)))
         (pilish--tool-block-delete old-block))
       (let ((stream (pilish--make-toolcall-stream
                      :content-index content-index
                      :tool-call-id (plist-get event :id)
                      :tool-name (plist-get event :toolName))))
         (puthash content-index stream streams)
         (pilish--render-toolcall-stream stream event-type)))
      ("toolcall_delta"
       (let ((stream (or (gethash content-index streams)
                         (let ((new-stream
                                (pilish--make-toolcall-stream
                                 :content-index content-index)))
                           (puthash content-index new-stream streams)
                           new-stream))))
         ;; Generic tool arguments are hidden while streaming.  Scan only the
         ;; built-ins whose command/path/content drives a live preview.
         (when (member (pilish--tool-stream-tool-name stream)
                       '("bash" "read" "edit" "write"))
           (pilish--toolcall-stream-feed
            stream (plist-get event :delta)))
         (pilish--queue-stream-delta 'toolcall stream)))
      ("toolcall_end"
       (when-let* ((tool-call (plist-get event :toolCall)))
         (let ((stream (or (gethash content-index streams)
                           (let ((new-stream
                                  (pilish--make-toolcall-stream
                                   :content-index content-index)))
                             (puthash content-index new-stream streams)
                             new-stream))))
           ;; Keep compact content-index/block identity until message_end,
           ;; which may apply an extension-replaced final call.
           (pilish--reconcile-final-toolcall
            content-index tool-call stream)))))))

(defun pilish--message-tool-calls (message)
  "Return MESSAGE toolCall content blocks in assistant source order.
Each element is a plist `(:content-index N :tool-call TOOL-CALL)'."
  (let ((content-vec (plist-get message :content))
        (tool-calls nil))
    (when (vectorp content-vec)
      (dotimes (content-index (length content-vec))
        (let ((block (aref content-vec content-index)))
          (when (equal (plist-get block :type) "toolCall")
            (push (list :content-index content-index
                        :tool-call block)
                  tool-calls)))))
    (nreverse tool-calls)))

(defun pilish--clear-toolcall-preview-body (block)
  "Clear stale streamed body state from unexecuted tool preview BLOCK."
  (unless (pilish--tool-block-execution-backed-p block)
    (pilish--tool-block-set-last-tail block nil)
    (pilish--tool-block-replace-body block "" nil nil)))

(defun pilish--reconcile-toolcall-preview-block
    (content-index tool-call &optional event-type block)
  "Create or update BLOCK for TOOL-CALL at CONTENT-INDEX.
EVENT-TYPE selects streaming or authoritative presentation.  When BLOCK is
nil, reuse a keyed block or create one."
  (let* ((tool-call-id (plist-get tool-call :id))
         (tool-name (plist-get tool-call :name))
         (args (plist-get tool-call :arguments))
         (streaming-p (member event-type '("toolcall_start" "toolcall_delta")))
         (compound-redraw-p (and (equal tool-name "codemode") (not streaming-p)))
         (preview-state (and streaming-p 'streaming))
         (existing-block (or block
                             (pilish--tool-block-get tool-call-id)
                             (pilish--nested-tool-owner tool-call-id)))
         (block (or existing-block
                    (pilish--display-tool-start
                     tool-name args tool-call-id content-index preview-state
                     'defer))))
    (unless (pilish--tool-block-execution-backed-p block)
      (when (and (pilish--tool-block-compound-p block) (not compound-redraw-p))
        ;; Ordinary authority supersedes generation-only compound state,
        ;; not observed execution facts or retained descendant obligations.
        (setf (pilish--tool-block-compound-p block) nil
              (pilish--tool-block-args block) nil
              (pilish--tool-block-folds block) nil)
        (pilish--tool-block-set-last-tail block nil)
        (remhash (pilish--tool-block-tool-call-id block) pilish--nested-tool-owners))
      (setq pilish--pending-tool-overlay
            (pilish--tool-block-overlay block))
      (overlay-put (pilish--tool-block-overlay block)
                   'pilish-tool-name tool-name)
      (when existing-block
        (pilish--display-tool-update-header
         tool-name args block preview-state))
      (let ((content (pilish--tool-arg-get args :content)))
        (cond
         ((equal event-type "toolcall_end")
          (if (and (equal tool-name "write") (stringp content))
              (pilish--display-tool-streaming-text
               content
               pilish-tool-preview-lines
               (pilish--path-to-language
                (pilish--tool-path-string
                 (pilish--tool-arg-path args)))
               block)
            ;; Capture established compound sections before replacing them.
            (unless compound-redraw-p
              (pilish--clear-toolcall-preview-body block))))
         ((and (equal tool-name "write")
               (pilish--tool-arg-member args :content))
          (if (stringp content)
              (pilish--display-tool-streaming-text
               content
               pilish-tool-preview-lines
               (pilish--path-to-language
                (pilish--tool-path-string
                 (pilish--tool-arg-path args)))
               block)
            (pilish--clear-toolcall-preview-body block))))))
    (when compound-redraw-p
      (pilish--enable-compound-tool block args)
      (pilish--display-tool-update-header tool-name args block)
      (pilish--redraw-compound-tool block))
    block))

(defun pilish--prune-stale-toolcall-previews (tool-call-ids)
  "Drop keyed live preview blocks whose IDs are absent from TOOL-CALL-IDS."
  (dolist (block (pilish--live-tool-blocks-in-order))
    (when-let* ((tool-call-id (pilish--tool-block-tool-call-id block))
                ((pilish--tool-call-id-p tool-call-id)))
      (unless (member tool-call-id tool-call-ids)
        (pilish--tool-block-delete block)))))

(defun pilish--toolcall-stream-by-id (tool-call-id excluded)
  "Return a stream for TOOL-CALL-ID that is not in EXCLUDED."
  (when (and (pilish--tool-call-id-p tool-call-id)
             pilish--toolcall-streams)
    (catch 'found
      (maphash
       (lambda (_content-index stream)
         (when (and (not (memq stream excluded))
                    (equal tool-call-id
                           (pilish--tool-stream-tool-call-id
                            stream)))
           (throw 'found stream)))
       pilish--toolcall-streams)
      nil)))

(defun pilish--dedupe-final-toolcall-items (items)
  "In ITEMS, keep the first authoritative ID and delete ambiguous duplicates."
  (let ((seen (make-hash-table :test 'equal))
        unique)
    (dolist (item items)
      (let* ((tool-call (plist-get item :tool-call))
             (tool-call-id (plist-get tool-call :id))
             (first (gethash tool-call-id seen))
             (block (plist-get item :block)))
        (if first
            (unless (eq block (plist-get first :block))
              (when-let* ((stream (plist-get item :stream)))
                (setf (pilish--tool-stream-block stream) nil))
              (pilish--tool-block-delete block)
              (puthash tool-call-id
                       (plist-get first :block)
                       (pilish--ensure-live-tool-blocks)))
          (puthash tool-call-id item seen)
          (push item unique))))
    (nreverse unique)))

(defun pilish--reconcile-toolcall-previews (message)
  "Reconcile live preview blocks from authoritative assistant MESSAGE."
  (let ((entries (pilish--message-tool-calls message))
        (streams pilish--toolcall-streams)
        matched-streams
        matched-blocks
        matched-items
        tool-call-ids)
    ;; Content index owns generation; a stable ID is only the fallback for a
    ;; final message that no longer has a matching stream index.
    (dolist (entry entries)
      (let* ((content-index (plist-get entry :content-index))
             (tool-call (plist-get entry :tool-call))
             (tool-call-id (plist-get tool-call :id))
             (indexed-stream (and streams (gethash content-index streams)))
             (stream (or (and indexed-stream
                              (not (memq indexed-stream matched-streams))
                              indexed-stream)
                         (pilish--toolcall-stream-by-id
                          tool-call-id matched-streams)))
             (block (pilish--reconcile-final-toolcall
                     content-index tool-call stream)))
        (when stream
          (push stream matched-streams))
        (if (pilish--tool-call-id-p tool-call-id)
            (progn
              (when block
                (push block matched-blocks)
                (push (list :content-index content-index
                            :tool-call tool-call
                            :stream stream
                            :block block)
                      matched-items))
              (push tool-call-id tool-call-ids))
          ;; Invalid final IDs cannot correlate execution.  Remove their
          ;; generation-only block now rather than leaving an orphan behind.
          (when block
            (when stream
              (setf (pilish--tool-stream-block stream) nil))
            (pilish--tool-block-delete block)))))
    (setq matched-items
          (pilish--dedupe-final-toolcall-items
           (nreverse matched-items))
          matched-blocks
          (mapcar (lambda (item) (plist-get item :block)) matched-items)
          tool-call-ids (delete-dups tool-call-ids))
    ;; Empty/provisional IDs are owned only by their stream records and cannot
    ;; be pruned through the execution-ID registry.
    (when streams
      (maphash
       (lambda (_content-index stream)
         (when-let* ((block (pilish--tool-stream-block stream)))
           (unless (memq block matched-blocks)
             (setf (pilish--tool-stream-block stream) nil)
             (pilish--tool-block-delete block))))
       streams))
    (pilish--prune-stale-toolcall-previews tool-call-ids)))

(defun pilish--extract-text-from-content (content-blocks)
  "Extract text from CONTENT-BLOCKS vector efficiently.
Returns the concatenated text from all text blocks.
Optimized for the common case of a single text block."
  (if (and (vectorp content-blocks) (> (length content-blocks) 0))
      (let ((first-block (aref content-blocks 0)))
        (if (and (= (length content-blocks) 1)
                 (equal (plist-get first-block :type) "text"))
            ;; Fast path: single text block (common case)
            (pilish--render-safe-string
             (plist-get first-block :text))
          ;; Slow path: multiple blocks, need to filter and concat
          (mapconcat (lambda (c)
                       (if (equal (plist-get c :type) "text")
                           (pilish--render-safe-string
                            (plist-get c :text))
                         ""))
                     content-blocks "")))
    ""))

(defun pilish--extract-user-message-text (content)
  "Extract text from user message CONTENT.
CONTENT is a vector of content blocks from a user message.
Returns the concatenated text, or nil if empty."
  (let ((text (pilish--extract-text-from-content content)))
    (unless (string-empty-p text) text)))

(defun pilish--get-tail-lines (content n)
  "Get last N non-blank lines from CONTENT by scanning backward.
Blank lines are included in the returned content but do not count
toward N, so downstream consumers that strip blanks still get N
content lines.
Returns (TAIL-CONTENT . HAS-HIDDEN) where HAS-HIDDEN is non-nil
if there are earlier lines not included in TAIL-CONTENT.
This is O(k) where k is the size of the tail, not O(n) like `split-string'."
  (let* ((len (length content))
         (pos len)
         (newlines-found 0))
    (cond
     ((= len 0)
      (cons "" nil))
     ((<= n 0)
      (cons "" (not (string-empty-p (string-trim-right content "\n+")))))
     (t
      ;; Skip trailing newlines
      (while (and (> pos 0) (eq (aref content (1- pos)) ?\n))
        (setq pos (1- pos)))
      ;; Find N newlines from the end, skipping blank-line boundaries.
      ;; A newline at `pos' leads to a blank line when content[pos+1]
      ;; is also a newline — that boundary doesn't add a content line.
      (while (and (> pos 0) (< newlines-found n))
        (setq pos (1- pos))
        (when (and (eq (aref content pos) ?\n)
                   (not (eq (aref content (1+ pos)) ?\n)))
          (setq newlines-found (1+ newlines-found))))
      ;; Adjust pos to start after the Nth newline
      (when (and (> pos 0) (eq (aref content pos) ?\n))
        (setq pos (1+ pos)))
      ;; Return tail and whether there's hidden content
      (cons (substring content pos) (> pos 0))))))

(defun pilish--call-with-tool-body-edit (beg end fallback function)
  "Call FUNCTION for one ordinary tool-body edit in the current buffer.
BEG and END delimit the old half-open replacement interval.  Positions
inside it move to the tool body start FALLBACK; surviving points and
window starts use advancing markers.  Following windows stay at a filled
tail.  Restore views only on normal completion and always detach markers.
FUNCTION must not yield or change unrelated text.  Return nil."
  (unless (and (integerp beg) (integerp end) (integerp fallback)
               (<= (point-min) fallback beg end (point-max)))
    (error "Invalid tool body edit bounds"))
  (let ((buffer (current-buffer))
        (selected (selected-window))
        markers buffer-point views selected-point)
    (cl-labels ((anchor (position)
                  (let* ((deleted (and (< beg end) (<= beg position)
                                       (< position end)))
                         (marker (copy-marker (if deleted fallback position)
                                              (not deleted))))
                    (push marker markers)
                    marker)))
      (unwind-protect
          (progn
            (setq buffer-point (anchor (point)))
            (unless (pilish--viewport-updates-deferred-p)
              (dolist (window (get-buffer-window-list buffer nil t))
                (push (list :window window
                            :following (pilish--window-following-p window)
                            :point (anchor (window-point window))
                            :start (anchor (window-start window)))
                      views)))
            (funcall function)
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (save-selected-window
                  (dolist (view (nreverse views))
                    (let ((window (plist-get view :window)))
                      (when (and (window-live-p window)
                                 (eq (window-buffer window) buffer))
                        (let* ((following (plist-get view :following))
                               (point-anchor (plist-get view :point))
                               (point (if following (point-max)
                                        (marker-position point-anchor)))
                               (start (marker-position (plist-get view :start))))
                          (when (and (not (marker-insertion-type point-anchor))
                                     (< point start))
                            (setq start point))
                          (if following
                              (pilish--restore-tail-window window start)
                            (set-window-start window start t)
                            (set-window-point window point))
                          (when (eq window selected)
                            (setq selected-point point)))))))
                (goto-char buffer-point)
                (when selected-point
                  (set-window-point selected selected-point))))
            nil)
        (dolist (marker markers)
          (set-marker marker nil))))))

(defun pilish--tool-block-replace-body
    (block display-content show-hidden-indicator lang)
  "Replace BLOCK body with DISPLAY-CONTENT.
SHOW-HIDDEN-INDICATOR adds the collapsed-output hint line.
LANG is passed to `pilish--wrap-in-src-block' for fence construction."
  (when-let* ((block block)
              (header-end (pilish--tool-block-header-end block))
              (end-marker (pilish--tool-block-end-marker block)))
    (let* ((body-start (marker-position header-end))
           (old-body (buffer-substring-no-properties
                      body-start (marker-position end-marker)))
           (new-body (concat
                      (when show-hidden-indicator
                        (propertize "... (earlier output)\n"
                                    'face 'pilish-collapsed-indicator))
                      (unless (string-empty-p display-content)
                        (concat (pilish--wrap-in-src-block
                                 display-content lang) "\n"))))
           (old-length (length old-body))
           (new-length (length new-body))
           (common-prefix 0)
           (common-suffix 0)
           (shorter-length (min old-length new-length))
           (inhibit-read-only t))
      ;; Keep unchanged fence lines in place: deleting and reinserting them
      ;; flushes font-lock across the whole Markdown buffer on every update.
      (while (and (< common-prefix shorter-length)
                  (eq (aref old-body common-prefix)
                      (aref new-body common-prefix)))
        (cl-incf common-prefix))
      (while (and (< common-suffix (- shorter-length common-prefix))
                  (eq (aref old-body (- old-length common-suffix 1))
                      (aref new-body (- new-length common-suffix 1))))
        (cl-incf common-suffix))
      (unless (and (= common-prefix old-length)
                   (= common-prefix new-length))
        (let* ((edit-start (+ body-start common-prefix))
               (edit-end (- (+ body-start old-length) common-suffix))
               (old-text (substring old-body common-prefix
                                    (- old-length common-suffix)))
               (new-text (substring new-body common-prefix
                                    (- new-length common-suffix))))
          (pilish--call-with-tool-body-edit
           edit-start edit-end body-start
           (lambda ()
             (save-excursion
               (goto-char edit-start)
               (save-match-data
                 (cond
                  ((= edit-start edit-end) (insert new-text))
                  ((string-empty-p new-text) (delete-region edit-start edit-end))
                  (t
                   (unless (and (search-forward old-text edit-end t)
                                (= (point) edit-end))
                     (error "Tool preview changed during redraw"))
                   (replace-match new-text t t))))
               (set-marker header-end body-start)
               (set-marker end-marker (+ body-start new-length))
               (pilish--tool-block-refresh-overlay block))))))
      (pilish--rebind-subagent-names new-body body-start (+ body-start new-length)))))

(defun pilish--display-tool-streaming-text
    (raw-text max-lines &optional lang block source-truncated)
  "Display RAW-TEXT as streaming content in BLOCK.
Shows a rolling tail truncated to MAX-LINES visual lines.
When BLOCK is nil, fall back to the current compatibility tool block.
SOURCE-TRUNCATED means the argument assembler already dropped an older prefix.

When LANG is non-nil, wrap the tail in a markdown fenced code block so
that `md-ts-mode' language injection handles syntax highlighting.
Skips redraw when only the trailing partial line changed (the preview
shows complete lines only)."
  (let ((raw-text (pilish--render-safe-string raw-text)))
    (when-let* ((block (or block (pilish--current-tool-block))))
      (let* (;; For language-aware streaming, only show complete lines
             ;; (exclude trailing partial line) to keep the preview
             ;; stable across partial-token deltas.
             (complete-text
              (if (and lang (not (string-suffix-p "\n" raw-text)))
                  (let ((last-nl (cl-position ?\n raw-text :from-end t)))
                    (if last-nl (substring raw-text 0 (1+ last-nl)) ""))
                raw-text))
             (tail-result (pilish--get-tail-lines complete-text max-lines))
             (tail-content (or (car tail-result) ""))
             (has-hidden (cdr tail-result))
             (truncation (pilish--truncate-to-visual-lines
                          tail-content max-lines
                          (pilish--chat-display-width)))
             (display-content
              (string-trim-right
               (or (plist-get truncation :content) "")
               "\n+"))
             (show-hidden-indicator
              (or source-truncated
                  has-hidden
                  (> (plist-get truncation :hidden-lines) 0)))
             (cache-key (list lang show-hidden-indicator display-content))
             (last-tail (pilish--tool-block-last-tail block)))
        (unless (equal-including-properties cache-key last-tail)
          (pilish--tool-block-replace-body
           block display-content show-hidden-indicator lang)
          (pilish--tool-block-set-last-tail block cache-key))))))

;;;; Coalesced tool update rendering

;; Pi emits one `tool_execution_update' per extension onUpdate call, with a
;; cumulative `:partialResult' (replace semantics).  Rendering every event
;; synchronously multiplied an expensive fenced body replacement by
;; machine-gun update bursts (median inter-update gap ~1 ms, peaks above
;; 40 updates/s in real subagent sessions).  Instead, each event only
;; records the latest partial result for its tool call, and one buffer-local
;; one-shot timer renders the pending previews at a humane cadence.  Typing
;; always wins: the flush re-arms instead of rendering while input is pending.

(defconst pilish--tool-update-render-interval 0.25
  "Seconds between coalesced renders of streaming tool output previews.
The pattern mirrors pi's TUI, which coalesces repaints latest-wins behind
a minimum render interval; 250 ms is this frontend's humane cadence for
previews that an authoritative tool_execution_end always supersedes.
Internal constant, not a user option.")

(defvar-local pilish--tool-update-flush-timer nil
  "The one pending one-shot flush timer for tool updates, or nil.
At most one timer exists per chat buffer; updates never cancel or rearm
it.  Only the flush itself schedules a further attempt (typing-wins).")

(defun pilish--schedule-tool-update-flush ()
  "Arm the one-shot tool-update flush timer for the current buffer."
  (setq pilish--tool-update-flush-timer
        (run-at-time pilish--tool-update-render-interval nil
                     #'pilish--flush-tool-updates
                     (current-buffer))))

(defun pilish--queue-tool-update (tool-call-id partial-result)
  "Record PARTIAL-RESULT as the pending paint for TOOL-CALL-ID.
PARTIAL-RESULT is an ordinary result plist or an ingested compound block.
Latest-wins per owner; the shared flush timer is armed only when none
is pending, and an armed timer keeps its deadline.  No chat text changes."
  (when (and tool-call-id partial-result)
    ;; A live ordinary tool can become compound before its first paint.  Its
    ;; transient parent snapshot must already exist when a child is ingested.
    (unless (pilish--tool-block-p partial-result)
      (when-let* ((block (pilish--tool-block-get tool-call-id)))
        (setf (pilish--tool-block-result block) partial-result)))
    (if-let* ((entry (assoc tool-call-id pilish--pending-tool-updates)))
        (setcdr entry partial-result)
      (push (cons tool-call-id partial-result)
            pilish--pending-tool-updates))
    (unless pilish--tool-update-flush-timer
      (pilish--schedule-tool-update-flush))))

(defun pilish--flush-tool-updates (buffer)
  "Render pending tool update previews in BUFFER, then leave clean state.
Timer callback for `pilish--tool-update-flush-timer'.  Clears the
timer slot first so updates arriving during the flush can schedule a fresh
pass.  While user input is pending, renders nothing and schedules one
retry; typing wins over preview refresh.  Errors during rendering cannot
wedge the scheduler: the timer slot and pending map are already cleared
before any preview is painted."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq pilish--tool-update-flush-timer nil)
      (if (input-pending-p)
          (when pilish--pending-tool-updates
            (pilish--schedule-tool-update-flush))
        (let ((pending (nreverse pilish--pending-tool-updates)))
          (setq pilish--pending-tool-updates nil)
          (dolist (entry pending)
            (let ((value (cdr entry)))
              (if (pilish--tool-block-p value)
                  (when (and (eq value (pilish--nested-tool-owner (car entry)))
                             (eq (overlay-buffer (pilish--tool-block-overlay value))
                                 (current-buffer)))
                    (pilish--redraw-compound-tool value))
                (pilish--display-tool-update
                 value
                 ;; Falls back to the compatibility block on an ordinary miss.
                 (pilish--tool-block-get (car entry)))))))))))

(defun pilish--discard-pending-tool-update (tool-call-id)
  "Drop any pending preview for TOOL-CALL-ID.
Called on tool_execution_end before the authoritative final render.  A
still-armed flush timer is left alone: it fires into the remaining (or
empty) pending map, and flushing nothing is a no-op."
  (when (and tool-call-id pilish--pending-tool-updates)
    (setq pilish--pending-tool-updates
          (assoc-delete-all tool-call-id
                            pilish--pending-tool-updates))))

(defun pilish--cancel-tool-update-flush ()
  "Cancel any armed tool-update flush timer and discard pending previews.
Idempotent.  Runs wherever live tool state is torn down -- buffer kill,
session reset, history rebuild -- so no stale timer or preview survives a
session transition.  Agent end preserves compound paints."
  (when (timerp pilish--tool-update-flush-timer)
    (cancel-timer pilish--tool-update-flush-timer))
  (setq pilish--tool-update-flush-timer nil
        pilish--pending-tool-updates nil))

(defun pilish--display-tool-update (partial-result &optional block)
  "Display PARTIAL-RESULT as streaming output in BLOCK.
When BLOCK is nil, fall back to the current compatibility tool block.
PARTIAL-RESULT has the same structure as a tool result plist with
`:content'.  Ordinary output delegates to `pilish--display-tool-streaming-text'.
Compound output retains parent facts and queues the owner for one repaint."
  (when partial-result
    (when block
      (when (and (pilish--tool-block-compound-p block)
                 (equal (overlay-get (pilish--tool-block-overlay block) 'pilish-tool-name) "codemode")
                 (equal (plist-get partial-result :content) [])
                 (plist-member partial-result :details))
        (setq partial-result
              (plist-put (copy-sequence partial-result) :content
                         (plist-get (pilish--tool-block-result block) :content))))
      (setf (pilish--tool-block-result block) partial-result
            (pilish--tool-block-saved-labels block)
            (pilish--saved-conversation-labels
             (overlay-get (pilish--tool-block-overlay block) 'pilish-tool-name)
             (plist-get partial-result :content) (plist-get partial-result :details))))
    (if (and block (pilish--tool-block-compound-p block))
        (progn
          (pilish--merge-codemode-calls block (pilish--tool-arg-get
                                             (plist-get partial-result :details) :calls))
          (pilish--queue-tool-update (pilish--tool-block-tool-call-id block) block))
      (let* ((content-blocks (plist-get partial-result :content))
             (raw-output (pilish--extract-text-from-content content-blocks))
             (tool-name (and block (overlay-get (pilish--tool-block-overlay block) 'pilish-tool-name)))
             (details (plist-get partial-result :details))
             (labels (if block (pilish--tool-block-saved-labels block)
                       (pilish--saved-conversation-labels tool-name content-blocks details))))
        (pilish--display-tool-streaming-text
         (pilish--saved-conversation-output raw-output labels)
         pilish-bash-preview-lines nil block)
        (pilish--annotate-saved-conversation-header block labels)))))

(defun pilish--markdown-fence-delimiter (content)
  "Return a markdown fence delimiter safe for CONTENT.
Uses triple backticks by default.  If CONTENT contains triple-backtick
runs, uses a tilde fence longer than any tilde run in CONTENT."
  (let ((text (or content "")))
    (if (string-match-p "```+" text)
        (let ((max-tilde-run 0)
              (pos 0))
          (while (string-match "~+" text pos)
            (setq max-tilde-run
                  (max max-tilde-run
                       (- (match-end 0) (match-beginning 0))))
            (setq pos (match-end 0)))
          (make-string (max 3 (1+ max-tilde-run)) ?~))
      "```")))

(defun pilish--wrap-in-src-block (content lang)
  "Wrap CONTENT in a markdown fenced code block with LANG.
Returns markdown string for syntax highlighting."
  (let ((fence (pilish--markdown-fence-delimiter content)))
    (format "%s%s\n%s\n%s" fence (or lang "") content fence)))

(defun pilish--codemode-output-content (content is-error)
  "Return CONTENT without an exact, outcome-consistent first codemode banner.
IS-ERROR selects the failed banner rather than the completed banner.
Inspect the original separate block before normalization can discard malformed
leading entries.  Unknown content and the original result remain untouched."
  (let* ((case-fold-search nil)
         (first (cond ((vectorp content) (and (> (length content) 0) (aref content 0)))
                      ((consp content) (car content))))
         (text (and (consp first) (equal (plist-get first :type) "text")
                    (plist-get first :text))))
    (if (and (stringp text)
             (string-match-p
              (concat "\\`Script " (if is-error "failed" "completed")
                      "\nWall time [0-9]+\\.[0-9] seconds\nOutput:\n\\'") text))
        (if (vectorp content) (seq-subseq content 1) (cdr content))
      content)))

(cl-defun pilish--tool-result-presentation
    (tool-name args content details is-error &optional omit-image-preparation
               (saved-labels nil saved-labels-p))
  "Select TOOL-NAME's result presentation from ARGS, CONTENT and DETAILS.
IS-ERROR gates success-only diff annotations and SVG previews.  Insertion
stays in the destination buffer so image properties and diff overlays survive.
OMIT-IMAGE-PREPARATION skips image decoding and SVG scans for closed children.
SAVED-LABELS, when supplied, reuses a captured declaration without adapters.
The :saved-labels result contains only small propertized labels, :images
contains prepared previews, and :image-content-p reports image presence."
  (let* ((is-error (eq t is-error))
         (content-blocks (pilish--content-block-list
                          (if (equal tool-name "codemode")
                              (pilish--codemode-output-content content is-error)
                            content)))
         (text-blocks (seq-filter (lambda (c) (equal (plist-get c :type) "text"))
                                  content-blocks))
         (raw-output (mapconcat (lambda (c)
                                  (pilish--render-safe-string (plist-get c :text)))
                                text-blocks "\n"))
         (images (unless omit-image-preparation
                   (pilish--content-image-previews content-blocks)))
         (svg-preview (and (not omit-image-preparation) (null images)
                           (pilish--read-svg-preview tool-name args raw-output details is-error)))
         (edit-diff (and (equal tool-name "edit") (pilish--tool-arg-get details :diff)))
         (details-json (and (not (member tool-name '("edit" "write" "bash" "read")))
                            (pilish--pretty-print-json details)))
         (labels (if saved-labels-p saved-labels
                   (pilish--saved-conversation-labels tool-name content details))))
    (list :saved-labels labels
          :text
          (pilish--saved-conversation-output
           (ansi-color-filter-apply
           (pilish--render-safe-string
            (pcase tool-name
              ("edit" (or edit-diff raw-output))
              ("write" (if is-error
                           raw-output
                         (or (pilish--tool-arg-get args :content) raw-output)))
              ((or "bash" "read") raw-output)
              (_ (if details-json
                     (concat raw-output "\n\n" (pilish--propertize-details-region details-json))
                   raw-output)))))
           labels)
          :lang (pilish--path-to-language (pilish--tool-path-string (pilish--tool-arg-path args)))
          :is-edit-diff (and (not is-error) (stringp edit-diff))
          :images (if svg-preview (list svg-preview) images)
          :image-content-p (pilish--content-has-image-p content-blocks)
          :preview-limit (if (equal tool-name "bash") pilish-bash-preview-lines pilish-tool-preview-lines)
          :offset (and (equal tool-name "read") (pilish--tool-arg-get args :offset)))))

(defun pilish--display-tool-end
    (tool-name args content details is-error &optional block)
  "Display result for TOOL-NAME and finalize BLOCK.
ARGS contains tool arguments, CONTENT is a list of content blocks.
DETAILS contains tool-specific data (e.g., a diff for the edit tool);
for generic tools, non-nil DETAILS are rendered below the content.
IS-ERROR indicates failure.
When BLOCK is nil, fall back to the current compatibility tool block and,
if none exists, render the result at point without a live overlay."
  (let* ((block (or block (pilish--current-tool-block)))
         (is-error (eq t is-error))
         (labels (pilish--saved-conversation-labels tool-name content details))
         (inhibit-read-only t))
    (when block
      (setf (pilish--tool-block-saved-labels block) labels)
      (when (pilish--argument-settle block nil tool-name
                                     (list :result-present-p t
                                           :is-error is-error
                                           :details details))
        (pilish--replace-tool-header
         block (pilish--argument-header-text block tool-name args))))
    (if (and block (pilish--tool-block-compound-p block))
        (progn
          (setf (pilish--tool-block-result block)
                (list :content content :details details :isError is-error))
          (pilish--merge-codemode-calls block (pilish--tool-arg-get details :calls)
                                       (pilish--tool-block-history-p block))
          (pilish--redraw-compound-tool block)
          (pilish--tool-overlay-finalize
           (if is-error 'pilish-tool-block-error 'pilish-tool-block) block))
      (let* ((presentation (pilish--tool-result-presentation tool-name args content details is-error nil labels))
             (image-previews (plist-get presentation :images))
             (lang (plist-get presentation :lang))
             (is-edit-diff (plist-get presentation :is-edit-diff))
             (display-content (plist-get presentation :text))
             (truncation (pilish--truncate-to-visual-lines
                          display-content (plist-get presentation :preview-limit)
                          (pilish--chat-display-width)))
             (hidden-count (plist-get truncation :hidden-lines))
             (needs-collapse (> hidden-count 0)))
        (pilish--annotate-saved-conversation-header block labels)
        (if block
            (let* ((header-end (pilish--tool-block-header-end block))
                   (end-marker (pilish--tool-block-end-marker block))
                   (body-start (marker-position header-end))
                   (old-end (marker-position end-marker)))
              (pilish--call-with-tool-body-edit
               body-start old-end body-start
               (lambda ()
                 (save-excursion
                   (goto-char body-start)
                   (delete-region body-start old-end)
                   (if needs-collapse
                       ;; Long output: show preview with toggle button.
                       (let ((preview-content (plist-get truncation :content)))
                         (pilish--insert-tool-content-with-toggle
                          preview-content display-content lang is-edit-diff hidden-count nil))
                     (unless (string-empty-p display-content)
                       (pilish--insert-rendered-tool-content
                        (string-trim-right display-content "\n+") lang is-edit-diff)))
                   (pilish--insert-image-previews image-previews)
                   (pilish--tool-block-set-image-previews block image-previews)
                   (set-marker end-marker (point))
                   (pilish--tool-block-refresh-overlay block)
                   ;; Error content and the overlay face suffice; no error badge.
                   (when-let* ((offset (plist-get presentation :offset)))
                     (pilish--tool-block-set-offset block offset))
                   (when-let* ((line-map (plist-get truncation :line-map)))
                     (pilish--tool-block-set-line-map block line-map))
                   (pilish--tool-overlay-finalize
                    (if is-error 'pilish-tool-block-error 'pilish-tool-block) block)
                   (when (eobp) (insert "\n"))))))
          (pilish--with-scroll-preservation
            (save-excursion
              (goto-char (point-max))
              (if needs-collapse
                  (let ((preview-content (plist-get truncation :content)))
                    (pilish--insert-tool-content-with-toggle
                     preview-content display-content lang is-edit-diff hidden-count nil))
                (unless (string-empty-p display-content)
                  (pilish--insert-rendered-tool-content
                   (string-trim-right display-content "\n+") lang is-edit-diff)))
              (pilish--insert-image-previews image-previews)
              (insert "\n"))))))))

(defun pilish--ranges-excluding-property (start end prop)
  "Return contiguous ranges in START..END where PROP is nil."
  (let ((pos start)
        (ranges nil))
    (while (< pos end)
      (let* ((excluded (get-text-property pos prop))
             (next (or (next-single-property-change pos prop nil end)
                       end)))
        (unless excluded
          (push (cons pos next) ranges))
        (setq pos next)))
    (nreverse ranges)))

(defun pilish--font-lock-ensure-excluding-property (start end prop)
  "Fontify START..END while skipping regions where PROP is non-nil.
Stops after the first font-lock error to avoid repeated failures.
Full history replay defers transcript fontification until all edits finish."
  (unless pilish--defer-history-postprocessing
    (catch 'pilish--font-lock-failed
      (dolist (range (pilish--ranges-excluding-property start end prop))
        (condition-case err
            (font-lock-ensure (car range) (cdr range))
          (error
           (when debug-on-error
             (message "pilish: toggle fontification failed: %S" err))
           (throw 'pilish--font-lock-failed nil)))))))

(defun pilish--toggle-tool-output (button)
  "Toggle between preview and full content for BUTTON.
Preserves window scroll position during the toggle."
  (let* ((inhibit-read-only t)
         (expanded (button-get button 'pilish-expanded))
         (full-content (button-get button 'pilish-full-content))
         (preview-content (button-get button 'pilish-preview-content))
         (lang (button-get button 'pilish-lang))
         (is-edit-diff (button-get button 'pilish-is-edit-diff))
         (hidden-count (button-get button 'hidden-count))
         (btn-start (button-start button)))
    (when-let* ((ov (save-excursion (goto-char btn-start) (pilish--tool-overlay-at-point)))
                (header-end (overlay-get ov 'pilish-header-end)))
      (let* ((start (marker-position header-end))
             (old-end (overlay-end ov))
             (record (pilish--tool-block-from-overlay ov))
             (line-map (overlay-get ov 'pilish-line-map))
             (old-sections (pilish--tool-section-bounds
                            start old-end (and (not expanded) (list (cons 'output line-map)))))
             (view (pilish--capture-tool-cooling-view))
             (image-previews (and record (pilish--tool-block-image-previews record))))
        (save-excursion
          (remove-overlays start old-end 'pilish-diff-overlay t)
          (delete-region start old-end)
          (goto-char start)
          (pilish--insert-tool-content-with-toggle
           preview-content full-content lang is-edit-diff hidden-count (not expanded))
          (pilish--insert-image-previews image-previews)
          (if record
              (progn
                (set-marker (pilish--tool-block-end-marker record) (point))
                (pilish--tool-block-refresh-overlay record))
            (move-overlay ov (overlay-start ov) (point)))
          (pilish--font-lock-ensure-excluding-property start (point) 'pilish-no-fontify))
        (let* ((new-end (overlay-end ov))
               (new-sections (pilish--tool-section-bounds
                              start new-end (and expanded (list (cons 'output line-map))))))
          (pilish--restore-tool-cooling-view
           view start old-end new-end
           (lambda (position)
             (pilish--map-tool-section-position
              position old-sections new-sections start old-end new-end 'output))))))))

(defun pilish--replace-thinking-block-region (start end rendered)
  "Replace completed-thinking text in START..END with RENDERED.
Returns the new bounds as (START . NEW-END)."
  (let ((inhibit-read-only t)
        new-end)
    (save-excursion
      (goto-char start)
      (pilish--remove-table-overlays start end)
      (delete-region start end)
      (insert rendered)
      (setq new-end (point))
      (condition-case-unless-debug nil
          (font-lock-ensure start new-end)
        (error nil)))
    (cons start new-end)))

(defun pilish--replace-thinking-block (block rendered)
  "Replace completed thinking BLOCK with RENDERED text.
Returns the new block bounds as (START . END) and preserves useful window
context after the rewrite."
  (let* ((start (plist-get block :start))
         (end (plist-get block :end))
         (buffer (current-buffer))
         (saved-windows (pilish--capture-window-rewrite-states))
         (new-bounds (pilish--replace-thinking-block-region
                      start end rendered))
         (delta (- (cdr new-bounds) end)))
    (pilish--restore-window-rewrite-states
     buffer
     saved-windows
     (let ((replacements (list (list start end delta))))
       (lambda (pos)
         (pilish--adjust-pos-after-region-replacements
          pos replacements))))
    new-bounds))

(defun pilish--completed-thinking-blocks ()
  "Return completed thinking blocks in the current buffer in source order."
  (let ((pos (point-min))
        blocks)
    (while (< pos (point-max))
      (if (get-text-property pos 'pilish-thinking-block)
          (when-let* ((block (pilish--thinking-block-metadata-at-pos pos)))
            (push block blocks)
            (setq pos (plist-get block :end)))
        (setq pos (or (next-single-property-change
                       pos 'pilish-thinking-block nil (point-max))
                      (point-max)))))
    (nreverse blocks)))

(defun pilish--apply-thinking-display-to-completed-blocks (display)
  "Rewrite every completed thinking block in the current buffer for DISPLAY.
DISPLAY is either `visible' or `hidden'.  Returns replacement records when at
least one completed thinking block changed, otherwise nil.  Unrelated buffer
content is left alone.  Each replacement record is (START END DELTA), using
coordinates from before the rewrites."
  (let (replacements)
    (save-excursion
      (dolist (block (nreverse (pilish--completed-thinking-blocks)))
        (unless (eq (plist-get block :display) display)
          (when-let* ((rendered
                       (pilish--completed-thinking-rendered-from-normalized
                        (plist-get block :normalized)
                        (plist-get block :order)
                        display
                        (plist-get block :details))))
            (let* ((start (plist-get block :start))
                   (end (plist-get block :end))
                   (new-bounds (pilish--replace-thinking-block-region
                                start end rendered)))
              (push (list start end (- (cdr new-bounds) end))
                    replacements))))))
    replacements))

(defun pilish--toggle-thinking-block-at-point ()
  "Toggle the completed-thinking block at point.
Returns non-nil when point was inside a completed thinking block and the block
was toggled successfully."
  (when-let* ((block (pilish--thinking-block-metadata-at-pos (point)))
              (normalized (plist-get block :normalized))
              (order (plist-get block :order))
              (display (plist-get block :display))
              (rendered (pilish--completed-thinking-rendered-from-normalized
                         normalized
                         order
                         (if (eq display 'hidden) 'visible 'hidden)
                         (plist-get block :details))))
    (let* ((original-pos (point))
           (new-bounds (pilish--replace-thinking-block block rendered))
           (new-start (car new-bounds))
           (new-end (cdr new-bounds)))
      (goto-char (max new-start
                      (min original-pos (max new-start (1- new-end))))))
    t))

(defun pilish--startup-banner-label (name)
  "Return NAME as a Markdown code span, preserving literal punctuation."
  (let ((delimiter "`"))
    (while (string-match-p (regexp-quote delimiter) name)
      (setq delimiter (concat delimiter "`")))
    (concat delimiter
            (if (or (string-prefix-p "`" name) (string-suffix-p "`" name))
                (concat " " name " ")
              name)
            delimiter)))

(defun pilish--startup-banner-item (name path &optional description)
  "Format a Markdown list item for NAME, source PATH, and DESCRIPTION.
PATH is an already normalized Emacs source path, or nil when unavailable.
Keep it on the link label so the existing file visitor can open known sources
without imposing the stricter path grammar used for arbitrary chat prose."
  (let ((label (pilish--startup-banner-label name))
        (description (string-join (split-string (or description "")) " ")))
    (concat
     "- "
     (if path
         (format "[%s](<%s>)"
                 (propertize label 'pilish-startup-source path)
                 (mapconcat #'url-hexify-string
                            (split-string (pilish--local-name-for-process path) "/")
                            "/"))
       label)
     (unless (string-empty-p description) (concat " — " description)))))

(defun pilish--startup-banner-section (heading contents)
  "Return Markdown HEADING followed by CONTENTS, omitting empty sections."
  (when contents
    (concat heading "\n\n" (string-join contents "\n"))))

(defun pilish--startup-banner-commands (heading source)
  "Format a HEADING section for commands of SOURCE, grouped by scope."
  (let ((groups (seq-group-by (lambda (command) (plist-get command :location))
                              (pilish--commands-by-source source)))
        sections)
    (dolist (scope '(("project" . "Project") ("user" . "User")
                     ("path" . "Explicit paths") (nil . "Other")))
      (when-let* ((commands (cdr (assoc (car scope) groups))))
        (push
         (pilish--startup-banner-section
          (concat "### " (cdr scope))
          (mapcar
           (lambda (command)
             (let ((name (plist-get command :name)))
               (pilish--startup-banner-item
                (if (equal source "skill")
                    (string-remove-prefix "skill:" name)
                  (concat "/" name))
                (plist-get command :path) (plist-get command :description))))
           commands))
         sections)))
    (when sections
      (concat heading "\n\n" (string-join (nreverse sections) "\n\n")))))

(defun pilish--format-startup-banner-expanded ()
  "Return Markdown session details with source links and scoped command lists."
  (pilish--propertize-startup-banner
   (string-join
    (delq nil
          (list
           (pilish--startup-banner-summary)
           (pilish--startup-banner-section
            "## Context files 📚"
            (mapcar (lambda (path)
                      (pilish--startup-banner-item
                       (pilish--route-preserving-abbreviate-file-name path) path))
                    (pilish--startup-context-files)))
           (pilish--startup-banner-commands "## Skills 🧠" "skill")
           (pilish--startup-banner-commands "## Prompts ✍️" "prompt")
           (pilish--startup-banner-commands "## Extension commands 🧩" "extension")))
    "\n\n")
   'expanded))

(defun pilish--replace-startup-banner-region (start end rendered)
  "Replace the startup banner START..END with RENDERED text.
Returns the new bounds as (START . NEW-END) and keeps visible windows
usable after the rewrite."
  (let* ((buffer (current-buffer))
         (saved-windows (pilish--capture-window-rewrite-states))
         (inhibit-read-only t)
         new-end)
    (save-excursion
      (goto-char start)
      (delete-region start end)
      (insert rendered)
      (setq new-end (point))
      (condition-case-unless-debug nil
          (font-lock-ensure start new-end)
        (error nil)))
    (pilish--restore-window-rewrite-states
     buffer
     saved-windows
     (let ((delta (- new-end end)))
       (lambda (pos)
         (pilish--adjust-pos-after-region-replacements
          pos (list (list start end delta))))))
    (cons start new-end)))

(defun pilish--toggle-startup-banner-at-point ()
  "Toggle the startup banner at point between compact and expanded.
Returns non-nil when point was on the startup banner."
  (when-let* ((probe (pilish--owned-span-probe-pos (point) 'pilish-startup-banner))
              (state (get-text-property probe 'pilish-startup-banner)))
    (let* ((original-pos (point))
           (start (or (previous-single-property-change
                       (1+ probe) 'pilish-startup-banner)
                      (point-min)))
           (end (next-single-property-change
                 probe 'pilish-startup-banner nil (point-max)))
           (rendered (if (eq state 'expanded)
                         (pilish--format-startup-banner-compact)
                       (pilish--format-startup-banner-expanded)))
           (new-bounds (pilish--replace-startup-banner-region
                        start end rendered)))
      (goto-char (max (car new-bounds)
                      (min original-pos (1- (cdr new-bounds)))))
      t)))

(defun pilish--insert-rendered-tool-content (content lang is-edit-diff)
  "Insert CONTENT rendered for LANG with a trailing newline.
When IS-EDIT-DIFF is non-nil, apply diff overlays to the inserted block."
  (let ((content-start (point)))
    (insert (pilish--wrap-in-src-block content lang) "\n")
    (when is-edit-diff
      (pilish--apply-diff-overlays content-start (point)))))

(defun pilish--tool-hidden-line-label (hidden-count)
  "Return the plain display label for HIDDEN-COUNT hidden lines.
Cold text keeps this inert historical hint."
  (format "... (%d more lines)" hidden-count))

(defun pilish--insert-tool-content-with-toggle
    (preview-content full-content lang is-edit-diff hidden-count expanded)
  "Insert the real Output button before its selected content.
EXPANDED selects FULL-CONTENT or PREVIEW-CONTENT.  LANG and IS-EDIT-DIFF
retain rich rendering.  HIDDEN-COUNT is the existing cold excerpt diagnostic."
  (let* ((start (point))
         (display-content (if expanded
                              (string-trim-right full-content "\n+")
                            preview-content))
         (button-label (propertize "Output" 'face 'pilish-collapsed-indicator)))
    (insert-text-button
     button-label
     'action #'pilish--toggle-tool-output
     'keymap pilish--tool-button-map
     'follow-link t
     'pilish-tool-toggle t
     'pilish-full-content full-content
     'pilish-preview-content preview-content
     'pilish-lang lang
     'pilish-is-edit-diff is-edit-diff
     'pilish-expanded expanded
     'hidden-count hidden-count)
    (insert "\n")
    (put-text-property start (point) 'pilish-tool-fold-heading t)
    (pilish--put-disclosure start (point) expanded
                           #'pilish--toggle-tool-fold-button-at-point)
    (pilish--insert-rendered-tool-content display-content lang is-edit-diff)
    (put-text-property start (point) 'pilish-tool-section 'output)))

(defun pilish--find-tool-block-bounds ()
  "Find the bounds of the tool block at point.
Returns (START . END) if inside a tool block, nil otherwise."
  (let ((overlays (overlays-at (point))))
    (when-let* ((ov (seq-find (lambda (o) (overlay-get o 'pilish-tool-block)) overlays)))
      (cons (overlay-start ov) (overlay-end ov)))))

(defun pilish--find-toggle-button-in-region (start end &optional section)
  "Find a toggle button between START and END, optionally for SECTION."
  (save-excursion
    (goto-char start)
    (let ((found nil))
      (while (and (not found) (< (point) end))
        (let ((btn (button-at (point))))
          (if (and btn (button-get btn 'pilish-tool-toggle)
                   (or (null section) (equal section (button-get btn 'pilish-tool-section))))
              (setq found btn)
            (forward-char 1))))
      found)))

(defun pilish-toggle-tool-section ()
  "Toggle the section at point.
The startup banner toggles first, then completed thinking blocks, then
argument controls, then tool output blocks, then the command falls back
to `outline-cycle' for turn folding."
  (interactive)
  (unless (pilish--toggle-startup-banner-at-point)
    (unless (pilish--toggle-thinking-block-at-point)
      (unless (pilish--toggle-tool-argument-at-point)
        (if-let* ((bounds (pilish--find-tool-block-bounds)))
            (if-let* ((overlay (pilish--tool-overlay-at-point))
                      (block (pilish--tool-block-from-overlay overlay))
                      ((pilish--tool-block-compound-p block)))
                (let ((section (or (get-text-property (point) 'pilish-tool-section)
                                   (and (pilish--compound-tool-code block) 'script)
                                   (and (pilish--tool-block-nested-calls block) 'children)
                                   'output)))
                  (when-let* ((button (pilish--find-toggle-button-in-region
                                      (car bounds) (cdr bounds) section)))
                    (button-activate button)))
              (if-let* ((btn (pilish--find-toggle-button-in-region
                              (car bounds) (cdr bounds))))
                  (pilish--toggle-tool-output btn)
                (outline-cycle)))
          (outline-cycle))))))

;;;; Tool Block Cooling
;;
;; Completed tool blocks outside the hot tail (older than the most
;; recent `pilish-hot-tail-turn-count' headed turns) are
;; cooled into plain text.  Live agent-end handling queues one block per
;; timer turn; history replay keeps synchronous cooling after invalidating
;; stale queued work.  The cold form keeps the header, visible preview, and
;; lightweight authoritative target metadata, but drops overlays, buttons,
;; full-content payloads, and syntax-tagged rendering.

(defconst pilish--tool-cooling-delay 0.05
  "Seconds between deferred rewrites of completed tool blocks.
A small nonzero delay gives input and redisplay a chance to run between
expensive Markdown-changing rewrites.  Internal constant, not a user option.")

(defvar-local pilish--tool-cooling-queue nil
  "Completed tool overlays awaiting deferred cold-history rewrites.
Candidates are ordered from the end of the buffer backward and are
revalidated immediately before each rewrite.")

(defvar-local pilish--tool-cooling-timer nil
  "The one owned one-shot timer for deferred tool cooling, or nil.")

(defvar-local pilish--tool-cooling-generation 0
  "Generation owning the current deferred tool-cooling queue.
Cancellation increments this value so already-dispatched callbacks cannot
act on rebuilt history or a newer queue.")

(defun pilish--ensure-cold-tool-property-nonsticky ()
  "Keep cold tool authority from spreading across insertion boundaries."
  (unless (eq t (alist-get 'pilish-cold-tool-block
                           text-property-default-nonsticky))
    (setq-local text-property-default-nonsticky
                (cons '(pilish-cold-tool-block . t)
                      (assq-delete-all
                       'pilish-cold-tool-block
                       (copy-sequence text-property-default-nonsticky))))))

(defun pilish--tool-overlay-live-p (overlay)
  "Return non-nil when OVERLAY's tool block is still in the live registry."
  (when-let* ((rec (overlay-get overlay 'pilish-tool-block-record))
              (id (pilish--tool-block-tool-call-id rec)))
    (pilish--tool-block-get id)))

(defun pilish--completed-tool-overlay-p (overlay)
  "Return non-nil when OVERLAY is a completed (finalized) tool block.
Live tool blocks that are still executing are excluded."
  (and (overlayp overlay)
       (overlay-buffer overlay)
       (overlay-get overlay 'pilish-tool-block)
       (not (eq overlay pilish--pending-tool-overlay))
       (not (pilish--tool-overlay-live-p overlay))
       (not (and pilish--toolcall-streams
                 (cl-loop for stream being the hash-values of pilish--toolcall-streams
                          thereis (when-let* ((block (pilish--tool-stream-block stream)))
                                    (eq overlay (pilish--tool-block-overlay block))))))
       (not (pilish--nested-pending-p
             (pilish--tool-block-from-overlay overlay)))
       (overlay-get overlay 'pilish-header-end)))

(defun pilish--completed-tool-overlay-before-p (overlay boundary)
  "Return non-nil when tool OVERLAY is completed and before BOUNDARY."
  (and (pilish--completed-tool-overlay-p overlay)
       (< (overlay-start overlay) boundary)))

(defun pilish--tool-overlays-in-reverse-order (overlays)
  "Return a copy of tool OVERLAYS ordered from buffer end backward."
  (sort (copy-sequence overlays)
        (lambda (a b)
          (> (overlay-start a) (overlay-start b)))))

(defun pilish--tool-cooling-boundary ()
  "Return the current usable hot-tail boundary, or nil.
A boundary at `point-min' leaves the whole buffer hot."
  (when (and (markerp pilish--hot-tail-start)
             (eq (marker-buffer pilish--hot-tail-start)
                 (current-buffer))
             (> (marker-position pilish--hot-tail-start) (point-min)))
    (marker-position pilish--hot-tail-start)))

(defun pilish--completed-tool-overlays-outside-hot-tail ()
  "Return completed tool overlays before the current hot-tail boundary.
The result is ordered from the end of the buffer backward."
  (when-let* ((boundary (pilish--tool-cooling-boundary)))
    (pilish--tool-overlays-in-reverse-order
     (seq-filter
      (lambda (overlay)
        (pilish--completed-tool-overlay-before-p overlay boundary))
      (overlays-in (point-min) boundary)))))

(defun pilish--tool-fenced-content-bounds (start end)
  "Return the tool wrapper's content bounds within START..END, or nil.
Skip only a declared heading prefix, never arbitrary output before a fence.
Exclude the wrapper newline immediately before the closing fence."
  (save-excursion
    (goto-char start)
    (when (and (< start end) (get-text-property start 'pilish-tool-fold-heading))
      (goto-char (next-single-property-change start 'pilish-tool-fold-heading nil end)))
    (when-let* (((< (point) end))
                (opening-fence (pilish--fence-line-info-at-point)))
      (forward-line 1)
      (let ((content-start (point))
            (closing-start nil))
        (while (and (not closing-start) (< (point) end))
          (let ((line-info (pilish--fence-line-info-at-point)))
            (when (pilish--fence-closing-line-p opening-fence line-info)
              (setq closing-start (line-beginning-position))))
          (unless closing-start
            (forward-line 1)))
        (when closing-start
          (cons content-start
                (if (and (> closing-start content-start)
                         (eq (char-before closing-start) ?\n))
                    (1- closing-start)
                  closing-start)))))))

(defun pilish--tool-overlay-visible-body (overlay)
  "Return the currently visible body text for completed tool OVERLAY.
Extracts the text between the outer fence lines, removing only the
wrapper newline inserted before the closing fence.  Collapsed blocks
therefore cool into their visible preview only."
  (when-let* ((header-end-marker (overlay-get overlay 'pilish-header-end))
              (header-end (and (markerp header-end-marker)
                               (marker-position header-end-marker)))
              (overlay-end (overlay-end overlay))
              (bounds (pilish--tool-fenced-content-bounds header-end overlay-end)))
    (let* ((source (buffer-substring (car bounds) (cdr bounds)))
           (cold (substring-no-properties source))
           (position 0))
      (while (< position (length source))
        (let ((next (next-single-property-change position 'pilish-subagent-name source (length source)))
              (value (get-text-property position 'pilish-subagent-name source)))
          (when value (put-text-property position next 'pilish-subagent-name value cold))
          (setq position next)))
      cold)))

(defun pilish--cold-tool-target-metadata
    (overlay header-end collapsed)
  "Return lightweight target metadata for cold tool OVERLAY.
HEADER-END is the current absolute end of its header.  COLLAPSED is non-nil
when the visible body is a mapped preview.  The result deliberately excludes
buttons, full content, markers, and absolute buffer positions."
  (let ((record (pilish--tool-block-from-overlay overlay)))
    (list :order (and record (pilish--tool-block-order record))
          :tool-name (overlay-get overlay 'pilish-tool-name)
          :path (overlay-get overlay 'pilish-tool-path)
          :raw-path (overlay-get overlay 'pilish-tool-raw-path)
          :path-error (overlay-get overlay 'pilish-tool-path-error)
          :offset (overlay-get overlay 'pilish-tool-offset)
          ;; Only collapsed previews need the small visible-line map.
          :line-map (and collapsed
                         (overlay-get overlay 'pilish-line-map))
          :header-length (- header-end (overlay-start overlay)))))

(defun pilish--compound-tool-cold-projection (overlay)
  "Project OVERLAY's displayed body to language-free cold text.
Return :cold-body and transient absolute :deleted-spans for view mapping."
  (let* ((start (marker-position (overlay-get overlay 'pilish-header-end)))
         (end (overlay-end overlay))
         (body (buffer-substring start end))
         (cold (substring-no-properties body))
         language-spans)
    (dolist (property '(pilish-tool-section pilish-nested-summary pilish-nested-root-id
                       pilish-nested-call-id pilish-image-preview pilish-tool-diagnostic-guard
                       pilish-no-fontify pilish-subagent-name pilish-tool-fold-heading
                       pilish-argument-guard pilish-argument-value pilish-argument-literal
                       line-prefix wrap-prefix))
      (let ((position 0))
        (while (< position (length body))
          (let ((next (next-single-property-change position property body (length body)))
                (value (get-text-property position property body)))
            (when value (put-text-property position next property value cold))
            (setq position next)))))
    (dolist (property '(pilish-argument-guard pilish-tool-diagnostic-guard pilish-argument-literal))
      (let ((position 0))
        (while (< position (length body))
          (let ((next (next-single-property-change position property body (length body))))
            (when (get-text-property position property body)
              (if (memq property '(pilish-argument-guard pilish-tool-diagnostic-guard))
                  (put-text-property position next 'display "" cold)
                (let ((face-pos position))
                  (while (< face-pos next)
                    (let ((face-end (next-single-property-change face-pos 'font-lock-face body next))
                          (face (get-text-property face-pos 'font-lock-face body)))
                      (when face (put-text-property face-pos face-end 'font-lock-face face cold))
                      (setq face-pos face-end))))))
            (setq position next)))))
    ;; Image placeholders keep the same graphical/terminal representation.
    (let ((position 0))
      (while (< position (length body))
        (let ((next (next-single-property-change position 'pilish-image-preview body (length body))))
          (when (get-text-property position 'pilish-image-preview body)
            (dolist (property '(display face fontified rear-nonsticky help-echo))
              (put-text-property position next property (get-text-property position property body) cold)))
          (setq position next))))
    (save-excursion
      (goto-char start)
      (let (fence)
        (while (< (point) end)
          (let ((info (pilish--fence-line-info-at-point)))
            (cond
             (fence (when (pilish--fence-closing-line-p fence info) (setq fence nil)))
             (info
              (setq fence info)
              (let ((language-length (length (plist-get info :trailing))))
                (when (> language-length 0)
                  (push (cons (- (line-end-position) language-length start)
                              (- (line-end-position) start)) language-spans))))))
          (forward-line 1))))
    ;; Spans are already in reverse order, so earlier offsets stay valid.
    (dolist (span language-spans)
      (setq cold (concat (substring cold 0 (car span)) (substring cold (cdr span)))))
    (list :cold-body cold
          :deleted-spans (mapcar (lambda (span)
                                   (cons (+ start (car span)) (+ start (cdr span))))
                                 language-spans))))

(defun pilish--tool-overlay-cold-metadata (overlay)
  "Return cold-history metadata for completed tool OVERLAY.
The result carries its visible body, lightweight target metadata and, for a
currently collapsed block, its hidden count.  Expanded blocks return no hidden
count because cold history must stay preview-only.  Header-only blocks keep
an empty :cold-body without inventing output.  Compound blocks instead freeze
their entire currently displayed body in :cold-body."
  (if-let* ((block (pilish--tool-block-from-overlay overlay))
            ((pilish--tool-block-compound-p block)))
      (append (pilish--compound-tool-cold-projection overlay)
              (list :target-metadata
                    (pilish--cold-tool-target-metadata
                     overlay (marker-position (pilish--tool-block-header-end block))
                     (not (member 'output (pilish--tool-block-folds block))))))
    (if-let* ((header-end (marker-position (overlay-get overlay 'pilish-header-end)))
              (end (overlay-end overlay))
              ((or (= header-end end)
                   (and block (pilish--tool-block-image-previews block)
                        (not (pilish--tool-fenced-content-bounds header-end end))))))
        (list :cold-body (or (and block (pilish--image-previews-text
                                        (pilish--tool-block-image-previews block))) "")
              :target-metadata (pilish--cold-tool-target-metadata overlay header-end nil))
      (when-let* ((visible-body (pilish--tool-overlay-visible-body overlay))
                  (header-end (marker-position
                               (overlay-get overlay 'pilish-header-end))))
        (let* ((record (pilish--tool-block-from-overlay overlay))
               (image-previews (and record (pilish--tool-block-image-previews record)))
               (button (pilish--find-toggle-button-in-region header-end (overlay-end overlay)))
               (collapsed (and button (not (button-get button 'pilish-expanded))))
               (hidden-count (and collapsed (button-get button 'hidden-count))))
          (list :visible-body visible-body
                :deleted-spans
                (save-excursion
                  (goto-char (car (pilish--tool-fenced-content-bounds header-end (overlay-end overlay))))
                  (forward-line -1)
                  (let ((length (length (plist-get (pilish--fence-line-info-at-point) :trailing))))
                    (when (> length 0)
                      (list (cons (- (line-end-position) length) (line-end-position))))))
                :heading (when (get-text-property header-end 'pilish-tool-fold-heading)
                           (propertize
                            (buffer-substring-no-properties
                             header-end (next-single-property-change
                                         header-end 'pilish-tool-fold-heading nil (overlay-end overlay)))
                            'pilish-tool-fold-heading t 'pilish-tool-section 'output))
                :image-previews image-previews
                :target-metadata
                (pilish--cold-tool-target-metadata overlay header-end collapsed)
                :hidden-count (and (integerp hidden-count) (> hidden-count 0) hidden-count)))))))

(defun pilish--cool-tool-overlay (overlay)
  "Rewrite completed tool OVERLAY into its cold plain-history form.
Argument controls are released first so cold metadata sees the exact
final header and visible text.
Return the applied projection metadata, or nil if ineligible."
  (when (pilish--completed-tool-overlay-p overlay)
    (pilish--argument-release-cold (pilish--tool-block-from-overlay overlay))
    (when-let* ((metadata (pilish--tool-overlay-cold-metadata overlay))
                (header-end (marker-position
                             (overlay-get overlay 'pilish-header-end))))
      (let* ((inhibit-read-only t)
             (hidden-count (plist-get metadata :hidden-count))
             (image-previews (plist-get metadata :image-previews))
             (target-metadata (plist-get metadata :target-metadata))
             (cold-body (or (plist-get metadata :cold-body)
                            (concat
                             (plist-get metadata :heading)
                             (pilish--wrap-in-src-block (plist-get metadata :visible-body) nil)
                             "\n"
                             (pilish--image-previews-text image-previews)
                             (when hidden-count
                               (concat (pilish--tool-hidden-line-label hidden-count) "\n")))))
             (ov-start (overlay-start overlay))
             (ov-end (overlay-end overlay))
             (record (pilish--tool-block-from-overlay overlay))
             (details (and record (pilish--tool-block-details record))))
        (remove-overlays ov-start ov-end 'pilish-diff-overlay t)
        (remove-text-properties
         ov-start ov-end '(pilish-cold-tool-block nil))
        (delete-overlay overlay)
        (save-excursion
          (goto-char header-end)
          (delete-region header-end ov-end)
          (insert cold-body)
          (pilish--ensure-cold-tool-property-nonsticky)
          (add-text-properties
           ov-start (point)
           `(pilish-cold-tool-block ,target-metadata))
          (when details
            (pilish--set-details ov-start (point) details))
          (pilish--restore-subagent-buttons ov-start (point)))
        (when (and record (pilish--tool-block-compound-p record))
          (pilish--release-nested-tool-block record))
        metadata))))

(defun pilish--cool-completed-tool-blocks (overlays)
  "Cool the given completed tool OVERLAYS.
Blocks are processed from the end of the buffer backward so region
rewrites do not disturb remaining candidates."
  (let ((sorted
         (pilish--tool-overlays-in-reverse-order
          (seq-filter #'pilish--completed-tool-overlay-p overlays))))
    (pilish--with-scroll-preservation
      (save-excursion
        (dolist (overlay sorted)
          (pilish--cool-tool-overlay overlay))))))

(defun pilish--cool-completed-tool-blocks-outside-hot-tail ()
  "Synchronously cool completed tool blocks before the hot-tail boundary.
Uses the same `pilish--hot-tail-start' marker that tables use for
resize scope.  History replay uses this synchronous path after cancelling
stale deferred work; live agent_end handling uses the deferred queue."
  (when-let* ((cold-overlays
              (pilish--completed-tool-overlays-outside-hot-tail)))
    (pilish--cool-completed-tool-blocks cold-overlays)))

(defun pilish--cancel-tool-cooling ()
  "Cancel and invalidate deferred completed-tool cooling.
The operation is idempotent with respect to owned work.  Its generation
always advances so a callback already dispatched by Emacs becomes stale."
  (when (timerp pilish--tool-cooling-timer)
    (cancel-timer pilish--tool-cooling-timer))
  (setq pilish--tool-cooling-timer nil
        pilish--tool-cooling-queue nil
        pilish--tool-cooling-generation
        (1+ pilish--tool-cooling-generation)))

(defun pilish--fail-tool-cooling (error-data)
  "Fail closed after deferred cooling ERROR-DATA.
Owned work is invalidated before reporting the failure, preventing an error
from leaving a retry loop or wedged timer slot."
  (pilish--cancel-tool-cooling)
  (display-warning
   'pilish
   (format "Deferred tool block cooling failed: %s"
           (error-message-string error-data))
   :error))

(defun pilish--schedule-tool-cooling ()
  "Arm one deferred tool-cooling slice when work lacks an owner."
  (when (and pilish--tool-cooling-queue
             (not pilish--tool-cooling-timer))
    (setq pilish--tool-cooling-timer
          (run-at-time pilish--tool-cooling-delay nil
                       #'pilish--run-tool-cooling-slice
                       (current-buffer)
                       pilish--tool-cooling-generation))))

(defun pilish--queue-tool-cooling-outside-hot-tail ()
  "Merge the current outside-hot-tail cohort into deferred cooling.
Existing candidates are deduplicated and retain one buffer-local timer owner.
Newly eligible overlays take their normal reverse-buffer order; stale queued
entries remain at the end for execution-time revalidation."
  (let ((candidates
         (pilish--completed-tool-overlays-outside-hot-tail))
        merged)
    (dolist (overlay (append candidates pilish--tool-cooling-queue))
      (unless (memq overlay merged)
        (push overlay merged)))
    (setq pilish--tool-cooling-queue (nreverse merged))
    (pilish--schedule-tool-cooling)))

(defun pilish--map-tool-cooling-position
    (position old-start old-end new-end)
  "Map POSITION through one tool-body replacement.
OLD-START and OLD-END delimit the old half-open body range; NEW-END is the
new body end and the body start is unchanged.  Positions before the body stay
fixed.  Positions in the old body retain their relative offset, clamped to the
new body end.  Positions at or after OLD-END shift by the actual length delta."
  (cond
   ((< position old-start)
    position)
   ((< position old-end)
    (+ old-start
       (min (- position old-start)
            (- new-end old-start))))
   (t
    (+ position (- new-end old-end)))))

(defun pilish--capture-tool-cooling-view ()
  "Capture buffer point and visible-window positions before tool cooling.
Every position is mapped through explicit replacement bounds.
During transcript construction, capture only buffer point."
  (list
   :point (point)
   :windows
   (unless (pilish--viewport-updates-deferred-p)
     (mapcar
      (lambda (window)
        (list :window window
              :following (pilish--window-following-p window)
              :start (window-start window)
              :point (window-point window)))
      (get-buffer-window-list (current-buffer) nil t)))))

(defun pilish--restore-tool-cooling-view
    (view old-start old-end new-end &optional map-position)
  "Restore cooling VIEW through the body replacement bounds.
OLD-START and OLD-END are the old body bounds and NEW-END is its new end.
Every live window still showing the current buffer gets mapped start and point;
a window that was following the tail instead gets point at the new buffer end.
The buffer's own point is mapped too.  Optional MAP-POSITION supplies a
section-aware old-position to new-position mapping."
  (let ((map-position
         (or map-position
             (lambda (position)
               (pilish--map-tool-cooling-position
                position old-start old-end new-end)))))
    ;; Restore buffer point first.  A selected chat window restored below then
    ;; establishes the same mapped point, or point-max when it was following.
    (goto-char (funcall map-position (plist-get view :point)))
    (dolist (window-state (plist-get view :windows))
      (let ((window (plist-get window-state :window)))
        (when (and (window-live-p window)
                   (eq (window-buffer window) (current-buffer)))
          (set-window-start
           window
           (funcall map-position (plist-get window-state :start))
           t)
          (set-window-point
           window
           (if (plist-get window-state :following)
               (point-max)
             (funcall map-position
                      (plist-get window-state :point)))))))))

(defun pilish--cool-tool-overlay-preserving-view (overlay)
  "Cool completed tool OVERLAY while mapping visible view positions.
Argument controls are released before the viewport snapshot so captured
positions describe the final cold text.  The header stays in place, so
only the replaced body bounds participate in the mapping.  Return
non-nil when the rewrite succeeds."
  (when (pilish--completed-tool-overlay-p overlay)
    (pilish--argument-release-cold (pilish--tool-block-from-overlay overlay)))
  (let* ((header-end-marker
          (overlay-get overlay 'pilish-header-end))
         (old-start (and (markerp header-end-marker)
                         (marker-position header-end-marker)))
         (old-end (overlay-end overlay)))
    (if (not (and old-start old-end (<= old-start old-end)))
        (pilish--cool-tool-overlay overlay)
      (let ((view (pilish--capture-tool-cooling-view))
            ;; The primitive deletes at OLD-START, then inserts there.  This
            ;; rear-advancing marker stays at the deletion boundary and moves
            ;; across exactly the newly inserted body.
            (new-end-marker (copy-marker old-start t)))
        (unwind-protect
            (when-let* ((metadata (pilish--cool-tool-overlay overlay)))
              (let ((spans (plist-get metadata :deleted-spans)))
                (pilish--restore-tool-cooling-view
                 view old-start old-end (marker-position new-end-marker)
                 (when spans
                   (lambda (position)
                     (if (>= position old-end)
                         (pilish--map-tool-cooling-position
                          position old-start old-end (marker-position new-end-marker))
                       (- position
                          (cl-loop for (beg . end) in spans
                                   sum (max 0 (- (min position end) beg)))))))))
              t)
          (set-marker new-end-marker nil))))))

(defun pilish--run-tool-cooling-slice (buffer generation)
  "Cool at most one queued tool overlay in BUFFER for GENERATION.
This is the ordinary one-shot timer callback.  Current input wins without
queue progress.  Otherwise one candidate is removed, revalidated as completed,
current-buffer-owned, and still outside the live hot-tail boundary, then passed
to the unchanged cold rewrite primitive with cooling-specific view mapping.
Timer ownership is cleared before input checks, mutation, or rearming."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (= generation pilish--tool-cooling-generation)
        (setq pilish--tool-cooling-timer nil)
        (condition-case error-data
            (if (input-pending-p)
                (pilish--schedule-tool-cooling)
              (when-let* ((overlay (pop pilish--tool-cooling-queue)))
                (when-let* ((boundary (pilish--tool-cooling-boundary)))
                  (when (pilish--completed-tool-overlay-before-p
                         overlay boundary)
                    (pilish--cool-tool-overlay-preserving-view
                     overlay)))
                (pilish--schedule-tool-cooling)))
          (quit
           ;; C-g is user intent: pending cooling is discarded silently and
           ;; the quit resignals; errors, by contrast, fail loudly below.
           (pilish--cancel-tool-cooling)
           (signal (car error-data) (cdr error-data)))
          (error
           (pilish--fail-tool-cooling error-data)))))))

;;;; File Navigation

(defun pilish--positive-location-p (value)
  "Return non-nil when VALUE is a positive one-based integer."
  (and (integerp value) (> value 0)))

(defun pilish--diff-line-at-point ()
  "Extract line number from diff line at point.
Returns the line number if point is on an added, removed, or context
line, nil otherwise.
Diff format: [+- ] LINENUM content.
For example: '+ 7     code', '-12     code', or '  9     context'."
  (save-excursion
    (beginning-of-line)
    (when (looking-at "^[ +-] *\\([1-9][0-9]*\\)\\(?:[ \t]+\\|$\\)")
      (string-to-number (match-string 1)))))

(defun pilish--fence-line-info-at-point ()
  "Return fence info for current line, or nil when not on a fence line.
Return value is plist `(:char CHAR :len LEN :trailing TEXT)'.
TEXT is everything after the fence run on this line.
Only recognizes fences indented by at most three spaces."
  (save-excursion
    (beginning-of-line)
    (let ((indent-start (point)))
      (skip-chars-forward " ")
      (let ((indent (- (point) indent-start))
            (char (char-after)))
        (when (and (<= indent 3)
                   (memq char '(?` ?~)))
          (let ((start (point)))
            (skip-chars-forward (char-to-string char))
            (let ((len (- (point) start)))
              (when (>= len 3)
                (list :char char
                      :len len
                      :trailing (buffer-substring-no-properties
                                 (point) (line-end-position)))))))))))

(defun pilish--fence-closing-line-p (fence line-info)
  "Return non-nil when LINE-INFO closes FENCE.
FENCE and LINE-INFO are plists from
`pilish--fence-line-info-at-point'."
  (and line-info
       (= (plist-get line-info :char) (plist-get fence :char))
       (>= (plist-get line-info :len) (plist-get fence :len))
       (string-match-p "^[ \t]*$" (plist-get line-info :trailing))))

(defun pilish--tool-overlay-collapsed-p (overlay)
  "Return non-nil when OVERLAY is currently collapsed.
Collapsed tool blocks contain a toggle button whose
`pilish-expanded' property is nil.  Expanded blocks and
non-collapsible blocks return nil."
  (when-let* ((btn (pilish--find-toggle-button-in-region
                   (overlay-start overlay)
                   (overlay-end overlay))))
    (not (button-get btn 'pilish-expanded))))

(defun pilish--tool-line-from-metadata
    (tool-name stored-offset line-map header-end body-end use-line-map)
  "Calculate the file line at point within HEADER-END..BODY-END.
TOOL-NAME and STORED-OFFSET identify tool semantics.  With USE-LINE-MAP,
LINE-MAP indexes real content rows, excluding declared headings and fences.
Invalid offsets and positions outside content have no source line."
  (when-let* ((header-end header-end)
              (body-end body-end)
              (bounds (pilish--tool-fenced-content-bounds header-end body-end))
              ((<= (car bounds) (point)))
              ((<= (point) (cdr bounds)))
              ((< (car bounds) (cdr bounds))))
    (if (equal tool-name "edit")
        (pilish--diff-line-at-point)
      (when-let* ((offset (cond
                          ((not (equal tool-name "read")) 1)
                          ((null stored-offset) 1)
                          ((pilish--positive-location-p stored-offset) stored-offset))))
        (let* ((index (- (line-number-at-pos) (line-number-at-pos (car bounds))))
               (source (if (and use-line-map line-map)
                           (and (< index (length line-map)) (aref line-map index))
                         (1+ index))))
          (when (pilish--positive-location-p source)
            (+ source (1- offset))))))))

(defun pilish--tool-line-at-point (overlay)
  "Calculate the physical file line at point for hot tool OVERLAY.
Any chat restriction is restored exactly after the authoritative lookup."
  (save-restriction
    (widen)
    (let ((line-map (overlay-get overlay 'pilish-line-map))
          (header-end (overlay-get overlay 'pilish-header-end)))
      (pilish--tool-line-from-metadata
       (overlay-get overlay 'pilish-tool-name)
       (overlay-get overlay 'pilish-tool-offset)
       line-map
       header-end (overlay-end overlay)
       (and line-map header-end
            (pilish--tool-overlay-collapsed-p overlay))))))

(cl-defun pilish--make-file-target
    (source raw emacs-path &key line column range bounds fragment label)
  "Return a resolved file target for SOURCE and RAW candidate.
EMACS-PATH is the normalized local or TRAMP path for Emacs operations.
The returned plist has this contract:

  `:source'     is `:tool', `:link', or `:text';
  `:raw'        is the original metadata, link destination, or text candidate;
  `:display'    is that candidate escaped for prompts and messages;
  `:emacs-path' is the normalized path for Emacs file operations;
  `:shell-path' is the unquoted path in the local or TRAMP shell namespace;
  `:shell-path-error' explains why no safe shell path can be represented;
  `:shell-directory' is the canonical directory selecting that shell host;
  `:line', `:column', and `:range' are optional source locations;
  `:bounds'     is an optional cons of buffer positions;
  `:fragment'   is an optional local-link fragment, outside filesystem paths;
  `:label'      is an optional control-safe Markdown link label.

Keyword arguments LINE, COLUMN, RANGE, BOUNDS, FRAGMENT, and LABEL supply those
fields.  Representable shell paths are absolute or remote-home-rooted, so
leading-dash relative names cannot become options.  A shell-only conversion
error is stored
rather than signaled, leaving `:emacs-path' usable by Emacs-only consumers.
Shell consumers must use `pilish--file-target-shell-path' or the
exactly-once quoted `pilish--file-target-shell-argument'; `:shell-path'
is not command text.  Constructing a target does not check file existence."
  (let ((anchor (pilish--chat-session-directory))
        shell-path shell-path-error)
    (condition-case err
        (setq shell-path
              (pilish--shell-command-path emacs-path anchor))
      (user-error
       (setq shell-path-error (error-message-string err))))
    (list :source source
          :raw raw
          :display (pilish--escape-control-chars-for-display raw)
          :emacs-path emacs-path
          :shell-path shell-path
          :shell-path-error shell-path-error
          :shell-directory anchor
          :line line
          :column column
          :range range
          :bounds bounds
          :fragment fragment
          :label label)))

(defun pilish--file-target-shell-path (target)
  "Return TARGET's unquoted shell-local path, or signal `user-error'.
Shell conversion failures are delayed until this shell-action boundary so
Emacs-only target consumers can always use a valid `:emacs-path'."
  (or (plist-get target :shell-path)
      (user-error "%s" (or (plist-get target :shell-path-error)
                            "File target has no shell path"))))

(defun pilish--file-target-shell-argument (target)
  "Return TARGET safely quoted exactly once as one shell operand.
The result is suitable for a `shell-command' run with TARGET's
`:shell-directory' as `default-directory'."
  (pilish--shell-quote-path
   (pilish--file-target-shell-path target)
   (plist-get target :shell-directory)))

(defun pilish--isolated-shell-star-p (command index)
  "Return non-nil when COMMAND has an isolated `*' at INDEX.
This is Dired's shell-agnostic textual rule: both neighbors must independently
be a string edge, an ASCII space, or a tab.  Quotes and backslashes have no
special meaning; explicit marker placement is the user's responsibility."
  (and (eq (aref command index) ?*)
       (or (zerop index)
           (memq (aref command (1- index)) '(?\s ?\t)))
       (or (= (1+ index) (length command))
           (memq (aref command (1+ index)) '(?\s ?\t)))))

(defun pilish--simple-shell-command-p (body)
  "Return non-nil when BODY is safe for automatic file-argument appending.
This is an explicit fail-closed ASCII whitelist, not a shell parser:

  BODY := H* COMMAND (H+ OPTION)* H*
  H := ASCII space or tab
  COMMAND := one or more of A-Z a-z 0-9 _ + . / -,
             containing at least one of A-Z a-z 0-9 _ and not being a
             path metatoken such as `.`, `..`, or `/`
  OPTION := `-` followed by one or more of A-Z a-z 0-9 _ + . / : = , -

Thus ordinary commands such as `file`, `cat`, `wc -l`, and path-like command
words are accepted.  Arguments other than options, controls, non-ASCII space,
quotes, escapes, comments, redirections, substitutions, and globs are rejected."
  (when (and
         (stringp body)
         (string-match
          (concat "\\`[ \t]*\\([A-Za-z0-9_+./-]+\\)"
                  "\\(?:[ \t]+-[A-Za-z0-9_+./:=,-]+\\)*"
                  "[ \t]*\\'")
          body))
    (let ((command (match-string 1 body)))
      (and (string-match-p "[A-Za-z0-9_]" command)
           (not (member command '("." ".." "/" "./" "../" "-" "--")))))))

(defun pilish--terminal-shell-async-start (command)
  "Return start of COMMAND's narrow native async suffix, or nil.
The suffix is one ampersand preceded by one or more ASCII spaces or tabs and
followed only by ASCII spaces or tabs.  Scan backward once so malformed long
near-suffixes cannot cause regular-expression backtracking."
  (let ((index (length command)))
    (while (and (> index 0)
                (memq (aref command (1- index)) '(?\s ?\t)))
      (setq index (1- index)))
    (when (and (> index 0)
               (eq (aref command (1- index)) ?&))
      (let ((ampersand (1- index)))
        (setq index ampersand)
        (while (and (> index 0)
                    (memq (aref command (1- index)) '(?\s ?\t)))
          (setq index (1- index)))
        (and (< index ampersand) index)))))

(defun pilish--shell-command-with-file (command argument)
  "Return validated COMMAND with already-quoted file ARGUMENT supplied.
ARGUMENT is safe shell text and is never quoted again.  Every `*' with
string-edge, ASCII-space, or tab boundaries on both sides is replaced linearly;
quotes and escapes do not alter this Dired-style textual marker grammar.  A
marker permits explicit compound, control, and multiline shell syntax.

Without a marker, append ARGUMENT only when the body satisfies
`pilish--simple-shell-command-p'.  Recognize asynchronous execution
only as one terminal ` &' suffix whose ampersand is preceded by ASCII space or
tab; strip that suffix before substitution and validation, then reattach it.
Reject blank bodies and any other raw terminal ampersand before `shell-command'
can classify it asynchronously."
  (let ((async-start (pilish--terminal-shell-async-start command))
        async-suffix)
    (when async-start
      (setq async-suffix (substring command async-start)
            command (substring command 0 async-start)))
    (when (or (string-match-p "\\`[ \t]*\\'" command)
              (and (not async-suffix)
                   (string-match-p "\\`[ \t]*&[ \t]*\\'" command)))
      (user-error "Shell command cannot be empty"))
    (let ((index 0)
          (last 0)
          (marker-p nil)
          parts)
      (while (< index (length command))
        (when (and (eq (aref command index) ?*)
                   (pilish--isolated-shell-star-p command index))
          (setq marker-p t)
          (push (substring command last index) parts)
          (push argument parts)
          (setq last (1+ index)))
        (setq index (1+ index)))
      (let ((body
             (if marker-p
                 (progn
                   (push (substring command last) parts)
                   (apply #'concat (nreverse parts)))
               (unless (pilish--simple-shell-command-p command)
                 (user-error
                  (concat "Compound shell commands require an isolated * "
                          "file placeholder")))
               (concat command " " argument))))
        (when (string-match-p "&[ \t]*\\'" body)
          (user-error
           "Ambiguous terminal ampersand; use a terminal ` &' suffix"))
        (concat body async-suffix)))))

(defun pilish--strict-text-file-path-p (path quoted)
  "Return non-nil when PATH has the strict plain-text file grammar.
PATH must be absolute, home-relative, explicitly relative with `./', or have
at least two slash-separated relative components.  When QUOTED is non-nil,
ASCII spaces are also allowed in a final component with a conventional file
extension.  This keeps the accepted quoted form narrow enough to reject common
prose and command tails.  Empty, dot, and dot-dot components are rejected."
  (when (and (stringp path) (not (string-empty-p path)))
    (let ((body (cond
                 ((string-prefix-p "./" path) (substring path 2))
                 ((string-prefix-p "~/" path) (substring path 2))
                 ((string-prefix-p "/" path) (substring path 1))
                 ((string-match-p "/" path) path))))
      (let ((components (and body (split-string body "/" nil))))
        (and body
             (not (string-empty-p body))
             (not (string-suffix-p "/" body))
             (or (not quoted)
                 (cl-every (lambda (component)
                             (not (string-match-p " " component)))
                           (butlast components)))
             (or (not quoted)
                 (not (string-match-p " " path))
                 (string-match-p
                  "\\.[[:alnum:]][-[:alnum:]_.+]*\\'"
                  (car (last components))))
             (cl-every
              (lambda (component)
                (and (not (member component '("" "." "..")))
                     (or (not quoted)
                         (equal component (string-trim component)))
                     (string-match-p
                      (if quoted
                          "\\`[-[:alnum:]_.+ ]+\\'"
                        "\\`[-[:alnum:]_.+]+\\'")
                      component)))
              components))))))

(defconst pilish--max-text-file-candidate-length 4096
  "Maximum number of characters in a plain-text file candidate.
This matches the common conservative PATH_MAX scale while bounding regexp
input, allocation, and at-point scans even for generated chat lines.  It is a
character bound because Emacs buffer and string positions count characters.")

(defconst pilish--text-file-input-radius
  (+ 2 (* 2 pilish--max-text-file-candidate-length))
  "Maximum source-text radius inspected around a file-target point.
One candidate length covers candidate text; the second retains bounded wrapper,
escape-parity, hidden-markup, and quote-authority context.")

(defun pilish--parse-text-file-candidate (raw quoted start end)
  "Parse strict plain-text file candidate RAW between START and END.
QUOTED permits spaces in the path.  START and END are caller-owned offsets
returned unchanged as `:bounds'.  Return nil unless all of RAW matches the
path grammar, optionally followed by `:LINE', `:LINE:COLUMN', or
`#LSTART-LEND'.  A `:LINE' or `:LINE:COLUMN' may itself be followed by one
terminal diagnostic-separator colon.  That separator is excluded from `:raw'
and `:bounds'; arbitrary path colons and no-space diagnostic prose remain
invalid.  Candidates longer than
`pilish--max-text-file-candidate-length' are rejected before any
regexp runs.  This pure helper performs no buffer access or file I/O."
  (when (and (stringp raw)
             (<= (length raw)
                 pilish--max-text-file-candidate-length))
    (let ((case-fold-search nil)
          (path raw)
          (candidate-raw raw)
          (candidate-end end)
          line column range diagnostic-separator)
      (cond
       ((string-match
         "\\`\\(.*\\):\\([1-9][0-9]*\\):\\([1-9][0-9]*\\)\\(:\\)?\\'"
         raw)
        (setq path (match-string 1 raw)
              line (string-to-number (match-string 2 raw))
              column (string-to-number (match-string 3 raw))
              diagnostic-separator (match-beginning 4)))
       ((string-match
         "\\`\\(.*\\):\\([1-9][0-9]*\\)\\(:\\)?\\'" raw)
        (setq path (match-string 1 raw)
              line (string-to-number (match-string 2 raw))
              diagnostic-separator (match-beginning 3)))
       ((string-match
         "\\`\\(.*\\)#L\\([1-9][0-9]*\\)-L\\([1-9][0-9]*\\)\\'" raw)
        (let ((first (string-to-number (match-string 2 raw)))
              (last (string-to-number (match-string 3 raw))))
          (when (<= first last)
            (setq path (match-string 1 raw)
                  line first
                  range (cons first last))))))
      (when diagnostic-separator
        (setq candidate-raw (substring raw 0 -1)
              candidate-end (1- end)))
      (when (and (or (not (string-match-p "#L" raw)) range)
                 (pilish--strict-text-file-path-p path quoted))
        (list :raw candidate-raw
              :path path
              :line line
              :column column
              :range range
              :diagnostic-separator (and diagnostic-separator t)
              :bounds (cons start candidate-end))))))

(defun pilish--text-file-diagnostic-context-p
    (candidate text lexical-end following-index)
  "Return non-nil when CANDIDATE has valid diagnostic context in TEXT.
Ordinary candidates always pass.  A diagnostic separator must be the actual
last character of the lexical candidate ending at LEXICAL-END, followed at
FOLLOWING-INDEX by exactly one ASCII space and non-whitespace diagnostic text.
Callers place FOLLOWING-INDEX after any authoritative quote wrapper."
  (or (not (plist-get candidate :diagnostic-separator))
      (let ((separator (cdr (plist-get candidate :bounds))))
        (and (= (1+ separator) lexical-end)
             (< (1+ following-index) (length text))
             (eq (aref text separator) ?:)
             (eq (aref text following-index) ?\s)
             (not (pilish--text-file-whitespace-p
                   (aref text (1+ following-index))))))))

(defun pilish--single-quote-boundary-p (text index opening)
  "Return non-nil when the quote at INDEX in TEXT is a wrapper boundary.
When OPENING is non-nil, accept line start, whitespace, or an opening Markdown
wrapper, emphasis runs included, before the quote.  Otherwise accept line end,
whitespace, trailing punctuation, or a closing Markdown wrapper, emphasis runs
included, after it."
  (let ((neighbor-index (if opening (1- index) (1+ index))))
    (or (< neighbor-index 0)
        (>= neighbor-index (length text))
        (memq (aref text neighbor-index)
              (string-to-list
               (if opening " \t([{<_*" " \t.,;!?)]}>_*"))))))

(defun pilish--escaped-text-quote-p (text index)
  "Return non-nil when the quote at INDEX in TEXT is backslash-escaped.
An overlong backslash run is conservatively treated as escaped."
  (let ((cursor (1- index))
        (remaining pilish--max-text-file-candidate-length)
        (slashes 0))
    (while (and (>= cursor 0) (> remaining 0)
                (eq (aref text cursor) ?\\))
      (setq slashes (1+ slashes)
            cursor (1- cursor)
            remaining (1- remaining)))
    (or (and (= remaining 0) (>= cursor 0)
             (eq (aref text cursor) ?\\))
        (cl-oddp slashes))))

(defun pilish--text-wrapper-quote-p (text index quote opening)
  "Return non-nil when TEXT at INDEX is a usable QUOTE wrapper.
OPENING selects the boundary direction.  Backslash-escaped quotes are literal.
Single quotes use prose boundaries; backticks use the same conservative
orientation, except an unescaped backtick after an even backslash run may open."
  (and (eq (aref text index) quote)
       (not (pilish--escaped-text-quote-p text index))
       (or (pilish--single-quote-boundary-p text index opening)
           (and opening (eq quote ?`) (> index 0)
                (eq (aref text (1- index)) ?\\)))))

(defun pilish--text-wrapper-bounds-at-index (text index quote)
  "Return non-crossing QUOTE wrapper bounds around INDEX in TEXT.
The returned cons excludes delimiters.  Backtick delimiter runs pair only with
runs of the same length, so ordinary Markdown double-backtick spans work while
embedded shorter runs remain content.  Single quotes remain one-character
prose wrappers.  Pairing scans only bounded TEXT from left to right.  A new
unambiguous opener supersedes an unmatched opener; a matching closer, including
a whitespace-ambiguous delimiter, closes the active opener.  Thus completed
spans on either side of INDEX cannot cross-pair, while an unrelated unmatched
earlier opener cannot poison a later local pair.  Overlong contents still
return bounds so the wrapper remains authoritative-invalid rather than exposing
an inner path token."
  (let ((cursor 0)
        (limit (length text))
        opening found)
    (while (and (not found) (< cursor limit))
      (if (or (not (eq (aref text cursor) quote))
              (pilish--escaped-text-quote-p text cursor))
          (setq cursor (1+ cursor))
        (let* ((run-start cursor)
               (run-end
                (if (eq quote ?`)
                    (progn
                      (while (and (< cursor limit)
                                  (eq (aref text cursor) quote))
                        (setq cursor (1+ cursor)))
                      cursor)
                  (1+ cursor)))
               (run-length (- run-end run-start))
               (opens (pilish--text-wrapper-quote-p
                       text run-start quote t))
               (closes (pilish--text-wrapper-quote-p
                        text (1- run-end) quote nil)))
          (cond
           ((null opening)
            (when opens
              (setq opening (list run-start run-end run-length))))
           ((and closes (= run-length (nth 2 opening)))
            (when (<= (nth 1 opening) index run-start)
              (setq found (cons (nth 1 opening) run-start)))
            (setq opening nil))
           (opens
            (setq opening (list run-start run-end run-length))))
          (setq cursor run-end))))
    found))

(defun pilish--text-wrapper-extent (text bounds quote)
  "Return BOUNDS expanded to include surrounding QUOTE delimiters in TEXT."
  (let ((start (1- (car bounds)))
        (end (cdr bounds)))
    (when (eq quote ?`)
      (while (and (> start 0) (eq (aref text (1- start)) quote))
        (setq start (1- start)))
      (while (and (< end (length text)) (eq (aref text end) quote))
        (setq end (1+ end))))
    (cons start (if (eq quote ?`) end (1+ end)))))

(defun pilish--quoted-text-file-candidate-at-index (text index)
  "Return a quoted file candidate surrounding INDEX in TEXT, or nil.
Only the nearest unescaped wrapper pair of each supported kind is considered,
so unrelated or unmatched earlier wrappers cannot poison local lookup.
Markdown backtick spans take authority over nested prose single quotes."
  (catch 'authoritative-wrapper
    (dolist (quote '(?` ?'))
      (when-let* ((bounds
                   (pilish--text-wrapper-bounds-at-index
                    text index quote)))
        (throw
         'authoritative-wrapper
         (when-let* ((candidate
                      (pilish--parse-text-file-candidate
                       (substring text (car bounds) (cdr bounds))
                       t (car bounds) (cdr bounds)))
                     (candidate-bounds (plist-get candidate :bounds))
                     ((<= (car candidate-bounds) index
                          (cdr candidate-bounds)))
                     ((pilish--text-file-diagnostic-context-p
                       candidate text (cdr bounds) (1+ (cdr bounds)))))
           (plist-put candidate :extent
                      (pilish--text-wrapper-extent
                       text bounds quote))))))))

(defun pilish--inside-text-wrapper-p (text index)
  "Return non-nil when INDEX is inside a supported wrapper in TEXT."
  (seq-some (lambda (quote)
              (pilish--text-wrapper-bounds-at-index
               text index quote))
            '(?' ?`)))

(defun pilish--text-file-whitespace-p (character)
  "Return non-nil when CHARACTER delimits an unquoted candidate."
  (memq character '(?\s ?\t ?\n ?\r)))

(defun pilish--unquoted-text-file-candidate-at-index (text index)
  "Return the whitespace-bounded candidate at INDEX in TEXT, or nil.
Scanning stops after `pilish--max-text-file-candidate-length'
characters in either direction.  Markdown wrappers and trailing punctuation
are excluded exactly as in the strict first-slice grammar."
  (let* ((length (length text))
         (probe (cond
                 ((and (< index length)
                       (not (pilish--text-file-whitespace-p
                             (aref text index))))
                  index)
                 ((and (> index 0)
                       (not (pilish--text-file-whitespace-p
                             (aref text (1- index)))))
                  (1- index)))))
    (when probe
      (let ((begin probe)
            (end (1+ probe))
            (remaining pilish--max-text-file-candidate-length)
            overlong token-begin token-end)
        (while (and (> begin 0)
                    (not (pilish--text-file-whitespace-p
                          (aref text (1- begin))))
                    (> remaining 0))
          (setq begin (1- begin)
                remaining (1- remaining)))
        (when (and (> begin 0)
                   (not (pilish--text-file-whitespace-p
                         (aref text (1- begin)))))
          (setq overlong t))
        (setq remaining pilish--max-text-file-candidate-length)
        (while (and (< end length)
                    (not (pilish--text-file-whitespace-p
                          (aref text end)))
                    (> remaining 0))
          (setq end (1+ end)
                remaining (1- remaining)))
        (when (and (< end length)
                   (not (pilish--text-file-whitespace-p
                         (aref text end))))
          (setq overlong t))
        (unless (or overlong
                    (> (- end begin)
                       pilish--max-text-file-candidate-length))
          (setq token-begin begin
                token-end end)
          (let (html-closing-tag)
            (while (and (< begin end)
                        (memq (aref text begin) '(?\( ?\[ ?\{)))
              (setq begin (1+ begin)))
            (setq html-closing-tag
                  (and (< (1+ begin) end)
                       (eq (aref text begin) ?<)
                       (eq (aref text (1+ begin)) ?/)))
            (while (and (< begin end) (eq (aref text begin) ?<))
              (setq begin (1+ begin)))
            (while (and (< begin end)
                        (memq (aref text (1- end))
                              (string-to-list ".,;!?)]}>")))
              (setq end (1- end)))
            (when (and (<= begin index end)
                       (not html-closing-tag))
              (let ((raw (substring text begin end)))
                ;; Quote-aware parsing owns tokens containing supported quotes.
                (unless (string-match-p "[`']" raw)
                  (when-let* ((candidate
                               (pilish--parse-text-file-candidate
                                raw nil begin end))
                              (candidate-bounds
                               (plist-get candidate :bounds))
                              ((<= begin index (cdr candidate-bounds)))
                              ((or
                                (not (plist-get
                                      candidate :diagnostic-separator))
                                (and (= end token-end)
                                     (pilish--text-file-diagnostic-context-p
                                      candidate text end token-end)))))
                    (plist-put candidate :extent
                               (cons token-begin token-end))))))))))))

(defun pilish--text-file-candidate-at-index (text index)
  "Return the strict file candidate at INDEX in one-line TEXT, or nil.
Lookup is exact rather than nearest-on-line: INDEX must fall within, or at the
exclusive end boundary of, the candidate text.  Work and allocations are
bounded around INDEX; unrelated candidates are never collected or parsed."
  (when (and (stringp text) (integerp index)
             (<= 0 index) (<= index (length text)))
    (or (pilish--quoted-text-file-candidate-at-index text index)
        (pilish--unquoted-text-file-candidate-at-index text index))))

(defun pilish--bounded-line-window-at-point ()
  "Return bounded current-line window metadata around point.
The plist contains `:start', `:end', `:start-complete', and `:end-complete'.
Complete edges are real line or buffer boundaries; incomplete edges are the
explicit candidate scan limit.  No operation searches farther than that limit."
  (let* ((origin (point))
         (lower (max (point-min)
                     (- origin pilish--text-file-input-radius)))
         (upper (min (point-max)
                     (+ origin pilish--text-file-input-radius)))
         start end start-complete end-complete)
    (save-excursion
      (goto-char origin)
      (if (search-backward "\n" lower t)
          (setq start (1+ (point))
                start-complete t)
        (setq start lower
              start-complete (= lower (point-min))))
      (goto-char origin)
      (if (search-forward "\n" upper t)
          (setq end (1- (point))
                end-complete t)
        (setq end upper
              end-complete (= upper (point-max)))))
    (list :start start :end end
          :start-complete start-complete :end-complete end-complete)))

(defun pilish--raw-text-file-candidate-visible-p
    (candidate window-start)
  "Return non-nil when raw CANDIDATE text is visible at WINDOW-START.
Wrapper delimiters are outside candidate bounds.  Hidden text inside the raw
candidate instead belongs to visible projection, which will derive a candidate
from what the user actually sees."
  (let* ((bounds (plist-get candidate :bounds))
         (start (+ window-start (car bounds)))
         (end (+ window-start (cdr bounds))))
    (equal (plist-get candidate :raw)
           (substring-no-properties
            (pilish--visible-text start end)))))

(defun pilish--raw-diagnostic-context-visible-p
    (candidate window-start)
  "Return non-nil when CANDIDATE's context at WINDOW-START is visible.
Hidden Markdown may not fabricate the separator, required space, or first
diagnostic character.  Ordinary non-diagnostic candidates always pass."
  (or (not (plist-get candidate :diagnostic-separator))
      (let* ((bounds (plist-get candidate :bounds))
             (separator (+ window-start (cdr bounds)))
             (following
              (+ window-start
                 (cdr (or (plist-get candidate :extent) bounds)))))
        (and (pilish--visible-text-span-p separator)
             (pilish--visible-text-span-p following)
             (pilish--visible-text-span-p (1+ following))))))

(defun pilish--target-closing-markdown-source-p (start end)
  "Return non-nil when omitted source in START..END only closes target markup.
Accept emphasis/code delimiter runs or one link-label close plus a simple hidden
destination and trailing delimiters.  This intentionally narrow grammar keeps
unrelated invisible text from fabricating diagnostic context."
  (let ((source (buffer-substring-no-properties start end)))
    (or (string-empty-p source)
        (string-match-p "\\`[*_`]+\\'" source)
        (string-match-p
         "\\`]\\(?:([^ \t\r\n()]*)\\)?[*_`]*\\'" source))))

(defun pilish--visible-diagnostic-context-source-p
    (candidate visible-input)
  "Return non-nil when projected CANDIDATE has literal diagnostic text.
VISIBLE-INPUT supplies its visible-to-source position map.  Only narrow
source-proven target-closing Markdown may lie between the separator and its
visible space.  The first diagnostic character must immediately follow that
space in source.  Thus unrelated hidden markup cannot fabricate the grammar."
  (or (not (plist-get candidate :diagnostic-separator))
      (let* ((separator (cdr (plist-get candidate :bounds)))
             (positions (plist-get visible-input :positions))
             (separator-source (aref positions separator))
             (space-source (aref positions (1+ separator)))
             (diagnostic-source (aref positions (+ separator 2))))
        (and (= diagnostic-source (1+ space-source))
             (pilish--target-closing-markdown-source-p
              (1+ separator-source) space-source)))))

(defun pilish--visible-file-candidate-buffer-bounds
    (candidate visible-input)
  "Map nonempty visible CANDIDATE bounds through VISIBLE-INPUT.
Return the real buffer envelope.  Internal hidden markup remains inside that
envelope, while hidden delimiters and link destinations remain outside it."
  (let* ((bounds (plist-get candidate :bounds))
         (start (car bounds))
         (end (cdr bounds))
         (positions (plist-get visible-input :positions)))
    (when (< start end)
      (cons (aref positions start)
            (1+ (aref positions (1- end)))))))

(defun pilish--markdown-code-span-at-point-p (start end)
  "Return non-nil when point is fontified as inline code in START..END.
Check both sides of a visible boundary.  This preserves authoritative code-span
semantics when its delimiters are outside the bounded resolver window."
  (seq-some
   (lambda (position)
     (let ((face (and (<= start position) (< position end)
                      (get-char-property position 'face))))
       (or (eq face 'md-ts-code)
           (and (listp face) (memq 'md-ts-code face)))))
   (list (point) (1- (point)))))

(define-error 'pilish-semantic-link-parser-error
  "Semantic Markdown parser failure")

(defvar pilish--semantic-link-resolver-parsers nil
  "Dynamically bound identities of live semantic resolver parsers.
The `:active' sentinel distinguishes resolver lookup from direct helper tests.
A parser remains registered only when its direct deletion fails, allowing outer
cleanup to retry that exact identity without claiming unrelated new parsers.")

(defvar pilish--semantic-code-span-at-point nil
  "Dynamically record code-span ownership during semantic resolution.
The `:active' sentinel limits this side channel to the public resolver call;
direct capture-helper tests do not mutate global state.")

(defconst pilish--semantic-link-query
  '(((inline_link) @link)
    ((image) @link)
    ((full_reference_link) @link)
    ((collapsed_reference_link) @link)
    ((shortcut_link) @link)
    ((code_span) @opaque)
    ((html_tag) @opaque)
    ((link_destination) @opaque)
    ((link_title) @opaque))
  "Tree-sitter query for Markdown links relevant to file ownership.")

(defconst pilish--max-semantic-link-host-length (* 256 1024)
  "Maximum characters parsed as one semantic Markdown inline host.
Semantic parsing must see a complete canonical `inline' or `pipe_table_cell'
host: parsing a clipped fragment can lose real ownership or invent links inside
an enclosing construct.  A 262,144-character cap keeps press-time native parser
work and recovery scanning explicitly bounded while covering the existing
100,000-character generated-line case and labels well beyond the old 16,388
character plain-text window.  Hosts beyond this cap fail closed and suppress
strict text fallback.")

(defun pilish--semantic-link-child (node type)
  "Return NODE's first named child whose tree-sitter type is TYPE."
  (seq-find (lambda (child)
              (string= (treesit-node-type child) type))
            (treesit-node-children node t)))

(defun pilish--semantic-link-code-projection (pairs)
  "Normalize code-span PAIRS while retaining one source position per character.
PAIRS are (CHARACTER . BUFFER-POSITION) entries with delimiters removed.
Markdown code spans render line endings as spaces.  When non-space content is
wrapped by a space at both ends, one space is removed from each end."
  (let (normalized)
    (while pairs
      (let* ((pair (pop pairs))
             (character (car pair)))
        (cond
         ((and (eq character ?\r) pairs (eq (caar pairs) ?\n))
          (push (cons ?\s (cdr pair)) normalized)
          (pop pairs))
         ((memq character '(?\r ?\n))
          (push (cons ?\s (cdr pair)) normalized))
         (t (push pair normalized)))))
    (setq normalized (nreverse normalized))
    (if (and (> (length normalized) 2)
             (eq (caar normalized) ?\s)
             (eq (car (car (last normalized))) ?\s)
             (seq-some (lambda (pair) (not (eq (car pair) ?\s))) normalized))
        (butlast (cdr normalized))
      normalized)))

(defun pilish--semantic-link-label-projection (label)
  "Return rendered source projection for tree-sitter LABEL.
The returned plist has rendered `:raw-text', control-safe `:text', and a
`:positions' vector parallel to `:raw-text'.  Its `:bounds' is the source
envelope from the
first through last emitted label character.  Emphasis, strong, and code
delimiters are omitted; punctuation escapes emit only their escaped character;
and nested links/images emit only their recursively rendered label text.  Every
emitted character keeps its exact source position, so internal hidden markup
remains inside the envelope but never becomes actionable.

Traversal uses an explicit work stack, so deeply nested labels remain bounded
by the complete host cap rather than Emacs Lisp recursion depth.  Projection
derives solely from source and tree shape, never from font-lock, invisibility,
faces, display, buttons, or overlays."
  (let ((work (list (list :node label)))
        output)
    (while work
      (let* ((action (pop work))
             (kind (car action)))
        (pcase kind
          (:source
           (let ((start (nth 1 action))
                 (end (nth 2 action)))
             (while (< start end)
               (push (cons (char-after start) start) output)
               (setq start (1+ start)))))
          (:pairs
           (dolist (pair (nth 1 action))
             (push pair output)))
          (:node
           (let* ((node (nth 1 action))
                  (type (treesit-node-type node)))
             (cond
              ((member type '("emphasis_delimiter" "code_span_delimiter"
                              "html_tag")))
              ((string= type "backslash_escape")
               (push (list :source
                           (min (treesit-node-end node)
                                (1+ (treesit-node-start node)))
                           (treesit-node-end node))
                     work))
              ((and (string= type "image")
                    (or (pilish--semantic-link-child
                         node "link_destination")
                        (pilish--semantic-link-child
                         node "link_label")))
               (when-let* ((description
                            (pilish--semantic-link-child
                             node "image_description")))
                 (push (list :node description) work)))
              ((and (member type '("inline_link" "full_reference_link"
                                   "collapsed_reference_link"))
                    (or (not (string= type "inline_link"))
                        (pilish--semantic-link-child
                         node "link_destination")))
               (when-let* ((text (pilish--semantic-link-child
                                  node "link_text")))
                 (push (list :node text) work)))
              ((string= type "code_span")
               (let* ((delimiters
                       (seq-filter
                        (lambda (child)
                          (string= (treesit-node-type child)
                                   "code_span_delimiter"))
                        (treesit-node-children node t)))
                      (start (and delimiters
                                  (treesit-node-end (car delimiters))))
                      (end (and delimiters
                                (treesit-node-start (car (last delimiters))))))
                 (when (and start end (<= start end))
                   (let (pairs)
                     (while (< start end)
                       (push (cons (char-after start) start) pairs)
                       (setq start (1+ start)))
                     (push (list :pairs
                                 (pilish--semantic-link-code-projection
                                  (nreverse pairs)))
                           work)))))
              (t
               (let ((cursor (treesit-node-start node))
                     actions)
                 (dolist (child (treesit-node-children node t))
                   (when (< cursor (treesit-node-start child))
                     (push (list :source cursor (treesit-node-start child))
                           actions))
                   (push (list :node child) actions)
                   (setq cursor (treesit-node-end child)))
                 (when (< cursor (treesit-node-end node))
                   (push (list :source cursor (treesit-node-end node)) actions))
                 (setq work (nconc (nreverse actions) work))))))))))
    (let ((pairs (nreverse output)))
      (when pairs
        (let* ((raw-text (apply #'string (mapcar #'car pairs)))
               (positions (vconcat (mapcar #'cdr pairs))))
          (list :raw-text raw-text
                :text (pilish--escape-control-chars-for-display
                       raw-text)
                :positions positions
                :bounds (cons (aref positions 0)
                              (1+ (aref positions
                                        (1- (length positions)))))))))))

(defun pilish--semantic-link-parent-owner (node)
  "Return a semantic label owner containing nested NODE, or nil.
Inline and reference hyperlinks own nested image alt text.  A standalone image
likewise owns any nested link or image source in its visible description.  The
ancestor must physically contain NODE in its `link_text' or
`image_description', so destination ancestry can never establish ownership."
  (let ((ancestor (treesit-node-parent node))
        owner)
    (while (and ancestor (not owner))
      (let* ((type (treesit-node-type ancestor))
             (label-type (if (string= type "image")
                             "image_description" "link_text")))
        (when (member type '("inline_link" "image" "full_reference_link"
                             "collapsed_reference_link" "shortcut_link"))
          (when-let* ((label (pilish--semantic-link-child
                              ancestor label-type))
                      ((<= (treesit-node-start label)
                           (treesit-node-start node)
                           (treesit-node-end node)
                           (treesit-node-end label))))
            (setq owner ancestor))))
      (setq ancestor (treesit-node-parent ancestor)))
    owner))

(defun pilish--semantic-link-fragment-index (destination)
  "Return the first unescaped fragment marker index in DESTINATION.
Backslash-escaped punctuation follows Markdown destination source semantics."
  (let ((index 0)
        (limit (length destination))
        found)
    (while (and (< index limit) (not found))
      (cond
       ((and (eq (aref destination index) ?\\)
             (< (1+ index) limit)
             (string-match-p "[[:punct:]]"
                             (char-to-string
                              (aref destination (1+ index)))))
        (setq index (+ index 2)))
       ((eq (aref destination index) ?#)
        (setq found index))
       (t (setq index (1+ index)))))
    found))

(defun pilish--semantic-link-unescape (destination)
  "Decode basic Markdown punctuation escapes in local DESTINATION.
Other backslashes remain literal and are subsequently rejected by the strict
file-path grammar rather than being assigned broader path semantics."
  (let ((index 0)
        (limit (length destination))
        pieces)
    (while (< index limit)
      (if (and (eq (aref destination index) ?\\)
               (< (1+ index) limit)
               (string-match-p "[[:punct:]]"
                               (char-to-string
                                (aref destination (1+ index)))))
          (progn
            (push (char-to-string (aref destination (1+ index))) pieces)
            (setq index (+ index 2)))
        (push (char-to-string (aref destination index)) pieces)
        (setq index (1+ index))))
    (apply #'concat (nreverse pieces))))

(defun pilish--semantic-link-percent-decode (text)
  "Decode URL percent escapes in TEXT and return the decoded string.
Only a percent sign followed by two hexadecimal digits is an escape; any
other percent sign stays literal.  Escapes denote UTF-8 bytes, not
characters, so decoded and literal input is assembled as UTF-8; invalid
sequences become raw bytes that fail the strict path grammar.  CommonMark
layering applies this after Markdown backslash escapes."
  (if (not (string-match-p "%[0-9A-Fa-f][0-9A-Fa-f]" text))
      text
    (let ((index 0)
          (bytes nil))
      (while (string-match "%\\([0-9A-Fa-f][0-9A-Fa-f]\\)" text index)
        (setq bytes
              (nconc bytes
                     (string-to-list
                      (encode-coding-string
                       (substring text index (match-beginning 0)) 'utf-8))
                     (list (string-to-number (match-string 1 text) 16)))
              index (match-end 0)))
      (setq bytes
            (nconc bytes
                   (string-to-list
                    (encode-coding-string (substring text index) 'utf-8))))
      (decode-coding-string (apply #'unibyte-string bytes) 'utf-8))))

(defun pilish--semantic-link-malformed-end (start limit)
  "Return malformed inline-link ownership end after shortcut ending at START.
A shortcut immediately followed by `(' is the installed grammar's recovery
shape for an incomplete or malformed inline link.  Scan no farther than LIMIT,
which is the end of a complete capped host.  Backslash escapes skip the next
character; bare destinations balance nested parentheses; an angle destination
is recognized only at destination start and ignores parentheses through its
unescaped `>'; and title quotes/parentheses are recognized only immediately
after destination whitespace.  Return the position after the real outer close,
or LIMIT for an incomplete streamed tail."
  (when (and (< start limit) (eq (char-after start) ?\())
    (let ((cursor (1+ start))
          (depth 1)
          (phase :destination)
          (destination-start t)
          angle quote done)
      (while (and (< cursor limit) (not done))
        (let ((character (char-after cursor)))
          (cond
           (quote
            (cond
             ((eq character ?\\)
              (setq cursor (min limit (+ cursor 2))))
             ((eq character quote)
              (setq quote nil
                    phase :after-title
                    cursor (1+ cursor)))
             (t (setq cursor (1+ cursor)))))
           (angle
            ;; CommonMark angle destinations cannot contain line endings, even
            ;; after a backslash.  Leave invalid angle state at that boundary
            ;; so the next outer close terminates malformed ownership.
            (cond
             ((memq character '(?\n ?\r))
              (setq angle nil
                    phase :trailing
                    cursor (1+ cursor)))
             ((and (eq character ?\\) (< (1+ cursor) limit))
              (if (memq (char-after (1+ cursor)) '(?\n ?\r))
                  (setq angle nil
                        phase :trailing)
                (setq destination-start nil))
              (setq cursor (min limit (+ cursor 2))))
             ((eq character ?>)
              (setq angle nil
                    phase :destination-ended
                    cursor (1+ cursor)))
             (t (setq cursor (1+ cursor)))))
           ;; Escape parity follows naturally: skipping a pair leaves the next
           ;; backslash or close to be interpreted on the following iteration.
           ((eq character ?\\)
            (cond
             ((eq phase :destination) (setq destination-start nil))
             ((memq phase '(:destination-ended :after-destination
                             :after-title))
              (setq phase :trailing)))
            (setq cursor (min limit (+ cursor 2))))
           ((and (eq phase :destination) destination-start
                 (eq character ?<))
            (setq angle t
                  destination-start nil
                  cursor (1+ cursor)))
           ((and (eq phase :destination) (= depth 1)
                 (memq character '(?\s ?\t ?\n ?\r)))
            (setq phase :after-destination
                  cursor (1+ cursor)))
           ((and (eq phase :destination-ended)
                 (memq character '(?\s ?\t ?\n ?\r)))
            (setq phase :after-destination
                  cursor (1+ cursor)))
           ((and (memq phase '(:after-destination :after-title))
                 (memq character '(?\s ?\t ?\n ?\r)))
            (setq cursor (1+ cursor)))
           ((and (eq phase :after-destination)
                 (memq character '(?\" ?')))
            (setq quote character
                  cursor (1+ cursor)))
           ((and (eq phase :after-destination) (eq character ?\())
            (setq phase :parenthesized-title
                  depth (1+ depth)
                  cursor (1+ cursor)))
           ((and (eq phase :parenthesized-title) (eq character ?\())
            (setq depth (1+ depth)
                  cursor (1+ cursor)))
           ((and (eq phase :destination) (eq character ?\())
            (setq destination-start nil
                  depth (1+ depth)
                  cursor (1+ cursor)))
           ((eq character ?\))
            (setq depth (1- depth)
                  cursor (1+ cursor))
            (cond
             ((= depth 0) (setq done t))
             ((and (= depth 1) (eq phase :parenthesized-title))
              (setq phase :after-title))))
           ((memq phase '(:after-destination :after-title))
            (setq phase :trailing
                  cursor (1+ cursor)))
           (t
            (cond
             ((eq phase :destination) (setq destination-start nil))
             ((eq phase :destination-ended) (setq phase :trailing)))
            (setq cursor (1+ cursor))))))
      (if done cursor limit))))

(defun pilish--semantic-link-markdown-host-parser ()
  "Return md-ts-mode's trustworthy canonical Markdown host parser.
The canonical host parser is the sole unrestricted Markdown parser whose
actual root covers the accessible buffer and lookup position.  `md-ts-mode' uses
that shape for its document parser and restricted, no-reuse parsers for local
work.  Requiring this shape avoids parser-list ordering and refuses ambiguous
or partial host state rather than querying the wrong Markdown document."
  (let ((positions (delete-dups
                    (list (point)
                          (max (point-min) (1- (point))))))
        candidates)
    (dolist (parser (treesit-parser-list))
      ;; Test included ranges before asking for a root: arbitrary restricted
      ;; parsers are not trusted and cannot break canonical selection.
      (when (and (eq (treesit-parser-language parser) 'markdown)
                 (null (treesit-parser-included-ranges parser)))
        (let ((root (treesit-parser-root-node parser)))
          (when (and (eq (treesit-node-language root) 'markdown)
                     (<= (treesit-node-start root) (point-min))
                     (>= (treesit-node-end root) (point-max))
                     (seq-every-p
                      (lambda (position)
                        (<= (treesit-node-start root) position
                            (treesit-node-end root)))
                      positions))
            (push parser candidates)))))
    (unless (= (length candidates) 1)
      (signal 'pilish-semantic-link-parser-error
              '("No unique canonical Markdown host parser")))
    (car candidates)))

(defun pilish--semantic-link-inline-host-node-at-point ()
  "Return the Markdown host node whose inline grammar owns point.
Installed `md-ts-mode' injects `markdown-inline' only into Markdown `inline' and
`pipe_table_cell' nodes.  Consult its canonical unrestricted host tree so
fenced/indented code, reference definitions, restricted competing parsers, and
other block source cannot be reinterpreted merely because it resembles inline
syntax."
  (let* ((parser (pilish--semantic-link-markdown-host-parser))
         (root (treesit-parser-root-node parser)))
    (catch 'host
      (dolist (position (delete-dups
                         (list (point)
                               (max (point-min) (1- (point))))))
        (let ((node (treesit-node-descendant-for-range
                     root position position)))
          (while node
            (when (member (treesit-node-type node)
                          '("inline" "pipe_table_cell"))
              (throw 'host node))
            (setq node (treesit-node-parent node))))))))

(defun pilish--semantic-link-host-at-point ()
  "Return complete canonical inline-host metadata at point, or nil.
Only the host types used by md-ts-mode's established local inline range rules,
`inline' and `pipe_table_cell', are accepted.  The returned plist contains the
complete host bounds and `:over-cap' when safely parsing that host would exceed
`pilish--max-semantic-link-host-length'.  No clipped source fragment is
ever presented to the inline grammar."
  (when-let* ((host (pilish--semantic-link-inline-host-node-at-point)))
    (let ((start (treesit-node-start host))
          (end (treesit-node-end host)))
      (when (<= start (point) end)
        (list :start start :end end
              :over-cap
              (> (- end start)
                 pilish--max-semantic-link-host-length))))))

(defun pilish--semantic-link-range-projection (start end)
  "Project rendered inline source from START through END in the current buffer.
This is used only for a grammar recovery label whose outer link node was lost
because the inline grammar cannot resolve an inner shortcut reference without
document-wide definitions."
  (let ((parser (treesit-parser-create 'markdown-inline nil t)))
    (when pilish--semantic-link-resolver-parsers
      (push parser pilish--semantic-link-resolver-parsers))
    (unwind-protect
        (progn
          (treesit-parser-set-included-ranges parser (list (cons start end)))
          (pilish--semantic-link-label-projection
           (treesit-parser-root-node parser)))
      (treesit-parser-delete parser)
      (setq pilish--semantic-link-resolver-parsers
            (delq parser pilish--semantic-link-resolver-parsers)))))

(defun pilish--semantic-link-reparse-shortcut-outer (candidate)
  "Return detached outer owner recovered from shortcut CANDIDATE.
CANDIDATE records source `:start', `:open', `:label-end', and `:end'.
Temporarily copy only that bounded source and replace nested shortcut brackets
with equal-width braces.  This models this phase's explicit unresolved-shortcut
deferral without changing the chat buffer or shifting source offsets."
  (let* ((source-start (plist-get candidate :start))
         (open (plist-get candidate :open))
         (label-end (plist-get candidate :label-end))
         (source-end (plist-get candidate :end))
         (source (buffer-substring-no-properties source-start source-end))
         metadata)
    ;; The temporary parse establishes only the recovered outer destination.
    ;; Neutralize every nested square delimiter in its label at equal width;
    ;; the original source is projected independently below, preserving valid
    ;; nested image rendering and literal malformed/shortcut text exactly.
    (let ((cursor (- (1+ open) source-start))
          (limit (- label-end source-start)))
      (while (< cursor limit)
        (pcase (aref source cursor)
          (?\[ (aset source cursor ?{))
          (?\] (aset source cursor ?})))
        (setq cursor (1+ cursor))))
    (with-temp-buffer
      (insert source)
      (let ((parser (treesit-parser-create 'markdown-inline nil t)))
        (when pilish--semantic-link-resolver-parsers
          (push parser pilish--semantic-link-resolver-parsers))
        (unwind-protect
            (let* ((root (treesit-parser-root-node parser))
                   (outer
                    (seq-find
                     (lambda (capture)
                       (let ((node (cdr capture)))
                         (and (= (treesit-node-start node) (point-min))
                              (= (treesit-node-end node) (point-max))
                              (member (treesit-node-type node)
                                      '("inline_link" "image")))))
                     (treesit-query-capture
                      root pilish--semantic-link-query
                      (point-min) (point-max)))))
              (when outer
                (let* ((node (cdr outer))
                       (type (treesit-node-type node))
                       (destination
                        (pilish--semantic-link-child
                         node "link_destination")))
                  (when destination
                    (setq metadata
                          (list
                           :type type
                           :destination-start
                           (+ source-start
                              (- (treesit-node-start destination)
                                 (point-min)))
                           :destination-end
                           (+ source-start
                              (- (treesit-node-end destination)
                                 (point-min)))))))))
          (treesit-parser-delete parser)
          (setq pilish--semantic-link-resolver-parsers
                (delq parser
                      pilish--semantic-link-resolver-parsers)))))
    (if metadata
        (append
         (list :start source-start
               :end source-end
               :label-start (1+ open)
               :label-end label-end
               :label-projection
               (pilish--semantic-link-range-projection
                (1+ open) label-end)
               :parent-owner-start nil
               :reference-image nil
               :malformed nil)
         metadata)
      (list :type "shortcut_link" :start source-start :end source-end
            :malformed source-end))))

(defun pilish--semantic-link-unescaped-bang-before-p (position start)
  "Return non-nil when POSITION follows an unescaped `!' after START."
  (when (and (> position start) (eq (char-before position) ?!))
    (let ((cursor (- position 2))
          (backslashes 0))
      (while (and (>= cursor start) (eq (char-after cursor) ?\\))
        (setq backslashes (1+ backslashes)
              cursor (1- cursor)))
      (zerop (% backslashes 2)))))

(defun pilish--semantic-link-recover-shortcut-outer
    (captures start end position)
  "Recover an outer construct from CAPTURES in START..END at POSITION.
The installed inline grammar treats every shortcut as a link before definition
lookup and therefore cannot emit a containing hyperlink.  This phase explicitly
defers shortcut definitions, so balance source brackets once, find an enclosing
outer label followed by a parenthesized tail, and reparse only that complete
bounded construct with nested shortcuts neutralized."
  (let ((shortcut-starts (make-hash-table :test #'eql))
        (open-for-shortcut (make-hash-table :test #'eql))
        (close-for-open (make-hash-table :test #'eql))
        (opaque-ends (make-hash-table :test #'eql))
        (seen-opens (make-hash-table :test #'eql))
        stack outer-image best)
    (dolist (capture captures)
      (cond
       ((string= (plist-get capture :type) "shortcut_link")
        (puthash (plist-get capture :start) t shortcut-starts))
       ((member (plist-get capture :type)
                '("code_span" "html_tag" "link_destination" "link_title"))
        (puthash (plist-get capture :start)
                 (plist-get capture :end) opaque-ends))))
    (let ((cursor start))
      (while (< cursor end)
        (let ((character (char-after cursor)))
          (cond
           ((gethash cursor opaque-ends)
            (setq cursor (gethash cursor opaque-ends)))
           ((eq character ?\\)
            (setq cursor (min end (+ cursor 2))))
           ((eq character ?\[)
            (when (gethash cursor shortcut-starts)
              ;; Only the nearest lexical opener and outermost image opener
              ;; can establish additional ownership.  Persisting/traversing
              ;; the full stack for every shortcut would be quadratic.
              (puthash cursor
                       (delete-dups
                        (delq nil (list (caar stack) outer-image)))
                       open-for-shortcut))
            (push (cons cursor outer-image) stack)
            (when (and (not outer-image)
                       (pilish--semantic-link-unescaped-bang-before-p
                        cursor start))
              (setq outer-image cursor))
            (setq cursor (1+ cursor)))
           ((eq character ?\])
            (when stack
              (let ((entry (pop stack)))
                (puthash (car entry) cursor close-for-open)
                (when (eq (car entry) outer-image)
                  (setq outer-image (cdr entry)))))
            (setq cursor (1+ cursor)))
           (t (setq cursor (1+ cursor)))))))
    (catch 'recovered
      (dolist (capture captures)
        (dolist (open (gethash (plist-get capture :start)
                               open-for-shortcut))
          (when-let* ((label-end (gethash open close-for-open))
                      ((< label-end end))
                      ((eq (char-after (1+ label-end)) ?\())
                      ((not (gethash open seen-opens)))
                      (seen (puthash open t seen-opens))
                      ((<= open position))
                      (source-end
                       (pilish--semantic-link-malformed-end
                        (1+ label-end) end))
                      ((< position source-end)))
            (let* ((imagep
                    (pilish--semantic-link-unescaped-bang-before-p
                     open start))
                   (source-start (if imagep (1- open) open))
                   (nested-link
                    (and (not imagep)
                         (seq-some
                          (lambda (inner)
                            (and (member (plist-get inner :type)
                                         '("inline_link"
                                           "full_reference_link"
                                           "collapsed_reference_link"))
                                 (< open (plist-get inner :start))
                                 (<= (plist-get inner :end) label-end)))
                          captures))))
              ;; CommonMark permits links inside image descriptions but never
              ;; links inside links.  Do not fabricate an apparent recovered
              ;; hyperlink by neutralizing a completed nested hyperlink.
              (unless nested-link
                (let ((owner
                       (pilish--semantic-link-reparse-shortcut-outer
                        (list :start source-start :open open
                              :label-end label-end :end source-end))))
                  (cond
                   ((not (plist-get owner :malformed))
                    (when (or (not best)
                              (and (string= (plist-get owner :type) "image")
                                   (not (string= (plist-get best :type)
                                                 "image")))
                              (< (plist-get owner :start)
                                 (plist-get best :start)))
                      (setq best owner)))
                   ((not best) (setq best owner)))
                  ;; An incomplete malformed tail consumes the host remainder;
                  ;; no later candidate can supply a containing outer close.
                  (when (and (plist-get owner :malformed)
                             (= source-end end))
                    (throw 'recovered best)))))))))
    best))

(defun pilish--semantic-link-select-owner (captures start end position)
  "Select one semantic owner from CAPTURES at POSITION in START..END.
Malformed recovery has source-order priority.  Completed recovery extents are
skipped before scanning later captures, so total malformed scanning is linear
in the complete capped host.  Otherwise label ancestry removes nested activation
captures, and explicit grammar type order selects the owner.  Ambiguous owners
of one semantic type fail closed before label projection."
  (let* ((ordered
          (sort (copy-sequence captures)
                (lambda (left right)
                  (< (plist-get left :start) (plist-get right :start)))))
         (parent-owner-starts (make-hash-table :test #'eql))
         (scanned-through (point-min))
         malformed-owner owners)
    (dolist (capture captures)
      (when-let* ((parent-start
                   (plist-get capture :parent-owner-start)))
        (puthash parent-start t parent-owner-starts)))
    ;; Find the earliest malformed extent that reaches point.  Once an extent
    ;; closes before point, captures nested inside it cannot own point and are
    ;; skipped.  This avoids rescanning the same recovery tail for every nested
    ;; shortcut capture.
    (catch 'owned-malformed
      (dolist (capture ordered)
        (let ((type (plist-get capture :type))
              (node-start (plist-get capture :start))
              (node-end (plist-get capture :end)))
          (when (and (not (plist-get capture :parent-owner-start))
                     (>= node-start scanned-through)
                     (<= node-start position)
                     (or (string= type "shortcut_link")
                         (and (string= type "image")
                              (null (plist-get capture :destination-start))
                              (not (plist-get capture :reference-image)))))
            (when-let* ((malformed-end
                         (pilish--semantic-link-malformed-end
                          node-end end)))
              (if (< position malformed-end)
                  (progn
                    (setq malformed-owner
                          (append (list :end malformed-end
                                        :malformed malformed-end)
                                  capture))
                    (throw 'owned-malformed malformed-owner))
                (setq scanned-through (max scanned-through malformed-end))))))))
    (or (pilish--semantic-link-recover-shortcut-outer
         ordered start end position)
        malformed-owner
        (progn
          ;; Markdown label ancestry is activation ancestry.  Hyperlinks
          ;; (including unsupported shortcut/reference forms) own nested image
          ;; alt text; standalone images own nested link/image descriptions.
          (dolist (capture captures)
            (let ((type (plist-get capture :type))
                  (node-start (plist-get capture :start))
                  (node-end (plist-get capture :end)))
              (when (and (or (not (string= type "shortcut_link"))
                             (gethash node-start parent-owner-starts))
                         (<= node-start position)
                         (< position node-end))
                (push (append (list :end node-end :malformed nil) capture)
                      owners))))
          (setq owners
                (seq-remove
                 (lambda (owner) (plist-get owner :parent-owner-start))
                 owners))
          (catch 'owner
            (dolist (type '("inline_link" "full_reference_link"
                            "collapsed_reference_link" "shortcut_link"
                            "image"))
              (let ((matches
                     (seq-filter
                      (lambda (owner)
                        (string= (plist-get owner :type) type))
                      owners)))
                (when (> (length matches) 1)
                  (signal 'pilish-semantic-link-parser-error
                          (list (format "Ambiguous semantic %s owners" type))))
                (when matches (throw 'owner (car matches))))))))))

(defun pilish--semantic-link-captures (start end)
  "Return detached installed-grammar owner metadata in complete START..END.
Use a short-lived independent `markdown-inline' parser so raw, fontified, and
streaming buffers have identical semantics.  Query captures are reduced to the
single semantic owner at point before projecting only that owner's label.  This
keeps deeply nested/recovery trees linear and fails ambiguity closed before
expensive projection.  All node types, bounds, labels, and destinations are
copied to a plist before deleting the parser; no caller observes a tree node
after its parser lifetime.  `md-ts-mode' exposes no public resolver with the
detached semantic metadata contract Pilish needs.  This parser never changes
text, overlays, font-lock properties, visibility, or the mode's parser set."
  (let ((parser (treesit-parser-create 'markdown-inline nil t)))
    (when pilish--semantic-link-resolver-parsers
      (push parser pilish--semantic-link-resolver-parsers))
    (unwind-protect
        (progn
          (treesit-parser-set-included-ranges parser (list (cons start end)))
          (let* ((captures
                  (mapcar
                   (lambda (capture)
                     (let* ((node (cdr capture))
                            (type (treesit-node-type node))
                            (label-type (if (string= type "image")
                                            "image_description" "link_text"))
                            (label (pilish--semantic-link-child
                                    node label-type))
                            (destination
                             (pilish--semantic-link-child
                              node "link_destination"))
                            (parent-owner
                             (pilish--semantic-link-parent-owner node)))
                       (list :type type
                             :start (treesit-node-start node)
                             :end (treesit-node-end node)
                             :label-start
                             (and label (treesit-node-start label))
                             :label-end (and label (treesit-node-end label))
                             :label-node label
                             :parent-owner-start
                             (and parent-owner
                                  (treesit-node-start parent-owner))
                             :reference-image
                             (and (string= type "image") label
                                  (null destination)
                                  (> (treesit-node-end node)
                                     (1+ (treesit-node-end label))))
                             :destination-start
                             (and destination (treesit-node-start destination))
                             :destination-end
                             (and destination (treesit-node-end destination)))))
                   (treesit-query-capture
                    (treesit-parser-root-node parser)
                    pilish--semantic-link-query start end)))
                 (_code-span
                  (when (eq pilish--semantic-code-span-at-point
                            :active)
                    (setq pilish--semantic-code-span-at-point
                          (and
                           (seq-some
                            (lambda (capture)
                              (and
                               (string= (plist-get capture :type) "code_span")
                               (seq-some
                                (lambda (position)
                                  (<= (plist-get capture :start) position
                                      (1- (plist-get capture :end))))
                                (delete-dups
                                 (list (point)
                                       (max (point-min) (1- (point))))))))
                            captures)
                           t))))
                 (owner (pilish--semantic-link-select-owner
                         captures start end (point))))
            (when owner
              (when (and (not (plist-get owner :malformed))
                         (member (plist-get owner :type)
                                 '("inline_link" "image"))
                         (plist-get owner :destination-start)
                         (plist-get owner :label-node)
                         (not (plist-get owner :label-projection)))
                (plist-put
                 owner :label-projection
                 (pilish--semantic-link-label-projection
                  (plist-get owner :label-node))))
              ;; Tree nodes must not escape the short-lived parser.
              (plist-put owner :label-node nil)
              (list owner))))
      (treesit-parser-delete parser)
      (setq pilish--semantic-link-resolver-parsers
            (delq parser pilish--semantic-link-resolver-parsers)))))

(defun pilish--semantic-link-owner-at-point (host)
  "Return the semantic activation owner at point inside complete HOST.
The result is detached metadata containing physical, projected-label, and
destination extents.  Label ancestry decides nested ownership explicitly:
hyperlinks own nested image alt text, while standalone images own nested label
constructs.  Unsupported shortcut references do not own ordinary bracketed
text, preserving the strict wrapper behavior.  However, a shortcut link
or non-reference shortcut image immediately followed by an opening parenthesis
is malformed inline recovery and owns its balanced, escape-aware tail.  Full
and collapsed references always own and suppress fallback."
  (car (pilish--semantic-link-captures
        (plist-get host :start) (plist-get host :end))))

(defun pilish--semantic-link-target (owner)
  "Return the valid local file target for semantic link OWNER, or nil.
Generated startup source links carry their known Emacs paths.  Otherwise,
only an inline link or inline image with a strict local destination qualifies.
URL schemes, mailto links, protocol-relative links, fragment-only links, empty
or malformed destinations, bare filenames, and reference forms are owned but
invalid.  A local fragment is returned separately and is never interpreted as
line metadata.  Destinations decode Markdown backslash escapes, then URL
percent escapes; angle-quoted destinations and destinations containing
percent escapes validate the decoded path with the angle-destination
rules."
  (let* ((type (plist-get owner :type))
         (label-projection (plist-get owner :label-projection))
         (label-positions (plist-get label-projection :positions))
         (destination-start (plist-get owner :destination-start))
         (destination-end (plist-get owner :destination-end))
         (position (point)))
    (when (and (not (plist-get owner :malformed))
               (member type '("inline_link" "image"))
               label-positions destination-start destination-end
               ;; A point activates only at the leading source boundary of an
               ;; emitted label character.  No trailing boundary is accepted
               ;; when it is physically a hidden Markdown delimiter.
               (seq-contains-p label-positions position #'=))
      (let* ((raw (buffer-substring-no-properties
                   destination-start destination-end))
             (angle (and (> (length raw) 1)
                         (string-prefix-p "<" raw)
                         (string-suffix-p ">" raw)))
             (source (if angle (substring raw 1 -1) raw))
             (fragment-index
              (pilish--semantic-link-fragment-index source))
             (path-source (if fragment-index
                              (substring source 0 fragment-index)
                            source))
             (fragment (and fragment-index
                            (substring source (1+ fragment-index))))
             (source-path
              (and (eq (get-text-property position 'pilish-startup-banner)
                       'expanded)
                   (get-text-property position 'pilish-startup-source)))
             (path (or source-path
                       (pilish--semantic-link-percent-decode
                        (pilish--semantic-link-unescape path-source))))
             (percent-escaped
              (string-match-p "%[0-9A-Fa-f][0-9A-Fa-f]" path-source))
             (case-fold-search t))
        (when (or source-path
                  (and (not (string-empty-p path))
                       (not (string-prefix-p "#" source))
                       (not (string-prefix-p "//" source))
                       (not (string-match-p
                             "\\`[[:alpha:]][[:alnum:]+.-]*:" source))
                       (pilish--strict-text-file-path-p
                        path (or angle percent-escaped))))
          (let* ((anchor (pilish--chat-session-directory))
                 (emacs-path (pilish--emacs-path path anchor))
                 (label (plist-get label-projection :text)))
            (pilish--make-file-target
             :link raw emacs-path
             :bounds (plist-get label-projection :bounds)
             :fragment fragment
             :label label)))))))

(defun pilish--semantic-link-parser-overlays ()
  "Return every inline-parser overlay md-ts could adopt in this buffer.
Use `overlay-lists' rather than positional overlay APIs: local ranges are
half-open, so `overlays-at' misses a host whose exclusive end is point.  md-ts
adopts any overlapping overlay carrying a matching parser even when host and
timestamp metadata are incomplete, so all such preexisting identities must be
isolated and restored."
  (seq-filter
   (lambda (overlay)
     (when-let* ((parser (overlay-get overlay 'treesit-parser)))
       (eq (treesit-parser-language parser) 'markdown-inline)))
   (append (car (overlay-lists)) (cdr (overlay-lists)))))

(defun pilish--semantic-link-parser-state ()
  "Snapshot parser identities/ranges and complete local-overlay state."
  (list
   :parsers
   (mapcar (lambda (parser)
             (cons parser (treesit-parser-included-ranges parser)))
           (treesit-parser-list))
   :overlays
   (mapcar
    (lambda (overlay)
      (let ((parser (overlay-get overlay 'treesit-parser)))
        (list overlay (overlay-start overlay) (overlay-end overlay)
              parser (treesit-parser-included-ranges parser)
              (overlay-get overlay 'treesit-parser-ov-timestamp))))
    (pilish--semantic-link-parser-overlays))))

(defun pilish--semantic-link-isolate-parser-state (state)
  "Hide preexisting local parsers in STATE during resolver-owned parsing.
A stale md-ts local parser would otherwise be replaced as a side effect of
lazy range discovery.  Temporarily hiding both identifying properties makes
md-ts create disposable resolver-owned state instead."
  (dolist (entry (plist-get state :overlays))
    (let ((overlay (car entry)))
      (overlay-put overlay 'treesit-parser nil)
      (overlay-put overlay 'treesit-parser-ov-timestamp nil))))

(defun pilish--semantic-link-cleanup-parser-state (state)
  "Restore preexisting parser STATE after isolated semantic lookup.
Local range discovery is dynamically disabled, so lookup cannot create or adopt
parser overlays.  Preexisting identities are still restored defensively with
their ranges, bounds, and timestamps.  Cleanup is best-effort across every
identity before its first error is re-signaled."
  (let* ((old-parser-state (plist-get state :parsers))
         (old-overlay-state (plist-get state :overlays))
         cleanup-error)
    (cl-labels ((remember-error
                 (error-data)
                 (unless cleanup-error
                   (setq cleanup-error error-data))))
      (unwind-protect
          (progn
            ;; Retry only an explicitly registered resolver parser whose direct
            ;; unwind deletion failed.  Identity, not "newness", establishes
            ;; ownership and preserves foreign parsers created during lookup.
            (dolist (parser
                     (delq :active
                           (copy-sequence
                            pilish--semantic-link-resolver-parsers)))
              (condition-case error-data
                  (progn
                    (treesit-parser-delete parser)
                    (setq pilish--semantic-link-resolver-parsers
                          (delq
                           parser
                           pilish--semantic-link-resolver-parsers)))
                (error (remember-error error-data))))
            (let ((current-parsers (treesit-parser-list)))
              (dolist (entry old-parser-state)
                (let ((parser (car entry))
                      (ranges (cdr entry)))
                  (when (memq parser current-parsers)
                    (condition-case error-data
                        (unless (equal
                                 ranges
                                 (treesit-parser-included-ranges parser))
                          (treesit-parser-set-included-ranges parser ranges))
                      (error (remember-error error-data))))))))
        ;; Restore every preexisting overlay even if disposal or another
        ;; restoration fails.  Identity comes first so an error cannot leave an
        ;; overlay hidden from md-ts and later lifecycle cleanup.
        (dolist (entry old-overlay-state)
          (let ((overlay (nth 0 entry))
                (start (nth 1 entry))
                (end (nth 2 entry))
                (parser (nth 3 entry))
                (ranges (nth 4 entry))
                (timestamp (nth 5 entry)))
            (when (overlay-buffer overlay)
              (condition-case error-data
                  (progn
                    (overlay-put overlay 'treesit-parser parser)
                    (overlay-put overlay 'treesit-parser-ov-timestamp timestamp)
                    (move-overlay overlay start end)
                    (unless (equal
                             ranges
                             (treesit-parser-included-ranges parser))
                      (treesit-parser-set-included-ranges parser ranges)))
                (error (remember-error error-data)))))))
      (when cleanup-error
        (signal (car cleanup-error) (cdr cleanup-error))))))

(defun pilish--semantic-link-file-target-at-point ()
  "Return explicit tri-state semantic Markdown link resolution at point.
The `:status' value is exactly one of `:not-a-link', `:owned-valid', or
`:owned-invalid'.  Ownership is source/tree based, independent of font-lock,
invisibility, faces, buttons, file existence, and unreleased `md-ts-mode' APIs.
This distinction prevents an owned non-file or malformed link from falling
through to a path-like visible label.

A missing/ambiguous canonical host or any tree/query/node failure signals
`pilish-semantic-link-parser-error'; parser failure is never semantic
absence.  Only a complete canonical inline/table-cell host is parsed, up to
`pilish--max-semantic-link-host-length'; an over-cap host returns
owned-invalid and cannot reach text fallback.  Lookup snapshots parser state,
isolates every preexisting inline overlay md-ts could adopt, and dynamically
disables local range discovery.  It therefore creates no md-ts parser overlays,
including at half-open host endpoints.  Lookup temporarily widens so buffer
narrowing cannot clip semantic ownership; the caller's restriction is restored."
  (save-restriction
    (widen)
    (let ((pilish--semantic-link-resolver-parsers (list :active))
          (pilish--semantic-code-span-at-point :active)
          state parse-result)
    (condition-case error-data
        (setq state (pilish--semantic-link-parser-state))
      (error
       (signal 'pilish-semantic-link-parser-error
               (list (error-message-string error-data)))))
    (unwind-protect
        (setq parse-result
              (condition-case error-data
                  (progn
                    (pilish--semantic-link-isolate-parser-state state)
                    (cl-labels
                        ((resolve
                          ()
                          (let* ((host
                                  (pilish--semantic-link-host-at-point))
                                 (owner
                                  (and
                                   host
                                   (not (plist-get host :over-cap))
                                   (pilish--semantic-link-owner-at-point
                                    host))))
                            (cond
                             ((and host (plist-get host :over-cap))
                              (list :status :owned-invalid
                                    :reason :host-over-cap))
                             ((not owner)
                              (append
                               (list :status :not-a-link)
                               (and
                                (eq pilish--semantic-code-span-at-point
                                    t)
                                (list :markdown-code-span t))))
                             (t (list :status :owner :owner owner))))))
                      ;; The resolver queries only the canonical block tree and
                      ;; its own short-lived inline parser.  Disable md-ts range
                      ;; discovery dynamically so lookup cannot create, adopt,
                      ;; or partially initialize local parser overlays at all.
                      (let ((treesit-range-settings nil))
                        (resolve))))
                (pilish-semantic-link-parser-error
                 (signal (car error-data) (cdr error-data)))
                (error
                 (signal 'pilish-semantic-link-parser-error
                         (list (error-message-string error-data))))))
      (condition-case error-data
          (pilish--semantic-link-cleanup-parser-state state)
        (pilish-semantic-link-parser-error
         (signal (car error-data) (cdr error-data)))
        (error
         (signal 'pilish-semantic-link-parser-error
                 (list (error-message-string error-data))))))
    ;; Path normalization is outside the parser-failure boundary: controlled
    ;; path `user-error' values retain their established target contract.
    (if (eq (plist-get parse-result :status) :owner)
        (if-let* ((target
                   (pilish--semantic-link-target
                    (plist-get parse-result :owner))))
            (list :status :owned-valid :target target)
          (list :status :owned-invalid))
      parse-result))))

(defun pilish--text-file-target-at-point (&optional markdown-code-span)
  "Return a strict markup-visible file target on the current line, or nil.
MARKDOWN-CODE-SPAN means semantic parsing already established code-span
ownership at point.  This buffer layer snapshots a fixed-size window around
point.  Supported raw quote wrappers complete within that snapshot remain
authoritative, including invalid quoted prose or commands; semantically owned
or fontified Markdown code remains authoritative when its delimiters lie
outside the snapshot.  Otherwise it first uses an
already-visible raw token, then projects backing buffer text according to
fontified chat markup, maps point into that projection, delegates pure candidate
parsing, and maps candidate bounds back to real buffer positions.  It never
widens, fontifies, or scans the whole current line.  Hidden
link destinations and syntax do not become candidate text.

The projection follows backing-buffer text properties, not synthetic overlay
replacement strings such as wrapped table displays, which lack character-level
source positions."
  (let* ((window (pilish--bounded-line-window-at-point))
         (window-start (plist-get window :start))
         (window-end (plist-get window :end))
         (text (buffer-substring-no-properties window-start window-end))
         (index (- (point) window-start))
         (wrapped (or markdown-code-span
                      (pilish--inside-text-wrapper-p text index)
                      (pilish--markdown-code-span-at-point-p
                       window-start window-end)))
         candidate bounds input-length)
    ;; A failed wrapper parse owns the result: never expose an inner path from
    ;; fontified `cat src/foo.el' or single-quoted prose.  Without a wrapper, a
    ;; normal visible token takes the cheap path before projection is allocated.
    (unless (pilish--position-inside-omitted-text-p
             (point) window-start window-end)
      (let* ((raw-candidate
              (if wrapped
                  (pilish--quoted-text-file-candidate-at-index
                   text index)
                (pilish--text-file-candidate-at-index text index)))
             (raw-text-visible
              (and raw-candidate
                   (pilish--raw-text-file-candidate-visible-p
                    raw-candidate window-start)))
             (raw-context-visible
              (and raw-candidate
                   (pilish--raw-diagnostic-context-visible-p
                    raw-candidate window-start)))
             (raw-visible (and raw-text-visible raw-context-visible))
             ;; An otherwise visible diagnostic candidate with hidden separator
             ;; context is authoritative-invalid.  If instead target markup is
             ;; hidden, normal visible projection remains authoritative.
             (hidden-diagnostic-context
              (and raw-candidate raw-text-visible
                   (plist-get raw-candidate :diagnostic-separator)
                   (not raw-context-visible))))
        (when raw-visible
          (let ((raw-bounds (plist-get raw-candidate :bounds)))
            (setq candidate raw-candidate
                  bounds (cons (+ window-start (car raw-bounds))
                               (+ window-start (cdr raw-bounds)))
                  input-length (length text))))
        (when (and (not candidate) (not wrapped)
                   (not hidden-diagnostic-context))
          (let* ((visible-input
                  (pilish--visible-text-with-position-map
                   window-start window-end (point)))
                 (visible-text (plist-get visible-input :text))
                 (visible-candidate
                  (pilish--text-file-candidate-at-index
                   visible-text (plist-get visible-input :index))))
            (when (and visible-candidate
                       (pilish--visible-diagnostic-context-source-p
                        visible-candidate visible-input))
              (setq candidate visible-candidate
                    bounds
                    (pilish--visible-file-candidate-buffer-bounds
                     visible-candidate visible-input)
                    input-length (length visible-text))))))
      (when-let* ((candidate candidate)
                  ;; Lexical extent includes wrappers and punctuation trimmed
                  ;; from returned bounds, so clipped windows cannot fabricate
                  ;; an apparently complete candidate.
                  (extent (or (plist-get candidate :extent)
                              (plist-get candidate :bounds)))
                  (complete-start
                   (or (> (car extent) 0)
                       (plist-get window :start-complete)))
                  (complete-end
                   (or (< (cdr extent) input-length)
                       (plist-get window :end-complete)))
                  (bounds bounds)
                  (raw (plist-get candidate :raw))
                  (path (plist-get candidate :path))
                  (anchor (pilish--chat-session-directory))
                  (emacs-path (pilish--emacs-path path anchor)))
        (pilish--make-file-target
         :text raw emacs-path
         :line (plist-get candidate :line)
         :column (plist-get candidate :column)
         :range (plist-get candidate :range)
         :bounds bounds)))))

(defun pilish--tool-overlay-at-point ()
  "Return the authoritative hot tool overlay at physical point, or nil.
Any chat restriction is restored exactly after lookup."
  (save-restriction
    (widen)
    (seq-find (lambda (overlay)
                (overlay-get overlay 'pilish-tool-block))
              (overlays-at (point)))))

(defun pilish--tool-file-target-from-metadata
    (stored-path raw-path path-error bounds line-function)
  "Return an authoritative tool target from stored metadata, or nil.
STORED-PATH, RAW-PATH, and PATH-ERROR retain the render-time path decision.
BOUNDS identify the owning hot or cold block.  LINE-FUNCTION is called only
for a valid path.  A stored error signals `user-error'; explicit path absence
returns nil."
  (cond
   (stored-path
    (unless (stringp stored-path)
      (user-error "Tool path metadata is not a string"))
    (let* ((emacs-path (pilish--tool-emacs-path stored-path))
           (raw (if (stringp raw-path) raw-path stored-path)))
      (pilish--make-file-target
       :tool raw emacs-path
       :line (funcall line-function)
       :bounds bounds)))
   (path-error
    (user-error "%s" path-error))))

(defun pilish--tool-file-target (overlay)
  "Return the authoritative file target for hot tool OVERLAY, or nil."
  (pilish--tool-file-target-from-metadata
   (overlay-get overlay 'pilish-tool-path)
   (overlay-get overlay 'pilish-tool-raw-path)
   (overlay-get overlay 'pilish-tool-path-error)
   (cons (overlay-start overlay) (overlay-end overlay))
   (lambda () (pilish--tool-line-at-point overlay))))

(defun pilish--cold-tool-block-at-point ()
  "Return authoritative cold-tool metadata and physical bounds at point.
Return nil outside a cold tool.  Any chat restriction is restored exactly."
  (save-restriction
    (widen)
    (when-let* ((metadata
                 (get-text-property (point)
                                    'pilish-cold-tool-block)))
      (let ((start (or (previous-single-property-change
                        (1+ (point)) 'pilish-cold-tool-block
                        nil (point-min))
                       (point-min)))
            (end (or (next-single-property-change
                      (point) 'pilish-cold-tool-block
                      nil (point-max))
                     (point-max))))
        (list :metadata metadata :bounds (cons start end))))))

(defun pilish--cold-tool-line-at-point (cold-block)
  "Calculate the physical meaningful file line at point for COLD-BLOCK."
  (save-restriction
    (widen)
    (let* ((metadata (plist-get cold-block :metadata))
           (bounds (plist-get cold-block :bounds))
           (header-length (plist-get metadata :header-length))
           (header-end (and (integerp header-length)
                            (+ (car bounds) header-length)))
           (line-map (plist-get metadata :line-map)))
      (pilish--tool-line-from-metadata
       (plist-get metadata :tool-name)
       (plist-get metadata :offset)
       line-map header-end (cdr bounds) line-map))))

(defun pilish--cold-tool-file-target (cold-block)
  "Return the authoritative file target for COLD-BLOCK, or nil."
  (let ((metadata (plist-get cold-block :metadata)))
    (pilish--tool-file-target-from-metadata
     (plist-get metadata :path)
     (plist-get metadata :raw-path)
     (plist-get metadata :path-error)
     (plist-get cold-block :bounds)
     (lambda () (pilish--cold-tool-line-at-point cold-block)))))

(defun pilish--file-target-at-point ()
  "Return the file target at point, or nil.
Resolution priority is authoritative hot/cold tool metadata, semantic Markdown
link ownership, then strict visible text.  Generated startup banners without
known source metadata have no file target.  Invalid or absent tool metadata
never falls through.  Semantic lookup is explicitly tri-state, so an owned
non-file, reference, or malformed link also never falls through to a path-like
label.
Child sections deliberately have no file-navigation authority."
  (let ((section (get-text-property (point) 'pilish-tool-section)))
    (unless (or (eq section 'children) (eq (car-safe section) 'child)
                (and (get-text-property (point) 'pilish-startup-banner)
                     (not (get-text-property (point) 'pilish-startup-source))))
      (if-let* ((overlay (pilish--tool-overlay-at-point)))
          (pilish--tool-file-target overlay)
        (if-let* ((cold-block (pilish--cold-tool-block-at-point)))
            (pilish--cold-tool-file-target cold-block)
          (pcase (pilish--semantic-link-file-target-at-point)
            (`(:status :owned-valid :target ,target) target)
            (`(:status :owned-invalid) nil)
            (`(:status :not-a-link . ,properties)
             (pilish--text-file-target-at-point
              (plist-get properties :markdown-code-span)))))))))

(defconst pilish--shell-execution-buffer-variables
  '(process-environment exec-path shell-file-name shell-command-switch
    process-connection-type coding-system-for-read coding-system-for-write
    default-process-coding-system process-coding-system-alist
    inherit-process-coding-system process-adaptive-read-buffering
    async-shell-command-width comint-terminfo-terminal
    tramp-remote-process-environment)
  "Narrow process-launch variables captured for one shell execution.")

(defconst pilish--shell-execution-dynamic-variables
  '(connection-local-profile-alist connection-local-criteria-alist
    connection-local-default-application enable-connection-local-variables)
  "Global connection-local configuration captured for one shell execution.")

(defun pilish--copy-shell-execution-value (value)
  "Copy VALUE for an execution snapshot, including nested strings."
  (cond
   ((stringp value) (copy-sequence value))
   ((consp value)
    (cons (pilish--copy-shell-execution-value (car value))
          (pilish--copy-shell-execution-value (cdr value))))
   ((vectorp value)
    (apply #'vector
           (mapcar #'pilish--copy-shell-execution-value value)))
   (t value)))

(defun pilish--shell-execution-snapshot (directory)
  "Snapshot shell execution state for DIRECTORY in the current chat buffer.
The snapshot is taken before prompting and owns one command launch.  It includes
DIRECTORY; effective process environment, executable path, shell and switch;
process/coding values; and remote connection configuration used by native
file-process dispatch.  Local asynchronous terminal variables are resolved now
so an existing output buffer cannot replace the invocation environment."
  (require 'comint)
  (let* ((directory (copy-sequence directory))
         (remote-p (file-remote-p directory))
         (buffer-variables
          (if remote-p
              pilish--shell-execution-buffer-variables
            (remq 'tramp-remote-process-environment
                  pilish--shell-execution-buffer-variables)))
         (buffer-values
          (delq nil
                (mapcar
                 (lambda (variable)
                   (and (boundp variable)
                        (cons variable
                              (pilish--copy-shell-execution-value
                               (symbol-value variable)))))
                 buffer-variables)))
         (base-environment
          (pilish--copy-shell-execution-value process-environment))
         (default-directory directory)
         (async-environment
          (append
           (and (natnump async-shell-command-width)
                (list (format "COLUMNS=%d" async-shell-command-width)))
           (comint-term-environment)
           base-environment)))
    (list
     :directory directory
     :buffer-values buffer-values
     :async-process-environment async-environment
     :dynamic-values
     ;; A remote handler can recalculate effective values from these global
     ;; tables.  Freeze them only for remote dispatch; local launches need no
     ;; broad connection-profile capture.
     (and remote-p
          (delq nil
                (mapcar
                 (lambda (variable)
                   (and (boundp variable)
                        (cons variable
                              (pilish--copy-shell-execution-value
                               (symbol-value variable)))))
                 pilish--shell-execution-dynamic-variables))))))

(defun pilish--call-with-shell-buffer-values (values function)
  "Call FUNCTION after temporarily installing buffer-local VALUES.
VALUES is an alist from an execution snapshot.  Restore both each value and its
original localness after the launch attempt, including when installation fails."
  (let ((buffer (current-buffer))
        originals)
    (unwind-protect
        (progn
          (dolist (entry values)
            (let ((variable (car entry)))
              (push (list variable
                          (local-variable-p variable buffer)
                          (boundp variable)
                          (and (boundp variable) (symbol-value variable)))
                    originals)
              (set (make-local-variable variable) (cdr entry))))
          (funcall function))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (dolist (original originals)
            (cond
             ((not (nth 1 original))
              (kill-local-variable (car original)))
             ((nth 2 original)
              (set (make-local-variable (car original)) (nth 3 original)))
             (t
              (make-local-variable (car original))
              (makunbound (car original))))))))))

(defun pilish--async-shell-mode ()
  "Enter the native asynchronous shell output mode for this Emacs version."
  (if (and (>= emacs-major-version 30)
           (boundp 'async-shell-command-mode))
      (funcall async-shell-command-mode)
    (shell-mode)))

(defun pilish--async-shell-display-action (&optional deferred)
  "Return native async display action, with version handling for DEFERRED.
Immediate display uses `allow-no-window' on Emacs 29 and later.  Deferred
first-output display gained that action in Emacs 30."
  (and (or (not deferred) (>= emacs-major-version 30))
       '(nil (allow-no-window . t))))

(defun pilish--start-snapshotted-async-shell-command
    (snapshot command &optional output-buffer)
  "Start local asynchronous COMMAND under SNAPSHOT with native shell UI.
COMMAND has no terminal ampersand.  OUTPUT-BUFFER, when non-nil, is the buffer
or name reused by native revert behavior.  This mirrors only the Emacs
29.4/30.1 local async branch that surrounds process launch; compatibility
helpers centralize their mode and display differences.  Preserve native buffer
naming, conflict policy, output retention, process name, sentinel, filter,
revert, and display behavior while replacing only process-launch values."
  (let* ((buffer (get-buffer-create
                  (or output-buffer shell-command-buffer-name-async
                      "*Async Shell Command*")))
         (buffer-name (buffer-name buffer))
         (process (get-buffer-process buffer))
         (directory (plist-get snapshot :directory)))
    (when process
      (cond
       ((eq async-shell-command-buffer 'confirm-kill-process)
        (shell-command--same-buffer-confirm "Kill it")
        (kill-process process))
       ((eq async-shell-command-buffer 'confirm-new-buffer)
        (shell-command--same-buffer-confirm "Use a new buffer")
        (setq buffer (generate-new-buffer buffer-name)))
       ((eq async-shell-command-buffer 'new-buffer)
        (setq buffer (generate-new-buffer buffer-name)))
       ((eq async-shell-command-buffer 'confirm-rename-buffer)
        (shell-command--same-buffer-confirm "Rename it")
        (with-current-buffer buffer (rename-uniquely))
        (setq buffer (get-buffer-create buffer-name)))
       ((eq async-shell-command-buffer 'rename-buffer)
        (with-current-buffer buffer (rename-uniquely))
        (setq buffer (get-buffer-create buffer-name)))))
    (with-current-buffer buffer
      (shell-command-save-pos-or-erase)
      (setq default-directory directory)
      (require 'shell)
      (let* ((values (copy-tree (plist-get snapshot :buffer-values)))
             (environment-entry (assq 'process-environment values)))
        (if environment-entry
            (setcdr environment-entry
                    (copy-sequence
                     (plist-get snapshot :async-process-environment)))
          (push (cons 'process-environment
                      (copy-sequence
                       (plist-get snapshot :async-process-environment)))
                values))
        (cl-progv (mapcar #'car values) (mapcar #'cdr values)
          (setq process
                (start-process-shell-command "Shell" buffer command))))
      (setq mode-line-process '(":%s"))
      (pilish--async-shell-mode)
      (setq-local revert-buffer-function
                  (lambda (&rest _)
                    (pilish--start-snapshotted-async-shell-command
                     snapshot command buffer)))
      (set-process-sentinel process #'shell-command-sentinel)
      (set-process-filter process #'comint-output-filter)
      (if async-shell-command-display-buffer
          (display-buffer buffer (pilish--async-shell-display-action))
        (let ((nonce (make-symbol "nonce")))
          (add-function
           :before (process-filter process)
           (lambda (proc _string)
             (let ((output (process-buffer proc)))
               (when (buffer-live-p output)
                 (remove-function (process-filter proc) nonce)
                 (display-buffer
                  output (pilish--async-shell-display-action t)))))
           `((name . ,nonce))))))))

(defun pilish--call-native-shell-command (snapshot command)
  "Run COMMAND through native shell machinery under execution SNAPSHOT."
  (let* ((dynamic-values (plist-get snapshot :dynamic-values))
         (dynamic-symbols (mapcar #'car dynamic-values))
         (dynamic-bindings (mapcar #'cdr dynamic-values)))
    (cl-progv dynamic-symbols dynamic-bindings
      (pilish--call-with-shell-buffer-values
       (plist-get snapshot :buffer-values)
       (lambda ()
         (let* ((default-directory (plist-get snapshot :directory))
                (handler
                 (find-file-name-handler
                  (directory-file-name default-directory) 'shell-command)))
           (if (and (not handler)
                    (string-match "[ \t]*&[ \t]*\\'" command))
               (pilish--start-snapshotted-async-shell-command
                snapshot (substring command 0 (match-beginning 0)))
             (shell-command command))))))))

(defun pilish--call-with-shell-directory (directory function)
  "Call FUNCTION with DIRECTORY as the current shell working directory.
Stay in the current buffer so its shell and process environment apply.  If a
canonical chat session transition occurs during the call, keep that transition's
new `default-directory' after the temporary binding unwinds."
  (let ((session-directory (pilish--chat-session-directory)))
    (unwind-protect
        (let ((default-directory directory))
          (funcall function))
      (let ((current-session-directory
             (pilish--chat-session-directory)))
        (unless (equal session-directory current-session-directory)
          (setq default-directory current-session-directory))))))

(defun pilish-shell-command-at-point ()
  "Read and run a Dired-inspired command on the file target at point.
One command word followed only by whitespace-delimited options beginning with
`-' automatically receives the safely quoted target.  All other command text,
including ordinary arguments, compound/control syntax, and multiple lines,
must place a textual isolated `*' bounded on each side by a space, tab, or
string edge.  A terminal whitespace-delimited ` &' uses asynchronous shell
output.  Prompting and execution use a snapshot of the target session's local
or TRAMP execution environment."
  (interactive)
  (let* ((target (or (pilish--file-target-at-point)
                     (user-error "No file at point")))
         ;; Do this before opening the minibuffer: shell-only target failures
         ;; must not consume input, and TARGET must remain a stable snapshot.
         (argument (pilish--file-target-shell-argument target))
         (shell-directory (plist-get target :shell-directory))
         (execution-snapshot
          (pilish--shell-execution-snapshot shell-directory))
         (command
          (pilish--call-with-shell-directory
           shell-directory
           (lambda ()
             (read-shell-command
              (format "! on %s: " (plist-get target :display))))))
         (shell-command-text
          (pilish--shell-command-with-file command argument)))
    ;; Reuse the target snapshot even if the chat changed sessions while the
    ;; prompt was active.
    (pilish--call-with-shell-directory
     shell-directory
     (lambda ()
       (pilish--call-native-shell-command
        execution-snapshot shell-command-text)))))

(defun pilish--goto-file-target-location (line column)
  "Move to optional one-based physical LINE and COLUMN in the current file.
A nil LINE preserves the point, mark, and restriction established by native
file visiting.  Explicit locations are computed against the full file, clamp
at physical EOF or EOL, and deactivate any stale region after a successful
move.  COLUMN uses display columns and never inserts text.  If the resulting
position is inaccessible, obey `widen-automatically': widen when non-nil, or
signal `user-error' without changing point or the restriction when nil.  Range
starts are already represented by LINE; range ends and link fragments do not
affect navigation."
  (when line
    (let ((position
           (save-excursion
             (save-restriction
               (widen)
               (goto-char (point-min))
               (forward-line (1- line))
               (when column
                 ;; Emacs 29's `move-to-column' requires a fixnum, while strict
                 ;; target parsing can produce a larger integer.  Either value
                 ;; is past any real line end, so this preserves EOL clamping.
                 (move-to-column (min (1- column) most-positive-fixnum)))
               (point)))))
      (cond
       ((and (<= (point-min) position) (<= position (point-max))))
       (widen-automatically (widen))
       (t (user-error "Position is outside accessible part of buffer")))
      (goto-char position)
      (deactivate-mark))))

(defun pilish--validate-file-target-location (source line column)
  "Validate SOURCE's optional one-based LINE and COLUMN before opening.
Tool rows retain their established controlled error for any absent or malformed
mapped LINE.  Other sources may omit a location, but explicit coordinates must
be positive integers and COLUMN requires LINE."
  (cond
   ((eq source :tool)
    (unless (pilish--positive-location-p line)
      (user-error "No file line at point")))
   ((and line (not (pilish--positive-location-p line)))
    (user-error "File line must be a positive integer")))
  (cond
   ((and column (not (pilish--positive-location-p line)))
    (user-error "File column requires a valid line"))
   ((and column (not (pilish--positive-location-p column)))
    (user-error "File column must be a positive integer"))))

(defun pilish--visit-file-target (target toggle)
  "Visit TARGET, honoring TOGGLE's window inversion.
Validate locations before requesting a native opener.  After opening, apply a
location only when the resulting buffer actually visits a file; native Dired
buffers and other non-file buffers retain the point and mark chosen by Emacs.
A target without a location preserves native behavior."
  (let ((source (plist-get target :source))
        (path (plist-get target :emacs-path))
        (line (plist-get target :line))
        (column (plist-get target :column)))
    (pilish--validate-file-target-location source line column)
    (let ((use-other-window
           (if toggle
               (not pilish-visit-file-other-window)
             pilish-visit-file-other-window)))
      (funcall (if use-other-window #'find-file-other-window #'find-file)
               path))
    ;; Decide applicability from public post-open buffer semantics.  In
    ;; particular, do not preflight local or remote paths to detect directories.
    (when (and line
               (buffer-file-name (current-buffer))
               (not (derived-mode-p 'dired-mode)))
      (pilish--goto-file-target-location line column))))

(defun pilish--dispatch-button
    (&optional position use-mouse-action strict-return)
  "Dispatch a remapped chat button at POSITION.
On keyboard RET, Pi tool toggles and owned saved subagent names retain their
button actions.  Other buttons resolve through the strict file-target visitor:
authoritative
tool ownership is preserved, while only a semantically owned local Markdown
link is accepted outside tools.  Invalid, non-local, reference, malformed, and
non-Markdown buttons fail closed.  Other keyboard keys, mouse events, and direct
calls to `push-button' retain standard behavior.  USE-MOUSE-ACTION has the same
meaning as for `push-button'.  STRICT-RETURN is non-nil only for interactive
RET."
  (interactive
   (list (if (mouse-event-p last-command-event) last-command-event (point))
         nil
         (member (this-single-command-keys) '([?\r] [return]))))
  (if (not strict-return)
      (push-button position use-mouse-action)
    (if-let* ((button (button-at (or position (point)))))
        (if (or (button-get button 'pilish-tool-toggle)
                (and (eq (button-get button 'action) #'pilish--subagent-button-action)
                     (pilish--snapshot-target-p (button-get button 'pilish-subagent-name))))
            (push-button position use-mouse-action)
          (let ((target (or (pilish--file-target-at-point)
                            (user-error "No file at point"))))
            (if (memq (plist-get target :source) '(:tool :link))
                (pilish--visit-file-target
                 target current-prefix-arg)
              (user-error "No file at point"))))
      (push-button position use-mouse-action))))

(defun pilish-visit-file (&optional toggle)
  "Open an owned saved subagent name or one strict file target at point.
File targets may be content rows in tool output, plain path references, or
labels of local Markdown links.  Tool headers and other non-content rows are
not visitable.  Plain path locations use a one-based physical file line and
optional one-based column; a line range visits its first line only.  Explicit
locations obey `widen-automatically' in file-visiting buffers and are ignored in
native Dired buffers.  Targets without a location preserve native point,
mark, and narrowing.  By default, `pilish-visit-file-other-window'
selects which native opener Pi requests; Emacs display policy controls final
placement.  With prefix argument TOGGLE, invert the opener request."
  (interactive "P")
  (let ((name (get-text-property (point) 'pilish-subagent-name)))
    (cond
     ((pilish--snapshot-target-p name) (pilish-open-subagent-snapshot name))
     ((stringp name) (user-error "Saved snapshot unavailable: %s" name))
     (t
      (let ((target (or (pilish--file-target-at-point)
                        (user-error "No file at point"))))
        (pilish--visit-file-target target toggle))))))

(defun pilish-copy-file-path ()
  "Copy the shell-local path for the strict file target at point.
Path resolution matches `pilish-shell-command-at-point': local paths are
absolute, while paths in remote sessions use the remote shell's namespace
without a TRAMP prefix.  Line, column, range, and link-fragment metadata are
not part of the path.  The `kill-ring' value is unquoted pathname text, not
shell syntax."
  (interactive)
  (let* ((target (or (pilish--file-target-at-point)
                     (user-error "No file at point")))
         (path (pilish--file-target-shell-path target)))
    (kill-new path)
    (message "Pi: Copied %s"
             (pilish--escape-control-chars-for-display path))))

;;;; Diff Overlay Highlighting

;; Overlay priorities determine stacking order (higher = on top)
;; Tool-block overlay has no priority (defaults to 0)
(defconst pilish--diff-line-priority 10
  "Priority for diff line background overlays.
Higher than tool-block (0) so diff colors show through.")

(defconst pilish--diff-indicator-priority 20
  "Priority for diff indicator (+/-) overlays.
Higher than line background so indicator face isn't obscured.")

(defun pilish--apply-diff-overlays (start end)
  "Apply diff highlighting overlays to region from START to END.
Scans for lines starting with +/- and applies diff faces via overlays.
Overlays survive font-lock refontification, unlike text properties.
The diff format from pi is: [+-]<space><padded-line-number><space><code>
For example: '+ 7     code' or '-12     code'"
  (save-excursion
    (goto-char start)
    (while (re-search-forward "^\\([+-]\\) *\\([0-9]+\\)" end t)
      (let* ((indicator (match-string 1))
             (is-added (string= indicator "+"))
             (indicator-start (match-beginning 1))
             (line-end (line-end-position))
             ;; Overlay for the indicator character
             (ind-ov (make-overlay indicator-start (match-end 1)))
             ;; Overlay for the rest of the line (background color)
             (line-ov (make-overlay (match-beginning 1) line-end)))
        ;; Indicator face (+/-) - highest priority to show on top
        (overlay-put ind-ov 'face (if is-added
                                      'diff-indicator-added
                                    'diff-indicator-removed))
        (overlay-put ind-ov 'priority pilish--diff-indicator-priority)
        (overlay-put ind-ov 'pilish-diff-overlay t)
        ;; Line background face - higher than tool-block but lower than indicator.
        ;; Use theme-derived background-only faces so syntax foregrounds stay visible.
        (overlay-put line-ov 'face (if is-added
                                      'pilish-diff-line-added
                                    'pilish-diff-line-removed))
        (overlay-put line-ov 'priority pilish--diff-line-priority)
        (overlay-put line-ov 'pilish-diff-overlay t)))))

;;;; Compaction Display

(defun pilish--display-compaction-result (tokens-before summary &optional timestamp)
  "Display a compaction result block in the transcript.
TOKENS-BEFORE is the token count before compaction.
SUMMARY is the compaction summary text (markdown).
TIMESTAMP is optional time when compaction occurred."
  (let ((start (with-current-buffer (pilish--get-render-buffer) (point-max))))
    (pilish--append-to-chat
     (concat "\n" (pilish--make-separator "Compaction" timestamp) "\n"
             (propertize (format "Compacted from %s tokens\n\n"
                                 (pilish--format-number (or tokens-before 0)))
                         'face 'pilish-tool-name)
             (pilish--render-safe-string summary) "\n"))
    (with-current-buffer (pilish--get-render-buffer)
      (setq pilish--assistant-header-shown nil)
      (pilish--decorate-tables-unless-deferred start (point-max)))))

(defun pilish--display-branch-summary (summary &optional timestamp)
  "Display a branch SUMMARY block in the transcript.
TIMESTAMP is the optional time when the branch summary was created."
  (let ((start (with-current-buffer (pilish--get-render-buffer) (point-max))))
    (pilish--append-to-chat
     (concat "\n" (pilish--make-separator "Branch Summary" timestamp) "\n"
             (pilish--render-safe-string summary) "\n"))
    (with-current-buffer (pilish--get-render-buffer)
      (pilish--decorate-tables-unless-deferred start (point-max)))))

(defun pilish--handle-compaction-success (tokens-before summary &optional timestamp)
  "Handle successful compaction: display result and notify user.
TOKENS-BEFORE is the pre-compaction token count.
SUMMARY is the compaction summary text.
TIMESTAMP is optional time when compaction occurred."
  (pilish--display-compaction-result tokens-before summary timestamp)
  (pilish--refresh-header)
  (message "Pi: Compacted from %s tokens" (pilish--format-number (or tokens-before 0))))

(defun pilish--render-complete-message ()
  "Finalize completed message: ensure trailing newline, decorate tables.
Uses message-start-marker and streaming-marker to find content.
No explicit fontification needed — jit-lock + tree-sitter fontify
at each redisplay cycle during streaming, and any remaining gaps
are fontified at the redisplay after this function returns.
Display-only table decoration is applied after the content is stable."
  (when (and pilish--message-start-marker pilish--streaming-marker)
    (let ((start (marker-position pilish--message-start-marker))
          (end (marker-position pilish--streaming-marker)))
      (when (< start end)
        (let ((inhibit-read-only t))
          (pilish--with-scroll-preservation
            (save-excursion
              (goto-char end)
              (unless (eq (char-before) ?\n)
                (insert "\n")
                (set-marker pilish--streaming-marker (point))))))
        (if (pilish--chat-buffer-hidden-p)
            (setq pilish--table-decoration-pending t)
          (pilish--decorate-tables-in-region
           start (marker-position pilish--streaming-marker)))))))

;;;; Tool Property Restoration

(defun pilish--restore-tool-properties (beg end)
  "Restore literal metadata after tree-sitter fontification in BEG..END.
Strip Markdown hiding, faces and link buttons from literal argument text,
saved assistant outcomes, child summaries and full-output paths, including
cold text without overlays.
Preserve image preview display properties and the outcome notice face.
Restore `font-lock-face' values for all
overlapping tool headers, live or finalized."
  (let ((inhibit-read-only t)
        (pos beg))
    (while (< pos end)
      (let* ((limit (min (next-single-property-change pos 'pilish-nested-summary nil end)
                         (next-single-property-change pos 'pilish-tool-section nil end)
                         (next-single-property-change pos 'pilish-argument-literal nil end)
                         (next-single-property-change pos 'pilish-argument-guard nil end)
                         (next-single-property-change pos 'pilish-tool-diagnostic-guard nil end)
                         (next-single-property-change pos 'pilish-assistant-outcome nil end)))
             (outcome (get-text-property pos 'pilish-assistant-outcome))
             (argument-p (get-text-property pos 'pilish-argument-literal)))
        (when (or outcome argument-p (get-text-property pos 'pilish-nested-summary)
                  (eq (get-text-property pos 'pilish-tool-section) 'full-output))
          (when (fboundp 'md-ts--remove-link-button-properties)
            (md-ts--remove-link-button-properties pos limit))
          (remove-text-properties pos limit '(invisible nil display nil face nil))
          (when outcome (put-text-property pos limit 'face 'pilish-error-notice))
          (when (or (get-text-property pos 'pilish-argument-guard)
                    (get-text-property pos 'pilish-tool-diagnostic-guard))
            (put-text-property pos limit 'display ""))
          (when argument-p
            (put-text-property pos limit 'rear-nonsticky t)
            (let ((face-pos pos))
              (while (< face-pos limit)
                (let ((next (next-single-property-change face-pos 'font-lock-face nil limit))
                      (face (get-text-property face-pos 'font-lock-face)))
                  (when face (put-text-property face-pos next 'face face))
                  (setq face-pos next))))))
        (setq pos limit)))
    (dolist (ov (pilish--tool-block-overlays-in-region beg end))
      (when-let* ((ov-start (overlay-start ov))
                  (ov-end (overlay-end ov))
                  (header-end-marker (overlay-get ov 'pilish-header-end))
                  (header-end (marker-position header-end-marker)))
        (when (and (< beg ov-end) (> end ov-start))
          ;; Header: restore face from font-lock-face (varies per span)
          (let ((hdr-beg (max beg ov-start))
                (hdr-end (min end header-end)))
            (when (< hdr-beg hdr-end)
              (remove-text-properties
               hdr-beg hdr-end
               '(invisible nil))
              (let ((pos hdr-beg))
                (while (< pos hdr-end)
                  (let* ((fl-face (get-text-property pos 'font-lock-face))
                         (next (or (next-single-property-change
                                    pos 'font-lock-face nil hdr-end)
                                   hdr-end)))
                    (when fl-face
                      (put-text-property pos next 'face fl-face))
                    (setq pos next))))
              (put-text-property hdr-beg hdr-end 'fontified t))))
        (pilish--tool-place-prefixes ov-start ov-end)))
    (pilish--restore-subagent-buttons beg end)))

;;;; History Display

(defun pilish--extract-history-user-message-text (message)
  "Extract visible user text from history MESSAGE.
Supports both string content and text-block vectors.  Returns nil when
MESSAGE has no visible text content."
  (let ((content (plist-get message :content)))
    (cond
     ((stringp content)
      (unless (string-empty-p content) content))
     ((vectorp content)
      (pilish--extract-user-message-text content))
     (t nil))))

(defun pilish--completed-thinking-rendered-from-normalized
    (normalized &optional block-order display details)
  "Return completed thinking NORMALIZED text rendered for DISPLAY.
BLOCK-ORDER identifies the logical completed-thinking block across rerenders.
DETAILS is the owning message's literal report when known.
Returns nil when NORMALIZED has no visible completed-thinking content."
  (unless (string-empty-p normalized)
    (let ((display (or display (pilish--thinking-display-mode))))
      (pilish--propertize-completed-thinking
       (pcase display
         ('hidden (pilish--thinking-hidden-stub normalized))
         (_ (pilish--thinking-blockquote-text normalized)))
       (or block-order (pilish--next-thinking-block-order))
       normalized
       display
       (or details (pilish--format-thinking-details nil normalized))))))

(defun pilish--completed-thinking-rendered-text
    (text &optional block-order display details)
  "Return completed thinking TEXT rendered for DISPLAY.
BLOCK-ORDER identifies the logical completed-thinking block across rerenders.
DETAILS is the owning message's literal report when known.
Returns nil when TEXT normalizes to no visible thinking content."
  (pilish--completed-thinking-rendered-from-normalized
   (pilish--thinking-normalize-text text)
   block-order
   display
   details))

(defun pilish--render-history-thinking (text &optional message)
  "Render completed thinking TEXT for assistant MESSAGE during history replay.
Uses the current buffer's completed-thinking display mode."
  (let* ((normalized (pilish--thinking-normalize-text text))
         (details (pilish--format-thinking-details message normalized)))
    (when-let* ((rendered
                 (pilish--completed-thinking-rendered-from-normalized
                  normalized nil nil details)))
      (pilish--render-history-text rendered details))))

(defun pilish--build-tool-result-index (messages)
  "Build hash-table mapping toolCallId to toolResult message from MESSAGES."
  (let ((index (make-hash-table :test 'equal)))
    (when (vectorp messages)
      (dotimes (i (length messages))
        (let ((msg (aref messages i)))
          (when (equal (plist-get msg :role) "toolResult")
            (puthash (plist-get msg :toolCallId) msg index)))))
    index))

(defun pilish--history-postprocess-start ()
  "Return the first position that needs eager history post-processing.
Large resumed histories should render the visible tail promptly.  Older content
can rely on normal jit-lock when visited, while display-only table decoration is
kept to the same hot-tail suffix used by resize refreshes."
  (if (markerp pilish--hot-tail-start)
      (marker-position pilish--hot-tail-start)
    (point-min)))

(defconst pilish--history-table-separator-candidate-re
  "^[ \t>]*|?[-:| \t]*---[-:| \t]*|[-:| \t]*$"
  "Regex matching a cheap markdown pipe-table separator candidate.
This avoids invoking tree-sitter for ordinary prose or shell commands that
contain `|' but cannot be pipe tables.")

(defun pilish--history-table-candidate-p (start end)
  "Return non-nil when START..END may contain a markdown pipe table."
  (save-excursion
    (goto-char start)
    (re-search-forward
     pilish--history-table-separator-candidate-re end t)))

(defun pilish--postprocess-history-buffer ()
  "Run consolidated display post-processing after history replay.
History replay inserts many small user/assistant chunks.  Running fontification
and table decoration after each chunk is expensive in large sessions, so replay
defers that work.  Fontification is left to jit-lock on redisplay; the only
synchronous pass decorates candidate tables in the recent hot tail."
  (let ((start (pilish--history-postprocess-start))
        (end (point-max)))
    (when (pilish--history-table-candidate-p start end)
      ;; Narrowing keeps tree-sitter's initial parse proportional to the hot
      ;; tail instead of the entire resumed transcript.
      (save-restriction
        (narrow-to-region start end)
        (pilish--decorate-tables-in-region start end)))))

(defun pilish--render-history-text (text &optional details)
  "Render TEXT as markdown content with proper isolation.
Literal DETAILS is applied to the inserted content.
Ensures markdown structures don't leak to subsequent content.
Display-only table decoration is applied after deferred history insertion."
  (when (and text (not (string-empty-p text)))
    (let ((start (with-current-buffer (pilish--get-render-buffer) (point-max))))
      (pilish--append-to-chat text)
      (with-current-buffer (pilish--get-render-buffer)
        (let ((content-end (point-max)))
          ;; History replay should keep rendering even if markdown
          ;; fontification trips over a tree-sitter/runtime mismatch.
          ;; Preserve debugger behavior when `debug-on-error' is non-nil.
          (unless (pilish--history-postprocessing-deferred-p)
            (condition-case-unless-debug nil
                (font-lock-ensure start content-end)
              (error nil))
            (pilish--decorate-tables-in-region start content-end))
          (when details
            (pilish--set-details start content-end details))))
      ;; Two trailing newlines reset any open markdown list/paragraph context
      (pilish--append-to-chat "\n\n"))))

(defun pilish--render-history-tool (tool-call result)
  "Render a single tool from history: TOOL-CALL block with its RESULT.
TOOL-CALL is a content block plist with :type \"toolCall\", :id, :name,
and :arguments.  RESULT is the matching toolResult message, or nil."
  (let* ((tool-name (plist-get tool-call :name))
         (args (plist-get tool-call :arguments))
         (block (pilish--display-tool-start tool-name args)))
    ;; Display identity is not execution registration.  History rows have no
    ;; runtime owner, owed end, or child result to replay.
    (setf (pilish--tool-block-tool-call-id block) (plist-get tool-call :id)
          (pilish--tool-block-args block) args
          (pilish--tool-block-history-p block) t)
    (pilish--argument-observe block nil tool-name args)
    (pilish--replace-tool-header
     block (pilish--argument-header-text block tool-name args))
    (pilish--merge-saved-nested-calls block (pilish--tool-arg-get result :nestedCalls))
    (pilish--merge-codemode-calls
     block (pilish--tool-arg-get (pilish--tool-arg-get result :details) :calls) t)
    (when (pilish--tool-block-compound-p block)
      (pilish--display-tool-update-header tool-name args block))
    (if result
        (pilish--display-tool-end
         tool-name args
         (plist-get result :content)
         (plist-get result :details)
         (plist-get result :isError)
         block)
      (pilish--tool-overlay-finalize 'pilish-tool-block block)
      (let ((inhibit-read-only t))
        (save-excursion (goto-char (point-max)) (insert "\n"))))
    (setf (pilish--tool-block-details block)
          (pilish--format-tool-details tool-name args result))
    (pilish--tool-block-apply-details block)))

(defun pilish--render-history-assistant-content (message results)
  "Render assistant MESSAGE content in order, followed by its saved outcome.
RESULTS maps toolCallId strings to matching toolResult messages."
  (let ((content (plist-get message :content))
        (details (pilish--format-reply-details message))
        (pending-text nil))
    (cl-labels ((flush-text ()
                  (when pending-text
                    (pilish--render-history-text
                     (string-join (nreverse pending-text) "")
                     details)
                    (setq pending-text nil))))
      (cond
       ((stringp content)
        (unless (string-empty-p content)
          (pilish--render-history-text content details)))
       ((vectorp content)
        (dolist (block (pilish--content-block-list content))
          (let ((block-type (plist-get block :type)))
            (pcase block-type
              ("text"
               (push (pilish--render-safe-string
                      (plist-get block :text))
                     pending-text))
              ("thinking"
               (flush-text)
               (pilish--render-history-thinking
                (pilish--render-safe-string
                 (plist-get block :thinking))
                message))
              ("toolCall"
               (flush-text)
               (pilish--render-history-tool
                block (gethash (plist-get block :id) results))))))
        (flush-text)))))
  (when-let* ((label (pcase (plist-get message :stopReason)
                      ("error" "Error")
                      ("aborted" "Aborted"))))
    (let ((explanation (plist-get message :errorMessage)))
      (pilish--append-to-chat
       (concat "\n"
               (propertize (concat "[" label
                                   (when (and (stringp explanation) (not (string-empty-p explanation)))
                                     (concat ": " explanation))
                                   "]")
                           'face 'pilish-error-notice 'pilish-assistant-outcome t)
               "\n")))))

(defun pilish--rewrite-tail-window-p
    (window-point window-end point-max point-row body-height)
  "Return non-nil when WINDOW-POINT or WINDOW-END should follow a rewritten tail.
A WINDOW-POINT at or just before POINT-MAX is tail-following.  A WINDOW-END that
merely reaches POINT-MAX counts only when POINT-ROW already sits in the lower
half of BODY-HEIGHT, so tall windows inspecting mid-buffer context do not get
misclassified as tail-following just because they can also see the tail."
  (or (>= window-point (1- point-max))
      (and (>= window-end (1- point-max))
           (< point-row (max 1 body-height))
           (>= point-row (/ (max 1 body-height) 2)))))

(defun pilish--clamp-rewrite-point-row (saved-row above-lines tail-lines body-height)
  "Clamp SAVED-ROW after a buffer rewrite.
ABOVE-LINES counts screen lines before point, TAIL-LINES counts screen lines
from point through the tail, and BODY-HEIGHT is the window body height in
screen lines.

When the whole buffer is shorter than the window, preserving a full window is
impossible, so the row falls back to the highest still-visible row.  Otherwise,
clamp the row so the tail still fills the window after the rewrite."
  (let* ((max-row (min (max 0 (1- body-height)) above-lines))
         (total-lines (+ above-lines tail-lines)))
    (if (< total-lines body-height)
        (min saved-row max-row)
      (let ((min-row (max 0 (- body-height tail-lines))))
        (max min-row (min saved-row max-row))))))

(defun pilish--live-thinking-start-at-pos (pos)
  "Return active thinking block start when POS is inside live thinking."
  (when (and (markerp pilish--thinking-start-marker)
             (markerp pilish--thinking-marker)
             (marker-position pilish--thinking-start-marker)
             (marker-position pilish--thinking-marker))
    (let ((start (marker-position pilish--thinking-start-marker))
          (end (marker-position pilish--thinking-marker)))
      (when (and (<= start pos) (< pos end))
        start))))

(defun pilish--capture-window-rewrite-state (window point-max)
  "Return saved WINDOW state before a buffer rewrite.
POINT-MAX is the old buffer end before the rewrite begins."
  (let* ((point (window-point window))
         (body-height (max 1 (window-body-height window)))
         (row (pilish--count-screen-lines-up-to
               (window-start window) point body-height window)))
    (list :window window
          :tail-p (pilish--rewrite-tail-window-p
                   point
                   (window-end window t)
                   point-max
                   row
                   body-height)
          :start (window-start window)
          :point point
          :thinking-block (pilish--thinking-block-at-pos point)
          :live-thinking-start (pilish--live-thinking-start-at-pos point)
          :row row)))

(defun pilish--capture-window-rewrite-states ()
  "Return saved rewrite states for visible windows showing the current buffer."
  (let ((old-point-max (point-max))
        (buffer (current-buffer)))
    (mapcar (lambda (win)
              (pilish--capture-window-rewrite-state win old-point-max))
            (get-buffer-window-list buffer nil t))))

(defun pilish--adjust-pos-after-region-replacements
    (pos replacements)
  "Return POS adjusted after REPLACEMENTS, or nil when POS was deleted.
Each entry in REPLACEMENTS is (START END DELTA), using coordinates from before
any replacement was applied."
  (let ((total-delta 0))
    (catch 'deleted
      (dolist (replacement replacements (+ pos total-delta))
        (pcase-let ((`(,start ,end ,delta) replacement))
          (cond
           ((and (<= start pos) (< pos end))
            (throw 'deleted nil))
           ((>= pos end)
            (setq total-delta (+ total-delta delta)))))))))

(defun pilish--map-window-rewrite-pos (pos map-position fallback)
  "Map old POS through MAP-POSITION, or return FALLBACK when POS was deleted."
  (if map-position
      (or (funcall map-position pos) fallback)
    (min pos (point-max))))

(defun pilish--resolve-window-rewrite-point
    (window-state &optional map-position)
  "Return the best restored point for WINDOW-STATE after a buffer rewrite.
When point was inside a completed or live thinking block, prefer the rewritten
block start.  Otherwise map the saved numeric point through MAP-POSITION when
provided, or clamp it into the rewritten buffer."
  (or (pilish--thinking-block-start
       (plist-get window-state :thinking-block))
      (plist-get window-state :live-thinking-start)
      (pilish--map-window-rewrite-pos
       (plist-get window-state :point)
       map-position
       (min (plist-get window-state :point) (point-max)))))

(defun pilish--restore-window-rewrite-state
    (window-state &optional map-position)
  "Restore WINDOW-STATE after a large buffer rewrite.
Tail-following windows stay pinned to the rewritten tail.  Other windows
restore point, then recenter to a clamped screen-line row so the window stays
filled when possible instead of showing a mostly blank tail view.
MAP-POSITION, when non-nil, maps old buffer positions to new ones and returns
nil for positions deleted by the rewrite."
  (let ((win (plist-get window-state :window)))
    (when (and (window-live-p win)
               (eq (window-buffer win) (current-buffer)))
      (with-selected-window win
        (let* ((point-max (point-max))
               (point (pilish--resolve-window-rewrite-point
                       window-state map-position)))
          (if (plist-get window-state :tail-p)
              (progn
                (goto-char point-max)
                (recenter -1))
            (goto-char point)
            (let* ((body-height (max 1 (window-body-height win)))
                   (saved-start
                    (pilish--map-window-rewrite-pos
                     (plist-get window-state :start)
                     map-position
                     point)))
              (if (pilish--window-start-fills-window-within-one-row-p
                   saved-start point-max body-height win)
                  (progn
                    (set-window-start win saved-start t)
                    (set-window-point win (max point saved-start)))
                (let* ((above-lines (pilish--count-screen-lines-up-to
                                     (point-min) point (max 0 (1- body-height)) win))
                       (tail-lines (max 1 (pilish--count-screen-lines-up-to
                                          point point-max body-height win)))
                       (row (pilish--clamp-rewrite-point-row
                             (plist-get window-state :row)
                             above-lines
                             tail-lines
                             body-height)))
                  (recenter row))))))))))

(defun pilish--restore-window-rewrite-states
    (buffer window-states &optional map-position)
  "Restore WINDOW-STATES for BUFFER after a large rewrite.
MAP-POSITION is passed to `pilish--restore-window-rewrite-state'."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (save-selected-window
        (dolist (window-state window-states)
          (pilish--restore-window-rewrite-state
           window-state map-position))))))

(defun pilish--rerender-canonical-history ()
  "Rebuild the current chat buffer from cached canonical messages.
Visible chat windows keep useful context after the rewrite: windows already at
or showing the tail stay at the rebuilt tail, while other windows restore point
and approximately the same screen-line row, clamped so the window stays filled
when possible."
  (let ((messages pilish--canonical-messages))
    (when (vectorp messages)
      (pilish--with-window-rewrite-preservation
        (pilish--display-session-history messages (current-buffer)))
      (pilish--fontify-visible-transcript-windows))))

(defun pilish--set-chat-thinking-display (mode)
  "Set completed-thinking display MODE for the current chat buffer.
Completed thinking already shown in the buffer is rewritten in place so the
whole-buffer toggle applies one mode to every finished thinking block without
rebuilding unrelated chat content. Live thinking stays visible while the
assistant is still working, and MODE is used when that block completes."
  (let ((chat-buf (pilish--get-chat-buffer)))
    (unless chat-buf
      (user-error "No pi session buffer"))
    (with-current-buffer chat-buf
      (pilish--set-thinking-display mode)
      (let ((buffer (current-buffer))
            (saved-windows (pilish--capture-window-rewrite-states)))
        (when-let* ((replacements
                     (pilish--apply-thinking-display-to-completed-blocks
                      mode)))
          (pilish--restore-window-rewrite-states
           buffer
           saved-windows
           (lambda (pos)
             (pilish--adjust-pos-after-region-replacements
              pos replacements))))))
    (message "Pi: This chat now %s completed thinking"
             (if (eq mode 'hidden) "hides" "shows"))))

(defun pilish--display-history-messages (messages)
  "Display MESSAGES from session history with full tool rendering.
Consecutive assistant messages are grouped under one header.
Tool calls are rendered with headers, output, overlays, and toggles."
  (let ((prev-role nil)
        (results (pilish--build-tool-result-index messages)))
    (dotimes (i (length messages))
      (let* ((message (aref messages i))
             (role (plist-get message :role)))
        (pcase role
          ("user"
           (let* ((content (plist-get message :content))
                  (text (pilish--extract-history-user-message-text message))
                  (has-images
                   (pilish--content-has-image-p content))
                  (timestamp
                   (pilish--ms-to-time (plist-get message :timestamp))))
             (when (or text has-images)
               (pilish--display-user-message text timestamp content)))
           (setq prev-role "user"))
          ("assistant"
           (when (not (equal prev-role "assistant"))
             (pilish--append-to-chat
              (concat "\n" (pilish--make-separator "Assistant") "\n")))
           (pilish--render-history-assistant-content message results)
           (setq prev-role "assistant"))
          ("custom"
           (when (plist-get message :display)
             (pilish--display-custom-message
              (plist-get message :content)))
           (setq prev-role "custom"))
          ("compactionSummary"
           (let* ((summary (plist-get message :summary))
                  (tokens-before (plist-get message :tokensBefore))
                  (timestamp (pilish--ms-to-time (plist-get message :timestamp))))
             (pilish--display-compaction-result tokens-before summary timestamp))
           (setq prev-role "compactionSummary"))
          ("branchSummary"
           (let* ((summary (plist-get message :summary))
                  (timestamp (pilish--ms-to-time (plist-get message :timestamp))))
             (pilish--display-branch-summary summary timestamp))
           (setq prev-role "branchSummary"))
          ("toolResult"
           nil))))))

(defun pilish--display-session-history (messages &optional chat-buf)
  "Display session history MESSAGES in the chat buffer.
MESSAGES is a vector of message plists from get_messages RPC.
CHAT-BUF is the target buffer; if nil, uses `pilish--get-chat-buffer'.
Note: When called from async callbacks, pass CHAT-BUF explicitly."
  (setq chat-buf (or chat-buf (pilish--get-chat-buffer)))
  (when (and chat-buf (buffer-live-p chat-buf))
    (with-current-buffer chat-buf
      (pilish--set-canonical-messages messages)
      (pilish--replay-history chat-buf messages
                              (concat (pilish--format-startup-header) "\n")))))

(cl-defstruct (pilish--history-parser-restart
               (:constructor pilish--make-history-parser-restart))
  "Operation-local ownership of a full replay's native parser cache.
ENTRIES are plists with original, language, tag, derived range policy,
notifiers in registration order, and an explicitly owned replacement."
  buffer originals overlays entries primary installed-p)

(defun pilish--history-parser-tag (parser)
  "Return PARSER's tag on Emacs versions that expose parser tags."
  (funcall (intern "treesit-parser-tag") parser))

(defun pilish--history-parser-restart-plan ()
  "Inventory a supported md-ts parser layout, or return nil for compatibility.
Only Emacs 30's known native API and unshared md-ts buffers are supported.
Inventory does not create, parse, delete, or reconfigure any parser."
  (cl-block supported
    (unless (and (= emacs-major-version 30)
                 (derived-mode-p 'md-ts-mode)
                 (not (buffer-base-buffer))
                 (not (seq-some
                       (lambda (buffer)
                         (eq (buffer-base-buffer buffer) (current-buffer)))
                       (buffer-list)))
                 (seq-every-p #'fboundp
                              (list (intern "treesit-parser-tag")
                                    'treesit-parser-notifiers
                                    'treesit-parser-add-notifier
                                    'treesit-parser-root-node
                                    'treesit-parser-included-ranges
                                    'treesit-parser-set-included-ranges
                                    'treesit-parser-create 'treesit-parser-delete
                                    'treesit-parser-list))
                 (equal (func-arity #'treesit-parser-list) '(0 . 3))
                 (equal (func-arity #'treesit-parser-create) '(1 . 4)))
      (cl-return-from supported nil))
    (let* ((originals (treesit-parser-list nil nil t))
           (overlays (seq-filter
                      (lambda (overlay) (overlay-get overlay 'treesit-parser))
                      (append (car (overlay-lists)) (cdr (overlay-lists)))))
           (primary treesit-primary-parser)
           local-parsers languages entries)
      (dolist (overlay overlays)
        (let ((parser (overlay-get overlay 'treesit-parser))
              (host (overlay-get overlay 'treesit-host-parser)))
          (unless (and (memq parser originals)
                       (eq (pilish--history-parser-tag parser) 'embedded)
                       (not (memq parser local-parsers))
                       (memq host originals)
                       (null (pilish--history-parser-tag host)))
            (cl-return-from supported nil))
          (push parser local-parsers)))
      (dolist (parser originals)
        (let ((tag (pilish--history-parser-tag parser))
              (language (treesit-parser-language parser))
              (notifiers (treesit-parser-notifiers parser)))
          (cond
           ((eq tag 'embedded)
            (when (or notifiers (eq parser primary))
              (cl-return-from supported nil)))
           ((or tag (memq language languages))
            (cl-return-from supported nil))
           (t
            (unless (and
                     (if (eq parser primary)
                         (and (eq language 'markdown)
                              (null (treesit-parser-included-ranges parser))
                              (equal notifiers
                                     (list (intern "treesit--font-lock-mark-ranges-to-fontify"))))
                       (null notifiers))
                     (pcase language
                       ('markdown (eq parser primary))
                       ('markdown-inline
                        (treesit-parser-included-ranges parser))
                       (_ (seq-some (lambda (setting)
                                      (eq (nth 1 setting) language))
                                    treesit-range-settings))))
              (cl-return-from supported nil))
            (push language languages)
            (push (list :original parser :language language :tag tag
                        :derived (treesit-parser-included-ranges parser)
                        :notifiers notifiers :replacement nil)
                  entries)))))
      (when (and (memq 'markdown languages)
                 (memq 'markdown-inline languages))
        (pilish--make-history-parser-restart
         :buffer (current-buffer) :originals originals :overlays overlays
         :entries (nreverse entries) :primary primary)))))

(defun pilish--call-with-history-parser-restart (function)
  "Call FUNCTION once with fresh, parse-lazy persistent parsers when supported.
Prepare before discarding old identities.  On failure retain live replacements
and restore notifiers without parsing partial text or replacing the condition.
Unsupported layouts call FUNCTION unchanged.  Preserve its return value."
  (let ((plan (save-restriction
                (widen)
                (pilish--history-parser-restart-plan))))
    (if (not plan)
        (funcall function)
      (let ((buffer (pilish--history-parser-restart-buffer plan))
            result completed primary-error cleanup-error)
        (cl-labels
            ((attempt (operation)
               (condition-case err
                   (progn (funcall operation) t)
                 ((error quit)
                  (unless cleanup-error (setq cleanup-error err))
                  nil)))
             (discard-old ()
               (dolist (overlay (pilish--history-parser-restart-overlays plan))
                 (attempt (lambda () (delete-overlay overlay))))
               (let ((live (treesit-parser-list nil nil t)))
                 (dolist (parser (pilish--history-parser-restart-originals plan))
                   (when (memq parser live)
                     (attempt (lambda () (treesit-parser-delete parser))))))))
          (unwind-protect
              (condition-case err
                  (progn
                    (save-restriction
                      (widen)
                      ;; Native creation prepends.  Reverse preparation preserves
                      ;; persistent lookup order after the originals are removed.
                      (dolist (entry (reverse (pilish--history-parser-restart-entries plan)))
                        (let ((parser (treesit-parser-create
                                       (plist-get entry :language) nil t)))
                          (setf (plist-get entry :replacement) parser)
                          (when (plist-get entry :derived)
                            (treesit-parser-set-included-ranges
                             parser (list (cons (point-min) (point-min))))))))
                    (let ((inhibit-quit t))
                      (setf (pilish--history-parser-restart-installed-p plan) t)
                      (setq-local treesit-primary-parser
                                  (plist-get
                                   (seq-find
                                    (lambda (entry)
                                      (eq (plist-get entry :original)
                                          (pilish--history-parser-restart-primary plan)))
                                    (pilish--history-parser-restart-entries plan))
                                   :replacement))
                      (discard-old)
                      (when cleanup-error
                        (signal (car cleanup-error) (cdr cleanup-error))))
                    (setq result (funcall function))
                    (when (buffer-live-p buffer)
                      (with-current-buffer buffer
                        (save-restriction
                          (widen)
                          ;; First-parse notifications otherwise rediscover every
                          ;; embedded range, including the unvisited cold prefix.
                          (dolist (entry (pilish--history-parser-restart-entries plan))
                            (when (plist-get entry :notifiers)
                              (treesit-parser-root-node
                               (plist-get entry :replacement)))))))
                    (setq completed t))
                ((error quit) (setq primary-error err)))
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (let ((inhibit-quit t))
                  (if (pilish--history-parser-restart-installed-p plan)
                      (progn
                        (attempt #'discard-old)
                        (dolist (entry (pilish--history-parser-restart-entries plan))
                          (dolist (notifier (plist-get entry :notifiers))
                            (let ((restore
                                   (lambda ()
                                     (treesit-parser-add-notifier
                                      (plist-get entry :replacement) notifier))))
                              (unless (attempt restore)
                                (attempt restore))))))
                    (dotimes (_ 2)
                      (let (live)
                        (attempt (lambda ()
                                   (setq live (treesit-parser-list nil nil t))))
                        (dolist (entry (pilish--history-parser-restart-entries plan))
                          (let ((parser (plist-get entry :replacement)))
                            (when (memq parser live)
                              (attempt
                               (lambda () (treesit-parser-delete parser))))))))))))
            (when cleanup-error
              (if (or primary-error (not completed))
                  (condition-case nil
                      (message "Pi: history parser cleanup failed: %S" cleanup-error)
                    ((error quit) nil))
                (signal (car cleanup-error) (cdr cleanup-error)))))
          (when primary-error (signal (car primary-error) (cdr primary-error)))
          result)))))

(defun pilish--fontify-visible-transcript-windows ()
  "Fontify explicit final bounds of genuinely visible transcript windows.
Hidden buffers and unavailable window ends wait for normal JIT fontification.
Preserve point, narrowing, selection, and every reader's window point."
  (let* ((buffer (current-buffer))
         (windows (seq-filter
                   (lambda (window)
                     (eq (frame-visible-p (window-frame window)) t))
                   (get-buffer-window-list buffer nil t)))
         (points (mapcar (lambda (window) (cons window (window-point window))) windows)))
    (save-excursion
      (save-selected-window
        (save-restriction
          (widen)
          (unwind-protect
              (dolist (window windows)
                (let ((start (window-start window))
                      (end (window-end window t)))
                  (when (and (integerp start) (integerp end))
                    (setq start (max (point-min) (min start (point-max)))
                          end (max (point-min) (min end (point-max))))
                    (when (< start end)
                      (condition-case-unless-debug nil
                          (font-lock-ensure start end)
                        (error nil))))))
            (dolist (view points)
              (let ((window (car view)) (position (cdr view)))
                (when (and (window-live-p window)
                           (eq (window-buffer window) buffer)
                           (/= (window-point window) position))
                  (set-window-point window position))))))))))

(defun pilish--replay-history (buffer messages &optional prefix display-width)
  "Replay full MESSAGES into passive transcript BUFFER with optional PREFIX.
DISPLAY-WIDTH, when non-nil, is the character width of the window BUFFER
will be shown in; width-sensitive rendering uses it while BUFFER is still
hidden.  Callers that omit it get the live window width or the fallback."
  (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (pilish--chat-display-width-override display-width)
            ;; A full resume/reload rebuild allocates many short strings,
            ;; overlays, and display properties.  Keep GC out of the hot path;
            ;; Emacs will collect normally after the dynamic binding unwinds.
            (gc-cons-threshold
             (max gc-cons-threshold
                  pilish--history-replay-gc-threshold)))
        ;; Replaying and cooling a large transcript performs hundreds of small
        ;; rewrites.  Suspend every known md-ts 0.4 per-change hook for the
        ;; whole rebuild.  This is one untracked epoch, so md-ts records one
        ;; dirty range and jit-lock fontifies visible text at the next redisplay.
        (prog1
            (pilish--with-md-ts-change-hooks-suspended
                #'pilish--md-ts-change-hook-p
              (pilish--call-with-history-parser-restart
               (lambda ()
                 (pilish--clear-render-artifacts)
                 (erase-buffer)
                 (when prefix (insert prefix))
                 (pilish--with-transcript-construction
                   (when (vectorp messages)
                     (let ((pilish--defer-history-postprocessing t))
                       (pilish--display-history-messages messages)))
                   (goto-char (point-max))
                   (unless (bolp) (insert "\n"))
                   (pilish--set-message-start-marker nil)
                   (pilish--set-streaming-marker nil)
                   (pilish--update-hot-tail-boundary)
                   (pilish--cool-completed-tool-blocks-outside-hot-tail)
                   (pilish--postprocess-history-buffer)
                   (goto-char (point-max))))))
          (pilish--fontify-visible-transcript-windows)))))

(provide 'pilish-render)

;;; pilish-render.el ends here
