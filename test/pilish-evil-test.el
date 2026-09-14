;;; pilish-evil-test.el --- Tests for pilish-evil -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel Nouri

;; Author: Daniel Nouri <daniel.nouri@gmail.com>

;;; Commentary:

;; Tests for the optional Evil integration: initial states, keymap
;; registrations, and the copy-raw-markdown default.  All tests are
;; skipped when Evil is not installed.

;;; Code:

(require 'ert)
(require 'pilish)
(when (require 'evil nil t)
  (require 'pilish-evil)
  ;; Requiring `pilish-evil' runs `pilish-evil-setup' at load time,
  ;; which installs global mode hooks.  The suite's default-behavior
  ;; tests (for example kill-ring stripping) must observe the
  ;; non-Evil defaults, so undo the copy-raw-markdown hook; every
  ;; test below re-runs `pilish-evil-setup' inside
  ;; `pilish-evil-test--with-evil', which snapshots the hooks.
  (remove-hook 'pilish-chat-mode-hook
               #'pilish-evil--copy-raw-markdown-in-chat))

;; Mark evil-snipe's hook variables special before any test code runs.
;; `add-hook' in `pilish-evil-setup' gives them global values without
;; declaring them special, so under this file's lexical binding the
;; `let' snapshot in `pilish-evil-test--with-evil' would bind them
;; lexically instead — and loading evil-snipe.elc inside that scope
;; then errors with "Defining as dynamic an already lexical var"
;; when its first real `defvar' executes.  `defvar' on already-bound
;; variables only marks them special, so this is safe either way.
(defvar evil-snipe-local-mode-hook nil)
(defvar evil-snipe-override-local-mode-hook nil)

(defmacro pilish-evil-test--with-evil (&rest body)
  "Skip the test when Evil is unavailable, else run BODY.
`pilish-evil-setup' installs global mode hooks (copy-raw-markdown,
snipe disabling); snapshot them so one test cannot pollute the rest
of the suite."
  (declare (indent 0) (debug t))
  `(if (not (featurep 'evil))
       (ert-skip "Evil not installed")
     (let ((pilish-chat-mode-hook pilish-chat-mode-hook)
           (evil-snipe-local-mode-hook evil-snipe-local-mode-hook)
           (evil-snipe-override-local-mode-hook
            evil-snipe-override-local-mode-hook))
       ,@body)))

(ert-deftest pilish-evil-test-initial-states ()
  "Chat buffers start in motion state, input buffers in insert state."
  (pilish-evil-test--with-evil
   (pilish-evil-setup)
   (should (eq (evil-initial-state 'pilish-chat-mode)
               pilish-evil-chat-state))
   (should (eq (evil-initial-state 'pilish-input-mode)
               pilish-evil-input-state))))

(ert-deftest pilish-evil-test-chat-motion-bindings ()
  "Motion state bindings in the chat buffer."
  (pilish-evil-test--with-evil
   (pilish-evil-setup)
   (let ((map (evil-get-auxiliary-keymap pilish-chat-mode-map
                                         'motion)))
     (should map)
     (should (eq (lookup-key map "n") #'pilish-next-message))
     (should (eq (lookup-key map "p") #'pilish-previous-message))
     (should (eq (lookup-key map "f") #'pilish-fork-at-point))
     (should (eq (lookup-key map "w") #'pilish-copy-file-reference))
     (should (eq (lookup-key map "?") #'pilish-menu))
     (should (eq (lookup-key map "q") #'pilish-quit))
     (should (eq (lookup-key map "i") #'pilish-evil-insert-input))
     (should (eq (lookup-key map "a") #'pilish-evil-append-input))
     (should (eq (lookup-key map (kbd "RET")) #'pilish-visit-file))
     (should (eq (lookup-key map (kbd "TAB"))
                 #'pilish-toggle-tool-section))
     (should (eq (lookup-key map [tab])
                 #'pilish-toggle-tool-section)))))

(ert-deftest pilish-evil-test-browse-initial-states ()
  "Browser buffers start in the configured browse state."
  (pilish-evil-test--with-evil
   (pilish-evil-setup)
   (dolist (mode '(pilish-browse-mode
                   pilish-session-browser-mode
                   pilish-tree-browser-mode))
     (should (eq (evil-initial-state mode)
                 pilish-evil-browse-state)))))

(ert-deftest pilish-evil-test-session-browser-motion-bindings ()
  "Motion state reclaims the documented session browser keys."
  (pilish-evil-test--with-evil
   (pilish-evil-setup)
   (let ((map (evil-get-auxiliary-keymap pilish-session-browser-mode-map
                                         'motion)))
     (should map)
     (should (eq (lookup-key map "s")
                 #'pilish-session-browser-cycle-sort))
     (should (eq (lookup-key map "f")
                 #'pilish-session-browser-toggle-named))
     (should (eq (lookup-key map "t")
                 #'pilish-session-browser-toggle-scope))
     (should (eq (lookup-key map "/")
                 #'pilish-session-browser-search))
     (should (eq (lookup-key map "r")
                 #'pilish-session-browser-rename))
     (should (eq (lookup-key map "d")
                 #'pilish-session-browser-delete))
     (should (eq (lookup-key map "?")
                 #'pilish-session-browser-dispatch))
     (should (eq (lookup-key map "h")
                 #'pilish-session-browser-dispatch))
     (should (eq (lookup-key map "g") #'pilish-browse-refresh))
     (should (eq (lookup-key map "q") #'quit-window))
     (should (eq (lookup-key map (kbd "RET"))
                 #'pilish-session-browser-switch)))))

(ert-deftest pilish-evil-test-tree-browser-motion-bindings ()
  "Motion state reclaims the documented tree browser keys."
  (pilish-evil-test--with-evil
   (pilish-evil-setup)
   (let ((map (evil-get-auxiliary-keymap pilish-tree-browser-mode-map
                                         'motion)))
     (should map)
     (should (eq (lookup-key map "f")
                 #'pilish-tree-browser-cycle-filter))
     (should (eq (lookup-key map "l")
                 #'pilish-tree-browser-set-label))
     (should (eq (lookup-key map "/")
                 #'pilish-tree-browser-search))
     (should (eq (lookup-key map "?")
                 #'pilish-tree-browser-dispatch))
     (should (eq (lookup-key map "h")
                 #'pilish-tree-browser-dispatch))
     (should (eq (lookup-key map "g") #'pilish-browse-refresh))
     (should (eq (lookup-key map "q") #'quit-window))
     (should (eq (lookup-key map (kbd "RET"))
                 #'pilish-tree-browser-navigate)))))

(ert-deftest pilish-evil-test-input-normal-bindings ()
  "Normal state bindings in the input buffer."
  (pilish-evil-test--with-evil
   (pilish-evil-setup)
   (let ((map (evil-get-auxiliary-keymap pilish-input-mode-map
                                         'normal)))
     (should map)
     (should (eq (lookup-key map (kbd "RET")) #'pilish-send))
     (should (eq (lookup-key map "q") #'pilish-evil-close-input))
     (should (eq (lookup-key map "?") #'pilish-menu)))))

(ert-deftest pilish-evil-test-copy-raw-markdown-default ()
  "Setup copies raw markdown buffer-locally in chat buffers by default."
  (pilish-evil-test--with-evil
   (let ((pilish-chat-mode-hook nil))
     (pilish-evil-setup)
     (should (memq #'pilish-evil--copy-raw-markdown-in-chat
                   pilish-chat-mode-hook)))
   (with-temp-buffer
     (pilish-evil--copy-raw-markdown-in-chat)
     (should (and (local-variable-p 'pilish-copy-raw-markdown)
                  pilish-copy-raw-markdown)))))

(ert-deftest pilish-evil-test-enter-input-state-respects-option ()
  "Focusing the input window enters `pilish-evil-input-state'."
  (pilish-evil-test--with-evil
   (dolist (state '(insert normal emacs))
     (let ((pilish-evil-input-state state))
       (with-temp-buffer
         (evil-local-mode 1)
         (pilish-evil--enter-input-state)
         (should (eq evil-state state)))))))

(ert-deftest pilish-evil-test-snipe-disabled-in-chat ()
  "Setup hooks snipe disablement, which turns snipe off in chat buffers."
  (pilish-evil-test--with-evil
   (pilish-evil-setup)
   (should (memq #'pilish-evil--maybe-disable-snipe
                 (default-value 'evil-snipe-local-mode-hook)))
   (should (memq #'pilish-evil--maybe-disable-snipe
                 (default-value 'evil-snipe-override-local-mode-hook)))))

(ert-deftest pilish-evil-test-snipe-hook-disables-in-chat ()
  "The snipe hook turns snipe off in chat buffers only."
  (pilish-evil-test--with-evil
   (skip-unless (require 'evil-snipe nil t))
   (with-temp-buffer
     (evil-snipe-local-mode 1)
     (evil-snipe-override-local-mode 1)
     (setq major-mode 'pilish-chat-mode)
     (pilish-evil--maybe-disable-snipe)
     (should-not evil-snipe-local-mode)
     (should-not evil-snipe-override-local-mode))
   (with-temp-buffer
     (evil-snipe-local-mode 1)
     (evil-snipe-override-local-mode 1)
     (setq major-mode 'text-mode)
     (pilish-evil--maybe-disable-snipe)
     (should evil-snipe-local-mode)
     (should evil-snipe-override-local-mode))))

(ert-deftest pilish-evil-test-snipe-hook-disables-in-browse-buffers ()
  "The snipe hook turns snipe off in both browser modes."
  (pilish-evil-test--with-evil
   (skip-unless (require 'evil-snipe nil t))
   (dolist (mode '(pilish-session-browser-mode pilish-tree-browser-mode))
     (with-temp-buffer
       (evil-snipe-local-mode 1)
       (evil-snipe-override-local-mode 1)
       (setq major-mode mode)
       (pilish-evil--maybe-disable-snipe)
       (should-not evil-snipe-local-mode)
       (should-not evil-snipe-override-local-mode)))))

(ert-deftest pilish-evil-test-copy-raw-markdown-opt-out ()
  "Setup does not add the chat mode hook when opted out."
  (pilish-evil-test--with-evil
   (let ((pilish-evil-copy-raw-markdown nil)
         (pilish-chat-mode-hook nil))
     (pilish-evil-setup)
     (should-not (memq #'pilish-evil--copy-raw-markdown-in-chat
                       pilish-chat-mode-hook)))))

(provide 'pilish-evil-test)
;;; pilish-evil-test.el ends here
