;;; pilish-build-test.el --- Tests for batch build helpers -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)

(defconst pilish-test-build--repo-root
  (expand-file-name ".." (file-name-directory load-file-name))
  "Repository root used by build script tests.")

(load (expand-file-name "scripts/pilish-build.el"
                        pilish-test-build--repo-root)
      t t)

(ert-deftest pilish-test-build-package-requirements-follow-package-header ()
  "Read dependency versions from the package header, excluding Emacs itself."
  (should (equal '((transient . (0 9 0))
                   (magit-section . (4 0 0))
                   (md-ts-mode . (0 3 0))
                   (markdown-table-wrap . (0 2 0)))
                 (pilish-build-package-requirements))))

(ert-deftest pilish-test-build-package-requirements-fallback-without-lm-package-requires ()
  "Read package requirements even when `lm-package-requires' is unavailable."
  (let ((pilish-build-main-file
         (make-temp-file "pilish-build" nil ".el"
                         ";;; demo.el --- demo -*- lexical-binding: t; -*-\n\
;; Package-Requires: ((emacs \"29.1\") (transient \"0.9.0\"))\n")))
    (unwind-protect
        (cl-letf (((symbol-function 'lm-package-requires) nil))
          (should (equal '((transient . (0 9 0)))
                         (pilish-build-package-requirements))))
      (delete-file pilish-build-main-file))))

(ert-deftest pilish-test-build-install-deps-installs-missing-or-outdated-packages ()
  "Install only package dependencies that are missing or too old."
  (let ((package-install-upgrade-built-in nil)
        (package-archives nil)
        (package-archive-contents nil)
        (refreshed nil)
        (installed nil)
        (installed-state '((transient . nil)
                           (md-ts-mode . t))))
    (cl-letf (((symbol-function 'package-initialize) #'ignore)
              ((symbol-function 'package-refresh-contents)
               (lambda ()
                 (setq refreshed t)
                 (setq package-archive-contents '((transient) (md-ts-mode)))))
              ((symbol-function 'package-installed-p)
               (lambda (package &optional _min-version)
                 (alist-get package installed-state)))
              ((symbol-function 'package-install)
               (lambda (package)
                 (push package installed)
                 (setf (alist-get package installed-state) t))))
      (pilish-build-install-deps
       '((transient . (0 9 0))
         (md-ts-mode . (0 3 0))))
      (should package-install-upgrade-built-in)
      (should refreshed)
      (should (equal '(transient) (nreverse installed)))
      (should (member '("melpa" . "https://melpa.org/packages/")
                      package-archives)))))

(ert-deftest pilish-test-build-install-deps-errors-when-dependency-stays-missing ()
  "Signal an error when a required dependency is still unavailable."
  (let ((package-archives nil)
        (package-archive-contents '(dummy))
        (message-text nil))
    (cl-letf (((symbol-function 'package-initialize) #'ignore)
              ((symbol-function 'package-refresh-contents) #'ignore)
              ((symbol-function 'package-installed-p)
               (lambda (package &optional _min-version)
                 (eq package 'transient)))
              ((symbol-function 'package-install)
               (lambda (_package) nil)))
      (setq message-text
            (condition-case err
                (progn
                  (pilish-build-install-deps
                   '((transient . (0 9 0))
                     (md-ts-mode . (0 3 0))))
                  nil)
              (error (error-message-string err))))
      (should (string-match-p "md-ts-mode" message-text)))))

(ert-deftest pilish-test-build-install-grammars-reports-ready-and-installed-counts ()
  "Count already-ready and newly installed grammars separately."
  (let ((available '(markdown))
        (installed nil)
        (messages nil))
    (cl-letf (((symbol-function 'treesit-language-available-p)
               (lambda (lang &rest _)
                 (memq lang available)))
              ((symbol-function 'treesit-install-language-grammar)
               (lambda (lang &optional _out-dir)
                 (push lang installed)
                 (push lang available)))
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) messages))))
      (let ((result (pilish-build-install-grammars '(markdown bash javascript))))
        (should (equal '(:already-installed 1 :installed 2 :failed 0 :total 3)
                       result))
        (should (equal '(bash javascript)
                       (sort installed
                             (lambda (left right)
                               (string-lessp (symbol-name left)
                                             (symbol-name right))))))
        (should (string-match-p "already ready 1, installed 2, failed 0, total 3"
                                (car messages)))))))

(ert-deftest pilish-test-build-install-grammars-errors-when-a-grammar-fails ()
  "Signal an error when any requested grammar cannot be installed."
  (let ((available nil)
        (messages nil)
        (error-text nil))
    (cl-letf (((symbol-function 'treesit-language-available-p)
               (lambda (lang &rest _)
                 (memq lang available)))
              ((symbol-function 'treesit-install-language-grammar)
               (lambda (_lang &optional _out-dir) nil))
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) messages))))
      (setq error-text
            (condition-case err
                (progn
                  (pilish-build-install-grammars '(markdown))
                  nil)
              (error (error-message-string err))))
      (should (string-match-p "markdown" error-text))
      (should (string-match-p "failed 1" (car messages))))))

(ert-deftest pilish-test-build-scripts-byte-compile-cleanly ()
  "Build helper and wrapper scripts byte-compile without warnings."
  (let* ((emacs (expand-file-name invocation-name invocation-directory))
         (scripts-dir (expand-file-name "scripts"
                                        pilish-test-build--repo-root))
         (output-buffer (generate-new-buffer " *pilish-build-compile*"))
         (exit-code
          (call-process emacs nil output-buffer nil
                        "--batch" "-Q"
                        "-L" pilish-test-build--repo-root
                        "-L" scripts-dir
                        "--eval" "(require 'package)"
                        "--eval"
                        "(let ((dir (getenv \"PACKAGE_USER_DIR\")))\n  (when dir\n    (setq package-user-dir\n          (directory-file-name (expand-file-name dir)))))"
                        "--eval" "(package-initialize)"
                        "--eval"
                        (format "(setq load-path (cons %S load-path))"
                                pilish-test-build--repo-root)
                        "--eval" "(setq byte-compile-error-on-warn t)"
                        "-f" "batch-byte-compile"
                        (expand-file-name "scripts/pilish-build.el"
                                          pilish-test-build--repo-root)
                        (expand-file-name "scripts/install-deps.el"
                                          pilish-test-build--repo-root)
                        (expand-file-name "scripts/install-ts-grammars.el"
                                          pilish-test-build--repo-root))))
    (unwind-protect
        (progn
          (should (eq 0 exit-code))
          (with-current-buffer output-buffer
            (should (equal "" (buffer-string)))))
      (kill-buffer output-buffer)
      (dolist (elc '("scripts/pilish-build.elc"
                     "scripts/install-deps.elc"
                     "scripts/install-ts-grammars.elc"))
        (let ((path (expand-file-name elc pilish-test-build--repo-root)))
          (when (file-exists-p path)
            (delete-file path)))))))

(ert-deftest pilish-test-build-install-deps-script-delegates-to-helper ()
  "The dependency install wrapper should call the shared build helper."
  (let ((called nil))
    (cl-letf (((symbol-function 'pilish-build-install-deps)
               (lambda (&rest _)
                 (setq called t)
                 t)))
      (load (expand-file-name "scripts/install-deps.el"
                              pilish-test-build--repo-root)
            nil t)
      (should called))))

(ert-deftest pilish-test-build-install-ts-grammars-script-delegates-to-helper ()
  "The grammar install wrapper should call the shared build helper."
  (let ((called nil))
    (cl-letf (((symbol-function 'pilish-build-install-grammars)
               (lambda (&rest _)
                 (setq called t)
                 t)))
      (load (expand-file-name "scripts/install-ts-grammars.el"
                              pilish-test-build--repo-root)
            nil t)
      (should called))))

;;;; Packaging invariants (MELPA recipe / melpazoid CI / shipped asset)

(defconst pilish-test-build--logo-asset "assets/pilish-logo.svg"
  "Canonical runtime path of the logo, relative to the package root.
Single source of truth for the packaging tests: the MELPA recipe and the
melpazoid CI recipe must map this file unflattened so that the installed
`pilish--logo-file' resolves beside the installed libraries.")

(ert-deftest pilish-test-build-logo-asset-present ()
  "The logo asset ships at the canonical path with the adaptation contract."
  (let ((asset (expand-file-name pilish-test-build--logo-asset
                                 pilish-test-build--repo-root)))
    (should (file-exists-p asset))
    (with-temp-buffer
      (insert-file-contents asset)
      ;; The runtime adapter (`pilish--logo-svg-data') rewrites exactly
      ;; these fills; a regenerated asset must keep the same contract.
      (should (= 1 (how-many "fill=\"#07100F\"" (point-min) (point-max))))
      (should (= 3 (how-many "fill=\"#EEF2E8\"" (point-min) (point-max))))
      (should (= 2 (how-many "fill=\"#A970FF\"" (point-min) (point-max)))))))

(ert-deftest pilish-test-build-recipe-files-mapping ()
  "The melpazoid CI recipe maps the logo unflattened into the install root.
MELPA's default file set omits `assets/'; the recipe therefore appends a
files mapping that must keep the subdirectory (a bare glob would flatten
the directory and break `pilish--logo-file' on package installs)."
  (let* ((workflow (expand-file-name ".github/workflows/melpazoid.yml"
                                     pilish-test-build--repo-root))
         (recipe (with-temp-buffer
                   (skip-unless (file-exists-p workflow))
                   (insert-file-contents workflow)
                   (goto-char (point-min))
                   (should (re-search-forward "^\\s-*RECIPE:\\s-+" nil t))
                   (read (current-buffer))))
         (files (plist-get (cdr recipe) :files))
         covered)
    (should (eq (car recipe) 'pilish))
    ;; `:defaults' must stay the first element of the files spec.
    (should (eq (car files) :defaults))
    (dolist (entry (cdr files))
      (pcase-exhaustive entry
        ;; A bare string entry is copied to the package root, flattening
        ;; any subdirectory; the mapping must use (TARGET-DIR SOURCE...).
        ((pred stringp) (should-not entry))
        (`(,dest . ,sources)
         (dolist (src sources)
           ;; Anti-flatten: the destination directory equals the source
           ;; file's own directory, so the installed path is unchanged.
           (should (string-equal (file-name-as-directory dest)
                                 (or (file-name-directory src) "")))
           ;; The mapped source must exist in the repository.
           (should (file-exists-p
                    (expand-file-name src pilish-test-build--repo-root)))
           (when (string-equal src pilish-test-build--logo-asset)
             (setq covered t))))))
    (should covered)))

(provide 'pilish-build-test)
;;; pilish-build-test.el ends here
