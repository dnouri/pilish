;;; pilish-answer.el --- Show the final answer when a turn ends -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026 Daniel Nouri

;; Author: Daniel Nouri <daniel.nouri@gmail.com>
;; Maintainer: Daniel Nouri <daniel.nouri@gmail.com>
;; URL: https://github.com/dnouri/pilish

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; With `pilish-jump-to-answer', a turn that ends normally moves every
;; chat window following the output to the start of the final assistant
;; message, the answer after the last tool call, so a long answer is
;; read from its beginning instead of its end.
;;
;; Only windows following the output move; a window where the reader
;; scrolled elsewhere stays.  An answer that already fits below the
;; window's top, with the end visible, moves nothing.  Windows that are
;; not live when the turn ends, such as those of another tab, land when
;; they are displayed again, because Lisp cannot move the point saved in
;; a window configuration.
;;
;; A landed window whose point the reader left in place follows the
;; output again when the next turn starts.  `pilish--answer-windows'
;; records each landing so that a window revived later at a landing
;; position is still recognized as unmoved.

;;; Code:

(require 'pilish-ui)

(defcustom pilish-jump-to-answer nil
  "Whether a finished turn shows the start of its final answer.
When non-nil, a turn that ends without being stopped moves chat
windows following the output to the start of the last assistant
message, unless the whole answer is visible already.  Windows
displayed later, such as those of another tab, land when shown.
Setting it buffer-locally in a chat buffer, as
`pilish-toggle-jump-to-answer' does, affects only that session."
  :type 'boolean
  :group 'pilish)

(defvar-local pilish--answer-target nil
  "Marker at the start of the finished turn's final answer, or nil.
Non-nil from the end of a turn until the next turn starts.")

(defvar-local pilish--answer-windows nil
  "Alist of (WINDOW . MARKER) for windows landed on an answer.
MARKER is the landing position.  A window still at its MARKER when a
newer turn starts, or when it is displayed again, is unmoved.")

(defun pilish-toggle-jump-to-answer (&optional buffer)
  "Toggle `pilish-jump-to-answer' for the session of BUFFER.
BUFFER is a chat or input buffer and defaults to the current buffer.
The setting becomes buffer-local in the session's chat buffer."
  (interactive)
  (let ((chat (with-current-buffer (or buffer (current-buffer))
                (pilish--get-chat-buffer))))
    (unless (buffer-live-p chat)
      (user-error "Not in a Pilish session"))
    (with-current-buffer chat
      (setq-local pilish-jump-to-answer (not pilish-jump-to-answer))
      ;; Landed windows keep their records, so they still follow the
      ;; next turn; only a pending landing for hidden windows is dropped.
      (unless pilish-jump-to-answer
        (pilish--answer-forget-target))
      (message "Pilish: jump to answer %s"
               (if pilish-jump-to-answer "on" "off"))
      pilish-jump-to-answer)))

(defun pilish--answer-start ()
  "Return the start of the current final answer's first line, or nil.
Nil when the final assistant message has no visible text."
  (when-let* ((marker pilish--message-start-marker)
              (start (marker-position marker)))
    (save-excursion
      (goto-char start)
      (skip-chars-forward " \t\n")
      (unless (eobp)
        (line-beginning-position)))))

(defun pilish--answer-visible-p (window start)
  "Return non-nil when following WINDOW shows START with the tail.
The current buffer must be WINDOW's buffer."
  (let ((height (max 1 (window-body-height window))))
    (< (pilish--count-screen-lines-up-to start (point-max) height window)
       height)))

(defun pilish--answer-unmoved-p (window marker)
  "Return non-nil when WINDOW's point is still at landing MARKER."
  (eql (window-point window) (marker-position marker)))

(defun pilish--answer-update-window (window)
  "Bring WINDOW of the current chat buffer up to date with the answer state.
An unmoved landing on an earlier answer follows the output again; a
following window lands on `pilish--answer-target'.  Return nil."
  (let ((entry (assq window pilish--answer-windows))
        (target pilish--answer-target))
    (unless (and entry (eq (cdr entry) target))
      (when entry
        (when (pilish--answer-unmoved-p window (cdr entry))
          (set-window-point window (point-max)))
        (setq pilish--answer-windows (delq entry pilish--answer-windows))
        (unless (rassq (cdr entry) pilish--answer-windows)
          (set-marker (cdr entry) nil)))
      (when (and target
                 (pilish--window-following-p window)
                 (not (pilish--answer-visible-p window target)))
        (set-window-point window target)
        (set-window-start window target)
        (push (cons window target) pilish--answer-windows))))
  nil)

(defun pilish--answer-update-live-windows ()
  "Update every live window showing the current chat buffer."
  (dolist (window (get-buffer-window-list (current-buffer) nil t))
    (pilish--answer-update-window window)))

(defun pilish--answer-turn-end ()
  "Land following windows on the final answer of the turn that ended.
Do nothing when the turn was stopped, a queued follow-up starts the
next turn at once, or `pilish-jump-to-answer' is nil."
  (when (and pilish-jump-to-answer
             (not pilish--aborted)
             (not pilish--followup-queue))
    (when-let* ((start (pilish--answer-start)))
      (pilish--answer-forget-target)
      (setq pilish--answer-target (copy-marker start))
      (pilish--answer-update-live-windows))))

(defun pilish--answer-turn-start ()
  "Let unmoved landed windows follow the output of a new turn."
  (when (or pilish--answer-target pilish--answer-windows)
    (pilish--answer-forget-target)
    (pilish--answer-update-live-windows)))

(defun pilish--answer-forget-target ()
  "Clear `pilish--answer-target', keeping markers that windows record."
  (when pilish--answer-target
    (unless (rassq pilish--answer-target pilish--answer-windows)
      (set-marker pilish--answer-target nil))
    (setq pilish--answer-target nil)))

(defun pilish--answer-window-buffer-change (window)
  "Update WINDOW, newly showing a chat buffer, with the answer state."
  (when (window-live-p window)
    (with-current-buffer (window-buffer window)
      (when (or pilish--answer-target pilish--answer-windows)
        (pilish--answer-update-window window)))))

(defun pilish--answer-setup ()
  "Track windows displaying the current chat buffer."
  (add-hook 'window-buffer-change-functions
            #'pilish--answer-window-buffer-change nil t))

(add-hook 'pilish-chat-mode-hook #'pilish--answer-setup)

(provide 'pilish-answer)
;;; pilish-answer.el ends here
