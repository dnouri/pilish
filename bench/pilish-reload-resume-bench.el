;;; pilish-reload-resume-bench.el --- Reload/resume benchmarks -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel Nouri

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Deterministic reload/resume benchmarks for Pilish.
;; The benchmark generates synthetic pi JSONL session files, drives the Emacs
;; UI through a fake JSON-over-stdio backend, and records only metrics.  No
;; private session files are read.
;;
;; Run with:
;;
;;   make bench-reload-resume            # GUI via xvfb, primary lane
;;   make bench-reload-resume-batch      # --batch, secondary lane
;;   make bench-reload-resume-smoke      # cheap correctness smoke
;;
;; or directly through `bench/run-reload-resume-bench.sh'.
;;
;; The primary lane is GUI/xvfb because reload/resume includes redisplay,
;; tree-sitter, overlays, and window-visible rendering.  Batch numbers are
;; useful for CI trend artifacts but less representative of interactive use.
;; Timing advice is diagnostic only; pass --timings when inclusive function
;; timings are more useful than purer wall-clock numbers.  No timing threshold
;; is enforced by this benchmark.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)

(defconst pilish-rr-bench-repo-root
  (file-name-as-directory
   (expand-file-name ".."
                     (file-name-directory
                      (or load-file-name buffer-file-name default-directory))))
  "Repository root containing the reload/resume benchmark files.")

(add-to-list 'load-path pilish-rr-bench-repo-root)
(require 'pilish)

(defun pilish-rr-bench--env (name default)
  "Return environment variable NAME, or DEFAULT when it is unset or empty."
  (let ((value (getenv name)))
    (if (and value (not (string-empty-p value))) value default)))

(defun pilish-rr-bench--env-int (name default)
  "Return environment variable NAME as an integer, or DEFAULT."
  (string-to-number (pilish-rr-bench--env
                     name (number-to-string default))))

(defun pilish-rr-bench--truthy-env-p (name default)
  "Return non-nil when environment variable NAME is truthy.
DEFAULT is used when NAME is unset."
  (let ((value (downcase (pilish-rr-bench--env name default))))
    (and (member value '("1" "true" "yes" "on")) t)))

(defun pilish-rr-bench--json-bool (value)
  "Return VALUE encoded as a JSON boolean sentinel."
  (if value t :json-false))

(defvar pilish-rr-bench-scenario
  (pilish-rr-bench--env "PI_RR_BENCH_SCENARIO" "standalone")
  "Scenario label written into reload/resume benchmark artifacts.")

(defvar pilish-rr-bench-variant
  (pilish-rr-bench--env "PI_RR_BENCH_VARIANT" "unknown")
  "Variant label written into reload/resume benchmark artifacts.")

(defvar pilish-rr-bench-iteration
  (pilish-rr-bench--env-int "PI_RR_BENCH_ITERATION" 1)
  "Iteration number written into reload/resume benchmark artifacts.")

(defvar pilish-rr-bench-turns
  (pilish-rr-bench--env-int "PI_RR_BENCH_TURNS" 350)
  "Number of synthetic turns in the current and target sessions.")

(defvar pilish-rr-bench-other-sessions
  (pilish-rr-bench--env-int "PI_RR_BENCH_OTHER_SESSIONS" 60)
  "Number of extra session files in the synthetic resume directory.")

(defvar pilish-rr-bench-other-turns
  (pilish-rr-bench--env-int "PI_RR_BENCH_OTHER_TURNS" 40)
  "Number of turns in each extra synthetic session file.")

(defvar pilish-rr-bench-tool-every
  (pilish-rr-bench--env-int "PI_RR_BENCH_TOOL_EVERY" 1)
  "Cadence for synthetic tool calls; zero disables tool calls.")

(defvar pilish-rr-bench-table-every
  (pilish-rr-bench--env-int "PI_RR_BENCH_TABLE_EVERY" 10)
  "Cadence for synthetic Markdown tables; zero disables tables.")

(defvar pilish-rr-bench-thinking-every
  (pilish-rr-bench--env-int "PI_RR_BENCH_THINKING_EVERY" 5)
  "Cadence for synthetic thinking blocks; zero disables thinking blocks.")

(defvar pilish-rr-bench-text-bytes
  (pilish-rr-bench--env-int "PI_RR_BENCH_TEXT_BYTES" 0)
  "Approximate extra bytes to append to each synthetic text block.")

(defvar pilish-rr-bench-wire-bytes
  (pilish-rr-bench--env-int "PI_RR_BENCH_WIRE_BYTES" 0)
  "Ignored bytes to add to each synthetic message object.
This grows the JSON-over-stdio `get_messages' response without growing the
rendered transcript, which keeps the RPC framing benchmark focused.")

(defvar pilish-rr-bench-tool-output-lines
  (pilish-rr-bench--env-int "PI_RR_BENCH_TOOL_OUTPUT_LINES" 36)
  "Number of synthetic output lines per tool result.")

(defvar pilish-rr-bench-timeout-seconds
  (pilish-rr-bench--env-int "PI_RR_BENCH_TIMEOUT_SECONDS" 300)
  "Timeout in seconds for each asynchronous benchmark operation.")

(defvar pilish-rr-bench-display-buffers
  (pilish-rr-bench--truthy-env-p "PI_RR_BENCH_DISPLAY" "0")
  "Whether GUI benchmark iterations should display chat and input windows.")

(defvar pilish-rr-bench-timings-enabled
  (pilish-rr-bench--truthy-env-p "PI_RR_BENCH_TIMINGS" "0")
  "Whether to collect diagnostic inclusive timing advice data.")

(defvar pilish-rr-bench-out-dir
  (file-name-as-directory
   (expand-file-name (pilish-rr-bench--env
                      "PI_RR_BENCH_OUT_DIR"
                      "tmp/reload-resume-bench/standalone")
                     pilish-rr-bench-repo-root))
  "Output directory for one reload/resume benchmark iteration.")

(defvar pilish-rr-bench-runner-out-dir
  (file-name-as-directory
   (expand-file-name (pilish-rr-bench--env
                      "PI_RR_BENCH_RUNNER_OUT_DIR"
                      pilish-rr-bench-out-dir)
                     pilish-rr-bench-repo-root))
  "Top-level runner output directory for reproduction commands.")

(defvar pilish-rr-bench-fixture-root
  (file-name-as-directory
   (expand-file-name (pilish-rr-bench--env
                      "PI_RR_BENCH_FIXTURE_ROOT"
                      (expand-file-name "fixtures"
                                        pilish-rr-bench-out-dir))
                     pilish-rr-bench-repo-root))
  "Root directory for generated synthetic fixture files.")

(defvar pilish-rr-bench-data-dir
  (expand-file-name "sessions" pilish-rr-bench-fixture-root)
  "Directory containing generated synthetic session JSONL files.")

(defvar pilish-rr-bench-project-dir
  (file-name-as-directory
   (expand-file-name "project" pilish-rr-bench-fixture-root))
  "Synthetic project directory recorded in generated session files.")

(defvar pilish-rr-bench-fake-pi
  (expand-file-name "bench/fake-pi-reload-resume.py"
                    pilish-rr-bench-repo-root)
  "Fake pi RPC executable used by reload/resume benchmark iterations.")

(defvar pilish-rr-bench-fake-log
  (expand-file-name "fake-pi.jsonl" pilish-rr-bench-out-dir)
  "Content-free fake RPC log path for one benchmark iteration.")

(defvar pilish-rr-bench-result-file
  (expand-file-name "result.json" pilish-rr-bench-out-dir)
  "JSON result artifact path for one benchmark iteration.")

(defvar pilish-rr-bench-report-file
  (expand-file-name "report.md" pilish-rr-bench-out-dir)
  "Markdown report artifact path for one benchmark iteration.")

(defvar pilish-rr-bench-times-file
  (expand-file-name "times.tsv" pilish-rr-bench-out-dir)
  "Diagnostic inclusive timing artifact path for one benchmark iteration.")

(defvar pilish-rr-bench--phase nil
  "Current operation phase used as a prefix for timing rows.")

(defvar pilish-rr-bench--timings (make-hash-table :test 'equal)
  "Hash table of diagnostic inclusive timing rows keyed by phase and name.")

(defvar pilish-rr-bench--advice-handles nil
  "List of installed timing advice functions for cleanup.")

(defun pilish-rr-bench--json-line (object)
  "Encode OBJECT as one JSONL line."
  (concat (json-encode object) "\n"))

(defun pilish-rr-bench--timestamp (turn &optional offset)
  "Return a deterministic millisecond timestamp for TURN plus OFFSET."
  (+ 1704067200000 (* 60000 turn) (or offset 0)))

(defun pilish-rr-bench--payload (turn label)
  "Return deterministic synthetic payload text for TURN and LABEL."
  (if (<= pilish-rr-bench-text-bytes 0)
      ""
    (let* ((alphabet "abcdefghijklmnopqrstuvwxyz0123456789")
           (ch (aref alphabet (% (+ turn (length label)) (length alphabet))))
           (prefix (format "\nSynthetic payload %s turn %d: " label turn))
           (payload-len (max 0 (- pilish-rr-bench-text-bytes
                                  (length prefix)))))
      (concat prefix (make-string payload-len ch)))))

(defun pilish-rr-bench--wire-payload (turn label)
  "Return ignored synthetic wire payload for TURN and LABEL, or nil."
  (when (> pilish-rr-bench-wire-bytes 0)
    (let* ((alphabet "abcdefghijklmnopqrstuvwxyz0123456789")
           (ch (aref alphabet (% (+ turn (* 3 (length label)))
                                  (length alphabet))))
           (prefix (format "ignored wire payload %s turn %d: " label turn))
           (payload-len (max 0 (- pilish-rr-bench-wire-bytes
                                  (length prefix)))))
      (concat prefix (make-string payload-len ch)))))

(defun pilish-rr-bench--message-with-wire-payload
    (message turn label)
  "Return MESSAGE plus ignored wire payload for TURN and LABEL when enabled."
  (if-let* ((payload (pilish-rr-bench--wire-payload turn label)))
      (append message (list :benchmarkPayload payload))
    message))

(defun pilish-rr-bench--table-text (turn)
  "Return deterministic Markdown table text for TURN."
  (mapconcat
   #'identity
   (append
    (list (format "| turn %d | status | value | note |" turn)
          "|---:|---|---:|---|")
    (cl-loop for i from 1 to 8
             collect (format "| %d.%d | **ok** | %d | `cell-%d-%d` wraps with extra words |"
                             turn i (* turn i) turn i)))
   "\n"))

(defun pilish-rr-bench--assistant-text (turn short)
  "Return deterministic assistant text for TURN.
When SHORT is non-nil, omit tables and large optional payloads."
  (concat
   (format "Assistant answer for synthetic turn %d. This deterministic paragraph gives history replay real insertion work.\n\n" turn)
   (unless short
     (when (and (> pilish-rr-bench-table-every 0)
                (zerop (% turn pilish-rr-bench-table-every)))
       (concat (pilish-rr-bench--table-text turn) "\n\n")))
   "```elisp\n"
   (format "(message \"synthetic turn %d\")\n" turn)
   "```\n"
   (pilish-rr-bench--payload turn "assistant")))

(defun pilish-rr-bench--thinking-text (turn)
  "Return deterministic thinking text for TURN."
  (concat (format "Synthetic thinking for turn %d. Keep render path deterministic."
                  turn)
          (pilish-rr-bench--payload turn "thinking")))

(defun pilish-rr-bench--tool-output (turn)
  "Return deterministic synthetic tool output for TURN."
  (mapconcat
   (lambda (i)
     (format "line %03d from tool on turn %03d: %s" i turn
             (make-string 72 (aref "abcdefghijklmnopqrstuvwxyz"
                                    (% (+ i turn) 26)))))
   (number-sequence 1 pilish-rr-bench-tool-output-lines)
   "\n"))

(defun pilish-rr-bench--tool-kind (turn)
  "Return the synthetic tool name for TURN."
  (pcase (% turn 4)
    (0 "read")
    (1 "bash")
    (2 "edit")
    (_ "profile_tool")))

(defun pilish-rr-bench--tool-args (turn tool-name)
  "Return synthetic arguments for TOOL-NAME on TURN."
  (pcase tool-name
    ("read" (list :path (format "src/file-%03d.el" (% turn 37))
                  :offset (* 10 (% turn 20))))
    ("bash" (list :command (format "printf 'turn %d' && sleep 0" turn)))
    ("edit" (list :path (format "src/file-%03d.el" (% turn 37))
                  :oldText (format "old-%d" turn)
                  :newText (format "new-%d" turn)))
    (_ (list :path (format "src/file-%03d.el" (% turn 37))
             :payload (vconcat (cl-loop for i below 8
                                         collect (list :key (format "k%d" i)
                                                       :value (format "v%d-%d" turn i))))))))

(defun pilish-rr-bench--tool-details (turn tool-name)
  "Return synthetic tool result details for TOOL-NAME on TURN."
  (pcase tool-name
    ("edit" (list :diff (format "- old-%d\n+ new-%d\n" turn turn)
                  :truncation nil
                  :fullOutputPath nil))
    (_ (list :truncation nil :fullOutputPath nil))))

(defun pilish-rr-bench--message-record (entry-id message)
  "Return a JSONL session record for ENTRY-ID containing MESSAGE."
  (list :type "message" :entryId entry-id :message message))

(defun pilish-rr-bench--write-session (path name turns mtime-index
                                                     &optional short)
  "Write synthetic session PATH.
NAME labels the session; TURNS controls its length; MTIME-INDEX controls its
synthetic modification time.  When SHORT is non-nil, omit expensive assistant
extras.  Return a metrics plist for the generated session."
  (make-directory (file-name-directory path) t)
  (let ((message-count 0)
        (tool-count 0))
    (with-temp-file path
      (insert (pilish-rr-bench--json-line
               (list :type "session"
                     :id (file-name-base path)
                     :cwd pilish-rr-bench-project-dir)))
      (insert (pilish-rr-bench--json-line
               (list :type "session_info"
                     :id (concat (file-name-base path) "-name")
                     :name name)))
      (cl-loop for turn from 1 to turns do
               (let ((user-text
                      (concat
                       (format "Session %s asks for synthetic reload/resume detail on turn %d."
                               name turn)
                       (pilish-rr-bench--payload turn "user"))))
                 (insert
                  (pilish-rr-bench--json-line
                   (pilish-rr-bench--message-record
                    (format "user-%d" turn)
                    (pilish-rr-bench--message-with-wire-payload
                     (list :role "user"
                           :content (vector (list :type "text" :text user-text))
                           :timestamp (pilish-rr-bench--timestamp turn))
                     turn "user"))))
                 (setq message-count (1+ message-count)))
               (let* ((tool-p (and (not short)
                                   (> pilish-rr-bench-tool-every 0)
                                   (zerop (% turn pilish-rr-bench-tool-every))))
                      (tool-name (and tool-p
                                      (pilish-rr-bench--tool-kind turn)))
                      (tool-id (and tool-p (format "tool-%d" turn)))
                      (assistant-content
                       (vconcat
                        (delq nil
                              (list
                               (list :type "text"
                                     :text (pilish-rr-bench--assistant-text
                                            turn short))
                               (when (and (not short)
                                          (> pilish-rr-bench-thinking-every 0)
                                          (zerop (% turn pilish-rr-bench-thinking-every)))
                                 (list :type "thinking"
                                       :thinking (pilish-rr-bench--thinking-text turn)))
                               (when tool-p
                                 (list :type "toolCall"
                                       :id tool-id
                                       :name tool-name
                                       :arguments (pilish-rr-bench--tool-args
                                                   turn tool-name)))
                               (list :type "text"
                                     :text (format "\nTail sentinel for turn %d.\n"
                                                   turn)))))))
                 (insert
                  (pilish-rr-bench--json-line
                   (pilish-rr-bench--message-record
                    (format "assistant-%d" turn)
                    (pilish-rr-bench--message-with-wire-payload
                     (list :role "assistant"
                           :content assistant-content
                           :timestamp (pilish-rr-bench--timestamp turn 1000)
                           :stopReason "stop")
                     turn "assistant"))))
                 (setq message-count (1+ message-count))
                 (when tool-p
                   (insert
                    (pilish-rr-bench--json-line
                     (pilish-rr-bench--message-record
                      (format "tool-result-%d" turn)
                      (pilish-rr-bench--message-with-wire-payload
                       (list :role "toolResult"
                             :toolCallId tool-id
                             :content (vector (list :type "text"
                                                    :text (pilish-rr-bench--tool-output turn)))
                             :details (pilish-rr-bench--tool-details
                                       turn tool-name)
                             :isError :json-false
                             :timestamp (pilish-rr-bench--timestamp
                                         turn 2000))
                       turn "toolResult"))))
                   (setq message-count (1+ message-count)
                         tool-count (1+ tool-count))))))
    (set-file-times path (seconds-to-time (+ 1704067200 mtime-index)))
    (let ((bytes (file-attribute-size (file-attributes path))))
      (list :path path :name name :turns turns :messages message-count
            :tools tool-count :bytes bytes))))

(defun pilish-rr-bench--prepare-data ()
  "Create deterministic fixtures and return a workload summary plist."
  (when (file-directory-p pilish-rr-bench-fixture-root)
    (delete-directory pilish-rr-bench-fixture-root t))
  (make-directory pilish-rr-bench-data-dir t)
  (make-directory pilish-rr-bench-project-dir t)
  (let* ((current (expand-file-name "current-long.jsonl"
                                    pilish-rr-bench-data-dir))
         (target (expand-file-name "target-long.jsonl"
                                   pilish-rr-bench-data-dir))
         (current-summary (pilish-rr-bench--write-session
                           current "Current long session"
                           pilish-rr-bench-turns 1000))
         (target-summary (pilish-rr-bench--write-session
                          target "Target long session"
                          pilish-rr-bench-turns 1001))
         (other-summaries nil))
    (cl-loop for i from 1 to pilish-rr-bench-other-sessions do
             (push (pilish-rr-bench--write-session
                    (expand-file-name (format "other-%03d.jsonl" i)
                                      pilish-rr-bench-data-dir)
                    (format "Other profiling session %03d" i)
                    pilish-rr-bench-other-turns i t)
                   other-summaries))
    (let* ((all (append (list current-summary target-summary)
                        (nreverse other-summaries)))
           (total-bytes (apply #'+ (mapcar (lambda (row)
                                             (plist-get row :bytes))
                                           all))))
      (list :current current-summary
            :target target-summary
            :other-count pilish-rr-bench-other-sessions
            :session-file-count (length all)
            :total-bytes total-bytes
            :fixture-root pilish-rr-bench-fixture-root
            :session-dir pilish-rr-bench-data-dir
            :project-dir pilish-rr-bench-project-dir))))

(defun pilish-rr-bench--timing-key (name)
  "Return the hash key for timing NAME in the current phase."
  (format "%s\t%s" (or pilish-rr-bench--phase "global") name))

(defun pilish-rr-bench--add-time (name seconds)
  "Add SECONDS to diagnostic timing row NAME."
  (let* ((key (pilish-rr-bench--timing-key name))
         (row (gethash key pilish-rr-bench--timings)))
    (if row
        (setcdr row (list (1+ (cadr row))
                          (+ seconds (cl-caddr row))
                          (max seconds (cl-cadddr row))))
      (puthash key (list name 1 seconds seconds)
               pilish-rr-bench--timings))))

(defun pilish-rr-bench--timing-advice (name)
  "Return around advice that records inclusive time under NAME."
  (lambda (orig &rest args)
    (let ((start (float-time)))
      (unwind-protect
          (apply orig args)
        (pilish-rr-bench--add-time name (- (float-time) start))))))

(defun pilish-rr-bench--install-timing-advices ()
  "Install diagnostic inclusive timing advice for reload/resume paths."
  (when pilish-rr-bench-timings-enabled
    (let ((symbols '(;; RPC and JSON framing.
                     pilish--rpc-async
                     pilish--process-filter
                     pilish--accumulate-lines
                     pilish--accumulate-line-chunks
                     pilish--dispatch-response
                     pilish--parse-json-line
                     json-parse-string
                     ;; Session browser and disk metadata.
                     pilish-session-browser
                     pilish--get-or-create-session-browser
                     pilish--session-browser-fetch-and-render
                     pilish--browse-load-sessions
                     pilish--browse-scan-session-files
                     pilish--browse-session-directories
                     pilish--browse-session-files
                     pilish-jsonl-open-session-info
                     pilish-jsonl-step-session-info
                     pilish--jsonl-info-scan-line
                     pilish--jsonl-info-result
                     pilish--jsonl-parse-current-line
                     pilish--jsonl-extract-text
                     pilish-jsonl-read-session-info
                     pilish--session-browser-render
                     pilish--session-browser-rerender
                     pilish--session-browser-insert-session
                     pilish-session-browser-switch
                     pilish--browse-switch-session
                     pilish--session-list-directory
                     pilish--session-file-cwd-or-error
                     pilish--update-session-name-from-file
                     directory-files
                     insert-file-contents
                     file-attributes
                     ;; Transition control flow.
                     pilish-reload
                     pilish--resume-selected-session
                     pilish--refresh-session-state
                     pilish--load-session-history
                     ;; History rendering.
                     pilish--display-session-history
                     pilish--clear-render-artifacts
                     pilish--display-history-messages
                     pilish--build-tool-result-index
                     pilish--display-user-message
                     pilish--render-history-assistant-content
                     pilish--render-history-text
                     pilish--render-history-thinking
                     pilish--render-history-tool
                     pilish--append-to-chat
                     pilish--restore-tail-window
                     pilish--window-start-fills-window-within-one-row-p
                     pilish--count-screen-lines-up-to
                     vertical-motion
                     recenter
                     pilish--update-hot-tail-boundary
                     pilish--cool-completed-tool-blocks-outside-hot-tail
                     pilish--cool-completed-tool-blocks
                     pilish--cool-tool-overlay
                     pilish--postprocess-history-buffer
                     pilish--history-table-candidate-p
                     pilish--decorate-tables-in-region
                     pilish--treesit-table-regions
                     pilish--decorate-table
                     pilish--table-display-groups
                     ;; Tool rendering / overlay pressure.
                     pilish--display-tool-start
                     pilish--display-tool-end
                     pilish--tool-block-create
                     pilish--tool-overlay-finalize
                     pilish--tool-block-finalize
                     pilish--truncate-to-visual-lines
                     pilish--insert-tool-output-section
                     pilish--insert-rendered-tool-content
                     pilish--pretty-print-json
                     make-overlay
                     overlays-in
                     remove-overlays
                     delete-overlay
                     font-lock-ensure
                     redisplay)))
      (dolist (sym symbols)
        (when (and (fboundp sym)
                   (not (assq sym pilish-rr-bench--advice-handles)))
          (let ((fn (pilish-rr-bench--timing-advice sym)))
            (advice-add sym :around fn)
            (push (cons sym fn)
                  pilish-rr-bench--advice-handles)))))))

(defun pilish-rr-bench--remove-timing-advices ()
  "Remove all diagnostic timing advice installed by the benchmark."
  (dolist (entry pilish-rr-bench--advice-handles)
    (ignore-errors (advice-remove (car entry) (cdr entry))))
  (setq pilish-rr-bench--advice-handles nil))

(defun pilish-rr-bench--timing-rows (&optional phase)
  "Return diagnostic timing rows, optionally filtered to PHASE.
Rows are sorted by descending inclusive total time."
  (let (rows)
    (maphash
     (lambda (key row)
       (let ((parts (split-string key "\t")))
         (when (or (null phase) (equal phase (car parts)))
           (push (list :phase (car parts)
                       :name (car row)
                       :count (cadr row)
                       :total (cl-caddr row)
                       :max (cl-cadddr row))
                 rows))))
     pilish-rr-bench--timings)
    (sort rows (lambda (a b) (> (plist-get a :total)
                                (plist-get b :total))))))

(defun pilish-rr-bench--write-times-tsv ()
  "Write diagnostic timing rows to `pilish-rr-bench-times-file'."
  (with-temp-file pilish-rr-bench-times-file
    (insert "phase\tname\tcount\ttotal_seconds\tmax_seconds\n")
    (dolist (row (pilish-rr-bench--timing-rows))
      (insert (format "%s\t%s\t%d\t%.6f\t%.6f\n"
                      (plist-get row :phase)
                      (plist-get row :name)
                      (plist-get row :count)
                      (plist-get row :total)
                      (plist-get row :max))))))

(defun pilish-rr-bench--read-session-messages (path)
  "Read message payloads from synthetic session file PATH."
  (let (messages)
    (with-temp-buffer
      (insert-file-contents path)
      (goto-char (point-min))
      (while (not (eobp))
        (let ((obj (json-parse-string
                    (buffer-substring-no-properties
                     (line-beginning-position) (line-end-position))
                    :object-type 'plist)))
          (when (equal (plist-get obj :type) "message")
            (push (plist-get obj :message) messages)))
        (forward-line 1)))
    (vconcat (nreverse messages))))

(defun pilish-rr-bench--preload-history (chat session-file)
  "Pre-render SESSION-FILE into CHAT before the timed operation."
  (when (buffer-live-p chat)
    (with-current-buffer chat
      (pilish--display-session-history
       (pilish-rr-bench--read-session-messages session-file)
       chat))))

(defun pilish-rr-bench--buffer-contains-p (buffer text)
  "Return non-nil if TEXT is present in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (save-excursion
        (goto-char (point-min))
        (search-forward text nil t)))))

(defun pilish-rr-bench--make-session (session-file &optional
                                                            backend-session-file
                                                            preload-session-file)
  "Create a fake-backed Emacs session whose cached file is SESSION-FILE.
BACKEND-SESSION-FILE, when non-nil, is the fake backend's initial session.
PRELOAD-SESSION-FILE, when non-nil, is rendered before timing starts."
  (setq pilish-executable (list (or (executable-find "python3")
                                             (error "Python3 not found"))
                                         pilish-rr-bench-fake-pi))
  (setq pilish-extra-args
        (list "--initial-session" (or backend-session-file session-file)
              "--log-file" pilish-rr-bench-fake-log))
  (let* ((chat (generate-new-buffer " *pilish-rr-bench-chat*"))
         (input (generate-new-buffer " *pilish-rr-bench-input*"))
         proc)
    (with-current-buffer chat
      (pilish-chat-mode)
      (pilish--set-chat-session-identity
       pilish-rr-bench-project-dir)
      (pilish--set-input-buffer input)
      (setq default-directory pilish-rr-bench-project-dir)
      (setq pilish--state
            (list :model (list :name "Fake Model" :provider "fake")
                  :thinking-level "medium"
                  :status 'idle
                  :session-id (file-name-base session-file)
                  :session-file session-file
                  :message-count 0
                  :pending-message-count 0))
      (setq pilish--status 'idle)
      (setq proc (pilish--start-process
                  pilish-rr-bench-project-dir))
      ;; Version probes are unrelated to reload/resume and would spawn an
      ;; extra fake process in the GUI lane.  Delay them beyond the benchmark.
      (let ((pilish--version-probe-delay 3600))
        (pilish--set-process proc))
      (set-process-buffer proc chat)
      (process-put proc 'pilish-chat-buffer chat)
      (pilish--register-display-handler proc))
    (with-current-buffer input
      (pilish-input-mode)
      (setq default-directory pilish-rr-bench-project-dir)
      (pilish--set-chat-buffer chat))
    (when preload-session-file
      (pilish-rr-bench--preload-history chat preload-session-file))
    (when (and pilish-rr-bench-display-buffers (not noninteractive))
      (delete-other-windows)
      (switch-to-buffer chat)
      (let ((input-window (split-window-vertically -8)))
        (set-window-buffer input-window input)
        (select-window (get-buffer-window chat)))
      (redisplay t))
    (list :chat chat :input input :proc proc)))

(defun pilish-rr-bench--cleanup-session (session)
  "Kill buffers and processes belonging to benchmark SESSION."
  (dolist (buf (list (plist-get session :chat) (plist-get session :input)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (and (boundp 'pilish--process)
                   (processp pilish--process)
                   (process-live-p pilish--process))
          (set-process-query-on-exit-flag pilish--process nil)
          (delete-process pilish--process)))
      (kill-buffer buf))))

(defun pilish-rr-bench--pending-requests-count (proc)
  "Return the number of pending RPC requests for PROC."
  (let ((pending (and (processp proc)
                      (process-get proc 'pilish-pending-requests))))
    (if (hash-table-p pending) (hash-table-count pending) 0)))

(defun pilish-rr-bench--canonical-message-count (chat)
  "Return CHAT's canonical message count, or nil if unavailable."
  (when (buffer-live-p chat)
    (with-current-buffer chat
      (when (and (boundp 'pilish--canonical-messages)
                 (vectorp pilish--canonical-messages))
        (length pilish--canonical-messages)))))

(defun pilish-rr-bench--state-session-file (chat)
  "Return CHAT's current state session file, or nil if unavailable."
  (when (buffer-live-p chat)
    (with-current-buffer chat
      (when (boundp 'pilish--state)
        (plist-get pilish--state :session-file)))))

(defun pilish-rr-bench--wait-until (predicate timeout)
  "Wait for PREDICATE to become non-nil, or TIMEOUT seconds to elapse."
  (let ((start (float-time))
        result)
    (while (and (not (setq result (funcall predicate)))
                (< (- (float-time) start) timeout))
      (accept-process-output nil 0.01)
      (when (and pilish-rr-bench-display-buffers (not noninteractive))
        (redisplay t)))
    result))

(defun pilish-rr-bench--run-operation (name session thunk done-p)
  "Run operation NAME for SESSION by calling THUNK.
DONE-P must return non-nil once asynchronous UI state has settled.  Return a
result plist containing correctness and wall-clock metrics."
  (setq pilish-rr-bench--phase name)
  (garbage-collect)
  (let* ((chat (plist-get session :chat))
         (gc-before gcs-done)
         (gc-time-before gc-elapsed)
         (start (float-time))
         (ok nil)
         (error-text nil))
    (condition-case err
        (progn
          ;; `pilish-reload' installs a fresh process and, in GUI
          ;; Emacs, normally schedules an unrelated `pi --version' probe.
          ;; Keep that probe out of the timed reload/resume window.
          (let ((pilish--version-probe-delay 3600))
            (funcall thunk))
          (setq ok (pilish-rr-bench--wait-until
                    (lambda ()
                      (let ((proc (and (buffer-live-p chat)
                                       (with-current-buffer chat
                                         pilish--process))))
                        (unless (and (processp proc) (process-live-p proc))
                          (error "Fake pi process exited before %s settled" name))
                        (and (funcall done-p)
                             (= 0 (pilish-rr-bench--pending-requests-count
                                   proc)))))
                    pilish-rr-bench-timeout-seconds))
          (unless ok
            (setq error-text (format "Timed out waiting for %s to settle" name))))
      (error (setq error-text (error-message-string err))))
    (when (and pilish-rr-bench-display-buffers (not noninteractive))
      (redisplay t))
    (prog1
        (list :name name
              :ok (pilish-rr-bench--json-bool ok)
              :error error-text
              :seconds (- (float-time) start)
              :gcs (- gcs-done gc-before)
              :gcSeconds (- gc-elapsed gc-time-before)
              :bufferBytes (and (buffer-live-p chat)
                                (with-current-buffer chat (buffer-size)))
              :bufferLines (and (buffer-live-p chat)
                                (with-current-buffer chat
                                  (count-lines (point-min) (point-max)))))
      (setq pilish-rr-bench--phase nil))))

(defun pilish-rr-bench--open-session-browser (chat)
  "Open the real async session browser linked to CHAT and return its buffer."
  (let (dir)
    (with-current-buffer chat
      (setq dir (pilish--session-directory))
      (pilish-session-browser))
    (let ((browser
           (get-buffer (pilish--session-browser-buffer-name dir))))
      (unless (buffer-live-p browser)
        (error "Session browser did not create a buffer for %s" dir))
      (unless (eq (buffer-local-value 'pilish--chat-buffer browser)
                  chat)
        (error "Session browser is not linked to the benchmark chat"))
      browser)))

(defun pilish-rr-bench--wait-for-session-browser (browser)
  "Wait boundedly for BROWSER to finish loading, or signal."
  (unless (pilish-rr-bench--wait-until
           (lambda ()
             (and (buffer-live-p browser)
                  (with-current-buffer browser
                    (not pilish--session-browser-loading))))
           pilish-rr-bench-timeout-seconds)
    (error "Timed out waiting for the session browser to load"))
  (with-current-buffer browser
    (when pilish--session-browser-error
      (error "Session browser failed: %s"
             pilish--session-browser-error))))

(defun pilish-rr-bench--select-session-path (browser path)
  "Move point in BROWSER to the session section whose value equals PATH."
  (with-current-buffer browser
    (let ((pending (oref magit-root-section children))
          (section nil))
      (while (and pending (not section))
        (let ((candidate (pop pending)))
          (if (and (eq (oref candidate type) 'session)
                   (equal (oref candidate value) path))
              (setq section candidate)
            (setq pending (append (oref candidate children) pending)))))
      (unless section
        (error "Session browser did not render target path: %s" path))
      (goto-char (oref section start))
      (dolist (window (get-buffer-window-list browser nil t))
        (set-window-point window (point))))))

(defun pilish-rr-bench--run-resume (current-session target-session
                                                            target-count)
  "Benchmark browser-backed resume from CURRENT-SESSION to TARGET-SESSION.
TARGET-COUNT is the expected canonical message count after resume."
  (let* ((session (pilish-rr-bench--make-session
                   current-session nil current-session))
         (chat (plist-get session :chat))
         (browser nil))
    (unwind-protect
        (pilish-rr-bench--run-operation
         "resume"
         session
         (lambda ()
           (setq browser
                 (pilish-rr-bench--open-session-browser chat))
           (pilish-rr-bench--wait-for-session-browser browser)
           (pilish-rr-bench--select-session-path
            browser target-session)
           (with-current-buffer browser
             (pilish-session-browser-switch)))
         (lambda ()
           (and (not (with-current-buffer chat
                       (pilish--session-transition-active-p)))
                (= (or (pilish-rr-bench--canonical-message-count chat)
                       -1)
                   target-count)
                (equal (pilish-rr-bench--state-session-file chat)
                       target-session)
                (pilish-rr-bench--buffer-contains-p
                 chat "Session Target long session asks")
                (not (pilish-rr-bench--buffer-contains-p
                      chat "Session Current long session asks")))))
      (when (buffer-live-p browser)
        (kill-buffer browser))
      (pilish-rr-bench--cleanup-session session))))

(defun pilish-rr-bench--run-reload (current-session target-session
                                                           target-count)
  "Benchmark reload from CURRENT-SESSION to TARGET-SESSION.
TARGET-COUNT is the expected canonical message count after reload."
  (let* ((session (pilish-rr-bench--make-session
                   target-session current-session target-session))
         (chat (plist-get session :chat)))
    (unwind-protect
        (pilish-rr-bench--run-operation
         "reload"
         session
         (lambda () (with-current-buffer chat (pilish-reload)))
         (lambda ()
           (and (not (with-current-buffer chat
                       (pilish--session-transition-active-p)))
                (= (or (pilish-rr-bench--canonical-message-count chat)
                       -1)
                   target-count)
                (equal (pilish-rr-bench--state-session-file chat)
                       target-session)
                (pilish-rr-bench--buffer-contains-p
                 chat "Session Target long session asks")
                (not (pilish-rr-bench--buffer-contains-p
                      chat "Session Current long session asks")))))
      (pilish-rr-bench--cleanup-session session))))

(defun pilish-rr-bench--fake-rpc-summary ()
  "Return a content-free summary of fake RPC traffic for this iteration."
  (let ((get-messages nil)
        (commands nil))
    (when (file-readable-p pilish-rr-bench-fake-log)
      (with-temp-buffer
        (insert-file-contents pilish-rr-bench-fake-log)
        (goto-char (point-min))
        (while (not (eobp))
          (let* ((line (buffer-substring-no-properties (line-beginning-position)
                                                       (line-end-position)))
                 (obj (ignore-errors
                        (json-parse-string line :object-type 'plist))))
            (when (plist-get obj :direction)
              (let ((command (plist-get obj :command)))
                (when command (push command commands))
                (when (and (equal (plist-get obj :direction) "out")
                           (equal command "get_messages"))
                  (push (plist-get obj :bytes) get-messages)))))
          (forward-line 1))))
    (list :getMessagesBytes (vconcat (nreverse get-messages))
          :commands (vconcat (nreverse commands)))))

(defun pilish-rr-bench--top-timings-json (phase n)
  "Return the top N diagnostic timing rows for PHASE as a JSON vector."
  (vconcat
   (mapcar
    (lambda (row)
      (list :phase (plist-get row :phase)
            :name (plist-get row :name)
            :count (plist-get row :count)
            :totalSeconds (plist-get row :total)
            :maxSeconds (plist-get row :max)))
    (seq-take (pilish-rr-bench--timing-rows phase) n))))

(defun pilish-rr-bench--git-string (&rest args)
  "Run git with ARGS in the repository root and return trimmed output."
  (string-trim
   (with-temp-buffer
     (let ((default-directory pilish-rr-bench-repo-root))
       (if (zerop (apply #'process-file "git" nil t nil args))
           (buffer-string)
         "")))))

(defun pilish-rr-bench--workload-json (data)
  "Return workload DATA as a JSON-encodable plist."
  (let* ((current (plist-get data :current))
         (target (plist-get data :target)))
    (list :turns pilish-rr-bench-turns
          :otherSessions pilish-rr-bench-other-sessions
          :otherTurns pilish-rr-bench-other-turns
          :toolEvery pilish-rr-bench-tool-every
          :tableEvery pilish-rr-bench-table-every
          :thinkingEvery pilish-rr-bench-thinking-every
          :textBytes pilish-rr-bench-text-bytes
          :wireBytes pilish-rr-bench-wire-bytes
          :toolOutputLines pilish-rr-bench-tool-output-lines
          :sessionFileCount (plist-get data :session-file-count)
          :totalBytes (plist-get data :total-bytes)
          :fixtureRoot (plist-get data :fixture-root)
          :sessionDir (plist-get data :session-dir)
          :projectDir (plist-get data :project-dir)
          :current (list :path (plist-get current :path)
                         :bytes (plist-get current :bytes)
                         :messages (plist-get current :messages)
                         :tools (plist-get current :tools))
          :target (list :path (plist-get target :path)
                        :bytes (plist-get target :bytes)
                        :messages (plist-get target :messages)
                        :tools (plist-get target :tools)))))

(defun pilish-rr-bench--write-result-json (results data)
  "Write RESULTS and workload DATA to `pilish-rr-bench-result-file'."
  (let* ((dirty (not (string-empty-p
                      (pilish-rr-bench--git-string
                       "status" "--porcelain" "--untracked-files=no"))))
         (object (list :scenario pilish-rr-bench-scenario
                       :variant pilish-rr-bench-variant
                       :iteration pilish-rr-bench-iteration
                       :commit (pilish-rr-bench--git-string
                                "rev-parse" "--short" "HEAD")
                       :dirty (pilish-rr-bench--json-bool dirty)
                       :display (pilish-rr-bench--json-bool
                                 pilish-rr-bench-display-buffers)
                       :timingsEnabled (pilish-rr-bench--json-bool
                                        pilish-rr-bench-timings-enabled)
                       :emacsVersion emacs-version
                       :workload (pilish-rr-bench--workload-json data)
                       :results (vconcat results)
                       :rpc (pilish-rr-bench--fake-rpc-summary)
                       :topTimings
                       (list :resume (pilish-rr-bench--top-timings-json
                                      "resume" 20)
                             :reload (pilish-rr-bench--top-timings-json
                                      "reload" 20)))))
    (with-temp-file pilish-rr-bench-result-file
      (insert (json-encode object) "\n"))))

(defun pilish-rr-bench--operation-summary-table (results)
  "Return a Markdown table summarizing operation RESULTS."
  (concat
   "| operation | ok | wall seconds | GCs | GC seconds | buffer bytes | buffer lines | error |\n"
   "|---|---:|---:|---:|---:|---:|---:|---|\n"
   (mapconcat
    (lambda (result)
      (format "| %s | %s | %.3f | %d | %.3f | %s | %s | %s |"
              (plist-get result :name)
              (if (eq (plist-get result :ok) t) "yes" "no")
              (plist-get result :seconds)
              (plist-get result :gcs)
              (plist-get result :gcSeconds)
              (or (plist-get result :bufferBytes) "")
              (or (plist-get result :bufferLines) "")
              (or (plist-get result :error) "")))
    results "\n")))

(defun pilish-rr-bench--top-lines (phase &optional n)
  "Return Markdown rows for the top N timing rows in PHASE."
  (let ((rows (seq-take (pilish-rr-bench--timing-rows phase)
                        (or n 18))))
    (if rows
        (mapconcat
         (lambda (row)
           (format "| `%s` | %d | %.3f | %.3f |"
                   (plist-get row :name)
                   (plist-get row :count)
                   (plist-get row :total)
                   (plist-get row :max)))
         rows "\n")
      "| _(no timing data)_ | 0 | 0.000 | 0.000 |")))

(defun pilish-rr-bench--write-report (results data)
  "Write a Markdown report for RESULTS and workload DATA."
  (let ((dirty (not (string-empty-p
                     (pilish-rr-bench--git-string
                      "status" "--porcelain" "--untracked-files=no")))))
    (with-temp-file pilish-rr-bench-report-file
      (insert "# Deterministic reload/resume benchmark\n\n")
      (insert "Synthetic fixture only; no private session content is read or stored.\n\n")
      (insert (format "- Scenario: `%s`\n" pilish-rr-bench-scenario))
      (insert (format "- Variant: `%s`\n" pilish-rr-bench-variant))
      (insert (format "- Iteration: `%d`\n" pilish-rr-bench-iteration))
      (insert (format "- Commit: `%s`%s\n"
                      (pilish-rr-bench--git-string
                       "rev-parse" "--short" "HEAD")
                      (if dirty " (dirty)" "")))
      (insert (format "- Emacs: `%s`\n" emacs-version))
      (insert (format "- Visible GUI buffers: `%s`\n"
                      (if pilish-rr-bench-display-buffers
                          "yes" "no")))
      (insert (format "- Diagnostic timing advice: `%s`\n"
                      (if pilish-rr-bench-timings-enabled
                          "enabled" "disabled")))
      (insert "- Existing transcript pre-rendered before timed operation: `yes`\n\n")
      (insert "## Reproduction command shape\n\n")
      (insert "```sh\n")
      (insert (format "./bench/run-reload-resume-bench.sh %s --scenario %s -c 1 --out-dir %s\n"
                      (if pilish-rr-bench-display-buffers
                          "" "--batch")
                      pilish-rr-bench-scenario
                      pilish-rr-bench-runner-out-dir))
      (insert "```\n\n")
      (insert "## Workload\n\n")
      (let* ((current (plist-get data :current))
             (target (plist-get data :target)))
        (insert (format "- Fixture root: `%s`\n" (plist-get data :fixture-root)))
        (insert (format "- Session files: `%d`; total JSONL bytes: `%d`\n"
                        (plist-get data :session-file-count)
                        (plist-get data :total-bytes)))
        (insert (format "- Current: `%d` bytes, `%d` messages\n"
                        (plist-get current :bytes)
                        (plist-get current :messages)))
        (insert (format "- Target: `%d` bytes, `%d` messages\n"
                        (plist-get target :bytes)
                        (plist-get target :messages)))
        (insert (format "- Other sessions: `%d` x `%d` turns\n"
                        pilish-rr-bench-other-sessions
                        pilish-rr-bench-other-turns))
        (insert (format "- Tool/table/thinking cadence: `%d`/`%d`/`%d`; text bytes per text block: `%d`; ignored wire bytes per message: `%d`\n\n"
                        pilish-rr-bench-tool-every
                        pilish-rr-bench-table-every
                        pilish-rr-bench-thinking-every
                        pilish-rr-bench-text-bytes
                        pilish-rr-bench-wire-bytes)))
      (insert "## Wall-clock results\n\n")
      (insert (pilish-rr-bench--operation-summary-table results))
      (insert "\n\n")
      (insert "## Fake RPC payload evidence\n\n")
      (insert (format "- `get_messages` response byte sizes: `%S`\n\n"
                      (append (plist-get (pilish-rr-bench--fake-rpc-summary)
                                         :getMessagesBytes)
                              nil)))
      (dolist (phase '("resume" "reload"))
        (insert (format "## Top inclusive timings: %s\n\n" phase))
        (insert "| function/feature | calls | total seconds | max call seconds |\n")
        (insert "|---|---:|---:|---:|\n")
        (insert (pilish-rr-bench--top-lines phase 20))
        (insert "\n\n"))
      (insert "## Raw artifacts\n\n")
      (insert (format "- Result JSON: `%s`\n" pilish-rr-bench-result-file))
      (insert (format "- Timing TSV: `%s`\n" pilish-rr-bench-times-file))
      (insert (format "- Fake RPC log without content: `%s`\n"
                      pilish-rr-bench-fake-log)))))

(defun pilish-rr-bench--results-ok-p (results)
  "Return non-nil when every operation in RESULTS completed correctly."
  (and results
       (seq-every-p (lambda (result) (eq (plist-get result :ok) t))
                    results)))

(defun pilish-rr-bench-run ()
  "Run one reload/resume benchmark iteration and write artifacts.
Return non-nil when all correctness checks passed.  Timing thresholds are not
enforced."
  (make-directory pilish-rr-bench-out-dir t)
  (ignore-errors (delete-file pilish-rr-bench-fake-log))
  (clrhash pilish-rr-bench--timings)
  (pilish-rr-bench--install-timing-advices)
  (unwind-protect
      (let* ((data (pilish-rr-bench--prepare-data))
             (current-session (plist-get (plist-get data :current) :path))
             (target-session (plist-get (plist-get data :target) :path))
             (target-count (plist-get (plist-get data :target) :messages))
             (results nil))
        (push (pilish-rr-bench--run-resume
               current-session target-session target-count)
              results)
        (push (pilish-rr-bench--run-reload
               current-session target-session target-count)
              results)
        (setq results (nreverse results))
        (pilish-rr-bench--write-times-tsv)
        (pilish-rr-bench--write-result-json results data)
        (pilish-rr-bench--write-report results data)
        (princ (format "Wrote %s\n" pilish-rr-bench-result-file))
        (princ (format "Wrote %s\n" pilish-rr-bench-times-file))
        (princ (format "Wrote %s\n" pilish-rr-bench-report-file))
        (pilish-rr-bench--results-ok-p results))
    (pilish-rr-bench--remove-timing-advices)))

(defun pilish-rr-bench-run-batch ()
  "Run one reload/resume benchmark iteration in batch mode and exit."
  (let ((standard-output #'external-debugging-output))
    (kill-emacs (if (pilish-rr-bench-run) 0 1))))

(provide 'pilish-reload-resume-bench)
;;; pilish-reload-resume-bench.el ends here
