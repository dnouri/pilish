;;; pilish.el --- Emacs frontend for pi coding agent -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel Nouri

;; Author: Daniel Nouri <daniel.nouri@gmail.com>
;; Maintainer: Daniel Nouri <daniel.nouri@gmail.com>
;; Assisted-by: pi:kimi-k3
;; Assisted-by: pi:glm-5.3
;; Assisted-by: pi:gpt-5.6
;; Assisted-by: pi:claude-opus-4.6
;; URL: https://github.com/dnouri/pilish
;; Keywords: ai llm ai-pair-programming tools
;; Version: 3.4.2
;; Package-Requires: ((emacs "29.1") (transient "0.9.0") (magit-section "4.0.0") (md-ts-mode "0.5.0") (markdown-table-wrap "0.2.0"))

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

;; Emacs frontend for the pi coding agent (https://pi.dev).
;; Provides a two-window interface for AI-assisted coding: chat history
;; with rendered markdown, and a separate prompt composition buffer.
;;
;; Requirements:
;;   - Emacs 29.1 or later (tree-sitter support required)
;;   - pi coding agent @earendil-works/pi-coding-agent 1.1.0 or later,
;;     installed and in PATH on the host where Pi runs
;;   - tree-sitter grammars for markdown and markdown-inline
;;
;; Pilish uses `md-ts-mode` for its own chat and input buffers;
;; loading it does not change global Markdown file associations.
;;
;; Usage:
;;   M-x pilish                    Start or focus session in current project
;;   C-u M-x pilish                Start a named session
;;   M-x pilish-open-session-file  Open a JSONL session file as live session
;;   M-x pilish-toggle             Hide/show session windows in current frame
;;   M-x pilish-session-browser    Browse sessions (filter, switch)
;;   M-x pilish-tree-browser       Browse conversation tree (navigate, label)
;;
;; Many users define an alias: (defalias 'pi 'pilish)
;;
;; Key Bindings:
;;   Input buffer:
;;     C-c C-c        Send prompt (queues text as follow-up if busy)
;;     C-c C-s        Queue steering (interrupts after current tool; busy only)
;;     C-c C-k        Abort current operation
;;     C-c C-p        Open menu
;;     C-c C-r        Browse sessions
;;     M-p / M-n      History navigation
;;     C-r            Incremental history search (like readline)
;;     TAB            Path/file completion
;;     @              File reference (search project files)
;;
;;   Chat buffer:
;;     n / p          Navigate messages
;;     TAB            Toggle completed thinking/tool section or fold turn
;;     !              Run a Dired-inspired shell command on a strict file target
;;                    (command + dash-options appends it; otherwise use *)
;;     w              Copy the shell-local file path to the kill ring
;;     RET            Visit strict file target at point (tool content,
;;                    plain path, or local Markdown label)
;;     C-c C-p d      Describe a completed reply, thinking, or tool in Help
;;     C-h .          Show local help at point in the echo area
;;     C-c C-k        Abort current operation
;;     C-c C-n        New session
;;     C-c C-r        Browse sessions
;;     C-c C-e        Export HTML
;;     C-c C-c        Compact context
;;     C-c C-m        Select model
;;     C-c C-t        Cycle thinking level
;;     C-c C-y        Copy last message
;;     C-c C-p        Open menu
;;
;; In saved snapshots, run M-x pilish-describe-reply on a completed reply,
;; thinking, or tool block.  C-h . shows quick help in both transcripts,
;; with native link and control help first.  Reply, thinking, and tool
;; metadata does not appear on automatic hover.  Other hover behavior,
;; including native chat controls, session headers, browsers, and menus,
;; is unchanged.
;;
;; Editor Features:
;;   - File reference (@): Type @ to search project files (respects .gitignore)
;;   - Path completion (Tab): Complete relative paths, ../, ~/, etc.
;;   - Prompt image: Attach one content-sniffed raster image to a direct,
;;     idle, non-slash prompt; the session header shows its name and size.
;;   - Message queuing: Submit text messages while agent is working:
;;       C-c C-c  queues follow-up (delivered after agent completes)
;;       C-c C-s  queues steering (interrupts after current tool)
;;     Image-bearing drafts refuse these busy paths and remain intact.
;;
;; Press C-c C-p for the full transient menu with model selection,
;; thinking level, completed-thinking controls, session management,
;; and custom commands.  Its Session r entry opens the disk-backed
;; session browser, and Context w opens the conversation-tree browser;
;; press ? in either browser to discover switching/navigation, search,
;; filters, renaming, and labels.
;;
;; See README.org for more documentation.

;;; Code:

(require 'cl-lib)
(require 'pilish-menu)
(require 'pilish-input)
(require 'pilish-browse)
(require 'pilish-snapshot)

(declare-function dired-get-filename "dired" (&optional localp no-error-if-not-filep))

;;;; Main Entry Point

(defcustom pilish-evil-integration t
  "When non-nil, load Evil keybindings automatically when Evil is in use.
Loads `pilish-evil' when a session is set up while Evil is
present.  Set to nil before loading this package to opt out."
  :type 'boolean
  :group 'pilish)

(defun pilish--maybe-load-evil-integration ()
  "Load the optional Evil integration when Evil is in use.
Skips when `pilish-evil-integration' is nil or Evil has not
been loaded.  Called before session buffers are created so initial
Evil states apply to them."
  (when (and pilish-evil-integration (featurep 'evil))
    (require 'pilish-evil nil t)))

(defvar pilish-session-environment-functions nil
  "Functions that supply environment overrides for a session's Pi process.
Each function is called for interactive and background sessions with the
chat buffer and directory when the session starts its first process,
and returns an alist of \(NAME . VALUE) entries, where a nil VALUE
removes NAME.  Pilish keeps
the combined result for the session, so `pilish-reload' starts its new
process with the same environment.  Earlier entries win: environment
passed to `pilish-start-session' first, then functions in hook order.
A function that signals an error is reported as a warning and supplies
nothing.  The overrides apply only to that session's processes, never
to the global `process-environment'.")

(defun pilish--session-environment (chat-buf dir)
  "Return the environment `pilish-session-environment-functions' supply.
Each function receives CHAT-BUF and DIR."
  (apply #'append
         (mapcar (lambda (function)
                   (condition-case-unless-debug err
                       (funcall function chat-buf dir)
                     (error
                      (display-warning
                       'pilish
                       (format "Session environment function %S failed: %s"
                               function (error-message-string err))
                       :error)
                      nil)))
                 pilish-session-environment-functions)))

(defun pilish--setup-session (dir &optional session args environment background)
  "Set up a new or existing session for DIR with optional SESSION name.
The first process the session starts takes ARGS and ENVIRONMENT, then
`pilish-session-environment-functions'; the session keeps them for every
later process (see `pilish--start-process').  BACKGROUND means the
caller already checked dependencies, so nothing prompts the user.
Returns the chat buffer."
  (pilish--maybe-load-evil-integration)
  (let* ((chat-buf (pilish--get-or-create-buffer :chat dir session))
         (input-buf (pilish--get-or-create-buffer :input dir session))
         (new-session nil))
    ;; Link buffers to each other
    (with-current-buffer chat-buf
      (pilish--set-chat-session-identity dir session)
      (pilish--set-input-buffer input-buf)
      ;; Start process if not already running
      (unless (and pilish--process (process-live-p pilish--process))
        (unless background
          (pilish--check-dependencies dir))
        (unless pilish--launch-options
          (setq pilish--launch-options
                (list :args args
                      :environment
                      (append environment
                              (pilish--session-environment chat-buf dir)))))
        (pilish--set-process
         (pilish--start-process
          dir
          (plist-get pilish--launch-options :args)
          (plist-get pilish--launch-options :environment)))
        (setq new-session t)
        ;; Associate process events and ownership with this chat buffer.
        (when (processp pilish--process)
          (set-process-buffer pilish--process chat-buf)
          (process-put pilish--process 'pilish-chat-buffer chat-buf)
          ;; Register event handler
          (pilish--register-display-handler pilish--process)
          ;; Initialize state from server
          (let ((buf chat-buf)
                (proc pilish--process))  ; Capture for closures
            (pilish--rpc-async proc '(:type "get_state")
              (lambda (response)
                (if (eq (plist-get response :success) t)
                    (progn
                      (pilish--apply-state-response buf response)
                      ;; Check if no model available and warn user
                      (when (buffer-live-p buf)
                        (with-current-buffer buf
                          (unless (plist-get pilish--state :model)
                            (pilish--display-no-model-warning)))))
                  (when (buffer-live-p buf)
                    (with-current-buffer buf
                      (when (eq pilish--process proc)
                        (pilish--display-startup-error
                         (plist-get response :error)
                         (plist-get response :stderr)
                         (plist-get response :exitCode))
                        ;; Core invokes pending callbacks before the generic exit
                        ;; handler.  Remember this dead process was rendered so
                        ;; that handler does not append the same diagnostic again.
                        (when (and (plist-get response :processExit)
                                   (processp proc)
                                   (not (process-live-p proc)))
                          (process-put
                           proc 'pilish-exit-error-rendered t))))))))
            ;; Fetch commands via RPC (independent of get_state)
            (pilish--fetch-commands proc
              (lambda (commands)
                (when (buffer-live-p buf)
                  (with-current-buffer buf
                    (pilish--set-commands commands)
                    (pilish--rebuild-commands-menu))))
              dir))))
      ;; Display startup header for new sessions
      (when new-session
        (pilish--display-startup-header)))
    (with-current-buffer input-buf
      (setq default-directory dir)
      (pilish--set-chat-buffer chat-buf))
    chat-buf))

(defvar treesit-auto-install-grammar)  ; Emacs 31+

(defun pilish--check-background-dependencies (dir)
  "Signal an error unless a session can start in DIR without asking.
Unlike `pilish--check-dependencies', which offers to install what is
missing, this fails when the Pi executable or an essential tree-sitter
grammar is missing."
  (unless (pilish--check-pi dir)
    (error "Pilish: %s not found in the execution path of %s"
           (car pilish-executable) dir))
  (when-let* ((missing (pilish--missing-essential-grammars)))
    (error "Pilish: essential tree-sitter grammars missing: %s"
           (mapconcat #'symbol-name missing ", "))))

;;;###autoload
(cl-defun pilish-start-session
    (directory name &key session-file args environment)
  "Start a session in DIRECTORY without displaying it.
Return the session's chat buffer.  NAME names the session as
\\[universal-argument] \\[pilish] does; nil selects DIRECTORY's default
session.  Starting a session that already exists is an error.

SESSION-FILE resumes that saved Pi session and renders its history.  Its
recorded working directory must be DIRECTORY; a nil DIRECTORY means that
recorded directory.

ARGS is a list of extra Pi command-line arguments, placed after
`pilish-extra-args'.  ENVIRONMENT is an alist of (NAME . VALUE)
overrides, where a nil VALUE removes NAME; it takes precedence over
`pilish-session-environment-functions'.  Both apply only to this
session's processes, and `pilish-reload' keeps them.

Pilish neither prompts to install dependencies nor waits for Pi.
Returning a buffer does not mean Pi has answered the initial state
request or finished resuming;
this function provides no readiness callback.  A missing Pi executable
or essential tree-sitter grammar, an invalid name, directory or
SESSION-FILE is an error that leaves no session behind.  Pi's later
startup errors appear in the chat; a failed resume is reported in the
echo area, as for interactive sessions.  To show the session, run
\\[pilish] from its directory, with a prefix argument for a named session.

Remote directories use the existing TRAMP process launcher and path
rules.  TRAMP may prompt for authentication, and dependency checks and
file reads may block on remote access; non-displaying does not mean
all setup is asynchronous."
  (unless (or (null name)
              (and (stringp name) (not (string-empty-p name))))
    (error "Pilish: session name must be nil or a nonempty string: %S"
           name))
  (let* ((session-file (and session-file
                            (pilish--route-preserving-expand-file-name
                             session-file)))
         (recorded-dir (and session-file
                            (pilish--normalize-directory
                             (pilish--session-file-cwd-or-error
                              session-file))))
         (dir (cond (directory (pilish--normalize-directory directory))
                    (recorded-dir)
                    (t (error "Pilish: a session needs a directory")))))
    (unless (file-directory-p dir)
      (error "Pilish: not a directory: %s" dir))
    (when (and recorded-dir (not (equal recorded-dir dir)))
      (error "Pilish: session file %s belongs to %s, not %s"
             session-file recorded-dir dir))
    (when (or (pilish--find-session dir name)
              (get-buffer (pilish--buffer-name :input dir name)))
      (error "Pilish: session already exists: %s"
             (pilish--buffer-name :chat dir name)))
    (pilish--check-background-dependencies dir)
    (condition-case err
        ;; A frameless daemon has nobody to answer a grammar prompt.
        (let* ((treesit-auto-install-grammar 'never)
               (chat-buf (pilish--setup-session
                          dir name args environment t)))
          (when session-file
            (pilish--resume-selected-session
             (buffer-local-value 'pilish--process chat-buf)
             chat-buf session-file))
          chat-buf)
      (error
       (let ((pilish-quit-without-confirmation t))
         (dolist (buffer (list (pilish--find-session dir name)
                               (get-buffer
                                (pilish--buffer-name :input dir name))))
           (when (buffer-live-p buffer)
             (kill-buffer buffer))))
       (signal (car err) (cdr err))))))

(defun pilish--show-session-buffers (chat-buf input-buf)
  "Show CHAT-BUF and INPUT-BUF, focusing input when both are visible.
When `pilish-input-window-display' is `hidden', a freshly
displayed session starts with only the chat window visible."
  (if (and (get-buffer-window-list chat-buf nil)
           (get-buffer-window-list input-buf nil))
      (pilish--focus-input-window chat-buf input-buf)
    (pilish--display-buffers
     chat-buf input-buf
     (eq pilish-input-window-display 'hidden))))

(defun pilish--dired-regular-file-at-point ()
  "Return Dired's regular file at point, or nil."
  (when (derived-mode-p 'dired-mode)
    (when-let* ((file (dired-get-filename nil t)))
      (and (file-regular-p file)
           (pilish--route-preserving-expand-file-name file)))))

(defun pilish--regular-jsonl-file-p (file)
  "Return non-nil if FILE is a cheap local JSONL file candidate."
  (when (stringp file)
    (let ((path (expand-file-name file)))
      (and (string-suffix-p ".jsonl" path)
           (not (file-remote-p path))
           (ignore-errors
             (and (file-regular-p path)
                  (file-readable-p path)))))))

(defun pilish--visited-jsonl-file-prompt-default ()
  "Return the current buffer's visited JSONL file for the prompt, or nil."
  (when-let* ((file buffer-file-name)
              (path (expand-file-name file)))
    (and (pilish--regular-jsonl-file-p path)
         path)))

(defun pilish--session-file-prompt-default ()
  "Return an explicit default file for the session-file prompt, or nil."
  (if (derived-mode-p 'dired-mode)
      (pilish--dired-regular-file-at-point)
    (pilish--visited-jsonl-file-prompt-default)))

(defun pilish--read-session-file-name ()
  "Read an existing pi session file name from the minibuffer."
  (let* ((default-file (pilish--session-file-prompt-default))
         (default-dir (and default-file
                           (pilish--route-preserving-file-name-directory
                            default-file)))
         (initial (and default-file (file-name-nondirectory default-file)))
         ;; `read-file-name' otherwise uses the current buffer's visited file
         ;; as a hidden default when DEFAULT-FILENAME and INITIAL are nil.
         (buffer-file-name nil))
    (read-file-name "Pi session file: "
                    default-dir
                    default-file
                    t
                    initial)))

;;;###autoload
(defun pilish (&optional session)
  "Start or switch to pi coding agent session in current project.
With prefix arg, prompt for SESSION name to allow multiple sessions.
If already in a pi buffer and no SESSION specified, ensures this session
is visible. When both chat and input are already shown in the current
frame, keeps layout unchanged and focuses the input window."
  (interactive
   (list (when current-prefix-arg
           (read-string "Session name: "))))
  (let (chat-buf input-buf)
    (if (and (derived-mode-p 'pilish-chat-mode 'pilish-input-mode)
             (not session))
        ;; Already in pi buffer with no new session requested - use current session
        (setq chat-buf (pilish--get-chat-buffer)
              input-buf (pilish--get-input-buffer))
      ;; Find or create session for current directory
      (let ((dir (pilish--session-directory)))
        (setq chat-buf (pilish--setup-session dir session))
        (setq input-buf (buffer-local-value 'pilish--input-buffer chat-buf))))
    (pilish--show-session-buffers chat-buf input-buf)))

;;;###autoload
(defun pilish-open-session-file (session-file)
  "Open pi JSONL SESSION-FILE as a live session.
This uses the normal chat/input UI and switches pi to SESSION-FILE; it is not a
static viewer.  The session header must record a non-empty absolute cwd that
names an existing directory.  Interactively, prompt for an existing file.  In
Dired, default to the regular file at point; otherwise, default to the current
visited local regular readable .jsonl file when there is one."
  (interactive (list (pilish--read-session-file-name)))
  (let* ((session-file (pilish--route-preserving-expand-file-name
                        session-file))
         (dir (pilish--session-file-cwd-or-error session-file)))
    (pilish--check-dependencies dir)
    (let* ((chat-buf (pilish--setup-session dir))
           (input-buf (buffer-local-value 'pilish--input-buffer
                                          chat-buf))
           (proc (buffer-local-value 'pilish--process chat-buf)))
      (pilish--show-session-buffers chat-buf input-buf)
      (when (pilish--session-transition-ready-p chat-buf "open")
        (pilish--resume-selected-session proc chat-buf session-file))
      chat-buf)))

;;;###autoload
(defun pilish-toggle ()
  "Toggle pi coding agent window visibility for the current project.
If pi windows are visible in the current frame, hide them.
If hidden there but a session exists, show them.
If no session exists, signal an error."
  (interactive)
  (let* ((chat-buf (if (derived-mode-p 'pilish-chat-mode 'pilish-input-mode)
                       (pilish--get-chat-buffer)
                     (car (pilish-project-buffers))))
         (input-buf (and chat-buf
                         (buffer-local-value 'pilish--input-buffer chat-buf))))
    (cond
     ;; No session at all
     ((null chat-buf)
      (user-error "No pi session for this project"))
     ;; Session visible in current frame: hide it
     ((or (get-buffer-window-list chat-buf nil)
          (and input-buf (get-buffer-window-list input-buf nil)))
      (with-current-buffer chat-buf
        (pilish--hide-session-windows)))
     ;; Session hidden: show it (chat only when input is shown on demand)
     (t
      (pilish--display-buffers
       chat-buf input-buf
       (pilish--input-window-on-demand-p))))))

(provide 'pilish)
;;; pilish.el ends here
