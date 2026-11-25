;;; pilish-test.el --- Tests for Pilish -*- lexical-binding: t; -*-

;;; Commentary:

;; Entry-point and cross-module integration tests for Pilish.

;;; Code:

(require 'dired)
(require 'ert)
(require 'pilish)
(require 'pilish-test-common)

;;; Shared Test Helpers

(defun pilish-test--make-open-session-command-buffers (&optional process)
  "Return linked chat/input/process fixtures for open-session-file tests.
PROCESS defaults to a harmless pipe process because pi buffer cleanup expects
`pilish--process' to be either nil or a process object.  These tests
still mock the RPC boundary, so the process is never used for I/O."
  (let ((chat-buf (generate-new-buffer " *pilish-open-session-chat*"))
        (input-buf (generate-new-buffer " *pilish-open-session-input*"))
        (proc (or process
                  (make-pipe-process :name "pilish-open-session-test"
                                     :buffer nil
                                     :noquery t))))
    (with-current-buffer chat-buf
      (pilish-chat-mode)
      (pilish--set-input-buffer input-buf)
      (pilish--set-process proc))
    (with-current-buffer input-buf
      (pilish-input-mode)
      (pilish--set-chat-buffer chat-buf))
    (list chat-buf input-buf proc)))

(ert-deftest pilish-test-backend-spec-builds-fake-launch-config ()
  "Shared test helper builds fake backend launch data from a scenario name."
  (let* ((spec (pilish-test-backend-spec 'fake "prompt-lifecycle"
                                                  "tool-read"
                                                  '("--log-file" "/tmp/fake-pi.log")))
         (executable (plist-get spec :executable)))
    (should (eq (plist-get spec :name) 'fake))
    (should (equal (plist-get spec :label) "fake:tool-read"))
    (should (equal (plist-get spec :scenario) "tool-read"))
    (should (equal (plist-get spec :extra-args)
                   '("--scenario" "tool-read"
                     "--log-file" "/tmp/fake-pi.log")))
    (should (equal (car executable)
                   (pilish-test-python-executable)))
    (should (equal (cadr executable)
                   pilish-test-fake-pi-script))))

(ert-deftest pilish-test-backend-spec-builds-real-launch-config ()
  "Shared test helper preserves the configured real backend launch command."
  (let ((pilish-executable '("pi" "rpc"))
        (pilish-extra-args '("--model" "fake")))
    (let ((spec (pilish-test-backend-spec 'real "prompt-lifecycle")))
      (should (eq (plist-get spec :name) 'real))
      (should (equal (plist-get spec :label) "real"))
      (should (equal (plist-get spec :executable) '("pi" "rpc")))
      (should (equal (plist-get spec :extra-args) '("--model" "fake")))
      (should-not (plist-member spec :scenario)))))

(ert-deftest pilish-test-backend-spec-rejects-unknown-backend ()
  "Shared backend helper should fail loudly for unsupported backends."
  (should-error
   (pilish-test-backend-spec 'bogus "prompt-lifecycle")))


(ert-deftest pilish-test-view-session-file-creates-independent-observers ()
  "Public file viewing is read-only, process-free and refreshes captured identity."
  (let* ((directory (pilish-test--make-temp-directory "pilish-view-file-"))
         (file (expand-file-name "saved.jsonl" directory))
         (write-save
          (lambda (text)
            (with-temp-file file
              (insert (json-serialize `(:type "session" :version 3 :id "saved"
                                        :cwd ,directory)) "\n"
                      (json-serialize `(:type "message" :id "answer" :parentId :null
                                     :message (:role "assistant" :content ,text))) "\n"))))
         first second)
    (unwind-protect
        (save-window-excursion
          (funcall write-save "Saved answer")
          (cl-letf (((symbol-function 'pilish--start-process)
                     (lambda (&rest _) (ert-fail "Read-only viewing started Pi"))))
            (setq first (pilish-view-session-file file)
                  second (pilish-view-session-file file))
            (should-not (eq first second))
            (should (eq (window-buffer (selected-window)) second))
            (with-current-buffer first
              (should (derived-mode-p 'pilish-snapshot-mode))
              (should buffer-read-only)
              (should-not buffer-file-name)
              (should-not (derived-mode-p 'pilish-chat-mode))
              (should-not pilish--process)
              (should (string-match-p "Saved answer" (buffer-string))))
            (funcall write-save "Changed answer")
            (with-current-buffer second
              (setq second (pilish-snapshot-refresh)))
            (with-current-buffer second
              (should (string-match-p "Changed answer" (buffer-string))))
            (with-current-buffer first
              (should (string-match-p "Saved answer" (buffer-string))))))
      (pilish-test--kill-live-buffers first second)
      (delete-directory directory t))))

(ert-deftest pilish-test-view-session-file-rejects-invalid-before-display ()
  "Invalid saves fail before creating an observer or selecting a window."
  (let* ((directory (pilish-test--make-temp-directory "pilish-view-invalid-"))
         (file (expand-file-name "saved.jsonl" directory)))
    (unwind-protect
        (dolist (text '("not json\n" "{\"type\":\"session\"}\n"
                        "{\"type\":\"session\",\"version\":2,\"id\":\"saved\"}\n"))
          (with-temp-file file (insert text))
          (let ((buffers (buffer-list)) (window (selected-window)))
            (should-error (pilish-view-session-file file) :type 'user-error)
            (should (equal (buffer-list) buffers))
            (should (eq (selected-window) window))))
      (delete-directory directory t))))

(ert-deftest pilish-test-view-session-file-preserves-multihop-route ()
  "The public command keeps a selected multi-hop TRAMP route in its target."
  (let* ((route "/ssh:bastion|sudo:host:")
         (file (concat route "/sessions/saved.jsonl"))
         (default-directory "/tmp/")
         captured)
    (cl-letf (((symbol-function 'pilish-jsonl-read-session-header)
               (lambda (path)
                 (should (equal path file))
                 (list :type "session" :version 3 :id "worker" :cwd "/work")))
              ((symbol-function 'pilish-open-subagent-snapshot)
               (lambda (target) (setq captured target) 'observer)))
      (should (eq (pilish-view-session-file file) 'observer))
      (should (equal (pilish--snapshot-target-anchor-file captured) file))
      (should (equal (pilish--snapshot-target-root captured)
                     (concat route "/sessions/")))
      (should (equal (pilish--snapshot-target-file captured) "saved.jsonl")))))

(ert-deftest pilish-test-view-session-file-refuses-explicit-symlink-outside ()
  "An explicitly selected symlink that resolves outside its root is refused."
  (pilish-test--with-snapshot-files
    (let ((outside (expand-file-name "outside.jsonl" directory))
          (link (expand-file-name "selected.jsonl" root)))
      (pilish-test--snapshot-write outside (list header))
      (make-symbolic-link outside link)
      (save-window-excursion
        (let ((buffers (buffer-list))
              (window (selected-window))
              (windows (window-state-get nil t))
              failure)
          (setq failure (should-error (pilish-view-session-file link)
                                      :type 'user-error))
          (should (string-match-p "escapes its storage root"
                                  (error-message-string failure)))
          (should (equal (buffer-list) buffers))
          (should (eq (selected-window) window))
          (should (equal (window-state-get nil t) windows)))))))

(ert-deftest pilish-test-view-session-file-follows-symlink-inside-root ()
  "A symlink whose target stays inside the selected directory is followed."
  (pilish-test--with-snapshot-files
    (pilish-test--snapshot-write
     child (list header (pilish-test--snapshot-message "leaf" nil "Linked answer")))
    (let ((link (expand-file-name "alias.jsonl" root))
          observer)
      (make-symbolic-link child link)
      (unwind-protect
          (save-window-excursion
            (setq observer (pilish-view-session-file link))
            (with-current-buffer observer
              (should (string-match-p "Linked answer" (buffer-string)))))
        (when (buffer-live-p observer) (kill-buffer observer))))))

;;; Public Session Inspection

(ert-deftest pilish-test-session-accessors-resolve-chat-and-input-without-display ()
  "Both buffer types expose the same copied data without selecting a window."
  (let* ((buffers (pilish-test--make-open-session-command-buffers))
         (chat (car buffers)) (input (cadr buffers)) (proc (caddr buffers))
         (window (selected-window))
         (current (current-buffer)))
    (unwind-protect
        (progn
          (with-current-buffer chat
            (pilish--set-chat-session-identity "/tmp/project/" "feature")
            (setq pilish--session-name "Conversation"
                  pilish--state '(:session-file "/tmp/session.jsonl"
                                  :model (:id "model" :provider "provider"))
                  pilish--cached-stats '(:contextUsage (:percent 12 :tokens 42))
                  pilish--status 'idle))
          (dolist (buffer (list chat input (buffer-name chat) (buffer-name input)))
            (should (eq (pilish-session-chat-buffer buffer) chat))
            (should (eq (pilish-session-input-buffer buffer) input))
            (should (eq (pilish-session-process buffer) proc))
            (should (equal (pilish-session-directory buffer) "/tmp/project/"))
            (should (equal (pilish-session-name buffer) "feature"))
            (should (equal (pilish-session-title buffer) "Conversation"))
            (should (equal (pilish-session-file buffer) "/tmp/session.jsonl"))
            (should (equal (pilish-session-model buffer)
                           '(:id "model" :provider "provider")))
            (should (equal (pilish-session-context-usage buffer)
                           '(:percent 12 :tokens 42)))
            (should-not (pilish-session-queued-prompts buffer))
            (should-not (pilish-session-busy-p buffer)))
          (with-current-buffer input
            (should (eq (pilish-session-chat-buffer) chat))
            (should (eq (pilish-session-input-buffer) input))
            (should (equal (pilish-session-title) "Conversation")))
          (should (eq (selected-window) window))
          (should (eq (current-buffer) current)))
      (pilish-test--kill-live-buffers input chat))))

(ert-deftest pilish-test-session-accessors-copy-nested-data-and-queue-text ()
  "Changing returned containers or strings cannot change session state."
  (let* ((buffers (pilish-test--make-open-session-command-buffers))
         (chat (car buffers)) (input (cadr buffers)) (proc (caddr buffers)))
    (unwind-protect
        (progn
          (with-current-buffer chat
            (pilish--set-chat-session-identity
             (copy-sequence "/tmp/project/") (copy-sequence "feature"))
            (setq pilish--session-name (copy-sequence "Title")
                  pilish--state
                  (list :session-file (copy-sequence "/tmp/session.jsonl")
                        :model (list :id (copy-sequence "model")
                                     :input (vector (copy-sequence "text"))
                                     :cost (list :input 1)))
                  pilish--cached-stats
                  (list :contextUsage (list :percent 12 :tokens 42))
                  pilish--followup-queue (list (copy-sequence "new local")
                                              (copy-sequence "old local"))))
          (process-put proc 'pilish-queue-snapshot
                       (list :followUp (vector (copy-sequence "backend"))
                             :steering (vector (copy-sequence "steer"))))
          (let ((model (pilish-session-model chat))
                (usage (pilish-session-context-usage chat))
                (queue (pilish-session-queued-prompts chat)))
            (should (equal queue '("backend" "old local" "new local" "steer")))
            (aset (plist-get model :id) 0 ?X)
            (aset (aref (plist-get model :input) 0) 0 ?X)
            (aset (plist-get model :input) 0 "other")
            (setf (plist-get (plist-get model :cost) :input) 999
                  (plist-get usage :percent) 99)
            (dolist (text queue) (aset text 0 ?X))
            (setcar queue "replaced")
            (should (equal (pilish-session-model chat)
                           '(:id "model" :input ["text"] :cost (:input 1))))
            (should (= (plist-get (pilish-session-context-usage chat) :percent) 12))
            (should (equal (pilish-session-queued-prompts chat)
                           '("backend" "old local" "new local" "steer"))))
          (dolist (accessor '(pilish-session-directory pilish-session-name
                              pilish-session-title pilish-session-file))
            (let ((before (funcall accessor chat)))
              (aset (funcall accessor chat) 0 ?X)
              (should (equal before (funcall accessor chat))))))
      (pilish-test--kill-live-buffers input chat))))

(ert-deftest pilish-test-session-accessors-return-nil-for-non-session-buffers ()
  "Missing, dead, unrelated and snapshot buffers never resolve as live chats."
  (let ((dead (generate-new-buffer " *pilish-accessor-dead*"))
        (snapshot (generate-new-buffer " *pilish-accessor-snapshot*")))
    (kill-buffer dead)
    (unwind-protect
        (progn
          (with-current-buffer snapshot (pilish-snapshot-mode))
          (with-temp-buffer
            ;; A stale link in a non-session buffer must not be trusted.
            (setq-local pilish--chat-buffer snapshot)
            (dolist (buffer (list dead " *pilish-no-such-buffer*" snapshot
                                  (current-buffer) nil))
              (dolist (accessor '(pilish-session-chat-buffer
                                  pilish-session-input-buffer pilish-session-process
                                  pilish-session-directory pilish-session-name
                                  pilish-session-title pilish-session-file
                                  pilish-session-model pilish-session-context-usage
                                  pilish-session-queued-prompts pilish-session-busy-p
                                  pilish-session-running-tools
                                  pilish-session-extension-status))
                (should-not (funcall accessor buffer))))))
      (kill-buffer snapshot))))

(ert-deftest pilish-test-session-accessors-distinguish-stopped-and-missing-session ()
  "Stopped chats remain inspectable; deleted input/chat links return nil."
  (let* ((buffers (pilish-test--make-open-session-command-buffers))
         (chat (car buffers)) (input (cadr buffers)) (proc (caddr buffers)))
    (unwind-protect
        (progn
          (with-current-buffer chat
            (pilish--set-chat-session-identity "/tmp/project/")
            (setq pilish--status 'idle pilish--state nil))
          (delete-process proc)
          (should (eq (pilish-session-chat-buffer input) chat))
          (should (eq (pilish-session-process input) proc))
          (should-not (process-live-p (pilish-session-process input)))
          (should-not (pilish-session-name chat))
          (should-not (pilish-session-title chat))
          (should-not (pilish-session-model chat))
          (should-not (pilish-session-context-usage chat))
          (should-not (pilish-session-busy-p chat))
          (with-current-buffer input (setq pilish--chat-buffer nil))
          (should-not (pilish-session-input-buffer chat))
          (should-not (pilish-session-chat-buffer input))
          (with-current-buffer input (setq pilish--chat-buffer chat))
          (kill-buffer input)
          (should-not (pilish-session-input-buffer chat))
          (kill-buffer chat)
          (should-not (pilish-session-chat-buffer chat)))
      (pilish-test--kill-live-buffers input chat))))

(ert-deftest pilish-test-session-accessors-busy-includes-pending-and-queued-work ()
  "The public busy predicate includes non-streaming work and known queues."
  (let* ((buffers (pilish-test--make-open-session-command-buffers))
         (chat (car buffers)) (input (cadr buffers)) (proc (caddr buffers)))
    (unwind-protect
        (with-current-buffer chat
          (setq pilish--status 'idle)
          (should-not (pilish-session-busy-p input))
          (dolist (status '(sending streaming compacting))
            (setq pilish--status status)
            (should (eq (pilish-session-busy-p input) t)))
          (setq pilish--status 'idle)
          (pilish--begin-prompt-start-wait)
          (should (pilish-session-busy-p input))
          (setq pilish--prompt-wait nil pilish--prompt-waits nil
                pilish--activity-phase "running")
          (should (pilish-session-busy-p input))
          (setq pilish--activity-phase "idle" pilish--followup-queue '("waiting"))
          (should (pilish-session-busy-p input))
          (setq pilish--followup-queue nil)
          ;; An observed empty backend queue is idle, not queued work.
          (process-put proc 'pilish-queue-snapshot '(:followUp [] :steering []))
          (should-not (pilish-session-busy-p input))
          (process-put proc 'pilish-queue-snapshot '(:followUp [] :steering ["steer"]))
          (should (pilish-session-busy-p input))
          (process-put proc 'pilish-queue-snapshot '(:followUp ["backend"] :steering []))
          (should (pilish-session-busy-p input))
          (delete-process proc)
          (should-not (pilish-session-queued-prompts input))
          (should-not (pilish-session-busy-p input)))
      (pilish-test--kill-live-buffers input chat))))

(ert-deftest pilish-test-session-accessors-exists-uses-canonical-directory-and-name ()
  "Existence includes stopped and renamed chats but not other sessions."
  (let ((root (pilish-test--make-temp-directory "pilish-accessor-exists-"))
        chat input)
    (unwind-protect
        (cl-letf (((symbol-function 'pilish--start-process) (lambda (&rest _) nil))
                  ((symbol-function 'pilish--check-dependencies) #'ignore))
          (setq chat (pilish--setup-session root "feature")
                input (pilish-session-input-buffer chat))
          (should (eq (pilish-session-exists-p (directory-file-name root) "feature") t))
          (should-not (pilish-session-exists-p root))
          (should-not (pilish-session-exists-p root "another"))
          (with-current-buffer chat
            (rename-buffer " *pilish-renamed-transcript*")
            (setq default-directory "/tmp/"))
          (should (equal (pilish-session-directory input) root))
          (should (pilish-session-exists-p root "feature"))
          ;; An input without a live chat is not an inspectable session.
          (with-temp-buffer
            (rename-buffer (pilish--buffer-name :input root))
            (pilish-input-mode)
            (should-not (pilish-session-chat-buffer (current-buffer)))
            (should-not (pilish-session-exists-p root))))
      (pilish-test--kill-live-buffers input chat)
      (delete-directory root t))))

(ert-deftest pilish-test-session-accessors-status-properties-are-isolated ()
  "Status text keeps its faces without sharing their mutable data."
  (let* ((buffers (pilish-test--make-open-session-command-buffers))
         (chat (car buffers)) (input (cadr buffers))
         (color (copy-sequence "green"))
         (face (list :foreground color))
         (help (vector (copy-sequence "details")))
         (extra (make-hash-table :test 'equal))
         seen)
    (puthash "state" (list (copy-sequence "ready")) extra)
    (unwind-protect
        (progn
          (with-current-buffer chat
            (setq-local pilish-extension-status-functions
                        (list (lambda (_buffer key text)
                                (aset key 0 ?X)
                                (aset text 0 ?X)
                                (aset (plist-get (get-text-property 0 'face text)
                                                 :foreground) 0 ?X)
                                (aset (aref (get-text-property 0 'help-echo text) 0) 0 ?X)
                                (aset (car (gethash "state" (get-text-property 0 'data text))) 0 ?X)
                                (set-buffer input))
                              (lambda (_buffer key text)
                                (should (eq (current-buffer) chat))
                                (push (cons key text) seen))))
            (pilish--set-extension-status
             "git" (propertize "synced" 'face face 'help-echo help 'data extra)))
          (should (equal (caar seen) "git"))
          (should (equal (cdar seen) "synced"))
          (should (equal (get-text-property 0 'face (cdar seen))
                         '(:foreground "green")))
          (dolist (buffer (list chat input (buffer-name chat) (buffer-name input)))
            (let* ((all (pilish-session-extension-status buffer))
                   (text (pilish-session-extension-status buffer "git")))
              (should (equal (cdar all) text))
              (should (equal (get-text-property 0 'face text)
                             '(:foreground "green")))
              (should (equal (get-text-property 0 'help-echo text) ["details"]))
              (should (equal (gethash "state" (get-text-property 0 'data text))
                             '("ready")))
              (should-not (eq (get-text-property 0 'data (cdar all))
                              (get-text-property 0 'data text)))
              (aset (plist-get (get-text-property 0 'face text) :foreground) 0 ?X)
              (aset (aref (get-text-property 0 'help-echo text) 0) 0 ?X)
              (aset (car (gethash "state" (get-text-property 0 'data text))) 0 ?X)
              (setcar all '("replaced" . "value"))))
          (with-current-buffer input
            (should (equal (pilish-session-extension-status) '(("git" . "synced")))))
          (should (equal color "green"))
          (should (equal help ["details"]))
          (should (equal (gethash "state" extra) '("ready")))
          ;; Property-only updates are observable, identical repeats are not.
          (with-current-buffer chat
            (setq-local pilish-extension-status-functions
                        (list (lambda (_buffer key text) (push (cons key text) seen))))
            (let ((text (propertize "synced" 'face (list :foreground "blue"))))
              (pilish--set-extension-status "git" text)
              (pilish--set-extension-status "git" text)))
          (should (= (length seen) 2)))
      (pilish-test--kill-live-buffers input chat))))

(ert-deftest pilish-test-session-accessors-copy-long-deep-and-circular-data ()
  "Copies of long, deep, shared and circular data complete and stay independent."
  (let* ((long (make-list 100000 'x))
         (deep (let ((value "bottom"))
                 (dotimes (_ 100000) (setq value (list value)))
                 value))
         (cycle (list (copy-sequence "a") (copy-sequence "b")))
         (shared (copy-sequence "shared"))
         (key (list (copy-sequence "key")))
         (table (make-hash-table :test #'equal))
         (text (propertize "status" 'data (list long cycle (vector shared shared) table))))
    (setcdr (cdr cycle) cycle)
    (puthash key deep table)
    (with-temp-buffer
      (pilish-chat-mode)
      (pilish--set-extension-status "k" text)
      (let* ((copy (pilish-session-extension-status nil "k"))
             (data (get-text-property 0 'data copy)))
        (should (equal copy "status"))
        ;; Long lists keep their length.
        (should (= (length (nth 0 data)) 100000))
        (should-not (eq (nth 0 data) long))
        ;; Cycles stay cycles of independent strings.
        (let ((copied-cycle (nth 1 data)))
          (should (eq (cddr copied-cycle) copied-cycle))
          (should (equal (car copied-cycle) "a"))
          (aset (car copied-cycle) 0 ?X)
          (should (equal (car cycle) "a")))
        ;; Shared elements stay shared within the copy only.
        (let ((vector (nth 2 data)))
          (should (eq (aref vector 0) (aref vector 1)))
          (should-not (eq (aref vector 0) shared)))
        ;; Hash keys are looked up by their completed copies; depth is unbounded.
        (let ((copied-deep (gethash '("key") (nth 3 data))))
          (should copied-deep)
          (should-not (eq copied-deep deep))
          (dotimes (_ 100000) (setq copied-deep (car copied-deep)))
          (should (equal copied-deep "bottom")))))))

(ert-deftest pilish-test-session-accessors-running-tools-use-live-registry ()
  "Live tool IDs are copied; finished and history blocks do not count."
  (let* ((buffers (pilish-test--make-open-session-command-buffers))
         (chat (car buffers)) (input (cadr buffers)))
    (unwind-protect
        (with-current-buffer chat
          (setq pilish--status 'idle pilish--activity-phase "idle")
          (should-not (pilish-session-running-tools input))
          (pilish--display-tool-start "bash" '(:command "true") (copy-sequence "t1"))
          (pilish--display-tool-start "bash" '(:command "true") (copy-sequence "t2"))
          (dolist (buffer (list chat input (buffer-name chat) (buffer-name input) nil))
            (let ((ids (pilish-session-running-tools buffer)))
              (should (equal (sort ids #'string<) '("t1" "t2")))
              (aset (car ids) 0 ?X)
              (setcar ids "replaced")))
          (should (pilish-session-busy-p input))
          (let ((finished (gethash "t2" pilish--live-tool-blocks)))
            (pilish--display-tool-end "bash" '(:command "true")
                                      '((:type "text" :text "done")) nil nil finished)
            (should (overlay-buffer (pilish--tool-block-overlay finished)))
            (should (equal (pilish-session-running-tools input) '("t1"))))
          (pilish--finalize-live-tool-blocks 'pilish-tool-block-error)
          (should-not (pilish-session-running-tools input))
          (should-not (pilish-session-busy-p input))
          (pilish--display-session-history
           [(:role "assistant" :content [(:type "toolCall" :id "old" :name "bash"
                                          :arguments (:command "true"))])
             (:role "toolResult" :toolCallId "old" :toolName "bash"
                    :content [(:type "text" :text "saved")])])
          (should-not (pilish-session-running-tools input)))
      (pilish-test--kill-live-buffers input chat))))

(ert-deftest pilish-test-session-accessors-running-tools-wait-for-call-id ()
  "Argument previews are not counted until an authoritative ID is known."
  (with-temp-buffer
    (pilish-chat-mode)
    (pilish--handle-display-event '(:type "agent_start"))
    (pilish--handle-display-event
     '(:type "message_start" :message (:role "assistant" :content [])))
    (pilish-test--send-assistant-message-update
     '(:type "toolcall_start" :contentIndex 0 :id "provisional" :toolName "bash"))
    (pilish-test--send-assistant-message-update
     '(:type "toolcall_delta" :contentIndex 0 :delta "{\"command\":\"true\"}"))
    (pilish--flush-stream-deltas)
    (should-not (pilish-session-running-tools))
    (should (pilish-session-busy-p))
    (pilish-test--send-assistant-message-update
     '(:type "toolcall_end" :contentIndex 0
       :toolCall (:type "toolCall" :id "authoritative" :name "bash"
                        :arguments (:command "true"))))
    (should (equal (pilish-session-running-tools) '("authoritative")))
    (pilish--finalize-live-tool-blocks 'pilish-tool-block-error)))

;;; Main Entry Point

(ert-deftest pilish-test-pilish-creates-chat-buffer ()
  "M-x pilish creates a chat buffer."
  (pilish-test-with-mock-session "/tmp/pilish-test-main/"
    (should (get-buffer "*pilish-chat:/tmp/pilish-test-main/*"))))

(ert-deftest pilish-test-pilish-creates-input-buffer ()
  "M-x pilish creates an input buffer."
  (pilish-test-with-mock-session "/tmp/pilish-test-main2/"
    (should (get-buffer "*pilish-input:/tmp/pilish-test-main2/*"))))

(ert-deftest pilish-test-pilish-sets-major-modes ()
  "M-x pilish sets correct major modes on buffers."
  (pilish-test-with-mock-session "/tmp/pilish-test-modes/"
    (with-current-buffer "*pilish-chat:/tmp/pilish-test-modes/*"
      (should (derived-mode-p 'pilish-chat-mode)))
    (with-current-buffer "*pilish-input:/tmp/pilish-test-modes/*"
      (should (derived-mode-p 'pilish-input-mode)))))

(ert-deftest pilish-test-open-session-file-validates-sets-up-displays-and-resumes ()
  "Opening a valid session file uses the normal live-session path."
  (let* ((project-dir (pilish-test--make-temp-directory
                       "pilish-test-open-project-"))
         (session-dir (pilish-test--make-temp-directory
                       "pilish-test-open-sessions-"))
         (session-file (expand-file-name "session.jsonl" session-dir))
         (original-validator (symbol-function
                              'pilish--session-file-cwd-or-error))
         (buffers (pilish-test--make-open-session-command-buffers))
         (chat-buf (car buffers))
         (input-buf (cadr buffers))
         (proc (caddr buffers))
         (calls nil))
    (unwind-protect
        (progn
          (pilish-test--write-session-file
           session-file "hello" (directory-file-name project-dir))
          (cl-letf (((symbol-function 'pilish--session-file-cwd-or-error)
                     (lambda (path)
                       (push (list 'validate path) calls)
                       (funcall original-validator path)))
                    ((symbol-function 'pilish--check-dependencies)
                     (lambda (&optional directory)
                       (push (list 'check-dependencies directory) calls)))
                    ((symbol-function 'pilish--setup-session)
                     (lambda (dir &optional session)
                       (push (list 'setup-session dir session) calls)
                       chat-buf))
                    ((symbol-function 'pilish--display-buffers)
                     (lambda (chat input &optional _chat-only)
                       (push (list 'display chat input) calls)))
                    ((symbol-function 'pilish--session-transition-ready-p)
                     (lambda (chat action)
                       (push (list 'ready chat action) calls)
                       t))
                    ((symbol-function 'pilish--resume-selected-session)
                     (lambda (proc chat path)
                       (push (list 'resume proc chat path) calls))))
            (should (eq (pilish-open-session-file session-file) chat-buf)))
          (should (equal (nreverse calls)
                         `((validate ,session-file)
                           (check-dependencies ,project-dir)
                           (setup-session ,project-dir nil)
                           (display ,chat-buf ,input-buf)
                           (ready ,chat-buf "open")
                           (resume ,proc ,chat-buf ,session-file)))))
      (pilish-test--kill-live-buffers input-buf chat-buf)
      (delete-directory project-dir t)
      (delete-directory session-dir t))))

(ert-deftest pilish-test-open-session-file-checks-dependencies-in-session-cwd ()
  "Opening a remote session file checks dependencies in the recorded cwd."
  (let* ((session-file "/ssh:pi-host:/home/pi/.pi/session.jsonl")
         (session-dir "/ssh:pi-host:/home/pi/project/")
         (buffers (pilish-test--make-open-session-command-buffers))
         (chat-buf (car buffers))
         (input-buf (cadr buffers))
         (checked-dir nil))
    (unwind-protect
        (cl-letf (((symbol-function 'pilish--session-file-cwd-or-error)
                   (lambda (_path) session-dir))
                  ((symbol-function 'pilish--check-dependencies)
                   (lambda (&optional directory)
                     (setq checked-dir directory)))
                  ((symbol-function 'pilish--setup-session)
                   (lambda (_dir &optional _session) chat-buf))
                  ((symbol-function 'pilish--display-buffers) #'ignore)
                  ((symbol-function 'pilish--session-transition-ready-p)
                   (lambda (&rest _) nil)))
          (let ((default-directory "/tmp/"))
            (should (eq (pilish-open-session-file session-file) chat-buf)))
          (should (equal checked-dir session-dir)))
      (pilish-test--kill-live-buffers input-buf chat-buf))))

(ert-deftest pilish-test-open-session-file-preserves-multi-hop-session-path ()
  "Opening a multi-hop remote session file keeps the full route through setup."
  (let* ((session-file
          "/ssh:bastion|sudo:root@pi-host:/home/pi/.pi/session.jsonl")
         (session-dir "/ssh:bastion|sudo:root@pi-host:/home/pi/project/")
         (buffers (pilish-test--make-open-session-command-buffers))
         (chat-buf (car buffers))
         (input-buf (cadr buffers))
         (proc (caddr buffers))
         (calls nil))
    (unwind-protect
        (cl-letf (((symbol-function 'pilish--session-file-cwd-or-error)
                   (lambda (path)
                     (push (list 'validate path) calls)
                     session-dir))
                  ((symbol-function 'pilish--check-dependencies)
                   (lambda (&optional directory)
                     (push (list 'check-dependencies directory) calls)))
                  ((symbol-function 'pilish--setup-session)
                   (lambda (dir &optional session)
                     (push (list 'setup-session dir session) calls)
                     chat-buf))
                  ((symbol-function 'pilish--display-buffers)
                   (lambda (chat input &optional _chat-only)
                     (push (list 'display chat input) calls)))
                  ((symbol-function 'pilish--session-transition-ready-p)
                   (lambda (chat action)
                     (push (list 'ready chat action) calls)
                     t))
                  ((symbol-function 'pilish--resume-selected-session)
                   (lambda (proc chat path)
                     (push (list 'resume proc chat path) calls))))
          (let ((default-directory "/tmp/"))
            (should (eq (pilish-open-session-file session-file)
                        chat-buf)))
          (should (equal (nreverse calls)
                         `((validate ,session-file)
                           (check-dependencies ,session-dir)
                           (setup-session ,session-dir nil)
                           (display ,chat-buf ,input-buf)
                           (ready ,chat-buf "open")
                           (resume ,proc ,chat-buf ,session-file)))))
      (pilish-test--kill-live-buffers input-buf chat-buf))))

(ert-deftest pilish-test-open-session-file-skips-resume-when-not-ready ()
  "Opening a valid session file displays the session but does not switch if busy."
  (let* ((project-dir (pilish-test--make-temp-directory
                       "pilish-test-open-not-ready-project-"))
         (session-dir (pilish-test--make-temp-directory
                       "pilish-test-open-not-ready-sessions-"))
         (session-file (expand-file-name "session.jsonl" session-dir))
         (buffers (pilish-test--make-open-session-command-buffers))
         (chat-buf (car buffers))
         (input-buf (cadr buffers))
         (displayed nil)
         (resume-called nil))
    (unwind-protect
        (progn
          (pilish-test--write-session-file
           session-file "hello" (directory-file-name project-dir))
          (cl-letf (((symbol-function 'pilish--check-dependencies)
                     #'ignore)
                    ((symbol-function 'pilish--setup-session)
                     (lambda (_dir &optional _session) chat-buf))
                    ((symbol-function 'pilish--display-buffers)
                     (lambda (_chat _input &optional _chat-only) (setq displayed t)))
                    ((symbol-function 'pilish--session-transition-ready-p)
                     (lambda (_chat _action) nil))
                    ((symbol-function 'pilish--resume-selected-session)
                     (lambda (&rest _) (setq resume-called t))))
            (should (eq (pilish-open-session-file session-file) chat-buf)))
          (should displayed)
          (should-not resume-called))
      (pilish-test--kill-live-buffers input-buf chat-buf)
      (delete-directory project-dir t)
      (delete-directory session-dir t))))

(ert-deftest pilish-test-open-session-file-rejects-bad-cwd-before-setup ()
  "Rejected session files do not start or display a pi session."
  (let* ((session-dir (pilish-test--make-temp-directory
                       "pilish-test-open-reject-sessions-"))
         (cases `(("missing-cwd" . ,(lambda (path)
                                      (pilish-test--write-session-file
                                       path "hello")))
                  ("relative-cwd" . ,(lambda (path)
                                       (pilish-test--write-session-file
                                        path "hello" "relative-project")))
                  ("stale-cwd" . ,(lambda (path)
                                    (pilish-test--write-session-file
                                     path "hello"
                                     (expand-file-name "deleted-project"
                                                       session-dir)))))))
    (unwind-protect
        (dolist (case cases)
          (let ((session-file (expand-file-name
                               (format "%s.jsonl" (car case))
                               session-dir)))
            (funcall (cdr case) session-file)
            (ert-info ((format "rejected case: %s" (car case)))
              (cl-letf (((symbol-function 'pilish--check-dependencies)
                         (lambda ()
                           (ert-fail "Dependencies checked before cwd validation")))
                        ((symbol-function 'pilish--setup-session)
                         (lambda (&rest _)
                           (ert-fail "Session setup ran for rejected file")))
                        ((symbol-function 'pilish--display-buffers)
                         (lambda (&rest _)
                           (ert-fail "Buffers displayed for rejected file")))
                        ((symbol-function 'pilish--resume-selected-session)
                         (lambda (&rest _)
                           (ert-fail "Resume ran for rejected file"))))
                (should-error (pilish-open-session-file session-file)
                              :type 'user-error)))))
      (delete-directory session-dir t))))

(ert-deftest pilish-test-open-session-file-interactive-defaults-to-dired-file ()
  "Interactively opening from Dired defaults to the regular file at point."
  (let* ((session-dir (pilish-test--make-temp-directory
                       "pilish-test-open-dired-sessions-"))
         (project-dir (pilish-test--make-temp-directory
                       "pilish-test-open-dired-project-"))
         (session-file (expand-file-name "session.jsonl" session-dir))
         (buffers (pilish-test--make-open-session-command-buffers))
         (chat-buf (car buffers))
         (input-buf (cadr buffers))
         (read-args nil)
         (dired-buf nil))
    (unwind-protect
        (progn
          (pilish-test--write-session-file
           session-file "hello" (directory-file-name project-dir))
          (setq dired-buf (dired-noselect session-dir))
          (with-current-buffer dired-buf
            (dired-goto-file session-file)
            (cl-letf (((symbol-function 'read-file-name)
                       (lambda (&rest args)
                         (setq read-args args)
                         (expand-file-name (or (nth 4 args) "")
                                           (or (nth 1 args) default-directory))))
                      ((symbol-function 'pilish--check-dependencies)
                       #'ignore)
                      ((symbol-function 'pilish--setup-session)
                       (lambda (_dir &optional _session) chat-buf))
                      ((symbol-function 'pilish--display-buffers)
                       #'ignore)
                      ((symbol-function 'pilish--session-transition-ready-p)
                       (lambda (_chat _action) t))
                      ((symbol-function 'pilish--resume-selected-session)
                       #'ignore))
              (call-interactively #'pilish-open-session-file)))
          (should (equal (nth 0 read-args) "Pi session file: "))
          (should (equal (nth 1 read-args) session-dir))
          (should (equal (nth 2 read-args) session-file))
          (should (eq (nth 3 read-args) t))
          (should (equal (nth 4 read-args)
                         (file-name-nondirectory session-file))))
      (when dired-buf (kill-buffer dired-buf))
      (pilish-test--kill-live-buffers input-buf chat-buf)
      (delete-directory project-dir t)
      (delete-directory session-dir t))))

(ert-deftest pilish-test-open-session-file-dired-default-preserves-multi-hop ()
  "Dired's open-session default keeps the full multi-hop TRAMP route."
  (let* ((session-file
          "/ssh:bastion|sudo:root@pi-host:/home/pi/.pi/session.jsonl")
         (project-dir "/ssh:bastion|sudo:root@pi-host:/home/pi/project/")
         (buffers (pilish-test--make-open-session-command-buffers))
         (chat-buf (car buffers))
         (input-buf (cadr buffers))
         (proc (caddr buffers))
         (read-args nil)
         (resumed-path nil))
    (unwind-protect
        (with-temp-buffer
          (cl-letf (((symbol-function 'derived-mode-p)
                     (lambda (&rest modes) (memq 'dired-mode modes)))
                    ((symbol-function 'dired-get-filename)
                     (lambda (&rest _) session-file))
                    ((symbol-function 'file-regular-p)
                     (lambda (path) (equal path session-file)))
                    ((symbol-function 'read-file-name)
                     (lambda (&rest args)
                       (setq read-args args)
                       (nth 2 args)))
                    ((symbol-function 'pilish--session-file-cwd-or-error)
                     (lambda (path)
                       (should (equal path session-file))
                       project-dir))
                    ((symbol-function 'pilish--check-dependencies)
                     #'ignore)
                    ((symbol-function 'pilish--setup-session)
                     (lambda (dir &optional _session)
                       (should (equal dir project-dir))
                       chat-buf))
                    ((symbol-function 'pilish--display-buffers)
                     #'ignore)
                    ((symbol-function 'pilish--session-transition-ready-p)
                     (lambda (_chat _action) t))
                    ((symbol-function 'pilish--resume-selected-session)
                     (lambda (actual-proc actual-chat path)
                       (should (eq actual-proc proc))
                       (should (eq actual-chat chat-buf))
                       (setq resumed-path path))))
            (call-interactively #'pilish-open-session-file)))
      (pilish-test--kill-live-buffers input-buf chat-buf))
    (should (equal (nth 1 read-args)
                   "/ssh:bastion|sudo:root@pi-host:/home/pi/.pi/"))
    (should (equal (nth 2 read-args) session-file))
    (should (equal (nth 4 read-args) "session.jsonl"))
    (should (equal resumed-path session-file))))

(ert-deftest pilish-test-open-session-file-interactive-defaults-to-visited-jsonl-file ()
  "Interactively opening from a JSONL buffer defaults to its file."
  (let* ((session-dir (pilish-test--make-temp-directory
                       "pilish-test-open-visited-sessions-"))
         (project-dir (pilish-test--make-temp-directory
                       "pilish-test-open-visited-project-"))
         (session-file (expand-file-name "session.jsonl" session-dir))
         (buffers (pilish-test--make-open-session-command-buffers))
         (chat-buf (car buffers))
         (input-buf (cadr buffers))
         (read-args nil)
         (file-buf nil))
    (unwind-protect
        (progn
          (pilish-test--write-session-file
           session-file "hello" (directory-file-name project-dir))
          (setq file-buf (find-file-noselect session-file))
          (with-current-buffer file-buf
            (cl-letf (((symbol-function 'read-file-name)
                       (lambda (&rest args)
                         (setq read-args args)
                         (expand-file-name (or (nth 4 args) "")
                                           (or (nth 1 args) default-directory))))
                      ((symbol-function 'pilish--check-dependencies)
                       #'ignore)
                      ((symbol-function 'pilish--setup-session)
                       (lambda (_dir &optional _session) chat-buf))
                      ((symbol-function 'pilish--display-buffers)
                       #'ignore)
                      ((symbol-function 'pilish--session-transition-ready-p)
                       (lambda (_chat _action) t))
                      ((symbol-function 'pilish--resume-selected-session)
                       #'ignore))
              (call-interactively #'pilish-open-session-file)))
          (should (equal (nth 0 read-args) "Pi session file: "))
          (should (equal (nth 1 read-args) session-dir))
          (should (equal (nth 2 read-args) session-file))
          (should (eq (nth 3 read-args) t))
          (should (equal (nth 4 read-args)
                         (file-name-nondirectory session-file))))
      (when file-buf (kill-buffer file-buf))
      (pilish-test--kill-live-buffers input-buf chat-buf)
      (delete-directory project-dir t)
      (delete-directory session-dir t))))

(ert-deftest pilish-test-open-session-file-rejects-invalid-visited-jsonl-before-setup ()
  "A visited invalid JSONL default is rejected before session setup."
  (let* ((session-dir (pilish-test--make-temp-directory
                       "pilish-test-open-invalid-visited-sessions-"))
         (session-file (expand-file-name "invalid.jsonl" session-dir))
         (read-args nil)
         (file-buf nil))
    (unwind-protect
        (progn
          (pilish-test--write-session-file session-file "hello")
          (setq file-buf (find-file-noselect session-file))
          (with-current-buffer file-buf
            (cl-letf (((symbol-function 'read-file-name)
                       (lambda (&rest args)
                         (setq read-args args)
                         (expand-file-name (or (nth 4 args) "")
                                           (or (nth 1 args) default-directory))))
                      ((symbol-function 'pilish--check-dependencies)
                       (lambda ()
                         (ert-fail "Dependencies checked before cwd validation")))
                      ((symbol-function 'pilish--setup-session)
                       (lambda (&rest _)
                         (ert-fail "Session setup ran for rejected file")))
                      ((symbol-function 'pilish--display-buffers)
                       (lambda (&rest _)
                         (ert-fail "Buffers displayed for rejected file")))
                      ((symbol-function 'pilish--resume-selected-session)
                       (lambda (&rest _)
                         (ert-fail "Resume ran for rejected file"))))
              (should-error (call-interactively #'pilish-open-session-file)
                            :type 'user-error)))
          (should (equal (nth 0 read-args) "Pi session file: "))
          (should (equal (nth 1 read-args) session-dir))
          (should (equal (nth 2 read-args) session-file))
          (should (eq (nth 3 read-args) t))
          (should (equal (nth 4 read-args)
                         (file-name-nondirectory session-file))))
      (when file-buf (kill-buffer file-buf))
      (delete-directory session-dir t))))

(ert-deftest pilish-test-open-session-file-dired-default-wins-over-visited-jsonl-file ()
  "Dired's regular file at point has priority over `buffer-file-name'."
  (let* ((session-dir (pilish-test--make-temp-directory
                       "pilish-test-open-dired-priority-sessions-"))
         (project-dir (pilish-test--make-temp-directory
                       "pilish-test-open-dired-priority-project-"))
         (dired-file (expand-file-name "dired.jsonl" session-dir))
         (visited-file (expand-file-name "visited.jsonl" session-dir))
         (buffers (pilish-test--make-open-session-command-buffers))
         (chat-buf (car buffers))
         (input-buf (cadr buffers))
         (read-args nil)
         (dired-buf nil))
    (unwind-protect
        (progn
          (pilish-test--write-session-file
           dired-file "dired" (directory-file-name project-dir))
          (pilish-test--write-session-file
           visited-file "visited" (directory-file-name project-dir))
          (setq dired-buf (dired-noselect session-dir))
          (with-current-buffer dired-buf
            (setq-local buffer-file-name visited-file)
            (dired-goto-file dired-file)
            (cl-letf (((symbol-function 'read-file-name)
                       (lambda (&rest args)
                         (setq read-args args)
                         (expand-file-name (or (nth 4 args) "")
                                           (or (nth 1 args) default-directory))))
                      ((symbol-function 'pilish--check-dependencies)
                       #'ignore)
                      ((symbol-function 'pilish--setup-session)
                       (lambda (_dir &optional _session) chat-buf))
                      ((symbol-function 'pilish--display-buffers)
                       #'ignore)
                      ((symbol-function 'pilish--session-transition-ready-p)
                       (lambda (_chat _action) t))
                      ((symbol-function 'pilish--resume-selected-session)
                       #'ignore))
              (call-interactively #'pilish-open-session-file)))
          (should (equal (nth 0 read-args) "Pi session file: "))
          (should (equal (nth 1 read-args) session-dir))
          (should (equal (nth 2 read-args) dired-file))
          (should (eq (nth 3 read-args) t))
          (should (equal (nth 4 read-args)
                         (file-name-nondirectory dired-file))))
      (when dired-buf (kill-buffer dired-buf))
      (pilish-test--kill-live-buffers input-buf chat-buf)
      (delete-directory project-dir t)
      (delete-directory session-dir t))))

(ert-deftest pilish-test-open-session-file-visited-non-jsonl-has-no-file-default ()
  "Visited non-JSONL buffers do not become session-file defaults."
  (let* ((session-dir (pilish-test--make-temp-directory
                       "pilish-test-open-non-jsonl-sessions-"))
         (project-dir (pilish-test--make-temp-directory
                       "pilish-test-open-non-jsonl-project-"))
         (text-file (expand-file-name "notes.txt" session-dir))
         (chosen-file (expand-file-name "chosen.jsonl" session-dir))
         (buffers (pilish-test--make-open-session-command-buffers))
         (chat-buf (car buffers))
         (input-buf (cadr buffers))
         (read-args nil)
         (read-buffer-file-name nil)
         (file-buf nil))
    (unwind-protect
        (progn
          (with-temp-file text-file (insert "not a session\n"))
          (pilish-test--write-session-file
           chosen-file "chosen" (directory-file-name project-dir))
          (setq file-buf (find-file-noselect text-file))
          (with-current-buffer file-buf
            (cl-letf (((symbol-function 'read-file-name)
                       (lambda (&rest args)
                         (setq read-args args
                               read-buffer-file-name buffer-file-name)
                         chosen-file))
                      ((symbol-function 'pilish--check-dependencies)
                       #'ignore)
                      ((symbol-function 'pilish--setup-session)
                       (lambda (_dir &optional _session) chat-buf))
                      ((symbol-function 'pilish--display-buffers)
                       #'ignore)
                      ((symbol-function 'pilish--session-transition-ready-p)
                       (lambda (_chat _action) t))
                      ((symbol-function 'pilish--resume-selected-session)
                       #'ignore))
              (call-interactively #'pilish-open-session-file)))
          (should (equal (nth 0 read-args) "Pi session file: "))
          (should-not (nth 1 read-args))
          (should-not (nth 2 read-args))
          (should (eq (nth 3 read-args) t))
          (should-not (nth 4 read-args))
          (should-not read-buffer-file-name))
      (when file-buf (kill-buffer file-buf))
      (pilish-test--kill-live-buffers input-buf chat-buf)
      (delete-directory project-dir t)
      (delete-directory session-dir t))))

(ert-deftest pilish-test-open-session-file-jsonl-probe-errors-have-no-file-default ()
  "Errors while probing a visited .jsonl file do not abort the prompt."
  (let* ((session-dir (pilish-test--make-temp-directory
                       "pilish-test-open-probe-error-sessions-"))
         (project-dir (pilish-test--make-temp-directory
                       "pilish-test-open-probe-error-project-"))
         (probed-file (expand-file-name "probed.jsonl" session-dir))
         (chosen-file (expand-file-name "chosen.jsonl" session-dir))
         (original-file-regular-p (symbol-function 'file-regular-p))
         (buffers (pilish-test--make-open-session-command-buffers))
         (chat-buf (car buffers))
         (input-buf (cadr buffers))
         (read-args nil)
         (read-buffer-file-name nil)
         (file-buf nil))
    (unwind-protect
        (progn
          (with-temp-file probed-file (insert "not important\n"))
          (pilish-test--write-session-file
           chosen-file "chosen" (directory-file-name project-dir))
          (setq file-buf (find-file-noselect probed-file))
          (with-current-buffer file-buf
            (cl-letf (((symbol-function 'file-regular-p)
                       (lambda (path)
                         (if (equal (expand-file-name path) probed-file)
                             (error "probe failed")
                           (funcall original-file-regular-p path))))
                      ((symbol-function 'read-file-name)
                       (lambda (&rest args)
                         (setq read-args args
                               read-buffer-file-name buffer-file-name)
                         chosen-file))
                      ((symbol-function 'pilish--check-dependencies)
                       #'ignore)
                      ((symbol-function 'pilish--setup-session)
                       (lambda (_dir &optional _session) chat-buf))
                      ((symbol-function 'pilish--display-buffers)
                       #'ignore)
                      ((symbol-function 'pilish--session-transition-ready-p)
                       (lambda (_chat _action) t))
                      ((symbol-function 'pilish--resume-selected-session)
                       #'ignore))
              (call-interactively #'pilish-open-session-file)))
          (should (equal (nth 0 read-args) "Pi session file: "))
          (should-not (nth 1 read-args))
          (should-not (nth 2 read-args))
          (should (eq (nth 3 read-args) t))
          (should-not (nth 4 read-args))
          (should-not read-buffer-file-name))
      (when file-buf (kill-buffer file-buf))
      (pilish-test--kill-live-buffers input-buf chat-buf)
      (delete-directory project-dir t)
      (delete-directory session-dir t))))

(ert-deftest pilish-test-open-session-file-unreadable-jsonl-has-no-file-default ()
  "An unreadable .jsonl file is not used as a session-file default."
  (let* ((session-dir (pilish-test--make-temp-directory
                       "pilish-test-open-unreadable-sessions-"))
         (project-dir (pilish-test--make-temp-directory
                       "pilish-test-open-unreadable-project-"))
         (unreadable-file (expand-file-name "unreadable.jsonl" session-dir))
         (chosen-file (expand-file-name "chosen.jsonl" session-dir))
         (original-file-readable-p (symbol-function 'file-readable-p))
         (buffers (pilish-test--make-open-session-command-buffers))
         (chat-buf (car buffers))
         (input-buf (cadr buffers))
         (read-args nil)
         (read-buffer-file-name nil)
         (file-buf nil))
    (unwind-protect
        (progn
          (with-temp-file unreadable-file (insert "not important\n"))
          (pilish-test--write-session-file
           chosen-file "chosen" (directory-file-name project-dir))
          (setq file-buf (find-file-noselect unreadable-file))
          (with-current-buffer file-buf
            (cl-letf (((symbol-function 'file-readable-p)
                       (lambda (path)
                         (and (not (equal (expand-file-name path)
                                          unreadable-file))
                              (funcall original-file-readable-p path))))
                      ((symbol-function 'read-file-name)
                       (lambda (&rest args)
                         (setq read-args args
                               read-buffer-file-name buffer-file-name)
                         chosen-file))
                      ((symbol-function 'pilish--check-dependencies)
                       #'ignore)
                      ((symbol-function 'pilish--setup-session)
                       (lambda (_dir &optional _session) chat-buf))
                      ((symbol-function 'pilish--display-buffers)
                       #'ignore)
                      ((symbol-function 'pilish--session-transition-ready-p)
                       (lambda (_chat _action) t))
                      ((symbol-function 'pilish--resume-selected-session)
                       #'ignore))
              (call-interactively #'pilish-open-session-file)))
          (should (equal (nth 0 read-args) "Pi session file: "))
          (should-not (nth 1 read-args))
          (should-not (nth 2 read-args))
          (should (eq (nth 3 read-args) t))
          (should-not (nth 4 read-args))
          (should-not read-buffer-file-name))
      (when file-buf (kill-buffer file-buf))
      (pilish-test--kill-live-buffers input-buf chat-buf)
      (delete-directory project-dir t)
      (delete-directory session-dir t))))

(ert-deftest pilish-test-open-session-file-non-regular-jsonl-has-no-file-default ()
  "A non-regular .jsonl path is not used as a session-file default."
  (let* ((session-dir (pilish-test--make-temp-directory
                       "pilish-test-open-non-regular-sessions-"))
         (project-dir (pilish-test--make-temp-directory
                       "pilish-test-open-non-regular-project-"))
         (jsonl-dir (expand-file-name "directory.jsonl" session-dir))
         (chosen-file (expand-file-name "chosen.jsonl" session-dir))
         (buffers (pilish-test--make-open-session-command-buffers))
         (chat-buf (car buffers))
         (input-buf (cadr buffers))
         (read-args nil)
         (read-buffer-file-name nil)
         (file-buf nil))
    (unwind-protect
        (progn
          (make-directory jsonl-dir)
          (pilish-test--write-session-file
           chosen-file "chosen" (directory-file-name project-dir))
          (setq file-buf (generate-new-buffer " *pilish-jsonl-dir*"))
          (with-current-buffer file-buf
            (setq buffer-file-name jsonl-dir)
            (setq default-directory session-dir)
            (cl-letf (((symbol-function 'read-file-name)
                       (lambda (&rest args)
                         (setq read-args args
                               read-buffer-file-name buffer-file-name)
                         chosen-file))
                      ((symbol-function 'pilish--check-dependencies)
                       #'ignore)
                      ((symbol-function 'pilish--setup-session)
                       (lambda (_dir &optional _session) chat-buf))
                      ((symbol-function 'pilish--display-buffers)
                       #'ignore)
                      ((symbol-function 'pilish--session-transition-ready-p)
                       (lambda (_chat _action) t))
                      ((symbol-function 'pilish--resume-selected-session)
                       #'ignore))
              (call-interactively #'pilish-open-session-file)))
          (should (equal (nth 0 read-args) "Pi session file: "))
          (should-not (nth 1 read-args))
          (should-not (nth 2 read-args))
          (should (eq (nth 3 read-args) t))
          (should-not (nth 4 read-args))
          (should-not read-buffer-file-name))
      (when file-buf (kill-buffer file-buf))
      (pilish-test--kill-live-buffers input-buf chat-buf)
      (delete-directory project-dir t)
      (delete-directory session-dir t))))

(ert-deftest pilish-test-open-session-file-dired-directory-has-no-file-default ()
  "Interactively opening from Dired does not default to a directory at point."
  (let* ((session-dir (pilish-test--make-temp-directory
                       "pilish-test-open-dired-dir-sessions-"))
         (project-dir (pilish-test--make-temp-directory
                       "pilish-test-open-dired-dir-project-"))
         (subdir (expand-file-name "subdir" session-dir))
         (visited-file (expand-file-name "visited.jsonl" session-dir))
         (chosen-file (expand-file-name "chosen.jsonl" session-dir))
         (buffers (pilish-test--make-open-session-command-buffers))
         (chat-buf (car buffers))
         (input-buf (cadr buffers))
         (read-args nil)
         (read-buffer-file-name nil)
         (dired-buf nil))
    (unwind-protect
        (progn
          (make-directory subdir)
          (with-temp-file chosen-file (insert "{}\n"))
          (with-temp-file visited-file (insert "{}\n"))
          (setq dired-buf (dired-noselect session-dir))
          (with-current-buffer dired-buf
            (setq-local buffer-file-name visited-file)
            (dired-goto-file subdir)
            (cl-letf (((symbol-function 'read-file-name)
                       (lambda (&rest args)
                         (setq read-args args
                               read-buffer-file-name buffer-file-name)
                         chosen-file))
                      ((symbol-function 'pilish--session-file-cwd-or-error)
                       (lambda (_path) project-dir))
                      ((symbol-function 'pilish--check-dependencies)
                       #'ignore)
                      ((symbol-function 'pilish--setup-session)
                       (lambda (_dir &optional _session) chat-buf))
                      ((symbol-function 'pilish--display-buffers)
                       #'ignore)
                      ((symbol-function 'pilish--session-transition-ready-p)
                       (lambda (_chat _action) t))
                      ((symbol-function 'pilish--resume-selected-session)
                       #'ignore))
              (call-interactively #'pilish-open-session-file)))
          (should (equal (nth 0 read-args) "Pi session file: "))
          (should-not (nth 1 read-args))
          (should-not (nth 2 read-args))
          (should (eq (nth 3 read-args) t))
          (should-not (nth 4 read-args))
          (should-not read-buffer-file-name))
      (when dired-buf (kill-buffer dired-buf))
      (pilish-test--kill-live-buffers input-buf chat-buf)
      (delete-directory project-dir t)
      (delete-directory session-dir t))))

(ert-deftest pilish-test-open-session-file-does-not-change-dired-pilish ()
  "Plain `pilish' stays directory-oriented when called from Dired."
  (let* ((session-dir (pilish-test--make-temp-directory
                       "pilish-test-open-plain-dired-"))
         (session-file (expand-file-name "session.jsonl" session-dir))
         (buffers (pilish-test--make-open-session-command-buffers))
         (chat-buf (car buffers))
         (input-buf (cadr buffers))
         (setup-dir nil)
         (dired-buf nil))
    (unwind-protect
        (progn
          (with-temp-file session-file (insert "{}\n"))
          (setq dired-buf (dired-noselect session-dir))
          (with-current-buffer dired-buf
            (dired-goto-file session-file)
            (cl-letf (((symbol-function 'dired-get-filename)
                       (lambda (&rest _)
                         (ert-fail "Pilish inspected Dired point")))
                      ((symbol-function 'project-current)
                       (lambda (&rest _) nil))
                      ((symbol-function 'pilish--check-dependencies)
                       #'ignore)
                      ((symbol-function 'pilish--setup-session)
                       (lambda (dir &optional _session)
                         (setq setup-dir dir)
                         chat-buf))
                      ((symbol-function 'pilish--display-buffers)
                       #'ignore))
              (pilish)))
          (should (equal setup-dir session-dir)))
      (when dired-buf (kill-buffer dired-buf))
      (pilish-test--kill-live-buffers input-buf chat-buf)
      (delete-directory session-dir t))))

(ert-deftest pilish-test-open-session-file-does-not-change-visited-jsonl-pilish ()
  "Plain `pilish' stays directory-oriented in a JSONL buffer."
  (let* ((session-dir (pilish-test--make-temp-directory
                       "pilish-test-open-plain-jsonl-"))
         (session-file (expand-file-name "session.jsonl" session-dir))
         (buffers (pilish-test--make-open-session-command-buffers))
         (chat-buf (car buffers))
         (input-buf (cadr buffers))
         (setup-dir nil)
         (file-buf nil))
    (unwind-protect
        (progn
          (with-temp-file session-file (insert "{}\n"))
          (setq file-buf (find-file-noselect session-file))
          (with-current-buffer file-buf
            (cl-letf (((symbol-function 'pilish--read-session-file-name)
                       (lambda ()
                         (ert-fail "Pilish read a session file")))
                      ((symbol-function 'pilish--session-file-cwd-or-error)
                       (lambda (&rest _)
                         (ert-fail "Pilish validated a session file")))
                      ((symbol-function 'pilish--resume-selected-session)
                       (lambda (&rest _)
                         (ert-fail "Pilish resumed a session file")))
                      ((symbol-function 'project-current)
                       (lambda (&rest _) nil))
                      ((symbol-function 'pilish--check-dependencies)
                       #'ignore)
                      ((symbol-function 'pilish--setup-session)
                       (lambda (dir &optional _session)
                         (setq setup-dir dir)
                         chat-buf))
                      ((symbol-function 'pilish--display-buffers)
                       #'ignore))
              (pilish)))
          (should (equal setup-dir session-dir)))
      (when file-buf (kill-buffer file-buf))
      (pilish-test--kill-live-buffers input-buf chat-buf)
      (delete-directory session-dir t))))

;;; Programmatic Submission

(defun pilish-test--submission-draft-state (input)
  "Return the protected draft and history state in INPUT."
  (with-current-buffer input
    (list (buffer-string) (point) (buffer-modified-p)
          (copy-tree pilish--draft-prompt-image)
          (and pilish--input-ring (ring-elements pilish--input-ring))
          pilish--input-ring-index pilish--input-saved)))

(ert-deftest pilish-test-submit-prompt-sends-rpc-without-owning-draft ()
  "Idle and busy submissions go straight to Pi without UI queue ownership."
  (pcase-let ((`(,chat ,input ,proc)
               (pilish-test--make-open-session-command-buffers)))
    (unwind-protect
        (progn
          (with-current-buffer input
            (insert "Unsent draft\nwith a second line")
            (goto-char 4)
            (setq pilish--draft-prompt-image '(:data "bytes" :mimeType "image/png"))
            (pilish--history-add "Older prompt")
            (setq pilish--input-ring-index 0 pilish--input-saved "Saved draft"))
          (dolist (status '(idle sending streaming compacting))
            (dolist (behavior '(nil "followUp" "steer"))
              (let ((before (pilish-test--submission-draft-state input))
                    (origin (current-buffer))
                    (window (selected-window))
                    wire result)
                (with-current-buffer chat
                  (setq pilish--status status))
                (cl-letf (((symbol-function 'pilish--send-string)
                           (lambda (process text)
                             (should (eq process proc))
                             (setq wire (pilish--parse-json-line text)))))
                  (pilish-submit-prompt
                   chat "  API prompt\n" (lambda (r) (setq result r)) behavior))
                (should (equal (plist-get wire :type) "prompt"))
                (should (equal (plist-get wire :message) "  API prompt\n"))
                (should (equal (plist-get wire :streamingBehavior)
                               (or behavior "followUp")))
                (should-not (plist-member wire :images))
                (should-not result)
                (pilish--dispatch-response
                 proc (list :type "response" :id (plist-get wire :id)
                            :success t :data '(:disposition "queued")))
                (should (eq (plist-get result :success) t))
                (should (equal (pilish-test--submission-draft-state input) before))
                (should (eq (current-buffer) origin))
                (should (eq (selected-window) window))
                (with-current-buffer chat
                  (should (eq pilish--status (if (eq status 'idle) 'sending status)))
                  (should (pilish--session-busy-p))
                  (should (= 1 (length pilish--prompt-waits)))
                  (should-not pilish--followup-queue)
                  (should-not pilish--prompt-wait)
                  (pilish--invalidate-prompt-start-wait))))))
      (pilish-test--kill-live-buffers input chat))))

(ert-deftest pilish-test-submit-prompt-validates-before-sending ()
  "Invalid requests never enter the wire or disturb the draft."
  (should (fboundp 'pilish-submit-prompt))
  (pcase-let ((`(,chat ,input ,proc)
               (pilish-test--make-open-session-command-buffers)))
    (unwind-protect
        (let ((before (pilish-test--submission-draft-state input)))
          (cl-letf (((symbol-function 'pilish--send-string)
                     (lambda (&rest _) (ert-fail "Invalid prompt sent"))))
            (dolist (args `((nil "text" ignore)
                            (,input "text" ignore)
                            (,chat nil ignore)
                            (,chat "" ignore)
                            (,chat " \n\t" ignore)
                            (,chat "text" nil)
                            (,chat "text" ignore "invalid")))
              (should-error (apply #'pilish-submit-prompt args)))
            (with-current-buffer chat (setq pilish--process nil))
            (should-error (pilish-submit-prompt chat "text" #'ignore))
            (with-current-buffer chat (setq pilish--process proc))
            (delete-process proc)
            (should-error (pilish-submit-prompt chat "text" #'ignore)))
          (should (equal (pilish-test--submission-draft-state input) before)))
      (pilish-test--kill-live-buffers input chat))))

(ert-deftest pilish-test-submit-prompt-rejection-does-not-restore-over-draft ()
  "A rejected or handled request passes its response to the caller unchanged."
  (pcase-let ((`(,chat ,input ,proc)
               (pilish-test--make-open-session-command-buffers)))
    (unwind-protect
        (progn
          (with-current-buffer input (insert "Keep this newer draft"))
          (dolist (response '((:type "response" :success :false :error "Rejected")
                              (:type "response" :success t
                               :data (:disposition "handled"))))
            (let ((before (pilish-test--submission-draft-state input))
                  wire result)
              (cl-letf (((symbol-function 'pilish--send-string)
                         (lambda (_ text)
                           (setq wire (pilish--parse-json-line text)))))
                (pilish-submit-prompt
                 chat "/extension" (lambda (r) (setq result r))))
              (let ((reply (append response (list :id (plist-get wire :id)))))
                (pilish--dispatch-response proc reply)
                (should (eq result reply)))
              (should (equal (pilish-test--submission-draft-state input) before)))))
      (pilish-test--kill-live-buffers input chat))))

(ert-deftest pilish-test-submit-prompt-send-failure-cleans-request ()
  "A synchronous send failure signals, preserving draft and pending tables."
  (should (fboundp 'pilish-submit-prompt))
  (pcase-let ((`(,chat ,input ,proc)
               (pilish-test--make-open-session-command-buffers)))
    (unwind-protect
        (let ((before (pilish-test--submission-draft-state input)) called)
          (cl-letf (((symbol-function 'pilish--send-string)
                     (lambda (&rest _) (error "Send failed"))))
            (should-error
             (pilish-submit-prompt chat "text" (lambda (_) (setq called t)))))
          (should-not called)
          (should (= 0 (hash-table-count (pilish--get-pending-requests proc))))
          (should (= 0 (hash-table-count (pilish--get-pending-command-types proc))))
          (should (equal (pilish-test--submission-draft-state input) before)))
      (pilish-test--kill-live-buffers input chat))))

(ert-deftest pilish-test-submit-prompt-process-exit-reports-failure ()
  "Exit settles a submitted prompt through the ordinary core callback path."
  (pcase-let ((`(,chat ,input ,proc)
               (pilish-test--make-open-session-command-buffers)))
    (unwind-protect
        (let ((before (pilish-test--submission-draft-state input)) responses)
          (cl-letf (((symbol-function 'pilish--send-string) #'ignore))
            (pilish-submit-prompt chat "text" (lambda (r) (push r responses))))
          (delete-process proc)
          (pilish--handle-process-exit proc "connection closed\n")
          (should (= 1 (length responses)))
          (should (eq (plist-get (car responses) :success) :false))
          (should (plist-get (car responses) :processExit))
          (should (equal (pilish-test--submission-draft-state input) before)))
      (pilish-test--kill-live-buffers input chat))))

(ert-deftest pilish-test-submit-prompt-refuses-session-transitions ()
  "A transition refuses all behaviors before RPC or draft mutation."
  (pcase-let ((`(,chat ,input ,proc)
               (pilish-test--make-open-session-command-buffers)))
    (unwind-protect
        (progn
          (with-current-buffer input
            (insert "Unsent draft")
            (goto-char 3)
            (pilish--history-add "Earlier prompt")
            (setq pilish--draft-prompt-image '(:data "bytes" :mimeType "image/png")))
          (with-current-buffer chat
            (pilish--begin-session-transition proc))
          (let ((before (pilish-test--submission-draft-state input))
                sent callback-called)
            (cl-letf (((symbol-function 'pilish--rpc-async)
                       (lambda (&rest _) (setq sent t))))
              (dolist (behavior '(nil "followUp" "steer"))
                (should-error
                 (pilish-submit-prompt chat "API text"
                                       (lambda (_) (setq callback-called t))
                                       behavior))))
            (should-not sent)
            (should-not callback-called)
            (should (equal (pilish-test--submission-draft-state input) before))
            (should (eq (buffer-local-value 'pilish--process chat) proc))
            (should (pilish--session-transition-active-p chat))))
      (pilish-test--kill-live-buffers input chat))))

(ert-deftest pilish-test-submit-prompt-refuses-reload-old-process ()
  "Reload keeps its old process live, but API prompts cannot go to it."
  ;; Like `pilish-test--with-reload-chat', the old process is a real
  ;; subprocess: reload asks Pi to shut down and close its stdin, and only a
  ;; subprocess exits on that.
  (pcase-let ((`(,chat ,input ,old-proc)
               (pilish-test--make-open-session-command-buffers
                (start-process "pilish-api-reload-old" nil "cat"))))
    (let ((new-proc (make-pipe-process :name "pilish-api-reload"
                                       :buffer nil :noquery t))
          (root (file-name-as-directory (make-temp-file "pilish-api-reload-" t)))
          switch-callback sent responses)
      (unwind-protect
          (progn
            (with-current-buffer input (insert "Keep this draft through reload"))
            (with-current-buffer chat
              (pilish--set-chat-session-identity root)
              (setq pilish--state
                    (list :session-file (expand-file-name "session.jsonl" root))))
            (cl-letf (((symbol-function 'pilish--start-process)
                       (lambda (&rest _) new-proc))
                      ((symbol-function 'pilish--rpc-async)
                       (lambda (proc command callback)
                         (pcase (plist-get command :type)
                           ("switch_session" (setq switch-callback callback))
                           ("prompt"
                            (push proc sent)
                            (funcall callback '(:success t :data (:disposition "started"))))
                           (_ (ert-fail "Unexpected reload RPC")))))
                      ((symbol-function 'pilish--refresh-transition-state-and-history)
                       (lambda (_proc buf generation &rest _)
                         (with-current-buffer buf
                           (pilish--finish-session-transition generation))))
                      ((symbol-function 'pilish--refresh-commands-ignoring-errors)
                       #'ignore))
              (with-current-buffer chat (pilish-reload))
              (should switch-callback)
              (should (process-live-p old-proc))
              (should (eq (buffer-local-value 'pilish--process chat) old-proc))
              (should (pilish--session-transition-active-p chat))
              (let ((before (pilish-test--submission-draft-state input)))
                (should-error
                 (pilish-submit-prompt chat "Must not reach the old process"
                                       (lambda (r) (push r responses))))
                (should-not sent)
                (should-not responses)
                (should (equal (pilish-test--submission-draft-state input) before)))
              (funcall switch-callback '(:success t :data (:cancelled :false)))
              ;; Pi is asked to shut down and exits on its own.
              (should (pilish-test-wait-for-process-exit old-proc))
              (should (eq (buffer-local-value 'pilish--process chat) new-proc))
              (should-not (pilish--session-transition-active-p chat))
              (pilish-submit-prompt chat "Safe after reload"
                                    (lambda (r) (push r responses)))
              (should (equal sent (list new-proc)))
              (should (= 1 (length responses)))))
        (when (process-live-p old-proc) (delete-process old-proc))
        (when (process-live-p new-proc) (delete-process new-proc))
        (pilish-test--kill-live-buffers input chat)
        (delete-directory root t)))))

(ert-deftest pilish-test-submit-prompt-fake-draft-and-queue ()
  "The subprocess reports acceptance, queue and rejection with the draft intact."
  (let* ((root (file-name-as-directory (make-temp-file "pilish-submit-" t)))
         (default-directory root)
         (fixture (pilish-test--read-json-fixture "fake-pi/input-dispositions.json"))
         (pilish-executable (pilish-test-fake-pi-executable))
         (pilish-extra-args (list "--scenario" "api" "--scenario-dir" root
                                 "--session-dir" root))
         chat input proc)
    (unwind-protect
        (progn
          ;; Keep the busy window long enough for the assertions, not a sleep
          ;; in the test: every wait below watches an observed state or reply.
          (plist-put (plist-get fixture :prompt) :delay_ms 100)
          (plist-put (plist-get fixture :prompt) :chunk_count 10)
          (with-temp-file (expand-file-name "api.json" root)
            (insert (json-serialize fixture)))
          (setq chat (pilish--setup-session root)
                input (buffer-local-value 'pilish--input-buffer chat)
                proc (buffer-local-value 'pilish--process chat))
          (should (pilish-test-wait-until
                   (lambda ()
                     (= 0 (hash-table-count (pilish--get-pending-requests proc))))
                   5 0.01 proc))
          (with-current-buffer input
            (insert "My unsent draft\nStill composing")
            (goto-char 5)
            (setq pilish--draft-prompt-image '(:data "draft-bytes" :mimeType "image/png"))
            (pilish--history-add "Previous local prompt")
            (set-buffer-modified-p nil))
          (let ((before (pilish-test--submission-draft-state input))
                started rejected queued handled)
            (pilish-submit-prompt chat "API first" (lambda (r) (setq started r)))
            (should (pilish-test-wait-until
                     (lambda ()
                       (and started (eq (buffer-local-value 'pilish--status chat)
                                        'streaming)))
                     5 0.01 proc))
            (should (equal (plist-get (plist-get started :data) :disposition) "started"))
            ;; The bounded fake rejects busy follow-ups.  Test that rejection
            ;; is returned, not hidden by silently queuing it in the frontend.
            (pilish-submit-prompt chat "Fake unsupported follow-up"
                                  (lambda (r) (setq rejected r)))
            (should (pilish-test-wait-until (lambda () rejected) 5 0.01 proc))
            (should (eq (plist-get rejected :success) :false))
            (pilish-submit-prompt chat "API steer" (lambda (r) (setq queued r)) "steer")
            (should (pilish-test-wait-until
                     (lambda ()
                       (and queued
                            (equal (plist-get (pilish--process-queue-snapshot proc)
                                              :steering)
                                   ["API steer"])))
                     5 0.01 proc))
            (should (equal (plist-get (plist-get queued :data) :disposition) "queued"))
            (pilish-submit-prompt chat "consume without a run"
                                  (lambda (r) (setq handled r)))
            (should (pilish-test-wait-until (lambda () handled) 5 0.01 proc))
            (should (equal (plist-get (plist-get handled :data) :disposition) "handled"))
            (should (equal (pilish-test--submission-draft-state input) before))
            (should (pilish-test-wait-until
                     (lambda ()
                       (and (eq (buffer-local-value 'pilish--status chat) 'idle)
                            (not (buffer-local-value 'pilish--prompt-waits chat))
                            (with-current-buffer chat
                              (string-match-p "Steered fake reply for: API steer"
                                              (buffer-string)))))
                     5 0.01 proc))
            (should (equal (plist-get (pilish--process-queue-snapshot proc) :steering) []))
            (should (equal (pilish-test--submission-draft-state input) before))
            (should-not (buffer-local-value 'pilish--followup-queue chat))
            (should-not (buffer-local-value 'pilish--prompt-wait chat))
            (should-not (get-buffer-window-list chat nil t))
            (should-not (get-buffer-window-list input nil t))))
      (when (and proc (process-live-p proc)) (delete-process proc))
      (pilish-test--kill-live-buffers input chat)
      (delete-directory root t))))

(defun pilish-test--api-response (process request success &optional disposition)
  "Deliver a correlated prompt response for REQUEST from PROCESS."
  (let ((response (list :type "response" :id (plist-get request :id)
                        :command "prompt" :success success
                        :data (list :disposition disposition))))
    (pilish--dispatch-response process response)
    response))

(ert-deftest pilish-test-submit-prompt-interleaves-with-user-send ()
  "Before agent_start, API requests go to Pi while user text stays in the FIFO."
  (pilish-test-with-rpc-session (chat input proc commands)
    (pilish-submit-prompt chat "API A" #'ignore)
    (let ((a (car commands)))
      (pilish-submit-prompt chat "API B" #'ignore "steer")
      (let ((b (car commands)))
        (with-current-buffer input (insert "User follow-up") (pilish-send))
        (should (= 2 (length commands)))
        (with-current-buffer chat
          (should (= 2 (length pilish--prompt-waits)))
          (should (equal pilish--followup-queue '("User follow-up")))
          (should (eq pilish--status 'sending))
          (should-not pilish--prompt-wait))
        (pilish-test--api-response proc b t "queued")
        (pilish-test--api-response proc a t "started")
        (pilish-test--stdout proc '(:type "agent_start")
                             '(:type "agent_end" :messages [])
                             '(:type "agent_settled"))
        ;; A run is not attributed to either outstanding API request.  Keep
        ;; the user's FIFO blocked until all ambiguous acceptances are probed.
        (should (= 2 (length commands)))
        (dotimes (_ 2)
          (let ((wait (car (buffer-local-value 'pilish--prompt-waits chat))))
            (pilish--clear-sending-if-no-agent-start
             chat wait (pilish--prompt-wait-on-no-agent-start wait))
            (let ((probe (car commands)))
              (should (equal (plist-get probe :type) "get_state"))
              (pilish--dispatch-response
               proc (list :type "response" :id (plist-get probe :id) :success t
                          :data '(:isStreaming :false :isCompacting :false
                                  :pendingMessageCount 0))))))
        ;; Once the local follow-up starts it becomes the distinguished owner.
        (should (buffer-local-value 'pilish--prompt-wait chat))
        (should (equal (plist-get (car commands) :message) "User follow-up"))
        (should (equal (mapcar (lambda (c) (plist-get c :message))
                              (seq-filter (lambda (c) (equal (plist-get c :type) "prompt"))
                                          (reverse commands)))
                       '("API A" "API B" "User follow-up")))))))

(ert-deftest pilish-test-submit-prompt-release-does-not-release-another-request ()
  "A rejected/handled API response cannot release pending or accepted API B."
  (dolist (accepted '(nil t))
    (dolist (result '((:false nil) (t "handled")))
      (pilish-test-with-rpc-session (chat input proc commands)
        (with-current-buffer input
          (insert "Draft with image")
          (goto-char 4)
          (setq pilish--draft-prompt-image '(:data "image" :mimeType "image/png"))
          (pilish--history-add "Old prompt"))
        (let ((before (pilish-test--submission-draft-state input)))
          (pilish-submit-prompt chat "API A" #'ignore)
          (let ((a (car commands)))
            (pilish-submit-prompt chat "API B" #'ignore)
            (let ((b (car commands))
                  (wait (car (buffer-local-value 'pilish--prompt-waits chat))))
              (when accepted (pilish-test--api-response proc b t "queued"))
              (pilish-test--api-response proc a (car result) (cadr result))
              (with-current-buffer chat
                (should (equal pilish--prompt-waits (list wait)))
                (should (pilish--session-busy-p))
                (should (eq pilish--status 'sending)))
              (with-current-buffer input (pilish-send))
              (should (= 2 (length commands)))
              (should (equal before (pilish-test--submission-draft-state input)))
              (unless accepted (pilish-test--api-response proc b :false))
              (with-current-buffer chat
                (if accepted
                    (should (pilish--prompt-start-current-p wait))
                  (should-not pilish--prompt-waits)
                  (should (eq pilish--status 'idle)))))))))))

(ert-deftest pilish-test-submit-prompt-preserves-interactive-owner ()
  "API cleanup never acquires the interactive echo, image or FIFO ownership."
  (pilish-test-with-rpc-session (chat input proc commands)
    (with-current-buffer input (insert "Interactive request") (pilish-send))
    (let ((interactive (car commands))
          (owner (buffer-local-value 'pilish--prompt-wait chat)))
      (with-current-buffer input
        (insert "New draft")
        (setq pilish--draft-prompt-image '(:data "image" :mimeType "image/png")))
      (let ((before (pilish-test--submission-draft-state input)))
        (with-current-buffer chat (pilish--push-followup "local successor"))
        (pilish-submit-prompt chat "API A" #'ignore)
        (let ((api (car commands)))
          (pilish-test--api-response proc api :false)
          (with-current-buffer chat
            (should (eq pilish--prompt-wait owner))
            (should (equal pilish--prompt-waits (list owner)))
            (should (equal pilish--followup-queue '("local successor"))))
          (pilish-test--api-response proc interactive t "started")
          ;; Concurrency makes an arbitrary echo/start attribution unsafe.
          (with-current-buffer chat
            (should-not pilish--local-user-message)
            (should (eq pilish--prompt-wait owner)))
          (should (equal before (pilish-test--submission-draft-state input))))))))

(ert-deftest pilish-test-submit-prompt-stale-probe-keeps-new-work ()
  "A new API request or lifecycle event invalidates an in-flight idle probe."
  (dolist (change '(new-request run-before-ack))
    (pilish-test-with-rpc-session (chat input proc commands)
      (pilish-submit-prompt chat "API A" #'ignore)
      (let ((a (car commands))
            (wait (car (buffer-local-value 'pilish--prompt-waits chat))))
        (pilish-test--api-response proc a t "queued")
        (pilish--clear-sending-if-no-agent-start chat wait)
        (let ((probe (car commands)))
          (if (eq change 'new-request)
              (pilish-submit-prompt chat "API B" #'ignore)
            (pilish-test--stdout proc '(:type "agent_start")
                                 '(:type "agent_end" :messages [])
                                 '(:type "agent_settled")))
          (pilish--dispatch-response
           proc (list :type "response" :id (plist-get probe :id) :success t
                      :data '(:isStreaming :false :isCompacting :false
                              :pendingMessageCount 0)))
          (with-current-buffer chat
            (should (pilish--prompt-start-current-p wait))
            (should (pilish--session-busy-p))
            (should-not (pilish--prompt-wait-started wait))))))))

(ert-deftest pilish-test-submit-prompt-run-before-ack-and-stale-process ()
  "Late API responses neither attribute another run nor clear a replacement."
  (pilish-test-with-rpc-session (chat input proc commands)
    (let (seen)
      (pilish-submit-prompt chat "API A" (lambda (r) (push r seen)))
      (let ((a (car commands))
            (wait (car (buffer-local-value 'pilish--prompt-waits chat))))
        (pilish-test--stdout proc '(:type "agent_start")
                             '(:type "agent_end" :messages [])
                             '(:type "agent_settled"))
        (pilish-test--api-response proc a t "started")
        (with-current-buffer chat
          (should (pilish--prompt-start-current-p wait))
          (should-not (pilish--prompt-wait-started wait)))
        (pilish--clear-sending-if-no-agent-start chat wait)
        (let ((probe (car commands)))
          (pilish-submit-prompt chat "API B" (lambda (r) (push r seen)))
          (let ((b (car commands))
              (replacement (make-pipe-process :name "pilish-api-replacement" :noquery t)))
          (unwind-protect
              (progn
                (with-current-buffer chat
                  (pilish--invalidate-prompt-start-wait)
                  (pilish--set-process replacement))
                (pilish-submit-prompt chat "New owner" #'ignore)
                (let ((new-wait (car (buffer-local-value 'pilish--prompt-waits chat))))
                  (pilish-test--api-response proc b :false)
                  (pilish--dispatch-response
                   proc (list :type "response" :id (plist-get probe :id) :success t
                              :data '(:isStreaming :false :isCompacting :false)))
                  (with-current-buffer chat
                    (should (equal pilish--prompt-waits (list new-wait)))
                    (should (eq pilish--status 'sending)))
                  (should (= 2 (length seen)))))
            (delete-process replacement))))))))

(ert-deftest pilish-test-submit-prompt-error-and-quit-release-only-owned-request ()
  "Scheduling errors/quits clean the failed request, not another pending API."
  (dolist (failure '(error quit))
    (pilish-test-with-rpc-session (chat input proc commands)
      (pilish-submit-prompt chat "API A" #'ignore)
      (let ((wait (car (buffer-local-value 'pilish--prompt-waits chat))) called)
        (with-current-buffer input (insert "Protected draft"))
        (let ((before (pilish-test--submission-draft-state input)))
          (cl-letf (((symbol-function 'pilish--send-string)
                     (lambda (&rest _) (signal failure '("Scheduling failed")))))
            (should (eq (condition-case err
                            (progn (pilish-submit-prompt
                                    chat "API B" (lambda (_) (setq called t))) nil)
                          ((error quit) (car err)))
                        failure)))
          (should-not called)
          (should (= 1 (hash-table-count (pilish--get-pending-requests proc))))
          (with-current-buffer chat
            (should (equal pilish--prompt-waits (list wait)))
            (should (eq pilish--status 'sending)))
          (should (equal before (pilish-test--submission-draft-state input))))))))

(ert-deftest pilish-test-submit-prompt-callback-reentrancy-and-errors ()
  "Cleanup precedes a reentrant callback, even when that observer then fails."
  (dolist (failure '(nil error quit))
    (pilish-test-with-rpc-session (chat input proc commands)
      (let (new-wait (calls 0))
        (pilish-submit-prompt
         chat "Handled" (lambda (_)
                          (cl-incf calls)
                          (with-current-buffer chat
                            (should-not pilish--prompt-waits)
                            (should (eq pilish--status 'idle)))
                          (pilish-submit-prompt chat "Reentrant API" #'ignore)
                          (setq new-wait
                                (car (buffer-local-value 'pilish--prompt-waits chat)))
                          (when failure (signal failure '("Observer failed")))))
        (let ((request (car commands)))
          (should (eq (condition-case err
                          (progn (pilish-test--api-response proc request t "handled") nil)
                        ((error quit) (car err)))
                      failure))
          (pilish-test--api-response proc request t "handled")
          (should (= calls 1))
          (with-current-buffer chat
            (should (equal pilish--prompt-waits (list new-wait)))
            (should (eq pilish--status 'sending)))
          (should (= 1 (hash-table-count (pilish--get-pending-requests proc)))))))))

(ert-deftest pilish-test-submit-prompt-keeps-attachment-editor-available ()
  "API ownership does not prevent the user from changing their draft image."
  (pilish-test-with-rpc-session (chat input _proc _commands)
    (pilish-submit-prompt chat "API A" #'ignore)
    (with-current-buffer input
      (insert "Draft")
      (setq pilish--draft-prompt-image '(:data "image" :mimeType "image/png"))
      (pilish-attach-image t)
      (should-not pilish--draft-prompt-image)
      (should (equal (buffer-string) "Draft")))))

(ert-deftest pilish-test-submit-prompt-scheduling-failure-releases-user-fifo ()
  "A reentrant user send remains queued until failed API scheduling releases it."
  (pilish-test-with-rpc-session (chat input proc commands)
    (let ((send (symbol-function 'pilish--send-string)) (first t))
      (cl-letf (((symbol-function 'pilish--send-string)
                 (lambda (process line)
                   (if first
                       (progn
                         (setq first nil)
                         (with-current-buffer input
                           (insert "User successor")
                           (pilish-send)
                           (insert "New draft"))
                         (error "Scheduling failed"))
                     (funcall send process line)))))
        (should-error (pilish-submit-prompt chat "Failed API" #'ignore)))
      (should (= 1 (length commands)))
      (should (equal (plist-get (car commands) :message) "User successor"))
      (with-current-buffer input (should (equal (buffer-string) "New draft")))
      (with-current-buffer chat
        (should pilish--prompt-wait)
        (should (equal pilish--prompt-waits (list pilish--prompt-wait))))
      (should (= 1 (hash-table-count (pilish--get-pending-requests proc)))))))

(ert-deftest pilish-test-submit-prompt-does-not-reopen-completed-interactive-run ()
  "A rejected API cannot leave a completed but unacknowledged user run sending."
  (pilish-test-with-rpc-session (chat input proc commands)
    (with-current-buffer input (insert "User request") (pilish-send))
    (let ((request (car commands)))
      (pilish-test--stdout proc '(:type "agent_start")
                           '(:type "agent_end" :messages [])
                           '(:type "agent_settled"))
      (pilish-submit-prompt chat "Rejected API" #'ignore)
      (pilish-test--api-response proc (car commands) :false)
      (pilish-test--api-response proc request t "started")
      (with-current-buffer chat
        (should-not pilish--prompt-waits)
        (should (eq pilish--status 'idle))
        (should-not (pilish--session-busy-p))))))

(ert-deftest pilish-test-submit-prompt-synchronous-callback-error-keeps-acceptance ()
  "A callback error delivered during scheduling is not a scheduling failure."
  (pilish-test-with-rpc-session (chat _input proc _commands)
    (cl-letf (((symbol-function 'pilish--send-string)
               (lambda (_ line)
                 (pilish-test--api-response
                  proc (pilish--parse-json-line line) t "queued"))))
      (should-error
       (pilish-submit-prompt chat "API A" (lambda (_) (error "Observer failed")))))
    (with-current-buffer chat
      (should (= 1 (length pilish--prompt-waits)))
      (should (pilish--prompt-wait-accepted (car pilish--prompt-waits)))
      (should (pilish--session-busy-p)))))

(ert-deftest pilish-test-submit-prompt-exit-settles-every-callback-once ()
  "Exit settles every request once even when one API callback raises an error/quit.
Callback failures are reported, not propagated (`pilish--call-process-hook')."
  (dolist (failure '(nil error quit))
    (pilish-test-with-rpc-session (chat input proc commands)
      (let (seen reported)
        (with-current-buffer input
          (insert "Protected exit draft")
          (setq pilish--draft-prompt-image '(:data "image" :mimeType "image/png")))
        (let ((before (pilish-test--submission-draft-state input)))
          (pilish-submit-prompt chat "API A" (lambda (r) (push r seen)))
          (pilish-submit-prompt chat "API B"
                                (lambda (r) (push r seen)
                                  (when failure (signal failure '("Observer failed")))))
          ;; The fixture has no sentinel; exercise real exit cleanup explicitly.
          (delete-process proc)
          (cl-letf (((symbol-function 'message)
                     (lambda (fmt &rest args) (push (apply #'format fmt args) reported))))
            (pilish--handle-process-exit proc "closed\n"))
          (should (eq (and (seq-some (lambda (text)
                                       (string-match-p "process handler failed" text))
                                     reported)
                           t)
                      (and failure t)))
          (should (= 2 (length seen)))
          (should (cl-every (lambda (r) (plist-get r :processExit)) seen))
          (pilish--handle-process-exit proc "closed\n")
          (should (= 2 (length seen)))
          (should (= 0 (hash-table-count (pilish--get-pending-requests proc))))
          (should (= 0 (hash-table-count (pilish--get-pending-command-types proc))))
          (with-current-buffer chat
            (should-not pilish--prompt-waits)
            (should-not pilish--prompt-start-timer)
            (should (eq pilish--status 'idle)))
          (should (equal before (pilish-test--submission-draft-state input))))))))

(ert-deftest pilish-test-submit-prompt-probe-does-not-skip-observed-settlement ()
  "An idle get_state cannot replace agent_settled after an observed run."
  (pilish-test-with-rpc-session (chat input proc commands)
    (pilish-submit-prompt chat "API A" #'ignore)
    (let ((wait (car (buffer-local-value 'pilish--prompt-waits chat))))
      (pilish-test--api-response proc (car commands) t "started")
      (with-current-buffer input (insert "Local successor") (pilish-send))
      (pilish-test--stdout proc '(:type "agent_start")
                           '(:type "agent_end" :messages []))
      (pilish--clear-sending-if-no-agent-start
       chat wait (pilish--prompt-wait-on-no-agent-start wait))
      (should (= 1 (length commands)))
      (with-current-buffer chat
        (should (eq pilish--status 'sending))
        (should-not (pilish--session-steerable-p))
        (should (pilish--prompt-start-current-p wait)))
      (pilish-test--stdout proc '(:type "agent_settled"))
      (pilish--clear-sending-if-no-agent-start
       chat wait (pilish--prompt-wait-on-no-agent-start wait))
      (let ((probe (car commands)))
        (should (equal (plist-get probe :type) "get_state"))
        (pilish--dispatch-response
         proc (list :type "response" :id (plist-get probe :id) :success t
                    :data '(:isStreaming :false :isCompacting :false
                            :pendingMessageCount 0))))
      (should (equal (plist-get (car commands) :message) "Local successor")))))

(ert-deftest pilish-test-submit-prompt-cleanup-distinguishes-preflight-and-run-work ()
  "Rejection/handled ends local preflight, not observed run/retry settlement."
  (dolist (result '((:false nil) (t "handled")))
    (dolist (stage '(preflight-compaction observed-end observed-retry))
      (pilish-test-with-rpc-session (chat input proc commands)
        (with-current-buffer input (insert "Protected draft"))
        (pcase stage
          ('observed-end
           (pilish-test--stdout proc '(:type "agent_start")
                                '(:type "agent_end" :messages [])))
          ('observed-retry
           (pilish-test--stdout proc '(:type "auto_retry_start" :attempt 1
                                      :errorMessage "Retrying"))))
        (pilish-submit-prompt chat "API A" #'ignore)
        (let ((request (car commands))
              (before (pilish-test--submission-draft-state input)))
          (when (eq stage 'preflight-compaction)
            (pilish-test--stdout proc '(:type "compaction_start" :reason "auto")))
          (pilish-test--api-response proc request (car result) (cadr result))
          (with-current-buffer chat
            (should-not pilish--prompt-waits)
            (should (eq pilish--status
                        (if (eq stage 'preflight-compaction) 'compacting 'sending))))
          (when (eq stage 'preflight-compaction)
            (pilish-test--stdout
             proc '(:type "compaction_end" :reason "auto" :aborted :false
                    :result (:tokensBefore 100 :summary "Summary")))
            (with-current-buffer chat (should (eq pilish--status 'idle))))
          (should (equal before (pilish-test--submission-draft-state input))))))))

(ert-deftest pilish-test-submit-prompt-exit-preserves-callback-and-cleanup-errors ()
  "Every request and stderr resource settles; every exit failure stays visible.
Callback failures are reported and the exit handler's error propagates."
  (pilish-test-with-rpc-session (chat _input proc _commands)
    (let ((stderr (generate-new-buffer " *pilish-api-exit-stderr*"))
          reported)
      (process-put proc 'pilish-stderr-buf stderr)
      (process-put proc 'pilish-exit-handler
                   (lambda (_) (error "Exit observer failed")))
      (pilish-submit-prompt chat "API A" (lambda (_) (error "Callback A failed")))
      (pilish-submit-prompt chat "API B" (lambda (_) (error "Callback B failed")))
      (delete-process proc)
      (let ((err (cl-letf (((symbol-function 'message)
                            (lambda (fmt &rest args)
                              (push (apply #'format fmt args) reported))))
                   (should-error (pilish--handle-process-exit proc "closed\n")))))
        (should (string-match-p "Exit observer failed" (error-message-string err))))
      (dolist (text '("Callback A failed" "Callback B failed"))
        (should (seq-some (lambda (line) (string-match-p text line)) reported)))
      (should-not (buffer-live-p stderr))
      (should-not (process-get proc 'pilish-stderr-buf))
      (should (= 0 (hash-table-count (pilish--get-pending-requests proc))))
      (with-current-buffer chat (should-not pilish--prompt-waits)))))

(ert-deftest pilish-test-submit-prompt-ambiguous-interactive-handled-awaits-settlement ()
  "A late handled response cannot release an ambiguously observed run early."
  (pilish-test-with-rpc-session (chat input proc commands)
    (with-current-buffer input (insert "User request") (pilish-send))
    (let ((interactive (car commands))
          (wait (buffer-local-value 'pilish--prompt-wait chat)))
      (pilish-submit-prompt chat "API A" #'ignore)
      (let ((api (car commands)))
        (pilish-test--stdout proc '(:type "agent_start")
                             '(:type "agent_end" :messages []))
        (with-current-buffer input (insert "Successor") (pilish-send))
        (pilish-test--api-response proc api :false)
        (pilish-test--api-response proc interactive t "handled")
        (should (= 2 (length commands)))
        (with-current-buffer chat
          (should (eq pilish--status 'sending))
          (should (eq pilish--prompt-wait wait)))
        (pilish-test--stdout proc '(:type "agent_settled"))
        (pilish--clear-sending-if-no-agent-start
         chat wait (pilish--prompt-wait-on-no-agent-start wait))
        (let ((probe (car commands)))
          (should (equal (plist-get probe :type) "get_state"))
          (pilish--dispatch-response
           proc (list :type "response" :id (plist-get probe :id) :success t
                      :data '(:isStreaming :false :isCompacting :false
                              :pendingMessageCount 0))))
        (should (equal (plist-get (car commands) :message) "Successor"))))))

(ert-deftest pilish-test-submit-prompt-exit-preserves-interactive-restoration ()
  "API exit callbacks leave interactive draft restoration to its own owner."
  (pilish-test-with-rpc-session (chat input proc commands)
    (with-current-buffer input (insert "Interactive text") (pilish-send))
    (pilish-submit-prompt chat "API A" #'ignore)
    (pilish-submit-prompt chat "API B" #'ignore)
    (with-current-buffer input (insert "Newer draft"))
    ;; Even if an API observer runs first it can release only its own record.
    (let ((request (car commands)))
      (pilish--dispatch-response
       proc (list :type "response" :id (plist-get request :id)
                  :success :false :processExit t :error "closed")))
    (delete-process proc)
    (pilish--handle-process-exit proc "closed\n")
    (with-current-buffer input
      (should (string-match-p "Interactive text" (buffer-string)))
      (should (string-match-p "Newer draft" (buffer-string)))
      (should-not (string-match-p "API [AB]" (buffer-string))))
    (with-current-buffer chat
      (should-not pilish--prompt-waits)
      (should-not pilish--prompt-wait)
      (should-not pilish--prompt-start-timer))))

;;; DWIM & Toggle

(ert-deftest pilish-test-dwim-reuses-existing-session ()
  "Calling `pilish' from a non-pi buffer reuses the existing session."
  (pilish-test-with-mock-session "/tmp/pilish-test-dwim/"
    ;; Session exists; now call from a non-pi buffer in the same project
    (with-temp-buffer
      (setq default-directory "/tmp/pilish-test-dwim/")
      (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
                ((symbol-function 'pilish--display-buffers) #'ignore))
        (pilish))
      ;; Should not have created a second chat buffer
      (should (= 1 (length (cl-remove-if-not
                             (lambda (b)
                               (string-prefix-p "*pilish-chat:/tmp/pilish-test-dwim/"
                                                (buffer-name b)))
                             (buffer-list))))))))

(ert-deftest pilish-test-dwim-reuses-saved-chat-buffer-after-write-file ()
  "A saved chat buffer is still reused as the project session."
  (let ((root (pilish-test--make-temp-directory
               "pilish-test-dwim-write-file-"))
        (file nil)
        (chat nil)
        (input nil)
        (make-backup-files nil))
    (unwind-protect
        (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
                  ((symbol-function 'pilish--start-process) (lambda (&rest _) nil))
                  ((symbol-function 'pilish--display-buffers) #'ignore)
                  ((symbol-function 'pilish--check-dependencies) #'ignore))
          (setq chat (pilish--setup-session root nil)
                input (buffer-local-value 'pilish--input-buffer chat)
                file (pilish-test--write-chat-buffer
                      chat "pilish-chat-dwim-" "Saved copy\n"))
          (with-temp-buffer
            (setq default-directory root)
            (pilish))
          (should (eq (pilish--find-session root) chat))
          (should (eq (buffer-local-value 'pilish--input-buffer chat)
                      input))
          (with-current-buffer chat
            (should (equal (pilish--chat-session-buffer-name)
                           (pilish-test--chat-buffer-name root)))
            (should (equal (pilish--session-directory) root))
            (should (equal buffer-file-name file))))
      (pilish-test--kill-live-buffers input chat)
      (ignore-errors (delete-file file))
      (ignore-errors (delete-directory root t)))))

(ert-deftest pilish-test-setup-session-ignores-stale-state-after-switch ()
  "Startup state cannot overwrite a newer session on the same process."
  (pilish-test-with-rpc-session (chat input proc commands)
    (let ((name "stale-state-startup"))
      (with-current-buffer chat
        (pilish--set-chat-session-identity "/tmp/" name)
        (setq pilish--process nil))
      (with-current-buffer input
        (rename-buffer (pilish--buffer-name :input "/tmp/" name)))
      (cl-letf (((symbol-function 'pilish--check-dependencies) #'ignore)
                ((symbol-function 'pilish--start-process) (lambda (&rest _) proc))
                ((symbol-function 'pilish--fetch-commands) #'ignore))
        (should (eq (pilish--setup-session "/tmp/" name) chat)))
      (let ((startup-request (car commands)))
        (should (equal (plist-get startup-request :type) "get_state"))
        ;; Complete the newer transition's authoritative refresh first.  The
        ;; startup reply still has a valid RPC id and the same live process.
        (pilish--refresh-session-state proc chat)
        (pilish--dispatch-response
         proc (list :type "response" :command "get_state"
                    :id (plist-get (car commands) :id) :success t
                    :data '(:sessionFile "/tmp/switched.jsonl"
                            :thinkingLevel "high" :isStreaming :false)))
        (should-not (pilish--session-transition-active-p chat))
        (pilish--dispatch-response
         proc (list :type "response" :command "get_state"
                    :id (plist-get startup-request :id) :success t
                    :data '(:sessionFile "/tmp/startup-old.jsonl"
                            :thinkingLevel "low" :isStreaming t)))
        (with-current-buffer chat
          (should (equal (plist-get pilish--state :session-file)
                         "/tmp/switched.jsonl"))
          (should (equal (plist-get pilish--state :thinking-level) "high"))
          (should (eq pilish--status 'idle)))
        (should (= (hash-table-count
                    (process-get proc 'pilish-pending-requests)) 0))))))

(ert-deftest pilish-test-setup-session-shows-startup-error-from-initial-state-request ()
  "Initial startup failure should be rendered into the chat buffer."
  (let ((root (pilish-test--make-temp-directory
               "pilish-test-startup-error-"))
        (proc (start-process "pilish-startup-error" nil "cat"))
        (chat nil))
    (unwind-protect
        (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
                  ((symbol-function 'pilish--start-process) (lambda (&rest _) proc))
                  ((symbol-function 'pilish--fetch-commands) (lambda (&rest _) nil))
                  ((symbol-function 'pilish--rpc-async)
                   (lambda (_proc cmd callback)
                     (should (equal (plist-get cmd :type) "get_state"))
                     (funcall callback
                              '(:type "response"
                                :command "get_state"
                                :success :false
                                :error "Process exited: exited abnormally with code 1"
                                :stderr "InvalidArgumentError: Invalid URL protocol")))))
          (setq chat (pilish--setup-session root nil))
          (should (buffer-live-p chat))
          (with-current-buffer chat
            (should (string-match-p "failed to start" (buffer-string)))
            (should (string-match-p "Invalid URL protocol" (buffer-string)))))
      (when (process-live-p proc)
        (delete-process proc))
      (pilish-test--kill-session-buffers root))))

(ert-deftest pilish-test-setup-session-ignores-stale-startup-error ()
  "A replaced startup process must not render into the newer process chat."
  (let ((root (pilish-test--make-temp-directory
               "pilish-test-stale-startup-error-"))
        (old-proc (start-process "pilish-old-startup" nil "cat"))
        (new-proc (start-process "pilish-new-startup" nil "cat"))
        (state-callback nil)
        (chat nil))
    (unwind-protect
        (progn
          (set-process-query-on-exit-flag old-proc nil)
          (set-process-query-on-exit-flag new-proc nil)
          (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
                    ((symbol-function 'pilish--start-process)
                     (lambda (&rest _) old-proc))
                    ((symbol-function 'pilish--fetch-commands)
                     (lambda (&rest _) nil))
                    ((symbol-function 'pilish--rpc-async)
                     (lambda (proc cmd callback)
                       (should (eq proc old-proc))
                       (should (equal (plist-get cmd :type) "get_state"))
                       (setq state-callback callback))))
            (setq chat (pilish--setup-session root nil)))
          (should state-callback)
          (with-current-buffer chat
            (pilish--set-process new-proc))
          (delete-process old-proc)
          (funcall state-callback
                   '(:type "response"
                     :command "get_state"
                     :success :false
                     :processExit t
                     :error "Process exited: old startup failed"
                     :stderr "OLD-STARTUP-STDERR"
                     :exitCode 1))
          (with-current-buffer chat
            (should (eq pilish--process new-proc))
            (should-not (string-match-p "OLD-STARTUP-STDERR"
                                        (buffer-string)))
            (should-not (string-match-p "pi failed to start"
                                        (buffer-string))))
          (should-not (process-get old-proc
                                   'pilish-exit-error-rendered)))
      (pilish-test--kill-session-buffers root)
      (pilish--unregister-display-handler old-proc)
      (when (process-live-p old-proc)
        (delete-process old-proc))
      (when (process-live-p new-proc)
        (delete-process new-proc)))))

(ert-deftest pilish-test-setup-session-deduplicates-dead-startup-exit ()
  "A dead initial get_state process renders its stderr only once."
  (let ((root (pilish-test--make-temp-directory
               "pilish-test-startup-exit-dedup-"))
        (proc (start-process "pilish-startup-exit-dedup" nil
                             "sh" "-c" "exit 1"))
        (response '(:type "response"
                    :command "get_state"
                    :success :false
                    :processExit t
                    :error "Process exited: exited abnormally with code 1"
                    :stderr "ECOMPROMISED: lock was compromised"
                    :exitCode 1))
        (chat nil))
    (unwind-protect
        (progn
          (set-process-sentinel proc nil)
          (set-process-query-on-exit-flag proc nil)
          (should (pilish-test-wait-for-process-exit proc))
          (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
                    ((symbol-function 'pilish--start-process)
                     (lambda (&rest _) proc))
                    ((symbol-function 'pilish--fetch-commands)
                     (lambda (&rest _) nil))
                    ((symbol-function 'pilish--rpc-async)
                     (lambda (rpc-proc cmd callback)
                       (should (eq rpc-proc proc))
                       (should (equal (plist-get cmd :type) "get_state"))
                       ;; Core dispatches pending callbacks before the exit
                       ;; handler, so reproduce that order here.
                       (funcall callback response)
                       (funcall (process-get proc
                                            'pilish-exit-handler)
                                response))))
            (setq chat (pilish--setup-session root nil)))
          (should (process-get proc
                               'pilish-exit-error-rendered))
          (with-current-buffer chat
            (let ((chat-text (buffer-string)))
              (should (= (pilish-test--count-matches
                          "ECOMPROMISED" chat-text)
                         1))
              (should (= (pilish-test--count-matches
                          "pi failed to start" chat-text)
                         1))
              (should-not (string-match-p "pi process exited" chat-text)))))
      (when (process-live-p proc)
        (delete-process proc))
      (pilish-test--kill-session-buffers root))))

(ert-deftest pilish-test-setup-session-shows-startup-env-node-hint ()
  "Initial env/node startup failures should explain subprocess PATH."
  (let ((root (pilish-test--make-temp-directory
               "pilish-test-startup-env-node-"))
        (proc (start-process "pilish-startup-env-node" nil "cat"))
        (chat nil))
    (unwind-protect
        (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
                  ((symbol-function 'pilish--start-process) (lambda (&rest _) proc))
                  ((symbol-function 'pilish--fetch-commands) (lambda (&rest _) nil))
                  ((symbol-function 'pilish--rpc-async)
                   (lambda (_proc cmd callback)
                     (should (equal (plist-get cmd :type) "get_state"))
                     (funcall callback
                              '(:type "response"
                                :command "get_state"
                                :success :false
                                :error "Process exited: exited abnormally with code 127"
                                :stderr "/usr/bin/env: node: No such file or directory"
                                :exitCode 127)))))
          (setq chat (pilish--setup-session root nil))
          (should (buffer-live-p chat))
          (with-current-buffer chat
            (should (string-match-p "failed to start" (buffer-string)))
            (should (string-match-p "Node launcher" (buffer-string)))
            (should (string-match-p "subprocess PATH" (buffer-string)))))
      (when (process-live-p proc)
        (delete-process proc))
      (pilish-test--kill-session-buffers root))))

(ert-deftest pilish-test-from-chat-buffer-noop-when-both-visible ()
  "From chat, `pilish' avoids redisplay and focuses input."
  (let ((root "/tmp/pilish-test-chat-visible/")
        (display-called nil))
    (make-directory root t)
    (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
              ((symbol-function 'pilish--start-process) (lambda (&rest _) nil)))
      (unwind-protect
          (progn
            (delete-other-windows)
            (switch-to-buffer "*scratch*")
            (setq default-directory root)
            (pilish)
            (let ((chat (get-buffer (pilish-test--chat-buffer-name root)))
                  (input (get-buffer (pilish-test--input-buffer-name root))))
              (select-window (car (get-buffer-window-list chat nil t)))
              (with-current-buffer chat
                (cl-letf (((symbol-function 'pilish--display-buffers)
                           (lambda (&rest _)
                             (setq display-called t))))
                  (pilish)))
              (should-not display-called)
              (should (get-buffer-window-list chat nil t))
              (should (get-buffer-window-list input nil t))
              (should (eq (window-buffer (selected-window)) input))))
        (pilish-test--kill-session-buffers root)
        (delete-other-windows)))))

(ert-deftest pilish-test-from-input-buffer-noop-when-both-visible ()
  "From input, `pilish' avoids redisplay when both panes are visible."
  (let ((root "/tmp/pilish-test-input-visible/")
        (display-called nil))
    (make-directory root t)
    (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
              ((symbol-function 'pilish--start-process) (lambda (&rest _) nil)))
      (unwind-protect
          (progn
            (delete-other-windows)
            (switch-to-buffer "*scratch*")
            (setq default-directory root)
            (pilish)
            (let ((chat (get-buffer (pilish-test--chat-buffer-name root)))
                  (input (get-buffer (pilish-test--input-buffer-name root))))
              (with-current-buffer input
                (cl-letf (((symbol-function 'pilish--display-buffers)
                           (lambda (&rest _)
                             (setq display-called t))))
                  (pilish)))
              (should-not display-called)
              (should (get-buffer-window-list chat nil t))
              (should (get-buffer-window-list input nil t))))
        (pilish-test--kill-session-buffers root)
        (delete-other-windows)))))

(ert-deftest pilish-test-from-chat-buffer-focuses-current-session-input ()
  "With multiple sessions visible, `pilish' focuses this session's input."
  (let ((root "/tmp/pilish-test-focus-root/")
        (sub "/tmp/pilish-test-focus-root/somesubdir/")
        (display-called nil))
    (make-directory root t)
    (make-directory sub t)
    (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
              ((symbol-function 'pilish--start-process) (lambda (&rest _) nil)))
      (unwind-protect
          (progn
            (with-temp-buffer
              (setq default-directory root)
              (pilish))
            (with-temp-buffer
              (setq default-directory sub)
              (pilish))
            (let ((root-chat (get-buffer (pilish-test--chat-buffer-name root)))
                  (root-input (get-buffer (pilish-test--input-buffer-name root)))
                  (sub-input (get-buffer (pilish-test--input-buffer-name sub))))
              (delete-other-windows)
              (switch-to-buffer root-chat)
              (let ((root-input-win (split-window nil -10 'below)))
                (set-window-buffer root-input-win root-input))
              (let ((sub-win (split-window-right)))
                (set-window-buffer sub-win sub-input))
              (select-window (get-buffer-window root-chat))
              (with-current-buffer root-chat
                (cl-letf (((symbol-function 'pilish--display-buffers)
                           (lambda (&rest _)
                             (setq display-called t))))
                  (pilish)))
              (should-not display-called)
              (should (eq (window-buffer (selected-window)) root-input))))
        (pilish-test--kill-session-buffers root)
        (pilish-test--kill-session-buffers sub)
        (delete-other-windows)))))

(ert-deftest pilish-test-from-pi-buffer-redisplays-when-visible-only-in-other-frame ()
  "Calling `pilish' should redisplay in current frame.
Even if chat/input are visible in another frame, current-frame visibility
must decide whether this is a no-op."
  (let ((root "/tmp/pilish-test-other-frame-noop/")
        (display-called nil))
    (make-directory root t)
    (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
              ((symbol-function 'pilish--start-process) (lambda (&rest _) nil)))
      (unwind-protect
          (progn
            (delete-other-windows)
            (switch-to-buffer "*scratch*")
            (setq default-directory root)
            (pilish)
            (let ((chat (get-buffer (pilish-test--chat-buffer-name root))))
              (with-current-buffer chat
                (cl-letf (((symbol-function 'get-buffer-window-list)
                           (lambda (_buffer _minibuf &optional all-frames)
                             (if all-frames '(foreign-window) nil)))
                          ((symbol-function 'pilish--display-buffers)
                           (lambda (&rest _)
                             (setq display-called t))))
                  (pilish)))
              (should display-called)))
        (pilish-test--kill-session-buffers root)
        (delete-other-windows)))))

(ert-deftest pilish-test-from-chat-buffer-restores-missing-input-window ()
  "Calling `pilish' from chat restores input and focuses it."
  (let ((root "/tmp/pilish-test-chat-restore/"))
    (make-directory root t)
    (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
              ((symbol-function 'pilish--start-process) (lambda (&rest _) nil)))
      (unwind-protect
          (progn
            (delete-other-windows)
            (switch-to-buffer "*scratch*")
            (setq default-directory root)
            (pilish)
            (let ((chat (get-buffer (pilish-test--chat-buffer-name root)))
                  (input (get-buffer (pilish-test--input-buffer-name root))))
              (delete-window (car (get-buffer-window-list input nil t)))
              (with-current-buffer chat
                (pilish))
              (should (= 1 (length (get-buffer-window-list input nil t))))
              (should (eq (window-buffer (selected-window)) input))))
        (pilish-test--kill-session-buffers root)
        (delete-other-windows)))))

(ert-deftest pilish-test-from-input-buffer-restores-missing-chat-window ()
  "Calling `pilish' from input restores the split layout."
  (let ((root "/tmp/pilish-test-input-restore/"))
    (make-directory root t)
    (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
              ((symbol-function 'pilish--start-process) (lambda (&rest _) nil)))
      (unwind-protect
          (progn
            (delete-other-windows)
            (switch-to-buffer "*scratch*")
            (setq default-directory root)
            (pilish)
            (let ((chat (get-buffer (pilish-test--chat-buffer-name root)))
                  (input (get-buffer (pilish-test--input-buffer-name root))))
              (let ((input-win (car (get-buffer-window-list input nil t))))
                (select-window input-win)
                (delete-other-windows input-win))
              (with-current-buffer input
                (pilish))
              (should (= 1 (length (get-buffer-window-list chat nil t))))
              (should (= 1 (length (get-buffer-window-list input nil t))))))
        (pilish-test--kill-session-buffers root)
        (delete-other-windows)))))

(ert-deftest pilish-test-non-pi-call-creates-default-session-when-only-named-exists ()
  "Calling `pilish' creates default session when only named one exists."
  (let* ((root "/tmp/pilish-test-dwim-named/")
         (default-directory root)
         (displayed nil)
         (named-chat (pilish-test--chat-buffer-name root "my-feature"))
         (named-input (pilish-test--input-buffer-name root "my-feature"))
         (default-chat (pilish-test--chat-buffer-name root))
         (default-input (pilish-test--input-buffer-name root)))
    (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
              ((symbol-function 'pilish--start-process) (lambda (&rest _) nil))
              ((symbol-function 'pilish--display-buffers)
               (lambda (chat _input &rest _) (setq displayed chat))))
      (unwind-protect
          (progn
            ;; Create named session first.
            (pilish "my-feature")
            ;; Non-pi call should create/reuse default unnamed session.
            (with-temp-buffer
              (setq default-directory root)
              (setq displayed nil)
              (pilish)
              (should displayed)
              (should (equal (buffer-name displayed) default-chat)))
            (should (get-buffer named-chat))
            (should (get-buffer named-input))
            (should (get-buffer default-chat))
            (should (get-buffer default-input)))
        (pilish-test--kill-session-buffers root "my-feature")
        (pilish-test--kill-session-buffers root)))))

(ert-deftest pilish-test-named-session-reuses-saved-chat-buffer-after-write-file ()
  "Saving a named session keeps it distinct from the default session."
  (let ((root (pilish-test--make-temp-directory
               "pilish-test-named-write-file-"))
        (file nil)
        (default-chat nil)
        (default-input nil)
        (named-chat nil)
        (named-input nil)
        (make-backup-files nil))
    (unwind-protect
        (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
                  ((symbol-function 'pilish--start-process) (lambda (&rest _) nil))
                  ((symbol-function 'pilish--display-buffers) #'ignore)
                  ((symbol-function 'pilish--check-dependencies) #'ignore))
          (setq default-chat (pilish--setup-session root nil)
                default-input (buffer-local-value 'pilish--input-buffer default-chat)
                named-chat (pilish--setup-session root "feature")
                named-input (buffer-local-value 'pilish--input-buffer named-chat)
                file (pilish-test--write-chat-buffer
                      named-chat "pilish-chat-named-"
                      "Named session archive\n"))
          (with-temp-buffer
            (setq default-directory root)
            (pilish "feature"))
          (should (eq (pilish--find-session root) default-chat))
          (should (eq (pilish--find-session root "feature") named-chat))
          (should-not (eq default-chat named-chat))
          (with-current-buffer named-chat
            (should (equal (pilish--chat-session-buffer-name)
                           (pilish-test--chat-buffer-name root "feature")))
            (should (equal (pilish--session-directory) root))
            (should (equal buffer-file-name file))))
      (pilish-test--kill-live-buffers
       named-input named-chat default-input default-chat)
      (ignore-errors (delete-file file))
      (ignore-errors (delete-directory root t)))))

(ert-deftest pilish-test-new-session-with-prefix-arg ()
  "\\[universal-argument] \\[pilish] creates a named session."
  (let ((root "/tmp/pilish-test-named/"))
    (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
              ((symbol-function 'pilish--start-process) (lambda (&rest _) nil))
              ((symbol-function 'pilish--display-buffers) #'ignore)
              ((symbol-function 'read-string) (lambda (&rest _) "my-session")))
      (let ((current-prefix-arg '(4))
            (default-directory root))
        (unwind-protect
            (progn
              (call-interactively #'pilish)
              (should (get-buffer (pilish-test--chat-buffer-name root "my-session"))))
          (pilish-test--kill-session-buffers root "my-session"))))))

(ert-deftest pilish-test-non-pi-rerun-from-small-window-does-not-error ()
  "Calling `pilish' from a small non-pi window should not error."
  (let ((root "/tmp/pilish-test-small-window/"))
    (make-directory root t)
    (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
              ((symbol-function 'pilish--start-process) (lambda (&rest _) nil)))
      (unwind-protect
          (progn
            (delete-other-windows)
            (switch-to-buffer "*scratch*")
            (with-temp-buffer
              (setq default-directory root)
              (pilish))
            (let* ((chat (get-buffer (pilish-test--chat-buffer-name root)))
                   (input (get-buffer (pilish-test--input-buffer-name root)))
                   (input-win (car (get-buffer-window-list input nil t)))
                   (non-pi (get-buffer-create "*pilish-test-non-pi*")))
              (select-window input-win)
              (with-current-buffer non-pi
                (setq default-directory root))
              (switch-to-buffer non-pi)
              (pilish)
              (should (get-buffer-window-list chat nil t))
              (should (get-buffer-window-list input nil t))))
        (pilish-test--kill-session-buffers root)
        (ignore-errors (kill-buffer "*pilish-test-non-pi*"))
        (delete-other-windows)))))

(ert-deftest pilish-test-non-pi-rerun-with-chat-hidden-avoids-duplicate-input-windows ()
  "Restoring from input-only visibility should keep a single input window."
  (let ((root "/tmp/pilish-test-input-only-rerun/"))
    (make-directory root t)
    (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
              ((symbol-function 'pilish--start-process) (lambda (&rest _) nil)))
      (unwind-protect
          (progn
            (delete-other-windows)
            (switch-to-buffer "*scratch*")
            (with-temp-buffer
              (setq default-directory root)
              (pilish))
            (let* ((chat (get-buffer (pilish-test--chat-buffer-name root)))
                   (input (get-buffer (pilish-test--input-buffer-name root)))
                   (chat-win (car (get-buffer-window-list chat nil t)))
                   (non-pi (get-buffer-create "*pilish-test-non-pi*")))
              ;; Hide chat by replacing it with a non-pi buffer, leaving input visible.
              (select-window chat-win)
              (with-current-buffer non-pi
                (setq default-directory root))
              (switch-to-buffer non-pi)
              (pilish)
              (should (= 1 (length (get-buffer-window-list input nil t))))
              (should (= 1 (length (get-buffer-window-list chat nil t))))))
        (pilish-test--kill-session-buffers root)
        (ignore-errors (kill-buffer "*pilish-test-non-pi*"))
        (delete-other-windows)))))

(ert-deftest pilish-test-project-buffers-excludes-subdir-sessions ()
  "`pilish-project-buffers' should match the directory exactly."
  (let ((root "/tmp/pilish-test-root/")
        (sub "/tmp/pilish-test-root/somesubdir/"))
    (make-directory root t)
    (make-directory sub t)
    (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
              ((symbol-function 'pilish--start-process) (lambda (&rest _) nil))
              ((symbol-function 'pilish--check-dependencies) #'ignore))
      (unwind-protect
          (progn
            (with-temp-buffer
              (setq default-directory root)
              (pilish--setup-session root nil))
            (with-temp-buffer
              (setq default-directory sub)
              (pilish--setup-session sub nil))
            (with-temp-buffer
              (setq default-directory root)
              (let ((buffers (pilish-project-buffers)))
                (should (= 1 (length buffers)))
                (should (equal (car buffers)
                               (get-buffer (pilish-test--chat-buffer-name root)))))))
        (pilish-test--kill-session-buffers root)
        (pilish-test--kill-session-buffers sub)))))

(ert-deftest pilish-test-toggle-existing-session-does-not-check-dependencies ()
  "Toggling an existing session is a UI action, not a process launch."
  (let* ((root (pilish-test--make-temp-directory
                "pilish-test-toggle-no-deps-"))
         (chat (generate-new-buffer (pilish-test--chat-buffer-name root)))
         (input (generate-new-buffer (pilish-test--input-buffer-name root)))
         (displayed nil))
    (unwind-protect
        (progn
          (with-current-buffer chat
            (pilish-chat-mode)
            (pilish--set-chat-session-identity root)
            (pilish--set-input-buffer input))
          (with-current-buffer input
            (pilish-input-mode)
            (pilish--set-chat-buffer chat))
          (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
                    ((symbol-function 'pilish--check-dependencies)
                     (lambda (&rest _)
                       (ert-fail "toggle checked process dependencies")))
                    ((symbol-function 'pilish--display-buffers)
                     (lambda (_chat _input &rest _)
                       (setq displayed t))))
            (with-temp-buffer
              (setq default-directory root)
              (pilish-toggle)))
          (should displayed))
      (pilish-test--kill-live-buffers input chat)
      (delete-directory root t))))

(ert-deftest pilish-test-toggle-uses-exact-project-session ()
  "`pilish-toggle' should not pick a subdir session for parent dir."
  (let ((root "/tmp/pilish-test-toggle-root/")
        (sub "/tmp/pilish-test-toggle-root/somesubdir/")
        (displayed-name nil))
    (make-directory root t)
    (make-directory sub t)
    (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
              ((symbol-function 'pilish--start-process) (lambda (&rest _) nil))
              ((symbol-function 'pilish--check-dependencies) #'ignore)
              ((symbol-function 'pilish--display-buffers)
               (lambda (chat _input &rest _)
                 (setq displayed-name (buffer-name chat)))))
      (unwind-protect
          (progn
            (with-temp-buffer
              (setq default-directory root)
              (pilish--setup-session root nil))
            (with-temp-buffer
              (setq default-directory sub)
              (pilish--setup-session sub nil))
            ;; Make subdir chat more recent, then hide all pi windows.
            (switch-to-buffer (pilish-test--chat-buffer-name sub))
            (switch-to-buffer "*scratch*")
            (with-temp-buffer
              (setq default-directory root)
              (pilish-toggle))
            (should (equal displayed-name
                           (pilish-test--chat-buffer-name root))))
        (pilish-test--kill-session-buffers root)
        (pilish-test--kill-session-buffers sub)))))

(ert-deftest pilish-test-toggle-from-pi-buffer-uses-current-session ()
  "`pilish-toggle' from pi buffer should use current session directly."
  (let ((root "/tmp/pilish-test-toggle-current-root/")
        (sub "/tmp/pilish-test-toggle-current-root/somesubdir/"))
    (make-directory root t)
    (make-directory sub t)
    (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
              ((symbol-function 'pilish--start-process) (lambda (&rest _) nil))
              ((symbol-function 'pilish--check-dependencies) #'ignore)
              ;; If toggle consulted project-buffers here, it would pick sub.
              ((symbol-function 'pilish-project-buffers)
               (lambda ()
                 (list (get-buffer (pilish-test--chat-buffer-name sub))))))
      (unwind-protect
          (progn
            (with-temp-buffer
              (setq default-directory root)
              (pilish))
            (with-temp-buffer
              (setq default-directory sub)
              (pilish--setup-session sub nil))
            (let ((root-chat (get-buffer (pilish-test--chat-buffer-name root)))
                  (root-input (get-buffer (pilish-test--input-buffer-name root)))
                  (sub-chat (get-buffer (pilish-test--chat-buffer-name sub))))
              (with-current-buffer root-chat
                (pilish-toggle))
              (should-not (get-buffer-window-list root-chat nil t))
              (should-not (get-buffer-window-list root-input nil t))
              (should-not (get-buffer-window-list sub-chat nil t))))
        (pilish-test--kill-session-buffers root)
        (pilish-test--kill-session-buffers sub)
        (delete-other-windows)))))

(ert-deftest pilish-test-project-buffers-finds-session ()
  "`pilish-project-buffers' returns chat buffer for the current project."
  (pilish-test-with-mock-session "/tmp/pilish-test-projbuf/"
    (let ((default-directory "/tmp/pilish-test-projbuf/"))
      (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil)))
        (should (= 1 (length (pilish-project-buffers))))
        (should (string-prefix-p "*pilish-chat:"
                                 (buffer-name (car (pilish-project-buffers)))))))))

(ert-deftest pilish-test-project-buffers-finds-saved-session-after-write-file ()
  "`pilish-project-buffers' still finds a saved chat buffer."
  (let ((root (pilish-test--make-temp-directory
               "pilish-test-projbuf-write-file-"))
        (file nil)
        (chat nil)
        (input nil)
        (make-backup-files nil))
    (unwind-protect
        (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
                  ((symbol-function 'pilish--start-process) (lambda (&rest _) nil))
                  ((symbol-function 'pilish--display-buffers) #'ignore)
                  ((symbol-function 'pilish--check-dependencies) #'ignore))
          (setq chat (pilish--setup-session root nil)
                input (buffer-local-value 'pilish--input-buffer chat)
                file (pilish-test--write-chat-buffer
                      chat "pilish-chat-projbuf-"))
          (with-temp-buffer
            (setq default-directory root)
            (should (equal (pilish-project-buffers)
                           (list chat)))))
      (pilish-test--kill-live-buffers input chat)
      (ignore-errors (delete-file file))
      (ignore-errors (delete-directory root t)))))

(ert-deftest pilish-test-project-root-session-reused-after-write-file-from-subdir ()
  "Saving from a subdir keeps the project-root session identity."
  (let* ((root (pilish-test--make-temp-directory
                "pilish-test-write-file-project-root-"))
         (nested (expand-file-name "src/nested/" root))
         (sibling (expand-file-name "docs/" root))
         (file nil)
         (chat nil)
         (input nil)
         (make-backup-files nil))
    (make-directory nested t)
    (make-directory sibling t)
    (unwind-protect
        (cl-letf (((symbol-function 'project-current)
                   (lambda (&rest _) 'mock-project))
                  ((symbol-function 'project-root)
                   (lambda (_project) root))
                  ((symbol-function 'pilish--start-process) (lambda (&rest _) nil))
                  ((symbol-function 'pilish--check-dependencies) #'ignore)
                  ((symbol-function 'pilish--display-buffers) #'ignore))
          (with-temp-buffer
            (setq default-directory nested)
            (pilish)
            (setq chat (pilish--find-session root)
                  input (get-buffer (pilish-test--input-buffer-name root))))
          (setq file (pilish-test--write-chat-buffer
                      chat "pilish-chat-project-root-"
                      "Saved from nested dir\n"))
          (with-current-buffer chat
            (should (equal (pilish--chat-session-buffer-name)
                           (pilish-test--chat-buffer-name root)))
            (should (equal (pilish--session-directory) root))
            (should (equal buffer-file-name file)))
          (with-temp-buffer
            (setq default-directory sibling)
            (pilish)
            (should (equal (pilish-project-buffers)
                           (list chat))))
          (should (eq (pilish--find-session root) chat))
          (should (eq (get-buffer (pilish-test--input-buffer-name root))
                      input)))
      (pilish-test--kill-live-buffers input chat)
      (ignore-errors (delete-file file))
      (ignore-errors (delete-directory root t)))))

(ert-deftest pilish-test-project-buffers-excludes-other-projects ()
  "`pilish-project-buffers' returns nil for a different project."
  (pilish-test-with-mock-session "/tmp/pilish-test-projbuf-a/"
    (let ((default-directory "/tmp/pilish-test-projbuf-b/"))
      (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil)))
        (should (null (pilish-project-buffers)))))))

(defun pilish-test--make-aliased-directory (prefix)
  "Return (REAL . LINK): a new directory and a symlink to it, both with slashes.
PREFIX names the directory; REAL is already resolved through `file-truename'."
  (let* ((real (file-truename (pilish-test--make-temp-directory prefix)))
         (link (concat (directory-file-name real) "-link")))
    (make-symbolic-link (directory-file-name real) link)
    (cons real (file-name-as-directory link))))

(defun pilish-test--delete-aliased-directory (dirs)
  "Delete the directory and symlink of DIRS from `pilish-test--make-aliased-directory'."
  (ignore-errors (delete-file (directory-file-name (cdr dirs))))
  (ignore-errors (delete-directory (car dirs) t)))

(defun pilish-test--session-pairs-in (dir)
  "Return the chat and input buffers whose directory resolves to DIR."
  (let ((truename (file-truename dir)))
    (seq-filter
     (lambda (buffer)
       (with-current-buffer buffer
         (and (derived-mode-p 'pilish-chat-mode 'pilish-input-mode)
              (equal (file-truename default-directory) truename))))
     (buffer-list))))

(ert-deftest pilish-test-session-lookup-matches-symlink-aliases ()
  "A session opened through one spelling of a directory is found through another.
Both orders: opened through the symlink and found through the resolved
path (Pi records the resolved cwd), and the reverse.  Default and named
sessions stay distinct, and setting up through the other spelling reuses
the pair and keeps its first spelling."
  (dolist (order '(link-first real-first))
    (let* ((dirs (pilish-test--make-aliased-directory "pilish-test-alias-"))
           (first (if (eq order 'link-first) (cdr dirs) (car dirs)))
           (second (if (eq order 'link-first) (car dirs) (cdr dirs)))
           default-chat named-chat)
      (unwind-protect
          (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
                    ((symbol-function 'pilish--start-process)
                     (lambda (&rest _) nil))
                    ((symbol-function 'pilish--check-dependencies) #'ignore))
            (setq default-chat (pilish--setup-session first)
                  named-chat (pilish--setup-session first "feature"))
            (should (eq (pilish--find-session second) default-chat))
            (should (eq (pilish--find-session second "feature") named-chat))
            (should-not (pilish--find-session second "other"))
            (should (eq (pilish-session-exists-p second) t))
            (should (eq (pilish-session-exists-p second "feature") t))
            (let ((default-directory second))
              (should (equal (sort (pilish-project-buffers)
                                   (lambda (a b)
                                     (string< (buffer-name a) (buffer-name b))))
                             (sort (list default-chat named-chat)
                                   (lambda (a b)
                                     (string< (buffer-name a)
                                              (buffer-name b)))))))
            (let ((inputs (mapcar #'pilish-session-input-buffer
                                  (list default-chat named-chat))))
              (should (eq (pilish--setup-session second) default-chat))
              (should (eq (pilish--setup-session second "feature") named-chat))
              (should (equal (mapcar #'pilish-session-input-buffer
                                     (list default-chat named-chat))
                             inputs))
              (should (equal (buffer-name default-chat)
                             (pilish-test--chat-buffer-name first)))
              (should (equal (buffer-name (car inputs))
                             (pilish-test--input-buffer-name first)))
              (should (equal (pilish-session-directory default-chat) first))
              (should (= (length (pilish-test--session-pairs-in first)) 4)))
            ;; A background start through the other spelling is refused.
            (should-error (pilish-start-session second nil)))
        (pilish-test--kill-session-buffers first)
        (pilish-test--kill-session-buffers first "feature")
        (pilish-test--kill-session-buffers second)
        (pilish-test--kill-session-buffers second "feature")
        (pilish-test--delete-aliased-directory dirs)))))

(ert-deftest pilish-test-toggle-finds-saved-session-after-write-file ()
  "`pilish-toggle' still finds a saved chat buffer."
  (let ((root (pilish-test--make-temp-directory
               "pilish-test-toggle-write-file-"))
        (file nil)
        (chat nil)
        (input nil)
        (displayed-chat nil)
        (displayed-input nil)
        (make-backup-files nil))
    (unwind-protect
        (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
                  ((symbol-function 'pilish--start-process) (lambda (&rest _) nil))
                  ((symbol-function 'pilish--check-dependencies) #'ignore)
                  ((symbol-function 'pilish--display-buffers)
                   (lambda (chat-buf input-buf &rest _)
                     (setq displayed-chat chat-buf
                           displayed-input input-buf))))
          (setq chat (pilish--setup-session root nil)
                input (buffer-local-value 'pilish--input-buffer chat)
                file (pilish-test--write-chat-buffer
                      chat "pilish-chat-toggle-"))
          (with-temp-buffer
            (setq default-directory root)
            (pilish-toggle))
          (should (eq displayed-chat chat))
          (should (eq displayed-input input)))
      (pilish-test--kill-live-buffers input chat)
      (ignore-errors (delete-file file))
      (ignore-errors (delete-directory root t)))))

(ert-deftest pilish-test-toggle-hides-and-shows-saved-session-after-write-file ()
  "`pilish-toggle' hides and restores a saved session."
  (let ((root (pilish-test--make-temp-directory
               "pilish-test-toggle-write-file-live-"))
        (file nil)
        (chat nil)
        (input nil)
        (make-backup-files nil))
    (unwind-protect
        (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
                  ((symbol-function 'pilish--start-process) (lambda (&rest _) nil))
                  ((symbol-function 'pilish--check-dependencies) #'ignore))
          (delete-other-windows)
          (switch-to-buffer "*scratch*")
          (setq default-directory root)
          (pilish)
          (setq chat (pilish--find-session root)
                input (get-buffer (pilish-test--input-buffer-name root)))
          (setq file (pilish-test--write-chat-buffer
                      chat "pilish-chat-toggle-live-"))
          (with-current-buffer chat
            (should (equal (pilish--chat-session-buffer-name)
                           (pilish-test--chat-buffer-name root)))
            (should (equal (pilish--session-directory) root))
            (should (equal buffer-file-name file)))
          (should (get-buffer-window-list chat nil t))
          (should (get-buffer-window-list input nil t))
          (let ((non-pi (get-buffer-create "*pilish-test-toggle-non-pi*")))
            (with-current-buffer non-pi
              (setq default-directory root))
            (switch-to-buffer non-pi)
            (pilish-toggle)
            (should-not (get-buffer-window-list chat nil t))
            (should-not (get-buffer-window-list input nil t))
            (pilish-toggle)
            (should (get-buffer-window-list chat nil t))
            (should (get-buffer-window-list input nil t))
            (with-current-buffer chat
              (should (equal buffer-file-name file)))))
      (pilish-test--kill-live-buffers input chat)
      (ignore-errors (kill-buffer "*pilish-test-toggle-non-pi*"))
      (ignore-errors (delete-file file))
      (ignore-errors (delete-directory root t))
      (delete-other-windows))))

(ert-deftest pilish-test-toggle-no-session-errors ()
  "`pilish-toggle' signals `user-error' when no session exists."
  (let ((default-directory "/tmp/pilish-test-no-session/"))
    (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
              ((symbol-function 'pilish--check-dependencies) #'ignore))
      (should-error (pilish-toggle) :type 'user-error))))

(ert-deftest pilish-test-toggle-shows-in-current-frame-when-only-visible-elsewhere ()
  "`pilish-toggle' should show in current frame when hidden there."
  (let ((root "/tmp/pilish-test-toggle-other-frame/")
        (display-called nil)
        (hide-called nil))
    (make-directory root t)
    (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
              ((symbol-function 'pilish--start-process) (lambda (&rest _) nil))
              ((symbol-function 'pilish--check-dependencies) #'ignore))
      (unwind-protect
          (progn
            (with-temp-buffer
              (setq default-directory root)
              (pilish))
            (with-temp-buffer
              (setq default-directory root)
              (cl-letf (((symbol-function 'get-buffer-window-list)
                         (lambda (_buffer _minibuf &optional all-frames)
                           (if all-frames '(foreign-window) nil)))
                        ((symbol-function 'pilish--display-buffers)
                         (lambda (&rest _)
                           (setq display-called t)))
                        ((symbol-function 'pilish--hide-session-windows)
                         (lambda ()
                           (setq hide-called t))))
                (pilish-toggle)))
            (should display-called)
            (should-not hide-called))
        (pilish-test--kill-session-buffers root)
        (delete-other-windows)))))

(ert-deftest pilish-test-toggle-hides-session-from-non-pi-window ()
  "`pilish-toggle' hides a visible session when called from non-pi."
  (let ((root "/tmp/pilish-test-toggle-hide/")
        (chat nil)
        (input nil))
    (make-directory root t)
    (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
              ((symbol-function 'pilish--start-process) (lambda (&rest _) nil))
              ((symbol-function 'pilish--check-dependencies) #'ignore))
      (unwind-protect
          (progn
            (delete-other-windows)
            (switch-to-buffer "*scratch*")
            (setq default-directory root)
            (pilish)
            (setq chat (get-buffer (pilish-test--chat-buffer-name root)))
            (setq input (get-buffer (pilish-test--input-buffer-name root)))
            (let* ((input-win (car (get-buffer-window-list input nil t)))
                   (non-pi (get-buffer-create "*pilish-test-non-pi*")))
              (select-window input-win)
              (with-current-buffer non-pi
                (setq default-directory root))
              (switch-to-buffer non-pi)
              (pilish-toggle))
            (should-not (get-buffer-window-list chat nil t))
            (should-not (get-buffer-window-list input nil t)))
        (pilish-test--kill-session-buffers root)
        (ignore-errors (kill-buffer "*pilish-test-non-pi*"))
        (delete-other-windows)))))

(ert-deftest pilish-test-toggle-hides-session-when-only-input-visible ()
  "`pilish-toggle' hides session when only input is visible."
  (let ((root "/tmp/pilish-test-toggle-input-only/")
        (chat nil)
        (input nil))
    (make-directory root t)
    (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
              ((symbol-function 'pilish--start-process) (lambda (&rest _) nil))
              ((symbol-function 'pilish--check-dependencies) #'ignore))
      (unwind-protect
          (progn
            (delete-other-windows)
            (switch-to-buffer "*scratch*")
            (setq default-directory root)
            (pilish)
            (setq chat (get-buffer (pilish-test--chat-buffer-name root)))
            (setq input (get-buffer (pilish-test--input-buffer-name root)))
            (let* ((chat-win (car (get-buffer-window-list chat nil t)))
                   (non-pi (get-buffer-create "*pilish-test-non-pi*")))
              ;; Keep only input visible by replacing chat with a non-pi buffer.
              (select-window chat-win)
              (with-current-buffer non-pi
                (setq default-directory root))
              (switch-to-buffer non-pi)
              (pilish-toggle))
            (should-not (get-buffer-window-list chat nil t))
            (should-not (get-buffer-window-list input nil t)))
        (pilish-test--kill-session-buffers root)
        (ignore-errors (kill-buffer "*pilish-test-non-pi*"))
        (delete-other-windows)))))

(ert-deftest pilish-test-batch-emacs-loads-overridden-package-directory ()
  "A child Emacs loads dependencies from the caller's package directory."
  (let* ((root (make-temp-file "pi-child-package-" t))
         (package-user-dir (expand-file-name "elpa" root))
         (package-dir (expand-file-name "pi-child-dependency-1.0"
                                        package-user-dir)))
    (unwind-protect
        (progn
          (make-directory package-dir t)
          (with-temp-file (expand-file-name "pi-child-dependency-pkg.el"
                                             package-dir)
            (insert "(define-package \"pi-child-dependency\" \"1.0\" \"Test dependency\")\n"))
          (with-temp-file (expand-file-name "pi-child-dependency-autoloads.el"
                                             package-dir)
            (insert "(add-to-list 'load-path\n"
                    "             (directory-file-name\n"
                    "              (file-name-directory\n"
                    "               (or load-file-name buffer-file-name))))\n"))
          (with-temp-file (expand-file-name "pi-child-dependency.el" package-dir)
            (insert "(defconst pi-child-dependency-value 'loaded-from-override)\n"
                    "(provide 'pi-child-dependency)\n"))
          (let ((process-environment (copy-sequence process-environment)))
            (setenv "PACKAGE_USER_DIR" package-user-dir)
            (should
             (eq 'loaded-from-override
                 (pilish-test--read-batch-emacs-result
                  "(progn
  (display-warning 'pilish-test \"injected child warning\")
  (require 'pi-child-dependency)
  (prin1 pi-child-dependency-value))")))))
      (delete-directory root t))))

(ert-deftest pilish-test-transient-warning-explains-built-in-upgrade ()
  "Loading the menu with an old transient explains how to upgrade it."
  (let* ((expression
          (mapconcat
           #'identity
           '("(progn"
             "  (require 'cl-lib)"
             "  (require 'transient)"
             "  (setq transient-version \"0.7.2.2\")"
             "  (let (captured)"
             "    (cl-letf (((symbol-function 'display-warning)"
             "               (lambda (_type message &rest _)"
             "                 (setq captured message))))"
             "      (load (expand-file-name \"pilish-menu.el\""
             "                              (file-name-directory"
             "                               (locate-library \"pilish\")))"
             "            nil t))"
             "    (prin1 captured)))")
           " "))
         (result (pilish-test--read-batch-emacs-result expression)))
    (should (string-match-p "upgrade transient from MELPA" result))
    (should (string-match-p "package-install-upgrade-built-in" result))))

(ert-deftest pilish-test-transient-version-check-handles-built-in-snapshot-format ()
  "Loading the menu tolerates built-in transient version strings with a prefix."
  (let* ((expression
          (mapconcat
           #'identity
           '("(progn"
             "  (require 'cl-lib)"
             "  (require 'transient)"
             "  (setq transient-version \"v0.12.0-15-gfe5214e6-builtin\")"
             "  (let (captured err)"
             "    (cl-letf (((symbol-function 'display-warning)"
             "               (lambda (_type message &rest _)"
             "                 (setq captured message))))"
             "      (condition-case load-err"
             "          (load (expand-file-name \"pilish-menu.el\""
             "                                  (file-name-directory"
             "                                   (locate-library \"pilish\")))"
             "                nil t)"
             "        (error (setq err (error-message-string load-err)))))"
             "    (prin1 (list :warning captured :error err))))")
           " "))
         (result (pilish-test--read-batch-emacs-result expression)))
    (should-not (plist-get result :error))
    (should-not (plist-get result :warning))))

(ert-deftest pilish-test-md-ts-mode-package-load-leaves-global-markdown-settings-alone ()
  "Loading `md-ts-mode' keeps global Markdown associations opt-in."
  (let ((result (pilish-test--markdown-load-state 'md-ts-mode)))
    (should (eq t (plist-get result :auto-unchanged)))
    (should (eq t (plist-get result :major-remap-unchanged)))
    (should (eq t (plist-get result :treesit-remap-unchanged)))
    (should (eq t (plist-get result :md-mode-defined)))
    (should (eq t (plist-get result :md-mode-maybe-defined)))
    (should (equal (plist-get result :before-md-association)
                   (plist-get result :after-md-association)))
    (should (equal (plist-get result :before-major-markdown-remap)
                   (plist-get result :after-major-markdown-remap)))
    (should (equal (plist-get result :before-treesit-markdown-remap)
                   (plist-get result :after-treesit-markdown-remap)))))

(ert-deftest pilish-test-package-load-leaves-global-markdown-settings-alone ()
  "Loading `pilish' does not change global Markdown mode settings."
  (let ((result (pilish-test--markdown-load-state 'pilish)))
    (should (eq t (plist-get result :auto-unchanged)))
    (should (eq t (plist-get result :major-remap-unchanged)))
    (should (eq t (plist-get result :treesit-remap-unchanged)))
    (should (equal (plist-get result :before-md-association)
                   (plist-get result :after-md-association)))
    (should (equal (plist-get result :before-major-markdown-remap)
                   (plist-get result :after-major-markdown-remap)))
    (should (equal (plist-get result :before-treesit-markdown-remap)
                   (plist-get result :after-treesit-markdown-remap)))))

;;;; Background sessions

(defvar pilish-test--background-launches nil
  "Recorded (DIRECTORY ARGS ENVIRONMENT) of mocked process starts.")

(defvar pilish-test--background-commands nil
  "RPC command types sent by mocked background sessions, oldest first.")

(defmacro pilish-test--with-background-startup (&rest body)
  "Run BODY with mocked Pi startup that fails on any user interaction.
Process starts land in `pilish-test--background-launches' and RPC
commands in `pilish-test--background-commands'."
  (declare (indent 0) (debug t))
  `(let ((pilish-test--background-launches nil)
         (pilish-test--background-commands nil)
         (processes nil))
     (cl-letf* (((symbol-function 'project-current) (lambda (&rest _) nil))
                ((symbol-function 'pilish--check-pi) (lambda (&rest _) t))
                ((symbol-function 'pilish--missing-essential-grammars)
                 (lambda () nil))
                ((symbol-function 'pilish--maybe-install-optional-grammars)
                 (lambda () (error "Optional grammars offered")))
                ((symbol-function 'pilish--display-buffers)
                 (lambda (&rest _) (error "Session displayed")))
                ((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (error "Prompted")))
                ((symbol-function 'yes-or-no-p)
                 (lambda (&rest _) (error "Prompted")))
                ((symbol-function 'read-from-minibuffer)
                 (lambda (&rest _) (error "Prompted")))
                ((symbol-function 'pilish--fetch-commands) #'ignore)
                ((symbol-function 'pilish--rpc-async)
                 (lambda (_proc command &rest _)
                   (setq pilish-test--background-commands
                         (append pilish-test--background-commands
                                 (list command)))))
                ((symbol-function 'pilish--start-process)
                 (lambda (dir &optional args environment)
                   (push (list dir args environment)
                         pilish-test--background-launches)
                   (car (push (make-pipe-process :name "pilish-test-bg"
                                                 :noquery t
                                                 :sentinel #'ignore)
                              processes)))))
       (unwind-protect
           (progn ,@body)
         (dolist (proc processes)
           (when (process-live-p proc)
             (delete-process proc)))))))

(ert-deftest pilish-test-start-session-leaves-layout-and-sends-no-prompt ()
  "Background sessions start without display, prompts or a Pi prompt.
A nil name selects the directory default; a string names the session."
  (let ((root (pilish-test--make-temp-directory "pilish-test-bg-start-"))
        default named)
    (unwind-protect
        (pilish-test--with-background-startup
          (let ((config (current-window-configuration))
                (selected (window-buffer (selected-window))))
            (setq default (pilish-start-session root nil)
                  named (pilish-start-session root "worker"))
            (should (compare-window-configurations
                     config (current-window-configuration)))
            (should (eq selected (window-buffer (selected-window)))))
          (should (equal (buffer-name default)
                         (pilish-test--chat-buffer-name root)))
          (should (equal (buffer-name named)
                         (pilish-test--chat-buffer-name root "worker")))
          (should (eq (pilish--find-session root) default))
          (dolist (chat (list default named))
            (should-not (get-buffer-window chat t))
            (let ((input (buffer-local-value 'pilish--input-buffer chat)))
              (should (buffer-live-p input))
              (should (eq (buffer-local-value 'pilish--chat-buffer input)
                          chat))
              (should-not (get-buffer-window input t)))
            (should (process-live-p
                     (buffer-local-value 'pilish--process chat))))
          (should (equal (mapcar #'car pilish-test--background-launches)
                         (list root root)))
          (should-not (seq-find
                       (lambda (command)
                         (member (plist-get command :type)
                                 '("prompt" "steer" "follow_up")))
                       pilish-test--background-commands))
          (should (equal (plist-get (car pilish-test--background-commands)
                                    :type)
                         "get_state")))
      (pilish-test--kill-session-buffers root)
      (pilish-test--kill-session-buffers root "worker")
      (delete-directory root t))))

(ert-deftest pilish-test-start-session-refuses-existing-or-invalid-session ()
  "An existing session, an empty name or a missing directory is an error."
  (let ((root (pilish-test--make-temp-directory "pilish-test-bg-exists-")))
    (unwind-protect
        (pilish-test--with-background-startup
          (let ((chat (pilish-start-session root "one")))
            (should-error (pilish-start-session root "one"))
            (should (buffer-live-p chat))
            (should (= 1 (length pilish-test--background-launches))))
          (should-error (pilish-start-session root ""))
          (should-error (pilish-start-session (expand-file-name "missing/" root)
                                              nil))
          (should-not (get-buffer (pilish-test--chat-buffer-name root))))
      (pilish-test--kill-session-buffers root "one")
      (delete-directory root t))))

(ert-deftest pilish-test-start-session-fails-without-prerequisites ()
  "Missing Pi, or essential grammars it may not ask about, fail cleanly.
No buffer or process remains."
  (let ((root (pilish-test--make-temp-directory "pilish-test-bg-deps-")))
    (unwind-protect
        (pilish-test--with-background-startup
          (cl-letf (((symbol-function 'pilish--check-pi) (lambda (&rest _) nil)))
            (should (string-match-p
                     "not found"
                     (cadr (should-error (pilish-start-session root nil))))))
          (cl-letf (((symbol-function 'pilish--missing-essential-grammars)
                     (lambda () '(markdown))))
            (let ((pilish-essential-grammar-action 'prompt))
              (should (string-match-p
                       "grammars missing: markdown"
                       (cadr (should-error (pilish-start-session root nil)))))))
          (should-not pilish-test--background-launches)
          (should-not (get-buffer (pilish-test--chat-buffer-name root)))
          (should-not (get-buffer (pilish-test--input-buffer-name root))))
      (delete-directory root t))))

(ert-deftest pilish-test-start-session-follows-essential-grammar-action ()
  "Background starts honor `pilish-essential-grammar-action' without asking.
`warn' starts after a warning and `auto' installs before Markdown modes run."
  (let ((root (pilish-test--make-temp-directory "pilish-test-bg-grammar-"))
        (missing '(markdown))
        (warnings nil)
        (installed nil))
    (unwind-protect
        (pilish-test--with-background-startup
          (cl-letf (((symbol-function 'pilish--missing-essential-grammars)
                     (lambda () missing))
                    ((symbol-function 'pilish--install-grammars)
                     (lambda (grammars)
                       (should-not
                        (get-buffer (pilish-test--chat-buffer-name root "auto")))
                       (should-not
                        (get-buffer (pilish-test--input-buffer-name root "auto")))
                       (setq installed grammars missing nil)
                       (length grammars)))
                    ((symbol-function 'display-warning)
                     (lambda (_type message &rest _) (push message warnings))))
            (let ((pilish-essential-grammar-action 'warn))
              (should (buffer-live-p (pilish-start-session root "warn")))
              (should (string-match-p "markdown" (car warnings)))
              (should-not installed))
            (let ((pilish-essential-grammar-action 'auto))
              (should (buffer-live-p (pilish-start-session root "auto")))
              (should (equal installed '(markdown))))
            (should (= 2 (length pilish-test--background-launches)))))
      (pilish-test--kill-session-buffers root "warn")
      (pilish-test--kill-session-buffers root "auto")
      (delete-directory root t))))

(ert-deftest pilish-test-start-session-removes-buffers-when-start-fails ()
  "A failing process start leaves no half-created session behind."
  (let ((root (pilish-test--make-temp-directory "pilish-test-bg-fail-")))
    (unwind-protect
        (pilish-test--with-background-startup
          (cl-letf (((symbol-function 'pilish--start-process)
                     (lambda (&rest _) (error "Spawn failed"))))
            (should (equal (cadr (should-error (pilish-start-session root nil)))
                           "Spawn failed")))
          (should-not (get-buffer (pilish-test--chat-buffer-name root)))
          (should-not (get-buffer (pilish-test--input-buffer-name root))))
      (pilish-test--kill-session-buffers root)
      (delete-directory root t))))

(ert-deftest pilish-test-start-session-removes-buffers-when-start-is-interrupted ()
  "Quitting startup leaves no buffers or live process behind."
  (let ((root (pilish-test--make-temp-directory "pilish-test-bg-quit-")))
    (unwind-protect
        (pilish-test--with-background-startup
          (let ((pilish-session-environment-functions
                 (list (lambda (&rest _) (signal 'quit nil)))))
            (should (equal '(quit)
                           (condition-case err
                               (pilish-start-session root nil)
                             ((error quit) err)))))
          (should-not (get-buffer (pilish-test--chat-buffer-name root)))
          (should-not (get-buffer (pilish-test--input-buffer-name root)))
          (should-not processes)
          (cl-letf (((symbol-function 'pilish--rpc-async)
                     (lambda (&rest _) (signal 'quit nil))))
            (should (equal '(quit)
                           (condition-case err
                               (pilish-start-session root nil)
                             ((error quit) err)))))
          (should-not (get-buffer (pilish-test--chat-buffer-name root)))
          (should-not (get-buffer (pilish-test--input-buffer-name root)))
          (should (= 1 (length processes)))
          (should-not (process-live-p (car processes))))
      (pilish-test--kill-session-buffers root)
      (delete-directory root t))))

(ert-deftest pilish-test-session-launch-options-apply-to-every-spawn ()
  "Explicit environment wins over hooks; options persist without leaking.
Environment functions run for every spawn, so a respawn gets their current
values, and a failing or malformed function only warns.  A respawn reuses
the session's own options, and another session of the same directory gets
none of them."
  (let* ((root (pilish-test--make-temp-directory "pilish-test-bg-env-"))
         (global-environment (copy-sequence process-environment))
         ;; Batch ERT enables debugging on Emacs 29; exercise the warning path.
         (debug-on-error nil)
         (calls nil)
         (warnings nil)
         (pilish-session-environment-functions
          (list (lambda (chat dir)
                  (push (list chat dir) calls)
                  (list (cons "PILISH_A" "hook")
                        (cons "PILISH_B" (format "hook-%d" (length calls)))))
                (lambda (_chat _dir) (error "Broken hook"))
                (lambda (_chat _dir) '(("BAD=NAME" . "x"))))))
    (unwind-protect
        (pilish-test--with-background-startup
          (cl-letf (((symbol-function 'display-warning)
                     (lambda (_type message &rest _) (push message warnings))))
            (let ((chat (pilish-start-session
                         root "env" :args '("--model" "m")
                         :environment '(("PILISH_A" . "explicit")))))
              (should (equal calls (list (list chat root))))
              (should (= 2 (length warnings)))
              (should (string-match-p "Broken hook" (cadr warnings)))
              (should (string-match-p "BAD=NAME" (car warnings)))
              (should (equal (car pilish-test--background-launches)
                             (list root '("--model" "m")
                                   '(("PILISH_A" . "explicit")
                                     ("PILISH_A" . "hook")
                                     ("PILISH_B" . "hook-1")))))
              ;; The process dies; reopening the session respawns it with its
              ;; own options and the functions' current values.
              (delete-process (buffer-local-value 'pilish--process chat))
              (pilish--setup-session root "env" :background t)
              (should (= 2 (length calls)))
              (should (equal (car pilish-test--background-launches)
                             (list root '("--model" "m")
                                   '(("PILISH_A" . "explicit")
                                     ("PILISH_A" . "hook")
                                     ("PILISH_B" . "hook-2")))))
              (pilish-start-session root "other")
              (should (equal (car pilish-test--background-launches)
                             (list root nil
                                   '(("PILISH_A" . "hook")
                                     ("PILISH_B" . "hook-3")))))
              (should (equal process-environment global-environment)))))
      (pilish-test--kill-session-buffers root "env")
      (pilish-test--kill-session-buffers root "other")
      (delete-directory root t))))

(ert-deftest pilish-test-start-session-resumes-session-file ()
  "A session file resumes in its recorded directory, which must match."
  (let* ((root (pilish-test--make-temp-directory "pilish-test-bg-resume-"))
         (other (pilish-test--make-temp-directory "pilish-test-bg-other-"))
         (file (expand-file-name "saved.jsonl" root)))
    (pilish-test--write-session-file file "Saved prompt" root)
    (unwind-protect
        (pilish-test--with-background-startup
          (should-error (pilish-start-session other nil :session-file file))
          (should-not pilish-test--background-launches)
          (should-not (get-buffer (pilish-test--chat-buffer-name other)))
          ;; An explicit directory that names the recorded one is accepted.
          (let ((chat (pilish-start-session (directory-file-name root) "explicit"
                                            :session-file file)))
            (should (equal (buffer-name chat)
                           (pilish-test--chat-buffer-name root "explicit")))
            (should (equal (caar pilish-test--background-launches) root)))
          (let ((chat (pilish-start-session nil "resumed" :session-file file)))
            (should (equal (buffer-name chat)
                           (pilish-test--chat-buffer-name root "resumed")))
            (should (equal (caar pilish-test--background-launches) root))
            (let ((switch (seq-find
                           (lambda (command)
                             (equal (plist-get command :type)
                                    "switch_session"))
                           pilish-test--background-commands)))
              (should (equal (plist-get switch :sessionPath) file)))
            (should-not (seq-find
                         (lambda (command)
                           (equal (plist-get command :type) "prompt"))
                         pilish-test--background-commands))))
      (pilish-test--kill-session-buffers root "explicit")
      (pilish-test--kill-session-buffers root "resumed")
      (delete-directory root t)
      (delete-directory other t))))

(ert-deftest pilish-test-start-session-accepts-alias-of-recorded-directory ()
  "A symlink to a session file's recorded directory names that directory."
  (let* ((dirs (pilish-test--make-aliased-directory "pilish-test-bg-alias-"))
         (file (expand-file-name "saved.jsonl" (car dirs))))
    (pilish-test--write-session-file file "Saved prompt" (car dirs))
    (unwind-protect
        (pilish-test--with-background-startup
          (let ((chat (pilish-start-session (cdr dirs) "alias"
                                            :session-file file)))
            (should (equal (buffer-name chat)
                           (pilish-test--chat-buffer-name (cdr dirs) "alias")))
            (should (equal (caar pilish-test--background-launches)
                           (cdr dirs)))))
      (pilish-test--kill-session-buffers (cdr dirs) "alias")
      (pilish-test--delete-aliased-directory dirs))))

(ert-deftest pilish-test-start-session-validates-args-and-environment ()
  "Malformed ARGS or ENVIRONMENT are refused before anything starts."
  (let ((root (pilish-test--make-temp-directory "pilish-test-bg-validate-")))
    (unwind-protect
        (pilish-test--with-background-startup
          (should-error (pilish-start-session root nil :args "--model"))
          (should-error (pilish-start-session root nil :args '("--model" 1)))
          (should-error (pilish-start-session root nil :environment '("A=b")))
          (should-error (pilish-start-session root nil
                                              :environment '(("A=B" . "c"))))
          (should-error (pilish-start-session root nil
                                              :environment '(("A" . 1))))
          (should-not pilish-test--background-launches)
          (should-not (get-buffer (pilish-test--chat-buffer-name root))))
      (delete-directory root t))))

(ert-deftest pilish-test-show-session-displays-background-session ()
  "`pilish-show-session' displays a background session from anywhere.
It does not depend on `default-directory' and starts no process."
  (let ((root (pilish-test--make-temp-directory "pilish-test-bg-show-"))
        (displayed nil))
    (unwind-protect
        (pilish-test--with-background-startup
          (let ((chat (pilish-start-session root "shown")))
            (cl-letf (((symbol-function 'pilish--display-buffers)
                       (lambda (chat-buf input-buf &rest _)
                         (setq displayed (list chat-buf input-buf)))))
              (let ((default-directory temporary-file-directory))
                (should (eq (pilish-show-session chat) chat))))
            (should (equal displayed
                           (list chat (buffer-local-value
                                       'pilish--input-buffer chat))))
            (should (= 1 (length pilish-test--background-launches)))
            (with-temp-buffer
              (should-error (pilish-show-session (current-buffer))))))
      (pilish-test--kill-session-buffers root "shown")
      (delete-directory root t))))

(provide 'pilish-test)
;;; pilish-test.el ends here
