;;; pilish-tool-md-ts-bench.el --- Wall-time benchmark for uncovered tool rewrites -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel Nouri

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Wall-time benchmark for the tool-rendering rewrites that suspend md-ts's
;; expensive stale-side-effect change hook:
;;
;;   - compound (codemode) tool redraw  `pilish--redraw-compound-tool'
;;   - completed tool body toggle       `pilish--toggle-tool-output'
;;   - completed thinking rewrite       `pilish--replace-thinking-block-region'
;;   - completed tool block cooling     `pilish--cool-tool-overlay'
;;
;; Master already suspends the hook around history replay, stream-delta
;; flushes, and the toolcall stream/reconcile/execution-start paths, and live
;; tool previews no longer rewrite Markdown fences.  This benchmark measures
;; the wall time of the paths those fixes do not cover, so the remaining
;; benefit of suspending the hook there can be judged instead of assumed.
;;
;; The benchmark is synthetic and in-process: it builds a large chat
;; transcript, drives each rewrite, and reports per-operation wall time
;; (min/median/mean/p95/max).  It fails on correctness violations (missing
;; rendered content, buffer growth, deleted overlay), not on timing
;; thresholds.  Each repetition uses a fresh buffer, and `gc-cons-threshold'
;; is raised for the run, so the numbers reflect the rewrite rather than
;; accumulated state or collector pauses.
;;
;; Run with:
;;
;;   bench/run-tool-md-ts-bench.sh              # GUI via xvfb (primary lane)
;;   bench/run-tool-md-ts-bench.sh --batch      # batch (secondary lane)
;;   bench/run-tool-md-ts-bench.sh --smoke      # cheap correctness smoke
;;
;; Compare revisions by running the same runner on each checkout; for example:
;;
;;   bench/run-tool-md-ts-bench.sh --batch
;;   git checkout master -- pilish-render.el
;;   bench/run-tool-md-ts-bench.sh --batch
;;   git checkout HEAD -- pilish-render.el
;;
;; Artifacts are written under `tmp/tool-md-ts-bench/'.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defconst pilish-tmd-bench-repo-root
  (file-name-as-directory
   (expand-file-name ".."
                     (file-name-directory
                      (or load-file-name buffer-file-name default-directory))))
  "Repository root containing the benchmark files.")

(add-to-list 'load-path pilish-tmd-bench-repo-root)
(require 'pilish)

(defun pilish-tmd-bench--env (name default)
  "Return environment variable NAME, or DEFAULT when it is unset or empty."
  (let ((value (getenv name)))
    (if (and value (not (string-empty-p value))) value default)))

(defun pilish-tmd-bench--env-int (name default)
  "Return environment variable NAME as an integer, or DEFAULT."
  (string-to-number (pilish-tmd-bench--env name (number-to-string default))))

(defvar pilish-tmd-bench-sections
  (pilish-tmd-bench--env-int "PILISH_TMD_BENCH_SECTIONS" 1600)
  "Number of synthetic transcript sections to build before measuring.")

(defvar pilish-tmd-bench-iterations
  (pilish-tmd-bench--env-int "PILISH_TMD_BENCH_ITERATIONS" 30)
  "Timed iterations per repetition and scenario.")

(defvar pilish-tmd-bench-reps
  (pilish-tmd-bench--env-int "PILISH_TMD_BENCH_REPS" 3)
  "Repetitions (fresh buffers) per scenario.")

(defvar pilish-tmd-bench-out-dir
  (pilish-tmd-bench--env "PILISH_TMD_BENCH_OUT_DIR"
                         (expand-file-name "tmp/tool-md-ts-bench/"
                                           pilish-tmd-bench-repo-root))
  "Directory for benchmark artifacts.")

(defvar pilish-tmd-bench-lane
  (pilish-tmd-bench--env "PILISH_TMD_BENCH_LANE" "batch")
  "Lane label recorded in benchmark artifacts.")

;;;; Synthetic transcript

(defun pilish-tmd-bench--fill (sections)
  "Insert SECTIONS transcript sections into the current buffer."
  (let ((inhibit-read-only t))
    (dotimes (i sections)
      (insert (format "## Section %d\n\nSome paragraph text with `code` and a [link](https://example.com/%d) here.\n\n"
                      i i))
      (insert "```bash\necho hello\nsome output line\n```\n\n"))))

(defun pilish-tmd-bench--lines (n prefix)
  "Return N lines prefixed with PREFIX and joined by newlines."
  (mapconcat (lambda (i)
               (format "%s line %d with some extra content to make it long" prefix i))
             (number-sequence 0 (1- n)) "\n"))

(defun pilish-tmd-bench--chat-buffer (sections)
  "Set up a fresh chat buffer with SECTIONS transcript sections at the end."
  (let ((inhibit-read-only t))
    (pilish-chat-mode)
    (pilish-tmd-bench--fill sections)
    (insert "\n")))

;;;; Timing and statistics

(defun pilish-tmd-bench--measure (iterations op)
  "Return a list of wall milliseconds for ITERATIONS calls of OP.
Three warmup calls are made and discarded."
  (dotimes (_ 3) (funcall op))
  (let (times)
    (dotimes (_ iterations)
      (let ((start (float-time)))
        (funcall op)
        (push (* 1000.0 (- (float-time) start)) times)))
    (nreverse times)))

(defun pilish-tmd-bench--stats (times)
  "Return a plist of summary statistics for TIMES in milliseconds."
  (let* ((sorted (sort (copy-sequence times) #'<))
         (n (length sorted)))
    (list :min (nth 0 sorted)
          :median (nth (/ n 2) sorted)
          :mean (/ (apply #'+ sorted) (float n))
          :p95 (nth (min (1- n) (floor (* 0.95 n))) sorted)
          :max (nth (1- n) sorted)
          :n n)))

;;;; Scenarios

(defun pilish-tmd-bench--compound ()
  "Measure compound (codemode) tool redraw wall time.
Return (LABEL . MILLISECONDS), one fresh buffer per repetition."
  (let (times)
    (dotimes (_ pilish-tmd-bench-reps)
      (with-temp-buffer
        (pilish-tmd-bench--chat-buffer pilish-tmd-bench-sections)
        (let* ((calls (vconcat (cl-loop for i below 40
                                        collect (list :id (format "c%d" i) :name "read"
                                                      :status "ok" :args (make-string 40 ?a)
                                                      :durationMs 12 :cost 0.001))))
               (parent-text (pilish-tmd-bench--lines 200 "parent output")))
          (pilish--handle-display-event
           (list :type "tool_execution_start" :toolCallId "p" :toolName "codemode"
                 :args '(:code "return 1;")))
          (pilish--handle-display-event
           (list :type "tool_execution_end" :toolCallId "p" :toolName "codemode"
                 :isError nil
                 :result (list :content (vector (list :type "text" :text parent-text))
                               :details (list :calls calls))))
          (let ((block (pilish--nested-tool-owner "p")))
            (unless block
              (error "compound benchmark: codemode block was not created"))
            (let ((ov (pilish--tool-block-overlay block)))
              (setq times
                    (append times
                            (pilish-tmd-bench--measure
                             pilish-tmd-bench-iterations
                             (lambda () (pilish--redraw-compound-tool block)))))
              (unless (and (overlay-buffer ov)
                           (string-match-p "parent output line 0" (buffer-string)))
                (error "compound benchmark: compound body missing after redraw")))))))
    (cons "compound-redraw" times)))

(defun pilish-tmd-bench--toggle ()
  "Measure completed tool body toggle wall time.
Return (LABEL . MILLISECONDS), one fresh buffer per repetition."
  (let ((pilish-tool-preview-lines 5)
        times)
    (dotimes (_ pilish-tmd-bench-reps)
      (with-temp-buffer
        (pilish-tmd-bench--chat-buffer pilish-tmd-bench-sections)
        (let* ((block (pilish--display-tool-start "bash" '(:command "ls")))
               (ov (pilish--tool-block-overlay block)))
          (pilish--display-tool-end
           "bash" '(:command "ls")
           (list (list :type "text" :text (pilish-tmd-bench--lines 600 "tool output")))
           nil nil block)
          (setq times
                (append times
                        (pilish-tmd-bench--measure
                         pilish-tmd-bench-iterations
                         (lambda ()
                           (when-let* ((btn (pilish--find-toggle-button-in-region
                                             (overlay-start ov) (overlay-end ov))))
                             (pilish--toggle-tool-output btn))))))
          (unless (string-match-p "tool output line 0" (buffer-string))
            (error "toggle benchmark: tool body missing after toggles"))
          (unless (overlay-buffer ov)
            (error "toggle benchmark: tool overlay was deleted")))))
    (cons "tool-toggle" times)))

(defun pilish-tmd-bench--thinking ()
  "Measure completed thinking rewrite wall time.
Return (LABEL . MILLISECONDS), one fresh buffer per repetition."
  (let (times)
    (dotimes (_ pilish-tmd-bench-reps)
      (with-temp-buffer
        (pilish-tmd-bench--chat-buffer pilish-tmd-bench-sections)
        (let ((inhibit-read-only t) start end)
          (setq start (point))
          (insert "\n" (pilish-tmd-bench--lines 800 "thinking") "\n")
          (setq end (point))
          (let* ((rendered (concat "> "
                                   (replace-regexp-in-string
                                    "\n" "\n> " (pilish-tmd-bench--lines 800 "thinking"))
                                   "\n"))
                 (stable-size nil))
            (setq times
                  (append times
                          (pilish-tmd-bench--measure
                           pilish-tmd-bench-iterations
                           (lambda ()
                             ;; Rewrite exactly the current block: the
                             ;; rendered text is longer than the source, so
                             ;; keep END at the block's real end or the buffer
                             ;; would grow by the difference every iteration.
                             (setq end (cdr (pilish--replace-thinking-block-region
                                             start end rendered)))
                             (unless stable-size
                               (setq stable-size (buffer-size)))))))
            (unless (and stable-size (= (buffer-size) stable-size))
              (error "thinking benchmark: buffer grew during rewrite"))
            (unless (string-match-p "> thinking line 799" (buffer-string))
              (error "thinking benchmark: rendered block missing after rewrite"))))))
    (cons "thinking-rewrite" times)))

(defun pilish-tmd-bench--cooling-case (label lines preview-lines)
  "Measure cooling of completed blocks sized LINES with PREVIEW-LINES.
PREVIEW-LINES high enough leaves blocks expanded, so cooling rewrites their
full visible body; a low value measures the collapsed preview case.
Return (LABEL . MILLISECONDS), one fresh buffer per repetition."
  (let ((blocks (max 10 (/ pilish-tmd-bench-iterations 2)))
        (pilish-tool-preview-lines preview-lines)
        (pilish-bash-preview-lines preview-lines)
        times)
    (dotimes (_ pilish-tmd-bench-reps)
      (with-temp-buffer
        (pilish-tmd-bench--chat-buffer pilish-tmd-bench-sections)
        (let (overlays)
          (dotimes (i blocks)
            (let* ((block (pilish--display-tool-start "bash" '(:command "ls")))
                   (ov (pilish--tool-block-overlay block)))
              (pilish--display-tool-end
               "bash" '(:command "ls")
               (list (list :type "text"
                           :text (pilish-tmd-bench--lines lines (format "out%d" i))))
               nil nil block)
              (push ov overlays)))
          (dolist (ov (nreverse overlays))
            (let ((start (float-time)))
              (pilish--cool-tool-overlay ov)
              (push (* 1000.0 (- (float-time) start)) times)))
          (unless (string-match-p "out0 line 0" (buffer-string))
            (error "cooling benchmark: cooled output missing")))))
    (cons label times)))

(defun pilish-tmd-bench--cooling ()
  "Measure cooling of collapsed and expanded completed blocks."
  (list (pilish-tmd-bench--cooling-case "tool-cooling-collapsed" 40 20)
        (pilish-tmd-bench--cooling-case "tool-cooling-expanded" 200 100000)))

;;;; Reporting

(defun pilish-tmd-bench--rows ()
  "Run every scenario and return rows of (LABEL STATS)."
  (let ((gc-cons-threshold (max gc-cons-threshold (* 512 1024 1024))))
    (mapcar (lambda (result)
              (cons (car result)
                    (pilish-tmd-bench--stats (cdr result))))
            (append (list (pilish-tmd-bench--compound)
                          (pilish-tmd-bench--toggle)
                          (pilish-tmd-bench--thinking))
                    (pilish-tmd-bench--cooling)))))

(defun pilish-tmd-bench--format-summary (rows)
  "Return a markdown table for benchmark ROWS."
  (concat
   "| operation | min ms | median ms | mean ms | p95 ms | max ms | n |\n"
   "|---|---:|---:|---:|---:|---:|---:|\n"
   (string-join
    (mapcar (lambda (row)
              (let ((label (car row))
                    (s (cdr row)))
                (format "| %s | %.2f | %.2f | %.2f | %.2f | %.2f | %d |"
                        label
                        (plist-get s :min) (plist-get s :median)
                        (plist-get s :mean) (plist-get s :p95)
                        (plist-get s :max) (plist-get s :n))))
            rows)
    "\n")))

(defun pilish-tmd-bench--write-artifacts (rows)
  "Write CSV and markdown artifacts for benchmark ROWS."
  (make-directory pilish-tmd-bench-out-dir t)
  (let ((csv (mapconcat
              (lambda (row)
                (let ((s (cdr row)))
                  (format "%s,%.3f,%.3f,%.3f,%.3f,%.3f,%d"
                          (car row)
                          (plist-get s :min) (plist-get s :median)
                          (plist-get s :mean) (plist-get s :p95)
                          (plist-get s :max) (plist-get s :n))))
              rows "\n"))
        (header (format "# Pilish tool md-ts wall-time (%s lane)\n\nsections=%d iterations=%d reps=%d\n\n"
                        pilish-tmd-bench-lane
                        pilish-tmd-bench-sections
                        pilish-tmd-bench-iterations
                        pilish-tmd-bench-reps)))
    (with-temp-file (expand-file-name "results.csv" pilish-tmd-bench-out-dir)
      (insert "operation,min_ms,median_ms,mean_ms,p95_ms,max_ms,n\n" csv "\n"))
    (with-temp-file (expand-file-name "report.md" pilish-tmd-bench-out-dir)
      (insert header (pilish-tmd-bench--format-summary rows) "\n"))))

(defun pilish-tmd-bench--print-summary (rows)
  "Print benchmark ROWS to the current output."
  (princ (format "\nsummary (%s, %d sections)\n"
                 pilish-tmd-bench-lane pilish-tmd-bench-sections))
  (princ "operation          min      median      mean       p95       max\n")
  (princ "-------------  -------  ----------  --------  --------  --------\n")
  (dolist (row rows)
    (let ((s (cdr row)))
      (princ (format "%-15s %7.2f  %9.2f  %8.2f  %8.2f  %8.2f\n"
                     (car row)
                     (plist-get s :min) (plist-get s :median)
                     (plist-get s :mean) (plist-get s :p95)
                     (plist-get s :max)))))
  (princ "\nWrote ")
  (princ (expand-file-name "results.csv" pilish-tmd-bench-out-dir))
  (princ "\n"))

(defun pilish-tmd-bench-run ()
  "Run the benchmark in the current Emacs."
  (let ((rows (pilish-tmd-bench--rows)))
    (pilish-tmd-bench--write-artifacts rows)
    (let ((standard-output #'external-debugging-output))
      (pilish-tmd-bench--print-summary rows))))

(defun pilish-tmd-bench-run-batch ()
  "Run the benchmark in batch mode and exit non-zero on failure."
  (condition-case err
      (progn
        (pilish-tmd-bench-run)
        (kill-emacs 0))
    (error
     (message "pilish-tool-md-ts-bench failed: %s" (error-message-string err))
     (kill-emacs 1))))

(provide 'pilish-tool-md-ts-bench)
;;; pilish-tool-md-ts-bench.el ends here
