;;; pilish-gui-tests.el --- GUI integration tests for Pilish -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; ERT tests that require a real Emacs GUI (windows, frames, scrolling).
;; Run with: make test-gui [SELECTOR=pattern]
;;
;; These tests focus on behavior that CANNOT be tested with unit tests:
;; - Real window scrolling during streamed updates in a displayed buffer
;; - Auto-scroll vs scroll-preservation with deterministic fake scenarios
;; - Tool-block overlays and extension UI behavior through the subprocess seam
;;
;; Many behaviors (history, spacing, and linked-buffer teardown) are covered
;; more directly by unit tests.
;;
;; For quick fake-backed debugging with a visible window:
;;   ./test/run-gui-tests.sh pilish-gui-test-scroll-auto-when-at-end

;;; Code:

(require 'ert)
(require 'pilish-gui-test-utils)
(require 'pilish-test-common)

(defun pilish-gui-test--table-display-strings (beg end)
  "Return ordered table overlay display strings between BEG and END."
  (when-let ((buf (plist-get pilish-gui-test--session :chat-buffer)))
    (with-current-buffer buf
      (mapcar (lambda (ov) (overlay-get ov 'display))
              (sort (seq-filter
                     (lambda (ov) (overlay-get ov 'pilish-table-display))
                     (overlays-in beg end))
                    (lambda (left right)
                      (< (overlay-start left) (overlay-start right))))))))

(defun pilish-gui-test--thinking-scroll-lines (prefix count)
  "Return COUNT newline-separated lines starting with PREFIX."
  (mapconcat (lambda (n) (format "%s %02d" prefix n))
             (number-sequence 1 count)
             "\n"))

(defun pilish-gui-test--thinking-scroll-messages ()
  "Return canonical history that exercises thinking-display scroll behavior."
  (vector
   (list :role "user"
         :content (vector (list :type "text" :text "Question one"))
         :timestamp 1704067200000)
   (list :role "assistant"
         :content (vector (list :type "text"
                                :text (concat
                                       (pilish-gui-test--thinking-scroll-lines
                                        "Earlier assistant line" 18)
                                       "\n\nShort bridge.")))
         :timestamp 1704067200500)
   (list :role "user"
         :content (vector (list :type "text" :text "Question two"))
         :timestamp 1704067200800)
   (list :role "assistant"
         :content (vector
                   (list :type "text"
                         :text "Prelude line A\nPrelude line B\nPrelude line C")
                   (list :type "thinking"
                         :thinking (concat
                                    (pilish-gui-test--thinking-scroll-lines
                                     "Thinking detail" 30)
                                    "\n\nConclusion thought"))
                   (list :type "text"
                         :text (concat "\n"
                                       (pilish-gui-test--thinking-scroll-lines
                                        "Final answer line" 12))))
         :timestamp 1704067201000)))

(defun pilish-gui-test--thinking-scroll-hidden-stub ()
  "Return the collapsed thinking stub used by the scroll-history fixture."
  (pilish--thinking-hidden-stub
   (pilish--thinking-normalize-text
    (concat
     (pilish-gui-test--thinking-scroll-lines
      "Thinking detail" 30)
     "\n\nConclusion thought"))))

(defun pilish-gui-test--render-thinking-scroll-history (buffer display-mode)
  "Render scroll-regression history into BUFFER using DISPLAY-MODE."
  (with-current-buffer buffer
    (pilish-chat-mode)
    (setq pilish--status 'idle
          pilish--thinking-display display-mode
          pilish--canonical-messages
          (pilish-gui-test--thinking-scroll-messages))
    (pilish--display-session-history pilish--canonical-messages
                                              buffer)
    (font-lock-ensure)
    (redisplay)))

(defun pilish-gui-test--window-visible-screen-lines (window)
  "Return how many screen lines WINDOW currently shows from buffer text."
  (count-screen-lines (window-start window) (window-end window t) nil window))

(defun pilish-gui-test--window-point-row (window)
  "Return WINDOW point's screen-line row within the current viewport."
  (count-screen-lines (window-start window) (window-point window) nil window))

(defun pilish-gui-test--window-current-line (window)
  "Return WINDOW point's current line without text properties."
  (with-selected-window window
    (buffer-substring-no-properties (line-beginning-position)
                                    (line-end-position))))

(defun pilish-gui-test--window-thinking-block-order (window)
  "Return the completed-thinking block order at WINDOW point, or nil."
  (with-selected-window window
    (pilish--thinking-block-at-pos (point))))

(defun pilish-gui-test--window-substantially-filled-p (window)
  "Return non-nil when WINDOW shows nearly a full body of buffer text."
  (>= (pilish-gui-test--window-visible-screen-lines window)
      (- (window-body-height window) 2)))

(defun pilish-gui-test--inspect-block-with-keys (command expected)
  "Use quick help and inspector COMMAND to show EXPECTED, then quit only Help."
  (let ((source (current-buffer))
        (original-message (symbol-function 'message))
        shown help)
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (when fmt (setq shown (apply #'format fmt args)))
                 (apply original-message fmt args))))
      (execute-kbd-macro (kbd "C-h .")))
    (should (equal shown expected))
    (execute-kbd-macro (kbd command))
    (setq help (current-buffer))
    (should (derived-mode-p 'help-mode))
    (should (eq help (window-buffer (selected-window))))
    (should buffer-read-only)
    (should (string-prefix-p (concat expected "\n") (buffer-string)))
    (execute-kbd-macro (kbd "q"))
    (should (eq (current-buffer) source))
    help))

;;;; Session Tests

(ert-deftest pilish-gui-test-session-starts ()
  "Test that a fake-backed pi session starts with proper layout."
  (pilish-gui-test-with-fresh-session
    (:backend fake :fake-scenario "prompt-lifecycle")
    (should (pilish-gui-test-session-active-p))
    (should (pilish-gui-test-chat-window))
    (should (pilish-gui-test-input-window))
    (should (pilish-gui-test-verify-layout))))

(ert-deftest pilish-gui-test-reply-details-keyboard-help-and-safe-quit ()
  "Production keys select Help, reuse its window, and leave a live draft alone."
  (pilish-gui-test-with-fresh-session
    (:backend fake :fake-scenario "prompt-lifecycle")
    (pilish-gui-test-send "reply details keyboard")
    (let* ((chat (plist-get pilish-gui-test--session :chat-buffer))
           (input (plist-get pilish-gui-test--session :input-buffer))
           (process (plist-get pilish-gui-test--session :process))
           (file (with-current-buffer chat (plist-get pilish--state :session-file)))
           (bytes (with-temp-buffer
                    (insert-file-contents-literally file) (buffer-string)))
           (draft "An unsent draft stays here.\nAnd on this line.")
           (help-window-select nil)
           help reused-window)
      (unwind-protect
          (progn
            (when (get-buffer "*Help*") (kill-buffer "*Help*"))
            (with-current-buffer input (erase-buffer) (insert draft))
            (select-window (pilish-gui-test-chat-window))
            (goto-char (point-min))
            (search-forward "Fake reply for: reply details keyboard")
            (backward-char)
            (let ((original-message (symbol-function 'message)) shown)
              (cl-letf (((symbol-function 'message)
                         (lambda (fmt &rest args)
                           (when fmt (setq shown (apply #'format fmt args)))
                           (apply original-message fmt args))))
                (execute-kbd-macro (kbd "C-h .")))
              (should (string-prefix-p "Reply · " shown))
              (should (string-match-p "ollama / qwen3:1.7b" shown))
              (should (string-match-p "Message tokens: input 0 · output 0" shown))
              (should-not (string-match-p "Stream:" shown)))
            (dolist (reuse '(nil t))
              (when reuse
                (setq reused-window
                      (display-buffer
                       help '((display-buffer-reuse-window display-buffer-pop-up-window)
                              (inhibit-same-window . t))))
                (should (window-live-p reused-window))
                (should (eq (window-buffer reused-window) help))
                (should (eq (current-buffer) chat))
                (should (eq (window-buffer (selected-window)) chat)))
              (execute-kbd-macro (kbd "C-c C-p d"))
              (should (derived-mode-p 'help-mode))
              (should (eq (current-buffer) (window-buffer (selected-window))))
              (setq help (current-buffer))
              (when reused-window (should (eq (selected-window) reused-window)))
              (should buffer-read-only)
              (should (string-prefix-p "Reply · " (buffer-string)))
              (should (string-match-p "ollama / qwen3:1.7b" (buffer-string)))
              (should (string-match-p "Message tokens: input 0 · output 0" (buffer-string)))
              (should (string-match-p "Cache: read 0 · write 0" (buffer-string)))
              (should-not (string-match-p "Stream:\\|Fake reply for:" (buffer-string)))
              (execute-kbd-macro (kbd "q"))
              (should (eq (current-buffer) chat))
              (should (process-live-p process))
              (should (eq (buffer-local-value 'pilish--process chat) process))
              (should (equal (with-current-buffer input (buffer-string)) draft))
              (should (equal (with-temp-buffer
                               (insert-file-contents-literally file) (buffer-string))
                             bytes)))
            (let ((pilish-bash-preview-lines 2))
              (pilish--set-chat-thinking-display 'visible)
              (pilish--display-history-messages
               [(:role "assistant" :timestamp 1784817120000 :provider "saved"
                 :model "literal\\[find-file]%"
                 :content [(:type "thinking" :thinking "GUI private first\nGUI private second")
                           (:type "toolCall" :id "gui-details" :name "bash"
                            :arguments (:command "printf '\\[find-file]' %"))])
                (:role "toolResult" :toolCallId "gui-details" :timestamp 1784817120000
                 :content [(:type "text" :text "GUI output one\nGUI output two\nGUI output three\nGUI output four")])])
              (goto-char (point-min))
              (search-forward "GUI private first")
              (backward-char)
              (let ((expected (pilish--details-at-point)))
                (should (string-prefix-p "Thinking · " expected))
                (should (string-match-p "2 lines" expected))
                (setq help (pilish-gui-test--inspect-block-with-keys "C-c C-p d" expected))
                (execute-kbd-macro (kbd "TAB"))
                (should (eq (plist-get (pilish--thinking-block-metadata-at-pos (point)) :display) 'hidden))
                (setq help (pilish-gui-test--inspect-block-with-keys "C-c C-p d" expected))
                (execute-kbd-macro (kbd "TAB")))
              (goto-char (point-min))
              (search-forward "GUI output one")
              (backward-char)
              (let* ((expected (pilish--details-at-point))
                     (overlay (car (pilish--tool-block-overlays-in-region (point) (1+ (point))))))
                (should (string-prefix-p "Bash · " expected))
                (should (string-match-p (regexp-quote "printf '\\[find-file]' %") expected))
                (setq help (pilish-gui-test--inspect-block-with-keys "C-c C-p d" expected))
                (execute-kbd-macro (kbd "TAB"))
                (search-forward "GUI output four")
                (backward-char)
                (setq help (pilish-gui-test--inspect-block-with-keys "C-c C-p d" expected))
                (execute-kbd-macro (kbd "TAB"))
                (goto-char (overlay-start overlay))
                (setq help (pilish-gui-test--inspect-block-with-keys "C-c C-p d" expected))
                (should (pilish--cool-tool-overlay overlay))
                (goto-char (point-min))
                (search-forward "GUI output one")
                (backward-char)
                (should (get-text-property (point) 'pilish-cold-tool-block))
                (setq help (pilish-gui-test--inspect-block-with-keys "C-c C-p d" expected))))
            (should (process-live-p process))
            (should (eq (buffer-local-value 'pilish--process chat) process))
            (should (equal (with-current-buffer input (buffer-string)) draft))
            (should (equal (with-temp-buffer
                             (insert-file-contents-literally file) (buffer-string)) bytes)))
        (when (buffer-live-p help) (kill-buffer help))))))

(ert-deftest pilish-gui-test-send-waits-for-turn-start ()
  "Regression for issue #303: send waits until the submitted turn starts.
With a pre-start delay between the prompt ack and `agent_start', the
helpers previously returned while the status was still `sending', so
the next `pilish-send' queued its prompt as a follow-up and assertions
raced a turn that was never submitted."
  (pilish-gui-test-with-fresh-session
    (:backend fake :fake-scenario "prompt-lifecycle"
              :fake-extra-args ("--pre-start-delay-ms=100"))
    (pilish-gui-test-send "first turn")
    (pilish-gui-test-send "second turn")
    (should (pilish-gui-test-chat-contains "Fake reply for: second turn"))
    (should (pilish-gui-test-idle-p))))

(ert-deftest pilish-gui-test-snapshot-keyboard-other-window ()
  "Open an observer, inspect each completed block, and quit only the observer."
  (pilish-gui-test-with-fresh-session
    (:backend fake :fake-scenario "prompt-lifecycle")
    (pilish-test--with-snapshot-files
      (pilish-test--snapshot-write
       child (list header
                   (pilish-test--snapshot-message "leaf" nil "GUI saved child answer")
                   '(:type "message" :id "assistant" :parentId "leaf"
                     :message (:role "assistant" :timestamp 0 :provider "saved"
                               :model "observer-model" :usage (:input 2 :output 3)
                               :content [(:type "text" :text "GUI saved assistant metadata")
                                         (:type "thinking" :thinking "GUI saved private reasoning")
                                         (:type "toolCall" :id "A" :name "bash"
                                          :arguments (:command "printf '\\[find-file]' %"))]))
                   '(:type "message" :id "result" :parentId "assistant"
                     :message (:role "toolResult" :toolCallId "A" :timestamp 0
                               :content [(:type "text" :text "GUI saved private output")]))))
      (let* ((parent (plist-get pilish-gui-test--session :chat-buffer))
             (input (plist-get pilish-gui-test--session :input-buffer))
             (process (plist-get pilish-gui-test--session :process))
             (parent-window (get-buffer-window parent))
             (saved-bytes (with-temp-buffer (insert-file-contents-literally child) (buffer-string)))
             snapshot help)
        (unwind-protect
            (progn
              (with-current-buffer input (insert "Unsent GUI draft"))
              (select-window parent-window)
              (setq pilish--state (plist-put pilish--state :session-file anchor))
              (let ((block (pilish--display-tool-start "subagent" '(:agent "alias") "snapshot-call")))
                (pilish--display-tool-end
                 "subagent" '(:agent "alias") [(:type "text" :text "## Subagent resolved result\nSaved")]
                 details nil block))
              (goto-char (point-min))
              (redisplay t)
              (execute-kbd-macro (kbd "C-c ]"))
              (redisplay t)
              (should (looking-at "saved child"))
              (should (pos-visible-in-window-p (point) parent-window))
              (let ((original-message (symbol-function 'message)) shown)
                (cl-letf (((symbol-function 'message)
                           (lambda (fmt &rest args)
                             (when fmt (setq shown (apply #'format fmt args)))
                             (apply original-message fmt args))))
                  (execute-kbd-macro (kbd "C-h .")))
                (should (equal shown "Open Pi session read-only in another window")))
              (execute-kbd-macro (kbd "RET"))
              (setq snapshot (current-buffer))
              (redisplay t)
              (should (derived-mode-p 'pilish-snapshot-mode))
              (should buffer-read-only)
              (should (equal pilish--snapshot-source-file child))
              (should-not (eq (selected-window) parent-window))
              (should (eq (window-buffer parent-window) parent))
              (search-forward "GUI saved child answer")
              (redisplay t)
              (should (pos-visible-in-window-p (match-beginning 0) (selected-window)))
              (should-not (pilish--get-process))
              (should (process-live-p process))
              (should (eq (buffer-local-value 'pilish--process parent) process))
              (should (equal (with-current-buffer input (buffer-string)) "Unsent GUI draft"))
              (search-forward "GUI saved assistant metadata")
              (backward-char)
              (let ((original-message (symbol-function 'message)) shown)
                (cl-letf (((symbol-function 'message)
                           (lambda (fmt &rest args)
                             (when fmt (setq shown (apply #'format fmt args)))
                             (apply original-message fmt args))))
                  (execute-kbd-macro (kbd "C-h .")))
                (should (string-prefix-p "Reply · " shown))
                (should (string-match-p "saved / observer-model" shown))
                (should (string-match-p "Message tokens: input 2 · output 3" shown))
                (should-not (string-match-p "Stream:\\|GUI saved assistant metadata" shown)))
              (execute-kbd-macro (kbd "M-x pilish-describe-reply RET"))
              (setq help (current-buffer))
              (should (derived-mode-p 'help-mode))
              (should (eq (window-buffer (selected-window)) help))
              (should buffer-read-only)
              (should (string-match-p "saved / observer-model" (buffer-string)))
              (should (string-match-p "Message tokens: input 2 · output 3" (buffer-string)))
              (should-not (string-match-p "Stream:\\|GUI saved assistant metadata" (buffer-string)))
              (execute-kbd-macro "q")
              (should (eq (current-buffer) snapshot))
              (dolist (target '(("GUI saved private reasoning" . "Thinking · ")
                                ("GUI saved private output" . "Bash · ")))
                (goto-char (point-min))
                (search-forward (car target))
                (backward-char)
                (let ((expected (pilish--details-at-point)))
                  (should (string-prefix-p (cdr target) expected))
                  (should-not (string-match-p "Stream:\\|Execution time:\\|private" expected))
                  (setq help (pilish-gui-test--inspect-block-with-keys
                              "M-x pilish-describe-reply RET" expected))))
              (should (process-live-p process))
              (should (eq (buffer-local-value 'pilish--process parent) process))
              (should (equal (with-current-buffer input (buffer-string)) "Unsent GUI draft"))
              (execute-kbd-macro "q")
              (should-not (buffer-live-p snapshot))
              (should (process-live-p process))
              (should (buffer-live-p parent))
              (should (eq (buffer-local-value 'pilish--process parent) process))
              (should (buffer-live-p input))
              (should (equal (with-current-buffer input (buffer-string)) "Unsent GUI draft"))
              (should (equal (with-temp-buffer (insert-file-contents-literally child) (buffer-string))
                             saved-bytes)))
          (when (buffer-live-p help) (kill-buffer help))
          (when (buffer-live-p snapshot) (kill-buffer snapshot)))))))

(ert-deftest pilish-gui-test-snapshot-refresh-keyboard-g ()
  "Pressing g in a snapshot observer rereads and republishes it in place."
  (pilish-gui-test-with-fresh-session
    (:backend fake :fake-scenario "prompt-lifecycle")
    (pilish-test--with-snapshot-files
      (pilish-test--snapshot-write
       child (list header (pilish-test--snapshot-message "leaf" nil "GUI saved child answer")))
      (let* ((parent (plist-get pilish-gui-test--session :chat-buffer))
             (input (plist-get pilish-gui-test--session :input-buffer))
             (process (plist-get pilish-gui-test--session :process))
             (parent-window (get-buffer-window parent))
             snapshot replacement snapshot-window)
        (unwind-protect
            (progn
              (with-current-buffer input (insert "Unsent GUI draft"))
              (select-window parent-window)
              (setq pilish--state (plist-put pilish--state :session-file anchor))
              (let ((block (pilish--display-tool-start "subagent" '(:agent "alias") "snapshot-call")))
                (pilish--display-tool-end
                 "subagent" '(:agent "alias") [(:type "text" :text "## Subagent resolved result\nSaved")]
                 details nil block))
              (goto-char (point-min))
              (redisplay t)
              (execute-kbd-macro (kbd "C-c ]"))
              (execute-kbd-macro (kbd "RET"))
              (setq snapshot (current-buffer))
              (setq snapshot-window (selected-window))
              (set-window-margins snapshot-window 3 2)
              (redisplay t)
              (should (string-match-p "GUI saved child answer" (buffer-string)))
              (execute-kbd-macro (kbd "g"))
              (redisplay t)
              (should (eq (current-buffer) snapshot))
              (should (eq (window-buffer snapshot-window) snapshot))
              (should (equal (window-margins snapshot-window) '(3 . 2)))
              (pilish-test--snapshot-write
               child (list header
                           (pilish-test--snapshot-message "leaf" nil "GUI saved child answer")
                           (pilish-test--snapshot-message "later" "leaf" "GUI refreshed text")))
              (execute-kbd-macro (kbd "g"))
              (setq replacement (window-buffer snapshot-window))
              (redisplay t)
              (should-not (eq replacement snapshot))
              (should-not (buffer-live-p snapshot))
              (should (equal (window-margins snapshot-window) '(3 . 2)))
              (with-selected-window snapshot-window
                (should (string-match-p "GUI refreshed text" (buffer-string)))
                (should (string-match-p "g rereads" (format-mode-line header-line-format)))
                (goto-char (point-min))
                (search-forward "GUI refreshed text")
                (redisplay t)
                (should (pos-visible-in-window-p (match-beginning 0) snapshot-window)))
              (delete-file child)
              (with-current-buffer replacement
                (should-error (pilish-snapshot-refresh) :type 'user-error))
              (redisplay t)
              (should (buffer-live-p replacement))
              (should (eq (window-buffer snapshot-window) replacement))
              (with-current-buffer replacement
                (should (string-match-p "Refresh failed:"
                                        (format-mode-line header-line-format))))
              (pilish-test--snapshot-write
               child (list header
                           (pilish-test--snapshot-message "leaf" nil "GUI saved child answer")
                           (pilish-test--snapshot-message "later" "leaf" "GUI refreshed text")))
              (with-current-buffer replacement
                (pilish-snapshot-refresh))
              (redisplay t)
              (with-current-buffer replacement
                (should-not (string-match-p "Refresh failed:"
                                            (format-mode-line header-line-format))))
              (execute-kbd-macro "q")
              (redisplay t)
              (should-not (buffer-live-p replacement))
              (should (process-live-p process))
              (should (buffer-live-p parent))
              (should (eq (window-buffer parent-window) parent))
              (should (equal (with-current-buffer input (buffer-string)) "Unsent GUI draft")))
          (when (buffer-live-p replacement) (kill-buffer replacement))
          (when (buffer-live-p snapshot) (kill-buffer snapshot)))))))

(ert-deftest pilish-gui-test-snapshot-refresh-preserves-markdown-display ()
  "Changed refreshes preserve Markdown faces and hidden delimiters."
  (pilish-test--with-snapshot-files
    (save-window-excursion
      (let (snapshot snapshot-window buffers messages)
        (unwind-protect
            (dolist (phase '((open "Initial") (g "Keyboard") (revert "Reverted")))
              (ert-info ((format "Snapshot Markdown display after %s" (car phase)))
                (let ((label (cadr phase))
                      (previous snapshot))
                  (pilish-test--snapshot-write
                   child (list header
                               (pilish-test--snapshot-message
                                "leaf" nil
                                (format "## %s heading\n\nA **%s bold answer**.\n" label label))))
                  (setq messages nil)
                  (cl-letf (((symbol-function 'message)
                             (lambda (fmt &rest args)
                               (push (apply #'format fmt args) messages))))
                    (pcase (car phase)
                      ('open
                       (setq snapshot (pilish-open-subagent-snapshot target)
                             snapshot-window (selected-window)))
                      ('g (execute-kbd-macro (kbd "g")))
                      ('revert (revert-buffer nil t))))
                  (setq snapshot (window-buffer snapshot-window))
                  (push snapshot buffers)
                  (when previous
                    (should-not (eq snapshot previous))
                    (should-not (buffer-live-p previous))
                    (should (member "Saved conversation updated" messages)))
                  (with-selected-window snapshot-window
                    (goto-char (point-min))
                    (set-window-start snapshot-window (point-min))
                    (redisplay t)
                    (should (search-forward (concat "## " label " heading") nil t))
                    (let ((marker (match-beginning 0)))
                      (should (pos-visible-in-window-p (+ marker 3) snapshot-window))
                      (should (invisible-p marker))
                      (should (memq 'md-ts-heading-2
                                    (ensure-list (get-text-property (+ marker 3) 'face)))))
                    (should (search-forward (concat "**" label " bold answer**") nil t))
                    (let ((marker (match-beginning 0))
                          (end (match-end 0)))
                      (should (pos-visible-in-window-p (+ marker 2) snapshot-window))
                      (should (invisible-p marker))
                      (should (invisible-p (- end 2)))
                      (should (memq 'bold
                                    (ensure-list (get-text-property (+ marker 2) 'face)))))))))
          (apply #'pilish-test--kill-live-buffers buffers))))))

(ert-deftest pilish-gui-test-snapshot-refresh-header-repaints-failure-and-recovery ()
  "Failed and unchanged-success rereads repaint the displayed observer header."
  (skip-unless (fboundp 'x-export-frames))
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write
     child (list header (pilish-test--snapshot-message "leaf" nil "Last good saved text")))
    (save-window-excursion
      (let (snapshot messages)
        (unwind-protect
            (progn
              (setq snapshot (pilish-open-subagent-snapshot target))
              (delete-other-windows)
              (setq-local cursor-type nil)
              (redisplay t)
              (let ((clean (secure-hash 'sha256 (x-export-frames nil 'png))))
                (should (equal clean (secure-hash 'sha256 (x-export-frames nil 'png))))
                (delete-file child)
                (should-error (pilish-snapshot-refresh) :type 'user-error)
                (redisplay t)
                (should-not (equal clean (secure-hash 'sha256 (x-export-frames nil 'png))))
                (should (string-match-p "Last good saved text" (buffer-string)))
                (pilish-test--snapshot-write
                 child (list header (pilish-test--snapshot-message "leaf" nil "Last good saved text")))
                (cl-letf (((symbol-function 'message)
                           (lambda (fmt &rest args)
                             (push (apply #'format fmt args) messages))))
                  (should (eq (pilish-snapshot-refresh) snapshot)))
                (should (member "Saved conversation unchanged" messages))
                (redisplay t)
                (should (equal clean (secure-hash 'sha256 (x-export-frames nil 'png))))))
          (pilish-test--kill-live-buffers snapshot))))))

(ert-deftest pilish-gui-test-snapshot-refresh-header-literal-percents ()
  "Formatted and painted refresh notes preserve literal percent constructs."
  (skip-unless (fboundp 'x-export-frames))
  (save-window-excursion
    (let ((snapshot (generate-new-buffer " *snapshot-percent-header*"))
          (width (frame-width))
          (note "Refresh failed: /tmp/child%s%d.jsonl"))
      (unwind-protect
          (progn
            (set-frame-width nil 140)
            (sit-for 0.1)
            (switch-to-buffer snapshot)
            (delete-other-windows)
            (pilish-snapshot-mode)
            (setq-local cursor-type nil)
            (pilish--set-snapshot-refresh-note note)
            (redisplay t)
            (should (equal (format-mode-line header-line-format)
                           (concat "Pi session, read-only.  g rereads, q closes.  " note)))
            (let ((painted (secure-hash 'sha256 (x-export-frames nil 'png))))
              (pilish--set-snapshot-refresh-note note)
              (redisplay t)
              (should (equal pilish--snapshot-refresh-note note))
              (should (equal painted (secure-hash 'sha256 (x-export-frames nil 'png))))
              (setq-local header-line-format
                          '("Pi session, read-only.  g rereads, q closes."
                            (:eval (propertize "  Refresh failed: /tmp/child%%s%%d.jsonl"
                                               'face 'pilish-error-notice))))
              (force-mode-line-update)
              (redisplay t)
              (should (equal painted (secure-hash 'sha256 (x-export-frames nil 'png))))))
        (pilish-test--kill-live-buffers snapshot)
        (set-frame-width nil width)
        (sit-for 0.1)))))

;;;; Scroll Preservation Tests

(defun pilish-gui-test--check-bounded-screen-lines (window regions)
  (dolist (region regions)
    (dolist (endpoints (list region (cons (cdr region) (car region))))
      (dolist (final-newline '(nil t))
        (let* ((start (car endpoints))
               (finish (cdr endpoints))
               (exact (count-screen-lines start finish final-newline window))
               (before (list (point) (point-min) (point-max) (selected-window)
                             (window-start window) (window-point window)
                             (window-hscroll window) (window-vscroll window))))
          (dolist (limit (delete-dups (list 0 1 (max 0 (1- exact)) exact
                                          (1+ exact) (+ exact 2))))
            (ert-info ((format "width=%S hscroll=%S region=%S final=%S limit=%S"
                               (window-body-width window) (window-hscroll window)
                               endpoints final-newline limit))
              (should (= (min limit exact)
                         (pilish--count-screen-lines-up-to
                          start finish limit window final-newline)))
              (should (equal before
                             (list (point) (point-min) (point-max) (selected-window)
                                   (window-start window) (window-point window)
                                   (window-hscroll window) (window-vscroll window)))))))))))

(ert-deftest pilish-gui-test-bounded-screen-lines-wrapping ()
  (should (display-graphic-p))
  (save-window-excursion
    (delete-other-windows)
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (setq-local word-wrap t
                  truncate-lines nil
                  truncate-partial-width-windows nil)
      (insert (apply #'concat (make-list 60 "wrap words ")) "\n")
      (let ((long-end (point))
            (window (selected-window))
            counts)
        (insert "hidden markup\nreplacement\nlast\n")
        (put-text-property long-end (+ long-end 14) 'invisible t)
        (put-text-property (+ long-end 14) (+ long-end 25)
                           'display "displayed\non two rows")
        (goto-char 20)
        (set-window-start window (point-min) t)
        (dolist (partial '(nil t))
          (when partial (split-window-right))
          (redisplay t)
          (let ((exact (count-screen-lines (point-min) (point-max) nil window)))
            (should (> exact (count-lines (point-min) (point-max))))
            (push exact counts))
          (pilish-gui-test--check-bounded-screen-lines
           window (list (cons (point-min) (point-max)) (cons 17 (- long-end 9))
                        (cons long-end (point-max)) (cons long-end long-end)))
          (save-restriction
            (narrow-to-region 10 (- long-end 3))
            (pilish-gui-test--check-bounded-screen-lines
             window (list (cons (point-min) (point-max))
                          (cons 22 (1- (point-max)))))))
        (should (> (car counts) (cadr counts)))))))

(ert-deftest pilish-gui-test-bounded-screen-lines-truncation-and-hscroll ()
  (should (display-graphic-p))
  (save-window-excursion
    (delete-other-windows)
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (setq-local truncate-lines t
                  truncate-partial-width-windows t
                  auto-hscroll-mode nil)
      (insert (make-string (* 4 (window-body-width)) ?x))
      (let ((long-end (point))
            (window (selected-window)))
        (insert "\nshort\n")
        (goto-char (point-min))
        (set-window-start window (point-min) t)
        (dolist (partial '(nil t))
          (when partial
            (split-window-right)
            (setq truncate-lines nil)
            (should (truncated-partial-width-window-p window)))
          (dolist (hscroll '(0 7 25))
            (set-window-hscroll window hscroll)
            (redisplay t)
            (should (= hscroll (window-hscroll window)))
            (should (= 1 (count-screen-lines 1 long-end nil window)))
            (let ((edge (+ 1 hscroll (window-body-width window))))
              (pilish-gui-test--check-bounded-screen-lines
               window (list (cons 1 long-end) (cons 1 (point-max))
                            (cons 1 (1- edge)) (cons 1 edge) (cons 1 (1+ edge))
                            (cons 12 long-end) (cons (1+ long-end) (point-max)))))
            (save-restriction
              (narrow-to-region 3 (1- (point-max)))
              (pilish-gui-test--check-bounded-screen-lines
               window (list (cons (point-min) (point-max)) (cons 10 long-end))))))))))

(ert-deftest pilish-gui-test-bounded-thinking-end-preserves-non-tail-reader ()
  (let ((chat (generate-new-buffer " *pi-bounded-thinking-reader*"))
        (input (generate-new-buffer " *pi-bounded-thinking-input*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer chat)
          (pilish-chat-mode)
          (setq pilish--thinking-display 'visible)
          (let ((inhibit-read-only t))
            (dotimes (index 150)
              (insert (format "History %03d with enough words to wrap in a narrow reader window.\n"
                              index))))
          (pilish--display-agent-start)
          (pilish--display-thinking-start)
          (pilish--display-thinking-delta "Visible thinking stays visible.\nAnother thought.")
          (let ((inhibit-read-only t))
            (save-excursion
              (goto-char pilish--thinking-marker)
              (pilish--ensure-blank-line-separator)))
          (let* ((reader (selected-window))
                 (input-window (split-window reader -5 'below))
                 (tail (split-window reader nil 'right))
                 (motion (symbol-function 'vertical-motion))
                 (restore (symbol-function 'pilish--restore-window-rewrite-states))
                 (thinking-start (marker-position pilish--thinking-start-marker))
                 (text (buffer-substring-no-properties (point-min) (point-max)))
                 (chars-tick (buffer-chars-modified-tick))
                 requests (restorations 0))
            (set-window-buffer tail chat)
            (with-selected-window tail (goto-char (point-max)) (recenter -1))
            (goto-char (point-min))
            (forward-line 7)
            (recenter 3)
            (set-window-buffer input-window input)
            (select-window input-window)
            (insert "An unsent draft.\nStill here.")
            (goto-char 5)
            (redisplay t)
            (let ((start (window-start reader))
                  (point (window-point reader)))
              (with-current-buffer chat
                (should-not (pilish--window-following-p reader))
                (cl-letf (((symbol-function 'vertical-motion)
                           (lambda (rows &rest args)
                             (push (list rows (car args)) requests)
                             (apply motion rows args)))
                          ((symbol-function 'pilish--restore-window-rewrite-states)
                           (lambda (&rest args)
                             (cl-incf restorations)
                             (apply restore args))))
                  (pilish--display-thinking-end ""))
                (should (= restorations 1))
                (should requests)
                (dolist (request requests)
                  (should (<= (car request)
                              (1+ (window-body-height (cadr request))))))
                (should (equal text (buffer-substring-no-properties (point-min) (point-max))))
                (should (= chars-tick (buffer-chars-modified-tick)))
                (should (pilish--thinking-block-at-pos thinking-start)))
              (redisplay t)
              (should (= start (window-start reader)))
              (should (= point (window-point reader)))
              (should (eq (selected-window) input-window))
              (should (= (point) 5))
              (should (equal (buffer-string) "An unsent draft.\nStill here."))
              (with-current-buffer chat
                (should-not (pilish--window-following-p reader))
                (should (pilish--window-following-p tail))
                (should (pilish-gui-test--window-substantially-filled-p tail))))))
      (kill-buffer chat)
      (kill-buffer input))))

(ert-deftest pilish-gui-test-scroll-preserved-streaming ()
  "Test scroll position is preserved while a fake stream updates below."
  (pilish-gui-test-with-fresh-session
    (:backend fake :fake-scenario "scrolling-text")
    (pilish-gui-test-send "first turn")
    ;; The fake stream is usually tall enough already, but large frames can make
    ;; the buffer barely non-scrollable.  Top off with dummy lines so the test
    ;; exercises scroll preservation rather than frame geometry.
    (pilish-gui-test-ensure-scrollable)
    (pilish-gui-test-scroll-up 20)
    (should-not (pilish-gui-test-at-end-p))
    (let ((line-before (pilish-gui-test-top-line-number)))
      (should (> line-before 1))
      (pilish-gui-test-send "second turn")
      (should (= line-before (pilish-gui-test-top-line-number)))
      (should (pilish-gui-test-chat-contains "Scroll line 24 for second turn")))))

(ert-deftest pilish-gui-test-scroll-preserved-tool-use ()
  "Test scroll position is preserved while fake tool output arrives."
  (pilish-gui-test-with-fresh-session
    (:backend fake :fake-scenario "tool-read")
    (pilish-gui-test-ensure-scrollable)
    (pilish-gui-test-scroll-up 20)
    (should-not (pilish-gui-test-at-end-p))
    (let ((line-before (pilish-gui-test-top-line-number)))
      (should (> line-before 1))
      (pilish-gui-test-send "Use the fake read tool")
      (should (= line-before (pilish-gui-test-top-line-number)))
      (should (pilish-gui-test-chat-contains "fake tool output")))))

(ert-deftest pilish-gui-test-tool-streaming-preserves-point-after-block ()
  "Tool growth and contraction keep point on text after the block."
  (let ((buf (get-buffer-create "*pi-gui-tool-point-stability*")))
    (unwind-protect
        (progn
          (switch-to-buffer buf)
          (pilish-chat-mode)
          (let ((block (pilish--display-tool-start
                        "bash" '(:command "demo") "point-stability"))
                (inhibit-read-only t)
                after-expansion after-contraction)
            (goto-char (point-max))
            (insert "AFTER-TOOL sentinel\n")
            (goto-char (point-min))
            (search-forward "AFTER-TOOL sentinel")
            (beginning-of-line)
            (set-window-point (selected-window) (point))
            (redisplay)
            (pilish--display-tool-update
             '(:content [(:type "text" :text "one\ntwo\nthree\n")])
             block)
            (redisplay)
            (setq after-expansion
                  (pilish-gui-test--window-current-line (selected-window)))
            (pilish--display-tool-end
             "bash" '(:command "demo")
             '[(:type "text" :text "final\n")] nil nil block)
            (redisplay)
            (setq after-contraction
                  (pilish-gui-test--window-current-line (selected-window)))
            (should (equal '("AFTER-TOOL sentinel" "AFTER-TOOL sentinel")
                           (list after-expansion after-contraction)))))
      (kill-buffer buf))))

(ert-deftest pilish-gui-test-tool-streaming-restores-deleted-point-to-body-start ()
  (let ((buf (get-buffer-create "*pi-gui-tool-deleted-preview-point*")))
    (unwind-protect
        (progn
          (switch-to-buffer buf)
          (pilish-chat-mode)
          (let ((block (pilish--display-tool-start
                        "bash" '(:command "demo") "deleted-preview-point"))
                body-start)
            (pilish--display-tool-update
             '(:content [(:type "text" :text "old preview text\n")])
             block)
            (setq body-start
                  (marker-position (pilish--tool-block-header-end block)))
            (goto-char (point-min))
            (search-forward "old pre")
            (pilish--display-tool-update
             '(:content [(:type "text" :text "new result text\n")])
             block)
            (redisplay)
            (should (= (point) body-start))))
      (kill-buffer buf))))

(ert-deftest pilish-gui-test-tool-completion-restores-deleted-point-to-body-start ()
  (let ((buf (get-buffer-create "*pi-gui-tool-deleted-final-point*")))
    (unwind-protect
        (progn
          (switch-to-buffer buf)
          (pilish-chat-mode)
          (let ((block (pilish--display-tool-start
                        "bash" '(:command "demo") "deleted-final-point"))
                body-start)
            (pilish--display-tool-update
             '(:content [(:type "text"
                          :text "first\nstreaming text that will disappear\nlast\n")])
             block)
            (setq body-start
                  (marker-position (pilish--tool-block-header-end block)))
            (goto-char (point-min))
            (search-forward "streaming text ")
            (pilish--display-tool-end
             "bash" '(:command "demo")
             (vector (list :type "text" :text "Short final result"))
             nil nil block)
            (redisplay)
            (should (= (point) body-start))))
      (kill-buffer buf))))

(ert-deftest pilish-gui-test-append-keeps-tail-filled ()
  (let ((buf (get-buffer-create "*pi-gui-append-tail*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer buf)
          (pilish-chat-mode)
          (let ((window (selected-window))
                (inhibit-read-only t))
            (dotimes (index 45)
              (insert (format "Earlier transcript line %02d\n" index)))
            (redisplay t)
            (sit-for 0.2)
            (goto-char (point-max))
            (recenter -1)
            (redisplay)
            (should (pilish-gui-test--window-substantially-filled-p window))
            (pilish--append-to-chat "Next streamed line\n")
            (redisplay)
            (should (>= (window-point window) (1- (point-max))))
            (should (>= (window-end window t) (1- (point-max))))
            (should (pilish-gui-test--window-substantially-filled-p window))))
      (kill-buffer buf))))

(ert-deftest pilish-gui-test-streaming-delta-keeps-tail-filled ()
  (let ((buf (get-buffer-create "*pi-gui-delta-tail*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer buf)
          (pilish-chat-mode)
          (let ((window (selected-window))
                (inhibit-read-only t))
            (dotimes (index 45)
              (insert (format "Earlier transcript line %02d\n" index)))
            (pilish--display-agent-start)
            (redisplay t)
            (sit-for 0.2)
            (goto-char (point-max))
            (recenter -1)
            (redisplay)
            (should (pilish-gui-test--window-substantially-filled-p window))
            (pilish--display-message-delta "Next streamed line\n")
            (redisplay)
            (should (>= (window-point window) (1- (point-max))))
            (should (>= (window-end window t) (1- (point-max))))
            (should (pilish-gui-test--window-substantially-filled-p window))))
      (kill-buffer buf))))

(ert-deftest pilish-gui-test-tool-completion-keeps-independent-views-filled ()
  (let ((buf (get-buffer-create "*pi-gui-tool-tail-contraction*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer buf)
          (pilish-chat-mode)
          (let ((tail-window (selected-window))
                (inhibit-read-only t)
                block reader-window reader-start reader-point)
            (dotimes (index 45)
              (insert (format "Earlier transcript line %02d\n" index)))
            (setq block
                  (pilish--display-tool-start
                   "bash" '(:command "demo") "tail-contraction"))
            (pilish--display-tool-update
             (list :content
                   (vector
                    (list :type "text"
                          :text (mapconcat
                                 (lambda (index)
                                   (format "Streaming output line %02d" index))
                                 (number-sequence 1 50) "\n"))))
             block)
            (goto-char (point-max))
            (recenter -1)
            (setq reader-window (split-window-right))
            (set-window-buffer reader-window buf)
            (set-window-start reader-window (point-min) t)
            (set-window-point reader-window (point-min))
            (setq reader-start (window-start reader-window)
                  reader-point (window-point reader-window))
            (redisplay)
            (pilish--display-tool-end
             "bash" '(:command "demo")
             (vector (list :type "text" :text "Short final result"))
             nil nil block)
            (redisplay)
            (should (>= (window-point tail-window) (1- (point-max))))
            (should (pilish-gui-test--window-substantially-filled-p tail-window))
            (should (= (window-start reader-window) reader-start))
            (should (= (window-point reader-window) reader-point))
            (pilish--append-to-chat "Next streamed line\n")
            (redisplay)
            (should (>= (window-point tail-window) (1- (point-max))))
            (should (pilish-gui-test--window-substantially-filled-p tail-window))
            (should (= (window-start reader-window) reader-start))
            (should (= (window-point reader-window) reader-point))))
      (kill-buffer buf))))

(ert-deftest pilish-gui-test-scroll-auto-when-at-end ()
  "Test auto-scroll when user is at end across deterministic fake turns.
Regression: `pilish--display-agent-end' must leave window-point at
buffer end so the next streamed turn still follows automatically."
  (pilish-gui-test-with-fresh-session
    (:backend fake :fake-scenario "scrolling-text")
    (pilish-gui-test-send "first turn")
    (should (pilish-gui-test-window-point-at-end-p))
    (should (pilish-gui-test-at-end-p))
    (pilish-gui-test-send "second turn")
    (should (pilish-gui-test-window-point-at-end-p))
    (should (pilish-gui-test-at-end-p))
    (should (pilish-gui-test-chat-contains "Scroll line 24 for second turn"))))

(ert-deftest pilish-gui-test-thinking-initial-whitespace-keeps-point ()
  (let ((buf (get-buffer-create "*pi-gui-thinking-initial-point*")))
    (unwind-protect
        (progn
          (switch-to-buffer buf)
          (pilish-chat-mode)
          (pilish--display-agent-start)
          (pilish--display-thinking-start)
          (let ((position (1+ (marker-position pilish--thinking-start-marker))))
            (goto-char position)
            (pilish--display-thinking-delta "\n")
            (pilish--display-thinking-delta "alpha")
            (redisplay)
            (should (equal (buffer-substring-no-properties
                            (line-beginning-position) (line-end-position))
                           "> alpha"))
            (should (= (point) position))))
      (kill-buffer buf))))

(ert-deftest pilish-gui-test-thinking-display-toggle-keeps-tail-filled ()
  "Toggling completed thinking keeps a tail-following chat window filled.
After the toggle, a new streamed turn should still auto-scroll from the tail."
  (let ((buf (get-buffer-create "*pi-gui-thinking-tail*")))
    (unwind-protect
        (progn
          (switch-to-buffer buf)
          (pilish-gui-test--render-thinking-scroll-history buf 'visible)
          (let ((win (selected-window)))
            (goto-char (point-max))
            (recenter -1)
            (redisplay)
            (should (>= (window-point win) (1- (point-max))))
            (should (pilish-gui-test--window-substantially-filled-p win))
            (pilish-toggle-thinking-display)
            (redisplay)
            (should (string-match-p
                     (regexp-quote
                      (pilish-gui-test--thinking-scroll-hidden-stub))
                     (buffer-string)))
            (should (>= (window-point win) (1- (point-max))))
            (should (>= (window-end win t) (1- (point-max))))
            (should (pilish-gui-test--window-substantially-filled-p win))
            (pilish--display-agent-start)
            (pilish--display-message-delta "Streaming tail line 01\n")
            (redisplay)
            (should (>= (window-point win) (1- (point-max))))
            (should (>= (window-end win t) (1- (point-max))))
            (pilish--display-message-delta "Streaming tail line 02\n")
            (pilish--display-agent-end)
            (redisplay)
            (should (>= (window-point win) (1- (point-max))))
            (should (>= (window-end win t) (1- (point-max))))
            (should (string-match-p "Streaming tail line 02" (buffer-string)))))
      (kill-buffer buf))))

(ert-deftest pilish-gui-test-thinking-display-toggle-keeps-context-window-usable ()
  "Toggling completed thinking keeps a non-tail chat window usable.
Point should stay on the same logical thinking block and the window should
remain substantially filled even when the collapsed tail is shorter."
  (let ((buf (get-buffer-create "*pi-gui-thinking-context*")))
    (unwind-protect
        (progn
          (switch-to-buffer buf)
          (pilish-gui-test--render-thinking-scroll-history buf 'visible)
          (let ((win (selected-window))
                block-before)
            (goto-char (point-min))
            (should (search-forward "Thinking detail 25" nil t))
            (beginning-of-line)
            (recenter 10)
            (redisplay)
            (setq block-before
                  (pilish-gui-test--window-thinking-block-order win))
            (should block-before)
            (should (pilish-gui-test--window-substantially-filled-p win))
            (should (equal "> Thinking detail 25"
                           (pilish-gui-test--window-current-line win)))
            (pilish-toggle-thinking-display)
            (redisplay)
            (should (string-match-p
                     (regexp-quote
                      (pilish-gui-test--thinking-scroll-hidden-stub))
                     (buffer-string)))
            (should (equal (car (split-string (pilish-gui-test--thinking-scroll-hidden-stub) "\n"))
                           (pilish-gui-test--window-current-line win)))
            (should (equal block-before
                           (pilish-gui-test--window-thinking-block-order win)))
            (should (pilish-gui-test--window-substantially-filled-p win))))
      (kill-buffer buf))))

(ert-deftest pilish-gui-test-thinking-display-toggle-expands-same-block-from-hidden-stub ()
  "Expanding a hidden thinking stub restores the same logical block.
Point should land back on the same completed-thinking block rather than an
unrelated raw offset in the conversation."
  (let ((buf (get-buffer-create "*pi-gui-thinking-expand*")))
    (unwind-protect
        (progn
          (switch-to-buffer buf)
          (pilish-gui-test--render-thinking-scroll-history buf 'hidden)
          (let ((win (selected-window))
                block-before)
            (goto-char (point-min))
            (should (search-forward
                     (pilish-gui-test--thinking-scroll-hidden-stub)
                     nil t))
            (goto-char (match-beginning 0))
            (recenter 10)
            (redisplay)
            (setq block-before
                  (pilish-gui-test--window-thinking-block-order win))
            (should block-before)
            (should (equal (car (split-string (pilish-gui-test--thinking-scroll-hidden-stub) "\n"))
                           (pilish-gui-test--window-current-line win)))
            (pilish-toggle-thinking-display)
            (redisplay)
            (should (string-match-p "Thinking detail 25" (buffer-string)))
            (should (equal block-before
                           (pilish-gui-test--window-thinking-block-order win)))
            (should (string-match-p
                     "^> Thinking detail [0-9][0-9]$"
                     (pilish-gui-test--window-current-line win)))
            (should (pilish-gui-test--window-substantially-filled-p win))))
      (kill-buffer buf))))

(ert-deftest pilish-gui-test-thinking-display-toggle-restores-each-visible-window ()
  "Toggling completed thinking preserves each visible window's own context.
The tail window should stay at the end, while the context window keeps its
logical block and should not start following later streamed output."
  (let ((buf (get-buffer-create "*pi-gui-thinking-multi-window*")))
    (unwind-protect
        (progn
          (delete-other-windows)
          (switch-to-buffer buf)
          (pilish-gui-test--render-thinking-scroll-history buf 'visible)
          (let* ((tail-win (selected-window))
                 (context-win (split-window-below)))
            (set-window-buffer context-win buf)
            (with-selected-window tail-win
              (goto-char (point-max))
              (recenter -1)
              (redisplay))
            (with-selected-window context-win
              (goto-char (point-min))
              (should (search-forward "Thinking detail 25" nil t))
              (beginning-of-line)
              (recenter 8)
              (redisplay))
            (let ((context-line-before
                   (pilish-gui-test--window-current-line context-win))
                  context-start-after-toggle)
              (with-selected-window tail-win
                (pilish-toggle-thinking-display))
              (redisplay)
              (should (eq (selected-window) tail-win))
              (should (>= (window-point tail-win) (1- (with-current-buffer buf (point-max)))))
              (should (>= (window-end tail-win t)
                          (1- (with-current-buffer buf (point-max)))))
              (should (pilish-gui-test--window-substantially-filled-p tail-win))
              (should (equal "> Thinking detail 25" context-line-before))
              (should (equal (car (split-string (pilish-gui-test--thinking-scroll-hidden-stub) "\n"))
                             (pilish-gui-test--window-current-line context-win)))
              (should (pilish-gui-test--window-substantially-filled-p context-win))
              (setq context-start-after-toggle (window-start context-win))
              (with-current-buffer buf
                (pilish--display-agent-start)
                (pilish--display-message-delta "Dual window tail line\n"))
              (redisplay)
              (should (>= (window-point tail-win) (1- (with-current-buffer buf (point-max)))))
              (should (>= (window-end tail-win t)
                          (1- (with-current-buffer buf (point-max)))))
              (should (= context-start-after-toggle (window-start context-win)))
              (should (equal (car (split-string (pilish-gui-test--thinking-scroll-hidden-stub) "\n"))
                             (pilish-gui-test--window-current-line context-win))))))
      (kill-buffer buf))))

(ert-deftest pilish-gui-test-table-resize-refreshes-hot-tail-only ()
  "Resizing rewraps hot tables only and preserves context below the table."
  (pilish-gui-test-with-fresh-session
    (:backend fake :fake-scenario "prompt-lifecycle")
    (let* ((chat-buf (plist-get pilish-gui-test--session :chat-buffer))
           (frame (selected-frame))
           (orig-width (frame-width))
           chat-win
           initial-chat-width
           (cold-table
            "| Feature | Notes |\n|---------|-------|\n| Cold history | This older table was wrapped at the original wide width and should stay frozen after resize |\n")
           (hot-table
            "| Feature | Notes |\n|---------|-------|\n| Hot tail | This recent table should rewrap when the window narrows so the columns remain readable |\n")
           cold-before
           hot-before
           cold-start
           hot-start
           filler-start)
      (unwind-protect
          (progn
            (with-current-buffer chat-buf
              (let ((inhibit-read-only t))
                (erase-buffer)
                (insert "You · 10:00\n===========\n")
                (setq cold-start (point))
                (insert cold-table "\nAssistant\n=========\nRecent reply\n\nYou · 10:05\n===========\n")
                (setq hot-start (point))
                ;; Terminate the Markdown table before adding scrollable context.
                ;; Without the blank line, tree-sitter treats every filler line
                ;; as a lazy continuation row inside one giant table.
                (insert hot-table "\n")
                (setq filler-start (point))
                (dotimes (i 80)
                  (insert (format "filler line %d\n" i))))
              (font-lock-ensure)
              (setq chat-win (pilish-gui-test-chat-window)
                    initial-chat-width (window-width chat-win))
              (pilish--decorate-tables-in-region
               (point-min) (point-max) initial-chat-width)
              (move-marker pilish--hot-tail-start hot-start)
              (setq cold-before
                    (pilish-gui-test--table-display-strings
                     cold-start hot-start)
                    hot-before
                    (pilish-gui-test--table-display-strings
                     hot-start filler-start))
              (should cold-before)
              (should hot-before)
              (should-not
               (pilish-gui-test--table-display-strings
                filler-start (point-max))))
            (redisplay)
            (pilish-gui-test-scroll-up 20)
            (let ((line-before (pilish-gui-test-top-line-number)))
              (set-frame-size frame (- orig-width 30) (frame-height))
              (redisplay)
              (unless (pilish-test-wait-until
                       (lambda ()
                         (< (window-width chat-win) initial-chat-width))
                       2 0.05)
                (ert-skip
                 (format
                  (concat "Window manager did not honor resize request from "
                          "frame width %d to %d: chat window width %d is not "
                          "narrower than its initial width %d")
                  orig-width (- orig-width 30)
                  (window-width chat-win) initial-chat-width)))
              ;; X11 can report the new width while a synchronous ERT body has
              ;; not re-entered the command-loop redisplay that delivers this
              ;; buffer-local hook.  Exercise our registered callback in the
              ;; same selected-window context Emacs documents for the hook.
              (with-selected-window chat-win
                (should
                 (memq #'pilish--maybe-refresh-hot-tail-tables
                       window-configuration-change-hook))
                (run-hooks 'window-configuration-change-hook)
                (should (= pilish--last-table-display-width
                           (pilish--chat-window-width))))
              (should-not
               (equal hot-before
                      (pilish-gui-test--table-display-strings
                       hot-start filler-start)))
              (should (equal cold-before
                             (pilish-gui-test--table-display-strings
                              cold-start hot-start)))
              (should (= line-before (pilish-gui-test-top-line-number)))))
        (set-frame-size frame orig-width (frame-height))
        (redisplay)))))

(ert-deftest pilish-gui-test-table-kill-line-moves-cursor-to-visual-end ()
  (let ((buf (get-buffer-create "*pi-gui-table-kill-line*")))
    (unwind-protect
        (progn
          (switch-to-buffer buf)
          (pilish-chat-mode)
          (remove-hook 'window-configuration-change-hook
                       #'pilish--maybe-refresh-hot-tail-tables t)
          (let ((inhibit-read-only t))
            (insert "before\n"
                    "| Name | Description |\n"
                    "|------|-------------|\n"
                    "| Auth | OAuth2 with refresh tokens and renewal |\n"
                    "| Other | short |\n"
                    "after\n"))
          (font-lock-ensure)
          (pilish--decorate-tables-in-region (point-min) (point-max) 30)
          (goto-char (point-min))
          (search-forward "| Auth |")
          (let* ((window (selected-window))
                 (raw-before (buffer-substring-no-properties
                              (point-min) (point-max)))
                 (row-start (line-beginning-position))
                 (row-end (line-end-position))
                 (overlay (cl-find-if
                           (lambda (candidate)
                             (and (overlay-get candidate 'pilish-table-display)
                                  (= (overlay-start candidate) row-start)))
                           (overlays-in row-start (1+ row-start))))
                 (display-lines (and overlay
                                     (split-string
                                      (string-trim-right
                                       (overlay-get overlay 'display) "\n+")
                                      "\n")))
                 (expected-copy (buffer-substring-no-properties (point) row-end))
                 before-y after-y)
            (should (> (length display-lines) 1))
            (redisplay)
            (setq before-y (cdr (posn-x-y (posn-at-point (point) window))))
            (let ((kill-read-only-ok t)
                  (kill-ring nil)
                  (kill-ring-yank-pointer nil)
                  (last-command nil))
              (execute-kbd-macro (kbd "C-k"))
              (should (= (point) row-end))
              (should (equal (current-kill 0) expected-copy)))
            (redisplay)
            (setq after-y (cdr (posn-x-y (posn-at-point (point) window))))
            (should (= (point) row-end))
            (should (> after-y before-y))
            (should (equal raw-before
                           (buffer-substring-no-properties
                            (point-min) (point-max))))))
      (kill-buffer buf))))

;;;; Content Tests

(ert-deftest pilish-gui-test-tool-result-image-has-real-display-property ()
  "A real PNG result inserts an image display property in graphical Emacs."
  (unless (and (display-images-p) (image-type-available-p 'png))
    (ert-skip "This Emacs display cannot render PNG images"))
  (let ((buffer (get-buffer-create "*pi-gui-image-preview*")))
    (unwind-protect
        (progn
          (switch-to-buffer buffer)
          (pilish-chat-mode)
          (let ((block (pilish--display-tool-start
                        "generate" nil "gui-image")))
            (pilish--display-tool-end
             "generate" nil
             '((:type "image"
                :mimeType "image/png"
                :data "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAADklEQVR4nGP4z8DwHwQBEPgD/U6VwW8AAAAASUVORK5CYII="))
             nil nil block))
          (redisplay)
          (let* ((position
                  (text-property-any (point-min) (point-max)
                                     'pilish-image-preview t))
                 (display (and position
                               (get-text-property position 'display)))
                 (size (and display (image-size display t))))
            (should position)
            (should (eq 'image (car-safe display)))
            (should (consp size))
            (should (> (car size) 0))
            (should (> (cdr size) 0))))
      (kill-buffer buffer))))

(ert-deftest pilish-gui-test-startup-logo-renders-real-image ()
  "The startup heading renders the real SVG logo on image-capable displays.
The 1.5em image glyph makes the heading row taller than a text row and
pushes the heading text right of the logo box."
  (unless (and (display-images-p) (image-type-available-p 'svg))
    (ert-skip "This Emacs display cannot render SVG images"))
  (let ((buffer (get-buffer-create "*pi-gui-startup-logo*")))
    (unwind-protect
        (progn
          (switch-to-buffer buffer)
          (pilish-chat-mode)
          (let ((inhibit-read-only t))
            (insert (pilish--format-startup-header))
            (font-lock-ensure)
            (goto-char (point-min))
            (set-window-start (selected-window) (point-min))
            (redisplay)
            (should (get-text-property 1 'line-prefix))
            ;; A rendered 1.5em image makes this row taller than a text row.
            (should (> (line-pixel-height) (frame-char-height)))
            ;; Heading text starts right of the logo box plus gap.
            (should (> (car (posn-x-y (posn-at-point (point-min))))
                       (frame-char-width)))))
      (kill-buffer buffer))))

(ert-deftest pilish-gui-test-read-svg-has-real-display-property ()
  "A complete standalone SVG returned by read renders graphically."
  (unless (and (display-images-p) (image-type-available-p 'svg))
    (ert-skip "This Emacs display cannot render SVG images"))
  (let ((buffer (get-buffer-create "*pi-gui-svg-preview*"))
        (source
         "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"2\" height=\"1\"><rect width=\"2\" height=\"1\" fill=\"#369\"/></svg>"))
    (unwind-protect
        (progn
          (switch-to-buffer buffer)
          (pilish-chat-mode)
          (pilish--display-tool-end
           "read" '(:path "/missing/returned.svg")
           (list (list :type "text" :text source)) nil nil)
          (redisplay)
          (let* ((position
                  (text-property-any (point-min) (point-max)
                                     'pilish-image-preview t))
                 (display (and position
                               (get-text-property position 'display)))
                 (size (and display (image-size display t))))
            (should position)
            (should (eq 'image (car-safe display)))
            (should (consp size))
            (should (> (car size) 0))
            (should (> (cdr size) 0))))
      (kill-buffer buffer))))

(ert-deftest pilish-gui-test-content-tool-output-shown ()
  "Test that fake-backed tool output appears in chat and in the tool block."
  (pilish-gui-test-with-fresh-session
    (:backend fake :fake-scenario "tool-read")
    (pilish-gui-test-send "Use the fake read tool")
    (should (pilish-gui-test-chat-contains "read /tmp/fake-tool.txt"))
    (should (pilish-gui-test-chat-text-in-tool-block-p "fake tool output"))
    (should (pilish-gui-test-chat-contains "Tool finished"))))

(ert-deftest pilish-gui-test-tool-overlay-bounded ()
  "Test that the tool overlay stops before later assistant text.
Regression: `pilish--tool-overlay-finalize' must replace the
rear-advance overlay before assistant text continues after the tool block."
  (pilish-gui-test-with-fresh-session
    (:backend fake :fake-scenario "tool-read")
    (pilish-gui-test-send "Use the fake read tool")
    (with-current-buffer (plist-get pilish-gui-test--session :chat-buffer)
      (goto-char (point-min))
      (search-forward "fake tool output")
      (let* ((tool-pos (match-beginning 0))
             (tool-overlay (seq-find
                            (lambda (ov) (overlay-get ov 'pilish-tool-block))
                            (overlays-at tool-pos))))
        (should tool-overlay))
      (goto-char (point-min))
      (search-forward "Tool finished")
      (let* ((assistant-pos (match-beginning 0))
             (tool-overlay (seq-find
                            (lambda (ov) (overlay-get ov 'pilish-tool-block))
                            (overlays-at assistant-pos))))
        (should-not tool-overlay)))))

;;;; Extension Command Tests

(ert-deftest pilish-gui-test-extension-command-returns-to-idle ()
  "Fake extension command without a visible turn returns to idle."
  (pilish-gui-test-with-fresh-session
    (:backend fake :fake-scenario "extension-noop")
    (pilish-gui-test-send "/test-noop" t)
    (should (pilish-gui-test-wait-for-idle 2))))

(ert-deftest pilish-gui-test-extension-custom-message-displayed ()
  "Fake extension command displays a custom message in chat."
  (pilish-gui-test-with-fresh-session
    (:backend fake :fake-scenario "extension-message")
    (pilish-gui-test-send "/test-message")
    (should (pilish-gui-test-chat-contains "Test message from extension"))))

(ert-deftest pilish-gui-test-extension-confirm-response-displayed ()
  "Fake extension confirm response triggers the displayed follow-up message."
  (pilish-gui-test-with-fresh-session
    (:backend fake :fake-scenario "extension-confirm")
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_prompt) t)))
      (pilish-gui-test-send "/test-confirm")
      (should (pilish-gui-test-chat-contains "CONFIRMED")))))

;;;; Tool Toggle Tests

(ert-deftest pilish-gui-test-tool-toggle-expand-collapse-cycle ()
  "Bottom controls accept TAB, RET and native margin hits at standard widths.
Capture text/image ordering, completed thinking and both cold projections."
  (require 'pilish-arguments-test)
  (let ((width (frame-width)) (height (frame-height))
        (pilish-tool-preview-lines 2))
    (unwind-protect
        (dolist (columns '(104 54))
          (set-frame-size nil columns 45)
          (sit-for 0.1)
          (let ((buf (generate-new-buffer " *pilish-gui-bottom-controls*")))
            (unwind-protect
                (save-window-excursion
                  (delete-other-windows)
                  (switch-to-buffer buf)
                  (pilish-chat-mode)
                  (setq pilish--thinking-display 'hidden)
                  (pilish--render-history-thinking "\nPlan the work\n\n\nCheck the result\n\n")
                  (let* ((block (pilish--display-tool-start "read" '(:path "/tmp/test.txt") "root"))
                         (overlay (pilish--tool-block-overlay block))
                         (window (selected-window)))
                    (pilish--display-tool-end
                     "read" '(:path "/tmp/test.txt")
                     (list (list :type "text" :text
                                 (mapconcat (lambda (n) (format "Line %02d of file" n))
                                            (number-sequence 1 20) "\n"))
                           (list :type "image" :mimeType "image/png"
                                 :data (pilish-test--prompt-image-base64 'png)))
                     nil nil block)
                    (cl-labels
                        ((footer ()
                           (goto-char (button-start (pilish--find-toggle-button-in-region
                                                     (overlay-start overlay) (overlay-end overlay)))))
                         (capture (state)
                           (goto-char (point-min))
                           (set-window-start window (point-min) t)
                           (redisplay t)
                           (pilish-gui-test--large-evidence
                            (format "bottom-%d-%s" columns state)
                            (list :width (window-body-width) :state state
                                  :raw (buffer-substring-no-properties (point-min) (point-max))
                                  :visible (pilish-arguments-test--visible-text)
                                  :window-start (window-start) :point (point)
                                  :package-user-dir package-user-dir :window-system window-system
                                  :render-library (symbol-file 'pilish--insert-tool-output-section)))))
                      (font-lock-ensure)
                      (should-not (string-match-p "Line 20" (buffer-string)))
                      (footer)
                      (should (looking-at-p "… 18 more lines"))
                      (should (equal (pilish-arguments-test--gutter (point)) "▸"))
                      (should (> (point) (text-property-any (point-min) (point-max)
                                                           'pilish-image-preview t)))
                      (should-not (pilish--file-target-at-point))
                      (should (pilish-gui-test--tool-margin-position window (point)))
                      (capture "collapsed")
                      (footer)
                      (execute-kbd-macro (kbd "<tab>"))
                      (should (string-match-p "Line 20" (buffer-string)))
                      (footer)
                      (should (looking-at-p "Show less"))
                      (should (equal (pilish-arguments-test--gutter (point)) "▾"))
                      (capture "expanded")
                      (footer)
                      (let ((hit (pilish-gui-test--tool-margin-position window (point))))
                        (should hit)
                        (pilish--disclosure-click (list 'mouse-1 hit)))
                      (should-not (string-match-p "Line 20" (buffer-string)))
                      ;; Re-expansion from the newly shortened block must remain local.
                      (execute-kbd-macro (kbd "TAB"))
                      (should (string-match-p "Line 20" (buffer-string)))
                      (footer)
                      (execute-kbd-macro (kbd "RET"))
                      (should-not (string-match-p "Line 20" (buffer-string)))
                      (footer)
                      (execute-kbd-macro (kbd "RET"))
                      (should (string-match-p "Line 20" (buffer-string)))
                      ;; Thinking's normalized three source lines conceal two, not
                      ;; the extra input blank lines or the continuation row.
                      (goto-char (point-min))
                      (re-search-forward "^… 2 more lines$")
                      (beginning-of-line)
                      (should (get-text-property (point) 'pilish-thinking-footer))
                      (let ((hit (pilish-gui-test--tool-margin-position window (point))))
                        (should hit)
                        (pilish--disclosure-click (list 'mouse-1 hit)))
                      (goto-char (point-min))
                      (re-search-forward "^Show less$")
                      (beginning-of-line)
                      (should (get-text-property (point) 'pilish-thinking-footer))
                      (capture "thinking-expanded")
                      (re-search-forward "^Show less$")
                      (beginning-of-line)
                      (execute-kbd-macro (kbd "RET"))
                      (should-not (string-match-p "^> Check the result" (buffer-string)))
                      (let ((other (pilish--display-tool-start "read" '(:path "/tmp/second.txt") "other")))
                        (pilish--display-tool-end "read" '(:path "/tmp/second.txt")
                                                  [(:type "text" :text "A\nB\nC\nD")] nil nil other)
                        (pilish--cool-completed-tool-blocks
                         (list overlay (pilish--tool-block-overlay other))))
                      (should (string-match-p "Line 20" (buffer-string)))
                      (should-not (string-match-p "Show less\\|^Output$" (buffer-string)))
                      (should-not (pilish--tool-block-output-view block))
                      (let ((start (text-property-not-all (point-min) (point-max) 'pilish-cold-tool-block nil)))
                        (should-not (text-property-not-all start (point-max) 'pilish-tool-toggle nil))
                        (should-not (text-property-not-all start (point-max) 'pilish-disclosure-hit nil)))
                      (capture "cooled"))))
              (when (buffer-live-p buf)
                (with-current-buffer buf (set-buffer-modified-p nil))
                (kill-buffer buf)))))
      (set-frame-size nil width height)
      (sit-for 0.1))))

(ert-deftest pilish-gui-test-saved-button-keyboard ()
  "Saved-name GUI TAB folds locally without changing RET's captured target."
  (require 'pilish-arguments-test)
  (dolist (key '("<tab>" "C-i"))
    (ert-info ((format "key=%s" key))
      (pilish-arguments-test--saved-button-keyboard (kbd key)))))

(ert-deftest pilish-gui-test-output-button-keyboard-ordinary ()
  "Native <tab> on an ordinary bottom control toggles locally, as does RET."
  (require 'pilish-arguments-test)
  (dolist (key '("<tab>" "C-i"))
    (ert-info ((format "key=%s" key))
      (pilish-arguments-test--output-button-keyboard 'ordinary (kbd key)))))

(ert-deftest pilish-gui-test-output-button-keyboard-compound ()
  "Native <tab> on a compound bottom control toggles locally, as does RET."
  (require 'pilish-arguments-test)
  (dolist (key '("<tab>" "C-i"))
    (ert-info ((format "key=%s" key))
      (pilish-arguments-test--output-button-keyboard 'compound (kbd key)))))

(ert-deftest pilish-gui-test-output-button-keyboard-child ()
  "Native <tab> on a child bottom control keeps its argument fold independent."
  (require 'pilish-arguments-test)
  (dolist (key '("<tab>" "C-i"))
    (ert-info ((format "key=%s" key))
      (pilish-arguments-test--output-button-keyboard 'child (kbd key)))))

;;;; Streaming Fontification Tests

(ert-deftest pilish-gui-test-streamed-reference-definition-refreshes-distant-link ()
  "A streamed definition refontifies an offscreen reference link."
  (pilish-gui-test-with-fresh-session
    (:backend fake :fake-scenario "prompt-lifecycle")
    (let* ((chat (plist-get pilish-gui-test--session :chat-buffer))
           (window (pilish-gui-test-chat-window))
           doc-position)
      (with-current-buffer chat
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert "See [Doc][id].\n\n")
          (dotimes (i (+ 20 (* 2 (window-body-height window))))
            (insert (format "Filler line %03d.\n" i)))
          (insert "\n"))
        (goto-char (point-min))
        (search-forward "Doc")
        (setq doc-position (match-beginning 0))
        (setq pilish--assistant-header-shown nil)
        (pilish--handle-display-event '(:type "agent_start"))
        (pilish--handle-display-event
         '(:type "message_start" :message (:role "assistant"))))
      (with-selected-window window
        (goto-char (point-min))
        (set-window-start window (point-min))
        (redisplay t)
        (should-not (pos-visible-in-window-p (point-max) window))
        (should (eq t (get-text-property doc-position 'fontified)))
        (should-not (button-at doc-position)))
      (with-selected-window window
        (goto-char (point-max))
        (recenter -1)
        (redisplay t)
        (should-not (pos-visible-in-window-p doc-position window)))
      (with-current-buffer chat
        (pilish--handle-display-event
         '(:type "message_update"
           :assistantMessageEvent
           (:type "text_delta" :delta "[id]: https://added.example\n")))
        (pilish--flush-stream-deltas))
      (with-selected-window window
        (goto-char doc-position)
        (set-window-start window (point-min))
        (redisplay t)
        (let ((button (button-at doc-position)))
          (should button)
          (should (equal "https://added.example"
                         (button-get button 'help-echo))))))))

(ert-deftest pilish-gui-test-streaming-no-fences ()
  "Streaming write content shows no fence markers to the user.
Fences exist in the buffer for tree-sitter parsing, but
`md-ts-hide-markup' makes them invisible.  Uses a displayed
buffer (jit-lock active) to verify under real GUI conditions."
  (let ((buf (get-buffer-create "*pi-gui-fontify-test*")))
    (unwind-protect
        (progn
          (switch-to-buffer buf)
          (pilish-chat-mode)
          (pilish--handle-display-event '(:type "agent_start"))
          (pilish--handle-display-event
           '(:type "message_start" :message (:role "assistant" :content [])))
          (pilish-test--send-assistant-message-update
           '(:type "toolcall_start" :contentIndex 0
             :id "call_1" :toolName "write"))
          (redisplay)
          (pilish-test--send-assistant-message-update
           '(:type "toolcall_delta" :contentIndex 0
             :delta "{\"path\":\"/tmp/test.py\",\"content\":\"def hello():\\n    return 42\\n\"}"))
          (pilish--flush-stream-deltas)
          (font-lock-ensure)
          ;; Fences are in the buffer (for tree-sitter) but invisible
          (let ((visible (pilish--visible-text
                          (point-min) (point-max))))
            (should-not (string-match-p "```" visible)))
          ;; Content is present with syntax faces
          (goto-char (point-min))
          (should (search-forward "def" nil t))
          (let ((face (get-text-property (match-beginning 0) 'face)))
            (should (or (eq face 'font-lock-keyword-face)
                        (and (listp face)
                             (memq 'font-lock-keyword-face face))))))
      (kill-buffer buf))))

(defun pilish-gui-test--display-prefix (line width)
  "Return LINE's prefix occupying the first WIDTH display columns."
  (let ((chars nil) (w 0))
    (catch 'done
      (dotimes (i (length line))
        (let ((cw (string-width (substring line i (1+ i)))))
          (when (> (+ w cw) width) (throw 'done nil))
          (push (aref line i) chars)
          (setq w (+ w cw)))))
    (concat (nreverse chars))))

(ert-deftest pilish-gui-test-session-browser-narrow-visibility ()
  "All-projects identity and live status stay visible on a real narrow
window.
Renders the session browser in a dedicated buffer and frame whose
window body is exactly 32 columns wide — the text area of a
53-column terminal next to the browser's 21 columns of combined margins
\\(`window-body-width' already excludes margins) — and checks
visibility with display widths (`string-width'), not character
offsets.  Adversarial fixtures: two projects sharing a long common
prefix (ordinal-front tokens), a wide-character project name, a
depth-18 threaded connector with the live marker behind it, and long
identical titles.  On every row the bounded token field and the
two-column live field must end inside the visible columns, with
`truncate-lines' on and no horizontal scroll; empty-state hint lines
keep their recovery keys on screen too."
  (let* ((long-title (make-string 60 ?x))
         (deep-dir "/home/u/long-common-prefix-abcdef")
         (token-width 16)
         (items
          (append
           (list (list :path "/a/one.jsonl" :cwd (concat deep-dir "/app")
                       :name (concat "One " long-title)
                       :messageCount 2 :modified "2026-03-11T10:00:00Z")
                 (list :path "/a/two.jsonl"
                       :cwd "/home/u/long-common-prefix-abcdeg/app"
                       :name (concat "Two " long-title)
                       :messageCount 4 :modified "2026-03-11T11:00:00Z")
                 (list :path "/a/wide.jsonl" :cwd "/home/u/\u4e2d\u6587\u9879\u76ee"
                       :name (concat "Wide " long-title)
                       :messageCount 1 :modified "2026-03-11T12:00:00Z")
                 ;; A malformed row: recorded cwd is rejected, but the
                 ;; bounded field is still reserved for it.
                 (list :path "/a/broken.jsonl" :cwd "/a\0b"
                       :name (concat "Broken " long-title)
                       :messageCount 1 :modified "2026-03-11T13:00:00Z"))
           ;; A depth-18 chain under the first project whose last
           ;; child is the live session: its connector alone would
           ;; far exceed the body.
           (let ((chain nil) (parent "/a/one.jsonl"))
             (dotimes (i 18)
               (let ((path (format "/a/deep-%02d.jsonl" i)))
                 (push (list :path path :cwd (concat deep-dir "/app")
                             :name (format "Deep %02d" i)
                             :parentSessionPath parent
                             :messageCount 1
                             :modified "2026-03-11T10:00:00Z")
                       chain)
                 (setq parent path)))
             (nreverse chain))))
         (live-line-title "Deep 17")
         frame win buffer chat-buf proc)
    ;; Enter cleanup protection before acquiring any GUI/process
    ;; resource, so a failure halfway through setup cannot leak those
    ;; already created.
    (unwind-protect
        (progn
          (setq frame (make-frame '((width . 53) (height . 22))))
          (setq win (frame-selected-window frame))
          (setq buffer (generate-new-buffer " *pilish-gui-narrow*"))
          (setq chat-buf
                (generate-new-buffer " *pilish-gui-narrow-chat*"))
          (setq proc (start-process "pilish-gui-narrow" nil "sleep" "30"))
          (set-process-query-on-exit-flag proc nil)
          (process-put proc 'pilish-chat-buffer chat-buf)
          (with-current-buffer chat-buf
            (setq pilish--process proc
                  pilish--state
                  (list :session-file "/a/deep-17.jsonl")))
          (set-window-buffer win buffer)
          (with-current-buffer buffer
            (pilish-session-browser-mode)
            ;; Bounded resize: let the mode's window-configuration
            ;; hook apply the right margin, then adjust the frame
            ;; until the body is exactly 32 columns; the assertion
            ;; catches an oscillating or stuck body.
            (redisplay)
            (let ((attempts 0))
              (while (not (= 32 (window-body-width win)))
                (cl-assert (< (cl-incf attempts) 60) t
                           "body width stuck at %d"
                           (window-body-width win))
                (set-frame-width
                 frame (+ (frame-width frame)
                          (- 32 (window-body-width win))))
                (redisplay)))
            (setq pilish--session-browser-scope 'all
                  pilish--session-browser-items items
                  pilish--session-browser-view 'threaded)
            (pilish--session-browser-rerender)
            (redisplay)
            (let* ((usable (window-body-width win))
                   (rows
                    (seq-remove
                     (lambda (line)
                       (or (string-empty-p line)
                           (not (string-match-p
                                 "One x\\|Two x\\|Wide x\\|Broken x\\|Deep "
                                 line))))
                     (split-string
                      (buffer-substring-no-properties
                       (point-min) (point-max))
                      "\n"))))
              (should (= usable 32))
              (should truncate-lines)
              (should (zerop (window-hscroll win)))
              (should (= (length rows) (length items)))
              (dolist (line rows)
                ;; Token field is exactly the fixed display width on
                ;; every row, and the two-column live field follows at
                ;; one constant column before any unbounded content.
                (let* ((tok (pilish-gui-test--display-prefix
                             line token-width))
                       (marker
                        (substring-no-properties
                         line (length tok) (+ (length tok) 2))))
                  (should (= (string-width tok) token-width))
                  (should (member marker '("\u25cf " "  ")))
                  ;; The visible invariant: identity plus live field
                  ;; end inside the narrow body.
                  (should (<= (+ token-width 2) usable))))
              ;; The malformed row keeps the placeholder field —
              ;; bounded and truthful even behind a long title.
              (let ((broken (cl-find "Broken " rows :test #'string-match-p)))
                (should broken)
                (should (string-prefix-p
                         "?"
                         (string-trim-right
                          (pilish-gui-test--display-prefix
                           broken token-width)))))
              ;; The live marker really is on the depth-18 child.
              (let ((live-line (cl-find live-line-title rows
                                        :test #'string-match-p)))
                (should live-line)
                (should (string-prefix-p
                         "\u25cf "
                         (substring-no-properties
                          live-line
                          (length (pilish-gui-test--display-prefix
                                   live-line token-width))
                          (+ (length (pilish-gui-test--display-prefix
                                      live-line token-width))
                             2))))))
            ;; Empty state: every hint line fits the same narrow body.
            (setq pilish--session-browser-search-query "zzz-no-match"
                  pilish--session-browser-search-tokens '("zzz-no-match"))
            (pilish--session-browser-rerender)
            (redisplay)
            (goto-char (point-min))
            (while (< (point) (point-max))
              (should (<= (string-width
                           (buffer-substring-no-properties
                            (line-beginning-position) (line-end-position)))
                          (window-body-width win)))
              (forward-line 1))))
      (when (and proc (process-live-p proc))
        (delete-process proc))
      (when (buffer-live-p chat-buf)
        (kill-buffer chat-buf))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (when (and frame (frame-live-p frame))
        (delete-frame frame)))))

(ert-deftest pilish-gui-test-argument-two-window-row-geometry ()
  "TAB preserves the active screen row and the other reader's surviving row."
  (let ((chat (generate-new-buffer " *pilish-gui-arguments*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer chat)
          (pilish-chat-mode)
          (pilish--render-history-text
           (mapconcat (lambda (n) (format "Prelude %d" n)) (number-sequence 0 20) "\n"))
          (pilish--handle-display-event
           '(:type "tool_execution_start" :toolCallId "r" :toolName "custom"
             :args (:first "A1\nA2" :second "B1\nB2")))
          (pilish--handle-display-event
           '(:type "tool_execution_end" :toolCallId "r" :toolName "custom"
             :result (:content [(:type "text" :text "RESULT")])))
          (pilish--render-history-text
           (mapconcat (lambda (n) (format "Tail %d" n)) (number-sequence 0 60) "\n"))
          (let ((active (selected-window))
                (other (split-window-below)))
            (set-window-buffer other chat)
            (goto-char (point-min))
            (search-forward "second=")
            (set-window-point other (- (point) 4))
            (set-window-start other (line-beginning-position) t)
            (goto-char (point-min))
            (search-forward "first=")
            (goto-char (match-beginning 0))
            (set-window-start active (save-excursion (forward-line -3) (point)) t)
            (redisplay t)
            (let ((active-y (cdr (posn-x-y (posn-at-point (point) active))))
                  (other-y (cdr (posn-x-y (posn-at-point (window-point other) other)))))
              (dotimes (_ 2)
                (pilish-toggle-tool-section)
                (redisplay t)
                (should (= active-y (cdr (posn-x-y (posn-at-point (window-point active) active)))))
                (should (= other-y (cdr (posn-x-y (posn-at-point (window-point other) other)))))
                (save-excursion
                  (goto-char (point-min))
                  (search-forward "second=")
                  (should (= (window-point other) (- (point) 4)))
                  (should (= (window-start other) (line-beginning-position))))))))
      (when (buffer-live-p chat)
        (with-current-buffer chat (set-buffer-modified-p nil))
        (kill-buffer chat)))))

(ert-deftest pilish-gui-test-argument-child-output-two-window ()
  "Argument TAB keeps another native window on its unchanged child output line."
  (require 'pilish-arguments-test)
  (pilish-arguments-test--child-output-two-window))

(ert-deftest pilish-gui-test-missing-result-header-only-cooling ()
  "Missing-result history releases its completed overlay without adding output."
  (let ((chat (generate-new-buffer " *pilish-gui-missing-result*")))
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer chat)
          (pilish-chat-mode)
          (pilish--render-history-tool
           '(:type "toolCall" :id "missing" :name "codemode"
             :arguments (:code "return 'missing result';")) nil)
          (let* ((overlays (pilish--tool-block-overlays-in-region (point-min) (point-max)))
                 (overlay (car overlays))
                 (block (pilish--tool-block-from-overlay overlay))
                 (before (pilish--visible-text (point-min) (point-max))))
            (should (= (length overlays) 1))
            (should (pilish--completed-tool-overlay-p overlay))
            (pilish--cool-completed-tool-blocks overlays)
            (font-lock-flush)
            (font-lock-ensure)
            (redisplay t)
            (should-not (pilish--tool-block-overlays-in-region (point-min) (point-max)))
            (should-not (pilish--tool-block-argument-view block))
            (should-not (text-property-not-all (point-min) (point-max) 'pilish-argument-locator nil))
            (should (equal before (pilish--visible-text (point-min) (point-max))))))
      (when (buffer-live-p chat)
        (with-current-buffer chat (set-buffer-modified-p nil))
        (kill-buffer chat)))))

(ert-deftest pilish-gui-test-browser-disclosure-native-gutter ()
  "Browser gutter hits fold only their row and leave ordinary copy intact."
  (require 'pilish-browse-test)
  (dolist (mode '(pilish-session-browser-mode pilish-tree-browser-mode))
    (let ((buffer (generate-new-buffer " *pilish-gui-browser-gutter*")))
      (unwind-protect
          (save-window-excursion
            (delete-other-windows)
            (switch-to-buffer buffer)
            (pilish-test--browse-disclosure-fixture mode)
            (let* ((window (selected-window))
                   (parent (car pilish--browse-fold-rows))
                   (child (cadr pilish--browse-fold-rows))
                   (p (oref (plist-get parent :section) start))
                   (c (oref (plist-get child :section) start))
                   (source (buffer-substring-no-properties (point-min) (point-max))))
              (set-window-margins window 3 (if (eq mode 'pilish-session-browser-mode) 24 20))
              (goto-char p)
              (set-window-start window (point-min) t)
              (redisplay t)
              (let* ((pixel (pos-visible-in-window-p p window t))
                     (edge (window-pixel-edges window))
                     (inside (window-inside-pixel-edges window))
                     (y (+ (nth 1 edge) (cadr pixel) (/ (frame-char-height) 2)))
                     (hit (cl-loop for x from (car edge) below (car inside)
                                   for position = (posn-at-x-y x y (window-frame window) t)
                                   when (and position (eq (posn-area position) 'left-margin)
                                             (posn-string position))
                                   return position)))
                (should hit)
                (should (eq (key-binding (vector 'left-margin 'mouse-1)) #'pilish--disclosure-click))
                (dolist (kind '(double-mouse-1 double-mouse-2))
                  (should-not (eq (key-binding (vector 'left-margin kind)) #'magit-mouse-toggle-section)))
                (pilish--disclosure-click (list 'mouse-1 hit))
                (should (pilish--browse-folded-p (plist-get parent :value)))
                (should (invisible-p c))
                (pilish--disclosure-click (list 'mouse-1 hit))
                (should (pilish--browse-folded-p (plist-get parent :value)))
                (should (equal source (filter-buffer-substring (point-min) (point-max))))
                (let ((kill-ring nil) (kill-ring-yank-pointer nil))
                  (goto-char (point-min))
                  (push-mark (point-max) t t)
                  (execute-kbd-macro (kbd "M-w"))
                  (should (equal source (current-kill 0 t)))
                  (should-not (text-property-not-all 0 (length (current-kill 0 t))
                                                      'pilish-disclosure-hit nil (current-kill 0 t))))
                (goto-char p)
                (pilish-browse-toggle-fold)
                (redisplay t)
                (let* ((pixel (pos-visible-in-window-p c window t))
                       (blank (posn-at-x-y (1+ (car edge))
                                           (+ (nth 1 edge) (cadr pixel) (/ (frame-char-height) 2))
                                           (window-frame window) t)))
                  (should-not (posn-string blank))
                  (pilish--disclosure-click (list 'mouse-1 blank))
                  (should-not (pilish--browse-folded-p (plist-get parent :value)))))))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer))))))

(defun pilish-gui-test--tool-margin-position (window position &optional row-offset)
  "Return a native margin hit on WINDOW's POSITION plus ROW-OFFSET screen rows."
  (redisplay t)
  (let* ((pixel (pos-visible-in-window-p position window t))
         (inside (window-inside-pixel-edges window))
         (edges (window-pixel-edges window))
         (y (+ (nth 1 inside) (nth 1 pixel) (/ (frame-char-height) 2)
               (* (or row-offset 0) (frame-char-height)))))
    (cl-loop for x from (car edges) below (car inside)
             for hit = (posn-at-x-y x y (window-frame window) t)
             when (and hit (eq (posn-window hit) window)
                       (eq (posn-area hit) 'left-margin)
                       (posn-string hit))
             return hit)))

(ert-deftest pilish-gui-test-polish-tool-gutter-native-row-actions ()
  "Native margin rows invoke exact argument actions and ignore continuations."
  (require 'pilish-arguments-test)
  (let ((chat (generate-new-buffer " *pilish-gui-tool-gutter*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer chat)
          (pilish-chat-mode)
          (let ((window (selected-window)))
            (set-window-fringes window 0 0)
            (set-window-margins window 3 2)
            (pilish-arguments-test--execute
             "r" "bash" (list :command (concat "printf '" (make-string 180 ?x) "'\n  echo SECOND")) "OUT")
            (pilish-arguments-test--goto-text "printf")
            (let ((hit (pilish-gui-test--tool-margin-position window (point))))
              (should hit)
              (should (integerp (posn-point hit)))
              (pilish--disclosure-click (list 'mouse-1 hit))
              (let ((expanded (buffer-string)))
                (pilish--disclosure-click (list 'mouse-1 hit))
                (should (equal-including-properties expanded (buffer-string)))))
            (pilish-arguments-test--goto-text "printf")
            (should (string-match-p "  echo SECOND" (pilish-arguments-test--visible-text)))
            (should-not (pilish-gui-test--tool-margin-position window (point) 1))
            (let* ((edges (window-pixel-edges window))
                   (inside (window-inside-pixel-edges window))
                   (pixel (pos-visible-in-window-p (point) window t))
                   (y (+ (nth 1 inside) (nth 1 pixel) (/ (frame-char-height) 2)))
                   (blank (posn-at-x-y (1+ (car edges)) (- y (frame-char-height)) (window-frame window) t))
                   (continuation (posn-at-x-y (1+ (car edges)) (+ y (frame-char-height)) (window-frame window) t)))
              (should-not (posn-string blank))
              (pilish--disclosure-click (list 'mouse-1 blank))
              (pilish--disclosure-click (list 'mouse-1 continuation))
              (should (string-match-p "  echo SECOND" (pilish-arguments-test--visible-text))))
            (pilish-arguments-test--goto-text "SECOND")
            (should-not (pilish-gui-test--tool-margin-position window (point)))
            (pilish--cool-completed-tool-blocks (pilish-arguments-test--all-tool-overlays))
            (pilish-arguments-test--goto-text "printf")
            (should-not (pilish-gui-test--tool-margin-position window (point)))
            (should-not (pilish--toggle-tool-argument-at-point))
            (should (equal (window-margins window) '(3 . 2)))))
      (when (buffer-live-p chat)
        (with-current-buffer chat (set-buffer-modified-p nil))
        (kill-buffer chat)))))

(ert-deftest pilish-gui-test-polish-empty-first-row-native-gutter ()
  "Empty first argument lines keep a native value-row control without changing data."
  (require 'pilish-arguments-test)
  (let ((chat (generate-new-buffer " *pilish-gui-empty-tool-row*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer chat)
          (pilish-chat-mode)
          (pilish-arguments-test--execute "r" "bash" '(:command "\n  echo SECOND\nlast") "OUT")
          (pilish-arguments-test--goto-text "bash")
          (execute-kbd-macro (kbd "TAB"))
          (pilish-arguments-test--goto-text "bash")
          (let* ((start (text-property-any (point-min) (point-max) 'pilish-argument-value t))
                 (hit (pilish-gui-test--tool-margin-position (selected-window) start)))
            (should hit)
            (should-not (pilish-gui-test--tool-margin-position (selected-window) (point)))
            (should-not (pilish-gui-test--tool-margin-position (selected-window) (1+ start)))
            (pilish--disclosure-click (list 'mouse-1 hit))
            (should-not (string-match-p "SECOND" (pilish-arguments-test--visible-text)))))
      (when (buffer-live-p chat)
        (with-current-buffer chat (set-buffer-modified-p nil))
        (kill-buffer chat)))))

(ert-deftest pilish-gui-test-polish-compound-controls-share-native-gutter ()
  "Heading and bottom controls invoke their exact owners through native margins."
  (require 'pilish-arguments-test)
  (let ((chat (generate-new-buffer " *pilish-gui-compound-gutter*"))
        (pilish-tool-preview-lines 2))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer chat)
          (pilish-chat-mode)
          (pilish--handle-display-event
           '(:type "tool_execution_start" :toolCallId "r" :toolName "codemode"
             :args (:code "one();\ntwo();\nthree();\nfour();")))
          (dotimes (n 4)
            (pilish--handle-display-event
             (list :type "tool_execution_end" :toolCallId (format "c%d" n) :parentToolCallId "r"
                   :toolName "read" :result '(:content [(:type "text" :text "CHILD-ONE\nCHILD-TWO")]))))
          (pilish--handle-display-event
           '(:type "tool_execution_end" :toolCallId "r" :toolName "codemode"
             :result (:content [(:type "text" :text "ROOT-ONE\nROOT-TWO\nROOT-THREE\nROOT-FOUR")])))
          (let ((block (pilish--nested-tool-owner "r")))
            (dolist (section '(script output children (child . "c3")))
              (let* ((overlay (pilish--tool-block-overlay block))
                     (button (pilish--find-toggle-button-in-region (overlay-start overlay) (overlay-end overlay) section)))
                (should button)
                (goto-char (button-start button))
                (set-window-start (selected-window) (line-beginning-position) t)
                (let ((hit (pilish-gui-test--tool-margin-position (selected-window) (point))))
                  (should hit)
                  (pilish--disclosure-click (list 'mouse-1 hit)))
                (if (memq section '(script children))
                    (should (member section (pilish--tool-block-folds block)))
                  (should (eq 'all (pilish--tool-output-view-selection
                                    (pilish-test--output-view
                                     (pilish--find-toggle-button-in-region
                                      (overlay-start overlay) (overlay-end overlay) section))))))))
            (should (= 1 (pilish-test--count-matches "^Child calls" (buffer-string))))
            (should-not (string-match-p "[▸▾]" (buffer-string)))
            (pilish--cool-completed-tool-blocks (list (pilish--tool-block-overlay block)))
            (goto-char (point-min))
            (while (< (point) (point-max))
              (should-not (pilish-arguments-test--gutter (point)))
              (forward-char 1))))
      (when (buffer-live-p chat)
        (with-current-buffer chat (set-buffer-modified-p nil))
        (kill-buffer chat)))))

(ert-deftest pilish-gui-test-polish-tool-gutter-two-window-action ()
  "A second reader's exact margin control never acts in the selected input window."
  (require 'pilish-arguments-test)
  (let ((chat (generate-new-buffer " *pilish-gui-gutter-chat*"))
        (input (generate-new-buffer " *pilish-gui-gutter-input*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer chat)
          (pilish-chat-mode)
          (pilish-arguments-test--child "bash" '(:command "printf FIRST\n  printf SECOND" :timeout 10) "CHILD")
          (let* ((first (selected-window))
                 (second (split-window-right 28))
                 (input-window (split-window first -5 'below)))
            (set-window-buffer second chat)
            (set-window-margins first 3 2)
            (with-current-buffer input
              (pilish-input-mode)
              (insert "Unsent draft"))
            (set-window-buffer input-window input)
            (pilish-arguments-test--goto-text "printf FIRST")
            (set-window-start second (line-beginning-position) t)
            (let ((row (point))
                  (input-margins (window-margins input-window)))
              (set-window-point first (point-min))
              (select-window input-window)
              (let ((hit (pilish-gui-test--tool-margin-position second row)))
                (should hit)
                (pilish--disclosure-click (list 'mouse-1 hit)))
              (should (eq (selected-window) input-window))
              (should (equal (buffer-string) "Unsent draft"))
              (should (equal (window-margins input-window) input-margins))
              (should (equal (window-margins first) '(3 . 2)))
              (should (equal (window-margins second) '(1)))
              (should (= (window-point first) 1))
              (with-current-buffer chat
                (should (string-match-p "printf FIRST\n  printf SECOND" (pilish-arguments-test--visible-text)))
                (should (member '(argument "child" 0) (pilish--tool-block-folds (pilish--nested-tool-owner "root"))))))))
      (dolist (buffer (list chat input))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer))))))

(defun pilish-gui-test--initial-tool-transcript (command)
  "Render a compound transcript with COMMAND and all four controls in view."
  (setq-local pilish-tool-preview-lines 2 pilish-bash-preview-lines 2)
  (pilish--handle-display-event
   '(:type "tool_execution_start" :toolCallId "r" :toolName "codemode"
     :args (:code "one();\ntwo();\nthree();\nfour();")))
  (pilish--handle-display-event
   (list :type "tool_execution_start" :toolCallId "c" :parentToolCallId "r"
         :toolName "bash" :args (list :command command :timeout 10)))
  (pilish--handle-display-event
   '(:type "tool_execution_end" :toolCallId "c" :parentToolCallId "r" :toolName "bash"
     :result (:content [(:type "text" :text "CHILD-ONE\nCHILD-TWO\nCHILD-THREE") ])))
  (pilish--handle-display-event
   '(:type "tool_execution_end" :toolCallId "r" :toolName "codemode"
     :result (:content [(:type "text" :text "ROOT-ONE\nROOT-TWO\nROOT-THREE\nROOT-FOUR")])))
  (let ((block (pilish--nested-tool-owner "r")))
    (pilish--argument-toggle block '(argument "c" 0))
    block))

(defun pilish-gui-test--initial-tool-controls (block window)
  "Assert all four BLOCK controls have distinct native hits in WINDOW's initial view."
  (let* ((overlay (pilish--tool-block-overlay block))
         (start (overlay-start overlay)) (end (overlay-end overlay))
         (primary (text-property-any start end 'pilish-argument-value t))
         (positions (append
                     (mapcar (lambda (section)
                               (button-start (pilish--find-toggle-button-in-region start end section)))
                             '(script output))
                     (list primary
                           (button-start (pilish--find-toggle-button-in-region start end '(child . "c"))))))
         hits)
    (should (= (window-start window) (point-min)))
    (dolist (position positions)
      (let ((hit (pilish-gui-test--tool-margin-position window position)))
        (should hit)
        (should (integerp (posn-point hit)))
        (should (get-text-property (cdr (posn-string hit)) 'pilish-disclosure-hit (car (posn-string hit))))
        (push (cdr (posn-x-y hit)) hits)))
    (should (= (length (delete-dups hits)) 4))
    (let ((inside (window-inside-pixel-edges window))
          (edges (window-pixel-edges window)))
      (should
       (= 4 (cl-loop for y from (+ (nth 1 inside) (/ (frame-char-height) 2))
                     below (nth 3 inside) by (frame-char-height)
                     count (cl-loop for x from (car edges) below (car inside)
                                    for hit = (posn-at-x-y x y (window-frame window) t)
                                    thereis (and hit (eq (posn-window hit) window)
                                                 (eq (posn-area hit) 'left-margin) (posn-string hit)))))))
    (should (= (window-start window) (point-min)))
    primary))

(ert-deftest pilish-gui-test-correction-initial-view-hidden-wrapper-controls ()
  "Earlier hidden fences cannot swallow controls or the first value's indentation."
  (require 'pilish-arguments-test)
  (let ((chat (generate-new-buffer " *pilish-initial-tool-controls*"))
        (width (frame-width)) (height (frame-height)))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer chat)
          (pilish-chat-mode)
          (let ((block (pilish-gui-test--initial-tool-transcript "echo FIRST\n  echo SECOND\nlast")))
            (dolist (columns '(104 54))
              (set-frame-size nil columns 55)
              (sit-for 0.1)
              (goto-char (point-min))
              (set-window-start nil (point-min) t)
              (dotimes (_ 2)
                (font-lock-flush)
                (font-lock-ensure)
                (redisplay t)
                (let* ((primary (pilish-gui-test--initial-tool-controls block (selected-window)))
                       (pixel (pos-visible-in-window-p primary nil t)))
                  (should (= (car pixel) (* 2 (frame-char-width)))))
                (let ((before (copy-tree (pilish--tool-block-folds block))))
                  (dolist (section '(script output (argument "c" 0) (child . "c")))
                    (let* ((overlay (pilish--tool-block-overlay block))
                           (position (if (eq (car-safe section) 'argument)
                                         (text-property-any (overlay-start overlay) (overlay-end overlay) 'pilish-argument-value t)
                                       (button-start (pilish--find-toggle-button-in-region
                                                      (overlay-start overlay) (overlay-end overlay) section))))
                           (hit (pilish-gui-test--tool-margin-position (selected-window) position))
                           (output (when (or (eq section 'output) (eq (car-safe section) 'child))
                                     (pilish-test--output-view (button-at position))))
                           (selection (and output (pilish--tool-output-view-selection output))))
                      (pilish--disclosure-click (list 'mouse-1 hit))
                      (if output
                          (should-not (eq selection (pilish--tool-output-view-selection output)))
                        (should-not (equal before (pilish--tool-block-folds block))))
                      (if (eq (car-safe section) 'argument)
                          (pilish--argument-toggle block section)
                        (button-activate
                         (pilish--find-toggle-button-in-region (overlay-start overlay) (overlay-end overlay) section)))
                      (should (equal before (pilish--tool-block-folds block)))
                      (when output
                        (should (eq selection (pilish--tool-output-view-selection output)))))))))))
      (set-frame-size nil width height)
      (sit-for 0.1)
      (when (buffer-live-p chat)
        (with-current-buffer chat (set-buffer-modified-p nil))
        (kill-buffer chat)))))

(ert-deftest pilish-gui-test-correction-first-value-rows-and-two-windows ()
  "Empty, combining and wide first characters retain one glyph and exact data."
  (require 'pilish-arguments-test)
  (let ((width (frame-width)) (height (frame-height)))
    (unwind-protect
        (dolist (columns '(104 54))
          (set-frame-size nil columns 55)
          (sit-for 0.1)
          (dolist (command (list "\n  echo SECOND\nlast"
                                 (concat "écho 'first' " (make-string 150 ?x) "\n  echo SECOND\nlast")
                                 (concat "界 echo 'first' " (make-string 150 ?x) "\n  echo SECOND\nlast")))
            (let ((chat (generate-new-buffer " *pilish-first-tool-row*")))
              (unwind-protect
                  (save-window-excursion
                    (delete-other-windows)
                    (switch-to-buffer chat)
                    (pilish-chat-mode)
                    (let* ((block (pilish-gui-test--initial-tool-transcript command))
                           (first (selected-window))
                           (second (split-window-below 25)))
                      (font-lock-ensure)
                      (goto-char (point-min))
                      (set-window-start first (point-min) t)
                      (set-window-point first (point-min))
                      (let ((primary (text-property-any (point-min) (point-max) 'pilish-argument-value t)))
                        (set-window-start second primary t)
                        (set-window-point second primary)
                        (dotimes (_ 2)
                          (font-lock-flush)
                          (font-lock-ensure)
                          (redisplay t)
                          (pilish-gui-test--initial-tool-controls block first)
                          (dolist (window (list first second))
                            (should (pilish-gui-test--tool-margin-position window primary))
                            (should-not (pilish-gui-test--tool-margin-position window (+ primary 1 (string-match-p "\n" command))))
                            (should (= (car (pos-visible-in-window-p primary window t)) (* 2 (frame-char-width)))))
                          (should (equal (buffer-substring-no-properties primary (+ primary (length command))) command)))
                        (let ((copy (pilish--filter-buffer-substring (point-min) (point-max))))
                          (delete-other-windows first)
                          (pilish--cool-completed-tool-blocks (list (pilish--tool-block-overlay block)))
                          (font-lock-flush)
                          (font-lock-ensure)
                          (goto-char (point-min))
                          (set-window-start first (point-min) t)
                          (redisplay t)
                          (setq primary (text-property-any (point-min) (point-max) 'pilish-argument-value t))
                          (should (= (car (pos-visible-in-window-p primary first t)) (* 2 (frame-char-width))))
                          (should-not (pilish-gui-test--tool-margin-position first primary))
                          (should (equal copy (pilish--filter-buffer-substring (point-min) (point-max))))))))
                (when (buffer-live-p chat)
                  (with-current-buffer chat (set-buffer-modified-p nil))
                  (kill-buffer chat))))))
      (set-frame-size nil width height)
      (sit-for 0.1))))

(ert-deftest pilish-gui-test-polish-multiline-exact-width-teaser ()
  "Exact-boundary root and child teasers fit the real gutter-bearing window."
  (require 'pilish-arguments-test)
  (let ((width (frame-width)) (height (frame-height)))
    (unwind-protect
        (dolist (columns '(54 104))
          (set-frame-size nil columns 40)
          (sit-for 0.1)
          (dolist (nested '(nil t))
            (dolist (named '(nil t))
              (let ((chat (generate-new-buffer " *pilish-exact-width-teaser*")))
                (unwind-protect
                    (save-window-excursion
                      (delete-other-windows)
                      (switch-to-buffer chat)
                      (pilish-chat-mode)
                      (let* ((window (selected-window))
                             (usable (pilish--chat-window-width))
                             (key-part (if named "payload=" ""))
                             (value (concat (make-string (- usable 2 (length key-part)) ?x) "\nSECOND…"))
                             (tool (if named "custom" "bash"))
                             (args (list (if named :payload :command) value)))
                        (should (>= (car (window-margins window)) 1))
                        (should-not truncate-lines)
                        (should word-wrap)
                        (if nested (pilish-arguments-test--child tool args "OUT")
                          (pilish-arguments-test--execute "r" tool args "OUT"))
                        (goto-char (point-min))
                        (set-window-start window (point-min) t)
                        (font-lock-ensure)
                        (redisplay t)
                        (pilish-arguments-test--goto-text "xxxx")
                        (let* ((start (point))
                               (end (line-end-position))
                               (first (pos-visible-in-window-p start window t))
                               (last (pos-visible-in-window-p (1- end) window t)))
                          (should (= usable (pilish--chat-window-width)))
                          (should (eq (char-before end) ?…))
                          (should first)
                          (should last)
                          (should (= (cadr first) (cadr last)))
                          (should (pilish-gui-test--tool-margin-position window start))
                          (pilish-toggle-tool-section)
                          (let ((start (text-property-any (point-min) (point-max) 'pilish-argument-value t)))
                            (should start)
                            (should (equal (pilish--filter-buffer-substring start (+ start (length value))) value))))))
                  (when (buffer-live-p chat)
                    (with-current-buffer chat (set-buffer-modified-p nil))
                    (kill-buffer chat)))))))
      (set-frame-size nil width height)
      (sit-for 0.1))))

(ert-deftest pilish-gui-test-r1-primary-literal-parser-native-cycle ()
  "Bound TAB and native margin collapse preserve literal rows and later Markdown."
  (require 'pilish-arguments-test)
  (let ((width (frame-width)) (height (frame-height)))
    (unwind-protect
        (dolist (columns '(104 54))
          (set-frame-size nil columns 45)
          (sit-for 0.1)
          (dolist (nested '(nil t))
            (dolist (first '("```" "~~~" "<!--"))
              (let ((chat (generate-new-buffer " *pilish-literal-primary*")))
                (unwind-protect
                    (save-window-excursion
                      (delete-other-windows)
                      (switch-to-buffer chat)
                      (pilish-chat-mode)
                      (let* ((window (selected-window))
                             (command (concat first "\n  echo SECOND '▸ ▾'"))
                             (teaser (concat first "…")))
                        (if nested (pilish-arguments-test--child "bash" (list :command command) "CHILD")
                          (pilish-arguments-test--execute "r" "bash" (list :command command) "ROOT" t))
                        (pilish--render-history-text
                         "\nAFTER-PARAGRAPH **bold**.\n\n```elisp\n(message \"AFTER-CODE\")\n```")
                        (goto-char (point-min))
                        (set-window-start window (point-min) t)
                        (pilish-arguments-test--assert-following-markdown)
                        (redisplay t)
                        (pilish-arguments-test--goto-text teaser)
                        (should (= (car (pos-visible-in-window-p (point) window t)) (* 2 (frame-char-width))))
                        (should (pilish-gui-test--tool-margin-position window (point)))
                        (pilish-arguments-test--goto-text "bash")
                        (cl-letf (((symbol-function 'message) #'ignore))
                          (execute-kbd-macro (kbd "TAB")))
                        (pilish-arguments-test--assert-following-markdown)
                        (pilish-arguments-test--goto-text command)
                        (let ((start (point)))
                          (should (equal (buffer-substring-no-properties start (+ start (length command))) command))
                          (dolist (pilish-copy-raw-markdown '(nil t))
                            (should (equal (pilish--filter-buffer-substring start (+ start (length command))) command)))
                          (redisplay t)
                          (should (= (car (pos-visible-in-window-p start window t)) (* 2 (frame-char-width))))
                          (let ((hit (pilish-gui-test--tool-margin-position window start)))
                            (should hit)
                            (pilish--disclosure-click (list 'mouse-1 hit))))
                        (pilish-arguments-test--assert-following-markdown)
                        (should (string-match-p (regexp-quote (concat "bash\n" teaser "\n"))
                                                (pilish-arguments-test--visible-text)))
                        (pilish-arguments-test--goto-text teaser)
                        (cl-letf (((symbol-function 'message) #'ignore))
                          (should-error (execute-kbd-macro (kbd "RET")) :type 'user-error))
                        (let ((copy (pilish--filter-buffer-substring (point-min) (point-max))))
                          (pilish--cool-completed-tool-blocks (pilish-arguments-test--all-tool-overlays))
                          (pilish-arguments-test--assert-following-markdown)
                          (should (equal copy (pilish--filter-buffer-substring (point-min) (point-max)))))
                        (pilish-arguments-test--goto-text teaser)
                        (should-not (get-text-property (point) 'pilish-argument-locator))
                        (redisplay t)
                        (should-not (pilish-gui-test--tool-margin-position window (point)))))
                  (when (buffer-live-p chat)
                    (with-current-buffer chat (set-buffer-modified-p nil))
                    (kill-buffer chat)))))))
      (set-frame-size nil width height)
      (sit-for 0.1))))

(ert-deftest pilish-gui-test-r1-short-equal-text-live-history-and-cold ()
  "Short command and path data remain exact through native refontification."
  (require 'pilish-arguments-test)
  (let ((width (frame-width)) (height (frame-height)))
    (unwind-protect
        (dolist (columns '(104 54))
          (set-frame-size nil columns 45)
          (sit-for 0.1)
          (dolist (history '(nil t))
            (dolist (tool '("bash" "read"))
              (let ((chat (generate-new-buffer " *pilish-short-literal*")))
                (unwind-protect
                    (save-window-excursion
                      (delete-other-windows)
                      (switch-to-buffer chat)
                      (pilish-chat-mode)
                      (let* ((value (concat (if (equal tool "bash") "echo " "src/")
                                            "[launch](https://example.com) **bold**"))
                             (args (list (if (equal tool "bash") :command :path) value))
                             (heading (concat tool " " value)))
                        (if history
                            (pilish--render-history-tool
                             (list :name tool :id "r" :arguments args)
                             '(:content [(:type "text" :text "OUT")]))
                          (pilish-arguments-test--execute "r" tool args "OUT"))
                        (pilish--render-history-text "\nA real [link](https://example.org).\n")
                        (dolist (cold '(nil t))
                          (when cold (pilish--cool-completed-tool-blocks (pilish-arguments-test--all-tool-overlays)))
                          (font-lock-flush)
                          (font-lock-ensure)
                          (goto-char (point-min))
                          (set-window-start nil (point-min) t)
                          (redisplay t)
                          (should (equal (car (split-string (pilish-arguments-test--visible-text) "\n")) heading))
                          (dolist (pilish-copy-raw-markdown '(nil t))
                            (should (equal (pilish--filter-buffer-substring (point-min) (+ (point-min) (length heading))) heading)))
                          (pilish-arguments-test--goto-text value)
                          (dotimes (offset (length value)) (should-not (button-at (+ (point) offset))))
                          (pilish-arguments-test--goto-text "link")
                          (should (button-at (point))))))
                  (when (buffer-live-p chat)
                    (with-current-buffer chat (set-buffer-modified-p nil))
                    (kill-buffer chat)))))))
      (set-frame-size nil width height)
      (sit-for 0.1))))


(defvar pilish-gui-test--large-trace nil)

(defun pilish-gui-test--large-evidence (name value)
  "Save test-owned VALUE under NAME when graphical evidence is requested."
  (when-let ((directory (getenv "G1_CAPTURE")))
    (make-directory directory t)
    (with-temp-file (expand-file-name (concat name ".el") directory)
      (prin1 value (current-buffer)))
    (when (fboundp 'x-export-frames)
      (redisplay t)
      (let ((coding-system-for-write 'binary))
        (write-region (x-export-frames nil 'png) nil
                      (expand-file-name (concat name ".png") directory) nil 'silent)))))

(defun pilish-gui-test--large-command (keys command &optional failure)
  "Dispatch KEYS, observe native COMMAND hooks, then force redisplay.
FAILURE permits an expected user error, whose native post hook may not run."
  (let* (events caught
         (observe (lambda (phase)
                    (push (list phase this-command (current-buffer)
                                (selected-window) (point)
                                (window-start (selected-window))) events)))
         (pre (lambda () (funcall observe 'pre)))
         (post (lambda () (funcall observe 'post))))
    (add-hook 'pre-command-hook pre)
    (add-hook 'post-command-hook post)
    (unwind-protect
        (condition-case err (execute-kbd-macro keys)
          (user-error (setq caught err)))
      (remove-hook 'pre-command-hook pre)
      (remove-hook 'post-command-hook post)
      (redisplay t))
    (setq events (nreverse events))
    (push events pilish-gui-test--large-trace)
    (should (cl-find-if (lambda (event) (equal (seq-take event 2) (list 'pre command))) events))
    (if failure (should caught)
      (should-not caught)
      (should (cl-find-if (lambda (event) (equal (seq-take event 2) (list 'post command))) events)))))

(defun pilish-gui-test--large-goto (text)
  "Find exact TEXT in the current transcript, leaving point at its start."
  (goto-char (point-min))
  (should (search-forward text nil t))
  (goto-char (match-beginning 0)))

(defun pilish-gui-test--large-fixture ()
  "Return fixed canonical messages, execution specs and independent outputs."
  (let (history roots children)
    (dotimes (n 180)
      (let* ((id (format "G1-history-%03d" n))
             (tool (pcase n (0 "write") (1 "edit") (_ "custom")))
             (args (pcase n
                     (0 '(:path "/tmp/G1-write" :content "G1-OMITTED-WRITE"))
                     (1 '(:path "/tmp/G1-edit" :oldText "G1-OMITTED-OLD" :newText "G1-OMITTED-NEW"))
                     (2 '(:diagnostic "G1-MISSING-DIAGNOSTIC\nSECOND"))
                     (_ '(:literal "```\n▸ ▾ <!-- literal -->\n~~~")))))
        (push (list :role "user" :content (format "G1 question %03d" n)) history)
        (push (list :role "assistant" :content
                    (vector (list :type "text" :text
                                  (mapconcat (lambda (line)
                                               (format "G1-PROSE-%03d-%02d %s" n line (make-string 52 ?x)))
                                             (number-sequence 0 39) "\n"))
                            (list :type "toolCall" :id id :name tool :arguments args))) history)
        (unless (= n 2)
          (push (list :role "toolResult" :toolCallId id :toolName tool
                      :content (vector (list :type "text" :text (concat "G1-OUTPUT-" id)))
                      :details (if (= n 1) '(:diff "- 1 old\n+ 1 G1-HISTORY-DIFF") :null)) history))))
    (dotimes (n 32)
      (push (list :id (format "G1-hot-%02d" n)
                  :name (cond ((= n 0) "codemode") ((= n 1) "bash") (t "custom"))
                  :arguments
                  (cond ((= n 0) '(:code "await tools();" :root "G1-ROOT-FIRST\nG1-ROOT-SECOND"))
                        ((= n 1) (list :command (concat "printf 'G1-BASH ▸ ▾'\n" (make-string 40000 ?b))))
                        ((= n 31) (cl-loop for k below 12 append
                                          (list (intern (format ":payload%d" k)) (make-string 40000 ?z))))
                        (t (list :payload (format "G1-VALUE-%02d-FIRST\nG1-VALUE-%02d-SECOND" n n))))
                  :result (list :content (vector (list :type "text" :text (format "G1-HOT-OUTPUT-%02d" n))))) roots))
    (setq history (vconcat (nreverse history)) roots (nreverse roots)
          children
          (list (list :id "G1-child-edit" :name "edit"
                      :arguments '(:path "/tmp/G1-child" :note "```\nG1-CHILD-LITERAL ▸ ▾\n~~~"
                                   :oldText "G1-OMITTED-CHILD-OLD" :newText "G1-OMITTED-CHILD-NEW")
                      :result '(:content [(:type "text" :text "G1-CHILD-OUTPUT")]
                                :details (:diff "- 1 old\n+ 1 G1-CHILD-DIFF\n  2 G1-CHILD-TAIL")))
                (list :id "G1-child-bash" :name "bash"
                      :arguments (list :command (concat "echo G1-CHILD-BASH\n" (make-string 40000 ?c)))
                      :result '(:content [(:type "text" :text "G1-CHILD-BASH-OUTPUT")]))
                (list :id "G1-child-budget" :name "custom"
                      :arguments (cl-loop for k below 12 append
                                          (list (intern (format ":child%d" k)) (make-string 40000 ?d)))
                      :result '(:content [(:type "text" :text "G1-CHILD-BUDGET-OUTPUT")]))))
    (list :history history :roots roots :children children
          :messages
          (vconcat history
                   (vector '(:role "user" :content "G1 hot cohort")
                           (list :role "assistant" :content
                                 (vconcat (mapcar (lambda (spec)
                                                   (append '(:type "toolCall")
                                                           (seq-take spec 6))) roots))))
                   (mapcar (lambda (spec)
                             (append (list :role "toolResult" :toolCallId (plist-get spec :id)
                                           :toolName (plist-get spec :name))
                                     (plist-get spec :result)
                                     (when (equal (plist-get spec :id) "G1-hot-00")
                                       (list :nestedCalls
                                             (list :complete t :calls
                                                   (vconcat (mapcar (lambda (c)
                                                                      (list :id (plist-get c :id) :name (plist-get c :name)
                                                                            :status "ok" :arguments (plist-get c :arguments))) children))))))) roots)))))

(defun pilish-gui-test--large-execute (spec &optional parent)
  "Render SPEC through ordinary execution display events, under PARENT if given."
  (dolist (type '("tool_execution_start" "tool_execution_end"))
    (pilish--handle-display-event
     (append (list :type type :toolCallId (plist-get spec :id) :toolName (plist-get spec :name))
             (when parent (list :parentToolCallId parent))
             (if (equal type "tool_execution_start")
                 (list :args (plist-get spec :arguments))
               (list :result (plist-get spec :result)))))))

(defun pilish-gui-test--large-handles (ids)
  "Find exactly one overlay-backed owner per member of IDS."
  (mapcar (lambda (id)
            (let ((blocks (mapcar #'pilish--tool-block-from-overlay
                                 (pilish--tool-block-overlays-in-region (point-min) (point-max)))))
              (should (= 1 (cl-count id blocks :key #'pilish--tool-block-tool-call-id :test #'equal)))
              (let ((block (cl-find id blocks :key #'pilish--tool-block-tool-call-id :test #'equal)))
                (list block
                      (copy-sequence (pilish--tool-block-nested-calls block))
                      (copy-marker (overlay-start (pilish--tool-block-overlay block))))))) ids))

(defun pilish-gui-test--large-cold-ranges ()
  "Check released cold text and return its physical bounds."
  (let ((p (point-min)) ranges)
    (while (< p (point-max))
      (let* ((metadata (get-text-property p 'pilish-cold-tool-block))
             (end (next-single-property-change p 'pilish-cold-tool-block nil (point-max))))
        (when metadata
          (should (stringp (plist-get metadata :tool-name)))
          (push (list p end) ranges)
          (dolist (property '(pilish-argument-locator pilish-argument-address pilish-disclosure-hit))
            (should-not (text-property-not-all p end property nil)))
          (let ((q p))
            (while (< q end)
              (dolist (property '(line-prefix wrap-prefix))
                (when-let ((prefix (get-text-property q property)))
                  (when (stringp prefix)
                    (should-not (text-property-not-all 0 (length prefix) 'pilish-disclosure-hit nil prefix)))))
              (setq q (next-property-change q nil end)))))
        (setq p end)))
    (nreverse ranges)))

(defun pilish-gui-test--large-retention (handles cold)
  "Check bounded hot or released cold HANDLES and their owned text."
  (let ((ranges (when cold (pilish-gui-test--large-cold-ranges))))
    (dolist (handle handles)
      (let* ((block (car handle)) (view (pilish--tool-block-argument-view block)))
        (if (not cold)
            (progn
              (should view)
              (should (<= (pilish--argument-view-chars view) 32768))
              (should (<= (pilish--argument-view-bytes view) 65536))
              (should (<= (pilish--argument-view-nodes view) 1024))
              (should (<= (pilish--argument-view-keys view) 256)))
          (should-not view)
          (dolist (call (cadr handle))
            (should-not (pilish--nested-call-argument-rows call))
            (should-not (pilish--nested-call-argument-charge call)))
          (should-not (seq-some (lambda (fold) (eq (car-safe fold) 'argument))
                               (pilish--tool-block-folds block)))
          (let ((start (marker-position (nth 2 handle))))
            (should start)
            (should (cl-find start ranges :key #'car))))))))

(ert-deftest pilish-gui-test-large-arguments-scroll-and-cool ()
  "Large transcripts retain independent readers and release old display views."
  (let ((chat (generate-new-buffer " *G1-large-chat*"))
        (fixture (pilish-gui-test--large-fixture))
        (width (frame-width)) (height (frame-height))
        (pilish-hot-tail-turn-count 3) (pilish-gui-test--large-trace nil))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer chat)
          (pilish-chat-mode)
          (pilish--display-session-history (plist-get fixture :history) chat)
          (should (>= (string-bytes (buffer-string)) 409600))
          (pilish--display-user-message "G1 live hot cohort")
          (dolist (spec (plist-get fixture :roots))
            (pilish-gui-test--large-execute spec)
            (when (equal (plist-get spec :id) "G1-hot-00")
              (dolist (child (plist-get fixture :children))
                (pilish-gui-test--large-execute child "G1-hot-00"))))
          (pilish--render-history-text
           (concat "\n" (pilish-gui-test--thinking-scroll-lines "G1 trailing" 65)))
          (let* ((handles (pilish-gui-test--large-handles (mapcar (lambda (s) (plist-get s :id)) (plist-get fixture :roots))))
                 (compound (caar handles))
                 (active (selected-window)) (other (split-window-below)))
            (pilish-gui-test--large-retention handles nil)
            (should (= 3 (length (cadar handles))))
            (should (pilish--argument-view-truncated-p (pilish--tool-block-argument-view compound)))
            (should (pilish--argument-view-truncated-p (pilish--tool-block-argument-view (car (car (last handles))))))
            (let* ((overlay (pilish--tool-block-overlay compound))
                   (button (pilish--find-toggle-button-in-region
                            (overlay-start overlay) (overlay-end overlay) '(child . "G1-child-edit"))))
              (should button)
              (goto-char (button-start button))
              (pilish-gui-test--large-command (kbd "TAB") 'pilish-toggle-tool-section))
            (pilish-gui-test--large-goto "G1-CHILD-DIFF")
            (let ((output (copy-marker (point)))
                  (identity (list 'G1-output)) (mutations 0)
                  (diffs (seq-filter (lambda (ov) (overlay-get ov 'pilish-diff-overlay))
                                     (overlays-in (point-min) (point-max)))))
              (should diffs)
              (let ((inhibit-read-only t))
                (add-text-properties output (+ output 13)
                                     (list 'pilish-g1-identity identity
                                           'modification-hooks (list (lambda (&rest _) (cl-incf mutations))))))
              (dolist (columns '(104 54))
                (set-frame-size nil columns 55)
                (sit-for 0.1)
                (set-window-buffer other chat)
                (set-window-point other (+ output 3))
                (set-window-start other (save-excursion (goto-char output) (line-beginning-position)) t)
                (dotimes (_ 4)
                  (select-window active)
                  (pilish-gui-test--large-goto "G1-PROSE-090-00")
                  (set-window-start active (line-beginning-position) t)
                  (redisplay t)
                  (let ((start (window-start active)))
                    (pilish-gui-test--large-command (kbd "C-v") 'scroll-up-command)
                    (should (> (window-start active) start))
                    (let ((down (window-start active)))
                      (pilish-gui-test--large-command (kbd "M-v") 'scroll-down-command)
                      (should (< (window-start active) down)))
                    (pilish-gui-test--large-command (kbd "C-l") 'recenter-top-bottom)))
                (dolist (needle (if (= columns 104)
                                    '("G1-ROOT-FIRST" "note=" "printf 'G1-BASH" "G1-VALUE-02-FIRST")
                                  '("echo G1-CHILD-BASH" "G1-VALUE-03-FIRST" "G1-VALUE-04-FIRST" "G1-VALUE-05-FIRST")))
                  (pilish-gui-test--large-goto needle)
                  (set-window-start active (line-beginning-position) t)
                  (redisplay t)
                  (let* ((owner (pilish--tool-block-from-overlay (pilish--tool-overlay-at-point)))
                         (folds (copy-tree (pilish--tool-block-folds owner)))
                         (active-y (cdr (posn-x-y (posn-at-point (point) active))))
                         (other-y (cdr (posn-x-y (posn-at-point (window-point other) other)))))
                    (dotimes (toggle 2)
                      (pilish-gui-test--large-command (kbd "TAB") 'pilish-toggle-tool-section)
                      (should (eq (selected-window) active))
                      (should (= active-y (cdr (posn-x-y (posn-at-point (point) active)))))
                      (should (eq (zerop toggle) (not (equal folds (pilish--tool-block-folds owner)))))
                      (should (eq (window-buffer other) chat))
                      (should (= (window-point other) (+ output 3)))
                      (should (= (window-start other) (save-excursion (goto-char output) (line-beginning-position))))
                      (should (= other-y (cdr (posn-x-y (posn-at-point (window-point other) other)))))
                      (should (= mutations 0))
                      (should (eq identity (get-text-property output 'pilish-g1-identity)))
                      (should (equal (buffer-substring-no-properties output (+ output 13)) "G1-CHILD-DIFF"))
                      (should (equal diffs (seq-filter (lambda (ov) (overlay-get ov 'pilish-diff-overlay))
                                                      (overlays-in (point-min) (point-max))))))
                    (should (equal folds (pilish--tool-block-folds owner)))))
                (pilish-gui-test--large-goto "note=")
                (set-window-start active (line-beginning-position) t)
                (redisplay t)
                (pilish-gui-test--large-evidence (format "chat-%d" columns)
                                               (list :bytes (string-bytes (buffer-string)) :roots (length handles)
                                                     :commands (reverse pilish-gui-test--large-trace))))
              (set-marker output nil))
            (should-not (string-match-p "content=G1-OMITTED-WRITE\\|oldText=G1-OMITTED-CHILD-OLD"
                                        (buffer-substring-no-properties (point-min) (point-max))))
            (should (= 1 (pilish-test--count-matches "G1-OMITTED-WRITE" (buffer-string))))
            (pilish-gui-test--large-goto "note=")
            (pilish-gui-test--large-command (kbd "TAB") 'pilish-toggle-tool-section)
            (pilish-gui-test--large-goto "G1-CHILD-LITERAL ▸ ▾")
            (should (get-text-property (point) 'pilish-argument-literal))
            (should-not (button-at (point)))
            (should (equal (filter-buffer-substring (point) (+ (point) 21)) "G1-CHILD-LITERAL ▸ ▾\n"))
            (should (string-match-p "G1-MISSING-DIAGNOSTIC" (buffer-string)))
            (dotimes (n 4) (pilish--display-user-message (format "G1 later headed turn %d" n)))
            (pilish-gui-test--large-execute
             '(:id "G1-recent" :name "custom" :arguments (:payload "RECENT-A\nRECENT-B")
               :result (:content [(:type "text" :text "G1-RECENT-OUTPUT")])))
            (let ((recent (pilish-gui-test--large-handles '("G1-recent"))))
              (pilish--handle-display-event '(:type "agent_end"))
              (should (timerp pilish--tool-cooling-timer))
              (dolist (handle handles) (should (memq (pilish--tool-block-overlay (car handle)) pilish--tool-cooling-queue)))
              (should (pilish-test-wait-until
                       (lambda () (with-current-buffer chat
                                    (and (null pilish--tool-cooling-timer) (null pilish--tool-cooling-queue))))
                       60 0.02))
              (pilish-gui-test--large-retention handles t)
              (pilish-gui-test--large-retention recent nil)
              (should (text-property-not-all (point-min) (point-max) 'pilish-argument-guard nil))
              (should (text-property-not-all (point-min) (point-max) 'pilish-argument-literal nil))
              (should (string-match-p "G1-CHILD-DIFF" (buffer-string)))
              (dotimes (n 32)
                (should (= 1 (pilish-test--count-matches (format "G1-HOT-OUTPUT-%02d" n) (buffer-string)))))
              (pilish-gui-test--large-goto "G1-CHILD-LITERAL ▸ ▾")
              (should (get-text-property (point) 'pilish-argument-literal))
              (should (get-text-property (point) 'line-prefix))
              (should (get-text-property (point) 'pilish-cold-tool-block))
              (should-not (get-text-property (point) 'pilish-argument-locator))
              (redisplay t)
              (should (= (* (+ 2 (length "note=")) (frame-char-width))
                         (car (pos-visible-in-window-p (point) active t))))
              (let ((views (mapcar (lambda (w) (list (window-point w) (window-start w))) (list active other))))
                (redisplay t)
                (should (equal views (mapcar (lambda (w) (list (window-point w) (window-start w))) (list active other)))))
              (pilish-gui-test--large-retention handles t)
              (pilish-gui-test--large-retention recent nil)
              (pilish-gui-test--large-evidence "chat-cooled"
                                             (list :cold (length (pilish-gui-test--large-cold-ranges))
                                                   :released (length handles) :recent-hot 1
                                                   :commands (reverse pilish-gui-test--large-trace))))))
      (set-frame-size nil width height)
      (when (buffer-live-p chat)
        (with-current-buffer chat (set-buffer-modified-p nil)) (kill-buffer chat)))))

(defun pilish-gui-test--large-browser (mode)
  "Render 100 independent families with 19 children using MODE's rerenderer."
  (funcall mode)
  (let (nodes items)
    (dotimes (r 100)
      (let ((root (format "G1-r%03d" r)) children)
        (push (list :path (concat "/G1/" root ".jsonl") :name (concat root " Family ▸")
                    :modified "2026-01-01T00:00:00Z") items)
        (dotimes (c 19)
          (let ((id (format "%s-c%02d" root c)))
            (push (list :id id :parentId root :type "message" :role "assistant"
                        :preview (concat id " Family ▾") :children []) children)
            (push (list :path (concat "/G1/" id ".jsonl") :name (concat id " Family ▾")
                        :parentSessionPath (concat "/G1/" root ".jsonl")
                        :modified "2026-01-01T00:00:00Z") items)))
        (push (list :id root :type "message" :role "user" :preview (concat root " Family ▸")
                    :children (vconcat (nreverse children))) nodes)))
    (if (eq mode 'pilish-tree-browser-mode)
        (setq pilish--tree-browser-tree (vconcat (nreverse nodes))
              pilish--tree-browser-leaf-id "G1-r099-c18" pilish--tree-browser-filter 'default)
      (setq pilish--session-browser-items (nreverse items)
            pilish--session-browser-include-search-text t
            pilish--session-browser-view 'threaded))
    (funcall (if (eq mode 'pilish-tree-browser-mode)
                 #'pilish--tree-browser-rerender #'pilish--session-browser-rerender))))

(ert-deftest pilish-gui-test-session-browser-first-search-from-disk ()
  "The / key gathers late saved text after a metadata-only opening."
  (let* ((root (pilish-test--make-temp-directory "pi-gui-search"))
         (default-directory (file-name-as-directory root))
         (process-environment (copy-sequence process-environment))
         (pilish-gui-test--large-trace nil)
         browser)
    (setenv "PI_CODING_AGENT_DIR" root)
    (let* ((dir (pilish-jsonl-session-dir-for-cwd root))
           (path (expand-file-name "session.jsonl" dir)))
      (make-directory dir t)
      (with-temp-file path
        (dolist (entry
                 (list (list :type "session" :version 3 :id "gui-search"
                             :cwd root :timestamp "2026-01-01T00:00:00Z")
                       '(:type "message" :id "first"
                         :message (:role "user" :content "Ordinary opening"))
                       '(:type "message" :id "late" :parentId "first"
                         :message (:role "assistant" :content "late-search-token"))))
          (insert (json-encode entry) "\n")))
      (unwind-protect
          (save-window-excursion
            (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil)))
              (pilish-session-browser)
              (setq browser (current-buffer))
              (should (pilish-test-wait-until
                       (lambda () (not pilish--session-browser-loading))))
              (should-not pilish--session-browser-error)
              (should (= (length pilish--session-browser-items) 1))
              (should-not (plist-member (car pilish--session-browser-items) :searchText))
              (should (string-match-p "Ordinary opening" (buffer-string)))
              (pilish-gui-test--large-command
               (vconcat (kbd "/") "late-search-token" (kbd "RET"))
               'pilish-session-browser-search)
              (should (pilish-test-wait-until
                       (lambda () (not pilish--session-browser-loading))))
              (should-not pilish--session-browser-error)
              (should pilish--session-browser-include-search-text)
              (should (string-match-p "late-search-token"
                                      (plist-get (car pilish--session-browser-items)
                                                 :searchText)))
              (should (string-match-p "Ordinary opening" (buffer-string)))
              (should-not (string-match-p "No matching sessions" (buffer-string)))
              (pilish-gui-test--large-command
               (vconcat (kbd "/ C-a C-k") "missing-search-token" (kbd "RET"))
               'pilish-session-browser-search)
              (should-not pilish--session-browser-loading)
              (should (string-match-p "No matching sessions" (buffer-string)))
              (pilish-gui-test--large-command
               (kbd "/ C-a C-k RET") 'pilish-session-browser-search)
              (pilish-gui-test--large-command (kbd "g") 'pilish-browse-refresh)
              (should (pilish-test-wait-until
                       (lambda () (not pilish--session-browser-loading))))
              (should-not pilish--session-browser-error)
              (should (plist-member (car pilish--session-browser-items) :searchText))
              (should (string-match-p "Ordinary opening" (buffer-string)))))
        (when (buffer-live-p browser) (kill-buffer browser))))))

(ert-deftest pilish-gui-test-large-browser-fold-and-copy ()
  "Both broad browsers preserve canonical folds, hidden data and live margin hits."
  (let ((pilish-gui-test--large-trace nil))
    (dolist (mode '(pilish-session-browser-mode pilish-tree-browser-mode))
      (let ((buffer (generate-new-buffer " *G1-large-browser*")))
        (unwind-protect
            (save-window-excursion
              (delete-other-windows)
              (switch-to-buffer buffer)
              (pilish-gui-test--large-browser mode)
              (should (= 2000 (length pilish--browse-fold-rows)))
              (let* ((state pilish--browse-fold-state)
                     (first (car pilish--browse-fold-rows))
                     (id (plist-get first :value))
                     (source (buffer-substring-no-properties (point-min) (point-max))))
                (goto-char (oref (plist-get first :section) start))
                (set-window-start nil (point-min) t)
                (redisplay t)
                (let* ((window (selected-window))
                       (pixel (pos-visible-in-window-p (point) window t))
                       (edge (window-pixel-edges window))
                       (inside (window-inside-pixel-edges window))
                       (y (+ (nth 1 edge) (cadr pixel) (/ (frame-char-height) 2)))
                       (hit (cl-loop for x from (car edge) below (car inside)
                                     for pos = (posn-at-x-y x y (window-frame window) t)
                                     when (and pos (eq (posn-area pos) 'left-margin) (posn-string pos))
                                     return pos)))
                  (should hit)
                  (pilish--disclosure-click (list 'mouse-1 hit))
                  (redisplay t)
                  (should (pilish--browse-folded-p id))
                  (pilish--disclosure-click (list 'mouse-1 hit))
                  (redisplay t)
                  (should (pilish--browse-folded-p id)))
                (pilish-gui-test--large-command (kbd "TAB") 'pilish-browse-toggle-fold)
                (should-not (pilish--browse-folded-p id))
                (dotimes (_ 4)
                  (goto-char (oref (plist-get (car pilish--browse-fold-rows) :section) start))
                  (pilish-gui-test--large-command (kbd "TAB") 'pilish-browse-toggle-fold)
                  (should (pilish--browse-folded-p id))
                  (pilish-gui-test--large-command (kbd "TAB") 'pilish-browse-toggle-fold)
                  (should-not (pilish--browse-folded-p id))
                  (goto-char (oref (plist-get (cadr pilish--browse-fold-rows) :section) start))
                  (pilish-gui-test--large-command (kbd "<backtab>") 'pilish-browse-fold-all)
                  (should (equal id (plist-get (pilish--browse-current-fold-row) :value)))
                  (should (= 100 (length pilish--browse-fold-overlays)))
                  (dolist (row pilish--browse-fold-rows)
                    (should (eq (and (invisible-p (oref (plist-get row :section) start)) t)
                                (not (plist-get row :foldable)))))
                  (let ((kill-ring nil) (kill-ring-yank-pointer nil))
                    (goto-char (point-min)) (push-mark (point-max) t t)
                    (pilish-gui-test--large-command (kbd "M-w") 'kill-ring-save)
                    (let ((copy (current-kill 0 t)))
                      (should (equal copy source))
                      (should (= 1900 (cl-count ?▾ copy)))
                      (should (= 100 (cl-count ?▸ copy)))
                      (should-not (text-property-not-all 0 (length copy) 'pilish-disclosure-hit nil copy))))
                  (pilish-gui-test--large-evidence (format "browser-%s-folded" mode)
                                                 (list :rows 2000 :overlays (length pilish--browse-fold-overlays)))
                  (pilish-gui-test--large-command (kbd "C-u <backtab>") 'pilish-browse-fold-all)
                  (should-not pilish--browse-fold-overlays)
                  (goto-char (point-min)) (set-window-start nil (point-min) t) (redisplay t)
                  (let ((start (window-start)))
                    (pilish-gui-test--large-command (kbd "C-v") 'scroll-up-command)
                    (should (> (window-start) start))
                    (let ((down (window-start)))
                      (pilish-gui-test--large-command (kbd "M-v") 'scroll-down-command)
                      (should (< (window-start) down)))))
                (let* ((expected-point (plist-get (pilish--browse-current-fold-row) :value))
                       (root (nth 1000 pilish--browse-fold-rows))
                       (root-id (plist-get root :value))
                       (command (if (eq mode 'pilish-tree-browser-mode)
                                    'pilish-tree-browser-search 'pilish-session-browser-search)))
                  (goto-char (oref (plist-get root :section) start))
                  (pilish-gui-test--large-command (kbd "TAB") 'pilish-browse-toggle-fold)
                  (should (gethash root-id state))
                  (goto-char (oref (plist-get (cl-find expected-point pilish--browse-fold-rows
                                                      :key (lambda (row) (plist-get row :value)) :test #'equal) :section) start))
                  (pilish-gui-test--large-command (vconcat (kbd "/") "-c" (kbd "RET")) command)
                  (should (= 1900 (length pilish--browse-fold-rows)))
                  (should (zerop (cl-count-if (lambda (row) (plist-get row :foldable)) pilish--browse-fold-rows)))
                  (should (gethash root-id state))
                  (pilish-gui-test--large-command (vconcat (kbd "/ C-a C-k RET")) command)
                  (should (gethash root-id state))
                  (should (= 1 (length pilish--browse-fold-overlays)))
                  (should (equal expected-point (plist-get (pilish--browse-current-fold-row) :value))))
                (should (eq state pilish--browse-fold-state))
                (should (equal source (buffer-substring-no-properties (point-min) (point-max))))
                (should (= 2000 (length pilish--browse-fold-rows)))
                (pilish-gui-test--large-evidence (format "browser-%s-unfolded" mode)
                                               (reverse pilish-gui-test--large-trace))))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pilish-gui-test-large-snapshot-refresh ()
  "Strict large saved observers refresh independently of a fake-backed parent."
  (pilish-gui-test-with-fresh-session
    (:backend fake :fake-scenario "prompt-lifecycle")
    (pilish-test--with-snapshot-files
      (let* ((fixture (pilish-gui-test--large-fixture))
             (messages (plist-get fixture :messages))
             (parent (plist-get pilish-gui-test--session :chat-buffer))
             (input (plist-get pilish-gui-test--session :input-buffer))
             (process (plist-get pilish-gui-test--session :process))
             (width (frame-width)) (height (frame-height))
             (pilish-hot-tail-turn-count 3) (pilish-gui-test--large-trace nil)
             (coding-system-for-write 'utf-8-unix)
             records previous snapshot replacement notices)
        (dotimes (n (length messages))
          (let ((id (format "G1-record-%04d" n)))
            (push (list :type "message" :id id :parentId (or previous :null) :message (aref messages n)) records)
            (setq previous id)))
        (setq records (cons header (nreverse records)))
        (pilish-test--snapshot-write child records)
        (with-temp-buffer
          (insert-file-contents child)
          (forward-line 1)
          (should (eq :g1-null (plist-get (json-parse-string
                                          (buffer-substring-no-properties (line-beginning-position) (line-end-position))
                                          :object-type 'plist :null-object :g1-null) :parentId))))
        (should (equal messages (pilish-jsonl-snapshot-messages (pilish-jsonl-read-snapshot target))))
        (unwind-protect
            (progn
              (with-current-buffer input (insert "G1 independent unsent draft"))
              (let ((parent-text (with-current-buffer parent (buffer-string))))
                (setq snapshot (pilish-open-subagent-snapshot target))
                (delete-other-windows)
                (let* ((first (selected-window)) (second (split-window-below))
                       (ids (mapcar (lambda (s) (plist-get s :id)) (plist-get fixture :roots)))
                       (handles (pilish-gui-test--large-handles ids)))
                  (set-window-buffer second snapshot)
                  (set-window-margins first 3 2) (set-window-margins second 4 3)
                  (should (>= (string-bytes (buffer-string)) 409600))
                  (pilish-gui-test--large-retention handles nil)
                  (should (= 179 (length (pilish-gui-test--large-cold-ranges))))
                  (should (= 33 (length (pilish--tool-block-overlays-in-region (point-min) (point-max)))))
                  (pilish-gui-test--large-goto "G1-VALUE-02-FIRST")
                  (pilish-gui-test--large-command (kbd "TAB") 'pilish-toggle-tool-section)
                  (let ((folds (copy-tree (pilish--tool-block-folds (car (nth 2 handles))))))
                    (dolist (columns '(104 54))
                      (set-frame-size nil columns 55) (sit-for 0.1)
                      (select-window first)
                      (pilish-gui-test--large-goto "G1-PROSE-090-00")
                      (set-window-start first (line-beginning-position) t)
                      (set-window-point second (point-max))
                      (with-selected-window second (goto-char (point-max)) (recenter -1))
                      (redisplay t)
                      (let ((views (mapcar (lambda (w) (list (window-point w) (window-start w) (window-margins w)))
                                           (list first second))))
                        (setq notices nil)
                        (cl-letf (((symbol-function 'message)
                                   (lambda (fmt &rest args) (push (apply #'format fmt args) notices))))
                          (pilish-gui-test--large-command (kbd "g") 'pilish-snapshot-refresh))
                        (should (member "Saved conversation unchanged" notices))
                        (should (eq snapshot (window-buffer first)))
                        (should (eq snapshot (window-buffer second)))
                        (should (equal views (mapcar (lambda (w) (list (window-point w) (window-start w) (window-margins w)))
                                                     (list first second))))
                        (should (equal folds (pilish--tool-block-folds (car (nth 2 handles))))))
                      (pilish-gui-test--large-evidence (format "observer-%d-unchanged" columns)
                                                     (list :bytes (string-bytes (buffer-string)) :messages (length messages))))
                    (pilish-test--snapshot-write
                     child (append records (list (pilish-test--snapshot-message "G1-change" previous "G1-INDEPENDENT-REFRESH-MARKER"))))
                    (setq notices nil)
                    (cl-letf (((symbol-function 'message)
                               (lambda (fmt &rest args) (push (apply #'format fmt args) notices))))
                      (pilish-gui-test--large-command (kbd "g") 'pilish-snapshot-refresh))
                    (should (member "Saved conversation updated" notices))
                    (setq replacement (window-buffer first))
                    (should-not (eq snapshot replacement))
                    (should-not (buffer-live-p snapshot))
                    (should (eq replacement (window-buffer second)))
                    (should (equal (window-margins first) '(3 . 2)))
                    (should (equal (window-margins second) '(4 . 3)))
                    (with-selected-window first
                      (should (string-match-p "G1-PROSE-090-" (pilish-gui-test--window-current-line first)))
                      (should (string-match-p "G1-INDEPENDENT-REFRESH-MARKER" (buffer-string)))
                      (should-not (pilish--tool-block-folds (caar (pilish-gui-test--large-handles '("G1-hot-02")))))
                      (pilish-gui-test--large-retention (pilish-gui-test--large-handles ids) nil)
                      (should (= 180 (length (pilish-gui-test--large-cold-ranges))))
                      (should (= 32 (length (pilish--tool-block-overlays-in-region (point-min) (point-max)))))
                      (pilish-gui-test--large-evidence "observer-changed" (reverse pilish-gui-test--large-trace))
                      (let ((last-good (buffer-substring-no-properties (point-min) (point-max))))
                        (delete-file child)
                        (cl-letf (((symbol-function 'message) #'ignore))
                          (pilish-gui-test--large-command (kbd "g") 'pilish-snapshot-refresh t))
                        (should (eq replacement (window-buffer first)))
                        (should (eq replacement (window-buffer second)))
                        (should (equal last-good (buffer-substring-no-properties (point-min) (point-max))))
                        (should (string-match-p "Refresh failed:" (format-mode-line header-line-format)))
                        (pilish-gui-test--large-evidence "observer-failed" (reverse pilish-gui-test--large-trace))))
                    (should (pos-visible-in-window-p (with-current-buffer replacement (point-max)) second)))
                  (should (process-live-p process))
                  (should (eq (buffer-local-value 'pilish--process parent) process))
                  (should (equal parent-text (with-current-buffer parent (buffer-string))))
                  (should (equal "G1 independent unsent draft" (with-current-buffer input (buffer-string)))))))
          (set-frame-size nil width height)
          (dolist (buffer (list snapshot replacement))
            (when (buffer-live-p buffer) (kill-buffer buffer))))))))

(provide 'pilish-gui-tests)
;;; pilish-gui-tests.el ends here
