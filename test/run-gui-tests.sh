#!/usr/bin/env bash
# run-gui-tests.sh - Run the deterministic fake-backed GUI ERT suite
#
# No Docker, Ollama, or real pi install is required.  The suite still uses a
# real Emacs frame/window environment and the normal subprocess seam.
#
# Usage:
#   ./test/run-gui-tests.sh [options] [test-selector]
#
# Options:
#   --headless   Force headless mode (uses xvfb-run)
#
# Environment:
#   PI_HEADLESS=1   Same as --headless
#
# Examples:
#   ./test/run-gui-tests.sh                        # Run with display
#   ./test/run-gui-tests.sh --headless             # Run headless
#   ./test/run-gui-tests.sh pilish-gui-test-session    # Run one GUI test

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

HEADLESS="${PI_HEADLESS:-0}"
EMACS_BIN="${EMACS:-emacs}"
if [ -z "${PACKAGE_USER_DIR:-}" ]; then
    EMACS_MAJOR_VERSION=$("$EMACS_BIN" --batch -Q \
        --eval '(princ emacs-major-version)')
    export PACKAGE_USER_DIR="$PROJECT_DIR/.cache/elpa/$EMACS_MAJOR_VERSION"
fi
SELECTOR="\"pilish-gui-test-\""

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --headless) HEADLESS=1; shift ;;
        *) SELECTOR="\"$1\""; shift ;;
    esac
done

# Auto-detect headless if no display available
if [ "$HEADLESS" != "1" ] && [ -z "$DISPLAY" ]; then
    HEADLESS=1
fi

WIDTH=80
HEIGHT=22
RESULTS_FILE=$(mktemp /tmp/ert-results.XXXXXX)
RUNNER_FILE=$(mktemp /tmp/run-gui-tests.XXXXXX.el)
trap 'rm -f "$RESULTS_FILE" "$RUNNER_FILE"' EXIT

echo "=== Pi.el GUI Tests ==="
echo "Project: $PROJECT_DIR"
echo "Selector: $SELECTOR"
if [ "$HEADLESS" = "1" ]; then
    echo "Mode: headless (xvfb)"
else
    echo "Mode: display"
fi
echo ""

# Create elisp to run tests
cat > "$RUNNER_FILE" << 'ELISP_END'
;; Setup
(setq inhibit-startup-screen t)
(setq load-prefer-newer t)
ELISP_END

cat >> "$RUNNER_FILE" << EOF
(set-frame-size (selected-frame) $WIDTH $HEIGHT)
(add-to-list 'load-path "$PROJECT_DIR")
(add-to-list 'load-path "$PROJECT_DIR/test")

;; Initialize the same project-local packages as the parent test lane.
(require 'package)
(let ((dir (getenv "PACKAGE_USER_DIR")))
  (when dir
    (setq package-user-dir
          (directory-file-name (expand-file-name dir)))))
(push '("melpa" . "https://melpa.org/packages/") package-archives)
(package-initialize)

;; Load test utilities and tests
(require 'pilish-gui-test-utils)
(require 'pilish-gui-tests)

;; Redirect messages to file for results
(defvar pilish-gui-test--output-file "$RESULTS_FILE")

;; Helper to print to stderr immediately (unbuffered, works in non-batch mode)
(defun pilish-gui-test--log (fmt &rest args)
  "Print formatted message to stderr immediately."
  (princ (concat (apply #'format fmt args) "\n") #'external-debugging-output))

;; Run tests and collect results
;; Order tests: session-starts first, then alphabetically
(defun pilish-gui-test--order-tests (tests)
  "Order TESTS so session-starts runs first."
  (let (first-test rest-tests)
    (dolist (test tests)
      (if (eq (ert-test-name test) 'pilish-gui-test-session-starts)
          (setq first-test test)
        (push test rest-tests)))
    (if first-test
        (cons first-test (nreverse rest-tests))
      (nreverse rest-tests))))

(let* ((selector $SELECTOR)
       (passed 0)
       (skipped 0)
       (failed 0)
       (total 0)
       (test-list (pilish-gui-test--order-tests (ert-select-tests selector t))))
  (setq total (length test-list))
  (pilish-gui-test--log "Running %d GUI tests..." total)
  (with-temp-buffer
    (insert "=== GUI Test Results ===\n\n")
    (let ((n 0))
      (dolist (test test-list)
        ;; Reset per test so a later failure cannot print a stale earlier
        ;; snapshot; sessionless tests never capture one.
        (setq pilish-gui-test--failure-snapshot nil)
        (let* ((name (ert-test-name test))
               (start (float-time))
               (result (ert-run-test test))
               (elapsed (pilish-test-format-elapsed (- (float-time) start))))
          (setq n (1+ n))
          (cond
           ((ert-test-passed-p result)
            (setq passed (1+ passed))
            (pilish-gui-test--log "  [%d/%d] PASS: %s (%s)" n total name elapsed)
            (insert (format "  PASS: %s (%s)\n" name elapsed)))
           ((ert-test-skipped-p result)
            (setq skipped (1+ skipped))
            (let ((reason
                   (error-message-string
                    (ert-test-result-with-condition-condition result))))
              (pilish-gui-test--log
               "  [%d/%d] SKIP: %s (%s): %s" n total name elapsed reason)
              (insert (format "  SKIP: %s (%s): %s\n" name elapsed reason))))
           (t
            (setq failed (1+ failed))
            (pilish-gui-test--log "  [%d/%d] FAIL: %s (%s)" n total name elapsed)
            (insert (format "  FAIL: %s (%s)\n" name elapsed))
            (when (ert-test-failed-p result)
              (insert (format "        %S\n" (ert-test-result-with-condition-condition result))))
            ;; Debug: print diagnostic info on failure
            (when (and (boundp 'pilish-gui-test--session) pilish-gui-test--session)
              (pilish-gui-test--log "  --- Session config ---")
              (pilish-gui-test--log "  Backend: %s"
                                (plist-get (plist-get pilish-gui-test--session :backend)
                                           :label))
              (pilish-gui-test--log "  Options: %S"
                                (plist-get pilish-gui-test--session :options))
              ;; Process status
              (when-let ((proc (plist-get pilish-gui-test--session :process)))
                (pilish-gui-test--log "  --- Process status ---")
                (pilish-gui-test--log "  Status: %s, Exit: %s"
                                  (process-status proc) (process-exit-status proc))
                (pilish-gui-test--log "  Events: %s, Last event: %S"
                                  (or (process-get proc 'pilish-gui-test-event-count) 0)
                                  (process-get proc 'pilish-gui-test-last-event)))
              ;; Chat buffer content
              (when-let ((chat-buf (plist-get pilish-gui-test--session :chat-buffer)))
                (when (buffer-live-p chat-buf)
                  (pilish-gui-test--log "  --- Chat buffer content ---")
                  (pilish-gui-test--log "%s" (with-current-buffer chat-buf (buffer-string)))
                  (pilish-gui-test--log "  --- End chat buffer ---"))))
            ;; Fresh-session failures unwind the session before the live
            ;; diagnostics above can run; print the pre-teardown snapshot.
            (when (and (boundp 'pilish-gui-test--failure-snapshot)
                       pilish-gui-test--failure-snapshot
                       (not (and (boundp 'pilish-gui-test--session)
                                 (pilish-gui-test-session-active-p))))
              (pilish-gui-test--log "  --- Pre-teardown snapshot ---")
              (pilish-gui-test--log "%s" pilish-gui-test--failure-snapshot)))))))
    (insert (format "\n=== %d tests: %d passed, %d skipped, %d failed ===\n"
                    total passed skipped failed))
    (write-region (point-min) (point-max) pilish-gui-test--output-file))
  (pilish-gui-test--log
   "=== %d tests: %d passed, %d skipped, %d failed ==="
   total passed skipped failed)
  (kill-emacs (if (> failed 0) 1 0)))
EOF

# Run Emacs (not in batch mode - we need GUI)
# Temporarily disable set -e since Emacs returns non-zero on test failure
set +e
if [ "$HEADLESS" = "1" ]; then
    # GDK_BACKEND=x11 forces GTK/PGTK to use X11 instead of auto-detecting Wayland
    # </dev/null prevents "standard input is not a tty" error in CI
    xvfb-run -a env GDK_BACKEND=x11 PATH="$PATH" \
        "$EMACS_BIN" -Q -l "$RUNNER_FILE" </dev/null 2>&1
else
    "$EMACS_BIN" -Q -l "$RUNNER_FILE" 2>&1
fi
EXIT_CODE=$?
set -e

# Show results
if [[ -f "$RESULTS_FILE" ]]; then
    cat "$RESULTS_FILE"
fi

exit $EXIT_CODE
