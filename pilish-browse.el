;;; pilish-browse.el --- Session and tree browser -*- lexical-binding: t; -*-

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

;; Session and tree browsing for Pilish.
;;
;; Provides two read-only, refreshable, keyboard-driven buffers:
;;   - Session Browser: find, filter, switch, rename, and delete sessions
;;   - Tree Browser: navigate conversation tree, label nodes (like TUI /tree)
;;
;; Session data comes from time-sliced scans of JSONL files on disk,
;; and conversation trees are projected from the linked chat's JSONL
;; session file.  Browsing does not need a live pi process, but the tree
;; shows the last persisted turn, so it can lag an in-flight turn;
;; refresh manually with `g'.  Tree labels are appended out-of-band and
;; fold back into every disk read.
;;
;; Session switching uses menu.el's guarded resume flow.  Renaming the
;; linked current session asks pi to append session_info; renaming any
;; other session appends session_info out-of-band.  Tree navigation
;; guards the linked session, process, and loaded file; computes the
;; target from fresh JSONL data; atomically rewrites an ordinary local
;; session file so the target's ancestor chain ends it (write-temp +
;; rename — the rename is the only step that touches the file); resumes
;; the rewritten file through menu; prefills the input buffer with the
;; target's re-edit text; and dismisses the browser window once the
;; transition settles.  Navigation does not auto-reopen the browser
;; (refresh with `g'); rewinding before the first message points at the
;; chat's fork command instead.

;;; Code:

(require 'pilish-core)
(require 'pilish-ui)
(require 'pilish-jsonl)
(require 'cl-lib)
(require 'magit-section)
(require 'transient)

;; Forward declarations for functions in other modules (avoid circular deps)
(declare-function pilish-set-session-name "pilish-menu" (name))
(declare-function pilish--resume-selected-session "pilish-menu"
                  (proc chat-buf selected-path))
(declare-function pilish--session-transition-ready-p "pilish-menu"
                  (chat-buf action))
(declare-function pilish--session-file-cwd-or-error "pilish-menu"
                  (path))
(declare-function pilish--session-list-directory "pilish-menu"
                  (&optional chat-buf))

;;;; Response Parsers

(defun pilish--parse-tree (response)
  "Parse a `get_tree' RESPONSE into a tree data plist.
Returns plist with :tree (vector) and :leafId (string), or nil on failure.
Currently unused by the disk-based tree seam (`--browse-load-tree'
reads the session file directly); reserved for a future RPC fallback
and as the projected-shape fixture loader for tests."
  (when (eq (plist-get response :success) t)
    (plist-get response :data)))

;;;; Session Display Helpers

(defun pilish--collapse-whitespace (str)
  "Collapse whitespace (including newlines) in STR to a single space."
  (replace-regexp-in-string "[\n\r\t ]+" " " str))

(defun pilish--first-nonempty-line (str)
  "Return the first non-empty line from STR.
Skips leading blank lines.  Returns empty string if STR is empty
or contains only whitespace."
  (if (or (null str) (string-empty-p str))
      ""
    (let ((lines (split-string str "\n")))
      (or (cl-find-if (lambda (l) (not (string-empty-p (string-trim l)))) lines)
          ""))))

(defun pilish--session-display-name (session)
  "Return display name for SESSION plist.
Prefers :name, falls back to :firstMessage, then \"[empty session]\".
Newlines and excess whitespace are collapsed to single spaces."
  (let ((raw (or (pilish--normalize-string-or-null
                  (plist-get session :name))
                 (pilish--normalize-string-or-null
                  (plist-get session :firstMessage)))))
    (if raw
        (pilish--collapse-whitespace raw)
      "[empty session]")))

;;;; Margin Rendering Infrastructure

(defun pilish--propertize-face (string face)
  "Propertize STRING with both `face' and `font-lock-face' set to FACE.
This follows Magit's convention to survive fontification."
  (propertize string 'face face 'font-lock-face face))

(defun pilish--make-margin-overlay (string)
  "Create a right-margin overlay on the current line displaying STRING.
The overlay uses `evaporate' so it auto-removes when the buffer text
is deleted (e.g., during erase-and-rewrite refresh).
STRING defaults to a single space if nil."
  (save-excursion
    (forward-line (if (bolp) -1 0))
    (let ((o (make-overlay (1+ (point)) (line-end-position) nil t)))
      (overlay-put o 'evaporate t)
      (overlay-put o 'before-string
                   (propertize "o" 'display
                               (list (list 'margin 'right-margin)
                                     (or string " ")))))))

(defconst pilish--session-margin-width 20
  "Right margin width for the session browser.
Accommodates: count (4 digits + \" msgs \") + age (2 + 1 + 7) + padding.
4 + 5 + 10 = 19, plus 1 char left padding = 20.")

(defconst pilish--tree-margin-width 16
  "Right margin width for the tree browser.
Accommodates: \"[\" + 12-char label + \"]\" + padding = 16.")

(defvar-local pilish--browse-margin-width nil
  "Right margin width for the current browse buffer.
Set by the derived mode; used by the window-configuration hook.")

(defun pilish--browse-set-window-margins (width &optional window)
  "Set right margin to WIDTH on WINDOW (default: selected window).
Preserves any existing left margin."
  (let ((win (or window (selected-window))))
    (when (window-live-p win)
      (set-window-margins win (car (window-margins win)) width))))

(defun pilish--browse-apply-margins ()
  "Re-apply right margins for the current browse buffer.
Reads width from `pilish--browse-margin-width'.
Intended as a `window-configuration-change-hook' callback."
  (when pilish--browse-margin-width
    (pilish--browse-set-window-margins
     pilish--browse-margin-width)))

;;;; Margin Age Formatting

(defconst pilish--age-spec
  '(("year"   31557600)
    ("month"   2629800)
    ("week"     604800)
    ("day"       86400)
    ("hour"       3600)
    ("minute"       60)
    ("second"        1))
  "Time units and their durations in seconds.
Used for margin age display in browse buffers.")

(defun pilish--margin-age (seconds)
  "Convert SECONDS to a (COUNT . UNIT) pair.
Returns the largest unit where COUNT >= 1, or (0 . \"second\") for zero."
  (let ((result (cons 0 "second")))
    (cl-loop for (unit secs) in pilish--age-spec
             when (>= seconds secs)
             do (setq result (cons (floor (/ (float seconds) secs)) unit))
             and return nil)
    result))

(defconst pilish--margin-age-unit-width
  (apply #'max (mapcar (lambda (s) (length (concat (car s) "s")))
                       pilish--age-spec))
  "Width of the longest pluralized unit name (\"minutes\" = 7).")

(defconst pilish--margin-age-format
  (format "%%2d %%-%ds" pilish--margin-age-unit-width)
  "Format string for margin age: \"%2d %-7s\".")

(defun pilish--format-margin-age (seconds)
  "Format SECONDS as a magit-log–style aligned age string.
Format: \"%2d %-Ns\" where N is the longest pluralized unit width.
Example: \" 5 minutes\", \" 1 hour   \", \"10 days   \"."
  (let* ((pair (pilish--margin-age seconds))
         (count (car pair))
         (unit (cdr pair))
         (unit-str (if (= count 1) unit (concat unit "s"))))
    (format pilish--margin-age-format count unit-str)))

(defun pilish--format-margin-age-from-iso (iso-timestamp)
  "Format ISO-TIMESTAMP as a margin age string.
Returns nil on invalid input."
  (condition-case nil
      (let* ((time (date-to-time iso-timestamp))
             (diff (floor (float-time (time-subtract (current-time) time)))))
        (pilish--format-margin-age (max 0 diff)))
    (error nil)))

;;;; Tree Helpers

(defun pilish--active-path-ids (tree leaf-id)
  "Compute the set of node IDs on the active path.
TREE is the root vector from get_tree.
LEAF-ID is the current leaf node ID.
Returns a hash table mapping active node IDs to t."
  (let ((result (make-hash-table :test 'equal)))
    (when leaf-id
      ;; Build parent-id lookup from tree
      (let ((parent-map (make-hash-table :test 'equal))
            (stack (append tree nil)))
        (while stack
          (let* ((node (pop stack))
                 (children (plist-get node :children)))
            (when (vectorp children)
              (dotimes (i (length children))
                (let ((child (aref children i)))
                  (puthash (plist-get child :id)
                           (plist-get node :id)
                           parent-map)
                  (push child stack))))))
        ;; Walk from leaf to root, marking the active path
        (let ((current leaf-id))
          (while current
            (puthash current t result)
            (setq current (gethash current parent-map))))))
    result))

;;;; Tree Filter Predicates

(defconst pilish--empty-assistant-preview "(no content)"
  "Preview string the RPC projection sets for assistant messages with no text.
Used as a heuristic to detect tool-dispatch-only assistant messages.")

(defun pilish--browse-node-empty-assistant-p (node)
  "Return non-nil if NODE is an empty assistant message.
Empty assistants have no text content — typically tool-dispatch messages
containing only toolCall blocks.  Detected via the preview string heuristic.
Aborted or errored messages are NOT considered empty."
  (let ((type (plist-get node :type))
        (role (plist-get node :role)))
    (and (equal type "message")
         (equal role "assistant")
         (let ((preview (or (plist-get node :preview) "")))
           (or (string-empty-p preview)
               (equal preview pilish--empty-assistant-preview)))
         (not (equal (plist-get node :stopReason) "aborted"))
         (not (plist-get node :errorMessage)))))

(defun pilish--browse-node-visible-p (node filter-mode)
  "Return non-nil if NODE should be visible under FILTER-MODE.
FILTER-MODE is one of: \"default\", \"no-tools\", \"user-only\",
\"labeled-only\", \"all\".
NODE is a tree node plist.

Filtering is two-phase (matching TUI tree-selector.ts:282-311):
  Phase 1 — universal pre-filter: empty assistant messages are always
            hidden regardless of mode (unless aborted or errored).
  Phase 2 — mode-specific filter: each mode defines additional rules."
  (if (pilish--browse-node-empty-assistant-p node)
      ;; Phase 1: universal pre-filter — empty assistants always hidden
      nil
    ;; Phase 2: mode-specific filter
    (let ((type (plist-get node :type))
          (role (plist-get node :role)))
      (pcase filter-mode
        ("all" t)
        ("labeled-only"
         (and (plist-get node :label) t))
        ("user-only"
         (and (equal type "message") (equal role "user")))
        ("no-tools"
         (and (not (member type '("model_change" "thinking_level_change")))
              (not (equal type "tool_result"))))
        (_ ;; "default"
         (not (member type '("model_change" "thinking_level_change"))))))))

;;;; Tree Flattening for Display

(defun pilish--flatten-tree-for-display (tree leaf-id filter-mode)
  "Flatten TREE into a display-ordered list of (NODE INDENT PREFIX) lists.
LEAF-ID identifies the current leaf for active-branch-first ordering.
FILTER-MODE controls which nodes are visible.
Each entry is (NODE INDENT-LEVEL PREFIX-STRING) where PREFIX-STRING
contains tree connectors and gutter characters for visual structure."
  (let ((active-ids (pilish--active-path-ids tree leaf-id))
        (result nil))
    (pilish--flatten-tree-walk
     (append tree nil) 0 active-ids filter-mode
     nil nil
     (lambda (node indent prefix) (push (list node indent prefix) result)))
    (nreverse result)))

(defun pilish--flatten-tree-walk (nodes indent active-ids filter-mode
                                                 gutter-stack is-branch-children
                                                 emit)
  "Walk NODES at INDENT level, calling EMIT for visible nodes.
ACTIVE-IDS is the active path hash table.
FILTER-MODE controls visibility.
GUTTER-STACK is a list of strings (\"│  \" or \"   \") for ancestor levels.
IS-BRANCH-CHILDREN is non-nil if NODES are siblings at a branch point.
EMIT is called with (node indent prefix) for each visible node.
Active-branch children are shown first at branch points.
Uses an explicit stack to avoid overflow on deep trees."
  ;; Each stack frame: [siblings vis-count vis-index indent gutter is-branch]
  (let* ((vis-count (cl-count-if
                     (lambda (n)
                       (pilish--browse-node-visible-p n filter-mode))
                     nodes))
         (stack (list (vector nodes vis-count 0
                              indent gutter-stack is-branch-children))))
    (while stack
      (let* ((frame (pop stack))
             (siblings (aref frame 0))
             (v-count  (aref frame 1))
             (v-index  (aref frame 2))
             (cur-indent (aref frame 3))
             (gutter   (aref frame 4))
             (is-branch-ch (aref frame 5)))
        (when siblings
          (let* ((node (car siblings))
                 (rest (cdr siblings))
                 (is-visible (pilish--browse-node-visible-p
                              node filter-mode))
                 (children (plist-get node :children))
                 (child-list (and (vectorp children) (append children nil)))
                 (is-branch (> (length child-list) 1))
                 (child-indent (if is-branch (1+ cur-indent) cur-indent))
                 ;; Compute gutter and child frame for this node
                 (child-gutter gutter)
                 (next-v-index v-index))
            ;; Push continuation for remaining siblings (goes UNDER children)
            (when is-visible
              (let* ((last-visible-p (= v-index (1- v-count)))
                     (connector (when is-branch-ch
                                  (if last-visible-p "└─ " "├─ ")))
                     (prefix (concat (apply #'concat gutter)
                                     (or connector "")))
                     (new-gutter (when is-branch-ch
                                   (if last-visible-p "   " "│  "))))
                (funcall emit node cur-indent prefix)
                (when new-gutter
                  (setq child-gutter (append gutter (list new-gutter))))
                (setq next-v-index (1+ v-index))))
            ;; Push remaining siblings (continuation)
            (when rest
              (push (vector rest v-count next-v-index
                            cur-indent gutter is-branch-ch)
                    stack))
            ;; Push children ON TOP (processed before remaining siblings)
            (when child-list
              (let* ((sorted (if is-branch
                                 (pilish--sort-active-first
                                  child-list active-ids)
                               child-list))
                     (child-v-count
                      (cl-count-if
                       (lambda (n)
                         (pilish--browse-node-visible-p n filter-mode))
                       sorted)))
                (push (vector sorted child-v-count 0
                              child-indent child-gutter is-branch)
                      stack)))))))))

(defun pilish--sort-active-first (children active-ids)
  "Sort CHILDREN so the subtree containing an active node comes first.
ACTIVE-IDS is the hash table of active path node IDs."
  (let ((active nil)
        (inactive nil))
    (dolist (child children)
      (if (pilish--subtree-contains-active-p child active-ids)
          (push child active)
        (push child inactive)))
    (append (nreverse active) (nreverse inactive))))

(defun pilish--subtree-contains-active-p (node active-ids)
  "Return non-nil if NODE or any descendant is in ACTIVE-IDS.
Uses iterative DFS to avoid stack overflow on deep trees."
  (let ((stack (list node)))
    (cl-block found
      (while stack
        (let* ((n (pop stack))
               (children (plist-get n :children)))
          (when (gethash (plist-get n :id) active-ids)
            (cl-return-from found t))
          (when (vectorp children)
            (dotimes (i (length children))
              (push (aref children i) stack)))))
      nil)))

;;;; Client-Side Search/Filter

(defun pilish--matches-filter-p (text tokens)
  "Return non-nil if TEXT matches all regexp TOKENS.
Each whitespace-separated token is a regexp.
All tokens must match for the entry to be included."
  (or (null tokens)
      (cl-every (lambda (tok) (string-match-p tok text)) tokens)))

;;;; Session Sort/Filter/Threading

(defconst pilish--session-sort-modes
  '("threaded" "recent" "relevance")
  "Available sort modes for the session browser.")

(defun pilish--session-sort-next (current)
  "Return the sort mode after CURRENT in the cycle."
  (let ((modes pilish--session-sort-modes))
    (or (cadr (member current modes))
        (car modes))))

(defun pilish--session-sort-items (items sort-mode)
  "Sort session ITEMS by SORT-MODE.
\"recent\" sorts by modified time descending.
\"relevance\" sorts by message count descending.
\"threaded\" returns items as-is (threading is handled during rendering)."
  (pcase sort-mode
    ("recent"
     (sort (copy-sequence items)
           (lambda (a b)
             (string> (plist-get a :modified) (plist-get b :modified)))))
    ("relevance"
     (sort (copy-sequence items)
           (lambda (a b)
             (> (or (plist-get a :messageCount) 0)
                (or (plist-get b :messageCount) 0)))))
    (_ items)))

(defun pilish--session-thread-items (items)
  "Arrange ITEMS into a flat list with threading depth.
Returns a list of (session . depth) cons cells.
Top-level items have depth 0, children have depth 1+."
  (let ((by-path (make-hash-table :test 'equal))
        (children-of (make-hash-table :test 'equal))
        (root-items nil))
    ;; Index by path
    (dolist (item items)
      (puthash (plist-get item :path) item by-path))
    ;; Group children under parents
    (dolist (item items)
      (let ((parent-path (plist-get item :parentSessionPath)))
        (if (and parent-path (gethash parent-path by-path))
            (puthash parent-path
                     (append (gethash parent-path children-of) (list item))
                     children-of)
          (push item root-items))))
    ;; Build threaded list with depth (DFS)
    (let ((result nil))
      (dolist (root (nreverse root-items))
        (setq result (pilish--collect-threaded
                      root children-of 0 result)))
      (nreverse result))))

(defun pilish--collect-threaded (item children-of depth result)
  "Collect ITEM and its children into RESULT at DEPTH.
CHILDREN-OF maps parent path to child items.
Returns the updated RESULT list."
  (push (cons item depth) result)
  (let ((kids (gethash (plist-get item :path) children-of)))
    (dolist (kid kids)
      (setq result (pilish--collect-threaded
                    kid children-of (1+ depth) result))))
  result)

(defun pilish--session-filter-named (items)
  "Filter ITEMS to only those with a name."
  (cl-remove-if-not (lambda (item)
                      (pilish--normalize-string-or-null
                       (plist-get item :name)))
                    items))

(defun pilish--session-filter-search (items tokens)
  "Filter ITEMS by search TOKENS.
Match prepared :searchText, or name/first-message text for metadata items."
  (if (null tokens)
      items
    (cl-remove-if-not
     (lambda (item)
       (let ((text (or (plist-get item :searchText)
                       (concat (or (plist-get item :name) "") " "
                               (or (plist-get item :firstMessage) "") " "
                               (or (plist-get item :allMessagesText) "")))))
         (pilish--matches-filter-p text tokens)))
     items)))

;;;; Time-Based Section Headers

(defun pilish--session-time-group (iso-timestamp)
  "Return time group label for ISO-TIMESTAMP.
Groups: \"Today\", \"Yesterday\", \"This Week\", \"Older\"."
  (condition-case nil
      (let* ((time (date-to-time iso-timestamp))
             (now (current-time))
             (diff-days (/ (float-time (time-subtract now time)) 86400.0)))
        (cond
         ((< diff-days 1) "Today")
         ((< diff-days 2) "Yesterday")
         ((< diff-days 7) "This Week")
         (t "Older")))
    (error "Older")))

;;;; Section Classes

(defclass pilish-session-section (magit-section)
  ((keymap :initform 'pilish-session-section-map))
  "Section class for a session entry in the session browser.")

;;;; Keymaps

(defvar pilish-browse-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "g") #'pilish-browse-refresh)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Base keymap for Pilish browse modes.")

(defvar pilish-session-browser-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map pilish-browse-mode-map)
    (define-key map (kbd "s") #'pilish-session-browser-cycle-sort)
    (define-key map (kbd "f") #'pilish-session-browser-toggle-named)
    (define-key map (kbd "/") #'pilish-session-browser-search)
    (define-key map (kbd "t") #'pilish-session-browser-toggle-scope)
    (define-key map (kbd "r") #'pilish-session-browser-rename)
    (define-key map (kbd "d") #'pilish-session-browser-delete)
    (define-key map (kbd "RET") #'pilish-session-browser-switch)
    (define-key map (kbd "?") #'pilish-session-browser-dispatch)
    (define-key map (kbd "h") #'pilish-session-browser-dispatch)
    map)
  "Keymap for the session browser.")

(defvar pilish-session-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'pilish-session-browser-switch)
    map)
  "Keymap for session sections (text property on each session line).")

;;;; Buffer-Local State

(defvar-local pilish--session-browser-scope "current"
  "Scope for session listing: \"current\" or \"all\".")

(defvar-local pilish--session-browser-sort "threaded"
  "Sort mode: \"threaded\", \"recent\", or \"relevance\".")

(defvar-local pilish--session-browser-named-only nil
  "When non-nil, show only named sessions.")

(defvar-local pilish--session-browser-items nil
  "Session items from the last `--browse-load-sessions' callback.")

(defvar-local pilish--session-browser-search-query nil
  "Current search query string, or nil.")

(defvar-local pilish--session-browser-search-tokens nil
  "Parsed search tokens from `pilish--session-browser-search-query'.")

(defvar-local pilish--session-browser-loading nil
  "Non-nil while a fetch is in progress.")

(defvar-local pilish--session-browser-fetch-anchor nil
  "Point anchor carried across the in-flight fetch cycle.
Set to the anchor captured at fetch start.  A refresh issued while
loading captures no anchor of its own (the loading render already
destroyed the sections), so it reuses this one instead.  Cleared when
the cycle's final render runs.")

(defvar-local pilish--session-browser-error nil
  "Error message string from last fetch, or nil on success.")

(defvar-local pilish--session-browser-fetch-token 0
  "Generation counter for session-browser fetches.
`pilish--browse-load-sessions' bumps it per fetch; callbacks
from superseded fetches are dropped by comparing their captured token
against the buffer's current one.")

;;;; Session Browser Dispatch Transient

(defun pilish--session-dispatch-heading ()
  "Return heading string for the session browser dispatch transient.
Shows current scope, sort mode, and named-only state — the same state
`pilish--session-browser-header-line' formats for the
header-line.  Transient evaluates group descriptions in the invoking
browser buffer (`transient-with-shadowed-buffer' inside
`transient--insert-group'), so these buffer-local reads see the
browser's state on the real rendering path."
  (mapconcat #'identity
             (append (list (format "scope:%s"
                                   pilish--session-browser-scope)
                           (format "sort:%s"
                                   pilish--session-browser-sort))
                     (and pilish--session-browser-named-only
                          '("named-only")))
             " │ "))

(transient-define-prefix pilish-session-browser-dispatch ()
  "Session browser help."
  [:description pilish--session-dispatch-heading
   ["Actions"
    ("RET" "switch" pilish-session-browser-switch)
    ("r" "rename" pilish-session-browser-rename)
    ("d" "delete" pilish-session-browser-delete)
    ("g" "refresh" pilish-browse-refresh)
    ("q" "quit" quit-window)]
   ["Filter & Sort"
    ("s" "sort" pilish-session-browser-cycle-sort)
    ("f" "named only" pilish-session-browser-toggle-named)
    ("t" "scope" pilish-session-browser-toggle-scope)
    ("/" "search" pilish-session-browser-search)]])

;;;; Faces

(defface pilish-session-name
  '((t :weight bold))
  "Face for session names in the session browser."
  :group 'pilish)

(defface pilish-session-message-count
  '((t :inherit shadow))
  "Face for message counts in the session browser."
  :group 'pilish)

(defface pilish-session-age
  '((t :inherit shadow))
  "Face for relative age in the session browser margin."
  :group 'pilish)

(defface pilish-session-thread-connector
  '((t :inherit shadow))
  "Face for threading connectors (├─, └─) in the session browser."
  :group 'pilish)

(defface pilish-session-group-header
  '((t :inherit magit-section-heading))
  "Face for time-group headers (Today, Yesterday, etc.)."
  :group 'pilish)

;;;; Major Modes

(define-derived-mode pilish-browse-mode magit-section-mode
  "Pi-Browse"
  "Base mode for Pilish browse buffers.
Inherits section navigation from `magit-section-mode'."
  :group 'pilish)

(define-derived-mode pilish-session-browser-mode
  pilish-browse-mode "Pi-Sessions"
  "Major mode for browsing pi sessions.
\\{pilish-session-browser-mode-map}"
  :group 'pilish
  (setq-local header-line-format
              '(:eval (pilish--session-browser-header-line)))
  (setq pilish--browse-margin-width
        pilish--session-margin-width)
  (setq-local right-margin-width pilish--session-margin-width)
  (add-hook 'window-configuration-change-hook
            #'pilish--browse-apply-margins nil t))

;;;; Buffer Management

(defun pilish--session-browser-buffer-name (dir)
  "Return session browser buffer name for DIR."
  (format "*pilish-sessions:%s*"
          (pilish--route-preserving-abbreviate-file-name dir)))

(defun pilish--get-or-create-session-browser (dir)
  "Get or create session browser buffer for DIR."
  (let* ((name (pilish--session-browser-buffer-name dir))
         (buf (get-buffer name)))
    (or buf
        (with-current-buffer (generate-new-buffer name)
          (setq default-directory dir)
          (pilish-session-browser-mode)
          (current-buffer)))))

;;;; Rendering

(defun pilish--session-browser-render (buf)
  "Render the session browser in BUF from its buffer-local state."
  (with-current-buffer buf
    (let* ((inhibit-read-only t)
           (items pilish--session-browser-items)
           ;; Loading/error screens retain the old snapshot but need not
           ;; search its potentially large corpus just to display status.
           (filtered
            (unless (or pilish--session-browser-loading
                        pilish--session-browser-error (null items))
              (pilish--session-filter-search
               (if pilish--session-browser-named-only
                   (pilish--session-filter-named items)
                 items)
               pilish--session-browser-search-tokens))))
      (magit-insert-section (root)
        (cond
         (pilish--session-browser-loading
          (insert (pilish--propertize-face
                   "Loading sessions..."
                   'pilish-activity-phase)
                  "\n"))
         (pilish--session-browser-error
          (insert (pilish--propertize-face
                   (format "Error: %s\n" pilish--session-browser-error)
                   'error)))
         ((null items)
          (insert "No sessions found.\n"))
         ((null filtered)
          (insert "No matching sessions.\n"))
         ((equal pilish--session-browser-sort "threaded")
          (pilish--session-browser-render-threaded filtered))
         ((equal pilish--session-browser-sort "recent")
          (pilish--session-browser-render-recent filtered))
         (t
          (let ((sorted (pilish--session-sort-items
                         filtered pilish--session-browser-sort)))
            (pilish--session-browser-render-flat sorted))))))))

(defun pilish--session-browser-render-flat (items)
  "Render ITEMS as a flat list."
  (dolist (item items)
    (pilish--session-browser-insert-session item 0 nil)))

(defun pilish--session-browser-render-threaded (items)
  "Render ITEMS in threaded view with connectors."
  (let ((threaded (pilish--session-thread-items items)))
    (dolist (entry threaded)
      (let ((item (car entry))
            (depth (cdr entry)))
        (pilish--session-browser-insert-session item depth t)))))

(defun pilish--session-browser-render-recent (items)
  "Render ITEMS sorted by recency with time-group headers."
  (let ((sorted (pilish--session-sort-items items "recent"))
        (last-group nil))
    (dolist (item sorted)
      (let ((group (pilish--session-time-group
                    (plist-get item :modified))))
        (unless (equal group last-group)
          (magit-insert-section (time-group group)
            (magit-insert-heading
              (pilish--propertize-face
               group 'pilish-session-group-header)))
          (setq last-group group)))
      (pilish--session-browser-insert-session item 0 nil))))

(defun pilish--session-browser-insert-session (session depth threaded)
  "Insert SESSION as a `magit-section' section at DEPTH.
When THREADED is non-nil, prepend threading connector at DEPTH.
In non-threaded modes, forked sessions get a \"fork:\" prefix.
Message count and age are rendered as a right-margin overlay."
  (let* ((path (plist-get session :path))
         (name (pilish--session-display-name session))
         (count (or (plist-get session :messageCount) 0))
         (modified (plist-get session :modified))
         (is-fork (plist-get session :parentSessionPath))
         (prefix (cond
                  ((and threaded (> depth 0))
                   (concat (make-string (* 2 (1- depth)) ?\s)
                           (pilish--propertize-face
                            "└─ " 'pilish-session-thread-connector)))
                  ((and is-fork (not threaded))
                   (pilish--propertize-face
                    "fork: " 'pilish-session-thread-connector))
                  (t "")))
         (heading (concat prefix
                          (pilish--propertize-face
                           name 'pilish-session-name)))
         (margin-str (concat
                      (pilish--propertize-face
                       (format "%4d msgs " count)
                       'pilish-session-message-count)
                      (pilish--propertize-face
                       (or (pilish--format-margin-age-from-iso modified)
                           (format (format "%%%ds"
                                           (+ 3 pilish--margin-age-unit-width))
                                   "?"))
                       'pilish-session-age))))
    (magit-insert-section (session path)
      (magit-insert-heading heading)
      (pilish--make-margin-overlay margin-str))))

;;;; Header-Line

(defun pilish--session-browser-header-line ()
  "Return header-line string for the session browser."
  (let* ((scope pilish--session-browser-scope)
         (sort pilish--session-browser-sort)
         (named pilish--session-browser-named-only)
         (query pilish--session-browser-search-query)
         (count (length (or pilish--session-browser-items '()))))
    (mapconcat #'identity
               (append (list (format "Sessions [%s]" scope)
                             (format "sort:%s" sort))
                       (and named '("named-only"))
                       (and query (list (format "/%s" query)))
                       (list (format "(%d)" count)
                             (pilish--propertize-face "?:help" 'shadow)))
               " │ ")))

;;;; Session Browser Interactive Commands

(defun pilish-session-browser-cycle-sort ()
  "Cycle the session browser sort mode."
  (interactive)
  (setq pilish--session-browser-sort
        (pilish--session-sort-next
         pilish--session-browser-sort))
  (pilish--session-browser-rerender)
  (message "Pi: Sort: %s" pilish--session-browser-sort))

(defun pilish-session-browser-toggle-named ()
  "Toggle named-only filter in the session browser."
  (interactive)
  (setq pilish--session-browser-named-only
        (not pilish--session-browser-named-only))
  (pilish--session-browser-rerender)
  (message "Pi: Named-only: %s"
           (if pilish--session-browser-named-only "on" "off")))

(defun pilish-session-browser-toggle-scope ()
  "Toggle scope between current and all projects."
  (interactive)
  (setq pilish--session-browser-scope
        (if (equal pilish--session-browser-scope "current")
            "all" "current"))
  (pilish--session-browser-fetch-and-render)
  (message "Pi: Scope: %s" pilish--session-browser-scope))

(defun pilish-session-browser-search ()
  "Search names, first messages and all user/assistant text on disk.
Whitespace-separated regexp tokens must all match.  Text on inactive
branches is included; thinking, tools, images and summaries are not added.
The legacy first-message fallback can still match text from any role."
  (interactive)
  (let ((query (read-string "Filter (regexp tokens): "
                            pilish--session-browser-search-query))
        (need-rerender t))
    (if (string-empty-p query)
        (setq pilish--session-browser-search-query nil
              pilish--session-browser-search-tokens nil)
      ;; Validate regexp tokens
      (condition-case err
          (let ((tokens (split-string query)))
            (dolist (tok tokens)
              (string-match-p tok ""))
            (setq pilish--session-browser-search-query query
                  pilish--session-browser-search-tokens tokens))
        (invalid-regexp
         (message "Pi: Invalid regexp: %s" (error-message-string err))
         (setq need-rerender nil))))
    (when need-rerender
      (pilish--session-browser-rerender))))

(defun pilish--session-browser-path-at-point ()
  "Return the file path of the session at point, or nil."
  (when-let* ((section (magit-current-section))
              ((object-of-class-p section 'pilish-session-section)))
    (oref section value)))

(defun pilish-session-browser-switch ()
  "Switch to the session at point."
  (interactive)
  (if-let* ((path (pilish--session-browser-path-at-point)))
      (pilish--browse-switch-session path)
    (message "Pi: No session at point")))

(defun pilish--browse-live-session-chat-buffer (path)
  "Return the chat buffer of a live Pilish process using PATH, or nil."
  (cl-loop for proc in (process-list)
           for chat-buf = (process-get proc 'pilish-chat-buffer)
           when (and (pilish--session-live-process-p proc)
                     (buffer-live-p chat-buf)
                     (pilish--browse-session-file-matches-p chat-buf path))
           return chat-buf))

(defun pilish--browse-ensure-session-closed (path)
  "Signal a `user-error' when a live Pilish process is using PATH."
  (when-let* ((chat-buf (pilish--browse-live-session-chat-buffer path)))
    (user-error "Session is open in %s — close it first"
                (buffer-name chat-buf))))

(defun pilish-session-browser-delete ()
  "Delete the session at point after confirmation.
Refuse sessions used by a live Pilish process in this Emacs.  Processes
outside this Emacs cannot be detected.  Pass the trash flag to
`delete-file', so `delete-by-moving-to-trash' controls whether the file
is moved to the system trash or permanently removed."
  (interactive)
  (if-let* ((path (pilish--session-browser-path-at-point)))
      (let ((name (file-name-nondirectory path)))
        (pilish--browse-ensure-session-closed path)
        (when (y-or-n-p (format "Delete session %s? " name))
          ;; A process can open the session while confirmation is active.
          (pilish--browse-ensure-session-closed path)
          (delete-file path t)
          (pilish--session-browser-fetch-and-render)
          (message "Pi: Deleted %s" name)))
    (message "Pi: No session at point")))

(defun pilish--browse-clean-session-name (name)
  "Return NAME cleaned for a session_info append.
CR/LF runs collapse to single spaces, then surrounding whitespace
trims (pi's appendSessionInfo order)."
  (string-trim (replace-regexp-in-string "[\r\n]+" " " name)))

(defun pilish--browse-last-entry-id-in-buffer ()
  "Return the id of the last parseable non-header line in the current buffer.
Blank or malformed trailing lines are skipped: pi's loader ignores them,
so parenting an append to one would detach it from the conversation (the
leaf walk would stop at a null parent).  The header ends the search — a
header-only file reads as nil."
  (goto-char (point-max))
  (catch 'done
    (while t
      (skip-chars-backward " \t\r\n")
      (if (bobp)
          (throw 'done nil)
        (let* ((bol (line-beginning-position))
               (data (and (> (point) bol)
                          (pilish--parse-json-line
                           (buffer-substring-no-properties bol (point))))))
          (cond
           ((and (consp data) (equal (plist-get data :type) "session"))
            (throw 'done nil))
           ((consp data)
            (throw 'done (pilish--normalize-string-or-null
                          (plist-get data :id))))
           ;; Blank or malformed line: step over it and retry.
           (t (goto-char bol))))))))

(defun pilish--browse-session-file-state (path)
  "Re-read session file PATH fresh and describe its tail for an append.
Return a plist (:last-id ID-OR-NIL :ids HASH :newline-p BOOL), or nil when
PATH is missing or unreadable.  :last-id is the id of the last parseable
non-header line (see `pilish--browse-last-entry-id-in-buffer').
:ids holds every id-shaped string in the file — a superset of pi's entry
index — for fresh-id collision checks.  :newline-p reports whether the
file already ends in a newline.  The whole file is inserted once, fresh:
a live pi process appends concurrently, so the state must reflect the
physical file, never cached browser data."
  (condition-case nil
      (when (file-readable-p path)
        (with-temp-buffer
          (insert-file-contents path)
          (let ((ids (make-hash-table :test #'equal)))
            (goto-char (point-min))
            (while (re-search-forward
                    "\"id\"[ \t]*:[ \t]*\"\\([^\"]+\\)\"" nil t)
              (puthash (match-string-no-properties 1) t ids))
            (list :last-id (pilish--browse-last-entry-id-in-buffer)
                  :ids ids
                  :newline-p (and (> (point-max) (point-min))
                                  (eq (char-before (point-max)) ?\n))))))
    (error nil)))

(defun pilish--browse-fresh-entry-id (ids)
  "Return a random 8-hex entry id absent from IDS, like pi's generateId.
Collision checking is not optional: pi keys entries by id and walks
parent chains without a cycle guard, so a colliding id can wedge its
loader on the next session load.  After 100 failed tries fall back to a
wider 16-hex id, mirroring pi's full-UUID fallback."
  (cl-loop repeat 100
           for id = (format "%08x" (random #x100000000))
           when (not (gethash id ids))
           return id
           finally return (format "%08x%08x"
                                  (random #x100000000)
                                  (random #x100000000))))

(defun pilish--browse-append-session-entry (path type payload action)
  "Append one out-of-band entry of TYPE with PAYLOAD to session file PATH.
ACTION names the operation for messages (\"rename\", \"label\").
Mirrors pi's appenders without a live process.  The file is re-read
immediately before the append via
`pilish--browse-session-file-state' so :parentId is the id of
the current last parseable line (never the browser's cached leaf),
which keeps the entry from orphaning the context on the next load, and
the fresh id is checked against every id already in the file (pi's
loader cannot tolerate duplicates — see
`pilish--browse-fresh-entry-id').  When the file does not end
in a newline a separator is inserted first — bytes are never glued
onto a partial line.  PAYLOAD's pairs are encoded verbatim after the
shared :type/:id/:parentId/:timestamp head, so an omitted key stays
omitted (clearing a label relies on that: the load-time fold treats an
absent :label as cleared).

The file is NEVER created: pi's _persist appends per-entry once the
file exists, and its full-rewrite path is an exclusive create ('wx')
that only runs when the file never existed — creating it here would
crash pi's next flush with EEXIST.  So this helper only ever appends
to an existing readable file.  Races: a concurrent pi append between
the read and the write turns our line into a benign sibling (name
resolution is file-order latest-wins and projection filters these
bookkeeping entries), and stale-parent orphans are impossible by
construction.  A session live elsewhere sees the change on its next
state refresh.  Return non-nil when the line was appended; nil (with a
message) when PATH is unreadable."
  (if-let* ((state (pilish--browse-session-file-state path)))
      (let ((line (json-encode
                   (append (list :type type
                                 :id (pilish--browse-fresh-entry-id
                                      (plist-get state :ids))
                                 :parentId (plist-get state :last-id)
                                 :timestamp (format-time-string
                                             "%Y-%m-%dT%H:%M:%S.%3NZ"
                                             (current-time) t))
                           payload))))
        (let ((coding-system-for-write 'utf-8))
          (write-region
           (concat (unless (plist-get state :newline-p) "\n") line "\n")
           nil path 'append))
        t)
    (message "Pi: Cannot %s: session file is unreadable: %s" action path)
    nil))

(defun pilish--browse-append-session-info (path name)
  "Append a session_info entry naming session file PATH to NAME, out-of-band.
Thin wrapper over `pilish--browse-append-session-entry' with
the session_info payload (:name NAME); see there for the freshness,
race, and never-create contract.  Return non-nil when the line was
appended."
  (pilish--browse-append-session-entry
   path "session_info" (list :name name) "rename"))

(defun pilish-session-browser-rename ()
  "Rename the session at point.
Prompt once; empty or whitespace-only input cancels with a message
\(names cannot be cleared, matching the TUI).  Dispatch on
current-vs-other session (see
`pilish--browse-session-file-matches-p'):
  - Current session: `pilish-set-session-name' RPC, then
    refresh.  Known benign race: the refresh may beat pi's
    session_info flush, leaving a stale name visible until
    \\[pilish-browse-refresh].
  - Other session: `pilish--browse-append-session-info'
    appends out-of-band, then refreshes; an unreadable file cancels
    with a message and no refresh."
  (interactive)
  (if-let* ((path (pilish--session-browser-path-at-point)))
      (let* ((item (cl-find path pilish--session-browser-items
                            :key (lambda (it) (plist-get it :path))
                            :test #'equal))
             (existing (and item
                            (pilish--normalize-string-or-null
                             (plist-get item :name))))
             (input (read-string "Rename session: " (or existing "")))
             (clean (pilish--browse-clean-session-name input)))
        (if (string-empty-p clean)
            (message "Pi: Rename cancelled")
          (if (pilish--browse-session-file-matches-p
               (pilish--get-chat-buffer) path)
              (progn
                (pilish-set-session-name clean)
                (pilish--session-browser-fetch-and-render))
            (when (pilish--browse-append-session-info path clean)
              (pilish--session-browser-fetch-and-render)))))
    (message "Pi: No session at point")))

;;;; Point-Preserving Rerender

(defun pilish--browse-capture-point-anchor ()
  "Return the point anchor (IDENT . OFFSET) for the section at point.
IDENT is the section's `magit-section-ident'; OFFSET is the distance
from the section start.  Return nil when point sits on no content
section: either there is no section at point, or only the root
section, which every render recreates over the whole buffer and which
carries no identity (a loading-state render produces nothing else).
Used to both capture point before a render and to carry a position
across a fetch cycle whose intermediate renders destroy sections."
  (let ((section (magit-current-section)))
    (when (and section (not (eq section magit-root-section)))
      (cons (magit-section-ident section)
            (- (point) (oref section start))))))

(defun pilish--browse-rerender-preserving-point (buf render-fn
                                                            &optional fallback)
  "Erase BUF, render via RENDER-FN, restore point by section identity.
The section at point is captured as a `magit-section-ident' before the
erase; after rendering, point moves to that section's start (plus the
captured intra-section column offset).  Falls back to `point-min' when
the section no longer exists (e.g. filtered away or state change).

FALLBACK, when non-nil, is a `(IDENT . OFFSET)' anchor (from
`pilish--browse-capture-point-anchor') captured before an
intermediate render destroyed the sections point sat on — the fetch
cycle renders a loading state before the final render.  It is used
only when the point-local capture yields no anchor, so a plain
rerender (no FALLBACK) behaves exactly as before.

After the restore, every live window displaying BUF is synced to the
restored position: `erase-buffer' clamps all displaying windows to
bob and `goto-char' moves only the buffer's own point, so without
`set-window-point' a pane whose window is not selected keeps showing
point-at-top (same idiom as `pilish--with-scroll-preservation'
in ui.el).  The sync covers both restore paths — the point-min
fallback included."
  (with-current-buffer buf
    (let* ((anchor (or (pilish--browse-capture-point-anchor)
                       fallback))
           (ident (car anchor))
           (offset (cdr anchor)))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (funcall render-fn buf)
        (let ((new (and ident (magit-get-section ident))))
          (if new
              (let ((start (oref new start))
                    (end (oref new end)))
                (goto-char start)
                (when (> offset 0)
                  (forward-char (min offset (1- (- (or end (point-max)) start))))))
            (goto-char (point-min)))
          ;; `erase-buffer' clamped every displaying window's point to
          ;; bob; the `goto-char' above moved only the buffer's own
          ;; point.  Sync all live windows displaying BUF — the list
          ;; spans live frames and yields only live windows (same
          ;; idiom as `pilish--with-scroll-preservation').
          (dolist (w (get-buffer-window-list buf nil t))
            (set-window-point w (point)))
          (when-let* ((cur (magit-current-section)))
            (magit-section-show cur))
          (force-mode-line-update))))))

;;;; Fetch and Render

(defun pilish--session-browser-fetch-and-render ()
  "Fetch sessions and re-render the session browser.
Sessions are read from disk, so no live pi process is required.

The point anchor is captured before the loading-state render — that
render destroys the session sections, so without carrying the anchor
across the cycle the final render would find nothing under point to
restore (E2E defect A4).  A refresh issued while another fetch is
still loading finds no sections to capture and reuses the in-flight
cycle's anchor (see `pilish--session-browser-fetch-anchor')."
  (let* ((buf (current-buffer))
         (anchor (or (pilish--browse-capture-point-anchor)
                     ;; Mid-flight refresh: the loading render already
                     ;; destroyed the sections under point, so carry
                     ;; the anchor the in-flight cycle captured.
                     (and pilish--session-browser-loading
                          pilish--session-browser-fetch-anchor))))
    (setq pilish--session-browser-loading t
          pilish--session-browser-fetch-anchor anchor)
    ;; Loading-state render: default point behavior (nothing to keep).
    (pilish--session-browser-rerender)
    (pilish--browse-load-sessions
     pilish--session-browser-scope
     (lambda (items error)
       (when (buffer-live-p buf)
         ;; The scan calls back from a timer in whatever buffer is
         ;; current; render in the browser buffer, not that one.
         (with-current-buffer buf
           (setq pilish--session-browser-loading nil
                 pilish--session-browser-fetch-anchor nil
                 pilish--session-browser-error error
                 pilish--session-browser-items items)
           (pilish--session-browser-rerender anchor)))))))

(defun pilish--session-browser-rerender (&optional fallback)
  "Re-render the session browser from local state, preserving point.
FALLBACK is a pre-fetch `(IDENT . OFFSET)' anchor handed to
`pilish--browse-rerender-preserving-point' for the fetch
cycle's final render."
  (pilish--browse-rerender-preserving-point
   (current-buffer) #'pilish--session-browser-render fallback))

;;;; Tree Browser Section Classes and Keymaps

(defclass pilish-tree-node-section (magit-section)
  ((keymap :initform 'pilish-tree-node-section-map))
  "Section class for a tree node in the tree browser.")

(defun pilish--register-section-types ()
  "Register browse section classes in `magit--section-type-alist'.
Wrapped because that alist is a private Magit internal; if Magit ever
changes the mechanism, this is the single place to adapt.

Unregistered types (e.g. the `time-group' headings, which are not
interactive) silently fall back to the plain `magit-section' section class;
that is fine for display-only sections."
  (setf (alist-get 'session magit--section-type-alist)
        'pilish-session-section)
  (setf (alist-get 'tree-node magit--section-type-alist)
        'pilish-tree-node-section))
(pilish--register-section-types)

(defvar pilish-tree-browser-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map pilish-browse-mode-map)
    (define-key map (kbd "f") #'pilish-tree-browser-cycle-filter)
    (define-key map (kbd "l") #'pilish-tree-browser-set-label)
    (define-key map (kbd "/") #'pilish-tree-browser-search)
    (define-key map (kbd "RET") #'pilish-tree-browser-navigate)
    (define-key map (kbd "?") #'pilish-tree-browser-dispatch)
    (define-key map (kbd "h") #'pilish-tree-browser-dispatch)
    map)
  "Keymap for the tree browser.")

(defvar pilish-tree-node-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'pilish-tree-browser-navigate)
    (define-key map (kbd "l") #'pilish-tree-browser-set-label)
    map)
  "Keymap for tree node sections.")

;;;; Tree Browser State

(defvar-local pilish--tree-browser-filter "no-tools"
  "Filter mode: \"no-tools\", \"default\", \"user-only\", \"labeled-only\", \"all\".")

(defvar-local pilish--tree-browser-tree nil
  "Projected tree from the last `--browse-load-tree' callback.
Vector of root nodes in the browse node dialect.")

(defvar-local pilish--tree-browser-leaf-id nil
  "Current leaf node ID from the tree response.")

(defvar-local pilish--tree-browser-visible-count 0
  "Count of visible entries from the last render.
Cached to avoid re-flattening the tree in the header-line.")

(defvar-local pilish--tree-browser-search-query nil
  "Current search query string, or nil.")

(defvar-local pilish--tree-browser-search-tokens nil
  "Parsed search tokens.")

(defvar-local pilish--tree-browser-loading nil
  "Non-nil while a fetch is in progress.")

(defvar-local pilish--tree-browser-fetch-anchor nil
  "Point anchor carried across the in-flight fetch cycle.
Same lifecycle as `pilish--session-browser-fetch-anchor': set
from the anchor captured at fetch start, reused by a refresh issued
while loading, cleared when the cycle's final render runs.")

(defvar-local pilish--tree-browser-error nil
  "Error message string from the last tree fetch, or nil on success.
Rendered as an error state with a zero visible count.")

(defvar-local pilish--tree-browser-fetch-token 0
  "Generation counter for tree-browser fetches.
`pilish--browse-load-tree' bumps it per fetch; deferred reads
from superseded fetches drop themselves by comparing their captured
token against the buffer's current one (mirrors the session side).")

(defvar-local pilish--tree-browser-loaded-file nil
  "Session file the current tree was loaded from, or nil on error states.
Set, when a fetch succeeds, to the file the FETCH read (resolved at
fetch start — a chat session switch mid-read cannot retarget the
labeler onto a tree the browser is not showing);
`pilish--browse-set-label' compares against it to refuse
labeling a session the chat has since left.")

(defconst pilish--tree-filter-modes
  '("no-tools" "default" "user-only" "labeled-only" "all")
  "Available filter modes for the tree browser.")

;;;; Tree Browser Dispatch Transient

(defun pilish--tree-dispatch-heading ()
  "Return heading string for the tree browser dispatch transient.
Shows current filter mode.
Sibling of `pilish--tree-browser-header-line' — both
format the same state variables for different contexts.  Transient
evaluates group descriptions in the invoking browser buffer (see
`transient-with-shadowed-buffer' inside `transient--insert-group'),
so this buffer-local read sees the browser's state on the real
rendering path."
  (format "filter:%s" pilish--tree-browser-filter))

(transient-define-prefix pilish-tree-browser-dispatch ()
  "Tree browser help."
  [:description pilish--tree-dispatch-heading
   ["Actions"
    ("RET" "navigate" pilish-tree-browser-navigate)
    ("l" "label" pilish-tree-browser-set-label)
    ("g" "refresh" pilish-browse-refresh)
    ("q" "quit" quit-window)]
   ["Filter"
    ("f" "filter" pilish-tree-browser-cycle-filter)
    ("/" "search" pilish-tree-browser-search)]])

;;;; Tree Browser Faces

(defface pilish-tree-user
  '((t :inherit font-lock-keyword-face))
  "Face for user messages in the tree browser."
  :group 'pilish)

(defface pilish-tree-assistant
  '((t :inherit font-lock-string-face))
  "Face for assistant messages in the tree browser."
  :group 'pilish)

(defface pilish-tree-tool
  '((t :inherit shadow))
  "Face for tool results in the tree browser."
  :group 'pilish)

(defface pilish-tree-compaction
  '((t :inherit shadow :slant italic))
  "Face for compaction entries in the tree browser."
  :group 'pilish)

(defface pilish-tree-summary
  '((t :inherit warning))
  "Face for branch summaries in the tree browser."
  :group 'pilish)

(defface pilish-tree-active
  '((t :weight bold))
  "Face for active-path marker in the tree browser."
  :group 'pilish)

(defface pilish-tree-label
  '((t :inherit success :weight bold))
  "Face for node labels in the tree browser."
  :group 'pilish)

(defface pilish-tree-connector
  '((t :inherit shadow))
  "Face for tree connectors (├─, └─, │) in the tree browser."
  :group 'pilish)

;;;; Tree Browser Mode

(define-derived-mode pilish-tree-browser-mode
  pilish-browse-mode "Pi-Tree"
  "Major mode for browsing pi conversation tree.
\\{pilish-tree-browser-mode-map}"
  :group 'pilish
  (setq-local header-line-format
              '(:eval (pilish--tree-browser-header-line)))
  (setq pilish--browse-margin-width
        pilish--tree-margin-width)
  (setq-local right-margin-width pilish--tree-margin-width)
  (add-hook 'window-configuration-change-hook
            #'pilish--browse-apply-margins nil t))

;;;; Tree Browser Buffer Management

(defun pilish--tree-browser-buffer-name (dir)
  "Return tree browser buffer name for DIR."
  (format "*pilish-tree:%s*"
          (pilish--route-preserving-abbreviate-file-name dir)))

(defun pilish--get-or-create-tree-browser (dir)
  "Get or create tree browser buffer for DIR."
  (let* ((name (pilish--tree-browser-buffer-name dir))
         (buf (get-buffer name)))
    (or buf
        (with-current-buffer (generate-new-buffer name)
          (setq default-directory dir)
          (pilish-tree-browser-mode)
          (current-buffer)))))

;;;; Tree Node Formatting

(defun pilish--tree-node-face (node)
  "Return the face for NODE based on its type and role."
  (let ((type (plist-get node :type))
        (role (plist-get node :role)))
    (pcase type
      ("message"
       (pcase role
         ("user" 'pilish-tree-user)
         ("assistant" 'pilish-tree-assistant)
         ("branchSummary" 'pilish-tree-summary)
         ("compactionSummary" 'pilish-tree-compaction)
         (_ 'default)))
      ("tool_result" 'pilish-tree-tool)
      ("compaction" 'pilish-tree-compaction)
      ("branch_summary" 'pilish-tree-summary)
      ("model_change" 'shadow)
      ("thinking_level_change" 'shadow)
      (_ 'default))))

(defun pilish--tree-node-type-label (node)
  "Return a short type label for NODE."
  (let ((type (plist-get node :type))
        (role (plist-get node :role)))
    (pcase type
      ("message"
       (pcase role
         ("user" "you")
         ("assistant" "ast")
         ("branchSummary" "sum")
         ("compactionSummary" "cmp")
         ("bashExecution" "sh")
         (_ role)))
      ("tool_result"
       (or (plist-get node :toolName) "tool"))
      ("compaction" "compact")
      ("branch_summary" "summary")
      ("model_change" "model")
      ("thinking_level_change" "think")
      (_ type))))

(defun pilish--tree-strip-bracket-preview (node)
  "Return preview text for NODE with bracket wrappers stripped.
The upstream `formatToolCall' wraps previews as `[name: args]'.  Since
the type-label column already identifies the tool, the wrapper is
redundant.  Prefers `formattedToolCall' over `preview'."
  (let ((text (or (plist-get node :formattedToolCall)
                  (plist-get node :preview)
                  "")))
    (cond
     ;; [name: content] → content
     ((string-match "^\\[.+?: \\(.*\\)\\]$" text)
      (match-string 1 text))
     ;; [name] (no args) → empty
     ((string-match "^\\[.+\\]$" text)
      "")
     ;; Plain text → as-is
     (t text))))

(defun pilish--tree-node-preview (node)
  "Return preview text for NODE."
  (let ((type (plist-get node :type)))
    (pcase type
      ("compaction"
       (format "compacted (%s tokens)"
               (pilish--format-tokens-compact
                (or (plist-get node :tokensBefore) 0))))
      ("branch_summary"
       (pilish--first-nonempty-line
        (or (plist-get node :summary) "")))
      ("model_change"
       (format "%s/%s" (plist-get node :provider) (plist-get node :modelId)))
      ("thinking_level_change"
       (or (plist-get node :thinkingLevel) ""))
      ("tool_result"
       (pilish--tree-strip-bracket-preview node))
      ("message"
       (if (equal (plist-get node :role) "bashExecution")
           (pilish--tree-strip-bracket-preview node)
         (or (plist-get node :preview) "")))
      (_ (or (plist-get node :preview) "")))))

(defun pilish--tree-format-node-line (node is-active)
  "Format a single NODE into a display string.
IS-ACTIVE is non-nil if the node is on the active path.
Labels are rendered separately as right-margin overlays."
  (let* ((face (pilish--tree-node-face node))
         (type-label (pilish--tree-node-type-label node))
         (preview (pilish--tree-node-preview node))
         (marker (if is-active
                     (pilish--propertize-face
                      "• " 'pilish-tree-active)
                   "  "))
         (type-str (pilish--propertize-face
                    (format "%-7s" type-label) face))
         (preview-str (pilish--propertize-face preview face)))
    (concat marker type-str " " preview-str)))

;;;; Tree Browser Rendering

(defun pilish--tree-browser-render (buf)
  "Render the tree browser in BUF from its buffer-local state."
  (with-current-buffer buf
    (let* ((inhibit-read-only t)
           (tree pilish--tree-browser-tree)
           (leaf-id pilish--tree-browser-leaf-id)
           (filter pilish--tree-browser-filter))
      (magit-insert-section (root)
        (cond
         (pilish--tree-browser-loading
          (setq pilish--tree-browser-visible-count 0)
          (insert (pilish--propertize-face
                   "Loading tree..."
                   'pilish-activity-phase)
                  "\n"))
         (pilish--tree-browser-error
          (setq pilish--tree-browser-visible-count 0)
          (insert (pilish--propertize-face
                   (format "Error: %s\n" pilish--tree-browser-error)
                   'error)))
         ((or (null tree) (= (length tree) 0))
          (insert "No conversation tree.\n"))
         (t
          (let* ((flat (pilish--flatten-tree-for-display
                        tree leaf-id filter))
                 (active-ids (pilish--active-path-ids tree leaf-id))
                 ;; Apply search filter if active
                 (visible (if pilish--tree-browser-search-tokens
                              (cl-remove-if-not
                               (lambda (entry)
                                 (pilish--matches-filter-p
                                  (pilish--tree-node-preview
                                   (nth 0 entry))
                                  pilish--tree-browser-search-tokens))
                               flat)
                            flat)))
            (setq pilish--tree-browser-visible-count
                  (length visible))
            (if (null visible)
                (insert "No matching entries.\n")
              (dolist (entry visible)
                (let* ((node (nth 0 entry))
                       (prefix (nth 2 entry))
                       (node-id (plist-get node :id))
                       (is-active (gethash node-id active-ids))
                       (prefix-str (pilish--propertize-face
                                    prefix
                                    'pilish-tree-connector))
                       (line (pilish--tree-format-node-line
                              node is-active)))
                  (magit-insert-section (tree-node node-id)
                    (magit-insert-heading
                      (concat prefix-str line))
                    (when-let* ((label (plist-get node :label)))
                      ;; 3 = "[" + "]" + 1 char padding
                      (let ((truncated
                             (pilish--truncate-string
                              label
                              (- pilish--tree-margin-width 3))))
                        (pilish--make-margin-overlay
                         (pilish--propertize-face
                          (format "[%s]" truncated)
                          'pilish-tree-label)))))))))))))))

;;;; Tree Browser Header-Line

(defun pilish--tree-browser-header-line ()
  "Return header-line string for the tree browser.
Uses cached visible count from the last render to avoid redundant
tree flattening on every redisplay cycle."
  (let* ((filter pilish--tree-browser-filter)
         (query pilish--tree-browser-search-query)
         (total pilish--tree-browser-visible-count))
    (mapconcat #'identity
               (append (list (format "Tree [%s]" filter)
                             (format "(%d)" total))
                       (and query (list (format "/%s" query)))
                       (list (pilish--propertize-face "?:help" 'shadow)))
               " │ ")))

;;;; Tree Browser Interactive Commands

(defun pilish-tree-browser-cycle-filter ()
  "Cycle the tree browser filter mode."
  (interactive)
  (let* ((modes pilish--tree-filter-modes)
         (current pilish--tree-browser-filter)
         (next (or (cadr (member current modes)) (car modes))))
    (setq pilish--tree-browser-filter next)
    (pilish--tree-browser-rerender)
    (message "Pi: Filter: %s" next)))

(defun pilish-tree-browser-search ()
  "Set or clear search filter in the tree browser."
  (interactive)
  (let ((query (read-string "Filter (regexp tokens): "
                            pilish--tree-browser-search-query))
        (need-rerender t))
    (if (string-empty-p query)
        (setq pilish--tree-browser-search-query nil
              pilish--tree-browser-search-tokens nil)
      (condition-case err
          (let ((tokens (split-string query)))
            (dolist (tok tokens)
              (string-match-p tok ""))
            (setq pilish--tree-browser-search-query query
                  pilish--tree-browser-search-tokens tokens))
        (invalid-regexp
         (message "Pi: Invalid regexp: %s" (error-message-string err))
         (setq need-rerender nil))))
    (when need-rerender
      (pilish--tree-browser-rerender))))

(defun pilish-tree-browser-navigate ()
  "Navigate to the tree node at point."
  (interactive)
  (if-let* ((section (magit-current-section))
            (node-id (oref section value)))
      (pilish--browse-navigate node-id)
    (message "Pi: No tree node at point")))

(defun pilish-tree-browser-set-label ()
  "Set or clear a label on the tree node at point."
  (interactive)
  (when-let* ((section (magit-current-section))
              (node-id (oref section value)))
    (let* ((current-label (when pilish--tree-browser-tree
                            (pilish--tree-find-label
                             pilish--tree-browser-tree node-id)))
           (new-label (read-string
                       (if current-label
                           (format "Label (current: %s, empty to clear): "
                                   current-label)
                         "Label: ")
                       current-label))
           (label (if (string-empty-p (string-trim new-label)) nil new-label)))
      (pilish--browse-set-label node-id label))))

(defun pilish--tree-find-label (tree node-id)
  "Find the label for NODE-ID in TREE.
Returns the label string or nil."
  (let ((stack (append tree nil))
        (result nil))
    (while (and stack (not result))
      (let* ((node (pop stack))
             (children (plist-get node :children)))
        (when (equal (plist-get node :id) node-id)
          (setq result (plist-get node :label)))
        (when (vectorp children)
          (dotimes (i (length children))
            (push (aref children i) stack)))))
    result))

(defun pilish--tree-find-node (tree node-id)
  "Find the projected node with :id NODE-ID in TREE; nil when absent.
Iterative pre-order walk; used by
`pilish--browse-navigate-message' for the success preview."
  (let ((stack (append tree nil))
        (found nil))
    (while (and stack (not found))
      (let ((node (pop stack)))
        (if (equal (plist-get node :id) node-id)
            (setq found node)
          (setq stack (append (append (plist-get node :children) nil)
                              stack)))))
    found))

(defun pilish--tree-node-with-label (node label)
  "Return a copy of projected NODE carrying :label LABEL, or no label.
LABEL nil removes the label pair entirely — the load-time fold treats
an absent label as cleared, and projection only emits the pair when a
label is set, so a patched node stays shape-identical to a fresh read.
Only NODE's own plist is copied; the :children vector is shared as-is,
keeping the copy O(1) in tree size — rebuilding the spine above NODE
is `pilish--tree-apply-label's business.  A newly set :label
pair goes right after :timestamp, the canonical projected position."
  (let ((out nil)
        (replaced nil))
    (while (consp node)
      (let ((key (pop node)))
        (if (eq key :label)
            ;; Drop the old pair wherever it sits.
            (when (consp node) (pop node))
          (setq out (nconc out
                           (list key (if (consp node) (pop node) nil))))
          (when (and (eq key :timestamp) label)
            (setq out (nconc out (list :label label))
                  replaced t)))))
    (if (or replaced (not label))
        out
      ;; No :timestamp anchor (not a projected node): append at the end.
      (nconc out (list :label label)))))

(defun pilish--tree-apply-label (tree node-id label)
  "Patch TREE so the projected node with NODE-ID carries LABEL, or none.
Return a fresh tree vector: the root-to-node spine is rebuilt with
fresh plists and child vectors, with the patched node
\\(`pilish--tree-node-with-label'\\) `aset' into each container,
while every unvisited subtree is shared — the patch costs O(path
length), not O(tree size).  Return nil when NODE-ID is not in TREE.
Both the search and the rebuild are iterative, so deep chains cannot
overflow the Lisp stack."
  (when (vectorp tree)
    (let* ((root-frame (cons tree 0))
           (stack (list root-frame))
           ;; PATH holds the reversed (CONTAINER . INDEX) frames of the
           ;; current DFS chain; once the target is found it is the
           ;; deepest-first root-to-node path.
           (path nil)
           (found nil))
      (catch 'exited
        (while stack
          (let* ((frame (car stack))
                 (vec (car frame))
                 (idx (cdr frame)))
            (if (>= idx (length vec))
                (progn
                  (pop stack)
                  ;; This frame's owner node is done; leave its path
                  ;; entry too (the root frame has no owner above it).
                  (unless (eq frame root-frame) (pop path)))
              (setcdr frame (1+ idx))
              (let* ((node (aref vec idx))
                     (children (plist-get node :children))
                     (descend (and (vectorp children)
                                   (> (length children) 0))))
                (push (cons vec idx) path)
                (when (equal (plist-get node :id) node-id)
                  (setq found t)
                  (throw 'exited t))
                (if descend
                    (push (cons children 0) stack)
                  (pop path))))))
        nil)
      (when found
        (let* ((target-frame (car path))
               (target (aref (car target-frame) (cdr target-frame)))
               (patched (pilish--tree-node-with-label target label))
               (result nil)
               (frames path))
          (while frames
            (let* ((frame (car frames))
                   (vec (copy-sequence (car frame))))
              (aset vec (cdr frame) patched)
              (if (cdr frames)
                  ;; The node at the next frame up owns VEC as its
                  ;; :children: hand it a fresh plist pointing there.
                  (let* ((owner-frame (cadr frames))
                         (owner (aref (car owner-frame)
                                      (cdr owner-frame))))
                    (setq patched (plist-put (copy-sequence owner)
                                             :children vec)))
                (setq result vec)))
            (setq frames (cdr frames)))
          result)))))

;;;; Disk-Backed Data Layer Seams

(defun pilish--browse-current-session-directory ()
  "Return the session directory for the \"current\" scope, or nil.
Resolution order: the optional menu-supplied session list directory
when menu.el is loaded, then the munged stable session directory of the
linked chat buffer — rooted on that directory's own host when remote —
then the munged project directory; the last works with no session at
all.  Signals when resolution itself fails."
  (or (and (fboundp 'pilish--session-list-directory)
           (pilish--session-list-directory))
      (when-let* ((chat-buf pilish--chat-buffer))
        (and (buffer-live-p chat-buf)
             (let ((cwd (pilish--chat-session-directory chat-buf)))
               (pilish-jsonl-session-dir-for-cwd
                cwd (pilish-jsonl-sessions-root cwd)))))
      (pilish-jsonl-session-dir-for-cwd
       (pilish--session-directory))))

(defun pilish--browse-session-directories (scope)
  "Return the list of session directories to scan for SCOPE.
\"current\" is the single current-project directory (see
`pilish--browse-current-session-directory').  \"all\" is
every root-level munged --…-- directory under the sessions root —
remote-anchored when a current directory is known — so .subagents
sidecars and non-munged directories are excluded by construction.
Missing roots read as empty; signals when resolution itself fails."
  (if (not (equal scope "all"))
      (list (pilish--browse-current-session-directory))
    (let* ((cur (pilish--browse-current-session-directory))
           (root (if cur
                     (pilish-jsonl-sessions-root
                      (file-name-as-directory cur))
                   (pilish-jsonl-sessions-root))))
      (delq nil
            (mapcar (lambda (dir)
                      (and (file-directory-p dir) dir))
                    (condition-case nil
                        (directory-files root t "\\`--")
                      (error nil)))))))

(defun pilish--browse-session-files (dirs)
  "Return every \\.jsonl file directly inside DIRS, in listing order.
Unreadable or missing directories are skipped silently (empty)."
  (apply #'append
         (mapcar (lambda (dir)
                   (condition-case nil
                       (directory-files dir t "\\.jsonl\\'")
                     (error nil)))
                 dirs)))

(defun pilish--browse-session-scan-current-p (buf token)
  "Return non-nil if BUF still owns the session scan generation TOKEN."
  (and (buffer-live-p buf)
       (eq token (buffer-local-value 'pilish--session-browser-fetch-token buf))))

(defun pilish--browse-scan-session-files
    (buf token files items callback &optional state)
  "Advance FILES and accumulated ITEMS for BUF's generation TOKEN.
STATE is the optional in-progress JSONL scan for the first file.  Each
slice shares a 10 ms deadline across opens and line processing.  A
positive-delay continuation allows a command-loop turn; it is not a
latency guarantee.  Whole-file IO, individual records, joining, GC, and
final synchronous filtering/rendering can exceed the budget.

At most one file state is retained by a pending continuation.  Completion,
errors and quit close it before CALLBACK receives (ITEMS ERROR).  A stale
or dead owner drops work and closes its state when the continuation next
runs, without a callback.  Hiding the browser with q does not cancel it."
  (let (transferred finished failure)
    (unwind-protect
        (when (pilish--browse-session-scan-current-p buf token)
          (condition-case err
              (let ((deadline (+ (float-time) 0.010))
                    yield)
                (while (and files (not yield) (< (float-time) deadline))
                  (let (result)
                    (condition-case nil
                        (progn
                          (unless state
                            (setq state (pilish-jsonl-open-session-info
                                         (car files) t)))
                          (when state
                            (setq result (pilish-jsonl-step-session-info
                                          state deadline))))
                      ;; Ordinary file failures skip just this file.  Quit
                      ;; instead reaches the scan-level interruption handler.
                      (error (setq result '(done))))
                    (if (or (null state) result)
                        (progn
                          (when (cdr result) (push (cdr result) items))
                          (pilish-jsonl-close-session-info state)
                          (setq state nil files (cdr files)))
                      (setq yield t))))
                ;; File handlers can run Lisp and supersede/kill the owner.
                (when (pilish--browse-session-scan-current-p buf token)
                  (if files
                      (progn
                        (run-at-time 0.001 nil #'pilish--browse-scan-session-files
                                     buf token files items callback state)
                        (setq transferred t))
                    (setq finished t))))
            (quit (setq failure "Session scan was interrupted"))
            (error (setq failure (format "Session scan failed: %s"
                                        (error-message-string err))))))
      (unless transferred (pilish-jsonl-close-session-info state)))
    ;; Outside handlers and after resource cleanup: a signaling consumer
    ;; must not be called again as an error callback.
    (when (pilish--browse-session-scan-current-p buf token)
      (cond (failure (funcall callback nil failure))
            (finished (funcall callback (nreverse items) nil))))))

(defun pilish--browse-load-sessions (scope callback)
  "Load session items for SCOPE, then call CALLBACK with (ITEMS ERROR).
ITEMS is a list of session plists in the browse session dialect:
\(:path :id :cwd :name? :parentSessionPath? :created :modified
:messageCount :firstMessage :searchText) — the optional search-corpus
output of `pilish-jsonl-read-session-info'.  ERROR is an error
string or nil.  SCOPE is \"current\" (one project directory) or \"all\" (every
munged directory under the sessions root).  The scan is
chunked (see `pilish--browse-scan-session-files'), shows a
loading state throughout, and reports exactly once; a superseded
fetch's callback is dropped by the fetch token — a superseding fetch
cancels an older one before any slice runs.  Directory resolution
failures surface synchronously as the ERROR string \"Cannot list
sessions: …\"."
  (let ((buf (current-buffer)))
    (setq pilish--session-browser-fetch-token
          (1+ pilish--session-browser-fetch-token))
    (let ((token pilish--session-browser-fetch-token))
      (let ((dirs nil)
            (failure nil))
        (condition-case err
            (setq dirs (pilish--browse-session-directories scope))
          (error
           (setq failure (format "Cannot list sessions: %s"
                                (error-message-string err)))))
        (if failure
            (funcall callback nil failure)
          (run-at-time 0 nil #'pilish--browse-scan-session-files
                       buf token
                       (pilish--browse-session-files dirs)
                       nil callback))))))

(defun pilish--tree-browser-chat-session-file ()
  "Return the linked chat buffer's current session file, or nil.
A live `pilish--chat-buffer' link supplies the normalized
:session-file from its state plist (populated at startup via get_state
--apply-state-response and TRAMP-prefixed for Emacs).  The file persists
after process death, so tree fetches and labels keep working with no
live pi process.  Nil covers both a dead link and a chat whose session
file does not exist yet (it is created on the first assistant reply)."
  (when-let* ((chat-buf pilish--chat-buffer))
    (when (buffer-live-p chat-buf)
      (with-current-buffer chat-buf
        (when (plistp pilish--state)
          (pilish--normalize-string-or-null
           (plist-get pilish--state :session-file)))))))

(defun pilish--browse-load-tree (callback)
  "Load the conversation tree, then call CALLBACK with (TREE LEAF-ID MESSAGE).
TREE is a vector of projected root nodes in the browse node dialect,
LEAF-ID the projected leaf entry id, and MESSAGE an error string or
nil on success — the same shape as the session side's (ITEMS ERROR)
callback.  The third MESSAGE argument lets callers render precise
error states instead of a generic \"no tree\".

The tree comes from the linked chat's session file on DISK —
`pilish-jsonl-project-session-file' — never an RPC get_tree.
Labels appended out-of-band fold back on every disk read, navigation
rewrites this same file, and no process is needed — the state
:session-file key persists after process death.  The tree shows
the last PERSISTED turn, so it lags an in-flight turn; refresh
manually with \\[pilish-browse-refresh].

The buffer's fetch token is bumped here (mirroring
`pilish--browse-load-sessions'); then a missing chat link
reports the link error and a link with no session file yet — or one
naming a path that does not exist — reports the not-yet error, both
synchronously.  Otherwise the read itself is deferred through
`(run-at-time 0 ...)' so the caller's forced redisplay can paint the
loading state first (see `pilish--tree-browser-fetch-and-render':
Emacs runs due 0-timers before redisplaying, so without the forced
paint a single timer hop starves the loading render entirely); then
it runs as one blocking read (a 53 MB worst-case session reads in
~0.6 s, typical files in tens of milliseconds; chunking would
complicate the pure jsonl reader for no UI gain).  A deferred read
drops itself when a newer fetch has bumped the token, and is wrapped
in `condition-case': a nil or garbage read reports MESSAGE \"Session
file is unreadable or not a pi session file: PATH\" instead of
signaling, and a `quit' during the blocking read (C-g against a huge
file) reports \"Session file read was interrupted: PATH\" — `quit'
is not an `error', so without its own handler the callback would
never run and the browser would sit on its loading state forever."
  (let ((buf (current-buffer)))
    (setq pilish--tree-browser-fetch-token
          (1+ pilish--tree-browser-fetch-token))
    (let ((token pilish--tree-browser-fetch-token)
          (linked (and pilish--chat-buffer
                       (buffer-live-p pilish--chat-buffer)))
          (path (pilish--tree-browser-chat-session-file)))
      (cond
       ((not linked)
        (funcall callback nil nil
                 "No linked pi chat session (open the tree browser from a pi chat)"))
       ((or (not path) (not (file-exists-p path)))
        (funcall callback nil nil
                 "No session file yet — it is created on the first assistant reply"))
       (t
        (run-at-time
         0 nil
         (lambda ()
           (when (and (buffer-live-p buf)
                      (eq token (buffer-local-value
                                 'pilish--tree-browser-fetch-token
                                 buf)))
             (let ((tree nil)
                   (leaf-id nil)
                   (failure nil))
               (condition-case nil
                   (let ((result (pilish-jsonl-project-session-file
                                  path)))
                     (if result
                         (setq tree (plist-get result :tree)
                               leaf-id (plist-get result :leafId))
                       (setq failure
                             (format "Session file is unreadable or not a pi session file: %s"
                                     path))))
                 (quit
                  (setq failure
                        (format "Session file read was interrupted: %s" path)))
                 (error
                  (setq failure
                        (format "Session file is unreadable or not a pi session file: %s"
                                path))))
               (funcall callback tree leaf-id failure))))))))))

(defun pilish--browse-session-file-matches-p (chat-buf path)
  "Return non-nil when CHAT-BUF's current session file is PATH.
Compares `expand-file-name' spellings (anchored at CHAT-BUF so relative
session files resolve like the chat does) with `file-equal-p' as the
symlink-aware fallback."
  (and (buffer-live-p chat-buf)
       (with-current-buffer chat-buf
         (let ((current (plist-get pilish--state :session-file)))
           (and (stringp current)
                (or (equal (expand-file-name current)
                           (expand-file-name path))
                    (file-equal-p current path)))))))

(defun pilish--browse-transition-refused-p (chat-buf action)
  "Return non-nil when CHAT-BUF must refuse to start ACTION now.
One gate for both halves of the transition guard, shared by
`pilish--browse-switch-session' and
`pilish--browse-navigate': an ACTIVE session transition
refuses with \"Pi: Cannot ACTION while switching sessions\" — the
status stays idle during the transition latch, so
`pilish--session-transition-ready-p' cannot see it, and a
second concurrent switch or navigate would race the first — and
otherwise the ready guard runs with ACTION (reporting its own refusal
when it returns nil)."
  (if (pilish--session-transition-active-p chat-buf)
      (progn
        (message "Pi: Cannot %s while switching sessions" action)
        t)
    (not (pilish--session-transition-ready-p chat-buf action))))

(defun pilish--browse-switch-session (path)
  "Switch the linked chat session to session file PATH.
Guards, in order: a live linked chat buffer (else `user-error'), a live
pi process (else `user-error'), and no session transition in flight —
`pilish--browse-transition-refused-p' gates both an active
transition, which keeps the status idle (without the explicit check a
second RET would race the first switch), and the ready guard, which
reports its own refusal and returns quietly.  Delegation is
`pilish--resume-selected-session' (PROC CHAT-BUF PATH); its
synchronous `user-error's (bad cwd, duplicate open) surface in the
browser.  Afterwards `pilish--browse-quit-when-settled' waits
out the transition and dismisses the browser window only when the chat
landed on PATH; a failed switch leaves the browser open (menu already
messaged).  No extra refresh logic: \\[pilish-browse-refresh]
re-derives the \"current\" scope live and the entry point opens a fresh
browser per project directory."
  (let ((chat-buf pilish--chat-buffer))
    (unless (and chat-buf (buffer-live-p chat-buf))
      (user-error "No pi session to switch to"))
    (let ((proc (buffer-local-value 'pilish--process chat-buf)))
      (unless (pilish--session-live-process-p proc)
        (user-error "Pi process is not running"))
      (unless (pilish--browse-transition-refused-p chat-buf "switch")
        (pilish--resume-selected-session proc chat-buf path)
        (pilish--browse-quit-when-settled
         chat-buf (selected-window) path)))))

(defun pilish--browse-poll-settled (chat-buf win path deadline)
  "Polling body of `pilish--browse-quit-when-settled'.
CHAT-BUF, WIN, and PATH are the parent's arguments; give up silently
once DEADLINE (an absolute time) has passed.  A dead CHAT-BUF also ends
the poll quietly — there is nothing left to wait for, and probing a
killed buffer would signal inside the timer."
  (if (not (buffer-live-p chat-buf))
      nil
    (if (pilish--session-transition-active-p chat-buf)
        (when (time-less-p (current-time) deadline)
          (run-at-time 0.05 nil #'pilish--browse-poll-settled
                       chat-buf win path deadline))
      (when (and (pilish--browse-session-file-matches-p chat-buf path)
                 (window-live-p win)
                 (with-current-buffer (window-buffer win)
                   (derived-mode-p 'pilish-session-browser-mode
                                   'pilish-tree-browser-mode)))
        (quit-window nil win)))))

(defun pilish--browse-quit-when-settled (chat-buf win path)
  "Wait out CHAT-BUF's session transition, then dismiss the browser window.
Polls `pilish--session-transition-active-p' every 0.05 s with
a 30 s timeout.  Once settled, WIN is quit ONLY when the chat state's
:session-file matches PATH — a failed switch already messaged via the
menu, so a mismatch silently leaves the browser open — and only when
WIN still shows a pi browse buffer (session OR tree browser, via
`derived-mode-p'): a dead or repurposed window (the buffer was killed
mid-poll) is left alone so `quit-window' can never close whatever
replaced it."
  (pilish--browse-poll-settled
   chat-buf win path (time-add (current-time) 30)))

(defun pilish--browse-navigate (node-id)
  "Move the live conversation onto tree node NODE-ID.
Guard → rewrite → switch → reload → prefill, mirroring pi's
navigateTree without a navigate RPC:

 1. a live linked chat buffer, else `user-error' \"No pi session to
    navigate\";
 2. the loaded-file guard (as `pilish--browse-set-label'):
    a fresh session-file resolution that is nil messages \"Pi: Cannot
    navigate: no session file\", one that disagrees with
    `pilish--tree-browser-loaded-file' messages \"Pi: Session
    changed since the tree was loaded — refresh with g\" (the rewrite
    would have to pick one of two files);
 3. a live pi process, else `user-error' \"Pi process is not running\";
 4. no in-flight session transition (the first half of
    `pilish--browse-transition-refused-p') —
    `--session-transition-ready-p' cannot see one (status stays idle
    during the latch), and a second RET during a switch would race it;
 5. `pilish--session-transition-ready-p' with the action
    \"navigate\" (the second half; reports its own refusal);
 6. a FRESH `pilish-jsonl-read-file' — the browser's cached
    tree can lag the file — else the unreadable message;
 7. a versioned header: version 1 files (no ids) refuse with the
    migrate hint;
 8. `pilish-jsonl-navigation-target': unknown node ids refuse
    with the refresh hint; a nil :leaf-id (the root user message has
    no parent to rewind to) refuses with the fork hint — the chat's
    fork command does that job;
 9. :current-p is the two-way no-op: without :prefill just message
    \"Pi: Already at current position\"; with :prefill (re-editing a
    prompt the file already sits on) prefill, message, and settle —
    no write, no switch in either case;
10. the resume cwd pre-flight (`--session-file-cwd-or-error') runs
    BEFORE any write so its `user-error's surface before the file
    changes;
11. the local atomic rewrite (`--browse-rewrite-session-file') — the
    closing rename is the ONLY call that touches the session file;
    pre-commit local failure messages and stops byte-identically;
12. `pilish--resume-selected-session' (PROC CHAT-BUF PATH) —
    a same-path switch is legal, so the switch rides the normal
    choreography including the transition latch and history reload;
13. the input prefill runs immediately after the resume RPC is
    scheduled (the latch blocks sending until the switch settles),
    against the input buffer captured from the chat BEFORE the RPC;
14. \"Pi: Navigated to PREVIEW\" from the cached tree
    (`--tree-find-node', `--tree-node-preview', truncated to 60;
    \"Pi: Navigated\" without a preview), then
    `pilish--browse-quit-when-settled';
15. no auto-reopen of the browser — refresh with `g'.

On ordinary local files this guard/read/rewrite path is synchronous and
does not yield back to Emacs, so only an independent writer can stale
the file between checks.  The ready guard idles the linked pi process
but cannot exclude another pi instance or external writer; such a
writer between the authoritative line read and rename can lose its
change.  TRAMP file handlers may yield, and their rename need not be
atomic.  These residual risks are accepted here rather than inventing
cross-module writer coordination."
  (let ((chat-buf pilish--chat-buffer))
    (unless (and chat-buf (buffer-live-p chat-buf))
      (user-error "No pi session to navigate"))
    ;; The input buffer is captured BEFORE the RPC: the chat may retarget
    ;; buffers during the switch (step 12).
    (let ((input-buf (buffer-local-value 'pilish--input-buffer
                                         chat-buf))
          (path (pilish--tree-browser-chat-session-file)))
      (cond
       ((null path)
        (message "Pi: Cannot navigate: no session file"))
       ((not (equal pilish--tree-browser-loaded-file path))
        (message "Pi: Session changed since the tree was loaded — refresh with g"))
       (t
        (let ((proc (buffer-local-value 'pilish--process chat-buf)))
          (unless (pilish--session-live-process-p proc)
            (user-error "Pi process is not running"))
          (cond
           ((pilish--browse-transition-refused-p chat-buf "navigate")
            nil)
           (t
            (let ((session (pilish-jsonl-read-file path)))
              (cond
               ((null session)
                (message
                 "Pi: Cannot navigate: session file is unreadable or not a pi session file: %s"
                 path))
               ((not (plist-get (plist-get session :header) :version))
                (message
                 "Pi: Session file uses an old format; open it with pi once to migrate, then refresh with g"))
               (t
                (let ((target (pilish-jsonl-navigation-target
                               session node-id)))
                  (cond
                   ((null target)
                    (message "Pi: No such tree node — refresh with g"))
                   ((null (plist-get target :leaf-id))
                    (message
                     "Pi: Cannot rewind before the first message; fork it from the chat instead"))
                   ((plist-get target :current-p)
                    (if (not (plist-get target :prefill))
                        (message "Pi: Already at current position")
                      (pilish--browse-prefill-input
                       input-buf (plist-get target :prefill))
                      (pilish--browse-navigate-message node-id)
                      (pilish--browse-quit-when-settled
                       chat-buf (selected-window) path)))
                   (t
                    (condition-case err
                        (pilish--session-file-cwd-or-error path)
                      ;; Re-signal the guard's own wording before any
                      ;; write happens.
                      (user-error (signal (car err) (cdr err))))
                    (let ((lines (pilish-jsonl-navigation-lines
                                  path (plist-get target :leaf-id))))
                      (if (null lines)
                          (message
                           "Pi: Cannot navigate: session file is unreadable or not a pi session file: %s"
                           path)
                        (when (pilish--browse-rewrite-session-file
                               path lines)
                          (pilish--resume-selected-session
                           proc chat-buf path)
                          (pilish--browse-prefill-input
                           input-buf (plist-get target :prefill))
                          (pilish--browse-navigate-message node-id)
                          (pilish--browse-quit-when-settled
                           chat-buf (selected-window) path))))))))))))))))))

(defun pilish--browse-navigate-message (node-id)
  "Message the navigate success for NODE-ID from the cached tree.
The preview comes from `pilish--tree-find-node' and
`pilish--tree-node-preview' over the browser's cached tree
with no refetch, truncated to 60; without a preview the bare
\"Pi: Navigated\"."
  (let* ((node (when (vectorp pilish--tree-browser-tree)
                 (pilish--tree-find-node
                  pilish--tree-browser-tree node-id)))
         (preview (if node (pilish--tree-node-preview node) "")))
    (if (and (stringp preview) (not (string-empty-p preview)))
        (message "Pi: Navigated to %s"
                 (pilish--truncate-string preview 60))
      (message "Pi: Navigated"))))

(defun pilish--browse-rewrite-session-file (path lines)
  "Atomically replace the session file at PATH with LINES.
LINES is the `pilish-jsonl-navigation-lines' vector; the
joined bytes gain one final LF.  The ONLY call that touches PATH is
the closing `rename-file': bytes land without coding or end-of-line
conversion in a sibling temp file (`.pi-nav-…' in PATH's directory)
that carries PATH's modes best-effort, then replace PATH.  On ordinary
local files the sibling is on the same filesystem and rename is the
atomic commit; pi holds no persistent descriptor on session files, so
its next append/read opens the replacement.  On TRAMP a handler may
degrade rename to copy+delete: replacement can be visible in pieces
and a remote failure cannot promise a byte-identical original.  This
is accepted because in-place writing is strictly worse.

The rewrite reorders complete raw lines only.  It always adds one final
LF; CR bytes returned for CRLF lines remain in place, so an all-CRLF
file with its final delimiter stays all-CRLF.  A file missing its
trailing newline gains LF (or CRLF when its final raw line ends in CR).
The ready guard only idles the linked pi process: an independent
append/change between the
fresh line read and local rename can still be lost.  `unwind-protect'
removes the temp on an error or quit before commit.  Thus on ordinary
local files pre-commit failures leave PATH byte-identical and no temp
behind; errors report \"Pi: Navigate failed: …\" and return nil, while quits
propagate after cleanup.  Success returns non-nil."
  (let* ((contents (concat (mapconcat #'identity (append lines nil) "\n")
                           "\n"))
         (tmp (make-temp-name
               (concat (file-name-directory path) ".pi-nav-")))
         (swapped nil))
    (condition-case err
        (unwind-protect
            (progn
              (let ((coding-system-for-write 'no-conversion))
                ;; VISIT 0: no "Wrote file" message, no lockfile — and
                ;; the target is TMP, never PATH.  LINES are unibyte raw
                ;; file lines, so no coding or EOL conversion is allowed.
                (write-region contents nil tmp nil 0))
              (ignore-errors
                (set-file-modes tmp (file-modes path)))
              (rename-file tmp path t)
              (setq swapped t))
          (unless swapped
            (ignore-errors (delete-file tmp))))
      (error
       (message "Pi: Navigate failed: %s" (error-message-string err))
       nil))))

(defun pilish--browse-prefill-input (input-buf text)
  "Replace INPUT-BUF's draft with TEXT; nil TEXT still erases.
Erasing unsent input is deliberate (the fork command's precedent):
the navigate prefill replaces whatever draft was in flight.  Runs
immediately after the resume RPC is scheduled — the transition latch
blocks sending until the switch settles, so the text cannot leak into
the outgoing session.  Failures are non-fatal."
  (when (buffer-live-p input-buf)
    (condition-case err
        (pilish--replace-input-draft input-buf text)
      (error
       (message "Pi: Failed to prefill prompt - %s"
                (error-message-string err))))))

(defun pilish--browse-set-label (node-id label)
  "Set LABEL (string, or nil to clear) on tree node NODE-ID.
Appends a `label' entry to the linked chat's session file out-of-band
via `pilish--browse-append-session-entry' — pi's
appendLabelChange shape, with the :label key omitted entirely on a
clear (the load-time fold treats an absent or empty label as
cleared).  The append also makes the label entry the file's new raw
leaf; the next fetch's projected leaf still resolves up to the last
visible entry, so the active path does not move.  Instead of
re-reading the file, the cached projected tree is patched locally
\\(`pilish--tree-apply-label'\\) and re-rendered: section
identity is the node id, which labeling never changes, so point
survives.  Report \"Pi: Label set to LABEL\" or \"Pi: Label cleared\".

Guards: no resolvable session file messages \"Pi: Cannot label: no
session file\" (nothing is written anywhere — session files are
append-only and must never be created here); a fresh resolution that
disagrees with `pilish--tree-browser-loaded-file' (the chat
switched sessions behind the browser's back) messages \"Pi: Session
changed since the tree was loaded — refresh with g\" and appends
nothing — writing into the old file would still be harmless for pi (a
benign sibling), but the browser would then show a label its tree no
longer reflects."
  (let ((path (pilish--tree-browser-chat-session-file)))
    (cond
     ((not path)
      (message "Pi: Cannot label: no session file"))
     ((not (equal pilish--tree-browser-loaded-file path))
      (message "Pi: Session changed since the tree was loaded — refresh with g"))
     (t
      (when (pilish--browse-append-session-entry
             path "label"
             (append (list :targetId node-id)
                     (when label (list :label label)))
             "label")
        (setq pilish--tree-browser-tree
              (or (pilish--tree-apply-label
                   pilish--tree-browser-tree node-id label)
                  pilish--tree-browser-tree))
        (pilish--tree-browser-rerender)
        (if label
            (message "Pi: Label set to %s" label)
          (message "Pi: Label cleared")))))))

;;;; Tree Browser Fetch and Render

(defun pilish--tree-browser-fetch-and-render ()
  "Fetch tree and re-render the tree browser.
The tree is read from the linked chat's session file on disk, so no
live pi process is required.  The callback reports (TREE LEAF-ID
MESSAGE): a non-nil MESSAGE renders as an error state with a zero
visible count.  On success, `pilish--tree-browser-loaded-file'
records the file resolved before the deferred read, so a chat session
switch mid-read leaves the label and navigation guards comparing
against the tree actually displayed; it is nil on error states.

The point anchor is captured before the loading-state render — that
render destroys the node sections, so without carrying the anchor
across the cycle the final render would find nothing under point to
restore (see `pilish--browse-rerender-preserving-point').
A refresh issued while another fetch is still loading finds no
sections to capture and reuses the in-flight cycle's anchor (see
`pilish--tree-browser-fetch-anchor').

The loading state is painted EXPLICITLY: the deferred read is a
single `(run-at-time 0 ...)' hop, and Emacs runs due 0-timers before
redisplaying, so without the forced `redisplay' here the loading
render would never become visible (the chunked session scan yields
to redisplay between its slices; one timer hop never does)."
  (let* ((buf (current-buffer))
         (loaded (pilish--tree-browser-chat-session-file))
         (anchor (or (pilish--browse-capture-point-anchor)
                     ;; Mid-flight refresh: the loading render already
                     ;; destroyed the sections under point, so carry
                     ;; the anchor the in-flight cycle captured.
                     (and pilish--tree-browser-loading
                          pilish--tree-browser-fetch-anchor))))
    (setq pilish--tree-browser-loading t
          pilish--tree-browser-fetch-anchor anchor)
    ;; Loading-state render: default point behavior (nothing to keep).
    (pilish--tree-browser-rerender)
    ;; Paint it before scheduling the read — see docstring.
    (redisplay)
    (pilish--browse-load-tree
     (lambda (tree leaf-id message)
       (when (buffer-live-p buf)
         ;; The load calls back from a timer in whatever buffer is
         ;; current; render in the browser buffer, not that one.
         (with-current-buffer buf
           (setq pilish--tree-browser-loading nil
                 pilish--tree-browser-fetch-anchor nil
                 pilish--tree-browser-error message
                 pilish--tree-browser-tree tree
                 pilish--tree-browser-leaf-id leaf-id
                 pilish--tree-browser-loaded-file
                 (and (not message) loaded))
           (pilish--tree-browser-rerender anchor)))))))

(defun pilish--tree-browser-rerender (&optional fallback)
  "Re-render the tree browser from local state, preserving point.
FALLBACK is a pre-fetch `(IDENT . OFFSET)' anchor handed to
`pilish--browse-rerender-preserving-point' for the fetch
cycle's final render."
  (pilish--browse-rerender-preserving-point
   (current-buffer) #'pilish--tree-browser-render fallback))

;;;; Tree Browser Refresh Integration

(defun pilish-browse-refresh ()
  "Refresh the current browse buffer from disk."
  (interactive)
  (cond
   ((derived-mode-p 'pilish-session-browser-mode)
    (pilish--session-browser-fetch-and-render))
   ((derived-mode-p 'pilish-tree-browser-mode)
    (pilish--tree-browser-fetch-and-render))
   (t (message "Pi: Not in a browse buffer"))))

;;;; Entry Points

;;;###autoload
(defun pilish-session-browser ()
  "Open the session browser for the current project."
  (interactive)
  (let* ((dir (pilish--session-directory))
         (new-p (not (get-buffer
                      (pilish--session-browser-buffer-name dir))))
         (buf (pilish--get-or-create-session-browser dir)))
    ;; Link to the chat session.  Only the chat buffer is cached here;
    ;; `pilish--get-process' resolves the process live.
    (when-let* ((chat-buf (pilish--get-chat-buffer)))
      (when (buffer-live-p chat-buf)
        (with-current-buffer buf
          (setq pilish--chat-buffer chat-buf))))
    (pop-to-buffer buf)
    (pilish--browse-apply-margins)
    (pilish--session-browser-fetch-and-render)
    (when new-p
      (message "Pi: Press ? for available commands"))))

;;;###autoload
(defun pilish-tree-browser ()
  "Open the tree browser for the current session.
Guard first: the tree browser reads the linked chat's session file
from disk, so without a live chat session there is nothing to browse
— signal `user-error' \"No pi session to browse\" BEFORE creating any
browser buffer (a buffer with no link would only render the link
error forever)."
  (interactive)
  (let ((chat-buf (pilish--get-chat-buffer)))
    (unless (and chat-buf (buffer-live-p chat-buf))
      (user-error "No pi session to browse")))
  (let* ((dir (pilish--session-directory))
         (new-p (not (get-buffer
                      (pilish--tree-browser-buffer-name dir))))
         (buf (pilish--get-or-create-tree-browser dir)))
    ;; Link to the chat session.  Only the chat buffer is cached here;
    ;; the session file is resolved live from its state on every fetch.
    (when-let* ((chat-buf (pilish--get-chat-buffer)))
      (when (buffer-live-p chat-buf)
        (with-current-buffer buf
          (setq pilish--chat-buffer chat-buf))))
    (pop-to-buffer buf)
    (pilish--browse-apply-margins)
    (pilish--tree-browser-fetch-and-render)
    (when new-p
      (message "Pi: Press ? for available commands"))))

(provide 'pilish-browse)
;;; pilish-browse.el ends here
