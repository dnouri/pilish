;;; pilish-snapshot.el --- Independent saved subagent conversations -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel Nouri

;; Author: Daniel Nouri <daniel.nouri@gmail.com>
;; Maintainer: Daniel Nouri <daniel.nouri@gmail.com>
;; URL: https://github.com/dnouri/pilish
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Read one manager-assigned saved child conversation.  Reuse transcript
;; drawing without acquiring any live session, process or input ownership.

;;; Code:

(require 'pilish-jsonl)
(require 'pilish-render)

(declare-function pilish--maybe-load-evil-integration "pilish")

(defun pilish-snapshot-quit ()
  "Close only the current saved snapshot and its window."
  (interactive)
  (unless (derived-mode-p 'pilish-snapshot-mode)
    (user-error "This buffer is not a saved snapshot"))
  (quit-window t))

;;;###autoload
(defun pilish-open-subagent-snapshot (&optional target)
  "Read TARGET once and open its saved conversation in another window.
With no TARGET, use the owned name at point.  Each activation creates a new,
read-only, non-file-visiting observer.  No polling, RPC or resume occurs."
  (interactive)
  (let* ((target (or target (get-text-property (point) 'pilish-subagent-name)))
         (saved (if (stringp target)
                    (user-error "Saved snapshot unavailable: %s" target)
                  (pilish-jsonl-read-subagent-snapshot target)))
         (buffer (generate-new-buffer
                  (format "*pilish-snapshot:%s*"
                          (pilish--snapshot-target-session-id target))))
         published)
    (unwind-protect
        (progn
          (when (fboundp 'pilish--maybe-load-evil-integration)
            (pilish--maybe-load-evil-integration))
          (with-current-buffer buffer
            (pilish-snapshot-mode)
            (pilish--set-snapshot-source-file (pilish-jsonl-snapshot-file saved))
            (setq default-directory (pilish-jsonl-snapshot-cwd saved))
            (pilish--replay-history buffer (pilish-jsonl-snapshot-messages saved)
                                    "Saved snapshot, not live.\n")
            (goto-char (point-min))
            (set-buffer-modified-p nil))
          (let ((window (display-buffer
                         buffer '((display-buffer-pop-up-window)
                                  (inhibit-same-window . t)))))
            (unless (window-live-p window)
              (user-error "Cannot display saved snapshot in another window"))
            (select-window window)
            (setq published t)
            buffer))
      (unless published (kill-buffer buffer)))))

(provide 'pilish-snapshot)
;;; pilish-snapshot.el ends here
