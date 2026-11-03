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
                  (should (eq pilish--status status))
                  (should-not pilish--followup-queue)
                  (should-not pilish--prompt-wait))))))
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
  (pcase-let ((`(,chat ,input ,old-proc)
               (pilish-test--make-open-session-command-buffers)))
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
                       (lambda (_) new-proc))
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
              (should-not (process-live-p old-proc))
              (should (eq (buffer-local-value 'pilish--process chat) new-proc))
              (should-not (pilish--session-transition-active-p chat))
              (pilish-submit-prompt chat "Safe after reload"
                                    (lambda (r) (push r responses)))
              (should (equal sent (list new-proc)))
              (should (= 1 (length responses)))))
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
                  ((symbol-function 'pilish--start-process) (lambda (_) nil))
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

(ert-deftest pilish-test-setup-session-shows-startup-error-from-initial-state-request ()
  "Initial startup failure should be rendered into the chat buffer."
  (let ((root (pilish-test--make-temp-directory
               "pilish-test-startup-error-"))
        (proc (start-process "pilish-startup-error" nil "cat"))
        (chat nil))
    (unwind-protect
        (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
                  ((symbol-function 'pilish--start-process) (lambda (_) proc))
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
                     (lambda (_) old-proc))
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
                     (lambda (_) proc))
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
                  ((symbol-function 'pilish--start-process) (lambda (_) proc))
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
              ((symbol-function 'pilish--start-process) (lambda (_) nil)))
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
              ((symbol-function 'pilish--start-process) (lambda (_) nil)))
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
              ((symbol-function 'pilish--start-process) (lambda (_) nil)))
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
              ((symbol-function 'pilish--start-process) (lambda (_) nil)))
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
              ((symbol-function 'pilish--start-process) (lambda (_) nil)))
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
              ((symbol-function 'pilish--start-process) (lambda (_) nil)))
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
              ((symbol-function 'pilish--start-process) (lambda (_) nil))
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
                  ((symbol-function 'pilish--start-process) (lambda (_) nil))
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
              ((symbol-function 'pilish--start-process) (lambda (_) nil))
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
              ((symbol-function 'pilish--start-process) (lambda (_) nil)))
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
              ((symbol-function 'pilish--start-process) (lambda (_) nil)))
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
              ((symbol-function 'pilish--start-process) (lambda (_) nil))
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
              ((symbol-function 'pilish--start-process) (lambda (_) nil))
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
              ((symbol-function 'pilish--start-process) (lambda (_) nil))
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
                  ((symbol-function 'pilish--start-process) (lambda (_) nil))
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
                  ((symbol-function 'pilish--start-process) (lambda (_) nil))
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
                  ((symbol-function 'pilish--start-process) (lambda (_) nil))
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
                  ((symbol-function 'pilish--start-process) (lambda (_) nil))
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
              ((symbol-function 'pilish--start-process) (lambda (_) nil))
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
              ((symbol-function 'pilish--start-process) (lambda (_) nil))
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
              ((symbol-function 'pilish--start-process) (lambda (_) nil))
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

(provide 'pilish-test)
;;; pilish-test.el ends here
