;;; pilish-build.el --- Batch helpers for local build tasks -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel Nouri

;; Author: Daniel Nouri <daniel.nouri@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Helpers shared by batch scripts used from the Makefile and CI.
;; Keep build-specific behavior here so it is easy to test with ERT.

;;; Code:

(require 'cl-lib)
(require 'lisp-mnt)
(require 'package)
(require 'treesit)

(defvar pilish-grammar-recipes nil
  "Grammar recipes provided by `pilish-grammars'.")

(defconst pilish-build-main-file
  (expand-file-name "../pilish.el"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Path to the package entry point used as build metadata source of truth.")

(defun pilish-build--version-string (version)
  "Return VERSION list as a dotted string."
  (mapconcat #'number-to-string version "."))

(defun pilish-build--read-package-requires ()
  "Return the `Package-Requires' header from the current buffer."
  (if (fboundp 'lm-package-requires)
      (lm-package-requires)
    (let ((header (lm-header "package-requires")))
      (unless header
        (error "Missing Package-Requires header in %s"
               pilish-build-main-file))
      (car (read-from-string header)))))

(defun pilish-build-package-requirements ()
  "Return non-Emacs package requirements from `pilish.el'."
  (mapcar (pcase-lambda (`(,package ,version))
            (cons package (version-to-list version)))
          (cl-remove-if (lambda (requirement)
                          (eq (car requirement) 'emacs))
                        (with-temp-buffer
                          (insert-file-contents pilish-build-main-file)
                          (pilish-build--read-package-requires)))))

(defconst pilish-build-test-requirements
  '((evil . (1 14)) (evil-snipe . (0)))
  "Development-only packages exercised by the test suite.
These are installed by `pilish-build-install-deps' alongside the
package requirements but never appear in `Package-Requires': Evil is
an optional integration that must keep building and loading without
it, and `test/pilish-evil-test.el' skips its cases when it is
absent.  evil-snipe covers the minor-mode keymap precedence the
browser bindings must overcome.  Explicit REQUIREMENTS arguments to
`pilish-build-install-deps' override this list.")

(defun pilish-build--package-missing-p (package min-version)
  "Return non-nil when PACKAGE does not satisfy MIN-VERSION."
  (not (package-installed-p package min-version)))

(defun pilish-build-install-deps (&optional requirements)
  "Install package REQUIREMENTS for local development.
REQUIREMENTS defaults to `pilish-build-package-requirements' plus
`pilish-build-test-requirements'.
Signals an error if any dependency still does not satisfy its minimum
version after installation finishes."
  (let ((requirements (or requirements
                           (append (pilish-build-package-requirements)
                                   pilish-build-test-requirements)))
        (missing nil))
    (setq package-install-upgrade-built-in t)
    (add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
    ;; MELPA's transient needs compat >= 31, which is published on
    ;; GNU ELPA only; without this archive a cold dependency install
    ;; fails with "Package 'compat' is unavailable".
    (add-to-list 'package-archives '("gnu" . "https://elpa.gnu.org/packages/") t)
    (package-initialize)
    (unless package-archive-contents
      (package-refresh-contents))
    (dolist (requirement requirements)
      (pcase-let ((`(,package . ,min-version) requirement))
        (when (pilish-build--package-missing-p package min-version)
          (message "Installing dependency %s >= %s..."
                   package
                   (pilish-build--version-string min-version))
          (package-install package))))
    (dolist (requirement requirements)
      (pcase-let ((`(,package . ,min-version) requirement))
        (when (pilish-build--package-missing-p package min-version)
          (push (format "%s >= %s"
                        package
                        (pilish-build--version-string min-version))
                missing))))
    (when missing
      (error "Dependency install failed: %s"
             (mapconcat #'identity (nreverse missing) ", ")))
    (message "Dependencies installed")
    t))

(defun pilish-build--default-grammars ()
  "Return all grammars needed by Pilish."
  (require 'pilish-grammars)
  (mapcar #'car pilish-grammar-recipes))

(defun pilish-build-install-grammars (&optional grammars)
  "Install tree-sitter GRAMMARS used by Pilish.
GRAMMARS defaults to all recipes from `pilish-grammar-recipes'.
Returns a plist with counts for already installed, newly installed,
failed, and total grammars.  Signals an error if any grammar fails."
  (let* ((grammars (or grammars (pilish-build--default-grammars)))
         (already-installed 0)
         (installed 0)
         (failed 0)
         (failed-grammars nil)
         (result nil))
    (dolist (lang grammars)
      (if (treesit-language-available-p lang)
          (progn
            (message "Grammar %s: already installed" lang)
            (cl-incf already-installed))
        (message "Grammar %s: installing..." lang)
        (condition-case err
            (progn
              (treesit-install-language-grammar lang)
              (if (treesit-language-available-p lang)
                  (progn
                    (message "Grammar %s: installed successfully" lang)
                    (cl-incf installed))
                (message "Grammar %s: install returned but grammar not available" lang)
                (push lang failed-grammars)
                (cl-incf failed)))
          (error
           (message "Grammar %s: FAILED - %s" lang (error-message-string err))
           (push lang failed-grammars)
           (cl-incf failed)))))
    (setq result (list :already-installed already-installed
                       :installed installed
                       :failed failed
                       :total (length grammars)))
    (message "Grammars: already ready %d, installed %d, failed %d, total %d"
             already-installed installed failed (length grammars))
    (when failed-grammars
      (error "Grammar install failed: %s"
             (mapconcat #'symbol-name (nreverse failed-grammars) ", ")))
    result))

(provide 'pilish-build)
;;; pilish-build.el ends here
