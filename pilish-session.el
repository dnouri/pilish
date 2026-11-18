;;; pilish-session.el --- Public session API -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel Nouri

;; Author: Daniel Nouri <daniel.nouri@gmail.com>
;; Maintainer: Daniel Nouri <daniel.nouri@gmail.com>
;; URL: https://github.com/dnouri/pilish
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Public readers for integrations that inspect Pilish sessions without
;; reading `pilish--' state.  Each reader resolves a chat or input buffer
;; through `pilish-session-chat-buffer'.  Readers that return session data
;; return copies, so changing a result cannot change the session.  Readers
;; send no RPC, start no process and display no window.
;;
;; The hooks that report changes stay with the code that runs them:
;; `pilish-extension-status-functions' and
;; `pilish-session-identity-functions' in pilish-ui,
;; `pilish-process-event-functions' and `pilish-process-exit-functions'
;; in pilish-core.  `pilish--copy-session-value' lives in pilish-ui,
;; which also copies extension status hook arguments.

;;; Code:

(require 'pilish-ui)

;;;; Session Inspection

(defun pilish-session-chat-buffer (&optional buffer)
  "Return the session chat linked to BUFFER, or nil outside a session.
BUFFER is a buffer or buffer name, defaulting to the current buffer.
Dead, missing, unrelated and saved snapshot buffers return nil.  An input
buffer resolves to its live chat even when Pi has stopped.  No process is
started and no window is displayed or selected."
  (when-let* ((buffer (get-buffer (or buffer (current-buffer))))
              ((buffer-live-p buffer)))
    (with-current-buffer buffer
      (cond
       ((derived-mode-p 'pilish-chat-mode) buffer)
       ((and (derived-mode-p 'pilish-input-mode)
             (buffer-live-p pilish--chat-buffer)
             (with-current-buffer pilish--chat-buffer
               (derived-mode-p 'pilish-chat-mode)))
        pilish--chat-buffer)))))

(defun pilish--session-value (buffer variable &optional key)
  "Copy VARIABLE's value from BUFFER's chat, or nil without a chat.
When KEY is non-nil, copy that plist member instead of the whole value."
  (when-let* ((chat (pilish-session-chat-buffer buffer)))
    (let ((value (buffer-local-value variable chat)))
      (pilish--copy-session-value (if key (plist-get value key) value)))))

(defun pilish-session-input-buffer (&optional buffer)
  "Return the live input buffer owned by BUFFER's session, or nil.
BUFFER follows `pilish-session-chat-buffer'.  No input is created."
  (when-let* ((chat (pilish-session-chat-buffer buffer))
              (input (buffer-local-value 'pilish--input-buffer chat))
              ((buffer-live-p input)))
    (with-current-buffer input
      (and (derived-mode-p 'pilish-input-mode)
           (eq pilish--chat-buffer chat)
           input))))

(defun pilish-session-process (&optional buffer)
  "Return BUFFER's session process, or nil if none was assigned.
BUFFER follows `pilish-session-chat-buffer'.  The returned process may have
exited; use `process-live-p' to check it.  This does not start a process."
  (when-let* ((chat (pilish-session-chat-buffer buffer))
              (process (buffer-local-value 'pilish--process chat)))
    (and (processp process) process)))

(defun pilish-session-directory (&optional buffer)
  "Return a copy of BUFFER's session directory, or nil without a session.
BUFFER follows `pilish-session-chat-buffer'.  The directory stays tied to
the session even when its chat visits a Markdown transcript elsewhere."
  (when-let* ((chat (pilish-session-chat-buffer buffer)))
    (pilish--copy-session-value (pilish--chat-session-directory chat))))

(defun pilish-session-name (&optional buffer)
  "Return BUFFER's named-session suffix, or nil for the default session.
BUFFER follows `pilish-session-chat-buffer'.  This is the Emacs session
name, not Pi's conversation title; the returned string is a copy."
  (pilish--session-value buffer 'pilish--canonical-session-name))

(defun pilish-session-title (&optional buffer)
  "Return a copy of Pi's conversation title for BUFFER, or nil if unnamed.
BUFFER follows `pilish-session-chat-buffer'."
  (let ((title (pilish--session-value buffer 'pilish--session-name)))
    (and (stringp title) (not (string-empty-p title)) title)))

(defun pilish-session-file (&optional buffer)
  "Return a copy of BUFFER's last reported Pi session pathname, or nil.
BUFFER follows `pilish-session-chat-buffer'.  This is not the chat's
visited Markdown transcript file, and no disk or RPC lookup is made."
  (pilish--session-value buffer 'pilish--state :session-file))

(defun pilish-session-model (&optional buffer)
  "Return BUFFER's last reported model plist, or nil if unknown.
BUFFER follows `pilish-session-chat-buffer'.  The result (including nested
values) is a copy; typical keys include :id, :name and :provider."
  (pilish--session-value buffer 'pilish--state :model))

(defun pilish-session-context-usage (&optional buffer)
  "Return BUFFER's last reported context usage plist, or nil if unknown.
BUFFER follows `pilish-session-chat-buffer'.  The result is a copy, with
keys such as :percent, :tokens and :contextWindow.  No RPC is sent."
  (pilish--session-value buffer 'pilish--cached-stats :contextUsage))

(defun pilish-session-queued-prompts (&optional buffer)
  "Return a copy of BUFFER's known queued prompt texts, or nil if none.
BUFFER follows `pilish-session-chat-buffer'.  Order matches the header:
Pi's reported follow-ups, local follow-ups in FIFO order, then reported
steering.  Unreported Pi queues are not included."
  (when-let* ((chat (pilish-session-chat-buffer buffer)))
    (pilish--copy-session-value
     (apply #'append (pilish--queued-prompt-groups chat)))))

(defun pilish-session-running-tools (&optional buffer)
  "Return a copy of BUFFER's known unfinished root tool call IDs.
BUFFER follows `pilish-session-chat-buffer'.  Order is unspecified.
The live registry includes announced or executing calls with an observed
ID, not argument-streaming previews without authoritative IDs.  Completed,
cooled and saved-history blocks are excluded.  No RPC is sent; an
unobserved backend tool is unknown, not necessarily absent."
  (when-let* ((chat (pilish-session-chat-buffer buffer))
              (live (buffer-local-value 'pilish--live-tool-blocks chat)))
    (let (ids)
      (maphash (lambda (id _block)
                 (push (pilish--copy-session-value id) ids))
               live)
      ids)))

(defun pilish-session-busy-p (&optional buffer)
  "Return non-nil when BUFFER's session has active or known queued work.
BUFFER follows `pilish-session-chat-buffer'.  This observed-work policy
includes pending prompts, model/session changes, compaction, non-idle
activity, known queues and unfinished tools, not just streamed output.
It is broader than the send-readiness predicate.  No RPC or fresh Pi
query is made, and nothing is copied, so frequent polling is cheap."
  (when-let* ((chat (pilish-session-chat-buffer buffer)))
    (and (pilish--session-observed-work-p chat) t)))

;;;###autoload
(defun pilish-session-exists-p (directory &optional name)
  "Return non-nil when DIRECTORY's session NAME has a chat buffer.
NAME nil means the directory's default session.  Stopped sessions count;
no process is started.  The chat is found by its session identity, so a
chat renamed or visiting a transcript still counts; an input buffer
without a live chat does not.  Every session that exists can be inspected
with the other session accessors.  DIRECTORY matches the session's
directory through any symlink alias of it, as Pilish's own lookup does;
remote directories match as written."
  (and (pilish--find-session (pilish--normalize-directory directory) name)
       t))

(defun pilish-session-extension-status (&optional buffer key)
  "Return a copy of BUFFER's extension status, or nil without a session.
BUFFER follows `pilish-session-chat-buffer'.  With KEY, return that
status's text; without KEY, return an alist of (KEY . TEXT) in header-line
order.  Text properties, including faces, are retained; their nested data
values are copied too.  Changing returned data cannot change the session.
`pilish-extension-status-functions' reports changes.  No RPC is sent."
  (when-let* ((chat (pilish-session-chat-buffer buffer)))
    (let ((statuses (buffer-local-value 'pilish--extension-status chat)))
      (pilish--copy-session-value
       (if key (cdr (assoc key statuses)) statuses) t))))

(provide 'pilish-session)
;;; pilish-session.el ends here
