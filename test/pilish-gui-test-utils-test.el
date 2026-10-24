;;; pilish-gui-test-utils-test.el --- Unit tests for GUI test utilities -*- lexical-binding: t; -*-

;;; Commentary:

;; Fast tests for the GUI test harness itself.  These cover macro and helper
;; contracts that do not need a visible frame.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'pilish-gui-test-utils)

(ert-deftest pilish-gui-test-utils-test-with-fresh-session-requires-explicit-backend ()
  "Fresh GUI sessions must declare a backend at the entry point."
  (should-error
   (macroexpand '(pilish-gui-test-with-fresh-session
                   (should t)))))

(ert-deftest pilish-gui-test-utils-test-with-session-requires-explicit-backend ()
  "Shared GUI sessions must declare a backend at the entry point."
  (should-error
   (macroexpand '(pilish-gui-test-with-session
                   (should t)))))

(ert-deftest pilish-gui-test-utils-test-ensure-session-rejects-implicit-start ()
  "Implicit session startup without a backend should fail loudly."
  (let ((pilish-gui-test--session nil))
    (should-error (pilish-gui-test-ensure-session))))

(ert-deftest pilish-gui-test-utils-test-ensure-session-preserves-active-backend ()
  "Helper calls may reuse the already-active session backend."
  (let ((options '(:backend fake :fake-scenario "tool-read" :fake-extra-args nil)))
    (cl-letf (((symbol-function 'pilish-gui-test-session-active-p)
               (lambda () t))
              ((symbol-function 'pilish-gui-test--current-session-options)
               (lambda () options))
              ((symbol-function 'pilish-gui-test--session-matches-p)
               (lambda (actual-options)
                 (should (equal actual-options options))
                 t))
              ((symbol-function 'pilish-gui-test-ensure-layout)
               (lambda () 'layout-ok)))
      (should (eq (pilish-gui-test-ensure-session) 'layout-ok)))))

(ert-deftest pilish-gui-test-utils-test-select-tests-rejects-zero-matches ()
  (let* ((selector "pilish-gui-test-definitely-no-such-test")
         (error (should-error
                 (pilish-gui-test--select-tests-or-error selector)
                 :type 'user-error)))
    (should (string-match-p (regexp-quote selector)
                            (error-message-string error)))))

(ert-deftest pilish-gui-test-utils-test-select-tests-returns-matches ()
  (let* ((name 'pilish-gui-test-utils-test-select-tests-returns-matches)
         (tests (pilish-gui-test--select-tests-or-error (symbol-name name))))
    (should (= 1 (length tests)))
    (should (eq name (ert-test-name (car tests))))))

(provide 'pilish-gui-test-utils-test)
;;; pilish-gui-test-utils-test.el ends here
