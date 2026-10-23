;;; pilish-snapshot.el --- Independent saved conversations -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel Nouri

;; Author: Daniel Nouri <daniel.nouri@gmail.com>
;; Maintainer: Daniel Nouri <daniel.nouri@gmail.com>
;; URL: https://github.com/dnouri/pilish
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A snapshot buffer owns one observer record holding its captured target
;; and the digest of its last successful read.  The g command rereads the
;; same target: an unchanged digest keeps the buffer and its folds exactly,
;; while changed content renders into a hidden replacement that is published
;; into the old observer's windows only after a full successful build.

;;; Code:

(require 'cl-lib)
(require 'pilish-jsonl)
(require 'pilish-render)

(declare-function pilish--maybe-load-evil-integration "pilish")

(cl-defstruct (pilish--snapshot-observer
               (:constructor pilish--make-snapshot-observer))
  "One snapshot buffer's refresh state.
TARGET is the original captured conversation reference and DIGEST the last
successful read's identity.  Both are fixed for the buffer's lifetime: a
changed refresh publishes a replacement buffer with a fresh record instead
of mutating this one.  REFRESHING-P is a reentrancy guard, always reset by
unwind-protect."
  (target nil :read-only t)
  (digest nil :read-only t)
  refreshing-p)

(defvar-local pilish--snapshot-observer nil
  "This snapshot buffer's observer refresh record, or nil.")

(defun pilish-snapshot-quit ()
  "Close only the current saved snapshot and its window."
  (interactive)
  (unless (derived-mode-p 'pilish-snapshot-mode)
    (user-error "This buffer is not a saved snapshot"))
  (quit-window t))

(defun pilish--snapshot-build-buffer (target saved &optional name display-width)
  "Build a hidden snapshot buffer for TARGET from the validated SAVED.
NAME overrides the default human-facing buffer name.  DISPLAY-WIDTH hints
width-sensitive rendering while the buffer is hidden.  Return the buffer;
on failure or quit, kill it and re-signal."
  (let ((buffer (generate-new-buffer
                 (or name (format "*pilish-snapshot:%s*"
                                  (pilish--snapshot-target-session-id target)))))
        built)
    (unwind-protect
        (progn
          (when (fboundp 'pilish--maybe-load-evil-integration)
            (pilish--maybe-load-evil-integration))
          (with-current-buffer buffer
            (pilish-snapshot-mode)
            (pilish--set-snapshot-source-file (pilish-jsonl-snapshot-file saved))
            (setq default-directory (pilish-jsonl-snapshot-cwd saved))
            (pilish--replay-history buffer (pilish-jsonl-snapshot-messages saved)
                                    "Pi session, read-only.\n" display-width)
            (setq pilish--snapshot-observer
                  (pilish--make-snapshot-observer
                   :target target
                   :digest (pilish-jsonl-snapshot-digest saved)))
            (goto-char (point-min))
            (set-buffer-modified-p nil))
          (setq built t)
          buffer)
      (unless built (kill-buffer buffer)))))

(defun pilish--snapshot-retarget-quit-restore (window from to)
  "Point WINDOW's quit-restore parameter at TO when it referred to FROM.
This keeps `quit-window''s window-deletion and previously-shown-buffer
behavior attached to the buffer the window actually shows."
  (let ((quit-restore (window-parameter window 'quit-restore)))
    (when (and (consp quit-restore) (eq (nth 3 quit-restore) from))
      (setf (nth 3 quit-restore) to))))

(defun pilish--snapshot-publish-replacement (old staged views)
  "Replace OLD with STAGED in every window showing OLD, then retire OLD.
VIEWS holds per-window state captured from OLD.  Rename both buffers so the
replacement keeps the human-facing name, and retarget each window's
quit-restore parameter at STAGED so quitting later keeps its original
behavior.  On any failure before every window is switched, restore OLD's
windows and name, kill STAGED, and re-signal.  After the switch, OLD is
killed; a failure there is only a diagnostic because a partly cleaned-up
buffer must never be resurrected.  Return STAGED."
  (let ((inhibit-quit t)
        (old-name (buffer-name old))
        (switched nil)
        (committed nil))
    (unwind-protect
        (progn
          (with-current-buffer old
            (rename-buffer (generate-new-buffer-name " *pilish-snapshot-retired*")))
          (with-current-buffer staged
            (rename-buffer old-name))
          (dolist (view views)
            (let ((window (plist-get view :window)))
              (when (window-live-p window)
                (set-window-buffer window staged t)
                (pilish--snapshot-retarget-quit-restore window old staged)
                (push window switched))))
          (setq committed t))
      (unless committed
        (dolist (window switched)
          (when (window-live-p window)
            (set-window-buffer window old t)
            (pilish--snapshot-retarget-quit-restore window staged old)))
        (when (buffer-live-p staged)
          (kill-buffer staged))
        (when (buffer-live-p old)
          (with-current-buffer old
            (rename-buffer old-name)))))
    (condition-case err
        (kill-buffer old)
      (error (message "Pi: snapshot refresh could not retire the old buffer: %s"
                      (error-message-string err))))
    (dolist (view views)
      (setf (plist-get view :thinking-block) nil
            (plist-get view :live-thinking-start) nil))
    (condition-case err
        (pilish--restore-window-rewrite-states staged views)
      (error (message "Pi: snapshot refresh could not restore the view: %s"
                      (error-message-string err))))
    staged))

(defun pilish-snapshot-refresh ()
  "Reread this observer's captured saved conversation from disk.
Revalidate the captured file association and exact saved identity, then
compare a digest of the validated read against this observer's last
successful read.  An unchanged read returns the same buffer without
replaying, keeping folds, links and the exact view, and clears any refresh
failure note.  A changed read renders a hidden replacement and publishes it
into this observer's windows only after a full successful build, keeping the
buffer name, approximate logical position or tail intent, and default folds.
Any read, render or publication failure and any interrupt keeps the current
usable buffer, discards the unpublished replacement, and leaves a stale note
in the header until a later refresh succeeds.  Return the published buffer;
a changed refresh can return a replacement, so callers should reacquire the
buffer from the return value."
  (interactive)
  (unless (derived-mode-p 'pilish-snapshot-mode)
    (user-error "This buffer is not a saved snapshot"))
  (unless pilish--snapshot-observer
    (user-error "This snapshot has no refresh identity"))
  (let ((old (current-buffer))
        (observer pilish--snapshot-observer))
    (when (pilish--snapshot-observer-refreshing-p observer)
      (user-error "This snapshot is already refreshing"))
    (let ((views (pilish--capture-window-rewrite-states))
          (width (pilish--chat-display-width)))
      (setf (pilish--snapshot-observer-refreshing-p observer) t)
      (unwind-protect
          (condition-case err
              (let ((saved (pilish-jsonl-read-snapshot
                            (pilish--snapshot-observer-target observer))))
                (if (equal (pilish-jsonl-snapshot-digest saved)
                           (pilish--snapshot-observer-digest observer))
                    (progn
                      (pilish--set-snapshot-refresh-note nil)
                      (message "Saved conversation unchanged")
                      old)
                  (let ((staged (pilish--snapshot-build-buffer
                                 (pilish--snapshot-observer-target observer)
                                 saved "*pilish-snapshot refresh*" width))
                        published)
                    (unwind-protect
                        (prog1
                            (setq published
                                  (pilish--snapshot-publish-replacement
                                   old staged views))
                          (message "Saved conversation updated"))
                      (unless published
                        (when (buffer-live-p staged)
                          (kill-buffer staged)))))))
            (quit
             (when (buffer-live-p old)
               (with-current-buffer old
                 (pilish--set-snapshot-refresh-note "Refresh failed: interrupted")))
             (signal 'quit nil))
            (error
             (when (buffer-live-p old)
               (with-current-buffer old
                 (pilish--set-snapshot-refresh-note
                  (concat "Refresh failed: " (error-message-string err)))))
             (signal (car err) (cdr err))))
        (setf (pilish--snapshot-observer-refreshing-p observer) nil)))))

(defun pilish--snapshot-revert-buffer (_ignore-auto _noconfirm)
  "Refresh this snapshot observer for `revert-buffer'."
  (pilish-snapshot-refresh))

;;;###autoload
(defun pilish-open-subagent-snapshot (&optional target)
  "Read TARGET once and open its saved conversation in another window.
With no TARGET, use the owned name at point.  Each activation creates a new,
read-only, non-file-visiting observer.  No polling, RPC or resume occurs.
The observer can later reread its captured target with
`pilish-snapshot-refresh' (g)."
  (interactive)
  (let* ((target (or target (get-text-property (point) 'pilish-subagent-name)))
         (saved (if (stringp target)
                    (user-error "Saved snapshot unavailable: %s" target)
                  (pilish-jsonl-read-snapshot target)))
         (buffer (pilish--snapshot-build-buffer target saved))
         published)
    (unwind-protect
        (let ((window (display-buffer
                       buffer '((display-buffer-pop-up-window)
                                (inhibit-same-window . t)))))
          (unless (window-live-p window)
            (user-error "Cannot display saved snapshot in another window"))
          (select-window window)
          (setq published t)
          buffer)
      (unless published (kill-buffer buffer)))))

(provide 'pilish-snapshot)
;;; pilish-snapshot.el ends here
