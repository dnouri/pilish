;;; pilish-core.el --- Core functionality for Pilish -*- lexical-binding: t; -*-

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

;; Core functionality for Pilish: JSON parsing, line buffering, RPC communication.
;; This module provides the low-level plumbing for communicating with the
;; pi coding agent via JSON-over-stdio.

;;; Code:

(require 'cl-lib)
(require 'json)

;;;; JSON Parsing

(defun pilish--parse-json-line (line)
  "Parse LINE as JSON, returning a plist.
Returns nil if LINE is not valid JSON."
  (condition-case nil
      (json-parse-string line :object-type 'plist)
    (json-error nil)))

;;;; Line Accumulation

(defun pilish--line-chunks-string (chunks)
  "Return CHUNKS, stored newest first, as one string."
  (if chunks
      (apply #'concat (nreverse (copy-sequence chunks)))
    ""))

(defun pilish--accumulate-line-chunks (chunks chunk)
  "Accumulate CHUNK into partial line CHUNKS.
CHUNKS stores fragments for an unfinished line newest first.  Return a cons
cell whose car is COMPLETE-LINES and cdr is REMAINDER-CHUNKS.  COMPLETE-LINES
are newline-terminated lines without newlines, and REMAINDER-CHUNKS is the
unfinished line state to keep for the next `process-filter' call.

The important property is that an unfinished long JSON line is kept as chunks
and materialized only when its newline arrives.  Large `get_messages' RPC
responses are one huge JSON line, so repeatedly concatenating the partial line
would otherwise become allocation-heavy and effectively quadratic."
  ;; Note: Empty strings are filtered here because they're not valid JSON.
  ;; This couples line splitting with JSON semantics, but keeps the API simple.
  (let ((lines nil)
        (start 0)
        newline)
    (while (setq newline (string-search "\n" chunk start))
      (let ((line (substring chunk start newline)))
        (when chunks
          (push line chunks)
          (setq line (pilish--line-chunks-string chunks)
                chunks nil))
        (unless (string-empty-p line)
          (push line lines)))
      (setq start (1+ newline)))
    (when (< start (length chunk))
      (push (substring chunk start) chunks))
    (cons (nreverse lines) chunks)))

(defun pilish--accumulate-lines (accumulated chunk)
  "Accumulate CHUNK into ACCUMULATED, extracting complete lines.
Returns a cons cell (COMPLETE-LINES . REMAINDER) where COMPLETE-LINES
is a list of complete newline-terminated lines (without the newlines)
and REMAINDER is any incomplete line fragment to save for next call.

This string API is kept for tests and small helpers.  The process filter uses
`pilish--accumulate-line-chunks' directly so very large partial lines
are not repeatedly copied."
  (let* ((accumulated (or accumulated ""))
         (chunks (unless (string-empty-p accumulated)
                   (list accumulated)))
         (result (pilish--accumulate-line-chunks chunks chunk)))
    (cons (car result)
          (pilish--line-chunks-string (cdr result)))))

;;;; JSON Encoding

(defun pilish--encode-command (command)
  "Encode COMMAND plist as a JSON line for sending to pi.
COMMAND must be a valid plist with string/number/list values.
Returns a JSON string terminated with a newline."
  (concat (json-encode command) "\n"))

;;;; Path Boundary Helpers

(defun pilish--path-string-contains-nul-p (path)
  "Return non-nil if PATH is a string containing a NUL byte."
  (and (stringp path)
       (cl-position ?\0 path :test #'=)))

(defun pilish--ensure-usable-path-string (path)
  "Signal `user-error' when PATH is a malformed file name string.
Non-string PATH values are ignored so callers can keep treating missing or
non-string path metadata as absent."
  (when (pilish--path-string-contains-nul-p path)
    (user-error "Path contains NUL byte"))
  path)

(defun pilish--syntactic-remote-prefix (path)
  "Return PATH's TRAMP-looking prefix, or nil.
This is a fallback for contexts that temporarily bind
`file-name-handler-alist' to nil; ordinary operation still delegates to
`file-remote-p'."
  (when (and (stringp path)
             (string-match "\\`\\(/[^/:]+:[^\n]*:\\)\\(?:/\\|~\\)" path))
    (match-string 1 path)))

(defun pilish--remote-prefix-from-handler (path)
  "Return PATH's full TRAMP prefix using `file-remote-p', or nil."
  (when-let* ((localname (and (stringp path)
                              (file-remote-p path 'localname))))
    (when (string-suffix-p localname path)
      (substring path 0 (- (length path) (length localname))))))

(defun pilish--remote-prefix (&optional anchor)
  "Return the full TRAMP remote prefix for ANCHOR, or nil.
When ANCHOR is nil, use `default-directory'.  This keeps multi-hop TRAMP
routes intact and falls back to a syntax check without requiring a remote
connection."
  (let ((anchor (or anchor default-directory)))
    (and (stringp anchor)
         (not (string-empty-p anchor))
         (or (pilish--remote-prefix-from-handler anchor)
             (pilish--syntactic-remote-prefix anchor)))))

(defun pilish--remote-home-path-p (path)
  "Return non-nil when PATH is tilde-prefixed."
  (and (stringp path)
       (> (length path) 0)
       (eq (aref path 0) ?~)))

(defun pilish--plain-remote-home-path-p (path)
  "Return non-nil when PATH is `~' or has the `~/' prefix."
  (and (stringp path)
       (or (equal path "~")
           (string-prefix-p "~/" path))))

(defun pilish--named-remote-home-path-p (path)
  "Return non-nil when PATH has a named-user home prefix such as `~root'."
  (and (pilish--remote-home-path-p path)
       (not (pilish--plain-remote-home-path-p path))))

(defun pilish--safe-shell-remote-home-path-p (path)
  "Return non-nil when PATH has a portable remote-shell home prefix.
Accept plain `~' and POSIX portable named-user forms such as `~root/path'.
Reject shell-significant and reserved expansion forms before an unquoted tilde
prefix can cross the shell-host path boundary."
  (and (stringp path)
       (string-match-p
        "\\`\\(?:~\\|~[[:alpha:]_][[:alnum:]_.-]*\\)\\(?:/\\|\\'\\)"
        path)))

(defun pilish--remote-prefix-for-path (path)
  "Return PATH's full TRAMP remote prefix, or nil."
  (and (stringp path)
       (not (string-empty-p path))
       (or (pilish--remote-prefix-from-handler path)
           (pilish--syntactic-remote-prefix path))))

(defun pilish--route-preserving-path-op-p (&rest paths)
  "Return non-nil when any of PATHS should bypass TRAMP handlers.
This predicate is for pure file-name string transforms only.  TRAMP's file
name handlers canonicalize multi-hop routes like `/ssh:bastion|sudo:host:' to
just the final hop for generic operations such as `expand-file-name'."
  (cl-some #'pilish--remote-prefix-for-path paths))

(defun pilish--route-preserving-expand-file-name (path &optional anchor)
  "Expand PATH against ANCHOR without collapsing TRAMP route text.
This helper only changes pure string normalization.  Callers must not use it to
wrap real file I/O or process creation.  When PATH or ANCHOR is remote-looking,
file-name handlers are disabled for the `expand-file-name' call so multi-hop
TRAMP prefixes remain byte-for-byte intact."
  (let* ((anchor (or anchor default-directory))
         (prefix (pilish--remote-prefix anchor)))
    (cond
     ((and prefix
           (pilish--remote-home-path-p path)
           (not (pilish--remote-prefix-for-path path)))
      (concat prefix path))
     ((pilish--route-preserving-path-op-p path anchor)
      (let ((file-name-handler-alist nil))
        (expand-file-name path anchor)))
     (t
      (expand-file-name path anchor)))))

(defun pilish--route-preserving-file-name-as-directory (path)
  "Return PATH as a directory without collapsing TRAMP route text.
This is a pure string helper; do not use it around real file I/O."
  (if (pilish--route-preserving-path-op-p path)
      (let ((file-name-handler-alist nil))
        (file-name-as-directory path))
    (file-name-as-directory path)))

(defun pilish--route-preserving-file-name-directory (path)
  "Return PATH's directory without collapsing TRAMP route text.
This is a pure string helper; do not use it around real file I/O."
  (if (pilish--route-preserving-path-op-p path)
      (let ((file-name-handler-alist nil))
        (file-name-directory path))
    (file-name-directory path)))

(defun pilish--route-preserving-abbreviate-file-name (path)
  "Abbreviate PATH for display without collapsing TRAMP route text.
This is a pure string helper; do not use it around real file I/O."
  (if (pilish--route-preserving-path-op-p path)
      (let ((file-name-handler-alist nil))
        (abbreviate-file-name path))
    (abbreviate-file-name path)))

(defun pilish--ensure-compatible-remote-path (path &optional anchor)
  "Signal `user-error' when remote PATH is incompatible with ANCHOR.
ANCHOR defaults to `default-directory'.  Remote PATH must use the same TRAMP
prefix as a remote ANCHOR, and is rejected when ANCHOR is local.  Malformed
file name strings are rejected before TRAMP prefix checks."
  (pilish--ensure-usable-path-string path)
  (let ((path-prefix (pilish--remote-prefix-for-path path))
        (anchor-prefix (pilish--remote-prefix anchor)))
    (when path-prefix
      (cond
       ((not anchor-prefix)
        (user-error "Remote path cannot be used with local session: %s" path))
       ((not (equal path-prefix anchor-prefix))
        (user-error "Remote path is not on this session host: %s" path))))))

(defun pilish--emacs-path (path &optional anchor)
  "Return inbound PATH as an Emacs-local file name.
PATH must be a nonempty string; otherwise return nil.  Already-remote PATHs
must match ANCHOR's TRAMP prefix, and are rejected when ANCHOR is local.  With
a remote ANCHOR (or remote `default-directory'), process-local absolute paths
like /x and home paths like ~/x are prefixed with that remote prefix.  Relative
paths are expanded under ANCHOR or `default-directory'.  Malformed file name
strings signal `user-error'."
  (pilish--ensure-usable-path-string path)
  (when (and (stringp path) (not (string-empty-p path)))
    (let ((prefix (pilish--remote-prefix anchor))
          (anchor (or anchor default-directory)))
      (cond
       ((pilish--remote-prefix-for-path path)
        (pilish--ensure-compatible-remote-path path anchor)
        path)
       ((and prefix (string-prefix-p "/" path))
        (concat prefix path))
       ((and prefix (pilish--remote-home-path-p path))
        (concat prefix path))
       (t
        (pilish--route-preserving-expand-file-name path anchor))))))

(defun pilish--emacs-directory (path &optional anchor)
  "Return inbound PATH as an Emacs directory name.
Optional ANCHOR is forwarded to `pilish--emacs-path'.  This adds a
trailing slash when PATH is usable."
  (when-let* ((emacs-path (pilish--emacs-path path anchor)))
    (pilish--route-preserving-file-name-as-directory emacs-path)))

(defun pilish--passive-emacs-path (path &optional anchor)
  "Return inbound backend PATH as an Emacs path, or nil when unsafe.
Optional ANCHOR is forwarded to `pilish--emacs-path'.  This is for
passive Pi-originated metadata only.  It intentionally keeps
`pilish--emacs-path' strict for explicit navigation, validation, and
outbound boundaries, while preventing malformed backend metadata from escaping
process filters or callbacks."
  (condition-case nil
      (pilish--emacs-path path anchor)
    (error nil)))

(defun pilish--local-name-for-process (path)
  "Return PATH without its TRAMP prefix, even when handlers are disabled."
  (if-let* ((prefix (pilish--remote-prefix-for-path path)))
      (substring path (length prefix))
    (file-local-name path)))

(defun pilish--shell-command-path (path &optional anchor)
  "Return unquoted PATH in the shell host's file-name namespace.
The shell host is selected by ANCHOR or `default-directory': local paths stay
local, while paths under a remote ANCHOR are for the remote shell started by
Emacs's `shell-command' file-name handler.  Relative paths become absolute,
matching TRAMP prefixes (including multi-hop routes) are removed, and remote
`~/' and `~USER/' forms remain unexpanded for that shell.  Local home paths are
expanded by Emacs.  Exactly one recognized Emacs file-name quote layer is
removed.  Explicit remote local names must then be absolute or home-rooted;
empty and relative forms are rejected rather than reinterpreted lexically.

This is deliberately separate from `pilish--process-local-path', whose
outbound JSON contract is specific to Pi RPC and rejects named remote homes.
This pure conversion neither checks file existence nor contacts a remote host.
Malformed or incompatible remote paths signal `user-error'."
  (when-let* ((emacs-path (pilish--emacs-path path anchor)))
    (let* ((remote-anchor (pilish--remote-prefix anchor))
           (localname (file-name-unquote
                       (pilish--local-name-for-process emacs-path))))
      (cond
       ((not remote-anchor)
        (if (file-name-absolute-p localname)
            localname
          (let ((file-name-handler-alist nil))
            (expand-file-name
             localname
             (file-name-unquote (or anchor default-directory))))))
       ((string-prefix-p "/" localname)
        localname)
       ((pilish--safe-shell-remote-home-path-p localname)
        localname)
       ((pilish--remote-home-path-p localname)
        (user-error "Unsafe shell home prefix in path: %S" localname))
       (t
        (user-error "Remote shell path is not absolute or home-rooted: %S"
                    localname))))))

(defun pilish--shell-quote-path (path &optional anchor)
  "Quote shell-local PATH exactly once for a shell under ANCHOR.
PATH should be the result of `pilish--shell-command-path'.  A remote
`~/' or portable `~USER/' prefix is left unquoted so the remote shell can
expand it; only the remaining path is POSIX-quoted.  Other remote paths use
POSIX quoting in full, while local paths use the platform's normal
`shell-quote-argument' behavior.  A terminal ampersand gets an adjacent empty
quoted fragment because `shell-command' otherwise treats it as an async marker
without parsing the shell escape.  Unsafe home prefixes and malformed paths
signal `user-error'."
  (pilish--ensure-usable-path-string path)
  (unless (and (stringp path) (not (string-empty-p path)))
    (user-error "Shell path is empty or not a string"))
  (let* ((remote-anchor (pilish--remote-prefix anchor))
         (quoted
          (if (and remote-anchor
                   (pilish--remote-home-path-p path))
              (if (string-match
                   "\\`\\(~\\|~[[:alpha:]_][[:alnum:]_.-]*\\)\\(?:/\\|\\'\\)"
                   path)
                  (let* ((prefix (match-string 1 path))
                         (prefix-end (match-end 1))
                         (slash-p (and (< prefix-end (length path))
                                       (eq (aref path prefix-end) ?/)))
                         (rest (and slash-p
                                    (substring path (1+ prefix-end)))))
                    (if slash-p
                        (concat prefix "/"
                                (if (string-empty-p rest)
                                    ""
                                  (shell-quote-argument rest t)))
                      prefix))
                (user-error "Unsafe shell home prefix in path: %S" path))
            (shell-quote-argument path (and remote-anchor t)))))
    ;; `shell-command' detects a final ampersand lexically, without honoring
    ;; shell escaping.  Concatenate an empty quoted fragment so a filename
    ;; ending in `&' remains one operand but cannot switch execution to async.
    (if (string-suffix-p "&" quoted)
        (concat quoted
                (shell-quote-argument "" (and remote-anchor t)))
      quoted)))

(defun pilish--process-local-path (path &optional anchor)
  "Return outbound PATH as the process-local path Pi should receive.
PATH must be a nonempty string; otherwise return nil.  Emacs/TRAMP paths are
converted only when they match remote ANCHOR; TRAMP paths are rejected for local
ANCHOR.  The paths `~' and `~/x' are preserved for remote sessions because only
Pi on that host can expand the remote account home.  Named-user homes such as
`~root/x' are rejected for remote sessions because Pi does not implement that
shell expansion.  Local sessions expand home, absolute, and relative paths
through Emacs before sending them over JSON.  Malformed file name strings signal
`user-error'."
  (pilish--ensure-compatible-remote-path path anchor)
  (when (and (stringp path) (not (string-empty-p path)))
    (let ((remote-anchor (pilish--remote-prefix anchor)))
      (cond
       ((and remote-anchor
             (pilish--plain-remote-home-path-p path)
             (not (pilish--remote-prefix-for-path path)))
        path)
       ((and remote-anchor
             (pilish--named-remote-home-path-p path)
             (not (pilish--remote-prefix-for-path path)))
        (user-error "Remote Pi paths only support ~ or ~/..., not named homes: %s"
                    path))
       (t
        (when-let* ((emacs-path (pilish--emacs-path path anchor)))
          (let ((localname (pilish--local-name-for-process emacs-path)))
            (when (and remote-anchor
                       (pilish--named-remote-home-path-p localname))
              (user-error "Remote Pi paths only support ~ or ~/..., not named homes: %s"
                          localname))
            localname)))))))

;;;; Request ID Management

(defvar pilish--request-id-counter 0
  "Counter for generating unique request IDs.")

(defun pilish--next-request-id ()
  "Generate the next unique request ID."
  (format "req_%d" (cl-incf pilish--request-id-counter)))

(defun pilish--get-pending-requests (process)
  "Get or create the pending requests hash table for PROCESS.
Each process has its own table stored as a process property."
  (or (process-get process 'pilish-pending-requests)
      (let ((table (make-hash-table :test 'equal)))
        (process-put process 'pilish-pending-requests table)
        table)))

(defun pilish--get-pending-command-types (process)
  "Get or create pending command type table for PROCESS.
Maps request IDs to command type strings."
  (or (process-get process 'pilish-pending-command-types)
      (let ((table (make-hash-table :test 'equal)))
        (process-put process 'pilish-pending-command-types table)
        table)))

(defun pilish--command-pending-p (process type)
  "Return non-nil when PROCESS has a correlated request of command TYPE."
  (when (processp process)
    (let ((pending (process-get process 'pilish-pending-command-types)))
      (and (hash-table-p pending)
           (cl-loop for command being the hash-values of pending
                    thereis (equal command type))))))

(defconst pilish--remote-ready-marker
  "__PILISH_RPC_READY_V1__"
  "Exact stdout line that marks a remote Pi process ready for stdin.")

(defun pilish--process-awaiting-ready-p (process)
  "Return non-nil when PROCESS must emit the ready marker before sends."
  (and (process-get process 'pilish-awaiting-ready-marker)
       (not (process-get process 'pilish-ready))))

(defun pilish--enqueue-outbound-string (process string)
  "Queue STRING to be sent to PROCESS when its ready marker arrives."
  (process-put process 'pilish-outbound-queue
               (append (process-get process 'pilish-outbound-queue)
                       (list string))))

(defun pilish--flush-outbound-queue (process)
  "Flush queued outbound strings to PROCESS in FIFO order."
  (let ((queue (process-get process 'pilish-outbound-queue)))
    (when queue
      (process-put process 'pilish-outbound-queue nil)
      (dolist (string queue)
        (process-send-string process string)))))

(defun pilish--mark-process-ready (process)
  "Mark PROCESS ready for stdin and flush queued outbound strings."
  (process-put process 'pilish-ready t)
  (process-put process 'pilish-awaiting-ready-marker nil)
  (pilish--flush-outbound-queue process))

(defun pilish--send-string (process string)
  "Send STRING to PROCESS, or queue it until a remote process is ready."
  (if (pilish--process-awaiting-ready-p process)
      (pilish--enqueue-outbound-string process string)
    (process-send-string process string)))

(defun pilish--rpc-async (process command callback)
  "Send COMMAND to pi PROCESS asynchronously.
COMMAND is a plist that will be augmented with a unique ID.
CALLBACK is called with the response plist when received.
Encoding or scheduling failures leave no pending request behind."
  (let* ((id (pilish--next-request-id))
         (full-command (plist-put (copy-sequence command) :id id))
         ;; Encode before registration so serialization failures cannot create
         ;; pending state that no response could ever resolve.
         (encoded-command (pilish--encode-command full-command))
         (pending (pilish--get-pending-requests process))
         (pending-types (pilish--get-pending-command-types process)))
    (condition-case err
        (progn
          (puthash id callback pending)
          (puthash id (plist-get command :type) pending-types)
          (pilish--send-string process encoded-command))
      ((error quit)
       (remhash id pending)
       (remhash id pending-types)
       (signal (car err) (cdr err))))))

(defun pilish--send-extension-ui-response (process response)
  "Send extension UI RESPONSE to pi PROCESS.
RESPONSE must include the original :id from the request, as pi uses
this to match responses to pending promises."
  (pilish--send-string process (pilish--encode-command response)))

(defun pilish--rpc-sync (process command &optional timeout)
  "Send COMMAND to pi PROCESS synchronously, returning the response.
Blocks until response is received or TIMEOUT seconds elapse.
TIMEOUT defaults to `pilish-rpc-timeout' (or 30 seconds).
Returns nil on timeout."
  (let ((response nil)
        (timeout (or timeout
                     (and (boundp 'pilish-rpc-timeout) pilish-rpc-timeout)
                     30))
        (start-time (float-time)))
    (pilish--rpc-async process command (lambda (r) (setq response r)))
    (while (and (null response)
                (< (- (float-time) start-time) timeout)
                (process-live-p process))
      (accept-process-output process 0.1))
    response))

;;;; Process Management

(defun pilish--process-filter (proc output)
  "Handle OUTPUT from pi PROC.
Accumulates output and dispatches complete JSON lines."
  (let* ((inhibit-redisplay t)
         (partial (process-get proc 'pilish-partial-output-chunks))
         (result (pilish--accumulate-line-chunks partial output))
         (lines (car result)))
    (process-put proc 'pilish-partial-output-chunks (cdr result))
    (dolist (line lines)
      (if (equal line pilish--remote-ready-marker)
          (pilish--mark-process-ready proc)
        (when-let* ((json (pilish--parse-json-line line)))
          (condition-case err
              (pilish--dispatch-response proc json)
            (error
             (message "pilish: error dispatching process response: %s"
                      (error-message-string err)))))))))

(defun pilish--process-sentinel (proc event)
  "Handle process state change EVENT for PROC."
  (unless (process-live-p proc)
    (pilish--handle-process-exit proc event)))

(defun pilish--dispatch-response (proc json)
  "Dispatch JSON response from PROC to callback or event handler.
Response routing order: explicit ID, id-less `:command' match, then
id-less sole pending request. Non-response JSON is treated as an event."
  (let ((type (plist-get json :type))
        (id (plist-get json :id)))
    (if (equal type "response")
        (let* ((pending (pilish--get-pending-requests proc))
               (pending-types (pilish--get-pending-command-types proc))
               (dispatch-response
                (lambda (request-id callback)
                  (remhash request-id pending)
                  (remhash request-id pending-types)
                  (funcall callback json))))
          (cond
           ((and id (gethash id pending))
            (funcall dispatch-response id (gethash id pending)))
           ((null id)
            (let ((matched-id nil)
                  (matched-callback nil)
                  (matched-count 0)
                  (command (plist-get json :command)))
              (when command
                (maphash (lambda (request-id command-type)
                           (when (equal command-type command)
                             (setq matched-count (1+ matched-count))
                             (when (= matched-count 1)
                               (setq matched-id request-id
                                     matched-callback (gethash request-id pending)))))
                         pending-types))
              (cond
               ((and (= matched-count 1) matched-callback)
                (funcall dispatch-response matched-id matched-callback))
               ((= (hash-table-count pending) 1)
                (let (only-id only-callback)
                  (maphash (lambda (request-id callback)
                             (setq only-id request-id
                                   only-callback callback))
                           pending)
                  (when only-callback
                    (funcall dispatch-response only-id only-callback)))))))))
      ;; Call only this process's handler, not all handlers
      (pilish--handle-event proc json))))

(defun pilish--handle-event (proc event)
  "Handle an EVENT from pi PROC.
Calls only the handler registered for this specific process."
  ;; Call only this process's handler
  (when-let* ((handler (process-get proc 'pilish-display-handler)))
    (funcall handler event)))

(defconst pilish--process-stderr-max-chars 4000
  "Maximum number of stderr characters to keep in process exit excerpts.")

(defun pilish--process-stderr-excerpt (proc)
  "Return a bounded stderr excerpt for PROC, or nil when stderr is empty."
  (when-let* ((stderr-buf (process-get proc 'pilish-stderr-buf))
              ((buffer-live-p stderr-buf)))
    (let ((text (string-trim-right
                 (with-current-buffer stderr-buf
                   (buffer-substring-no-properties (point-min) (point-max))))))
      (unless (string-empty-p text)
        (if (<= (length text) pilish--process-stderr-max-chars)
            text
          (let* ((head-chars (/ pilish--process-stderr-max-chars 2))
                 (tail-chars (- pilish--process-stderr-max-chars
                                head-chars)))
            (concat (substring text 0 head-chars)
                    "\n… [stderr truncated] …\n"
                    (substring text (- (length text) tail-chars)))))))))

(defun pilish--cleanup-process-stderr-buffer (proc)
  "Kill PROC's stderr buffer, if any, and clear its process property."
  (when-let* ((stderr-buf (process-get proc 'pilish-stderr-buf)))
    (process-put proc 'pilish-stderr-buf nil)
    (when (buffer-live-p stderr-buf)
      (when-let* ((stderr-proc (get-buffer-process stderr-buf)))
        (set-process-query-on-exit-flag stderr-proc nil)
        (delete-process stderr-proc))
      (kill-buffer stderr-buf))))

(defun pilish--handle-process-exit (proc event)
  "Clean up when pi process PROC exits with EVENT.
Calls pending request callbacks for this process with an error response
containing EVENT, then clears this process's pending request tables."
  (let* ((pending (process-get proc 'pilish-pending-requests))
         (pending-types (process-get proc 'pilish-pending-command-types))
         (stderr (pilish--process-stderr-excerpt proc))
         (exit-code (process-exit-status proc))
         (error-response
          (append (list :type "response"
                        :success :false
                        :processExit t
                        :error (format "Process exited: %s" (string-trim event))
                        :exitCode exit-code)
                  (when stderr
                    (list :stderr stderr)))))
    (unwind-protect
        (unwind-protect
            (progn
              (when pending
                (maphash (lambda (_id callback)
                           (funcall callback error-response))
                         pending)
                (clrhash pending))
              (when pending-types
                (clrhash pending-types)))
          (when-let* ((handler (process-get proc 'pilish-exit-handler)))
            (funcall handler error-response)))
      (pilish--cleanup-process-stderr-buffer proc))))

(defvar pilish-executable)  ; forward decl — core.el cannot require ui.el
(defvar pilish-project-trust-policy) ; forward decl — defined in ui.el

(defvar pilish-extra-args nil
  "Extra arguments to pass to the pi command.
A list of strings that will be appended to the base command before the
project trust flag selected by `pilish-project-trust-policy'.

Example: (setq pilish-extra-args \\='(\"-e\" \"/path/to/ext.ts\"))

This is useful for testing extensions or passing additional flags.")

(defun pilish--project-trust-args ()
  "Return Pi CLI arguments for `pilish-project-trust-policy'."
  (let ((policy (if (boundp 'pilish-project-trust-policy)
                    pilish-project-trust-policy
                  'approve)))
    (pcase policy
      ('approve '("--approve"))
      ('default nil)
      ('no-approve '("--no-approve"))
      (_ (error "Invalid pilish-project-trust-policy: %S" policy)))))

(defun pilish--pi-command ()
  "Return the argv used to start Pi in RPC mode."
  (append pilish-executable
          '("--mode" "rpc")
          pilish-extra-args
          (pilish--project-trust-args)))

(defun pilish--remote-start-command (command)
  "Return a remote shell wrapper COMMAND that emits the ready marker.
COMMAND is passed as `$0' and `$@' to preserve the original argv exactly."
  (append (list "sh" "-c"
                (format "printf '%%s\\n' %s; exec \"$0\" \"$@\""
                        (shell-quote-argument
                         pilish--remote-ready-marker)))
          command))

(defun pilish--start-process (directory)
  "Start pi RPC process in DIRECTORY.
Returns the process object."
  (let* ((default-directory directory)
         (remote-start-p (pilish--remote-prefix directory))
         (command (pilish--pi-command))
         (process-command (if remote-start-p
                              (pilish--remote-start-command command)
                            command))
         (stderr-buf (generate-new-buffer " *pilish-stderr*")))
    (condition-case err
        (let ((proc (make-process
                     :name "pi"
                     :command process-command
                     :connection-type 'pipe
                     :noquery t
                     :file-handler t
                     :stderr stderr-buf
                     :filter #'pilish--process-filter
                     :sentinel #'pilish--process-sentinel)))
          (when (and remote-start-p
                     (not (process-get proc 'pilish-ready)))
            (process-put proc 'pilish-awaiting-ready-marker t))
          (process-put proc 'pilish-stderr-buf stderr-buf)
          (when-let* ((stderr-proc (get-buffer-process stderr-buf)))
            (set-process-query-on-exit-flag stderr-proc nil))
          proc)
      (error
       (when (buffer-live-p stderr-buf)
         (kill-buffer stderr-buf))
       (signal (car err) (cdr err))))))

;;;; State Management

(defvar-local pilish--status 'idle
  "Current status of the pi session (buffer-local in chat buffer).
One of: `idle', `sending', `streaming', `compacting'.
This is the single source of truth for session activity state.

Runtime status transitions are driven by events from pi:
- `idle' or `sending' -> `streaming' on agent_start
- `streaming' -> `sending' on agent_end, awaiting session settlement
- `sending' -> `idle' on agent_settled, unless newer streaming or compaction
  has already been observed
- any status -> `compacting' on compaction_start
- `compacting' -> the surrounding `streaming' or `sending' work on
  compaction_end, including failure and extension cancellation
- standalone manual compaction -> `idle' on compaction_end

Local commands may mark a session busy before the first event arrives,
for example normal prompt submission and manual compaction during the
RPC pre-event window.")

(defvar-local pilish--pre-compaction-status nil
  "Status that was active before a compaction event sequence.
Restores the surrounding run or prompt preflight even when compaction fails
or an extension cancels it.  Standalone manual compaction has no active run.")

(defvar-local pilish--state nil
  "Current state of the pi session (buffer-local in chat buffer).
A plist with keys like :model, :thinking-level, :messages, etc.")

(defun pilish--json-false-p (value)
  "Return t if VALUE represents JSON false.
`json-parse-string' yields `:false', while older helpers and tests may still
use `:json-false'.  Treat both as falsey JSON sentinels."
  (memq value '(:false :json-false)))

(defun pilish--json-null-p (value)
  "Return t if VALUE represents JSON null.
`json-parse-string' decodes JSON null as the keyword :null."
  (eq value :null))

(defun pilish--normalize-boolean (value)
  "Convert JSON boolean VALUE to Elisp boolean.
JSON true (t) stays t, and either supported false sentinel becomes nil."
  (if (pilish--json-false-p value) nil value))

(defun pilish--normalize-string-or-null (value)
  "Return VALUE when it is a nonempty string, nil otherwise.
Whitespace-only strings are nonempty and remain unchanged.  Empty strings,
JSON null values, and other non-strings become nil."
  (and (stringp value)
       (not (string-empty-p value))
       value))

(defun pilish--compaction-result-from-event (event)
  "Return EVENT's successful compaction result, or nil when absent."
  (let ((result (plist-get event :result)))
    (unless (or (null result)
                (pilish--json-null-p result))
      result)))

(defun pilish--update-state-from-event (event)
  "Update status and state based on EVENT.
Handles agent lifecycle, message events, compaction, and error/retry events.
For agent_settled, return non-nil only when waiting work was released."
  (let ((type (plist-get event :type)))
    (pcase type
      ("agent_start"
       (setq pilish--status 'streaming)
       (plist-put pilish--state :is-retrying nil)
       (plist-put pilish--state :last-error nil))
      ("agent_end"
       (setq pilish--status 'sending)
       (plist-put pilish--state :is-retrying nil)
       (plist-put pilish--state :messages (plist-get event :messages)))
      ("agent_settled"
       ;; Pi awaits extension hooks before emitting this event.  A hook can
       ;; start B before A settles; do not release observably newer work.
       ;; If B has ALSO ended, A_settled and B_settled are indistinguishable:
       ;; the wire has no run identity, and get_state cannot resolve all such
       ;; cases because Pi clears its run flag before awaiting those hooks.
       (when (eq pilish--status 'sending)
         (setq pilish--status 'idle)))
      ("message_start"
       (plist-put pilish--state :current-message (plist-get event :message)))
      ("message_end"
       (plist-put pilish--state :current-message nil))
      ("tool_execution_start"
       (pilish--handle-tool-start event))
      ("tool_execution_update"
       (pilish--handle-tool-update event))
      ("tool_execution_end"
       (pilish--handle-tool-end event))
      ("compaction_start"
       (setq pilish--pre-compaction-status
             (if (equal (plist-get event :reason) "manual")
                 'idle
               (unless (eq pilish--status 'compacting)
                 pilish--status)))
       (setq pilish--status 'compacting))
      ("compaction_end"
       ;; Exhausted overflow recovery emits an end without a start.  It does
       ;; not release the surrounding sending owner (or newer streaming work).
       (when (eq pilish--status 'compacting)
         (setq pilish--status
               (if (memq pilish--pre-compaction-status '(sending streaming))
                   pilish--pre-compaction-status
                 'idle)))
       (setq pilish--pre-compaction-status nil))
      ("auto_retry_start"
       (setq pilish--status 'sending)
       (plist-put pilish--state :is-retrying t)
       (plist-put pilish--state :retry-attempt (plist-get event :attempt))
       (plist-put pilish--state :last-error (plist-get event :errorMessage)))
      ("auto_retry_end"
       (plist-put pilish--state :is-retrying nil)
       (unless (eq (plist-get event :success) t)
         (plist-put pilish--state :last-error (plist-get event :finalError))))
      ("extension_error"
       (plist-put pilish--state :last-error (plist-get event :error))))))

(defun pilish--ensure-active-tools ()
  "Ensure :active-tools hash table exists in state."
  (unless (plist-get pilish--state :active-tools)
    (setq pilish--state (plist-put pilish--state :active-tools
                                (make-hash-table :test 'equal))))
  (plist-get pilish--state :active-tools))

(defun pilish--handle-tool-start (event)
  "Handle tool_execution_start EVENT."
  (let ((tools (pilish--ensure-active-tools))
        (id (plist-get event :toolCallId))
        (name (plist-get event :toolName))
        (args (plist-get event :args)))
    (puthash id (list :name name :args args) tools)))

(defun pilish--handle-tool-update (event)
  "Handle tool_execution_update EVENT."
  (let* ((tools (plist-get pilish--state :active-tools))
         (id (plist-get event :toolCallId))
         (tool (and tools (gethash id tools))))
    (when tool
      (plist-put tool :partial-result (plist-get event :partialResult)))))

(defun pilish--handle-tool-end (event)
  "Handle tool_execution_end EVENT."
  (let* ((tools (plist-get pilish--state :active-tools))
         (id (plist-get event :toolCallId)))
    (when tools
      (remhash id tools))))

(defun pilish--merge-state-response-status (remote-status)
  "Merge REMOTE-STATUS without overwriting an owned busy phase.
A snapshot may initialize an idle session, but isStreaming also includes
post-run work and is not evidence of a newer agent_start.  Lifecycle
events and the explicit no-turn prompt probe own busy-phase transitions."
  (if (memq pilish--status '(sending streaming compacting))
      pilish--status
    remote-status))

(defun pilish--update-state-from-response (response)
  "Update state from a command RESPONSE.
Only processes successful responses for state-modifying commands."
  (when (eq (plist-get response :success) t)
    (let ((command (plist-get response :command))
          (data (plist-get response :data)))
      (pcase command
        ("set_model"
         (plist-put pilish--state :model data))
        ("cycle_model"
         (when data
           (plist-put pilish--state :model (plist-get data :model))
           (plist-put pilish--state :thinking-level (plist-get data :thinkingLevel))))
        ("cycle_thinking_level"
         (when data
           (plist-put pilish--state :thinking-level (plist-get data :level))))
        ("get_state"
         (let ((new-state (pilish--extract-state-from-response response)))
           (setq pilish--status
                 (pilish--merge-state-response-status
                  (plist-get new-state :status)))
           (setq pilish--state (plist-put new-state :status pilish--status))))))))

(defun pilish--extract-state-from-response (response &optional anchor)
  "Extract state plist from a get_state RESPONSE.
Converts camelCase keys to kebab-case, normalizes booleans, and converts
inbound sessionFile values to Emacs paths using ANCHOR or `default-directory'.
Returns plist with :status key for setting `pilish--status'."
  (when-let* ((data (plist-get response :data)))
    (let ((is-streaming (pilish--normalize-boolean (plist-get data :isStreaming)))
          (is-compacting (pilish--normalize-boolean (plist-get data :isCompacting)))
          (session-file (pilish--normalize-string-or-null
                         (plist-get data :sessionFile))))
      (list :status (cond (is-streaming 'streaming)
                          (is-compacting 'compacting)
                          (t 'idle))
            :model (plist-get data :model)
            :thinking-level (plist-get data :thinkingLevel)
            :session-id (plist-get data :sessionId)
            :session-file (pilish--passive-emacs-path session-file anchor)
            :message-count (plist-get data :messageCount)
            :pending-message-count (plist-get data :pendingMessageCount)))))

(provide 'pilish-core)
;;; pilish-core.el ends here
