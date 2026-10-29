;;; -*- lexical-binding: t; -*-

(require 'pilish-test-common)
(require 'pilish)

(defvar evil-snipe-local-mode-hook nil)
(defvar evil-snipe-override-local-mode-hook nil)

(ert-deftest pilish-test-snapshot-hidden-build-does-not-settle-windows ()
  "A hidden replay builds the full observer without moving visible windows."
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write
     child (list header '(:type "message" :id "question" :parentId :null
                          :message (:role "user" :content "Saved question"))
                 '(:type "message" :id "answer" :parentId "question"
                   :message (:role "assistant"
                             :content [(:type "text" :text "Saved answer")]))))
    (let ((saved (pilish-jsonl-read-snapshot target))
          (capture (symbol-function 'get-buffer-window-list))
          (replay (symbol-function 'pilish--replay-history))
          (paint-visible (symbol-function 'pilish--fontify-visible-transcript-windows))
          (windows (window-state-get nil t))
          (captures 0)
          replaying painting snapshot)
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'pilish--replay-history)
                       (lambda (&rest args)
                         (setq replaying t)
                         (unwind-protect (apply replay args)
                           (setq replaying nil))))
                      ((symbol-function 'pilish--fontify-visible-transcript-windows)
                       (lambda ()
                         (setq painting t)
                         (unwind-protect (funcall paint-visible)
                           (setq painting nil))))
                      ((symbol-function 'font-lock-ensure)
                       (lambda (&rest _)
                         (when replaying (ert-fail "Hidden replay painted text"))))
                      ((symbol-function 'get-buffer-window-list)
                       (lambda (&rest args)
                         (when (and replaying (not painting)) (cl-incf captures))
                         (let ((result (apply capture args)))
                           (should-not result)
                           result)))
                      ((symbol-function 'pilish--restore-tail-window)
                       (lambda (&rest _) (ert-fail "Hidden build settled a window")))
                      ((symbol-function 'set-window-point)
                       (lambda (&rest _) (ert-fail "Hidden build moved window point")))
                      ((symbol-function 'set-window-start)
                       (lambda (&rest _) (ert-fail "Hidden build moved window start"))))
              (setq snapshot (pilish--snapshot-build-buffer target saved)))
            (should (= captures 1))
            (should (equal windows (window-state-get nil t)))
            (should-not (get-buffer-window snapshot t))
            (with-current-buffer snapshot
              (should (derived-mode-p 'pilish-snapshot-mode))
              (should (memq treesit-primary-parser (treesit-parser-list)))
              (should (equal (treesit-parser-notifiers treesit-primary-parser)
                             '(treesit--font-lock-mark-ranges-to-fontify)))
              (should (= (point) (point-min)))
              (should buffer-read-only)
              (should (equal (buffer-substring-no-properties (point-min) (point-max))
                             "Pi session, read-only.\n\nYou\n===\n\nSaved question\n\nAssistant\n=========\n\nSaved answer\n\n"))))
        (pilish-test--kill-live-buffers snapshot)))))

(ert-deftest pilish-test-snapshot-disk-selected-full-branch ()
  (pilish-test--with-snapshot-files
    (let* ((first (pilish-test--snapshot-message "first" nil "Full pre-compaction user text"))
           (tool (list :type "message" :id "tool" :parentId "first"
                       :message '(:role "toolResult" :toolCallId "call" :content
                                        [(:type "text" :text "Full tool output")]
                                        :details (:run (:sessionId "grandchild")))))
           (entries (list first tool
                          (pilish-test--snapshot-message "wrong" "first" "Other branch")
                          '(:type "compaction" :id "compact" :parentId "tool"
                                  :timestamp "2026-10-15T00:00:00Z" :summary "Saved compaction" :tokensBefore 100)
                          '(:type "branch_summary" :id "branch" :parentId "compact"
                                  :timestamp "2026-10-15T00:01:00Z" :summary "Saved branch")
                          '(:type "custom_message" :id "custom" :parentId "branch"
                                  :timestamp "2026-10-15T00:02:00Z" :content "Saved extension" :display t)
                          '(:type "session_info" :id "leaf" :parentId "custom" :name "Child"))))
      (pilish-test--snapshot-write child (cons header entries) "{\"type\":")
      (let ((saved (pilish-jsonl-read-snapshot target)))
        (should (equal (pilish-jsonl-snapshot-file saved) child))
        (should (equal (pilish-jsonl-snapshot-cwd saved) (file-name-as-directory directory)))
        (should (equal (pilish-jsonl-snapshot-messages saved)
                       (vector (plist-get first :message) (plist-get tool :message)
                               '(:role "compactionSummary" :summary "Saved compaction" :tokensBefore 100
                                       :timestamp 1792022400000.0)
                               '(:role "branchSummary" :summary "Saved branch" :timestamp 1792022460000.0)
                               '(:role "custom" :customType nil :content "Saved extension" :display t
                                       :timestamp 1792022520000.0))))))))

(ert-deftest pilish-test-snapshot-disk-v087-system-full-branch ()
  (pilish-test--with-snapshot-files
    (with-temp-buffer
      (insert-file-contents (expand-file-name "browse-session-v087.jsonl" pilish-test--fixture-dir))
      (goto-char (point-min))
      (let ((saved-header (json-parse-string
                           (buffer-substring-no-properties (point) (line-end-position))
                           :object-type 'plist)))
        (delete-region (point) (line-end-position))
        (insert (json-serialize
                 (plist-put (plist-put saved-header :id (plist-get header :id))
                            :cwd (plist-get header :cwd)))))
      (write-region (point-min) (point-max) child nil 'silent))
    (let* ((saved (pilish-jsonl-read-snapshot target))
           (messages (pilish-jsonl-snapshot-messages saved)))
      (should (equal (pilish-jsonl-snapshot-file saved) child))
      (should (equal (pilish-jsonl-snapshot-cwd saved) (file-name-as-directory directory)))
      (should (equal (mapcar (lambda (message) (plist-get message :role)) (append messages nil))
                     '("system" "user" "assistant" "toolResult" "assistant" "compactionSummary" "user")))
      (should (equal (aref messages 0)
                     '(:role "system" :content ""
                             :sections (:preamble "You are an expert coding assistant operating inside pi."
                                        :tools "<tools>\n- read: Read file contents\n- bash: Execute bash commands\n</tools>"
                                        :rules "<rules>\n- Use read to examine files\n</rules>"
                                        :docs :null
                                        :project_context "<project_context>\nPilish development guide.\n</project_context>"
                                        :skills :null :cwd "<cwd>\n/home/daniel/co/pilish\n</cwd>")
                             :timestamp 1790375335488 :toolsAdded [(:name "read") (:name "bash")])))
      (should (equal (plist-get (aref messages 1) :content) [(:type "text" :text "hello")]))
      (should (equal (plist-get (aref messages 2) :content)
                     [(:type "thinking" :thinking "Run the echo check, then answer." :thinkingSignature "reasoning")
                      (:type "toolCall" :id "call_9f01a2bc" :name "bash" :arguments (:command "echo ok"))]))
      (should (equal (plist-get (aref messages 3) :content) [(:type "text" :text "ok")]))
      (should (equal (plist-get (aref messages 4) :content) [(:type "text" :text "hi there")]))
      (should (equal (aref messages 5)
                     '(:role "compactionSummary" :summary "Summary of earlier turns"
                             :tokensBefore 1234 :timestamp 1790375400000.0)))
      (should (equal (plist-get (aref messages 6) :content)
                     [(:type "text" :text "continue from the summary")])))))

(ert-deftest pilish-test-snapshot-open-missing-planned-file-can-be-retried ()
  (pilish-test--with-snapshot-files
    (save-window-excursion
      (let ((buffers (buffer-list))
            (windows (window-state-get nil t))
            opened)
        (unwind-protect
            (progn
              (should-error (pilish-open-subagent-snapshot target) :type 'user-error)
              (should (equal (buffer-list) buffers))
              (should (equal (window-state-get nil t) windows))
              (pilish-test--snapshot-write
               child (list header (pilish-test--snapshot-message "latest" nil "Latest saved resume")))
              (setq opened (pilish-open-subagent-snapshot target))
              (should (string-match-p "Latest saved resume" (buffer-string))))
          (pilish-test--kill-live-buffers opened))))))

(ert-deftest pilish-test-snapshot-disk-header-and-complete-record-errors ()
  (pilish-test--with-snapshot-files
    (dolist (bad-header (list (plist-put (copy-sequence header) :id "wrong")
                             (plist-put (copy-sequence header) :version 2)
                             (plist-put (copy-sequence header) :cwd :null)))
      (pilish-test--snapshot-write child (list bad-header))
      (should-error (pilish-jsonl-read-snapshot target) :type 'user-error))
    (pilish-test--snapshot-write child (list header) "not-json\n")
    (should-error (pilish-jsonl-read-snapshot target) :type 'user-error)
    (pilish-test--snapshot-write child (list header) "not-json")
    (should-error (pilish-jsonl-read-snapshot target) :type 'user-error)
    (pilish-test--snapshot-write child (list header) "{\"type\":")
    (should (equal (pilish-jsonl-snapshot-messages (pilish-jsonl-read-snapshot target)) []))))

(ert-deftest pilish-test-snapshot-disk-duplicate-and-ancestry-errors ()
  (pilish-test--with-snapshot-files
    (let ((entry (pilish-test--snapshot-message "leaf" nil "Saved once")))
      (pilish-test--snapshot-write child (list header entry entry))
      (should (equal (pilish-jsonl-snapshot-messages (pilish-jsonl-read-snapshot target))
                     [(:role "user" :content "Saved once" :timestamp 0)]))
      (dolist (entries (list (list entry (pilish-test--snapshot-message "leaf" nil "Conflict"))
                            (list (pilish-test--snapshot-message "leaf" "missing" "Dangling"))
                            (list (pilish-test--snapshot-message "a" "b" "A")
                                  (pilish-test--snapshot-message "b" "a" "B"))
                            (list '(:type "unknown" :id "leaf" :parentId :null))
                            (list '(:type "message" :id "leaf" :message (:role "user" :content "Missing parent")))))
        (pilish-test--snapshot-write child (cons header entries))
        (should-error (pilish-jsonl-read-snapshot target) :type 'user-error)))))

(ert-deftest pilish-test-snapshot-disk-symlink-escape ()
  (pilish-test--with-snapshot-files
    (let ((outside (expand-file-name "outside.jsonl" directory)))
      (pilish-test--snapshot-write outside (list header))
      (make-symbolic-link outside child)
      (should-error (pilish-jsonl-read-snapshot target) :type 'user-error))))

(ert-deftest pilish-test-snapshot-open-rejects-unsupported-message-role ()
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write
     child (list header '(:type "message" :id "leaf" :parentId :null
                                :message (:role "future_role" :content "Cannot render this saved role"))))
    (save-window-excursion
      (let ((buffers (buffer-list))
            (windows (window-state-get nil t))
            opened)
        (unwind-protect
            (progn
              (let ((failure
                     (cl-letf (((symbol-function 'write-region)
                                (lambda (&rest _) (ert-fail "Snapshot wrote source"))))
                       (should-error (setq opened (pilish-open-subagent-snapshot target)) :type 'user-error))))
                (should (equal (cadr failure) "Unsupported saved message role \"future_role\" in entry leaf")))
              (should (equal (buffer-list) buffers))
              (should (equal (window-state-get nil t) windows)))
          (pilish-test--kill-live-buffers opened))))))

(ert-deftest pilish-test-snapshot-open-distinguishes-hidden-custom-messages ()
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write
     child (list header '(:type "message" :id "user" :parentId :null
                                :message (:role "user" :content "Saved question"))
                 '(:type "custom_message" :id "hidden" :parentId "user"
                         :display :false :content "Hidden false extension")
                 '(:type "custom_message" :id "null" :parentId "hidden"
                         :display :null :content "Hidden null extension")
                 '(:type "custom_message" :id "visible" :parentId "null"
                         :display t :content "Visible saved extension")))
    (save-window-excursion
      (let ((snapshot (pilish-open-subagent-snapshot target)))
        (unwind-protect
            (should (equal (buffer-substring-no-properties (point-min) (point-max))
                           (concat "Pi session, read-only.\n\nYou\n===\n\nSaved question\n"
                                   "\nVisible saved extension\n")))
          (pilish-test--kill-live-buffers snapshot))))))

(ert-deftest pilish-test-snapshot-open-system-patches-preserve-dialogue ()
  (pilish-test--with-snapshot-files
    (let ((leading '(:role "system" :content "Private leading instructions"
                           :sections (:keep "Keep this section" :remove "Remove this section")
                           :toolsAdded [(:name "old_tool" :description "Old tool"
                                               :parameters (:type "object" :properties (:path (:type "string"))
                                                                  :required ["path"]))]
                           :timestamp 0))
          (patch '(:role "system" :content [(:type "text" :text "Private later instructions")]
                         :sections (:remove :null :added "Private new section")
                         :toolsAdded [(:name "new_tool" :description "New tool"
                                             :parameters (:type "object" :properties (:query (:type "string"))
                                                                :required ["query"])
                                             :constrainedSampling t)]
                         :toolsRemoved [(:name "old_tool")] :timestamp 4))
          (question '(:role "user" :content "Saved question"))
          (first '(:role "assistant" :content [(:type "text" :text "First answer")]))
          (second '(:role "assistant" :content [(:type "text" :text "Second answer")])))
      (save-window-excursion
        (let (opened)
          (unwind-protect
              (dolist (branch (list (list (cons "user" question) (cons "first" first) (cons "second" second))
                                   (list (cons "system-leading" leading) (cons "user" question)
                                         (cons "first" first) (cons "system-patch" patch) (cons "second" second))))
                (let (parent)
                  (pilish-test--snapshot-write
                   child (cons header
                               (mapcar (lambda (entry)
                                         (prog1 (list :type "message" :id (car entry) :parentId (or parent :null)
                                                      :message (cdr entry))
                                           (setq parent (car entry))))
                                       branch))))
                (cl-letf (((symbol-function 'pilish--rpc-async) (lambda (&rest _) (ert-fail "Snapshot sent RPC")))
                          ((symbol-function 'pilish--rpc-sync) (lambda (&rest _) (ert-fail "Snapshot sent synchronous RPC")))
                          ((symbol-function 'pilish--send-string) (lambda (&rest _) (ert-fail "Snapshot sent process input")))
                          ((symbol-function 'pilish--start-process) (lambda (&rest _) (ert-fail "Snapshot started pi")))
                          ((symbol-function 'write-region) (lambda (&rest _) (ert-fail "Snapshot wrote source"))))
                  (push (pilish-open-subagent-snapshot target) opened)
                  (should (equal (buffer-substring-no-properties (point-min) (point-max))
                                 (concat "Pi session, read-only.\n\nYou\n===\n\nSaved question\n"
                                         "\nAssistant\n=========\n\nFirst answer\n\nSecond answer\n\n")))
                  (should (equal (pilish-jsonl-snapshot-messages (pilish-jsonl-read-snapshot target))
                                 (vconcat (mapcar #'cdr branch))))))
            (apply #'pilish-test--kill-live-buffers opened)))))))

(ert-deftest pilish-test-snapshot-open-system-only-independent-read-only ()
  (pilish-test--with-snapshot-files
    (let ((system '(:role "system" :content "" :sections (:preamble "Private system-only instructions") :timestamp 0)))
      (pilish-test--snapshot-write
       child (list header (list :type "message" :id "system-only" :parentId :null :message system)))
      (pilish-test-with-mock-session directory
        (let* ((parent (pilish--find-session directory))
               (input (buffer-local-value 'pilish--input-buffer parent))
               (canonical [(:role "user" :content "Parent conversation")])
               snapshot)
          (unwind-protect
              (save-window-excursion
                (switch-to-buffer parent)
                (setq pilish--state (list :session-file anchor)
                      pilish--status 'sending
                      pilish--canonical-messages canonical)
                (with-current-buffer input (insert "Unsent parent draft"))
                (let ((parent-window (selected-window)))
                  (cl-letf (((symbol-function 'pilish--rpc-async) (lambda (&rest _) (ert-fail "Snapshot sent RPC")))
                            ((symbol-function 'pilish--rpc-sync) (lambda (&rest _) (ert-fail "Snapshot sent synchronous RPC")))
                            ((symbol-function 'pilish--send-string) (lambda (&rest _) (ert-fail "Snapshot sent process input")))
                            ((symbol-function 'pilish--start-process) (lambda (&rest _) (ert-fail "Snapshot started pi")))
                            ((symbol-function 'write-region) (lambda (&rest _) (ert-fail "Snapshot wrote source"))))
                    (setq snapshot (pilish-open-subagent-snapshot target))
                    (should (equal (pilish-jsonl-snapshot-messages (pilish-jsonl-read-snapshot target))
                                   (vector system)))
                    (should (equal (buffer-substring-no-properties (point-min) (point-max)) "Pi session, read-only.\n"))
                    (should (derived-mode-p 'pilish-snapshot-mode))
                    (should buffer-read-only)
                    (should-error (insert "not editable") :type 'buffer-read-only)
                    (should-not buffer-file-name)
                    (should-not (pilish--get-chat-buffer))
                    (should-not (pilish--get-process))
                    (should-not (pilish--get-input-buffer))
                    (should (equal pilish--snapshot-source-file child))
                    (should-not (eq parent-window (selected-window)))
                    (should (eq (window-buffer parent-window) parent))
                    (should (eq (window-buffer (selected-window)) snapshot))
                    (should (eq (pilish--find-session directory) parent))
                    (should (eq (buffer-local-value 'pilish--status parent) 'sending))
                    (should (equal (buffer-local-value 'pilish--state parent) (list :session-file anchor)))
                    (should (eq (buffer-local-value 'pilish--canonical-messages parent) canonical))
                    (should (equal (with-current-buffer input (buffer-string)) "Unsent parent draft"))
                    (pilish-snapshot-quit)
                    (should-not (buffer-live-p snapshot))
                    (should (buffer-live-p parent))
                    (should (buffer-live-p input)))))
            (pilish-test--kill-live-buffers snapshot)))))))

(ert-deftest pilish-test-snapshot-open-independent-read-only-other-window ()
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write
     child (list header '(:type "message" :id "user" :parentId :null
                                :message (:role "user" :content "Saved child question"))
                 '(:type "message" :id "assistant" :parentId "user"
                         :message (:role "assistant" :content [(:type "text" :text "Saved child answer")]))
                 '(:type "compaction" :id "compact" :parentId "assistant"
                         :summary "Saved summary" :tokensBefore 10)))
    (pilish-test-with-mock-session directory
      (let* ((parent (pilish--find-session directory))
             (input (buffer-local-value 'pilish--input-buffer parent))
             (canonical [(:role "user" :content "Parent message")])
             snapshot second)
        (unwind-protect
            (save-window-excursion
              (switch-to-buffer parent)
              (setq pilish--state (list :session-file anchor)
                    pilish--status 'sending
                    pilish--canonical-messages canonical)
              (with-current-buffer input (insert "Unsent parent draft"))
              (let ((parent-window (selected-window))
                    (comp-enable-subr-trampolines nil))
                (cl-letf (((symbol-function 'pilish--rpc-async) (lambda (&rest _) (ert-fail "Snapshot sent RPC")))
                          ((symbol-function 'pilish--rpc-sync) (lambda (&rest _) (ert-fail "Snapshot sent synchronous RPC")))
                          ((symbol-function 'pilish--send-string) (lambda (&rest _) (ert-fail "Snapshot sent process input")))
                          ((symbol-function 'pilish--start-process) (lambda (&rest _) (ert-fail "Snapshot started pi")))
                          ((symbol-function 'make-process) (lambda (&rest _) (ert-fail "Snapshot created process")))
                          ((symbol-function 'hack-local-variables) (lambda (&rest _) (ert-fail "Snapshot installed file-local variables")))
                          ((symbol-function 'write-region) (lambda (&rest _) (ert-fail "Snapshot wrote source"))))
                  (setq snapshot (pilish-open-subagent-snapshot target))
                  (should-not (eq parent-window (selected-window)))
                  (should (eq (window-buffer parent-window) parent))
                  (should (eq (window-buffer (selected-window)) snapshot))
                  (should (equal (buffer-substring-no-properties (point-min) (point-max))
                                 (concat "Pi session, read-only.\n\nYou\n===\n\nSaved child question\n"
                                         "\nAssistant\n=========\n\nSaved child answer\n\n"
                                         "\nCompaction\n==========\n\nCompacted from 10 tokens\n\nSaved summary\n")))
                  (should buffer-read-only)
                  (should-error (insert "not editable") :type 'buffer-read-only)
                  (should-not buffer-file-name)
                  (should-not (pilish--get-chat-buffer))
                  (should-not (pilish--get-process))
                  (should-not (pilish--get-input-buffer))
                  (should-not (derived-mode-p 'pilish-chat-mode))
                  (should (equal pilish--snapshot-source-file child))
                  (should (eq (pilish--find-session directory) parent))
                  (should (equal (buffer-local-value 'pilish--status parent) 'sending))
                  (should (equal (buffer-local-value 'pilish--state parent) (list :session-file anchor)))
                  (should (eq (buffer-local-value 'pilish--canonical-messages parent) canonical))
                  (should (equal (with-current-buffer input (buffer-string)) "Unsent parent draft"))
                  (setq second (pilish-open-subagent-snapshot target))
                  (should-not (eq second snapshot))
                  (pilish-snapshot-quit)
                  (should-not (buffer-live-p second))
                  (should (buffer-live-p snapshot))
                  (should (buffer-live-p parent))
                  (should (buffer-live-p input)))))
          (pilish-test--kill-live-buffers snapshot second))))))

(ert-deftest pilish-test-snapshot-details-survive-source-death ()
  "Every saved block opens detached Help without timing, RPC, or source retention."
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write
     child (list header
                 '(:type "message" :id "reply" :parentId :null
                   :message (:role "assistant" :timestamp 0 :provider "saved"
                             :model "historical" :usage (:input 0 :output 7)
                             :content [(:type "text" :text "Saved inspected answer")
                                       (:type "thinking" :thinking "Saved private thinking")
                                       (:type "toolCall" :id "A" :name "bash"
                                        :arguments (:command "printf '\\[find-file]' %"))]))
                 '(:type "message" :id "result" :parentId "reply"
                   :message (:role "toolResult" :toolCallId "A" :timestamp 0
                             :content [(:type "text" :text "Saved private output")]))))
    (save-window-excursion
      (let (snapshot reports)
        (unwind-protect
            (cl-letf (((symbol-function 'pilish--rpc-async)
                       (lambda (&rest _) (ert-fail "Saved inspector sent RPC"))))
              (setq snapshot (pilish-open-subagent-snapshot target))
              (dolist (text '("Saved inspected" "Saved private thinking" "Saved private output"))
                (goto-char (point-min))
                (search-forward text)
                (backward-char)
                (let ((expected (pilish--details-at-point)) shown)
                  (should (stringp expected))
                  (should-not (get-text-property (point) 'help-echo))
                  (cl-letf (((symbol-function 'message)
                             (lambda (fmt &rest args) (when fmt (setq shown (apply #'format fmt args))))))
                    (call-interactively (key-binding (kbd "C-h ."))))
                  (should (equal shown expected))
                  (should-not (string-match-p "Stream:\\|Execution time:\\|Saved inspected\\|private" expected))
                  (call-interactively #'pilish-describe-reply)
                  (set-buffer (window-buffer (selected-window)))
                  (should (derived-mode-p 'help-mode))
                  (should buffer-read-only)
                  (should (string-prefix-p (concat expected "\n") (buffer-string)))
                  (push expected reports)
                  (quit-window)
                  (set-buffer (window-buffer (selected-window)))
                  (should (eq (current-buffer) snapshot))))
              (should (string-match-p "saved / historical" (nth 2 reports)))
              (should (string-match-p "Message tokens: input 0 · output 7" (nth 2 reports)))
              (should (string-match-p "saved / historical" (nth 1 reports)))
              (should (string-match-p (regexp-quote "printf '\\[find-file]' %") (car reports)))
              (kill-buffer snapshot)
              (delete-file child)
              (switch-to-buffer (get-buffer "*Help*"))
              (dolist (report reports)
                (revert-buffer nil t)
                (should (string-prefix-p (concat report "\n") (buffer-string)))
                (unless (equal report (car (last reports)))
                  (help-xref-go-back (current-buffer))))
              (help-xref-go-forward (current-buffer))
              (should (string-prefix-p (nth 1 reports) (buffer-string)))
              (help-xref-go-forward (current-buffer))
              (should (string-prefix-p (car reports) (buffer-string))))
          (when (buffer-live-p snapshot) (kill-buffer snapshot))
          (when (get-buffer "*Help*") (kill-buffer "*Help*")))))))

(ert-deftest pilish-test-snapshot-open-render-failure-is-not-published ()
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write child (list header))
    (let ((before (buffer-list)))
      (cl-letf (((symbol-function 'pilish--replay-history)
                 (lambda (&rest _) (error "Synthetic render failure"))))
        (should-error (pilish-open-subagent-snapshot target)))
      (should (equal (buffer-list) before)))))

(defun pilish-test--saved-details (id label &optional root file)
  (list :savedConversations
        (list :version 1 :root (or root "/saved/ledger")
              :items (vector (list :sessionId id :file (or file (concat id ".jsonl"))
                                   :label label)))))

(defun pilish-test--snapshot-name-rows ()
  (let ((position (point-min)) rows)
    (while (< position (point-max))
      (let ((next (next-single-property-change position 'pilish-subagent-name nil (point-max)))
            (target (get-text-property position 'pilish-subagent-name)))
        (when (pilish--snapshot-target-p target)
          (push (list (buffer-substring-no-properties position next)
                      (pilish--snapshot-target-session-id target)
                      (pilish--snapshot-target-anchor-file target)) rows))
        (setq position next)))
    (nreverse rows)))

(ert-deftest pilish-test-snapshot-session-link-copy ()
  (dolist (nested '(nil t))
    (with-temp-buffer
      (pilish-chat-mode)
      (setq pilish--state '(:session-file "/saved/parent.jsonl"))
      (let ((pilish-tool-preview-lines 1)
            (result (list :content [(:type "text" :text "Done")]
                          :details (pilish-test--saved-details "child" "reviewer"))))
        (when nested
          (pilish--handle-display-event
           '(:type "tool_execution_start" :toolCallId "owner" :toolName "codemode")))
        (pilish--handle-display-event
         (append '(:type "tool_execution_start" :toolCallId "call" :toolName "delegate_work")
                 (when nested '(:parentToolCallId "owner"))))
        (pilish--handle-display-event
         (append (list :type "tool_execution_end" :toolCallId "call" :toolName "delegate_work" :result result)
                 (when nested '(:parentToolCallId "owner"))))
        (when nested
          (pilish--handle-display-event
           '(:type "tool_execution_end" :toolCallId "owner" :toolName "codemode" :result (:content []))))
        (goto-char (point-min))
        (pilish-next-subagent-name)
        (should (equal (pilish-test--snapshot-name-rows)
                       '(("reviewer" "child" "/saved/parent.jsonl"))))
        (dolist (pilish-copy-raw-markdown '(nil t))
          (let ((copy (filter-buffer-substring (line-beginning-position) (line-end-position))))
            (should (string-suffix-p " · Pi session: reviewer" copy))
            (should (equal-including-properties copy (substring-no-properties copy)))))
        (call-interactively (key-binding (kbd "TAB")))
        (search-forward "Done")
        (let ((start (- (point) (length "Done"))))
          (search-forward "Pi sessions: reviewer")
          (dolist (pilish-copy-raw-markdown '(nil t))
            (let ((copy (filter-buffer-substring start (point))))
              (should (string-prefix-p "Done\n\n**Details**\n" copy))
              (should (string-suffix-p "\n\nPi sessions: reviewer" copy))
              (should (equal-including-properties copy (substring-no-properties copy))))))))))

(ert-deftest pilish-test-snapshot-session-link-face ()
  (with-temp-buffer
    (pilish-chat-mode)
    (setq pilish--state '(:session-file "/saved/parent.jsonl"))
    (let* ((block (pilish--display-tool-start "delegate_work" nil "call"))
           (overlay (pilish--tool-block-overlay block)))
      (pilish--display-tool-end
       "delegate_work" nil [(:type "text" :text "Done")]
       (pilish-test--saved-details "child" "reviewer") nil block)
      (dolist (cold '(nil t))
        (when cold (pilish--cool-tool-overlay overlay))
        (font-lock-flush)
        (font-lock-ensure)
        (pilish--restore-tool-properties (point-min) (point-max))
        (goto-char (point-min))
        (pilish-next-subagent-name)
        (should (looking-at "reviewer"))
        (should (eq (button-get (button-at (point)) 'face) 'link))
        (should (eq (get-text-property (point) 'face) 'link))
        (should (eq (button-get (button-at (point)) 'action)
                    #'pilish--subagent-button-action))))))

(ert-deftest pilish-test-snapshot-session-link-retires-face ()
  (with-temp-buffer
    (pilish-chat-mode)
    (setq pilish--state '(:session-file "/saved/parent.jsonl"))
    (let* ((block (pilish--display-tool-start "delegate_work" nil "call"))
           (content [(:type "text" :text "Working")]))
      (pilish--display-tool-update
       (list :content content :details (pilish-test--saved-details "child" "unavailable")) block)
      (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
        (pilish--display-tool-update
         (list :content content :details '(:savedConversations :null)) block)
        (should (equal (buffer-substring-no-properties (point-min) (point-max)) plain)))
      (goto-char (point-min))
      (search-forward "unavailable")
      (let ((position (- (point) (length "unavailable"))))
        (should-not (button-at position))
        (should (stringp (get-text-property position 'pilish-subagent-name)))
        (should-not (eq (get-text-property position 'face) 'link))))))

(ert-deftest pilish-test-snapshot-names-coalesced-metadata-only-rebind ()
  (with-temp-buffer
    (pilish-chat-mode)
    (setq pilish--state '(:session-file "/saved/root.jsonl"))
    (let* ((block (pilish--display-tool-start "subagent" '(:agent "same") "call"))
           (text "Working")
           (first (list :content (vector (list :type "text" :text text))
                        :details (pilish-test--saved-details "first" "same")))
           (second (list :content (vector (list :type "text" :text text))
                         :details (pilish-test--saved-details "second" "same"))))
      (pilish--display-tool-update first block)
      (let ((painted (buffer-substring-no-properties (point-min) (point-max))))
        (pilish--queue-tool-update "call" second)
        (should (equal (mapcar #'cadr (pilish-test--snapshot-name-rows)) '("first" "first")))
        (cl-letf (((symbol-function 'input-pending-p) (lambda (&optional _) nil)))
          (pilish--flush-tool-updates (current-buffer)))
        (should (equal (buffer-substring-no-properties (point-min) (point-max)) painted))
        (should (equal (mapcar #'cadr (pilish-test--snapshot-name-rows)) '("second" "second")))
        (pilish--display-tool-update
         (list :content (vector (list :type "text" :text text))
               :details '(:savedConversations :null)) block)
        (should-not (pilish-test--snapshot-name-rows))
        (goto-char (point-min))
        (search-forward "unavailable")
        (should (stringp (get-text-property (1- (point)) 'pilish-subagent-name)))
        (should-not (button-at (1- (point))))))))

(ert-deftest pilish-test-snapshot-names-final-details-fold-cold-refontified ()
  (with-temp-buffer
    (pilish-chat-mode)
    (setq pilish--state '(:session-file "/saved/root.jsonl"))
    (let* ((pilish-tool-preview-lines 3)
           (details (pilish-test--saved-details "child-id" "same"))
           (args '(:agent "alias" :task "same"))
           (content [(:type "text" :text "## Subagent same result\nSubagent session ID: child-id\n\nsame task word")])
           (block (pilish--display-tool-start "subagent" args "call"))
           (overlay (pilish--tool-block-overlay block)))
      (pilish--display-tool-end "subagent" args content details nil block)
      (should-not (pilish--tool-block-result block))
      (should-not (pilish--tool-block-args block))
      (should (equal (mapcar #'car (pilish-test--snapshot-name-rows)) '("same")))
      (goto-char (overlay-start overlay))
      (call-interactively (key-binding (kbd "TAB")))
      (should (equal (mapcar (lambda (row) (list (car row) (cadr row)))
                            (pilish-test--snapshot-name-rows))
                     '(("same" "child-id") ("same" "child-id"))))
      (should (string-match-p "\\*\\*Details\\*\\*" (buffer-string)))
      (goto-char (point-min))
      (search-forward "same task word")
      (should-not (get-text-property (1- (point)) 'pilish-subagent-name))
      (let ((names (pilish-test--snapshot-name-rows)))
        (font-lock-ensure)
        (pilish--restore-tool-properties (point-min) (point-max))
        (should (equal (pilish-test--snapshot-name-rows) names))
        (pilish--cool-tool-overlay overlay)
        (should-not (overlay-buffer overlay))
        (should (equal (pilish-test--snapshot-name-rows) names))
        (font-lock-flush)
        (font-lock-ensure)
        (should (equal (pilish-test--snapshot-name-rows) names))
        (goto-char (point-min))
        (pilish-next-subagent-name)
        (should (eq (button-get (button-at (point)) 'action) #'pilish--subagent-button-action))
        (should-not (text-property-not-all (point-min) (point-max) 'pilish-tool-toggle nil))))))

(ert-deftest pilish-test-snapshot-names-truncation-and-inert-surfaces ()
  (with-temp-buffer
    (pilish-chat-mode)
    (setq pilish--state '(:session-file "/saved/root.jsonl"))
    (let* ((labels (pilish--saved-conversation-labels
                    "any_tool" [] (pilish-test--saved-details "child-id" "long-name")))
           (text (pilish--saved-conversation-output "Ordinary long-name output" labels))
           (slice (plist-get (pilish--truncate-to-visual-lines labels 2 4) :content)))
      (should (pilish--snapshot-target-p (get-text-property (string-search "long-name" text 30) 'pilish-subagent-name text)))
      (should-not (text-property-not-all 0 (length slice) 'pilish-subagent-name nil slice))
      (should-not (text-property-any 0 (length slice) 'face 'link slice))
      (should (equal-including-properties
               (pilish--saved-conversation-output "Ordinary long-name output" nil)
               "Ordinary long-name output")))))

(ert-deftest pilish-test-snapshot-names-navigation-skips-hidden-and-unavailable ()
  (with-temp-buffer
    (pilish-snapshot-mode)
    (let ((inhibit-read-only t)
          (target (pilish--snapshot-target-for-pi-v3 "/saved/root.jsonl" "child-id" "/saved/ledger" "child.jsonl")))
      (insert (concat (pilish--subagent-label "first" target) " "
                      (pilish--subagent-label "hidden" target) " "
                      (pilish--subagent-label "unavailable" "No saved identity") " "
                      (pilish--subagent-label "last" target)))
      (put-text-property 7 13 'invisible t)
      (goto-char (point-min))
      (pilish-next-subagent-name)
      (should (looking-at "last"))
      (pilish-previous-subagent-name)
      (should (looking-at "first"))
      (should-error (pilish-previous-subagent-name) :type 'user-error))))

(ert-deftest pilish-test-snapshot-names-navigation-skips-empty-display-and-overlays ()
  (with-temp-buffer
    (pilish-snapshot-mode)
    (let ((inhibit-read-only t)
          (target (pilish--snapshot-target-for-pi-v3 "/saved/root.jsonl" "child-id" "/saved/ledger" "child.jsonl")))
      (insert (concat "\n" (pilish--subagent-label "first" target) " "
                      (pilish--subagent-label "empty" target) " "
                      (pilish--subagent-label "folded" target) " "
                      (pilish--subagent-label "last" target)))
      (put-text-property 8 13 'display "")
      (overlay-put (make-overlay 14 20) 'invisible t)
      (goto-char (point-min))
      (call-interactively (key-binding (kbd "C-c ]")))
      (should (looking-at "first"))
      (call-interactively (key-binding (kbd "C-c ]")))
      (should (looking-at "last"))
      (goto-char (point-max))
      (call-interactively (key-binding (kbd "C-c [")))
      (should (looking-at "last"))
      (call-interactively (key-binding (kbd "C-c [")))
      (should (looking-at "first"))
      (should-error (call-interactively (key-binding (kbd "C-c ["))) :type 'user-error))))

(ert-deftest pilish-test-snapshot-name-command-and-button-action-use-actual-opener ()
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "Actual name action saved child")))
    (save-window-excursion
      (let ((parent (generate-new-buffer " *snapshot-action-parent*")) snapshot)
        (unwind-protect
            (progn
              (switch-to-buffer parent)
              (pilish-chat-mode)
              (setq pilish--state (list :session-file anchor))
              (let* ((args '(:agent "alias"))
                     (block (pilish--display-tool-start "subagent" args "call")))
                (pilish--display-tool-end "subagent" args
                                          [(:type "text" :text "## Subagent resolved result\nSaved")]
                                          details nil block))
              (goto-char (point-min))
              (call-interactively (key-binding (kbd "C-c ]")))
              (should (looking-at "saved child"))
              (let ((name-position (point)))
                (setq pilish--state '(:session-file "/different/root.jsonl"))
                (call-interactively #'pilish-visit-file)
                (setq snapshot (current-buffer))
                (should (string-match-p "Actual name action saved child" (buffer-string)))
                (should (derived-mode-p 'pilish-snapshot-mode))
                (pilish-snapshot-quit)
                (switch-to-buffer parent)
                (goto-char name-position)
                (button-activate (button-at (point)) t)
                (setq snapshot (current-buffer))
                (should (string-match-p "Actual name action saved child" (buffer-string)))
                (should (derived-mode-p 'pilish-snapshot-mode))))
          (pilish-test--kill-live-buffers snapshot parent))))))

(ert-deftest pilish-test-snapshot-default-headers-keyboard-open-collapsed-and-cold ()
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write
     child (list header '(:type "message" :id "leaf" :parentId :null
                                :message (:role "user" :content "Saved child behind collapsed output"))))
    (dolist (case '(("subagent" (:task "Read the saved file"))
                   ("subagent_resume" (:sessionId "argument-child" :message "Continue"))
                   ("delegate_work" nil)))
      (pcase-let ((`(,tool ,args) case))
        (pilish-test-with-mock-session directory
          (let* ((parent (pilish--find-session directory))
                 (input (buffer-local-value 'pilish--input-buffer parent))
                 (canonical [(:role "user" :content "Parent conversation")])
                 (pilish-tool-preview-lines 1)
                 (fill-column 200)
                 snapshot)
            (unwind-protect
                (save-window-excursion
                  (switch-to-buffer parent)
                  (setq pilish--state (list :session-file anchor)
                        pilish--status 'streaming
                        pilish--canonical-messages canonical)
                  (with-current-buffer input (insert "Unsent parent draft"))
                  (pilish--display-user-message "Read the saved file")
                  (let* ((block (pilish--display-tool-start tool args "not-a-session-id"))
                         (overlay (pilish--tool-block-overlay block)))
                    (pilish--display-tool-end
                     tool args [(:type "text" :text "## Subagent result\nSaved answer")]
                     details nil block)
                    (let* ((button (pilish--find-toggle-button-in-region
                                    (overlay-start overlay) (overlay-end overlay)))
                           (original (and button (button-get button 'pilish-full-content))))
                      (should (stringp original))
                      (should (string-prefix-p "## Subagent result\nSaved answer\n\n**Details**\n" original))
                      (should (string-suffix-p "\n\nPi sessions: saved child" original))
                      (should (= (length (split-string original "\n")) 19))
                      (should (= (button-get button 'hidden-count) 18)))
                    (should (equal (pilish-test--snapshot-name-rows) (list (list "saved child" "child-id" anchor))))
                    (should (string-match-p "^Output$" (buffer-string)))
                    (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
                      (goto-char (point-min))
                      (execute-kbd-macro (kbd "C-c ]"))
                      (should (looking-at "saved child"))
                      (should (equal (pilish--snapshot-target-file
                                      (get-text-property (point) 'pilish-subagent-name)) "dialogue.jsonl"))
                      (should (eq (key-binding (kbd "TAB")) #'pilish-toggle-tool-section))
                      (execute-kbd-macro (kbd "TAB"))
                      (should (string-match-p "Saved answer\n\n\\*\\*Details\\*\\*\n" (buffer-string)))
                      (execute-kbd-macro (kbd "TAB"))
                      (should (equal (buffer-substring-no-properties (point-min) (point-max)) plain))
                      (dolist (cold '(nil t))
                        (when cold
                          (pilish--cool-tool-overlay overlay)
                          (should-not (overlay-buffer overlay))
                          (should-not (text-property-not-all (point-min) (point-max) 'pilish-tool-toggle nil)))
                        (font-lock-flush)
                        (font-lock-ensure)
                        (pilish--restore-tool-properties (point-min) (point-max))
                        (should (equal (buffer-substring-no-properties (point-min) (point-max))
                                       (if cold
                                           (replace-regexp-in-string
                                            "\n```\n\n\\'"
                                            "\n```\n... (18 more lines)\n\n" plain t t)
                                         plain)))
                        (should (equal (pilish-test--snapshot-name-rows) (list (list "saved child" "child-id" anchor))))
                        (goto-char (point-min))
                        (execute-kbd-macro (kbd "C-c ]"))
                        (should (looking-at "saved child"))
                        (let ((parent-window (selected-window))
                              (comp-enable-subr-trampolines nil))
                          (cl-letf (((symbol-function 'pilish--rpc-async) (lambda (&rest _) (ert-fail "Snapshot sent RPC")))
                                    ((symbol-function 'pilish--rpc-sync) (lambda (&rest _) (ert-fail "Snapshot sent synchronous RPC")))
                                    ((symbol-function 'pilish--start-process) (lambda (&rest _) (ert-fail "Snapshot started pi")))
                                    ((symbol-function 'make-process) (lambda (&rest _) (ert-fail "Snapshot created process")))
                                    ((symbol-function 'write-region) (lambda (&rest _) (ert-fail "Snapshot wrote source"))))
                            (execute-kbd-macro (kbd "RET")))
                          (setq snapshot (current-buffer))
                          (should (derived-mode-p 'pilish-snapshot-mode))
                          (should (equal (buffer-substring-no-properties (point-min) (point-max))
                                         "Pi session, read-only.\n\nYou\n===\n\nSaved child behind collapsed output\n"))
                          (should (equal pilish--snapshot-source-file child))
                          (should buffer-read-only)
                          (should-not (eq parent-window (selected-window)))
                          (should (eq (window-buffer parent-window) parent))
                          (should-not (pilish--get-chat-buffer))
                          (should-not (pilish--get-process))
                          (should-not (pilish--get-input-buffer))
                          (should (eq (buffer-local-value 'pilish--status parent) 'streaming))
                          (should (equal (buffer-local-value 'pilish--state parent) (list :session-file anchor)))
                          (should (eq (buffer-local-value 'pilish--canonical-messages parent) canonical))
                          (should (equal (with-current-buffer input (buffer-string)) "Unsent parent draft"))
                          (pilish-snapshot-quit)
                          (should-not (buffer-live-p snapshot))
                          (switch-to-buffer parent))))))
              (pilish-test--kill-live-buffers snapshot))))))))

(ert-deftest pilish-test-snapshot-header-unavailable-without-captured-origin ()
  (with-temp-buffer
    (pilish-chat-mode)
    (let ((block (pilish--display-tool-start "any_tool" nil "call")))
      (pilish--display-tool-update
       (list :content [] :details (pilish-test--saved-details "child-id" "label")) block)
      (should-not (pilish-test--snapshot-name-rows))
      (goto-char (point-min))
      (search-forward "unavailable")
      (backward-char)
      (should (stringp (get-text-property (point) 'pilish-subagent-name)))
      (should-not (button-at (point)))
      (should-error (call-interactively (key-binding (kbd "RET"))) :type 'user-error)
      (should-error (pilish-next-subagent-name) :type 'user-error))))

(ert-deftest pilish-test-snapshot-history-nested-origin-survives-parent-death ()
  (pilish-test--with-snapshot-files
    (let* ((grandchild (concat root "manager-grandchild.jsonl"))
           (nested-details (pilish-test--saved-details
                            "grandchild-id" "same" root "manager-grandchild.jsonl"))
           parent snapshot nested)
      (pilish-test--snapshot-write
       child (list header
                   '(:type "message" :id "assistant" :parentId :null
                           :message (:role "assistant" :content
                                           [(:type "toolCall" :id "nested" :name "subagent"
                                                   :arguments (:agent "alias" :task "same plain task"))]))
                   (list :type "message" :id "result" :parentId "assistant"
                         :message (list :role "toolResult" :toolCallId "nested"
                                        :content [(:type "text" :text "## Subagent same result\nSaved descendant")]
                                        :details nested-details))))
      (pilish-test--snapshot-write
       grandchild (list (list :type "session" :version 3 :id "grandchild-id" :cwd directory)
                        (pilish-test--snapshot-message "leaf" nil "Grandchild saved answer")))
      (unwind-protect
          (save-window-excursion
            (setq parent (generate-new-buffer " *snapshot-parent-origin*"))
            (switch-to-buffer parent)
            (pilish-chat-mode)
            (setq pilish--state (list :session-file anchor) pilish--status 'streaming)
            (setq snapshot (pilish-open-subagent-snapshot target))
            (should (equal (mapcar (lambda (row) (list (car row) (cadr row)))
                                  (pilish-test--snapshot-name-rows))
                           '(("same" "grandchild-id"))))
            (should (equal (cl-remove-duplicates (mapcar #'caddr (pilish-test--snapshot-name-rows)) :test #'equal)
                           (list child)))
            (with-current-buffer parent (setq pilish--state '(:session-file "/different/root.jsonl")))
            (kill-buffer parent)
            (goto-char (point-min))
            (call-interactively (key-binding (kbd "C-c ]")))
            (should (looking-at "same"))
            (call-interactively #'pilish-visit-file)
            (setq nested (current-buffer))
            (should (equal pilish--snapshot-source-file grandchild))
            (should (string-match-p "Grandchild saved answer" (buffer-string)))
            (should-not (pilish--get-chat-buffer))
            (pilish-snapshot-quit)
            (should (buffer-live-p snapshot))
            (should-not (buffer-live-p nested)))
        (pilish-test--kill-live-buffers nested snapshot parent)))))

(ert-deftest pilish-test-snapshot-does-not-update-until-another-open ()
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "first" nil "First saved text")))
    (save-window-excursion
      (let (first second)
        (unwind-protect
            (progn
              (setq first (pilish-open-subagent-snapshot target))
              (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "second" nil "New saved text")))
              (setq second (pilish-open-subagent-snapshot target))
              (should (string-match-p "New saved text" (buffer-string)))
              (should (with-current-buffer first
                        (and (string-match-p "First saved text" (buffer-string))
                             (not (string-match-p "New saved text" (buffer-string)))))))
          (pilish-test--kill-live-buffers first second))))))

(defun pilish-test--snapshot-check-native-summary-opener (tool arguments)
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write
     child (list header '(:type "message" :id "leaf" :parentId :null
                                :message (:role "user" :content "Saved native nested child"))))
    (save-window-excursion
      (let ((parent (generate-new-buffer " *snapshot-native-summary-parent*")) snapshot)
        (unwind-protect
            (progn
              (switch-to-buffer parent)
              (pilish-chat-mode)
              (setq pilish--state (list :session-file anchor))
              (pilish--handle-display-event
               '(:type "tool_execution_start" :toolCallId "compound-owner"
                       :toolName "codemode" :args (:code "await child();")))
              (pilish--handle-display-event
               (append (list :type "tool_execution_start" :toolCallId "native-tool-call-not-a-session"
                             :parentToolCallId "compound-owner" :toolName tool)
                       (when arguments (list :args arguments))))
              (pilish--handle-display-event
               (list :type "tool_execution_end" :toolCallId "native-tool-call-not-a-session"
                     :parentToolCallId "compound-owner" :toolName tool :isError nil
                     :result (list :content []
                                   :details details)))
              (pilish--handle-display-event
               '(:type "tool_execution_end" :toolCallId "compound-owner"
                       :toolName "codemode" :isError nil :result (:content [])))
              (goto-char (point-min))
              (execute-kbd-macro (kbd "C-c ]"))
              (should (looking-at "saved child"))
              (execute-kbd-macro (kbd "RET"))
              (setq snapshot (current-buffer))
              (should (derived-mode-p 'pilish-snapshot-mode))
              (should (equal (buffer-substring-no-properties (point-min) (point-max))
                             "Pi session, read-only.\n\nYou\n===\n\nSaved native nested child\n"))
              (should (equal pilish--snapshot-source-file child)))
          (pilish-test--kill-live-buffers snapshot parent))))))

(ert-deftest pilish-test-snapshot-native-default-summary-keyboard-open ()
  (pilish-test--snapshot-check-native-summary-opener
   "delegate_work" '(:task "Read saved file")))

(ert-deftest pilish-test-snapshot-native-resume-summary-keyboard-open ()
  (pilish-test--snapshot-check-native-summary-opener
   "subagent_resume" '(:sessionId "argument-child" :message "Continue")))

(ert-deftest pilish-test-snapshot-native-default-summary-no-arguments-keyboard-open ()
  (pilish-test--snapshot-check-native-summary-opener "subagent" nil))

(ert-deftest pilish-test-snapshot-native-resume-summary-no-arguments-keyboard-open ()
  (pilish-test--snapshot-check-native-summary-opener "renamed_resume" nil))

(ert-deftest pilish-test-snapshot-native-summary-exact-result-not-call-id ()
  (with-temp-buffer
    (pilish-chat-mode)
    (setq pilish--state '(:session-file "/saved/root.jsonl"))
    (pilish--handle-display-event '(:type "tool_execution_start" :toolCallId "owner" :toolName "codemode"))
    (pilish--handle-display-event
     '(:type "tool_execution_start" :toolCallId "not-a-session" :parentToolCallId "owner"
             :toolName "any_tool" :args (:sessionId "argument-child")))
    (pilish--handle-display-event
     (list :type "tool_execution_end" :toolCallId "not-a-session" :parentToolCallId "owner"
           :toolName "any_tool" :result
           (list :content [] :details (pilish-test--saved-details "real-child" "quote\" λ"))))
    (let ((rows (pilish-test--snapshot-name-rows)))
      (should (equal rows '(("quote\" λ" "real-child" "/saved/root.jsonl")))))
    (goto-char (point-min))
    (search-forward "argument-child")
    (should-not (get-text-property (1- (point)) 'pilish-subagent-name))))

(ert-deftest pilish-test-snapshot-disk-absolute-compatible-paths-and-headers ()
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "Saved")))
    (pilish-test--snapshot-write child (list header (plist-put (copy-sequence header) :id "conflict")))
    (should-error (pilish-jsonl-read-snapshot target) :type 'user-error)
    (pilish-test--snapshot-write child (list header header (pilish-test--snapshot-message "leaf" nil "Saved")))
    (should (equal (pilish-jsonl-snapshot-messages (pilish-jsonl-read-snapshot target))
                   [(:role "user" :content "Saved" :timestamp 0)]))))

(ert-deftest pilish-test-snapshot-evil-keyboard-activation-and-safe-quit ()
  (skip-unless (require 'evil nil t))
  (let ((pilish-chat-mode-hook pilish-chat-mode-hook)
        (evil-snipe-local-mode-hook evil-snipe-local-mode-hook)
        (evil-snipe-override-local-mode-hook evil-snipe-override-local-mode-hook))
    (require 'pilish-evil)
    (pilish-evil-setup)
    (pilish-test--with-snapshot-files
      (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "Evil saved answer")))
      (save-window-excursion
        (let ((parent (generate-new-buffer " *snapshot-evil-parent*")) snapshot)
          (unwind-protect
              (progn
                (switch-to-buffer parent)
                (pilish-chat-mode)
                (evil-local-mode 1)
                (setq pilish--state (list :session-file anchor))
                (let ((block (pilish--display-tool-start "subagent" '(:agent "alias") "call")))
                  (pilish--display-tool-end
                   "subagent" '(:agent "alias") [(:type "text" :text "Saved")]
                   details nil block))
                (goto-char (point-min))
                (execute-kbd-macro (kbd "C-c ]"))
                (should (looking-at "saved child"))
                (should (eq (key-binding (kbd "TAB")) #'pilish-toggle-tool-section))
                (execute-kbd-macro (kbd "RET"))
                (setq snapshot (current-buffer))
                (should (derived-mode-p 'pilish-snapshot-mode))
                (evil-local-mode 1)
                (should (eq evil-state 'motion))
                (should (string-match-p "Evil saved answer" (buffer-string)))
                (should-not (memq (key-binding (kbd "C-c C-k")) '(pilish-abort pilish-compact)))
                (should-not (eq (key-binding "f") #'pilish-fork-at-point))
                (execute-kbd-macro "q")
                (should-not (buffer-live-p snapshot))
                (should (buffer-live-p parent)))
            (pilish-test--kill-live-buffers snapshot parent)))))))

(ert-deftest pilish-test-snapshot-load-without-evil ()
  (should
   (equal
    (pilish-test--read-batch-emacs-result
     "(progn
        (require 'cl-lib)
        (require 'pilish)
        (let ((original (symbol-function 'require)))
          (cl-letf (((symbol-function 'require)
                     (lambda (feature &rest args)
                       (unless (eq feature 'evil) (apply original feature args)))))
            (require 'pilish-evil)))
        (with-temp-buffer
          (pilish-snapshot-mode)
          (prin1 (list major-mode (derived-mode-p 'pilish-chat-mode)
                       (key-binding (kbd \"q\")) (key-binding (kbd \"g\"))))))")
    '(pilish-snapshot-mode nil pilish-snapshot-quit pilish-snapshot-refresh))))

(ert-deftest pilish-test-snapshot-disk-rejects-complete-empty-object-tail ()
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "Saved")))
    (should (equal (pilish-jsonl-snapshot-messages (pilish-jsonl-read-snapshot target))
                   [(:role "user" :content "Saved" :timestamp 0)]))
    (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "Saved")) "{}")
    (should-error (pilish-jsonl-read-snapshot target) :type 'user-error)))

(ert-deftest pilish-test-snapshot-annotation-does-not-mutate-wire-text ()
  (with-temp-buffer
    (pilish-chat-mode)
    (setq pilish--state '(:session-file "/saved/root.jsonl"))
    (let* ((wire "Log: /tmp/subagents.md\n- same (0 turns): working")
           (painted (pilish--saved-conversation-output
                     wire (pilish--saved-conversation-labels
                           "any_tool" [] (pilish-test--saved-details "child-id" "same"))))
           (inhibit-read-only t))
      (should (equal-including-properties wire "Log: /tmp/subagents.md\n- same (0 turns): working"))
      (insert painted)
      (should (equal (pilish-test--snapshot-name-rows) '(("same" "child-id" "/saved/root.jsonl"))))
      (erase-buffer)
      (insert (pilish--saved-conversation-output wire nil))
      (should (equal (buffer-substring-no-properties (point-min) (point-max)) wire))
      (should-not (pilish-test--snapshot-name-rows)))))

(ert-deftest pilish-test-snapshot-native-cold-summary-releases-payloads ()
  (with-temp-buffer
    (pilish-chat-mode)
    (setq pilish--state '(:session-file "/saved/root.jsonl"))
    (let* ((args '(:code "tools.subagent({agent: 'alias'})"))
           (block (pilish--display-tool-start "codemode" args "owner"))
           (call (pilish--make-nested-call
                  :id "native-call" :name "subagent" :source 'event :status 'ok
                  :arguments '(:agent "alias" :task "same task")
                  :saved-labels (pilish--saved-conversation-labels
                                 "subagent" [] (pilish-test--saved-details "child-id" "saved child"))
                  :result '(:content [(:type "text" :text "Saved")])))
           (overlay (pilish--tool-block-overlay block)))
      (pilish--enable-compound-tool block args)
      (pilish--argument-observe block nil "codemode" args)
      (pilish--argument-observe block call "subagent" (pilish--nested-call-arguments call))
      (setf (pilish--tool-block-nested-calls block) (list call))
      (pilish--redraw-compound-tool block)
      (pilish--tool-overlay-finalize 'pilish-tool-block block)
      (should (equal (pilish-test--snapshot-name-rows) '(("saved child" "child-id" "/saved/root.jsonl"))))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (pilish--cool-tool-overlay overlay)
        (should-not (overlay-buffer overlay))
        (should-not (pilish--nested-call-result call))
        (should-not (pilish--tool-block-result block))
        (should-not (pilish--tool-block-nested-calls block))
        (should (equal (pilish-test--snapshot-name-rows) '(("saved child" "child-id" "/saved/root.jsonl"))))
        (should (string-match-p "same task" (buffer-string)))
        (should (string-match-p "alias" text))
        (font-lock-ensure)
        (pilish--restore-tool-properties (point-min) (point-max))
        (goto-char (point-min))
        (pilish-next-subagent-name)
        (should (looking-at "saved child"))
        (should (eq (button-get (button-at (point)) 'action) #'pilish--subagent-button-action))
        (should-not (text-property-not-all (point-min) (point-max) 'pilish-tool-toggle nil))))))

(ert-deftest pilish-test-snapshot-old-run-and-envelopes-remain-readable-and-inert ()
  (dolist (tool '("subagent" "subagent_resume" "renamed_tool"))
    (dolist (text (list
                  "Log: /tmp/subagents.md\n- same (0 turns) -> child (0 turns): working"
                  "## Subagent same result\nSubagent session ID: 01234567-0123-0123-0123-0123456789ab\n\nAnswer"
                  (concat "## Subagent same error\n\nFailure\n\n"
                          "Subagent session ID: 01234567-0123-0123-0123-0123456789ab\n\n"
                          "This child session may be recoverable. If the same task should continue after a transient failure, call `subagent_resume` with this session ID and a message. Otherwise start a new `subagent`.")
                  (concat "## Subagent same interrupted\n\nNo final answer was produced.\n\n"
                          "Subagent session ID: 01234567-0123-0123-0123-0123456789ab\n\n"
                          "If the interrupted task should continue, call `subagent_resume` with this session ID and a message. Otherwise start a new `subagent`.\n\n"
                          "Example for `message`:\n- You were interrupted. Continue the original task from where you left off.")))
      (with-temp-buffer
        (pilish-chat-mode)
        (setq pilish--state '(:session-file "/saved/root.jsonl"))
        (let* ((args '(:agent "same" :sessionId "argument-child"))
               (details '(:run (:sessionId "child-id" :episodeId "episode" :agent "same"
                                          :children [(:sessionId "grandchild" :agent "child")])
                               :other (:agent "quote\" λ")))
               (presentation (pilish--tool-result-presentation
                              tool args (vector (list :type "text" :text text)) details nil))
               (inhibit-read-only t))
          (insert (pilish--tool-header tool args) "\n" (plist-get presentation :text))
          (should (string-match-p (regexp-quote text) (buffer-string)))
          (should (string-match-p "grandchild" (buffer-string)))
          (should-not (pilish-test--snapshot-name-rows))
          (should-not (text-property-not-all (point-min) (point-max) 'pilish-subagent-name nil))
          (should-not (plist-get presentation :saved-labels)))))))

(ert-deftest pilish-test-snapshot-neutral-history-duplicate-labels-cold-openers ()
  (pilish-test--with-saved-conversation-files
    (save-window-excursion
      (let ((parent (generate-new-buffer " *neutral-saved-parent*")) snapshot
            (pilish-tool-preview-lines 2)
            (fill-column 200)
            (wire "reviewer is an ordinary output word, not a link")
            (details (list :savedConversations declaration)))
        (unwind-protect
            (progn
              (switch-to-buffer parent)
              (pilish-chat-mode)
              (setq pilish--state (list :session-file anchor))
              (let ((original-details (json-serialize details))
                    (messages
                     (vector '(:role "assistant" :content
                                     [(:type "toolCall" :id "different-producer" :name "delegate_work"
                                             :arguments (:task "reviewer"))])
                             (list :role "toolResult" :toolCallId "different-producer"
                                   :content (vector (list :type "text" :text wire)) :details details))))
                (pilish--replay-history parent messages)
                (should (equal-including-properties wire "reviewer is an ordinary output word, not a link"))
                (should (equal (json-serialize details) original-details))
                (should (equal-including-properties
                         (plist-get (aref (plist-get declaration :items) 0) :label) "reviewer")))
              (should (equal (mapcar #'cadr (pilish-test--snapshot-name-rows)) '("worker-17" "worker-42")))
              (goto-char (point-min))
              (search-forward wire)
              (should-not (get-text-property (- (point) (length wire)) 'pilish-subagent-name))
              (let ((overlay (seq-find (lambda (ov) (overlay-get ov 'pilish-tool-block))
                                       (overlays-in (point-min) (point-max)))))
                (goto-char (overlay-start overlay))
                (call-interactively (key-binding (kbd "TAB")))
                (should (equal (mapcar #'cadr (pilish-test--snapshot-name-rows))
                               '("worker-17" "worker-42" "worker-17" "worker-42")))
                (pilish--cool-tool-overlay overlay)
                (font-lock-ensure)
                (pilish--restore-tool-properties (point-min) (point-max)))
              (setq pilish--state '(:session-file "/different/parent.jsonl"))
              (goto-char (point-min))
              (call-interactively (key-binding (kbd "C-c ]")))
              (let ((blue (point)))
                (should (looking-at "reviewer"))
                (call-interactively (key-binding (kbd "C-c ]")))
                (let ((red (point)))
                  (dolist (case (list (list blue child "Blue saved conversation")
                                     (list red other "Red saved conversation")))
                    (goto-char (car case))
                    (call-interactively (key-binding (kbd "RET")))
                    (setq snapshot (current-buffer))
                    (should (derived-mode-p 'pilish-snapshot-mode))
                    (should (equal pilish--snapshot-source-file (cadr case)))
                    (should (string-match-p (nth 2 case) (buffer-string)))
                    (pilish-snapshot-quit)
                    (switch-to-buffer parent)))))
          (pilish-test--kill-live-buffers snapshot parent))))))

(ert-deftest pilish-test-snapshot-neutral-adapter-capture-survives-removal-and-parent-death ()
  (pilish-test--with-saved-conversation-files
    (save-window-excursion
      (let* ((parent (generate-new-buffer " *capture-only-parent*")) snapshot label
             (declaration (json-parse-string (json-serialize declaration) :object-type 'plist))
             (calls 0)
             (content [(:type "text" :text "A producer-specific receipt")])
             (receipt (aref (plist-get declaration :items) 0))
             (details (list :ledgerRoot (plist-get declaration :root)
                            :savedId (plist-get receipt :sessionId)
                            :savedFile (plist-get receipt :file)
                            :title (plist-get receipt :label)))
             (pilish-saved-conversation-functions
              (list (lambda (name observed-content observed-details)
                      (cl-incf calls)
                      (should (equal name "delegate_work"))
                      (should (eq observed-content content))
                      (should (eq observed-details details))
                      (list :version 1 :root (plist-get observed-details :ledgerRoot)
                            :items (vector (list :sessionId (plist-get observed-details :savedId)
                                                 :file (plist-get observed-details :savedFile)
                                                 :label (plist-get observed-details :title))))))))
        (unwind-protect
            (progn
              (switch-to-buffer parent)
              (pilish-chat-mode)
              (setq pilish--state (list :session-file anchor))
              (pilish--display-tool-end "delegate_work" nil content details nil
                                        (pilish--display-tool-start "delegate_work" nil "call"))
              (should (= calls 1))
              (goto-char (point-min))
              (pilish-next-subagent-name)
              (setq label (buffer-substring (point) (+ (point) (length "reviewer")))
                    pilish-saved-conversation-functions nil
                    pilish--state '(:session-file "/new/parent.jsonl"))
              (dolist (string (list anchor (plist-get declaration :root)
                                    (plist-get (aref (plist-get declaration :items) 0) :sessionId)
                                    (plist-get (aref (plist-get declaration :items) 0) :file)
                                    (plist-get (aref (plist-get declaration :items) 0) :label)))
                (aset string 0 ?X))
              (kill-buffer parent)
              (with-temp-buffer
                (pilish-transcript-mode)
                (let ((inhibit-read-only t)) (insert label))
                (goto-char (point-min))
                (call-interactively #'pilish-open-subagent-snapshot)
                (setq snapshot (current-buffer))
                (should (equal pilish--snapshot-source-file child))
                (should (string-match-p "Blue saved conversation" (buffer-string)))))
          (pilish-test--kill-live-buffers snapshot parent))))))

(ert-deftest pilish-test-snapshot-neutral-arbitrary-run-fields-and-envelopes-openers ()
  (pilish-test--with-saved-conversation-files
    (dolist (tool '("subagent" "subagent_resume" "renamed_tool"))
      (dolist (run '(nil :null 7 [] "malformed" (:status "finished" :job "blue")
                         (:sessionId "unrelated" :episodeId "episode")
                         (:sessionId :null :episodeId 42)
                         (:children [(:sessionId 7 :episodeId :null)])
                         (:children [(:children [(:sessionId :null)])])))
        (dolist (source '(explicit adapter))
          (save-window-excursion
            (let* ((parent (generate-new-buffer " *identity-free-run-parent*")) snapshot
                   (calls 0)
                   (details (list :run run))
                   (pilish-saved-conversation-functions
                    (list (lambda (name _content observed-details)
                            (cl-incf calls)
                            (should (equal name tool))
                            (should (eq observed-details details))
                            declaration))))
              (unwind-protect
                  (progn
                    (when (eq source 'explicit)
                      (setq details (plist-put details :savedConversations declaration)))
                    (switch-to-buffer parent)
                    (pilish-chat-mode)
                    (setq pilish--state (list :session-file anchor))
                    (pilish--display-tool-end
                     tool nil [(:type "text" :text "## Subagent worker result\nSubagent session ID: 01234567-0123-0123-0123-0123456789ab\n\nSaved job receipt")] details nil
                     (pilish--display-tool-start tool nil "call"))
                    (should (= calls (if (eq source 'explicit) 0 1)))
                    (goto-char (point-min))
                    (call-interactively (key-binding (kbd "C-c ]")))
                    (should (looking-at "reviewer"))
                    (setq pilish-saved-conversation-functions nil)
                    (call-interactively (key-binding (kbd "RET")))
                    (setq snapshot (current-buffer))
                    (should (derived-mode-p 'pilish-snapshot-mode))
                    (should (equal pilish--snapshot-source-file child))
                    (should (string-match-p "Blue saved conversation" (buffer-string))))
                (pilish-test--kill-live-buffers snapshot parent)))))))))

(ert-deftest pilish-test-snapshot-neutral-metadata-only-rebind-and-final-removal ()
  (pilish-test--with-saved-conversation-files
    (with-temp-buffer
      (pilish-chat-mode)
      (setq pilish--state (list :session-file anchor))
      (let* ((block (pilish--display-tool-start "delegate_work" nil "call"))
             (content [(:type "text" :text "Working")])
             (first (plist-put (copy-sequence declaration) :items
                               (vector (aref (plist-get declaration :items) 0))))
             (second (plist-put (copy-sequence declaration) :items
                                (vector (aref (plist-get declaration :items) 1)))))
        (pilish--display-tool-update
         (list :content content :details (list :savedConversations first)) block)
        (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
          (pilish--display-tool-update
           (list :content content :details (list :savedConversations second)) block)
          (should (equal (buffer-substring-no-properties (point-min) (point-max)) plain))
          (should (equal (mapcar #'cadr (pilish-test--snapshot-name-rows)) '("worker-42" "worker-42"))))
        (pilish--display-tool-end "delegate_work" nil content nil nil block)
        (should-not (pilish-test--snapshot-name-rows))
        (should-not (string-match-p "Pi session:" (buffer-string)))))))

(ert-deftest pilish-test-snapshot-neutral-malformed-declarations-are-disk-free-and-inert ()
  (pilish-test--with-saved-conversation-files
    (with-temp-buffer
      (pilish-chat-mode)
      (setq pilish--state (list :session-file anchor))
      (let* ((good (list :version 1 :root root :items
                         (vector (list :sessionId "worker-17" :file relative))))
             (adapter-calls 0)
             (pilish-saved-conversation-functions
              (list (lambda (&rest _) (cl-incf adapter-calls) good))))
        (dolist (bad (append
                     (list nil :null t [] '(:version 2) (list :version 1 :root root :items [])
                           (plist-put (copy-sequence good) :version 2)
                           (plist-put (copy-sequence good) :items '(:notAnArray t))
                           (plist-put (copy-sequence good) :items (vector (aref (plist-get good :items) 0)
                                                                 (aref (plist-get good :items) 0)))
                           (plist-put (copy-sequence good) :items
                                      (vector (aref (plist-get good :items) 0)
                                              (list :sessionId "different-id" :file relative)))
                           (plist-put (copy-sequence good) :items
                                      (vector (aref (plist-get good :items) 0)
                                              (list :sessionId "worker-17" :file "different.jsonl"))))
                     (mapcar (lambda (root) (plist-put (copy-sequence good) :root root))
                             '("/" "/tmp/.." "relative" "~/ledger" "~someone/ledger" "" "/bad\nroot" "/bad\u202eroot"))
                     (mapcar (lambda (file)
                               (list :version 1 :root root :items (vector (list :sessionId "worker-17" :file file))))
                             '("" "../escape" "./dialogue" "a//b" "a/" "/absolute" "~/home" "a/../b" "a\0b" "a\nb"))
                     (mapcar (lambda (item) (list :version 1 :root root :items (vector item)))
                             '((:sessionId "" :file "a") (:sessionId 7 :file "a")
                               (:sessionId :null :file "a") (:sessionId "bad\u202eid" :file "a")
                               (:sessionId "valid" :file "a" :label :null)
                               (:sessionId "valid" :file "a" :label "two\nlines")
                               (:sessionId "valid" :file "a" :label "")))))
          (let* ((details (list :savedConversations bad))
                 (content [(:type "text" :text "Ordinary reviewer /tmp/reviewer.txt")])
                 (block (pilish--display-tool-start "delegate_work" nil "call")))
            (cl-letf (((symbol-function 'insert-file-contents) (lambda (&rest _) (ert-fail "Annotation read disk")))
                      ((symbol-function 'file-in-directory-p) (lambda (&rest _) (ert-fail "Annotation checked disk"))))
              (pilish--display-tool-end "delegate_work" nil content details nil block))
            (goto-char (overlay-start (pilish--tool-block-overlay block)))
            (search-forward "unavailable")
            (should (stringp (get-text-property (1- (point)) 'pilish-subagent-name)))
            (should-not (button-at (1- (point))))
            (backward-char)
            (should-error (call-interactively #'pilish-visit-file) :type 'user-error)))
        (should-not (pilish-test--snapshot-name-rows))
        (should (= adapter-calls 0))
        (let* ((presentation (pilish--tool-result-presentation
                              "delegate_work" nil [] (list :savedConversations good) nil))
               (labels (plist-get presentation :saved-labels)))
          (should (equal (substring-no-properties labels) "worker-17"))
          (should (pilish--snapshot-target-p (get-text-property 0 'pilish-subagent-name labels)))
          (should-not (text-property-not-all
                       0 3 'pilish-subagent-name nil
                       (pilish--remove-clipped-subagent-names labels (substring labels 0 3)))))))))

(ert-deftest pilish-test-snapshot-stale-branded-details-produce-no-links ()
  (pilish-test--with-saved-conversation-files
    (with-temp-buffer
      (pilish-chat-mode)
      (setq pilish--state (list :session-file anchor))
      (let* ((content [(:type "text" :text "Legacy branded receipt")])
             (pilish-saved-conversation-functions nil)
             (block (pilish--display-tool-start "delegate_work" nil "call")))
        (pilish--display-tool-end
         "delegate_work" nil content
         (list :pilish (list :savedConversations declaration)) nil block)
        (should (string-match-p "Legacy branded receipt" (buffer-string)))
        (should-not (string-match-p "Pi sessions:" (buffer-string)))
        (should-not (pilish-test--snapshot-name-rows))
        (should-not (text-property-not-all (point-min) (point-max) 'pilish-subagent-name nil))))))

(ert-deftest pilish-test-snapshot-direct-declaration-beats-stale-branded-wrapper ()
  (pilish-test--with-saved-conversation-files
    (save-window-excursion
      (let* ((parent (generate-new-buffer " *direct-over-wrapper*")) snapshot
             (stale (list :version 1 :root "/stale/ledger"
                          :items (vector (list :sessionId "ghost-id" :file "ghost.jsonl"
                                               :label "ghost")))))
        (unwind-protect
            (progn
              (switch-to-buffer parent)
              (pilish-chat-mode)
              (setq pilish--state (list :session-file anchor))
              (pilish--display-tool-end
               "delegate_work" nil [(:type "text" :text "Direct declaration receipt")]
               (list :savedConversations declaration
                     :pilish (list :savedConversations stale))
               nil (pilish--display-tool-start "delegate_work" nil "call"))
              (let ((ids (mapcar #'cadr (pilish-test--snapshot-name-rows))))
                (should (member "worker-17" ids))
                (should (member "worker-42" ids))
                (should-not (member "ghost-id" ids)))
              (goto-char (point-min))
              (call-interactively (key-binding (kbd "C-c ]")))
              (should (looking-at "reviewer"))
              (call-interactively (key-binding (kbd "RET")))
              (setq snapshot (current-buffer))
              (should (equal pilish--snapshot-source-file child))
              (should (string-match-p "Blue saved conversation" (buffer-string))))
          (pilish-test--kill-live-buffers snapshot parent))))))

(ert-deftest pilish-test-snapshot-malformed-direct-suppresses-wrapper-and-adapter ()
  (pilish-test--with-saved-conversation-files
    (dolist (direct (list :null
                          (list :version 2 :root root
                                :items (vector (list :sessionId "worker-17" :file relative)))))
      (with-temp-buffer
        (pilish-chat-mode)
        (setq pilish--state (list :session-file anchor))
        (let* ((calls 0)
               (pilish-saved-conversation-functions
                (list (lambda (&rest _) (cl-incf calls) declaration)))
               (details (list :savedConversations direct
                              :pilish (list :savedConversations declaration)))
               (block (pilish--display-tool-start "delegate_work" nil "call")))
          (cl-letf (((symbol-function 'insert-file-contents) (lambda (&rest _) (ert-fail "Capture read disk")))
                    ((symbol-function 'file-in-directory-p) (lambda (&rest _) (ert-fail "Capture checked disk"))))
            (pilish--display-tool-end
             "delegate_work" nil [(:type "text" :text "Conflicting declaration receipt")]
             details nil block))
          (should (= calls 0))
          (goto-char (point-min))
          (search-forward "unavailable")
          (should (stringp (get-text-property (1- (point)) 'pilish-subagent-name)))
          (should-not (button-at (1- (point))))
          (should-not (pilish-test--snapshot-name-rows)))))))

(ert-deftest pilish-test-snapshot-adapter-captures-despite-stale-branded-metadata ()
  (pilish-test--with-saved-conversation-files
    (save-window-excursion
      (let* ((parent (generate-new-buffer " *adapter-over-stale*")) snapshot
             (calls 0)
             (stale (list :version 1 :root "/stale/ledger"
                          :items (vector (list :sessionId "ghost-id" :file "ghost.jsonl"
                                               :label "ghost"))))
             (pilish-saved-conversation-functions
              (list (lambda (name _content _details)
                      (cl-incf calls)
                      (should (equal name "delegate_work"))
                      declaration))))
        (unwind-protect
            (progn
              (switch-to-buffer parent)
              (pilish-chat-mode)
              (setq pilish--state (list :session-file anchor))
              (pilish--display-tool-end
               "delegate_work" nil [(:type "text" :text "Adapter receipt")]
               (list :run '(:sessionId "unrelated")
                     :pilish (list :savedConversations stale))
               nil (pilish--display-tool-start "delegate_work" nil "call"))
              (should (= calls 1))
              (goto-char (point-min))
              (call-interactively (key-binding (kbd "C-c ]")))
              (call-interactively (key-binding (kbd "RET")))
              (setq snapshot (current-buffer))
              (should (equal pilish--snapshot-source-file child))
              (should (string-match-p "Blue saved conversation" (buffer-string))))
          (pilish-test--kill-live-buffers snapshot parent))))))

(ert-deftest pilish-test-snapshot-neutral-adapter-errors-do-not-break-rendering ()
  (with-temp-buffer
    (pilish-chat-mode)
    (setq pilish--state '(:session-file "/saved/parent.jsonl"))
    (dolist (adapter (list (lambda (&rest _) (error "Broken capture adapter"))
                          (lambda (&rest _) t)
                          (lambda (&rest _) '(:version 99))))
      (let* ((pilish-saved-conversation-functions (list adapter))
             (presentation (pilish--tool-result-presentation
                            "other_producer" nil [(:type "text" :text "Unrelated tool output survives")]
                            nil nil)))
        (should (string-prefix-p "Unrelated tool output survives" (plist-get presentation :text)))
        (should (equal (substring-no-properties (plist-get presentation :saved-labels)) "unavailable"))
        (should-not (get-text-property 0 'button (plist-get presentation :saved-labels)))))))

(ert-deftest pilish-test-snapshot-valid-capture-is-disk-free-and-copied ()
  (with-temp-buffer
    (pilish-chat-mode)
    (let* ((anchor (copy-sequence "/saved/parent.jsonl"))
           (id (copy-sequence "child-id"))
           (root (copy-sequence "/saved/ledger"))
           (file (copy-sequence "bucket/dialogue.jsonl"))
           (label (copy-sequence "reviewer %s%d"))
           (details (pilish-test--saved-details id label root file))
           (content [(:type "text" :text "## Subagent result\nSubagent session ID: unrelated")])
           (pilish--state (list :session-file anchor))
           (comp-enable-subr-trampolines nil)
           labels)
      (cl-letf (((symbol-function 'insert-file-contents) (lambda (&rest _) (ert-fail "Capture read disk")))
                ((symbol-function 'file-readable-p) (lambda (&rest _) (ert-fail "Capture probed disk")))
                ((symbol-function 'file-exists-p) (lambda (&rest _) (ert-fail "Capture probed disk")))
                ((symbol-function 'file-in-directory-p) (lambda (&rest _) (ert-fail "Capture checked containment"))))
        (setq labels (pilish--saved-conversation-labels "subagent" content details)))
      (dolist (string (list anchor id root file label)) (aset string 0 ?X))
      (let ((target (get-text-property 0 'pilish-subagent-name labels)))
        (should (equal (substring-no-properties labels) "reviewer %s%d"))
        (should (equal (pilish--snapshot-target-anchor-file target) "/saved/parent.jsonl"))
        (should (equal (pilish--snapshot-target-session-id target) "child-id"))
        (should (equal (pilish--snapshot-target-root target) "/saved/ledger"))
        (should (equal (pilish--snapshot-target-file target) "bucket/dialogue.jsonl"))))))

(ert-deftest pilish-test-snapshot-reader-rejects-forged-target-fields-before-io ()
  (dolist (fields '((:anchor-file "/saved/parent.jsonl" :session-id "child" :root "/" :file "child.jsonl")
                    (:anchor-file "/saved/parent.jsonl" :session-id "child" :root "/saved/ledger" :file "../escape")
                    (:anchor-file "/saved/parent.jsonl" :session-id :null :root "/saved/ledger" :file "child.jsonl")
                    (:anchor-file nil :session-id "child" :root "/saved/ledger" :file "child.jsonl")
                    (:anchor-file "/saved/parent.jsonl" :session-id "child" :root "relative" :file "child.jsonl")
                    (:anchor-file "/saved/parent.jsonl" :session-id "child" :root "/ssh:other:/ledger" :file "child.jsonl")))
    (let ((target (apply #'pilish--make-snapshot-target fields)))
      (cl-letf (((symbol-function 'insert-file-contents) (lambda (&rest _) (ert-fail "Invalid target read disk")))
                ((symbol-function 'file-in-directory-p) (lambda (&rest _) (ert-fail "Invalid target checked disk"))))
        (should-error (pilish-jsonl-read-snapshot target) :type 'user-error))))
  (should-error (pilish-jsonl-read-snapshot nil) :type 'user-error))

(ert-deftest pilish-test-snapshot-final-result-labels-belong-to-exact-call ()
  (with-temp-buffer
    (pilish-chat-mode)
    (setq pilish--state '(:session-file "/saved/parent.jsonl"))
    (dolist (id '("first-call" "second-call"))
      (pilish--handle-display-event
       (list :type "tool_execution_start" :toolCallId id :toolName "delegate_work"))
      (pilish--handle-display-event
       (list :type "tool_execution_update" :toolCallId id :toolName "delegate_work"
             :partialResult (list :content [] :details (pilish-test--saved-details id "same")))))
    (cl-letf (((symbol-function 'input-pending-p) (lambda (&optional _) nil)))
      (pilish--flush-tool-updates (current-buffer)))
    (pilish--handle-display-event
     (list :type "tool_execution_end" :toolCallId "first-call" :toolName "delegate_work"
           :result (list :content [] :details (pilish-test--saved-details "final-child" "same"))))
    (should (member "final-child" (mapcar #'cadr (pilish-test--snapshot-name-rows))))
    (should (member "second-call" (mapcar #'cadr (pilish-test--snapshot-name-rows))))
    (should-not (member "first-call" (mapcar #'cadr (pilish-test--snapshot-name-rows))))
    (pilish--handle-display-event
     '(:type "tool_execution_end" :toolCallId "second-call" :toolName "delegate_work" :result (:content [])))
    (should (cl-every (lambda (row) (equal (cadr row) "final-child"))
                      (pilish-test--snapshot-name-rows)))))

(ert-deftest pilish-test-snapshot-header-labels-survive-repaint-with-literal-percents ()
  (with-temp-buffer
    (pilish-chat-mode)
    (setq pilish--state '(:session-file "/saved/parent.jsonl"))
    (let* ((block (pilish--display-tool-start "delegate_work" '(:task "100% complete %s%d") "call"))
           (labels (pilish--saved-conversation-labels
                    "delegate_work" [] (pilish-test--saved-details "first" "reviewer %s%d"))))
      (pilish--annotate-saved-conversation-header block labels)
      (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
        (setq labels (pilish--saved-conversation-labels
                      "delegate_work" [] (pilish-test--saved-details "second" "reviewer %s%d")))
        (pilish--annotate-saved-conversation-header block labels)
        (should (equal (buffer-substring-no-properties (point-min) (point-max)) plain))
        (should (equal (pilish-test--snapshot-name-rows)
                       '(("reviewer %s%d" "second" "/saved/parent.jsonl")))))
      (pilish--annotate-saved-conversation-header block nil)
      (should-not (pilish-test--snapshot-name-rows))
      (should-not (string-match-p "Pi session:" (buffer-string))))))

(ert-deftest pilish-test-snapshot-neutral-strict-v3-identity-and-full-branch ()
  (pilish-test--with-saved-conversation-files
    (let ((target (pilish--snapshot-target-for-pi-v3 anchor "worker-17" root relative)))
      (pilish-test--snapshot-write
       child (list header
                   '(:type "message" :id "system" :parentId :null :message (:role "system" :content "Private saved instructions"))
                   (pilish-test--snapshot-message "user" "system" "Pre-compaction dialogue")
                   (pilish-test--snapshot-message "wrong" "system" "Wrong branch")
                   '(:type "compaction" :id "compact" :parentId "user" :summary "Full summary")))
      (should (equal (mapcar (lambda (message) (plist-get message :role))
                            (append (pilish-jsonl-snapshot-messages (pilish-jsonl-read-snapshot target)) nil))
                     '("system" "user" "compactionSummary")))
      (dolist (records (list (list (plist-put (copy-sequence header) :id "wrong"))
                            (list (plist-put (copy-sequence header) :version 2))
                            (list header (plist-put (copy-sequence header) :cwd "/different"))
                            (list header '(:type "message" :id "leaf" :parentId :null
                                                :message (:role "unknown" :content "Future role")))
                            (list header (pilish-test--snapshot-message "leaf" "missing" "Dangling"))))
        (pilish-test--snapshot-write child records)
        (should-error (pilish-open-subagent-snapshot target) :type 'user-error))
      (pilish-test--snapshot-write child (list header) "not-json\n")
      (should-error (pilish-jsonl-read-snapshot target) :type 'user-error))))

(ert-deftest pilish-test-snapshot-neutral-rechecks-symlink-containment ()
  (pilish-test--with-saved-conversation-files
    (let* ((target (pilish--snapshot-target-for-pi-v3 anchor "worker-17" root relative))
           (outside (expand-file-name "outside.jsonl" directory)))
      (should (pilish-jsonl-read-snapshot target))
      (pilish-test--snapshot-write outside (list header))
      (delete-file child)
      (make-symbolic-link outside child)
      (should-error (pilish-jsonl-read-snapshot target) :type 'user-error))))

(ert-deftest pilish-test-snapshot-neutral-captured-multihop-route ()
  (let* ((route "/ssh:bastion|sudo:host:")
         (anchor (concat route "/sessions/root.jsonl"))
         (target (pilish--snapshot-target-for-pi-v3 anchor "worker-17" "/var/ledger" "workers/dialogue.jsonl"))
         (child (concat route "/var/ledger/workers/dialogue.jsonl"))
         (default-directory "/ssh:unrelated:/elsewhere/")
         reads)
    (should-not (pilish--snapshot-target-for-pi-v3 anchor "worker-17" "/ssh:other:/ledger" "dialogue.jsonl"))
    (should-not (pilish--snapshot-target-for-pi-v3 anchor "worker-17" "/" "dialogue.jsonl"))
    (cl-letf (((symbol-function 'file-readable-p) (lambda (file) (equal file child)))
              ((symbol-function 'file-in-directory-p)
               (lambda (file root)
                 (should (equal file child))
                 (should (equal root (concat route "/var/ledger/"))) t))
              ((symbol-function 'insert-file-contents)
               (lambda (file &rest _)
                 (push file reads)
                 (insert (json-serialize '(:type "session" :version 3 :id "worker-17" :cwd "/work")) "\n")
                 (list file 1))))
      (let ((saved (pilish-jsonl-read-snapshot target)))
        (should (equal (pilish-jsonl-snapshot-cwd saved) (concat route "/work/")))
        (should (equal reads (list child)))))))

(ert-deftest pilish-test-snapshot-neutral-native-final-result-cold-activation ()
  (pilish-test--with-saved-conversation-files
    (save-window-excursion
      (let* ((parent (generate-new-buffer " *neutral-native-parent*")) snapshot
             (calls 0)
             (pilish-saved-conversation-functions
              (list (lambda (name _content _details)
                      (when (equal name "delegate_work") (cl-incf calls) declaration)))))
        (unwind-protect
            (progn
              (switch-to-buffer parent)
              (pilish-chat-mode)
              (setq pilish--state (list :session-file anchor))
              (pilish--handle-display-event '(:type "tool_execution_start" :toolCallId "owner" :toolName "codemode" :args (:code "await delegate();")))
              (pilish--handle-display-event '(:type "tool_execution_start" :toolCallId "not-a-session" :parentToolCallId "owner"
                                                     :toolName "delegate_work" :args (:task "reviewer")))
              (pilish--handle-display-event '(:type "tool_execution_end" :toolCallId "not-a-session" :parentToolCallId "owner"
                                                     :toolName "delegate_work" :result (:content [(:type "text" :text "Saved receipt")])))
              (should (= calls 1))
              (setq pilish-saved-conversation-functions nil)
              (let* ((block (pilish--tool-block-get "owner"))
                     (call (car (pilish--tool-block-nested-calls block)))
                     (overlay (pilish--tool-block-overlay block)))
                (goto-char (point-min))
                (re-search-forward "^Output$")
                (button-activate (button-at (1- (point))))
                (should (equal (mapcar #'cadr (pilish-test--snapshot-name-rows))
                               '("worker-17" "worker-42" "worker-17" "worker-42")))
                (pilish--handle-display-event '(:type "tool_execution_end" :toolCallId "owner" :toolName "codemode" :result (:content [])))
                (pilish--cool-tool-overlay overlay)
                (should-not (pilish--nested-call-result call))
                (should-not (pilish--tool-block-nested-calls block))
                (should-not (pilish--tool-block-result block))
                (should-not (pilish--tool-block-displayed-output block)))
              (goto-char (point-min))
              (pilish-next-subagent-name)
              (pilish-next-subagent-name)
              (call-interactively (key-binding (kbd "RET")))
              (setq snapshot (current-buffer))
              (should (equal pilish--snapshot-source-file other))
              (should (string-match-p "Red saved conversation" (buffer-string))))
          (pilish-test--kill-live-buffers snapshot parent))))))

(ert-deftest pilish-test-snapshot-native-run-and-envelope-without-declaration-stay-inert ()
  (dolist (tool '("subagent" "subagent_resume" "renamed_tool"))
    (with-temp-buffer
      (pilish-chat-mode)
      (setq pilish--state '(:session-file "/saved/parent.jsonl"))
      (pilish--handle-display-event
       '(:type "tool_execution_start" :toolCallId "owner" :toolName "codemode"))
      (pilish--handle-display-event
       (list :type "tool_execution_start" :toolCallId "child" :parentToolCallId "owner"
             :toolName tool :args '(:sessionId "argument-child" :agent "same")))
      (pilish--handle-display-event
       (list :type "tool_execution_end" :toolCallId "child" :parentToolCallId "owner"
             :toolName tool :result
             '(:content [(:type "text" :text "## Subagent same result\nSubagent session ID: 01234567-0123-0123-0123-0123456789ab\n\nSaved answer")]
                        :details (:run (:sessionId "child-id" :episodeId "episode" :agent "same")))))
      (should (string-match-p "argument-child" (buffer-string)))
      (should-not (text-property-not-all (point-min) (point-max) 'pilish-subagent-name nil)))))

(ert-deftest pilish-test-snapshot-neutral-native-partial-identity-is-not-final ()
  (pilish-test--with-saved-conversation-files
    (with-temp-buffer
      (pilish-chat-mode)
      (setq pilish--state (list :session-file anchor))
      (pilish--handle-display-event '(:type "tool_execution_start" :toolCallId "owner" :toolName "codemode" :args (:code "await delegate();")))
      (pilish--handle-display-event '(:type "tool_execution_start" :toolCallId "child" :parentToolCallId "owner" :toolName "delegate_work"))
      (pilish--handle-display-event
       (list :type "tool_execution_update" :toolCallId "child" :parentToolCallId "owner" :toolName "delegate_work"
             :partialResult (list :content [] :details (list :savedConversations declaration))))
      (pilish--handle-display-event '(:type "tool_execution_end" :toolCallId "child" :parentToolCallId "owner" :toolName "delegate_work" :result (:content [])))
      (pilish--handle-display-event '(:type "tool_execution_end" :toolCallId "owner" :toolName "codemode" :result (:content [])))
      (should-not (pilish-test--snapshot-name-rows)))))

(ert-deftest pilish-test-snapshot-neutral-nested-source-independent-of-parent-layout ()
  (pilish-test--with-saved-conversation-files
    (let* ((nested-root (expand-file-name "separate-ledger" directory))
           (nested (expand-file-name "reviews/followup/transcript.jsonl" nested-root))
           (target (pilish--snapshot-target-for-pi-v3 anchor "worker-17" root relative))
           parent snapshot descendant)
      (pilish-test--snapshot-write nested (list (list :type "session" :version 3 :id "peer-id" :cwd directory)
                                               (pilish-test--snapshot-message "leaf" nil "Independent peer review")))
      (pilish-test--snapshot-write
       child (list header
                   '(:type "message" :id "call" :parentId :null :message
                           (:role "assistant" :content [(:type "toolCall" :id "peer" :name "request_peer_review" :arguments ())]))
                   (list :type "message" :id "result" :parentId "call" :message
                         (list :role "toolResult" :toolCallId "peer" :content []
                               :details (list :savedConversations
                                              (list :version 1 :root nested-root :items
                                                    [(:sessionId "peer-id" :file "reviews/followup/transcript.jsonl" :label "peer")]))))))
      (unwind-protect
          (save-window-excursion
            (setq parent (generate-new-buffer " *neutral-nested-parent*"))
            (switch-to-buffer parent)
            (pilish-chat-mode)
            (setq snapshot (pilish-open-subagent-snapshot target))
            (should (equal (cl-remove-duplicates (mapcar #'caddr (pilish-test--snapshot-name-rows)) :test #'equal)
                           (list child)))
            (kill-buffer parent)
            (goto-char (point-min))
            (pilish-next-subagent-name)
            (call-interactively (key-binding (kbd "RET")))
            (setq descendant (current-buffer))
            (should (equal pilish--snapshot-source-file nested))
            (should (string-match-p "Independent peer review" (buffer-string))))
        (pilish-test--kill-live-buffers descendant snapshot parent)))))

(defun pilish-test--snapshot-tool-entries (header output)
  "Return HEADER plus one bash tool call and result whose output is OUTPUT."
  (list header
        (pilish-test--snapshot-message "user" nil "Run a tool")
        (list :type "message" :id "assistant" :parentId "user"
              :message (list :role "assistant"
                             :content (vector (list :type "toolCall" :id "call_1" :name "bash"
                                                    :arguments (list :command "emit output")))
                             :timestamp 0))
        (list :type "message" :id "result" :parentId "assistant"
              :message (list :role "toolResult" :toolCallId "call_1"
                             :content (vector (list :type "text" :text output))
                             :details nil :timestamp 0))))

(defun pilish-test--snapshot-hidden-stage-names ()
  "Return live buffer names belonging to hidden snapshot stages."
  (cl-remove-if-not (lambda (name) (string-prefix-p " *pilish-snapshot" name))
                    (mapcar #'buffer-name (buffer-list))))

(defun pilish-test--snapshot-refresh (expected-message)
  "Refresh the observer and assert EXPECTED-MESSAGE without printing it."
  (let (messages result)
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) messages))))
      (setq result (pilish-snapshot-refresh)))
    (should (member expected-message messages))
    result))

(ert-deftest pilish-test-snapshot-refresh-requires-snapshot-mode ()
  (with-temp-buffer
    (pilish-chat-mode)
    (should-error (pilish-snapshot-refresh) :type 'user-error)))

(ert-deftest pilish-test-snapshot-digest-covers-content-and-cwd ()
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "Same text")))
    (let ((first (pilish-jsonl-snapshot-digest (pilish-jsonl-read-snapshot target))))
      (should (equal first (pilish-jsonl-snapshot-digest (pilish-jsonl-read-snapshot target))))
      (pilish-test--snapshot-write
       child (list (plist-put (copy-sequence header) :cwd "/var")
                   (pilish-test--snapshot-message "leaf" nil "Same text")))
      (should-not (equal first (pilish-jsonl-snapshot-digest (pilish-jsonl-read-snapshot target))))
      (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "Other text")))
      (should-not (equal first (pilish-jsonl-snapshot-digest (pilish-jsonl-read-snapshot target)))))))

(ert-deftest pilish-test-snapshot-refresh-unchanged-keeps-view-folds-and-clears-note ()
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write
     child (pilish-test--snapshot-tool-entries
            header (mapconcat (lambda (n) (format "fold-line-%02d" n))
                              (number-sequence 1 15) "\n")))
    (save-window-excursion
      (switch-to-buffer (generate-new-buffer " *snapshot-refresh-parent*"))
      (let ((parent (current-buffer)) snapshot win line-pos messages)
        (unwind-protect
            (progn
              (setq snapshot (pilish-open-subagent-snapshot target))
              (setq win (selected-window))
              (should (string-match-p "fold-line-05" (buffer-string)))
              (should-not (string-match-p "fold-line-15" (buffer-string)))
              (should (string-match-p "^Output$" (buffer-string)))
              (goto-char (point-min))
              (search-forward "fold-line-01")
              (execute-kbd-macro (kbd "TAB"))
              (goto-char (point-min))
              (search-forward "fold-line-15")
              (setq line-pos (point))
              (pilish--set-snapshot-refresh-note
               "Refresh failed: synthetic earlier failure")
              (let ((start (window-start win)))
                (cl-letf (((symbol-function 'message)
                           (lambda (fmt &rest args)
                             (push (apply #'format fmt args) messages))))
                  (execute-kbd-macro (kbd "g")))
                (should (member "Saved conversation unchanged" messages))
                (should (eq (current-buffer) snapshot))
                (should-not pilish--snapshot-refresh-note)
                (should (= (point) line-pos))
                (should (= (window-start win) start))
                (should (string-match-p "fold-line-15" (buffer-string)))))
          (pilish-test--kill-live-buffers snapshot parent))))))

(ert-deftest pilish-test-snapshot-refresh-changed-replaces-observer-in-its-windows ()
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write
     child (pilish-test--snapshot-tool-entries
            header (mapconcat (lambda (n) (format "fold-line-%02d" n))
                              (number-sequence 1 15) "\n")))
    (pilish-test-with-mock-session directory
      (let* ((parent (pilish--find-session directory))
             (input (buffer-local-value 'pilish--input-buffer parent))
             (canonical [(:role "user" :content "Parent message")])
             snapshot replacement messages window-count)
        (unwind-protect
            (save-window-excursion
              (switch-to-buffer parent)
              (setq pilish--state (list :session-file anchor)
                    pilish--status 'sending
                    pilish--canonical-messages canonical)
              (with-current-buffer input (insert "Unsent parent draft"))
              (setq snapshot (pilish-open-subagent-snapshot target))
              (setq window-count (length (window-list)))
              (goto-char (point-min))
              (search-forward "fold-line-01")
              (execute-kbd-macro (kbd "TAB"))
              (should (string-match-p "fold-line-15" (buffer-string)))
              (let ((snapshot-window (selected-window))
                    (snapshot-name (buffer-name snapshot)))
                (cl-letf (((symbol-function 'display-buffer)
                           (lambda (&rest _) (ert-fail "Refresh displayed a new window")))
                          ((symbol-function 'message)
                           (lambda (fmt &rest args)
                             (push (apply #'format fmt args) messages))))
                  (pilish-test--snapshot-write
                   child (append (pilish-test--snapshot-tool-entries
                                  header (mapconcat (lambda (n) (format "fold-line-%02d" n))
                                                    (number-sequence 1 15) "\n"))
                                 (list (pilish-test--snapshot-message "later" "result" "Fresh saved text"))))
                  (execute-kbd-macro (kbd "g")))
                (setq replacement (window-buffer snapshot-window))
                (should (member "Saved conversation updated" messages))
                (should-not (eq replacement snapshot))
                (should-not (buffer-live-p snapshot))
                (should (eq (window-buffer snapshot-window) replacement))
                (should (= (length (window-list)) window-count))
                (should (equal (buffer-name replacement) snapshot-name))
                (with-current-buffer replacement
                  (should (equal pilish--snapshot-source-file child))
                  (should (equal default-directory (file-name-as-directory directory)))
                  (should buffer-read-only)
                  (should-not buffer-file-name)
                  (should (eq revert-buffer-function #'pilish--snapshot-revert-buffer))
                  (should (string-match-p "Fresh saved text" (buffer-string)))
                  (should (string-match-p "fold-line-05" (buffer-string)))
                  (should-not (string-match-p "fold-line-15" (buffer-string)))
                  (should (string-match-p "^Output$" (buffer-string))))
                (should (equal (buffer-local-value 'pilish--status parent) 'sending))
                (should (equal (buffer-local-value 'pilish--state parent) (list :session-file anchor)))
                (should (eq (buffer-local-value 'pilish--canonical-messages parent) canonical))
                (should (equal (with-current-buffer input (buffer-string)) "Unsent parent draft"))
                (should (eq (pilish--find-session directory) parent))))
          (pilish-test--kill-live-buffers replacement snapshot))))))

(ert-deftest pilish-test-snapshot-refresh-neutral-target ()
  (pilish-test--with-saved-conversation-files
    (let ((target (pilish--snapshot-target-for-pi-v3 anchor "worker-17" root relative)))
      (save-window-excursion
        (let (snapshot replacement)
          (unwind-protect
              (progn
                (setq snapshot (pilish-open-subagent-snapshot target))
                (should (string-match-p "Blue saved conversation" (buffer-string)))
                (should (eq (with-current-buffer snapshot
                              (pilish-test--snapshot-refresh "Saved conversation unchanged"))
                            snapshot))
                (pilish-test--snapshot-write
                 child (list header (pilish-test--snapshot-message "leaf" nil "Blue conversation rewritten")))
                (setq replacement (with-current-buffer snapshot
                                    (pilish-test--snapshot-refresh "Saved conversation updated")))
                (should-not (eq replacement snapshot))
                (should-not (buffer-live-p snapshot))
                (with-current-buffer replacement
                  (should (string-match-p "Blue conversation rewritten" (buffer-string)))
                  (should (equal pilish--snapshot-source-file child))))
            (pilish-test--kill-live-buffers replacement snapshot)))))))

(ert-deftest pilish-test-snapshot-refresh-detects-same-size-same-mtime-rewrite ()
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "First saved text")))
    (save-window-excursion
      (let (snapshot replacement)
        (unwind-protect
            (progn
              (setq snapshot (pilish-open-subagent-snapshot target))
              (let ((size (file-attribute-size (file-attributes child)))
                    (mtime (file-attribute-modification-time (file-attributes child))))
                (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "Equal saved text")))
                (set-file-times child mtime)
                (should (= size (file-attribute-size (file-attributes child))))
                (setq replacement (with-current-buffer snapshot
                                    (pilish-test--snapshot-refresh "Saved conversation updated")))
                (should-not (eq replacement snapshot))
                (with-current-buffer replacement
                  (should (string-match-p "Equal saved text" (buffer-string))))))
          (pilish-test--kill-live-buffers replacement snapshot))))))

(ert-deftest pilish-test-snapshot-refresh-revalidates-explicit-identity ()
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "First saved text")))
    (save-window-excursion
      (let (snapshot)
        (unwind-protect
            (progn
              (setq snapshot (pilish-open-subagent-snapshot target))
              (pilish-test--snapshot-write
               child (list (plist-put (copy-sequence header) :id "wrong-id")
                           (pilish-test--snapshot-message "leaf" nil "First saved text")))
              (should-error (with-current-buffer snapshot (pilish-snapshot-refresh))
                            :type 'user-error)
              (should (buffer-live-p snapshot))
              (should (eq (window-buffer (selected-window)) snapshot))
              (should (string-match-p "First saved text"
                                      (with-current-buffer snapshot (buffer-string))))
              (should (string-match-p "Refresh failed:"
                                      (buffer-local-value
                                       'pilish--snapshot-refresh-note snapshot)))
              (should-not (pilish-test--snapshot-hidden-stage-names))
              (pilish-test--snapshot-write
               child (list header (pilish-test--snapshot-message "leaf" nil "First saved text")))
              (should (eq (with-current-buffer snapshot
                            (pilish-test--snapshot-refresh "Saved conversation unchanged")) snapshot))
              (should-not (buffer-local-value 'pilish--snapshot-refresh-note snapshot)))
          (pilish-test--kill-live-buffers snapshot))))))

(ert-deftest pilish-test-snapshot-refresh-revalidates-real-containment ()
  (pilish-test--with-snapshot-files
    (let ((outside (expand-file-name "outside.jsonl" directory)))
      (pilish-test--snapshot-write
       child (list header (pilish-test--snapshot-message "leaf" nil "Last good saved text")))
      (pilish-test--snapshot-write
       outside (list header (pilish-test--snapshot-message "leaf" nil "Escaped saved text")))
      (save-window-excursion
        (let (snapshot)
          (unwind-protect
              (progn
                (setq snapshot (pilish-open-subagent-snapshot target))
                (delete-file child)
                (make-symbolic-link outside child)
                (should-error (pilish-snapshot-refresh) :type 'user-error)
                (should (eq (window-buffer (selected-window)) snapshot))
                (should (string-match-p "Last good saved text" (buffer-string)))
                (should-not (string-match-p "Escaped saved text" (buffer-string)))
                (should (string-match-p "Refresh failed:" pilish--snapshot-refresh-note))
                (should-not (pilish-test--snapshot-hidden-stage-names)))
            (pilish-test--kill-live-buffers snapshot)))))))

(ert-deftest pilish-test-snapshot-refresh-read-failure-keeps-old-usable ()
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "First saved text")))
    (save-window-excursion
      (let (snapshot)
        (unwind-protect
            (progn
              (setq snapshot (pilish-open-subagent-snapshot target))
              (goto-char (point-min))
              (search-forward "First saved text")
              (let ((pos (point)))
                (delete-file child)
                (should-error (with-current-buffer snapshot (pilish-snapshot-refresh))
                              :type 'user-error)
                (should (buffer-live-p snapshot))
                (should (eq (window-buffer (selected-window)) snapshot))
                (should (= (point) pos))
                (should (string-match-p "Refresh failed:" pilish--snapshot-refresh-note))
                (should-not (pilish-test--snapshot-hidden-stage-names))
                (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "First saved text")))
                (should (eq (with-current-buffer snapshot
                              (pilish-test--snapshot-refresh "Saved conversation unchanged")) snapshot))
                (should-not pilish--snapshot-refresh-note)))
          (pilish-test--kill-live-buffers snapshot))))))

(ert-deftest pilish-test-snapshot-refresh-quit-resets-guard-and-notes-stale ()
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "First saved text")))
    (save-window-excursion
      (let (snapshot)
        (unwind-protect
            (progn
              (setq snapshot (pilish-open-subagent-snapshot target))
              (let ((observer pilish--snapshot-observer))
                (cl-letf (((symbol-function 'pilish-jsonl-read-snapshot)
                           (lambda (&rest _) (signal 'quit nil))))
                  (should (eq 'interrupted
                              (condition-case nil
                                  (progn (pilish-snapshot-refresh) nil)
                                (quit 'interrupted)))))
                (should (buffer-live-p snapshot))
                (should (equal pilish--snapshot-refresh-note "Refresh failed: interrupted"))
                (should-not (pilish--snapshot-observer-refreshing-p observer))
                (should (eq (pilish-test--snapshot-refresh "Saved conversation unchanged") snapshot))
                (should-not pilish--snapshot-refresh-note)))
          (pilish-test--kill-live-buffers snapshot))))))

(ert-deftest pilish-test-snapshot-refresh-render-failure-leaves-no-stage ()
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "First saved text")))
    (save-window-excursion
      (let (snapshot)
        (unwind-protect
            (progn
              (setq snapshot (pilish-open-subagent-snapshot target))
              (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "New saved text")))
              (let ((before (buffer-list)))
                (cl-letf (((symbol-function 'pilish--replay-history)
                           (lambda (&rest _) (error "Synthetic render failure"))))
                  (should-error (with-current-buffer snapshot (pilish-snapshot-refresh))))
                (should (equal (buffer-list) before)))
              (should (buffer-live-p snapshot))
              (should (eq (window-buffer (selected-window)) snapshot))
              (should (string-match-p "First saved text"
                                      (with-current-buffer snapshot (buffer-string))))
              (should (string-match-p "Refresh failed: Synthetic render failure"
                                      (buffer-local-value
                                       'pilish--snapshot-refresh-note snapshot))))
          (pilish-test--kill-live-buffers snapshot))))))

(ert-deftest pilish-test-snapshot-refresh-publication-failure-rolls-back ()
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "First saved text")))
    (save-window-excursion
      (let (snapshot)
        (unwind-protect
            (progn
              (setq snapshot (pilish-open-subagent-snapshot target))
              (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "New saved text")))
              (let ((real (symbol-function 'set-window-buffer))
                    (name (buffer-name snapshot)))
                (cl-letf (((symbol-function 'set-window-buffer)
                           (lambda (window buffer &optional keep-margins)
                             (if (and (buffer-live-p buffer)
                                      (not (eq buffer snapshot))
                                      (eq (buffer-local-value 'major-mode buffer)
                                          'pilish-snapshot-mode))
                                 (error "Synthetic publication failure")
                               (funcall real window buffer keep-margins)))))
                  (should-error (with-current-buffer snapshot (pilish-snapshot-refresh))))
                (should (buffer-live-p snapshot))
                (should (equal (buffer-name snapshot) name))
                (should (eq (window-buffer (selected-window)) snapshot))
                (should (string-match-p "First saved text"
                                        (with-current-buffer snapshot (buffer-string))))
                (should-not (pilish-test--snapshot-hidden-stage-names))
                (should (buffer-local-value 'pilish--snapshot-refresh-note snapshot)))
              (let ((replacement (with-current-buffer snapshot
                                   (pilish-test--snapshot-refresh "Saved conversation updated"))))
                (unwind-protect
                    (progn
                      (should-not (eq replacement snapshot))
                      (should-not (buffer-live-p snapshot))
                      (should (eq (window-buffer (selected-window)) replacement))
                      (with-current-buffer replacement
                        (should (string-match-p "New saved text" (buffer-string)))))
                  (pilish-test--kill-live-buffers replacement))))
          (pilish-test--kill-live-buffers snapshot))))))

(ert-deftest pilish-test-snapshot-refresh-observers-stay-independent ()
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "First saved text")))
    (save-window-excursion
      (let (first second first-replacement)
        (unwind-protect
            (progn
              (setq first (pilish-open-subagent-snapshot target))
              (setq second (pilish-open-subagent-snapshot target))
              (should-not (eq first second))
              (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "New saved text")))
              (setq first-replacement (with-current-buffer first
                                        (pilish-test--snapshot-refresh "Saved conversation updated")))
              (should-not (eq first-replacement first))
              (should-not (buffer-live-p first))
              (with-current-buffer first-replacement
                (should (string-match-p "New saved text" (buffer-string))))
              (should (buffer-live-p second))
              (with-current-buffer second
                (should (string-match-p "First saved text" (buffer-string)))
                (should-not (string-match-p "New saved text" (buffer-string))))
              (setq second (with-current-buffer second
                             (pilish-test--snapshot-refresh "Saved conversation updated")))
              (with-current-buffer second
                (should (string-match-p "New saved text" (buffer-string)))
                (should-not (string-match-p "First saved text" (buffer-string)))))
          (pilish-test--kill-live-buffers first-replacement first second))))))

(ert-deftest pilish-test-snapshot-refresh-switches-every-window-showing-the-observer ()
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "First saved text")))
    (save-window-excursion
      (switch-to-buffer (generate-new-buffer " *snapshot-two-window-parent*"))
      (let ((parent (current-buffer)) snapshot replacement)
        (unwind-protect
            (progn
              (setq snapshot (pilish-open-subagent-snapshot target))
              (let* ((win1 (selected-window))
                     (win2 (split-window win1 nil 'right)))
                (set-window-buffer win2 snapshot)
                (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "New saved text")))
                (setq replacement (with-current-buffer snapshot
                                    (pilish-test--snapshot-refresh "Saved conversation updated")))
                (should (eq (window-buffer win1) replacement))
                (should (eq (window-buffer win2) replacement))
                (should-not (buffer-live-p snapshot))))
          (pilish-test--kill-live-buffers replacement snapshot parent))))))

(ert-deftest pilish-test-snapshot-refresh-survives-parent-death ()
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "First saved text")))
    (save-window-excursion
      (switch-to-buffer (generate-new-buffer " *snapshot-orphan-parent*"))
      (let ((parent (current-buffer)) snapshot replacement)
        (unwind-protect
            (progn
              (setq snapshot (pilish-open-subagent-snapshot target))
              (kill-buffer parent)
              (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "New saved text")))
              (setq replacement (with-current-buffer snapshot
                                  (pilish-test--snapshot-refresh "Saved conversation updated")))
              (should-not (eq replacement snapshot))
              (with-current-buffer replacement
                (should (string-match-p "New saved text" (buffer-string)))))
          (pilish-test--kill-live-buffers replacement snapshot parent))))))

(ert-deftest pilish-test-snapshot-refresh-quit-returns-toward-parent ()
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "First saved text")))
    (save-window-excursion
      (switch-to-buffer (generate-new-buffer " *snapshot-refresh-quit-parent*"))
      (let ((parent (current-buffer)) snapshot replacement)
        (unwind-protect
            (progn
              (setq snapshot (pilish-open-subagent-snapshot target))
              (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "New saved text")))
              (setq replacement (with-current-buffer snapshot
                                  (pilish-test--snapshot-refresh "Saved conversation updated")))
              (execute-kbd-macro (kbd "q"))
              (should-not (buffer-live-p replacement))
              (should (buffer-live-p parent))
              (should (eq (window-buffer (selected-window)) parent))
              (should-not (pilish-test--snapshot-hidden-stage-names)))
          (pilish-test--kill-live-buffers replacement snapshot parent))))))

(ert-deftest pilish-test-snapshot-refresh-restores-tail-middle-and-clamped-views ()
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write
     child (cons header (cl-loop for n from 1 to 10 collect
                                 (pilish-test--snapshot-message
                                  (format "m%d" n) (unless (= n 1) (format "m%d" (1- n)))
                                  (format "message-%02d" n)))))
    (save-window-excursion
      (switch-to-buffer (generate-new-buffer " *snapshot-refresh-views-parent*"))
      (let ((parent (current-buffer)) snapshot replacement win)
        (unwind-protect
            (progn
              (setq snapshot (pilish-open-subagent-snapshot target))
              (setq win (selected-window))
              (with-selected-window win (goto-char (point-max)))
              (pilish-test--snapshot-write
               child (cons header (append
                                   (cl-loop for n from 1 to 10 collect
                                            (pilish-test--snapshot-message
                                             (format "m%d" n) (unless (= n 1) (format "m%d" (1- n)))
                                             (format "message-%02d" n)))
                                   (list (pilish-test--snapshot-message "m11" "m10" "message-11")))))
              (setq replacement (with-current-buffer snapshot
                                  (pilish-test--snapshot-refresh "Saved conversation updated")))
              (should-not (eq replacement snapshot))
              (should (= (window-point win)
                         (with-current-buffer replacement (point-max))))
              (should (string-match-p "message-11"
                                      (with-current-buffer replacement (buffer-string))))
              (with-current-buffer replacement
                (goto-char (point-min))
                (search-forward "message-03"))
              (let ((start (with-current-buffer replacement (point))))
                (with-current-buffer replacement
                  (goto-char (point-min))
                  (search-forward "message-05"))
                (let ((pos (with-current-buffer replacement (point))))
                  (set-window-start win start t)
                  (set-window-point win pos)
                  (pilish-test--snapshot-write
                   child (cons header (append
                                       (cl-loop for n from 1 to 11 collect
                                                (pilish-test--snapshot-message
                                                 (format "m%d" n) (unless (= n 1) (format "m%d" (1- n)))
                                                 (format "message-%02d" n)))
                                       (list (pilish-test--snapshot-message "m12" "m11" "message-12")))))
                  (setq snapshot replacement
                        replacement (with-current-buffer snapshot
                                      (pilish-test--snapshot-refresh "Saved conversation updated")))
                  (should (= (window-point win) pos))
                  (should (= (window-start win) start))
                  (pilish-test--snapshot-write
                   child (list header (pilish-test--snapshot-message "only" nil "only message")))
                  (setq snapshot replacement
                        replacement (with-current-buffer snapshot
                                      (pilish-test--snapshot-refresh "Saved conversation updated")))
                  (should (string-match-p "only message"
                                          (with-current-buffer replacement (buffer-string))))
                  (should (<= (window-point win)
                              (with-current-buffer replacement (point-max))))
                  (should (<= (window-start win) (window-point win))))))
          (pilish-test--kill-live-buffers replacement parent))))))

(ert-deftest pilish-test-snapshot-refresh-branch-rewrite-does-not-alias-thinking-blocks ()
  (pilish-test--with-snapshot-files
    (cl-labels ((thinking (id parent count)
                  (list :type "message" :id id :parentId (or parent :null)
                        :message
                        (list :role "assistant" :timestamp 0
                              :content
                              (vector (list :type "thinking" :thinking
                                            (mapconcat (lambda (n) (format "%s-thought-%02d" id n))
                                                       (number-sequence 1 count) "\n"))
                                      (list :type "text" :text (concat id " answer"))))))
                (branch (first second count)
                  (list header (thinking first nil count) (thinking second first count)
                        (pilish-test--snapshot-message
                         "filler" second
                         (mapconcat (lambda (n) (format "FILLER-%02d" n))
                                    (number-sequence 1 160) "\n")))))
      (pilish-test--snapshot-write child (branch "old-first" "old-second" 60))
      (save-window-excursion
        (let ((pilish-thinking-display 'visible) snapshot replacement messages)
          (unwind-protect
              (progn
                (setq snapshot (pilish-open-subagent-snapshot target))
                (goto-char (point-min))
                (search-forward "old-second-thought-30")
                (let ((win (selected-window))
                      (pos (point)))
                  (set-window-start win (line-beginning-position) t)
                  (should (numberp (pilish--thinking-block-at-pos pos)))
                  (pilish-test--snapshot-write child (branch "new-first" "new-second" 5))
                  (cl-letf (((symbol-function 'message)
                             (lambda (fmt &rest args)
                               (push (apply #'format fmt args) messages))))
                    (setq replacement (pilish-snapshot-refresh)))
                  (should (member "Saved conversation updated" messages))
                  (should-not (buffer-live-p snapshot))
                  (with-current-buffer replacement
                    (should (= (window-point win) (min pos (point-max))))
                    (goto-char (window-point win))
                    (should (string-prefix-p "FILLER-" (thing-at-point 'line t))))))
            (pilish-test--kill-live-buffers replacement snapshot)))))))

(ert-deftest pilish-test-snapshot-refresh-renders-with-displayed-width ()
  (pilish-test--with-snapshot-files
    (let* ((long-line (make-string 500 ?x))
           (entries (pilish-test--snapshot-tool-entries header long-line)))
      (pilish-test--snapshot-write child entries)
      (save-window-excursion
        (let (snapshot replacement)
          (unwind-protect
              (progn
                (setq snapshot (pilish-open-subagent-snapshot target))
                (delete-other-windows (selected-window))
                (should (string-match-p (make-string 300 ?x) (buffer-string)))
                (split-window-right)
                (pilish-test--snapshot-write
                 child (append entries (list (pilish-test--snapshot-message "later" "result" "Width marker"))))
                (setq replacement (with-current-buffer snapshot
                                    (pilish-test--snapshot-refresh "Saved conversation updated")))
                (should-not (eq replacement snapshot))
                (with-current-buffer replacement
                  (should (< (pilish--chat-display-width) 60))
                  (should-not (string-match-p (make-string 300 ?x) (buffer-string)))
                  (should (string-match-p (make-string 100 ?x) (buffer-string)))
                  (should (string-match-p "^Output$" (buffer-string)))
                  (should (string-match-p "Width marker" (buffer-string)))))
            (pilish-test--kill-live-buffers replacement snapshot)))))))

(ert-deftest pilish-test-snapshot-refresh-via-revert-buffer ()
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "First saved text")))
    (save-window-excursion
      (let (snapshot)
        (unwind-protect
            (progn
              (setq snapshot (pilish-open-subagent-snapshot target))
              (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "New saved text")))
              (let (messages)
                (cl-letf (((symbol-function 'message)
                           (lambda (fmt &rest args)
                             (push (apply #'format fmt args) messages))))
                  (with-current-buffer snapshot (revert-buffer nil t)))
                (should (member "Saved conversation updated" messages)))
              (let ((replacement (get-buffer "*pilish-snapshot:child-id*")))
                (should-not (eq replacement snapshot))
                (should-not (buffer-live-p snapshot))
                (should (string-match-p "New saved text"
                                        (with-current-buffer replacement (buffer-string))))))
          (pilish-test--kill-live-buffers snapshot (get-buffer "*pilish-snapshot:child-id*")))))))

(ert-deftest pilish-test-snapshot-evil-g-refreshes-and-q-quits ()
  (skip-unless (require 'evil nil t))
  (let ((pilish-chat-mode-hook pilish-chat-mode-hook)
        (evil-snipe-local-mode-hook evil-snipe-local-mode-hook)
        (evil-snipe-override-local-mode-hook evil-snipe-override-local-mode-hook))
    (require 'pilish-evil)
    (pilish-evil-setup)
    (pilish-test--with-snapshot-files
      (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "Evil saved answer")))
      (save-window-excursion
        (let ((parent (generate-new-buffer " *snapshot-evil-refresh-parent*")) snapshot replacement)
          (unwind-protect
              (progn
                (switch-to-buffer parent)
                (pilish-chat-mode)
                (setq snapshot (pilish-open-subagent-snapshot target))
                (evil-local-mode 1)
                (should (eq evil-state 'motion))
                (should (eq (key-binding "g") #'pilish-snapshot-refresh))
                (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "Evil refreshed answer")))
                (let ((win (selected-window)) messages)
                  (cl-letf (((symbol-function 'message)
                             (lambda (fmt &rest args)
                               (push (apply #'format fmt args) messages))))
                    (execute-kbd-macro "g"))
                  (should (member "Saved conversation updated" messages))
                  (setq replacement (window-buffer win)))
                (should-not (eq replacement snapshot))
                (should-not (buffer-live-p snapshot))
                (should (string-match-p "Evil refreshed answer" (buffer-string)))
                (execute-kbd-macro "q")
                (should-not (buffer-live-p replacement))
                (should (buffer-live-p parent)))
            (pilish-test--kill-live-buffers replacement snapshot parent)))))))

(ert-deftest pilish-test-polish-snapshot-publication-keeps-window-margins ()
  "Replacement snapshots retain each reader's independent margin widths."
  (let ((old (generate-new-buffer " *polish-old-snapshot*"))
        (staged (generate-new-buffer " *polish-staged-snapshot*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (dolist (buffer (list old staged))
            (with-current-buffer buffer
              (pilish-snapshot-mode)
              (pilish--replay-history buffer [] "Snapshot text\n" 25)
              (should (= left-margin-width 1))))
          (switch-to-buffer old)
          (let ((first (selected-window)) (second (split-window-right 28)))
            (set-window-buffer second old)
            (set-window-margins first 3 2)
            (set-window-margins second 1 4)
            (let ((views (with-current-buffer old (pilish--capture-window-rewrite-states))))
              (should (eq staged (pilish--snapshot-publish-replacement old staged views))))
            (should (equal (window-margins first) '(3 . 2)))
            (should (equal (window-margins second) '(1 . 4)))
            (should (eq (window-buffer first) staged))
            (should (eq (window-buffer second) staged))))
      (when (buffer-live-p old) (kill-buffer old))
      (when (buffer-live-p staged) (kill-buffer staged)))))

(provide 'pilish-snapshot-test)
