;;; -*- lexical-binding: t; -*-

(require 'pilish-test-common)
(require 'pilish)

(defvar evil-snipe-local-mode-hook nil)
(defvar evil-snipe-override-local-mode-hook nil)

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
      (let ((saved (pilish-jsonl-read-subagent-snapshot target)))
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
    (let* ((saved (pilish-jsonl-read-subagent-snapshot target))
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

(ert-deftest pilish-test-snapshot-disk-nested-and-resumed-same-file ()
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write
     manifest (list start (list :type "resume_started" :sessionId "child-id"
                               :episodeId "episode-2" :sessionFile child)))
    (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "latest" nil "Latest saved resume")))
    (dolist (anchor-file (list anchor (concat root "parent-child.jsonl")))
      (dolist (episode '(nil "episode-1" "episode-2"))
        (should (equal (pilish-jsonl-snapshot-messages
                        (pilish-jsonl-read-subagent-snapshot
                         (pilish--snapshot-target anchor-file "child-id" episode)))
                       [(:role "user" :content "Latest saved resume" :timestamp 0)]))))))

(ert-deftest pilish-test-snapshot-disk-mapping-errors ()
  (pilish-test--with-snapshot-files
    (let ((failure (should-error (pilish-jsonl-read-subagent-snapshot target) :type 'user-error)))
      (should (equal (cadr failure) (concat "Saved snapshot file is not readable yet: " child))))
    (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "Saved")))
    (should (equal (pilish-jsonl-snapshot-messages (pilish-jsonl-read-subagent-snapshot target))
                   [(:role "user" :content "Saved" :timestamp 0)]))
    (should-error (pilish-jsonl-read-subagent-snapshot
                   (pilish--snapshot-target anchor "child-id" "wrong-episode")) :type 'user-error)
    (dolist (records (list nil (list start start)
                          (list start (list :type "resume_started" :sessionId "child-id"
                                            :episodeId "episode-2" :sessionFile (concat root "other.jsonl")))
                          (list (plist-put (copy-sequence start) :sessionFile anchor))
                          (list start (list :type "started" :sessionId "different-id"
                                            :episodeId "different-episode" :sessionFile child))))
      (pilish-test--snapshot-write manifest records)
      (should-error (pilish-jsonl-read-subagent-snapshot target) :type 'user-error))))

(ert-deftest pilish-test-snapshot-disk-missing-file-does-not-claim-physical-identity ()
  (pilish-test--with-snapshot-files
    (let ((other (concat root "other.jsonl")))
      (pilish-test--snapshot-write other (list (plist-put (copy-sequence header) :id "other-child")))
      (pilish-test--snapshot-write
       manifest (list start (list :type "started" :sessionId "other-child"
                                  :episodeId "other-episode" :sessionFile other)))
      (let ((failure (should-error (pilish-jsonl-read-subagent-snapshot target) :type 'user-error)))
        (should (equal (cadr failure) (concat "Saved snapshot file is not readable yet: " child)))))))

(ert-deftest pilish-test-snapshot-disk-header-and-complete-record-errors ()
  (pilish-test--with-snapshot-files
    (dolist (bad-header (list (plist-put (copy-sequence header) :id "wrong")
                             (plist-put (copy-sequence header) :version 2)
                             (plist-put (copy-sequence header) :cwd :null)))
      (pilish-test--snapshot-write child (list bad-header))
      (should-error (pilish-jsonl-read-subagent-snapshot target) :type 'user-error))
    (pilish-test--snapshot-write child (list header) "not-json\n")
    (should-error (pilish-jsonl-read-subagent-snapshot target) :type 'user-error)
    (pilish-test--snapshot-write child (list header) "not-json")
    (should-error (pilish-jsonl-read-subagent-snapshot target) :type 'user-error)
    (pilish-test--snapshot-write child (list header) "{\"type\":")
    (should (equal (pilish-jsonl-snapshot-messages (pilish-jsonl-read-subagent-snapshot target)) []))
    (pilish-test--snapshot-write manifest (list start) "not-json\n")
    (should-error (pilish-jsonl-read-subagent-snapshot target) :type 'user-error)))

(ert-deftest pilish-test-snapshot-disk-duplicate-and-ancestry-errors ()
  (pilish-test--with-snapshot-files
    (let ((entry (pilish-test--snapshot-message "leaf" nil "Saved once")))
      (pilish-test--snapshot-write child (list header entry entry))
      (should (equal (pilish-jsonl-snapshot-messages (pilish-jsonl-read-subagent-snapshot target))
                     [(:role "user" :content "Saved once" :timestamp 0)]))
      (dolist (entries (list (list entry (pilish-test--snapshot-message "leaf" nil "Conflict"))
                            (list (pilish-test--snapshot-message "leaf" "missing" "Dangling"))
                            (list (pilish-test--snapshot-message "a" "b" "A")
                                  (pilish-test--snapshot-message "b" "a" "B"))
                            (list '(:type "unknown" :id "leaf" :parentId :null))
                            (list '(:type "message" :id "leaf" :message (:role "user" :content "Missing parent")))))
        (pilish-test--snapshot-write child (cons header entries))
        (should-error (pilish-jsonl-read-subagent-snapshot target) :type 'user-error)))))

(ert-deftest pilish-test-snapshot-disk-symlink-escape ()
  (pilish-test--with-snapshot-files
    (let ((outside (expand-file-name "outside.jsonl" directory)))
      (pilish-test--snapshot-write outside (list header))
      (make-symbolic-link outside child)
      (should-error (pilish-jsonl-read-subagent-snapshot target) :type 'user-error))))

(defun pilish-test--snapshot-check-file-alias (link-function)
  "Check conflicting and resume mappings with a real alias from LINK-FUNCTION."
  (pilish-test--with-snapshot-files
    (let ((alias (concat root "alias.jsonl")))
      (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "Correct child")))
      (condition-case err
          (funcall link-function child alias)
        (file-error (ert-skip (error-message-string err))))
      (should (equal (pilish-jsonl-snapshot-messages (pilish-jsonl-read-subagent-snapshot target))
                     [(:role "user" :content "Correct child" :timestamp 0)]))
      (dolist (mapping (list (list :type "started" :sessionId "other-child"
                                  :episodeId "other-episode" :sessionFile alias)
                            (list :type "resume_started" :sessionId "child-id"
                                  :episodeId "episode-2" :sessionFile alias)))
        (pilish-test--snapshot-write manifest (list start mapping))
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
                    (should (equal (cadr failure)
                                   (if (equal (plist-get mapping :type) "started")
                                       "Subagent session path is assigned to conflicting identities"
                                     "Contradictory subagent session paths for child-id"))))
                  (should (equal (buffer-list) buffers))
                  (should (equal (window-state-get nil t) windows)))
              (pilish-test--kill-live-buffers opened))))))))

(ert-deftest pilish-test-snapshot-open-rejects-symlink-file-double-identity ()
  (pilish-test--snapshot-check-file-alias #'make-symbolic-link))

(ert-deftest pilish-test-snapshot-open-rejects-hardlink-file-double-identity ()
  (pilish-test--snapshot-check-file-alias #'add-name-to-file))

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
                           (concat "Saved snapshot, not live.\n\nYou\n===\n\nSaved question\n"
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
                                 (concat "Saved snapshot, not live.\n\nYou\n===\n\nSaved question\n"
                                         "\nAssistant\n=========\n\nFirst answer\n\nSecond answer\n\n")))
                  (should (equal (pilish-jsonl-snapshot-messages (pilish-jsonl-read-subagent-snapshot target))
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
                    (should (equal (pilish-jsonl-snapshot-messages (pilish-jsonl-read-subagent-snapshot target))
                                   (vector system)))
                    (should (equal (buffer-substring-no-properties (point-min) (point-max)) "Saved snapshot, not live.\n"))
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
                                 (concat "Saved snapshot, not live.\n\nYou\n===\n\nSaved child question\n"
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

(ert-deftest pilish-test-snapshot-open-render-failure-is-not-published ()
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write child (list header))
    (let ((before (buffer-list)))
      (cl-letf (((symbol-function 'pilish--replay-history)
                 (lambda (&rest _) (error "Synthetic render failure"))))
        (should-error (pilish-open-subagent-snapshot target)))
      (should (equal (buffer-list) before)))))

(defun pilish-test--snapshot-run (id agent &optional children)
  (list :sessionId id :episodeId (concat "episode-" id) :agent agent
        :status "running" :turnCount 0 :activity "working" :activityLog "/tmp/subagents.md"
        :children (or children [])))

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

(ert-deftest pilish-test-snapshot-names-progress-hierarchy-duplicates-aliases ()
  (with-temp-buffer
    (pilish-chat-mode)
    (setq pilish--state '(:session-file "/saved/root.jsonl"))
    (let* ((run (pilish-test--snapshot-run
                 "root-id" "same"
                 (vector (pilish-test--snapshot-run "first-id" "same")
                         (pilish-test--snapshot-run "second-id" "same"))))
           (args '(:agent "alias" :task "same alias remain ordinary"))
           (block (pilish--display-tool-start "subagent" args "call"))
           (text (concat "Log: /tmp/subagents.md\n"
                         "- same (0 turns) -> same (0 turns): working\n"
                         "- same (0 turns) -> same (0 turns): working")))
      (pilish--display-tool-update (list :content (vector (list :type "text" :text text))
                                         :details (list :run run)) block)
      (should (equal (pilish-test--snapshot-name-rows)
                     '(("alias" "root-id" "/saved/root.jsonl")
                       ("same" "root-id" "/saved/root.jsonl")
                       ("same" "first-id" "/saved/root.jsonl")
                       ("same" "root-id" "/saved/root.jsonl")
                       ("same" "second-id" "/saved/root.jsonl"))))
      (should (string-match-p (regexp-quote text) (buffer-string)))
      (goto-char (point-min))
      (search-forward "same alias remain ordinary")
      (should-not (get-text-property (1- (point)) 'pilish-subagent-name))
      (goto-char (point-min))
      (pilish-next-subagent-name)
      (should (looking-at "alias"))
      (let ((first (point)))
        (pilish-next-subagent-name)
        (should (looking-at "same (0 turns) ->"))
        (pilish-previous-subagent-name)
        (should (= (point) first)))
      (should (eq (key-binding (kbd "TAB")) #'pilish-toggle-tool-section)))))

(ert-deftest pilish-test-snapshot-names-coalesced-metadata-only-rebind ()
  (with-temp-buffer
    (pilish-chat-mode)
    (setq pilish--state '(:session-file "/saved/root.jsonl"))
    (let* ((block (pilish--display-tool-start "subagent" '(:agent "same") "call"))
           (text "Log: /tmp/subagents.md\n- same (0 turns): working")
           (first (list :content (vector (list :type "text" :text text))
                        :details (list :run (pilish-test--snapshot-run "first" "same"))))
           (second (list :content (vector (list :type "text" :text text))
                         :details (list :run (pilish-test--snapshot-run "second" "same")))))
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
               :details (list :run (plist-put (pilish-test--snapshot-run "second" "same") :episodeId 42))) block)
        (should (equal (buffer-substring-no-properties (point-min) (point-max)) painted))
        (should-not (pilish-test--snapshot-name-rows))
        (goto-char (point-min))
        (search-forward "same")
        (should (equal (get-text-property (1- (point)) 'pilish-subagent-name)
                       "This name has an invalid child episode identity"))))))

(ert-deftest pilish-test-snapshot-names-final-details-fold-cold-refontified ()
  (with-temp-buffer
    (pilish-chat-mode)
    (setq pilish--state '(:session-file "/saved/root.jsonl"))
    (let* ((pilish-tool-preview-lines 3)
           (run '(:sessionId "child-id" :agent "same" :children
                            [(:sessionId "other-id" :agent "same" :children [])]))
           (details (list :run run :unrelated '(:agent "same")))
           (args '(:agent "alias" :task "same"))
           (content [(:type "text" :text "## Subagent same result\nSubagent session ID: child-id\n\nsame task word")])
           (block (pilish--display-tool-start "subagent" args "call"))
           (overlay (pilish--tool-block-overlay block)))
      (pilish--display-tool-end "subagent" args content details nil block)
      (should-not (pilish--tool-block-result block))
      (should-not (pilish--tool-block-args block))
      (should (equal (mapcar #'car (pilish-test--snapshot-name-rows)) '("alias" "same")))
      (goto-char (overlay-start overlay))
      (call-interactively (key-binding (kbd "TAB")))
      (should (equal (mapcar (lambda (row) (list (car row) (cadr row)))
                            (pilish-test--snapshot-name-rows))
                     '(("alias" "child-id") ("same" "child-id")
                       ("same" "child-id") ("same" "other-id"))))
      (should (string-match-p
               (regexp-quote (concat "**Details**\n{\n  \"run\": {\n    \"sessionId\": \"child-id\",\n"
                                    "    \"agent\": \"same\",\n    \"children\": [\n      {\n"
                                    "        \"sessionId\": \"other-id\",\n        \"agent\": \"same\",\n"
                                    "        \"children\": []\n      }\n    ]\n  },\n"
                                    "  \"unrelated\": {\n    \"agent\": \"same\"\n  }\n}"))
               (buffer-string)))
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
    (let* ((run (pilish-test--snapshot-run "child-id" "long-name"))
           (text (pilish--subagent-output
                  "Log: /tmp/subagents.md\n- long-name (0 turns): working" "subagent" (list :run run)))
           (slice (plist-get (pilish--truncate-to-visual-lines
                              (pilish--subagent-spans
                               "long-name (0 turns): working"
                               (list (list 0 9 (pilish--subagent-name-target run)))) 2 4) :content)))
      (should (pilish--snapshot-target-p (get-text-property (string-search "long-name" text) 'pilish-subagent-name text)))
      (should-not (text-property-not-all 0 (length slice) 'pilish-subagent-name nil slice))
      (dolist (tool '("subagent_list" "arbitrary"))
        (should (equal-including-properties
                 (pilish--subagent-output "## Subagent long-name result\nlong-name" tool (list :run run))
                 "## Subagent long-name result\nlong-name")))
      (let ((inhibit-read-only t))
        (insert (pilish--subagent-output "Ordinary long-name task/output and /profiles/long-name.md" "subagent" (list :run run))))
      (should (equal (buffer-string) "Ordinary long-name task/output and /profiles/long-name.md"))
      (should-not (pilish-test--snapshot-name-rows)))))

(ert-deftest pilish-test-snapshot-names-navigation-skips-hidden-and-unavailable ()
  (with-temp-buffer
    (pilish-snapshot-mode)
    (let ((inhibit-read-only t)
          (target (pilish--snapshot-target "/saved/root.jsonl" "child-id")))
      (insert (pilish--subagent-spans "first hidden unavailable last"
                                    (list (list 0 5 target) (list 6 12 target)
                                          (list 13 24 "No saved identity") (list 25 29 target))))
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
          (target (pilish--snapshot-target "/saved/root.jsonl" "child-id")))
      (insert (pilish--subagent-spans "\nfirst empty folded last"
                                    (list (list 1 6 target) (list 7 12 target)
                                          (list 13 19 target) (list 20 24 target))))
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

(ert-deftest pilish-test-snapshot-names-legacy-root-envelope-only ()
  (with-temp-buffer
    (pilish-chat-mode)
    (setq pilish--state '(:session-file "/saved/root.jsonl"))
    (let* ((capsule (concat "## Subagent same error\n\nFailure same\n\n"
                            "Subagent session ID: 01234567-0123-0123-0123-0123456789ab\n\n"
                            "This child session may be recoverable. If the same task should continue after a transient failure, call `subagent_resume` with this session ID and a message. Otherwise start a new `subagent`."))
           (text (pilish--subagent-output capsule "subagent" nil)))
      (let ((inhibit-read-only t)) (insert text))
      (should (equal (pilish-test--snapshot-name-rows)
                     '(("same" "01234567-0123-0123-0123-0123456789ab" "/saved/root.jsonl"))))
      (let ((inhibit-read-only t)) (erase-buffer)
        (insert (pilish--subagent-output
                 (concat capsule "\nSubagent session ID: 01234567-0123-0123-0123-0123456789ab") "subagent" nil)))
      (should-not (pilish-test--snapshot-name-rows))
      (goto-char (point-min))
      (search-forward "same")
      (should (stringp (get-text-property (1- (point)) 'pilish-subagent-name)))
      (should-error (call-interactively #'pilish-visit-file) :type 'user-error))))

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
                     (run '(:sessionId "child-id" :episodeId "episode-1" :agent "resolved" :children []))
                     (block (pilish--display-tool-start "subagent" args "call")))
                (pilish--display-tool-end "subagent" args
                                          [(:type "text" :text "## Subagent resolved result\nSaved")]
                                          (list :run run) nil block))
              (goto-char (point-min))
              (call-interactively (key-binding (kbd "C-c ]")))
              (should (looking-at "alias"))
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
     manifest (list start (list :type "resume_started" :sessionId "child-id"
                               :episodeId "episode-2" :sessionFile child)))
    (pilish-test--snapshot-write
     child (list header '(:type "message" :id "leaf" :parentId :null
                                :message (:role "user" :content "Saved child behind collapsed output"))))
    (dolist (case '(("subagent" (:task "Read the saved file")
                    "subagent { \"task\": \"Read the saved file\" }" "episode-1")
                   ("subagent_resume" (:sessionId "argument-child" :message "Continue")
                    "subagent_resume { \"sessionId\": \"argument-child\", \"message\": \"Continue\" }" "episode-2")))
      (pcase-let ((`(,tool ,args ,header-text ,episode) case))
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
                         (overlay (pilish--tool-block-overlay block))
                         (run (list :sessionId "child-id" :episodeId episode :agent "subagent" :children [])))
                    (pilish--display-tool-end
                     tool args [(:type "text" :text "## Subagent result\nSaved answer")]
                     (list :run run) nil block)
                    (should (equal (pilish-test--snapshot-name-rows) (list (list tool "child-id" anchor))))
                    (should (equal (buffer-substring-no-properties (overlay-start overlay) (overlay-end overlay))
                                   (concat header-text "\n```\n## Subagent result\n```\n... (11 more lines)\n")))
                    (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
                      (goto-char (point-min))
                      (execute-kbd-macro (kbd "C-c ]"))
                      (should (looking-at (regexp-quote header-text)))
                      (should (equal (pilish--snapshot-target-episode-id
                                      (get-text-property (point) 'pilish-subagent-name)) episode))
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
                        (should (equal (buffer-substring-no-properties (point-min) (point-max)) plain))
                        (should (equal (pilish-test--snapshot-name-rows) (list (list tool "child-id" anchor))))
                        (goto-char (point-min))
                        (execute-kbd-macro (kbd "C-c ]"))
                        (should (looking-at (regexp-quote header-text)))
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
                                         "Saved snapshot, not live.\n\nYou\n===\n\nSaved child behind collapsed output\n"))
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

(ert-deftest pilish-test-snapshot-default-headers-rebind-and-unavailable ()
  (dolist (tool '("subagent" "subagent_resume"))
    (with-temp-buffer
      (pilish-chat-mode)
      (setq pilish--state '(:session-file "/saved/root.jsonl"))
      (let* ((block (pilish--display-tool-start tool '(:sessionId "argument-child" :task "subagent") "call"))
             (run '(:sessionId "observed-child" :episodeId "observed-episode" :agent "subagent"))
             (result (list :content [(:type "text" :text "Working")] :details (list :run run))))
        (pilish--display-tool-update result block)
        (should (equal (pilish-test--snapshot-name-rows) (list (list tool "observed-child" "/saved/root.jsonl"))))
        (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
          (setq run (plist-put (copy-sequence run) :sessionId "replacement-child"))
          (pilish--display-tool-update (plist-put (copy-sequence result) :details (list :run run)) block)
          (should (equal (pilish-test--snapshot-name-rows) (list (list tool "replacement-child" "/saved/root.jsonl"))))
          (dolist (case (list (list nil "/saved/root.jsonl" "This saved name has no child session identity")
                             (list (plist-put (copy-sequence run) :episodeId 42) "/saved/root.jsonl"
                                   "This name has an invalid child episode identity")
                             (list run nil "No saved parent session anchor is known")))
            (pcase-let ((`(,observed-run ,anchor ,reason) case))
              (setq pilish--state (list :session-file anchor))
              (pilish--display-tool-update
               (plist-put (copy-sequence result) :details (list :run observed-run)) block)
              (should (equal (buffer-substring-no-properties (point-min) (point-max)) plain))
              (should-not (pilish-test--snapshot-name-rows))
              (goto-char (point-min))
              (should (equal (get-text-property (point) 'pilish-subagent-name) reason))
              (should-not (button-at (point)))
              (should-error (call-interactively (key-binding (kbd "C-c ]"))) :type 'user-error)
              (let ((failure (should-error (call-interactively #'pilish-visit-file) :type 'user-error)))
                (should (equal (error-message-string failure) (concat "Saved snapshot unavailable: " reason))))))))))
  (dolist (tool '("subagent_list" "arbitrary"))
    (with-temp-buffer
      (pilish-chat-mode)
      (setq pilish--state '(:session-file "/saved/root.jsonl"))
      (let ((block (pilish--display-tool-start tool '(:sessionId "argument-child") "call")))
        (pilish--display-tool-update
         '(:content [(:type "text" :text "Working")] :details (:run (:sessionId "observed-child" :agent "subagent"))) block)
        (goto-char (point-min))
        (should (looking-at (regexp-quote tool)))
        (should-not (get-text-property (point) 'pilish-subagent-name))
        (should-not (button-at (point)))
        (should-error (call-interactively #'pilish-visit-file) :type 'user-error)))))

(ert-deftest pilish-test-snapshot-default-headers-strict-recovery-only ()
  (dolist (tool '("subagent" "subagent_resume"))
    (dolist (suffix '("" "\nSubagent session ID: 01234567-0123-0123-0123-0123456789ab"))
      (with-temp-buffer
        (pilish-chat-mode)
        (setq pilish--state '(:session-file "/saved/root.jsonl"))
        (let* ((pilish-tool-preview-lines 1)
               (args '(:sessionId "argument-child" :task "Read the saved file"))
               (block (pilish--display-tool-start tool args "call")))
          (pilish--display-tool-end
           tool args (vector (list :type "text" :text
                                   (concat "## Subagent result\nSubagent session ID: 01234567-0123-0123-0123-0123456789ab\n\nSaved answer" suffix)))
           nil nil block)
          (goto-char (point-min))
          (if (string-empty-p suffix)
              (progn
                (should (equal (pilish-test--snapshot-name-rows)
                               (list (list tool "01234567-0123-0123-0123-0123456789ab" "/saved/root.jsonl"))))
                (should-not (pilish--snapshot-target-episode-id (get-text-property (point) 'pilish-subagent-name)))
                (should (button-at (point))))
            (should-not (pilish-test--snapshot-name-rows))
            (should (equal (get-text-property (point) 'pilish-subagent-name)
                           "This saved name has no child session identity"))
            (should-not (button-at (point)))))))))

(ert-deftest pilish-test-snapshot-history-nested-origin-survives-parent-death ()
  (pilish-test--with-snapshot-files
    (let* ((grandchild (concat root "manager-grandchild.jsonl"))
           (nested-run '(:sessionId "grandchild-id" :episodeId "grandchild-episode"
                                     :agent "same" :children []))
           parent snapshot nested)
      (pilish-test--snapshot-write
       manifest (list start (list :type "started" :sessionId "grandchild-id"
                                  :episodeId "grandchild-episode" :sessionFile grandchild)))
      (pilish-test--snapshot-write
       child (list header
                   '(:type "message" :id "assistant" :parentId :null
                           :message (:role "assistant" :content
                                           [(:type "toolCall" :id "nested" :name "subagent"
                                                   :arguments (:agent "alias" :task "same plain task"))]))
                   (list :type "message" :id "result" :parentId "assistant"
                         :message (list :role "toolResult" :toolCallId "nested"
                                        :content [(:type "text" :text "## Subagent same result\nSaved descendant")]
                                        :details (list :run nested-run)))))
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
                           '(("alias" "grandchild-id") ("same" "grandchild-id") ("same" "grandchild-id"))))
            (should (equal (cl-remove-duplicates (mapcar #'caddr (pilish-test--snapshot-name-rows)) :test #'equal)
                           (list child)))
            (with-current-buffer parent (setq pilish--state '(:session-file "/different/root.jsonl")))
            (kill-buffer parent)
            (goto-char (point-min))
            (call-interactively (key-binding (kbd "C-c ]")))
            (should (looking-at "alias"))
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

(defun pilish-test--snapshot-check-native-summary-opener (tool arguments episode)
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write
     manifest (list start (list :type "resume_started" :sessionId "child-id"
                               :episodeId "episode-2" :sessionFile child)))
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
                                   :details (list :run (list :sessionId "child-id" :episodeId episode
                                                             :agent "subagent" :children [])))))
              (pilish--handle-display-event
               '(:type "tool_execution_end" :toolCallId "compound-owner"
                       :toolName "codemode" :isError nil :result (:content [])))
              (goto-char (point-min))
              (execute-kbd-macro (kbd "C-c ]"))
              (should (looking-at (regexp-quote tool)))
              (execute-kbd-macro (kbd "RET"))
              (setq snapshot (current-buffer))
              (should (derived-mode-p 'pilish-snapshot-mode))
              (should (equal (buffer-substring-no-properties (point-min) (point-max))
                             "Saved snapshot, not live.\n\nYou\n===\n\nSaved native nested child\n"))
              (should (equal pilish--snapshot-source-file child)))
          (pilish-test--kill-live-buffers snapshot parent))))))

(ert-deftest pilish-test-snapshot-native-default-summary-keyboard-open ()
  (pilish-test--snapshot-check-native-summary-opener
   "subagent" '(:task "Read saved file") "episode-1"))

(ert-deftest pilish-test-snapshot-native-resume-summary-keyboard-open ()
  (pilish-test--snapshot-check-native-summary-opener
   "subagent_resume" '(:sessionId "argument-child" :message "Continue") "episode-2"))

(ert-deftest pilish-test-snapshot-native-default-summary-no-arguments-keyboard-open ()
  (pilish-test--snapshot-check-native-summary-opener "subagent" nil "episode-1"))

(ert-deftest pilish-test-snapshot-native-resume-summary-no-arguments-keyboard-open ()
  (pilish-test--snapshot-check-native-summary-opener "subagent_resume" nil "episode-2"))

(ert-deftest pilish-test-snapshot-native-summary-exact-result-not-call-id ()
  (with-temp-buffer
    (pilish-chat-mode)
    (setq pilish--state '(:session-file "/saved/root.jsonl"))
    (let* ((call (pilish--make-nested-call
                  :id "native-tool-call-not-a-session" :name "subagent" :status 'ok
                  :arguments '(:agent "alias" :task "alias ordinary task")
                  :result '(:details (:run (:sessionId "real-child" :agent "resolved")))))
           (inhibit-read-only t))
      (insert (pilish--nested-call-summary call nil))
      (should (equal (pilish-test--snapshot-name-rows) '(("alias" "real-child" "/saved/root.jsonl"))))
      (should (equal (buffer-substring-no-properties (point-min) (point-max))
                     "  ✓ subagent {\"agent\":\"alias\",\"task\":\"alias ordinary task\"}"))
      (erase-buffer)
      (setf (pilish--nested-call-result call) nil)
      (insert (pilish--nested-call-summary call t))
      (should-not (pilish-test--snapshot-name-rows))
      (goto-char (point-min))
      (search-forward "alias")
      (should (equal (get-text-property (1- (point)) 'pilish-subagent-name)
                     "This saved name has no child session identity")))))

(ert-deftest pilish-test-snapshot-native-summary-fallback-keeps-unavailable-identities-inert ()
  (dolist (tool '("subagent" "subagent_resume"))
    (with-temp-buffer
      (pilish-chat-mode)
      (setq pilish--state '(:session-file "/saved/root.jsonl"))
      (let* ((call (pilish--make-nested-call
                    :id "native-tool-call-not-a-session" :name tool :status 'ok
                    :arguments '(:sessionId "argument-child")
                    :result '(:details (:run (:sessionId "observed-child" :episodeId "observed-episode")))))
             (inhibit-read-only t))
        (insert (pilish--nested-call-summary call nil))
        (should (equal (buffer-substring-no-properties (point-min) (point-max))
                       (concat "  ✓ " tool " {\"sessionId\":\"argument-child\"}")))
        (goto-char (point-min))
        (call-interactively (key-binding (kbd "C-c ]")))
        (should (looking-at (regexp-quote tool)))
        (should (equal (pilish-test--snapshot-name-rows)
                       (list (list tool "observed-child" "/saved/root.jsonl"))))
        (dolist (case '((nil "This saved name has no child session identity")
                        ((:sessionId "observed-child" :episodeId 42)
                         "This name has an invalid child episode identity")))
          (pcase-let ((`(,run ,reason) case))
            (erase-buffer)
            (setf (pilish--nested-call-result call) (list :details (list :run run)))
            (insert (pilish--nested-call-summary call nil))
            (should (equal (buffer-substring-no-properties (point-min) (point-max))
                           (concat "  ✓ " tool " {\"sessionId\":\"argument-child\"}")))
            (goto-char (point-min))
            (search-forward tool)
            (backward-char (length tool))
            (should (equal (get-text-property (point) 'pilish-subagent-name) reason))
            (should-not (button-at (point)))
            (let ((failure (should-error (call-interactively #'pilish-visit-file) :type 'user-error)))
              (should (equal (error-message-string failure) (concat "Saved snapshot unavailable: " reason))))
            (goto-char (point-min))
            (let ((failure (should-error (call-interactively (key-binding (kbd "C-c ]"))) :type 'user-error)))
              (should (equal (error-message-string failure) "No next visible subagent name")))))))))

(ert-deftest pilish-test-snapshot-json-escaped-agent-and-unrelated-fields ()
  (with-temp-buffer
    (pilish-chat-mode)
    (setq pilish--state '(:session-file "/saved/root.jsonl"))
    (let* ((agent "quote\" λ")
           (details (list :run (list :sessionId "child" :agent agent :children [])
                          :other (list :agent agent)))
           (presentation (pilish--tool-result-presentation "subagent" nil [] details nil))
           (inhibit-read-only t))
      (insert (plist-get presentation :text))
      (should (equal (pilish-test--snapshot-name-rows)
                     '(("quote\\\" λ" "child" "/saved/root.jsonl"))))
      (should (string-match-p "\"other\"" (buffer-string)))
      (goto-char (point-max))
      (search-backward "quote")
      (should-not (get-text-property (point) 'pilish-subagent-name)))))

(ert-deftest pilish-test-snapshot-disk-absolute-compatible-paths-and-headers ()
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "Saved")))
    (dolist (raw '("relative.jsonl" "/ssh:other:/child.jsonl"))
      (pilish-test--snapshot-write manifest (list (plist-put (copy-sequence start) :sessionFile raw)))
      (should-error (pilish-jsonl-read-subagent-snapshot target) :type 'user-error))
    (pilish-test--snapshot-write manifest (list start))
    (pilish-test--snapshot-write child (list header (plist-put (copy-sequence header) :id "conflict")))
    (should-error (pilish-jsonl-read-subagent-snapshot target) :type 'user-error)
    (pilish-test--snapshot-write child (list header header (pilish-test--snapshot-message "leaf" nil "Saved")))
    (should (equal (pilish-jsonl-snapshot-messages (pilish-jsonl-read-subagent-snapshot target))
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
                   '(:run (:sessionId "child-id" :episodeId "episode-1" :agent "resolved" :children []))
                   nil block))
                (goto-char (point-min))
                (execute-kbd-macro (kbd "C-c ]"))
                (should (looking-at "alias"))
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
                       (key-binding (kbd \"q\"))))))")
    '(pilish-snapshot-mode nil pilish-snapshot-quit))))

(ert-deftest pilish-test-snapshot-disk-captured-multihop-route ()
  (let* ((origin "/ssh:bastion|sudo:host:/saved/root.jsonl")
         (target (pilish--snapshot-target origin "child-id" "episode-1"))
         (manifest [(:type "started" :sessionId "child-id" :episodeId "episode-1"
                           :sessionFile "/saved/root.jsonl.subagents/managed.jsonl")])
         (session [(:type "session" :version 3 :id "child-id" :cwd "/work/project")
                  (:type "message" :id "leaf" :parentId :null
                         :message (:role "user" :content "Remote saved text"))])
         (default-directory "/tmp/"))
    (cl-letf (((symbol-function 'pilish--jsonl-snapshot-records)
               (lambda (path)
                 (cond
                  ((equal path "/ssh:bastion|sudo:host:/saved/root.jsonl.subagents/manifest.jsonl") manifest)
                  ((equal path "/ssh:bastion|sudo:host:/saved/root.jsonl.subagents/managed.jsonl") session)
                  (t (ert-fail (format "Unexpected captured route read %s" path))))))
              ((symbol-function 'file-in-directory-p)
               (lambda (path root)
                 (and (equal root "/ssh:bastion|sudo:host:/saved/root.jsonl.subagents/")
                      (equal path "/ssh:bastion|sudo:host:/saved/root.jsonl.subagents/managed.jsonl")))))
      (let ((saved (pilish-jsonl-read-subagent-snapshot target)))
        (should (equal (pilish-jsonl-snapshot-file saved)
                       "/ssh:bastion|sudo:host:/saved/root.jsonl.subagents/managed.jsonl"))
        (should (equal (pilish-jsonl-snapshot-cwd saved) "/ssh:bastion|sudo:host:/work/project/"))
        (should (equal (pilish-jsonl-snapshot-messages saved) [(:role "user" :content "Remote saved text")])))
      (setq manifest (vconcat manifest [(:type "started" :sessionId "other-child" :episodeId "other-episode"
                                               :sessionFile "/saved/root.jsonl.subagents/alias.jsonl")]))
      (cl-letf (((symbol-function 'file-exists-p)
                 (lambda (path)
                   (should (member path '("/ssh:bastion|sudo:host:/saved/root.jsonl.subagents/managed.jsonl"
                                          "/ssh:bastion|sudo:host:/saved/root.jsonl.subagents/alias.jsonl")))
                   t))
                ((symbol-function 'file-equal-p)
                 (lambda (first second)
                   (should (equal (list first second)
                                  '("/ssh:bastion|sudo:host:/saved/root.jsonl.subagents/managed.jsonl"
                                    "/ssh:bastion|sudo:host:/saved/root.jsonl.subagents/alias.jsonl")))
                   t)))
        (let ((failure (should-error (pilish-jsonl-read-subagent-snapshot target) :type 'user-error)))
          (should (equal (cadr failure) "Subagent session path is assigned to conflicting identities")))))))

(ert-deftest pilish-test-snapshot-disk-rejects-complete-empty-object-tail ()
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "Saved")))
    (should (equal (pilish-jsonl-snapshot-messages (pilish-jsonl-read-subagent-snapshot target))
                   [(:role "user" :content "Saved" :timestamp 0)]))
    (pilish-test--snapshot-write child (list header (pilish-test--snapshot-message "leaf" nil "Saved")) "{}")
    (should-error (pilish-jsonl-read-subagent-snapshot target) :type 'user-error)))

(ert-deftest pilish-test-snapshot-annotation-does-not-mutate-wire-text ()
  (with-temp-buffer
    (pilish-chat-mode)
    (setq pilish--state '(:session-file "/saved/root.jsonl"))
    (let* ((wire "Log: /tmp/subagents.md\n- same (0 turns): working")
           (painted (pilish--subagent-output wire "subagent"
                                            (list :run (pilish-test--snapshot-run "child-id" "same"))))
           (inhibit-read-only t))
      (should (equal-including-properties wire "Log: /tmp/subagents.md\n- same (0 turns): working"))
      (insert painted)
      (should (equal (pilish-test--snapshot-name-rows) '(("same" "child-id" "/saved/root.jsonl"))))
      (erase-buffer)
      (insert (pilish--subagent-output wire "subagent" nil))
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
                  :result '(:content [(:type "text" :text "## Subagent resolved result\nSaved")]
                                     :details (:run (:sessionId "child-id" :agent "resolved" :children [])))))
           (overlay (pilish--tool-block-overlay block)))
      (pilish--enable-compound-tool block args)
      (setf (pilish--tool-block-nested-calls block) (list call))
      (pilish--redraw-compound-tool block)
      (pilish--tool-overlay-finalize 'pilish-tool-block block)
      (should (equal (pilish-test--snapshot-name-rows) '(("alias" "child-id" "/saved/root.jsonl"))))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (pilish--cool-tool-overlay overlay)
        (should-not (overlay-buffer overlay))
        (should-not (pilish--nested-call-result call))
        (should-not (pilish--tool-block-result block))
        (should-not (pilish--tool-block-nested-calls block))
        (should (equal (pilish-test--snapshot-name-rows) '(("alias" "child-id" "/saved/root.jsonl"))))
        (should (string-match-p "same task" (buffer-string)))
        (should (string-match-p "alias" text))
        (font-lock-ensure)
        (pilish--restore-tool-properties (point-min) (point-max))
        (goto-char (point-min))
        (pilish-next-subagent-name)
        (should (looking-at "alias"))
        (should (eq (button-get (button-at (point)) 'action) #'pilish--subagent-button-action))
        (should-not (text-property-not-all (point-min) (point-max) 'pilish-tool-toggle nil))))))

(ert-deftest pilish-test-snapshot-root-result-and-interrupted-recovery ()
  (with-temp-buffer
    (pilish-chat-mode)
    (setq pilish--state '(:session-file "/saved/root.jsonl"))
    (dolist (text (list
                   "## Subagent same result\nSubagent session ID: 01234567-0123-0123-0123-0123456789ab\n\nAnswer"
                   (concat "## Subagent same interrupted\n\nNo final answer was produced.\n\n"
                           "Subagent session ID: 01234567-0123-0123-0123-0123456789ab\n\n"
                           "If the interrupted task should continue, call `subagent_resume` with this session ID and a message. Otherwise start a new `subagent`.\n\n"
                           "Example for `message`:\n- You were interrupted. Continue the original task from where you left off.")))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (pilish--subagent-output text "subagent_resume" nil)))
      (should (equal (pilish-test--snapshot-name-rows)
                     '(("same" "01234567-0123-0123-0123-0123456789ab" "/saved/root.jsonl")))))))

(provide 'pilish-snapshot-test)
