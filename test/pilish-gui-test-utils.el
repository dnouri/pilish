;;; pilish-gui-test-utils.el --- Utilities for Pilish GUI tests -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Shared utilities for deterministic GUI tests.
;;
;; Usage:
;;   (require 'pilish-gui-test-utils)
;;   (pilish-gui-test-with-fresh-session
;;     (:backend fake :fake-scenario "prompt-lifecycle")
;;     (pilish-gui-test-send "Hello")
;;     (should (pilish-gui-test-chat-contains "Fake reply for: Hello")))
;;
;; Session-entry helpers require a literal plist as the first form, including
;; an explicit `:backend'.  Once a session is active, inner helper calls may
;; reuse its options.
;; New GUI regressions should prefer fresh fake-backed sessions unless a shared
;; session is deliberately needed and justified.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'pilish)
(require 'pilish-test-common)
(require 'seq)

;; Disable "Buffer has running process" prompts in tests
(remove-hook 'kill-buffer-query-functions #'process-kill-buffer-query-function)

;;;; Configuration

(defvar pilish-gui-test-model '(:provider "ollama" :modelId "qwen3:1.7b")
  "Frontend model state pushed at GUI-session startup on every backend.")

(defconst pilish-gui-test-default-fake-scenario "prompt-lifecycle"
  "Default fake-pi scenario when a fake backend is chosen explicitly.")

;;;; Session State

(defvar pilish-gui-test--session nil
  "Current test session plist with :chat-buffer, :input-buffer, :process.")

(defvar pilish-gui-test--failure-snapshot nil
  "Diagnostics captured before the fresh-session teardown.
The fresh-session macro fills this while the session still exists, so
the runner can show chat buffer and process state for failures whose
session is otherwise unwound away before diagnostics run.")

(defun pilish-gui-test--capture-failure-snapshot ()
  "Record session diagnostics before the fresh-session teardown."
  (setq pilish-gui-test--failure-snapshot nil)
  (when-let ((session pilish-gui-test--session))
    (let ((chat-buf (plist-get session :chat-buffer))
          (proc (plist-get session :process))
          (parts nil))
      (when (buffer-live-p chat-buf)
        (with-current-buffer chat-buf
          (push (format "status: %S" pilish--status) parts)
          (push (concat "--- chat buffer ---\n"
                        (buffer-substring-no-properties (point-min) (point-max))
                        "--- end chat buffer ---")
                parts)))
      (when (and proc (process-live-p proc))
        (push (format "process: %s exit=%s events=%s last=%S"
                      (process-status proc)
                      (process-exit-status proc)
                      (or (process-get proc 'pilish-gui-test-event-count) 0)
                      (process-get proc 'pilish-gui-test-last-event))
              parts))
      (setq pilish-gui-test--failure-snapshot
            (and parts (mapconcat #'identity (nreverse parts) "\n"))))))

(defun pilish-gui-test-session-active-p ()
  "Return t if a test session is active and healthy."
  (and pilish-gui-test--session
       (buffer-live-p (plist-get pilish-gui-test--session :chat-buffer))
       (process-live-p (plist-get pilish-gui-test--session :process))))

;;;; Session Management

(defun pilish-gui-test--normalize-backend (backend)
  "Return BACKEND normalized to either `real' or `fake'."
  (pcase backend
    ('real 'real)
    ('fake 'fake)
    (_ (error "GUI test sessions require explicit :backend, got: %S" backend))))

(defun pilish-gui-test--backend-spec (backend &optional fake-scenario fake-extra-args)
  "Return backend plist for BACKEND.
FAKE-SCENARIO and FAKE-EXTRA-ARGS apply only to the fake backend."
  (pilish-test-backend-spec
   (pilish-gui-test--normalize-backend backend)
   pilish-gui-test-default-fake-scenario
   fake-scenario
   fake-extra-args))

(defun pilish-gui-test--normalize-session-options (options)
  "Return normalized GUI session OPTIONS plist.
OPTIONS must include an explicit `:backend'.  Fake sessions may omit
`:fake-scenario', which defaults to
`pilish-gui-test-default-fake-scenario'."
  (let ((backend (pilish-gui-test--normalize-backend
                  (plist-get options :backend))))
    (list :backend backend
          :fake-scenario (or (plist-get options :fake-scenario)
                             pilish-gui-test-default-fake-scenario)
          :fake-extra-args (plist-get options :fake-extra-args))))

(defun pilish-gui-test--current-session-options ()
  "Return the current session options.
Signal an error when no session is active, so test entry points must declare
an explicit backend instead of relying on a hidden default."
  (if (pilish-gui-test-session-active-p)
      (plist-get pilish-gui-test--session :options)
    (error "No active GUI test session; pass explicit options with :backend")))

(defun pilish-gui-test--session-matches-p (options)
  "Return non-nil when current session already matches OPTIONS."
  (and (pilish-gui-test-session-active-p)
       (equal (plist-get (plist-get pilish-gui-test--session :options) :backend)
              (plist-get options :backend))
       (equal (plist-get (plist-get pilish-gui-test--session :options) :fake-scenario)
              (plist-get options :fake-scenario))
       (equal (plist-get (plist-get pilish-gui-test--session :options) :fake-extra-args)
              (plist-get options :fake-extra-args))))

(defun pilish-gui-test--instrument-display-handler (proc)
  "Wrap PROC display handler with GUI-test event counters."
  (unless (process-get proc 'pilish-gui-test-instrumented)
    (let ((handler (process-get proc 'pilish-display-handler)))
      (process-put proc 'pilish-gui-test-event-count 0)
      (process-put proc 'pilish-gui-test-last-event nil)
      (process-put proc 'pilish-gui-test-instrumented t)
      (process-put
       proc 'pilish-display-handler
       (lambda (event)
         (process-put proc 'pilish-gui-test-event-count
                      (1+ (or (process-get proc 'pilish-gui-test-event-count) 0)))
         (process-put proc 'pilish-gui-test-last-event event)
         (when handler
           (funcall handler event)))))))

(defun pilish-gui-test-start-session (&optional dir options)
  "Start a new pi session in DIR with OPTIONS.
DIR defaults to /tmp.  OPTIONS must include an explicit `:backend' and may
also set `:fake-scenario' and `:fake-extra-args'.  Returns the session
plist."
  (let* ((options (pilish-gui-test--normalize-session-options options))
         (backend (pilish-gui-test--backend-spec
                   (plist-get options :backend)
                   (plist-get options :fake-scenario)
                   (plist-get options :fake-extra-args)))
         (default-directory (or dir "/tmp/"))
         (pilish-executable (plist-get backend :executable))
         (pilish-extra-args (plist-get backend :extra-args)))
    (delete-other-windows)
    (pilish)
    (let* ((chat-buffer-name (format "*pilish-chat:%s*" default-directory)))
      (should
       (pilish-test-wait-until
        (lambda ()
          (let* ((chat-buf (get-buffer chat-buffer-name))
                 (input-buf (and chat-buf
                                 (with-current-buffer chat-buf
                                   pilish--input-buffer)))
                 (proc (and chat-buf
                            (with-current-buffer chat-buf
                              pilish--process))))
            (and (buffer-live-p chat-buf)
                 (buffer-live-p input-buf)
                 (process-live-p proc))))
        pilish-test-gui-timeout
        pilish-test-poll-interval))
      (let* ((chat-buf (get-buffer chat-buffer-name))
             (input-buf (and chat-buf
                             (with-current-buffer chat-buf
                               pilish--input-buffer)))
             (proc (and chat-buf
                        (with-current-buffer chat-buf
                          pilish--process))))
        (when (and chat-buf proc)
          (pilish-gui-test--instrument-display-handler proc)
          ;; Keep GUI sessions on the normal frontend initialization path.
          (with-current-buffer chat-buf
            (pilish--rpc-sync
             proc
             `(:type "set_model"
               :provider ,(plist-get pilish-gui-test-model :provider)
               :modelId ,(plist-get pilish-gui-test-model :modelId)))
            (pilish--rpc-sync proc '(:type "set_thinking_level" :level "off")))
          (setq pilish-gui-test--session
                (list :chat-buffer chat-buf
                      :input-buffer input-buf
                      :process proc
                      :directory default-directory
                      :options options
                      :backend backend)))))))

(defun pilish-gui-test-end-session ()
  "End the current test session."
  (when pilish-gui-test--session
    (let ((chat-buf (plist-get pilish-gui-test--session :chat-buffer))
          (pilish-quit-without-confirmation t))
      (when (buffer-live-p chat-buf)
        (kill-buffer chat-buf)))
    (setq pilish-gui-test--session nil)))

(defun pilish-gui-test-ensure-session (&optional options)
  "Ensure a test session matching OPTIONS is active.
When OPTIONS is nil, preserve the current session options if one is active.
Otherwise signal an error so the test entry point must declare an explicit
backend.  Also ensures proper window layout."
  (let ((options (if options
                     (pilish-gui-test--normalize-session-options options)
                   (pilish-gui-test--current-session-options))))
    (unless (pilish-gui-test--session-matches-p options)
      (pilish-gui-test-end-session)
      (pilish-gui-test-start-session nil options))
    (pilish-gui-test-ensure-layout)))

(defun pilish-gui-test-ensure-layout ()
  "Ensure chat window is visible with proper layout."
  (when pilish-gui-test--session
    (let ((chat-buf (plist-get pilish-gui-test--session :chat-buffer))
          (input-buf (plist-get pilish-gui-test--session :input-buffer)))
      (unless (get-buffer-window chat-buf)
        (delete-other-windows)
        (switch-to-buffer chat-buf)
        (when input-buf
          (let ((input-win (split-window nil -10 'below)))
            (set-window-buffer input-win input-buf)))))))

(defun pilish-gui-test--macro-session-forms (macro-name forms)
  "Return (OPTIONS . BODY) from FORMS for MACRO-NAME.
Signal an error unless FORMS starts with a literal plist containing
an explicit `:backend'."
  (let ((options (car forms)))
    (unless (and (listp options)
                 (keywordp (car options))
                 (plist-member options :backend))
      (error "%s requires an explicit session options plist with :backend"
             macro-name))
    (cons options (cdr forms))))

;;;; Macros for Test Structure

(defmacro pilish-gui-test-with-session (&rest forms)
  "Execute FORMS with an active pi session.
FORMS must start with a literal session options plist containing an explicit
`:backend'."
  (declare (indent 0) (debug t))
  (pcase-let* ((`(,options . ,body)
                (pilish-gui-test--macro-session-forms
                 'pilish-gui-test-with-session forms)))
    `(progn
       (pilish-gui-test-ensure-session ',options)
       (ert-info ((format "backend: %s"
                          (plist-get (plist-get pilish-gui-test--session :backend)
                                     :label)))
         ,@body))))

(defmacro pilish-gui-test-with-fresh-session (&rest forms)
  "Execute FORMS with a fresh pi session.
FORMS must start with a literal session options plist containing an explicit
`:backend'."
  (declare (indent 0) (debug t))
  (pcase-let* ((`(,options . ,body)
                (pilish-gui-test--macro-session-forms
                 'pilish-gui-test-with-fresh-session forms)))
    `(progn
       (setq pilish-gui-test--failure-snapshot nil)
       (pilish-gui-test-end-session)
       (pilish-gui-test-start-session nil ',options)
       (unwind-protect
           (ert-info ((format "backend: %s"
                              (plist-get (plist-get pilish-gui-test--session :backend)
                                         :label)))
             (progn ,@body))
         (pilish-gui-test--capture-failure-snapshot)
         (pilish-gui-test-end-session)))))

;;;; Waiting

(defun pilish-gui-test-idle-p ()
  "Return t when the chat buffer's `pilish--status' is `idle'."
  (when-let ((chat-buf (plist-get pilish-gui-test--session :chat-buffer)))
    (with-current-buffer chat-buf
      (eq pilish--status 'idle))))

(defun pilish-gui-test-wait-for-idle (&optional timeout)
  "Wait until the session returns to `idle', up to TIMEOUT seconds.

Waits on `pilish--status' rather than the absence of `streaming': a
just-sent prompt sits in `sending' until the backend starts the run,
so treating anything non-streaming as idle returns before the turn
begins.  Deliberately does not use `pilish--session-busy-p', which
also covers model changes and session transitions that would keep
tests hanging for reasons unrelated to turn activity."
  (let ((timeout (or timeout pilish-test-gui-timeout))
        (proc (plist-get pilish-gui-test--session :process)))
    (let ((done (pilish-test-wait-until
                 (lambda () (pilish-gui-test-idle-p))
                 timeout
                 pilish-test-poll-interval
                 proc)))
      (when done
        (redisplay))
      done)))

(defun pilish-gui-test-wait-for-chat-settled (&optional timeout)
  "Wait until the chat buffer stops changing.
Returns non-nil if the buffer is stable before TIMEOUT."
  (let* ((timeout (or timeout pilish-test-rpc-timeout))
         (proc (plist-get pilish-gui-test--session :process))
         (chat-buf (plist-get pilish-gui-test--session :chat-buffer)))
    (when (buffer-live-p chat-buf)
      (let ((last-tick (with-current-buffer chat-buf
                         (buffer-chars-modified-tick))))
        (pilish-test-wait-until
         (lambda ()
           (let ((tick (with-current-buffer chat-buf
                         (buffer-chars-modified-tick))))
             (if (= tick last-tick)
                 t
               (setq last-tick tick)
               nil)))
         timeout
         pilish-test-poll-interval
         proc)))))

;;;; Sending Messages

(defun pilish-gui-test-send (text &optional no-wait)
  "Send TEXT to pi and wait for the turn to settle unless NO-WAIT is t.

Waiting on real idle state keeps this helper from returning while the
prompt is still being submitted; a return before the turn starts can
queue the next prompt as a follow-up and race the assertions.
`pilish-gui-test-wait-for-chat-settled' then guards the final render
and delta flush."
  (pilish-gui-test-ensure-session)
  (let ((input-buf (plist-get pilish-gui-test--session :input-buffer)))
    (when input-buf
      (with-current-buffer input-buf
        (erase-buffer)
        (insert text)
        (pilish-send)))
    (unless no-wait
      (should (pilish-gui-test-wait-for-idle))
      (should (pilish-gui-test-wait-for-chat-settled))
      (redisplay))))

;;;; Window & Scroll Utilities

(defun pilish-gui-test-chat-window ()
  "Get the chat window."
  (when-let ((buf (plist-get pilish-gui-test--session :chat-buffer)))
    (get-buffer-window buf)))

(defun pilish-gui-test-input-window ()
  "Get the input window."
  (when-let ((buf (plist-get pilish-gui-test--session :input-buffer)))
    (get-buffer-window buf)))

(defun pilish-gui-test-top-line-number ()
  "Get the line number at the top of the chat window.
This is stricter than window-start for detecting scroll drift."
  (when-let ((win (pilish-gui-test-chat-window))
             (buf (plist-get pilish-gui-test--session :chat-buffer)))
    (with-current-buffer buf
      (save-excursion
        (goto-char (window-start win))
        (line-number-at-pos)))))

(defun pilish-gui-test-at-end-p ()
  "Return t if chat window is scrolled to end."
  (when-let ((win (pilish-gui-test-chat-window))
             (buf (plist-get pilish-gui-test--session :chat-buffer)))
    (with-current-buffer buf
      (>= (window-end win t) (1- (point-max))))))

(defun pilish-gui-test-window-point-at-end-p ()
  "Return t if chat window's point is at buffer end (following).
This checks window-point, not window-end.  Window-point being at end
is what determines if the window will auto-scroll during streaming."
  (when-let ((win (pilish-gui-test-chat-window))
             (buf (plist-get pilish-gui-test--session :chat-buffer)))
    (with-current-buffer buf
      (>= (window-point win) (1- (point-max))))))

(defun pilish-gui-test-scroll-up (lines)
  "Scroll chat window up LINES lines (away from end)."
  (when-let ((win (pilish-gui-test-chat-window))
             (buf (plist-get pilish-gui-test--session :chat-buffer)))
    (with-selected-window win
      (with-current-buffer buf
        (goto-char (point-max))
        (scroll-down lines)
        (redisplay)))))

;;;; Buffer Content Utilities

(defun pilish-gui-test-chat-content ()
  "Get chat buffer content as string."
  (when-let ((buf (plist-get pilish-gui-test--session :chat-buffer)))
    (with-current-buffer buf
      (buffer-substring-no-properties (point-min) (point-max)))))

(defun pilish-gui-test-chat-contains (text)
  "Return t if chat buffer contains TEXT."
  (when-let ((content (pilish-gui-test-chat-content)))
    (string-match-p (regexp-quote text) content)))

(defun pilish-gui-test-chat-text-in-tool-block-p (text)
  "Return t if TEXT appears inside a tool block overlay."
  (when-let ((buf (plist-get pilish-gui-test--session :chat-buffer)))
    (with-current-buffer buf
      (save-excursion
        (goto-char (point-min))
        (let ((found nil))
          (while (and (not found) (search-forward text nil t))
            (let ((pos (match-beginning 0)))
              (setq found
                    (seq-some (lambda (ov) (overlay-get ov 'pilish-tool-block))
                              (overlays-at pos)))))
          found)))))

(defun pilish-gui-test-chat-lines ()
  "Get number of lines in chat buffer."
  (when-let ((buf (plist-get pilish-gui-test--session :chat-buffer)))
    (with-current-buffer buf
      (count-lines (point-min) (point-max)))))

;;;; Layout Verification

(defun pilish-gui-test-verify-layout ()
  "Verify window layout: chat on top, input on bottom.
Signals error if layout is wrong."
  (let ((chat-win (pilish-gui-test-chat-window))
        (input-win (pilish-gui-test-input-window)))
    (unless chat-win (error "Chat window not found"))
    (unless input-win (error "Input window not found"))
    (let ((chat-top (nth 1 (window-edges chat-win)))
          (input-top (nth 1 (window-edges input-win))))
      (unless (< chat-top input-top)
        (error "Layout wrong: chat-top=%s input-top=%s" chat-top input-top)))
    t))

;;;; Content Generation

(defun pilish-gui-test-ensure-scrollable ()
  "Ensure chat has enough content to test scrolling.
Inserts dummy content directly for speed, without backend traffic."
  (pilish-gui-test-ensure-session)
  (let* ((win (pilish-gui-test-chat-window))
         (buf (plist-get pilish-gui-test--session :chat-buffer))
         (win-height (and win (window-body-height win)))
         (target-lines (and win-height (* 3 win-height))))
    (when (and buf win target-lines
               (< (pilish-gui-test-chat-lines) target-lines))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          ;; Insert dummy content to make buffer scrollable
          (dotimes (i (- target-lines (pilish-gui-test-chat-lines)))
            (insert (format "Dummy line %d for scroll testing.\n" (1+ i))))
          (set-window-point win (point-max))))
      (redisplay))
    t))

(provide 'pilish-gui-test-utils)
;;; pilish-gui-test-utils.el ends here
