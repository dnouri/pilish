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
;; Version: 3.4.5
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
;;     C-c C-c        Send prompt (queues text as follow-up if busy;
;;                    steers instead with `pilish-send-while-busy')
;;     C-c C-s        Queue steering (interrupts after current tool; busy only)
;;     M-RET          Send prompt, or always queue as follow-up if busy
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
;;       C-c C-c  queues follow-up (delivered after agent completes),
;;                or steers when `pilish-send-while-busy' is `steer'
;;       C-c C-s  queues steering (interrupts after current tool)
;;       M-RET    queues follow-up whatever that option says
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

(require 'pilish-menu)
(require 'pilish-input)
(require 'pilish-browse)
(require 'pilish-snapshot)

(declare-function dired-get-filename "dired" (&optional localp no-error-if-not-filep))

;;;###autoload
(defun pilish-view-session-file (file)
  "Open Pi v3 session FILE in a new read-only saved observer and return it.
Like a saved-conversation link, select the observer in another window.
This never starts or resumes Pi and never changes any live session or
draft.  Each call creates an independent observer; \`g' rereads its captured
file identity.  Invalid or unreadable files signal an error before display.
A symlink whose target resolves outside FILE's own directory is refused.
Reads and rendering are synchronous, including for remote files."
  (interactive (list (pilish--read-session-file-name)))
  (let* ((file (pilish--route-preserving-expand-file-name file))
         (header (pilish-jsonl-read-session-header file))
         (target (pilish--snapshot-target-for-pi-v3
                  file (plist-get header :id)
                  (pilish--route-preserving-file-name-directory file)
                  (file-name-nondirectory file))))
    (unless target
      (user-error "Not a readable Pi session: %s" file))
    (pilish-open-subagent-snapshot target)))

;;;; Session Inspection

;; Buffer resolution and copying live in pilish-ui for extension-status hooks.

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
with the other session accessors.  DIRECTORY is expanded with a trailing
slash, not resolved through symlinks, matching Pilish's normal lookup."
  (and (pilish--find-session (pilish--normalize-directory directory) name)
       t))

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

(defun pilish--setup-session (dir &optional session)
  "Set up a new or existing session for DIR with optional SESSION name.
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
        (pilish--check-dependencies dir)
        (pilish--set-process (pilish--start-process dir))
        (setq new-session t)
        ;; Associate process events and ownership with this chat buffer.
        (when (processp pilish--process)
          (set-process-buffer pilish--process chat-buf)
          (process-put pilish--process 'pilish-chat-buffer chat-buf)
          ;; Register event handler
          (pilish--register-display-handler pilish--process)
          ;; Initialize state from server
          (let ((buf chat-buf)
                (proc pilish--process)
                (generation pilish--session-transition-generation))
            (pilish--rpc-async proc '(:type "get_state")
              (lambda (response)
                (if (eq (plist-get response :success) t)
                    (when (pilish--session-transition-current-p buf proc generation)
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
