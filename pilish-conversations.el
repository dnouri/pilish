;;; pilish-conversations.el --- Saved conversation catalogs -*- lexical-binding: t; -*-

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

;; A tool result owns one catalog of declared saved conversations.  Session
;; identity is the routed root and exact session ID, not an invocation ID,
;; file, tool name, or label.  Occurrences describe invocation ancestry and
;; refer to canonical sessions; only the first displayed occurrence of each
;; session can open its save.  Conflicting associations disable every action
;; for the affected sessions without discarding unrelated siblings.
;;
;; Capture copies and validates v1 flat declarations and v2 occurrence trees
;; without filesystem access.  Each update is a whole replacement.  The
;; snapshot opener remains the only reader and revalidates the captured target.
;; Rendering derives one literal inline tree from the catalog.  Hidden syntax
;; guards protect producer labels from Markdown interpretation, independently
;; of output fences, previews, and folds.

;;; Code:

(require 'pilish-ui)
(require 'cl-lib)

(declare-function pilish-open-subagent-snapshot "pilish-snapshot" (&optional target))
(defvar pilish--tool-button-map)

(defvar pilish-saved-conversation-functions nil
  "Capture-only adapters for saved Pi v3 conversations.
Each function receives TOOL-NAME, CONTENT and DETAILS, and returns nil or
an object with :version 1 or 2, :root and :items, the same declaration as
`details.savedConversations'.  The first non-nil result wins.
Callbacks must use explicit saved associations, perform no I/O, and return
only data, never resolver callbacks or display offsets.  Captured targets
remain usable after hook removal and parent buffer death.
Explicit field presence takes precedence, even for null or malformed values.
Errors and malformed declarations produce inert unavailability metadata
without interrupting unrelated rendering.")

(defconst pilish--conversation-max-rows 1024
  "Maximum occurrence rows accepted in a saved declaration.")
(defconst pilish--conversation-max-string-bytes 4096
  "Maximum UTF-8 bytes accepted in each saved reference string.")

(cl-defstruct (pilish--conversation-catalog
               (:constructor pilish--make-conversation-catalog))
  "One result's copied session table and ordered occurrence forest.
V1 roots are flat legacy occurrences and make no completeness claim.
ERROR replaces the entire declaration when its container or graph is invalid."
  version coverage root sessions occurrences roots error)

(cl-defstruct (pilish--conversation-session
               (:constructor pilish--make-conversation-session))
  "One canonical chat, keyed by routed root and exact ID.
REASON makes TARGET inert even if another occurrence supplied a valid file."
  key id file target reason unavailable-reason primary)

(cl-defstruct (pilish--conversation-occurrence
               (:constructor pilish--make-conversation-occurrence))
  "One invocation row; labels and parent links never identify a chat."
  id parent-id kind label title stats session children)

(defun pilish--conversation-object-p (object)
  "Return non-nil for a nonempty JSON-style plist OBJECT."
  (and (consp object) (proper-list-p object) (cl-evenp (length object))
       (cl-loop for (key _value) on object by #'cddr always (keywordp key))))

(defun pilish--conversation-string-p (value)
  "Return non-nil for bounded, single-line reference VALUE."
  (and (stringp value)
       (<= (length value) pilish--conversation-max-string-bytes)
       (<= (string-bytes (encode-coding-string value 'utf-8))
           pilish--conversation-max-string-bytes)
       (pilish--saved-reference-string-p value)))

(defun pilish--conversation-relative-file-p (file)
  "Return non-nil for bounded, exact, root-relative FILE."
  (and (pilish--conversation-string-p file)
       (not (string-search "\\" file))
       (pilish--saved-reference-relative-file-p file)))

(defun pilish--conversation-save (save)
  "Validate SAVE without I/O, returning (FILE REASON STATUS).
STATUS is `unavailable' only for a valid explicit unavailable save."
  (cond
   ((not (pilish--conversation-object-p save))
    '(nil "Malformed saved conversation save"))
   ((and (equal (plist-get save :kind) "pi-v3")
         (pilish--conversation-relative-file-p (plist-get save :file))
         (member (plist-get save :readiness) '("planned" "checked")))
    (list (substring-no-properties (plist-get save :file)) nil))
   ((and (equal (plist-get save :kind) "unavailable")
         (pilish--conversation-string-p (plist-get save :reason)))
    (list nil (substring-no-properties (plist-get save :reason)) 'unavailable))
   (t '(nil "Malformed saved conversation save"))))

(defun pilish--conversation-walk (roots function)
  "Call FUNCTION for each row in ROOTS in display order, without recursion."
  (let ((pending (copy-sequence roots)))
    (while pending
      (let ((row (pop pending)))
        (funcall function row)
        (setq pending (append (pilish--conversation-occurrence-children row) pending))))))

(defun pilish--conversation-normalize (declaration)
  "Validate and copy DECLARATION into a result-local catalog, without I/O.
Invalid graphs reject the whole declaration.  Invalid row payloads and
association conflicts are inert, while valid siblings remain usable."
  (unless (and (pilish--conversation-object-p declaration)
               (memq (plist-get declaration :version) '(1 2))
               (pilish--conversation-string-p (plist-get declaration :root))
               (not (string-search "\\" (plist-get declaration :root)))
               (vectorp (plist-get declaration :items))
               (<= 1 (length (plist-get declaration :items)) pilish--conversation-max-rows))
    (user-error "Malformed or unsupported saved conversations declaration"))
  (let* ((version (plist-get declaration :version))
         (coverage (plist-get declaration :coverage))
         (anchor (or pilish--snapshot-source-file (plist-get pilish--state :session-file)))
         (root-target (pilish--snapshot-target-for-pi-v3
                       anchor "root" (plist-get declaration :root) "root.jsonl"))
         (root (and root-target (pilish--snapshot-target-root root-target)))
         (sessions (make-hash-table :test #'equal))
         (by-id (make-hash-table :test #'equal))
         (files (make-hash-table :test #'equal))
         rows roots)
    (unless root (user-error "Invalid saved conversation origin or root"))
    (when (and (= version 2) (not (member coverage '("observed" "complete" "partial"))))
      (user-error "Invalid saved conversation coverage"))
    (seq-map-indexed
     (lambda (item index)
       (unless (pilish--conversation-object-p item)
         (user-error "Malformed saved conversation item"))
       (let* ((legacy (= version 1))
              (id (if legacy (format "legacy:%d" index) (plist-get item :id)))
              (parent (unless legacy (plist-get item :parentId)))
              (kind (if legacy "unknown" (plist-get item :kind)))
              (session-id (plist-get item :sessionId))
              (title (unless legacy (plist-get item :title)))
              (stats (unless legacy (plist-get item :stats)))
              (label (if (plist-member item :label) (plist-get item :label) session-id))
              (save (if legacy
                        (if (pilish--conversation-relative-file-p (plist-get item :file))
                            (list (substring-no-properties (plist-get item :file)) nil)
                          '(nil "Invalid saved conversation path"))
                      (pilish--conversation-save (plist-get item :save))))
              (file (car save))
              (reason (unless (eq (nth 2 save) 'unavailable) (cadr save))))
         (unless (and (pilish--conversation-string-p id)
                      (or legacy (and (plist-member item :parentId)
                                      (or (memq parent '(nil :null))
                                          (pilish--conversation-string-p parent))))
                      (member kind '("start" "resume" "unknown"))
                      (not (gethash id by-id)))
           (user-error "Invalid or duplicate saved conversation occurrence"))
         (unless (pilish--conversation-string-p session-id)
           (setq session-id nil reason "Invalid saved conversation identity"))
         (unless (pilish--conversation-string-p label)
           (setq label (or session-id "unavailable") reason "Invalid saved conversation label"))
         (let* ((key (and session-id (cons root (substring-no-properties session-id))))
                (existing (and key (gethash key sessions)))
                (session (or existing (pilish--make-conversation-session
                                       :key key :id (and key (cdr key)))))
                (row (pilish--make-conversation-occurrence
                      :id (substring-no-properties id)
                      :parent-id (and (stringp parent) (substring-no-properties parent))
                      :kind (substring-no-properties kind) :label (substring-no-properties label)
                      :title (and (pilish--conversation-string-p title) (substring-no-properties title))
                      :stats (and (pilish--conversation-object-p stats)
                                  (integerp (plist-get stats :turns))
                                  (<= 0 (plist-get stats :turns) 1000000)
                                  (plist-member stats :contextPercent)
                                  (or (memq (plist-get stats :contextPercent) '(nil :null))
                                      (and (numberp (plist-get stats :contextPercent))
                                           (<= 0 (plist-get stats :contextPercent) 100)))
                                  (list :turns (plist-get stats :turns)
                                        :contextPercent (when (numberp (plist-get stats :contextPercent))
                                                          (plist-get stats :contextPercent))))
                      :session session)))
           (when key (puthash key session sessions))
           (cond
            ((and existing legacy)
             (setf (pilish--conversation-session-reason session) "Duplicate legacy saved session"))
            ((and file (pilish--conversation-session-file session)
                  (not (equal file (pilish--conversation-session-file session))))
             (setf (pilish--conversation-session-reason session) "Conflicting saved files for this chat")))
           ;; An unavailable occurrence can coexist with a later checked save.
           ;; Malformed data, unlike an explicit unavailable save, taints identity.
           (when reason (setf (pilish--conversation-session-reason session) reason))
           (when (eq (nth 2 save) 'unavailable)
             (setf (pilish--conversation-session-unavailable-reason session) (cadr save)))
           (when file
             (let ((other (gethash file files)))
               (when (and other (not (eq other session)))
                 (setf (pilish--conversation-session-reason other) "Saved file claimed by different chats"
                       (pilish--conversation-session-reason session) "Saved file claimed by different chats"))
               (puthash file session files))
             (unless (pilish--conversation-session-file session)
               (setf (pilish--conversation-session-file session) file
                     (pilish--conversation-session-target session)
                     (and session-id (pilish--snapshot-target-for-pi-v3 anchor session-id root file)))))
           (puthash id row by-id)
           (push row rows))))
     (plist-get declaration :items))
    (setq rows (nreverse rows))
    (dolist (row rows)
      (if-let* ((parent-id (pilish--conversation-occurrence-parent-id row)))
          (let ((parent (gethash parent-id by-id)))
            (unless parent (user-error "Dangling saved conversation parent"))
            (push row (pilish--conversation-occurrence-children parent)))
        (push row roots)))
    (setq roots (nreverse roots))
    (dolist (row rows)
      (setf (pilish--conversation-occurrence-children row)
            (nreverse (pilish--conversation-occurrence-children row))))
    (when (= version 2)
      (unless (= (length roots) 1) (user-error "Saved conversation tree needs one root"))
      (let ((count 0))
        (pilish--conversation-walk roots (lambda (_) (cl-incf count)))
        (unless (= count (length rows)) (user-error "Cyclic saved conversation ancestry"))))
    (pilish--conversation-walk
     roots (lambda (row)
             (let ((session (pilish--conversation-occurrence-session row)))
               (when (pilish--conversation-session-reason session)
                 (setf (pilish--conversation-session-target session) nil))
               (unless (pilish--conversation-session-primary session)
                 (setf (pilish--conversation-session-primary session) row)))))
    (pilish--make-conversation-catalog
     :version version :coverage (and (= version 2) (substring-no-properties coverage))
     :root root :sessions sessions :occurrences rows :roots roots)))

(defun pilish--conversation-capture (tool-name content details)
  "Capture TOOL-NAME's saved CONTENT and DETAILS as a catalog, without I/O.
Explicit savedConversations presence wins, including null or malformed data.
No declaration returns nil; invalid declarations and adapter errors return
an inert error catalog.  Nothing is inferred from tool names or output."
  (condition-case err
      (let* ((explicit (and (listp details) (plist-member details :savedConversations)))
             (declaration (if explicit (plist-get details :savedConversations)
                            (run-hook-with-args-until-success
                             'pilish-saved-conversation-functions tool-name content details))))
        (when (or explicit declaration) (pilish--conversation-normalize declaration)))
    (error (pilish--make-conversation-catalog :error (error-message-string err)))))

(defun pilish--subagent-button-action (button)
  "Open only BUTTON's copied saved subagent target."
  (pilish-open-subagent-snapshot (button-get button 'pilish-subagent-name)))

(defun pilish--subagent-label (text target-or-reason)
  "Return a plain copy of TEXT annotated with TARGET-OR-REASON."
  (setq text (propertize (substring-no-properties text) 'pilish-subagent-name target-or-reason))
  (pilish--restore-subagent-buttons 0 (length text) text)
  text)

(defun pilish--restore-subagent-buttons (start end &optional object)
  "Restore owned name behavior in START..END of OBJECT, or the current buffer."
  (let ((position start) (inhibit-read-only t))
    (with-silent-modifications
      (while (< position end)
        (let* ((value (get-text-property position 'pilish-subagent-name object))
               (next (next-single-property-change position 'pilish-subagent-name object end)))
          (cond
           ((pilish--snapshot-target-p value)
            (add-text-properties
             position next
             (list 'button t 'category 'default-button
                   'action #'pilish--subagent-button-action 'face 'link
                   'mouse-face 'highlight 'follow-link t
                   'keymap (if (boundp 'pilish--tool-button-map) pilish--tool-button-map button-map)
                   'help-echo "Open Pi session read-only in another window" 'rear-nonsticky t)
             object))
           ((stringp value) (put-text-property position next 'help-echo value object)))
          (setq position next))))))

(defun pilish--conversation-label-suffix (session sessions)
  "Return the shortest session-ID suffix that distinguishes SESSION in SESSIONS."
  (when-let* ((id (pilish--conversation-session-id session))
              (others (delq nil (mapcar (lambda (other)
                                          (unless (eq other session)
                                            (pilish--conversation-session-id other)))
                                        sessions))))
    (let ((width (min 4 (length id))) collision)
      (setq collision
            (lambda ()
              (cl-some (lambda (other)
                         (equal (substring id (max 0 (- (length id) width)))
                                (substring other (max 0 (- (length other) width)))))
                       others)))
      (while (and (< width (length id)) (funcall collision))
        (cl-incf width))
      (concat " #" (substring id (max 0 (- (length id) width)))))))

(defun pilish--conversation-tree (catalog)
  "Derive CATALOG's single literal body tree, or nil for no declaration.
Only a canonical session's first displayed occurrence can be actionable.
Later resumes remain visible but have no button or link face."
  (when catalog
    (let ((labels (make-hash-table :test #'equal)) lines)
      (dolist (row (pilish--conversation-catalog-occurrences catalog))
        (let ((label (pilish--conversation-occurrence-label row))
              (session (pilish--conversation-occurrence-session row)))
          (cl-pushnew session (gethash label labels) :test #'eq)))
      (if-let* ((reason (pilish--conversation-catalog-error catalog)))
          (setq lines (list (concat "Pi sessions · " (pilish--subagent-label "unavailable" reason))
                            (pilish--subagent-label "unavailable" reason)))
        (let* ((count (hash-table-count (pilish--conversation-catalog-sessions catalog)))
               (pending (mapcar (lambda (row) (list row "" ""))
                                (pilish--conversation-catalog-roots catalog))))
          (push (format "Pi sessions · %d %s%s" count (if (= count 1) "chat" "chats")
                        (if (equal (pilish--conversation-catalog-coverage catalog) "partial")
                            " · partial" "")) lines)
          (while pending
            (pcase-let* ((`(,row ,prefix ,branch) (pop pending))
                         (session (pilish--conversation-occurrence-session row))
                         (primary (eq row (pilish--conversation-session-primary session)))
                         (label (pilish--conversation-occurrence-label row))
                         (title (pilish--conversation-occurrence-title row))
                         (stats (pilish--conversation-occurrence-stats row))
                         (reason (pilish--conversation-session-reason session))
                         (target (and (not reason) (pilish--conversation-session-target session)))
                         (reason (or reason (and (not target)
                                                 (pilish--conversation-session-unavailable-reason session))))
                         (suffix (when (> (length (gethash label labels)) 1)
                                   (pilish--conversation-label-suffix session (gethash label labels)))))
              (let* ((headed (and title (not (string-empty-p title))))
                     (head (if headed title label))
                     (linked (if primary
                                 (pilish--subagent-label head (or target reason "No saved file association"))
                               head)))
                (push (concat prefix branch linked
                              (if headed (concat " (" label suffix ")") suffix)
                              (cond ((not primary)
                                     (if (equal (pilish--conversation-occurrence-kind row) "resume")
                                         " · resumed · same chat" " · same chat"))
                                    ((not target)
                                     (concat " · " (pilish--subagent-label "unavailable" (or reason "No saved file association")))))
                              (when stats
                                (concat (format " · %d turns" (plist-get stats :turns))
                                        (if (numberp (plist-get stats :contextPercent))
                                            (format " · %d%% ctx" (round (plist-get stats :contextPercent)))
                                          " · ? ctx")))) lines))
              (let* ((children (pilish--conversation-occurrence-children row))
                     (indent (concat prefix (cond ((equal branch "├─ ") "│  ")
                                                  ((equal branch "└─ ") "   ")
                                                  (t "")))))
                (setq pending
                      (append (cl-loop for child in children for tail on children
                                       collect (list child indent (if (cdr tail) "├─ " "└─ ")))
                              pending)))))
          (setq lines (nreverse lines))))
      (let* ((text (string-join lines "\n"))
             (position 0) (width 3))
        (while (string-match "~+" text position)
          (setq width (max width (1+ (- (match-end 0) (match-beginning 0))))
                position (match-end 0)))
        (let* ((fence (make-string width ?~))
               (guard (propertize (concat fence "\n") 'pilish-conversation-guard t 'display "")))
          (propertize (concat guard text "\n" guard)
                      'pilish-conversation-tree t 'pilish-no-fontify t))))))

(provide 'pilish-conversations)
;;; pilish-conversations.el ends here
