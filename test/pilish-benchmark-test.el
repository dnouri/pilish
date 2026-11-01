;;; pilish-benchmark-test.el --- Benchmark oracle contracts -*- lexical-binding: t; -*-

;;; Commentary:


;;; Code:

(require 'pilish-test-common)
(require 'pilish)
(load (expand-file-name "bench/pilish-stream-delta-bench.el"
                        (file-name-directory (locate-library "pilish"))) nil t)
(load (expand-file-name "bench/pilish-tool-update-bench.el"
                        (file-name-directory (locate-library "pilish"))) nil t)

(defconst pilish-benchmark-test--stream-names
  '("history-replayed" "representative-history-size"
    "exact-stream-payload-visible-projection" "representative-text-delta-count"
    "exact-delta-event-counts" "exact-stream-boundary-counts" "complete-lifecycle"
    "final-state-idle" "stream-flush-state-clean" "rpc-requests-drained"
    "timer-and-synchronous-flushes-observed" "display-calls-coalesced"
    "toolcall-paints-coalesced" "backlog-used-one-real-filter"
    "backlog-grouped-into-one-display-call" "md-ts-dirty-range-probe-guarded"))

(defconst pilish-benchmark-test--tool-names
  '("agent-end-received" "tool-execution-start-count" "tool-execution-end-count"
    "tool-execution-update-count" "subagent-blocks-present-once"
    "subagent-final-text-exactly-once" "no-live-tool-blocks-remain"))

(defconst pilish-benchmark-test--cooling-names
  '("agent-end-real-process-filter-path"
    "hot-tail-boundary-advances-only-at-agent-end"
    "current-tool-live-on-agent-end-entry"
    "agent-end-returns-with-whole-cohort-deferred"
    "cohort-has-collapsed-and-short-tools"
    "one-candidate-maximum-per-natural-callback"
    "natural-drain-settles-before-timeout" "exact-final-cold-hot-counts"
    "exact-cold-tool-cohort-composition" "current-inside-hot-tail-stays-hot"
    "semantic-sentinel-projection-hash-holds"
    "adjacent-hot-tail-table-remains-usable"
    "adjacent-hot-tail-table-overlay-present"
    "no-stale-buttons-diffs-or-tool-overlays"
    "cooling-scheduler-and-live-registry-clean"
    "parser-root-and-font-lock-usable" "command-loop-scroll-heartbeats-routed"
    "command-and-cooling-viewport-preserved"
    "cooling-wire-event-counts" "gui-frame-is-120x40"))

(defconst pilish-benchmark-test--cooling-categories
  '("behavior" "cooling-policy" "cooling-policy" "scheduler-contract"
    "cooling-policy" "scheduler-contract" "scheduler-contract" "cooling-policy"
    "cooling-policy" "cooling-policy" "behavior" "behavior" "viewport"
    "cooling-policy" "scheduler-contract" "behavior" "behavior" "viewport"
    "behavior" "viewport"))

(defconst pilish-benchmark-test--command
  "echo SD-BOUNDARY-TOOL; echo SD-CMD-0000; echo SD-CMD-0001; ")
(defconst pilish-benchmark-test--live-command
  "cooling-live --sentinel COOLING-SEMANTIC-LIVE")
(defconst pilish-benchmark-test--anchor
  "run the deterministic stream-delta benchmark\n\n")

(defun pilish-benchmark-test--stream-lines (prefix)
  "Return independent complete stream lines using tool title PREFIX."
  (append
   '("Assistant" "")
   (cl-loop for i below 12 collect
            (format "SD-TEXT-%04d value-%05d" i (mod (+ 20240817 (* i 7919)) 100000)))
   '("")
   (cl-loop for i below 6 collect
            (format "> SD-THINK-%04d thought-%05d" i (mod (+ 20240817 (* i 3571)) 100000)))
   '("Show less" "")
   (cl-loop for i below 20 collect
            (format "SD-BACKLOG-%04d value-%05d" i (mod (+ 20240817 (* i 6151)) 100000)))
   (list "" (concat prefix pilish-benchmark-test--command) "")))

(defun pilish-benchmark-test--read-json (file)
  "Parse actual artifact FILE with distinct null and false values."
  (with-temp-buffer
    (insert-file-contents file)
    (json-parse-buffer :object-type 'plist :null-object :null :false-object :false)))

(defun pilish-benchmark-test--stream-metrics (text &optional file)
  "Collect the complete stream verdict for raw TEXT, writing FILE if given."
  (let ((pilish-sd-bench-scenario "smoke")
        (pilish-sd-bench-history-turns 6)
        (pilish-sd-bench-timer-text-deltas 12)
        (pilish-sd-bench-thinking-deltas 6)
        (pilish-sd-bench-backlog-deltas 20)
        (pilish-sd-bench-toolcall-repeats 2)
        (pilish-sd-bench-seed 20240817)
        (pilish-sd-bench-burst-pause-ms 80)
        (pilish-sd-bench--event-counts (make-hash-table :test 'equal))
        (pilish-sd-bench--filter-rows '((:id 7 :backlog t :phase "stream" :wallMs 0)))
        (pilish-sd-bench--flush-rows '((:kind "timer") (:kind "synchronous")))
        (pilish-sd-bench--display-rows
         '((:kind "text" :phase "backlog-boundary" :flushKind "synchronous")
           (:kind "thinking" :phase "timer") (:kind "text" :phase "timer")))
        (pilish-sd-bench--backlog-filter-ids (make-list 20 7))
        (pilish-sd-bench--backlog-boundary-filter-id 7)
        (pilish-sd-bench--collector-complete t)
        (pilish-sd-bench--toolcall-paints 1)
        (pilish-sd-bench-result-file file))
    (dolist (entry `(("text_delta" . 32) ("thinking_delta" . 6)
                     ("text_start" . 2) ("text_end" . 2)
                     ("thinking_start" . 1) ("thinking_end" . 1)
                     ("toolcall_start" . 1) ("toolcall_end" . 1)
                     ("toolcall_delta" . ,(pilish-sd-bench--toolcall-delta-count))
                     ("agent_start" . 1) ("agent_end" . 1) ("agent_settled" . 1)
                     ("message_start" . 1) ("message_end" . 1)))
      (puthash (car entry) (cdr entry) pilish-sd-bench--event-counts))
    (with-temp-buffer
      (insert text)
      (setq-local pilish--status 'idle)
      (let* ((projection (pilish-sd-bench--actual-projection (current-buffer)))
             (md-ts '(:supported :json-false))
             (metrics
              (list :settled t :projection projection :mdTs md-ts
                    :checks (pilish-sd-bench--collect-checks
                             (current-buffer) nil 12 5000 projection md-ts))))
        (when file
          (pilish-sd-bench--write-result-json
           metrics (pilish-sd-bench--metrics-ok-p metrics)))
        metrics))))

(defun pilish-benchmark-test--cooling-lines (prefix)
  "Return the independent ordered cooling projection with title PREFIX."
  (list "COOLING-SEMANTIC call-cooling-0000"
        "COOLING-SEMANTIC call-cooling-0001"
        "| COOLING-SEMANTIC-HOT-TABLE | hot | remains decorated and outside the completed cooling cohort |"
        (concat prefix pilish-benchmark-test--live-command)))

(defun pilish-benchmark-test--cooling-metrics (post final &optional gui file mutate)
  "Collect both real semantic projections from POST and FINAL line lists.
GUI makes viewport rows required.  Write the actual artifact to FILE if given.
MUTATE can damage the collected drain and final state before checks run."
  (let* ((pilish-tu-bench-scenario "agent-end-cooling-smoke")
         (pilish-tu-bench-fill-bash 1) (pilish-tu-bench-fill-read 1)
         (pilish-tu-bench-fill-write 0) (pilish-tu-bench-fill-edit 0)
         (pilish-tu-bench-display-buffers gui)
         (noninteractive (not gui))
         (pilish-tu-bench--agent-end-time 1)
         (pilish-tu-bench--agent-end-filter '(:id 7 :wallMs 0))
         (pilish-tu-bench--agent-end-observation
          (with-temp-buffer
            (insert (string-join post "\n"))
            (let ((summary (pilish-tu-bench--semantic-summary)))
              (list :wallMs 0 :boundaryBefore 1 :boundaryAfter 2
                    :liveRegistryBefore 1 :currentOverlayBefore 1
                    :queueAfter 2 :timerAfter t :coldAfter 0 :toolOverlaysAfter 3
                    :collapsedToolOverlaysBefore 1
                    :semanticLinesAfter (car summary) :semanticHashAfter (cdr summary)))))
         (pilish-tu-bench--cooling-slice-log
          (copy-tree
           '((:queueDelta 1 :candidateEligible t :candidateOverlayAliveAfter :json-false
              :window (:available t :status "pass")
              :treeRoots (:count 0 :totalMs 0 :maxMs 0))
             (:queueDelta 1 :candidateEligible t :candidateOverlayAliveAfter :json-false
              :window (:available t :status "pass")
              :treeRoots (:count 0 :totalMs 0 :maxMs 0)))))
         (pilish-tu-bench--command-log
          (copy-tree
           '((:route "sentinel" :preHook t :postHook t :error nil
              :window (:available t :status "pass") :latenessMs 0 :durationMs 0)
             (:route "follow" :preHook t :postHook t :error nil
              :window (:available t :status "pass") :latenessMs 0 :durationMs 0))))
         (pilish-tu-bench--scheduler-errors nil)
         (pilish-tu-bench--event-log
          '(("tool_execution_start" . 0) ("tool_execution_start" . 0)
            ("tool_execution_start" . 0) ("tool_execution_end" . 0)
            ("tool_execution_end" . 0) ("agent_end" . 0)))
         (pilish-tu-bench--render-log (make-hash-table :test 'equal))
         (pilish-tu-bench-result-file file)
         (drain (copy-tree '(:settled t :wallMs 0 :activeMs 0 :timeoutSeconds 30
                            :finalWindow (:available t :status "pass")))))
    (with-temp-buffer
      (insert (string-join final "\n"))
      (let* ((summary (pilish-tu-bench--semantic-summary))
             (state
              (list :coldTools 2 :coldToolNames '(:bash 1 :read 1 :write 0 :edit 0)
                    :pathBearingColdTools 1 :toolOverlays 1
                    :toolOverlayIds (vector pilish-tu-bench-cooling-live-id)
                    :currentInsideHotTail t :currentColdProperty :json-false
                    :currentOverlayStart (point-max) :tableOverlays 1
                    :window '(:available t :status "pass")
                    :buttons 0 :diffOverlays 0 :queueLength 0 :timerOwned :json-false
                    :liveToolRegistry 0 :pendingToolOverlay :json-false
                    :parser '(:parserOk t :fontLockOk t)
                    :semanticLineCount (car summary) :semanticHash (cdr summary)
                    :geometry '(:frameColumns 120 :frameLines 40 :chatColumns 120 :chatLines 30)))
             (metrics
              (pilish-tu-bench--metrics-with-verdict
               (list :settled t :drain drain :final state
                     :checks (progn
                               (when mutate (funcall mutate drain state))
                               (pilish-tu-bench--collect-cooling-checks
                                (current-buffer) drain state))))))
        (when file (pilish-tu-bench--write-result-json metrics))
        metrics))))

(defun pilish-benchmark-test--assert-verdict (metrics name good &optional stream)
  "Require named check NAME and full METRICS verdict to agree with GOOD.
STREAM chooses the stream engine rather than the tool engine."
  (let ((check (seq-find (lambda (row) (equal (plist-get row :name) name))
                         (plist-get metrics :checks))))
    (should check)
    (if stream
        (should (eq (plist-get check :ok) (if good t :json-false)))
      (should (equal (plist-get check :status) (if good "pass" "fail"))))
    (should (eq (and (if stream (pilish-sd-bench--metrics-ok-p metrics)
                       (pilish-tu-bench--metrics-ok-p metrics)) t) good))
    (unless stream
      (should (= (pilish-tu-bench--exit-status (eq (plist-get metrics :ok) t))
                 (if good 0 1))))))

(ert-deftest pilish-test-benchmark-stream-exact-contract ()
  "Accept only complete supported titles and reject damaged stream spans."
  (let* ((good (pilish-benchmark-test--stream-lines "$ "))
         (slot (- (length good) 2))
         (title (nth slot good))
         (file (make-temp-file "pilish-stream-oracle-" nil ".json")))
    (unwind-protect
        (progn
          (dolist (prefix '("$ " "bash "))
            (let* ((metrics
                    (pilish-benchmark-test--stream-metrics
                     (concat pilish-benchmark-test--anchor
                             (string-join (pilish-benchmark-test--stream-lines prefix) "\n")) file))
                   (json (pilish-benchmark-test--read-json file)))
              (pilish-benchmark-test--assert-verdict
               metrics "exact-stream-payload-visible-projection" t t)
              (should (eq (plist-get json :ok) t))
              (should (equal (mapcar (lambda (row) (plist-get row :name))
                                     (plist-get metrics :checks))
                             pilish-benchmark-test--stream-names))))
          (dolist (case
                   `((altered . ,(replace-regexp-in-string "BOUNDARY" "BOUNXARY" title))
                     (dropped-byte . ,(substring title 0 -2))
                     (no-title . ,pilish-benchmark-test--command)
                     (raw-payload . ,(substring pilish-benchmark-test--command 5))
                     (no-echo . ,(concat "$ " (substring pilish-benchmark-test--command 5)))
                     (wrong-token . ,(concat "sh " pilish-benchmark-test--command))
                     (trimmed . ,(string-trim-right title))
                     (extra-byte . ,(concat title "x"))
                     (duplicate . duplicate) (omitted . omitted)
                     (reordered . reordered) (extra-text . extra-text)
                     (wrong-ordinal . wrong-ordinal)))
            (ert-info ((format "Stream corruption %s" (car case)))
              (let ((lines (copy-sequence good)))
                (pcase (cdr case)
                  ('duplicate (setq lines (append lines (list title))))
                  ('omitted (setf (nth slot lines) ""))
                  ('reordered (cl-rotatef (nth 2 lines) (nth 3 lines)))
                  ('extra-text (setq lines (append lines '("unexpected visible text"))))
                  ('wrong-ordinal (cl-rotatef (nth slot lines) (nth (1- slot) lines)))
                  (replacement (setf (nth slot lines) replacement)))
                (let* ((metrics (pilish-benchmark-test--stream-metrics
                                 (concat pilish-benchmark-test--anchor (string-join lines "\n")) file))
                       (json (pilish-benchmark-test--read-json file)))
                  (pilish-benchmark-test--assert-verdict
                   metrics "exact-stream-payload-visible-projection" nil t)
                  (should (eq (plist-get json :ok) :false)))))))
      (delete-file file))))

(ert-deftest pilish-test-benchmark-reader-contract ()
  (let* ((state '(:start 1 :point 1 :following :json-false))
         (pilish-sd-bench-scenario "reader")
         (pilish-sd-bench-timer-text-deltas 12)
         (pilish-sd-bench-backlog-deltas 20)
         (pilish-sd-bench--event-counts (make-hash-table :test 'equal))
         (pilish-sd-bench--reader-initial (copy-sequence state))
         (pilish-sd-bench--reader-settled (copy-sequence state))
         (pilish-sd-bench--thinking-end-rows
          (list (list :before (copy-sequence state) :after (copy-sequence state)
                      :wallMs 0 :jitCreated 0)))
         (reader-names '("non-tail-reader-observed" "reader-start-preserved"
                         "reader-point-preserved")))
    (cl-labels ((metrics () (list :settled t :checks (pilish-sd-bench--reader-checks))))
      (should (pilish-sd-bench--metrics-ok-p (metrics)))
      (let ((checks (pilish-sd-bench--collect-checks
                     nil nil 0 0 "" '(:supported :json-false))))
        (should (equal (mapcar (lambda (row) (plist-get row :name)) checks)
                       (append pilish-benchmark-test--stream-names reader-names)))
        (dolist (name '("representative-history-size" "representative-text-delta-count"
                        "timer-and-synchronous-flushes-observed"))
          (should (eq (plist-get (seq-find
                                  (lambda (row) (equal (plist-get row :name) name))
                                  checks) :ok)
                      :json-false))))
      (dolist (sample (list pilish-sd-bench--reader-initial
                            (plist-get (car pilish-sd-bench--thinking-end-rows) :before)
                            (plist-get (car pilish-sd-bench--thinking-end-rows) :after)
                            pilish-sd-bench--reader-settled))
        (dolist (case '((:start 2 "reader-start-preserved")
                        (:point 2 "reader-point-preserved")
                        (:following t "non-tail-reader-observed")))
          (let ((old (plist-get sample (car case))))
            (setf (plist-get sample (car case)) (cadr case))
            (pilish-benchmark-test--assert-verdict (metrics) (nth 2 case) nil t)
            (setf (plist-get sample (car case)) old))))
      (let ((pilish-sd-bench--thinking-end-rows nil))
        (pilish-benchmark-test--assert-verdict
         (metrics) "non-tail-reader-observed" nil t))
      (let ((pilish-sd-bench--reader-settled nil))
        (pilish-benchmark-test--assert-verdict
         (metrics) "reader-start-preserved" nil t)))))

(ert-deftest pilish-test-benchmark-reader-timer-ownership ()
  (with-temp-buffer
    (let ((pilish-sd-bench--reader-chat-buffer (current-buffer))
          (pilish-sd-bench--phase "stream")
          (pilish-sd-bench--jit-created 0)
          (owned (copy-marker (point-min)))
          (detached (make-marker)))
      (with-temp-buffer
        (let ((foreign (copy-marker (point-min))))
          (dolist (case `((jit-lock-force-redisplay ,owned)
                          (jit-lock-force-redisplay ,foreign)
                          (jit-lock-force-redisplay ,detached)
                          (ignore ,owned)))
            (should (eq (pilish-sd-bench--around-run-with-timer
                         (lambda (&rest _) 'timer) 0 nil (car case) (cadr case))
                        'timer)))
          (should (= pilish-sd-bench--jit-created 1))
          (let ((pilish-sd-bench--phase "validation"))
            (pilish-sd-bench--around-run-with-timer
             #'ignore 0 nil 'jit-lock-force-redisplay owned))
          (should (= pilish-sd-bench--jit-created 1)))))))

(ert-deftest pilish-test-benchmark-cooling-exact-contract ()
  "Retain order and multiplicity at each cooling observation independently."
  (let* ((good (pilish-benchmark-test--cooling-lines "$ "))
         (title (nth 3 good))
         (file (make-temp-file "pilish-cooling-oracle-" nil ".json")))
    (unwind-protect
        (progn
          (dolist (post '("$ " "bash "))
            (dolist (final '("$ " "bash "))
              (let ((metrics (pilish-benchmark-test--cooling-metrics
                              (pilish-benchmark-test--cooling-lines post)
                              (pilish-benchmark-test--cooling-lines final) nil file)))
                (pilish-benchmark-test--assert-verdict
                 metrics "semantic-sentinel-projection-hash-holds" t)
                (should (eq (plist-get (pilish-benchmark-test--read-json file) :ok) t)))))
          (dolist (phase '(post final))
            (dolist (case
                     `((altered . ,(replace-regexp-in-string "cooling-live" "cooling-livx" title))
                       (dropped-byte . ,(replace-regexp-in-string "--sentinel" "--sentine" title))
                       (no-title . ,pilish-benchmark-test--live-command)
                       (raw-payload . "COOLING-SEMANTIC-LIVE")
                       (wrong-token . ,(concat "sh " pilish-benchmark-test--live-command))
                       (trailing-byte . ,(concat title " "))
                       (duplicate . duplicate) (omitted . omitted)
                       (reordered . reordered) (extra-text . extra-text)
                       (wrong-ordinal . wrong-ordinal)))
              (ert-info ((format "Cooling %s corruption %s" phase (car case)))
                (let ((bad (copy-sequence good)))
                  (pcase (cdr case)
                    ('duplicate (setq bad (append bad (list title))))
                    ('omitted (setq bad (cdr bad)))
                    ('reordered (cl-rotatef (nth 0 bad) (nth 1 bad)))
                    ('extra-text (setq bad (append bad '("COOLING-SEMANTIC extra text"))))
                    ('wrong-ordinal (cl-rotatef (nth 2 bad) (nth 3 bad)))
                    (replacement (setf (nth 3 bad) replacement)))
                  (let* ((metrics (pilish-benchmark-test--cooling-metrics
                                   (if (eq phase 'post) bad good)
                                   (if (eq phase 'final) bad good) nil file))
                         (json (pilish-benchmark-test--read-json file)))
                    (pilish-benchmark-test--assert-verdict
                     metrics "semantic-sentinel-projection-hash-holds" nil)
                    (should (eq (plist-get json :ok) :false))))))))
      (delete-file file))))

(ert-deftest pilish-test-benchmark-check-inventory ()
  "Keep the full inventories and their categories in both lanes."
  (dolist (gui '(nil t))
    (let* ((lines (pilish-benchmark-test--cooling-lines "bash "))
           (metrics (pilish-benchmark-test--cooling-metrics lines lines gui)))
      (should (pilish-tu-bench--metrics-ok-p metrics))
      (should (equal (mapcar (lambda (row) (plist-get row :name))
                             (plist-get metrics :checks))
                     pilish-benchmark-test--cooling-names))
      (should (equal (mapcar (lambda (row) (plist-get row :category))
                            (plist-get metrics :checks))
                     pilish-benchmark-test--cooling-categories))
      (dolist (row (plist-get metrics :checks))
        (should (equal (plist-get row :status)
                       (if (and (not gui) (equal (plist-get row :category) "viewport"))
                           "not-applicable" "pass"))))))
  (with-temp-buffer
    (pilish-chat-mode)
    (let ((pilish-tu-bench-fill-bash 0) (pilish-tu-bench-fill-read 0)
          (pilish-tu-bench-fill-write 0) (pilish-tu-bench-fill-edit 0)
          (pilish-tu-bench-parallel-tools 1) (pilish-tu-bench-updates 1)
          (pilish-tu-bench--agent-end-time 1)
          (pilish-tu-bench--event-log
           '(("tool_execution_start" . 0) ("tool_execution_update" . 0)
             ("tool_execution_end" . 0))))
      (let ((block (pilish--display-tool-start "subagent" '(:agent "worker") "call-storm-00")))
        (pilish--display-tool-end "subagent" '(:agent "worker")
                                 [(:type "text" :text "STORM-FINAL-RESULT call-storm-00")]
                                 nil nil block))
      (let ((metrics (pilish-tu-bench--metrics-with-verdict
                      (list :settled t :checks (pilish-tu-bench--collect-checks (current-buffer))))))
        (should (pilish-tu-bench--metrics-ok-p metrics))
        (should (equal (mapcar (lambda (row) (plist-get row :name))
                               (plist-get metrics :checks))
                       pilish-benchmark-test--tool-names))
        (should (seq-every-p (lambda (row)
                              (and (equal (plist-get row :category) "behavior")
                                   (equal (plist-get row :status) "pass")))
                            (plist-get metrics :checks)))))))

(ert-deftest pilish-test-benchmark-production-stream-canary ()
  "Project a real rendered stream against an independent full-title oracle."
  (let ((pilish-thinking-display 'visible))
    (with-temp-buffer
      (pilish-chat-mode)
      (pilish--display-user-message "run the deterministic stream-delta benchmark")
      (pilish--handle-display-event '(:type "agent_start"))
      (pilish--handle-display-event '(:type "message_start" :message (:role "assistant")))
      (pilish--display-message-delta
       (concat (string-join (seq-subseq (pilish-benchmark-test--stream-lines "$ ") 2 14) "\n") "\n"))
      (pilish--display-thinking-start)
      (pilish--display-thinking-delta
       (concat (string-join
                (mapcar (lambda (line) (substring line 2))
                        (seq-subseq (pilish-benchmark-test--stream-lines "$ ") 15 21)) "\n") "\n"))
      (pilish--display-thinking-end nil)
      (pilish--display-message-delta
       (concat (string-join (seq-subseq (pilish-benchmark-test--stream-lines "$ ") 23 43) "\n") "\n"))
      (pilish-test--send-toolcall-message-update
       "toolcall_end" 0
       (list (pilish-test--toolcall "boundary" "bash" (list :command pilish-benchmark-test--command))))
      (font-lock-ensure (point-min) (point-max))
      (let* ((actual (substring-no-properties (pilish--visible-text (point-min) (point-max))))
             (metrics (pilish-benchmark-test--stream-metrics actual)))
        (pilish-benchmark-test--assert-verdict metrics "exact-stream-payload-visible-projection" t t)))))

(ert-deftest pilish-test-benchmark-production-cooling-canary ()
  "Read real execution titles and outputs through the cooling verdict."
  (with-temp-buffer
    (pilish-chat-mode)
    (dotimes (i 2)
      (let ((block (pilish--display-tool-start "bash" '(:command "true") (format "call-cooling-%04d" i))))
        (pilish--display-tool-end "bash" '(:command "true")
                                 (vector (list :type "text" :text (format "COOLING-SEMANTIC call-cooling-%04d" i)))
                                 nil nil block)))
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert "| COOLING-SEMANTIC-HOT-TABLE | hot | remains decorated and outside the completed cooling cohort |\n"))
    (pilish--display-tool-start "bash" (list :command pilish-benchmark-test--live-command) "live")
    (let* ((lines (pilish-tu-bench--semantic-lines))
           (metrics (pilish-benchmark-test--cooling-metrics lines lines)))
      (pilish-benchmark-test--assert-verdict metrics "semantic-sentinel-projection-hash-holds" t))))

(ert-deftest pilish-test-benchmark-tool-json-boundary ()
  "Actual constructors and writers distinguish null, false, arrays and data."
  (let* ((file (make-temp-file "pilish-tool-json-" nil ".json"))
         (pilish-tu-bench-result-file file)
         (pilish-tu-bench-report-file (concat file ".md"))
         (pilish-tu-bench-cooling-slices-file (concat file ".slices.tsv"))
         (pilish-tu-bench-commands-file (concat file ".commands.tsv"))
         (pilish-tu-bench-scenario "agent-end-cooling-smoke")
         (pilish-tu-bench-display-buffers nil)
         (pilish-tu-bench--agent-end-observation nil)
         (pilish-tu-bench--agent-end-filter nil)
         (pilish-tu-bench--cooling-slice-log nil)
         (pilish-tu-bench--cooling-slice-sequence 0)
         (pilish-tu-bench--command-log nil)
         (pilish-tu-bench--command-pending nil)
         (pilish-tu-bench--command-drain-active nil)
         (pilish-tu-bench--command-current-job nil)
         (pilish-tu-bench--cooling-chat-buffer nil)
         (pilish-tu-bench--window-sentinel-marker nil)
         (pilish-tu-bench--command-last-route nil)
         (pilish-tu-bench--scheduler-errors nil)
         (pilish-tu-bench--render-log (make-hash-table :test 'equal))
         (json-null :hostile-null) (json-false :hostile-false))
    (unwind-protect
        (with-temp-buffer
          (pilish-chat-mode)
          (let ((inhibit-read-only t)) (insert "COOLING-WINDOW-SENTINEL\n"))
          (pilish-tu-bench--around-cooling-slice #'ignore (current-buffer) 0)
          (should-not (plist-get (car pilish-tu-bench--cooling-slice-log) :candidateId))
          (pilish-tu-bench--install-command-route (current-buffer))
          (setq pilish-tu-bench--command-pending
                '((:route "sentinel" :sequence 1 :dueAt 0 :enqueuedAt 0)))
          (pilish-tu-bench--route-command-event pilish-tu-bench-command-event)
          (should-not (plist-get (car pilish-tu-bench--command-log) :error))
          (pilish-tu-bench--write-cooling-tsv)
          (with-temp-buffer
            (insert-file-contents pilish-tu-bench-commands-file)
            (should (string-match-p "window_status" (buffer-string)))
            (should (string-match-p "\tnot-applicable\t" (buffer-string)))
            (should (equal (car (last (split-string
                                      (nth 1 (split-string (buffer-string) "\n" t))
                                      "\t" nil))) "")))
          (with-temp-buffer
            (insert-file-contents pilish-tu-bench-cooling-slices-file)
            (should (string-match-p "window_status" (buffer-string)))
            (should (string-match-p "\tnot-applicable\n" (buffer-string))))
          (setq-local pilish--hot-tail-start nil)
          (let* ((parser (pilish-tu-bench--parser-font-lock-state (current-buffer)))
                 (state (pilish-tu-bench--cooling-final-state (current-buffer) parser))
                 (metrics (pilish-tu-bench--metrics-with-verdict
                           (list :settled t :wallMs 0 :seconds 0 :error nil :final state
                                 :checks (list (pilish-tu-bench--check "writer-contract" "behavior" t "")
                                               (pilish-tu-bench--check "batch-view" "viewport" nil "not observed"))))))
            (should-not (plist-get parser :parserError))
            (should-not (plist-get parser :fontLockError))
            (dolist (key '(:currentOverlayStart :currentOverlayEnd :hotTailBoundary :geometry))
              (should-not (plist-get state key)))
            (pilish-tu-bench--write-result-json metrics)
            (pilish-tu-bench--write-report metrics t)
            (with-temp-buffer
              (insert-file-contents pilish-tu-bench-report-file)
              (should (string-match-p "| check | category | status | detail |" (buffer-string)))
              (should (string-match-p "| `writer-contract` | behavior | pass |" (buffer-string)))
              (should (string-match-p "| `batch-view` | viewport | not-applicable |" (buffer-string))))
            (let* ((json (pilish-benchmark-test--read-json file))
                   (cooling (plist-get json :cooling))
                   (final (plist-get cooling :final)))
              (should (eq (plist-get json :error) :null))
              (should (eq (plist-get json :agentEnd) :null))
              (should (eq (plist-get (plist-get json :processFilters) :agentEnd) :null))
              (should (eq (plist-get cooling :drain) :null))
              (should (eq (plist-get (aref (plist-get cooling :slices) 0) :candidateId) :null))
              (should (eq (plist-get (aref (plist-get (plist-get cooling :commands) :rows) 0) :error) :null))
              (should (eq (plist-get (plist-get final :parser) :parserError) :null))
              (should (eq (plist-get (plist-get final :parser) :fontLockError) :null))
              (dolist (key '(:currentOverlayStart :currentOverlayEnd :hotTailBoundary :geometry))
                (should (eq (plist-get final key) :null)))
              (should (equal (plist-get final :toolOverlayIds) []))
              (should (equal (plist-get cooling :schedulerErrors) []))
              (should (eq (plist-get final :timerOwned) :false))
              (should (eq (plist-get json :display) :false))
              (should (= (plist-get json :wallMs) 0))
              (should (equal (plist-get (aref (plist-get json :checks) 0) :detail) ""))
              (should (equal (plist-get (aref (plist-get json :checks) 0) :category) "behavior"))
              (should (equal (plist-get (aref (plist-get json :checks) 0) :status) "pass"))
              (should-not (plist-member (aref (plist-get json :checks) 0) :ok))
              (should (equal (plist-get (aref (plist-get json :checks) 1) :status) "not-applicable"))
              (let ((window (plist-get (aref (plist-get cooling :slices) 0) :window)))
                (should (equal (plist-get window :status) "not-applicable"))))
            (setf (plist-get metrics :wallMs) nil)
            (pilish-tu-bench--write-result-json metrics)
            (should (eq (plist-get (pilish-benchmark-test--read-json file) :wallMs) :null))
            (cl-letf (((symbol-function 'pilish--markdown-parser) (lambda () (error "json-null"))))
              (setq parser (pilish-tu-bench--parser-font-lock-state (current-buffer))))
            (should (equal (plist-get parser :parserError) "json-null"))
            (dolist (key '(:rootType :rootStart :rootEnd))
              (should-not (plist-get parser key)))
            (setq state (pilish-tu-bench--cooling-final-state (current-buffer) parser))
            (setq metrics (pilish-tu-bench--metrics-with-verdict
                           (list :settled t :error "json-null" :final state
                                 :checks (list (pilish-tu-bench--check
                                                "parser-contract" "behavior" (eq (plist-get parser :parserOk) t) "")))))
            (should-not (pilish-tu-bench--metrics-ok-p metrics))
            (pilish-tu-bench--write-result-json metrics)
            (let* ((json (pilish-benchmark-test--read-json file))
                   (parsed (plist-get (plist-get (plist-get json :cooling) :final) :parser)))
              (should (equal (plist-get json :error) "json-null"))
              (should (eq (plist-get json :ok) :false))
              (should (equal (plist-get parsed :parserError) "json-null"))
              (dolist (key '(:rootType :rootStart :rootEnd))
                (should (eq (plist-get parsed key) :null))))
            (let ((pilish-tu-bench-scenario "smoke"))
              (pilish-tu-bench--write-result-json metrics)
              (should (eq (plist-get (pilish-benchmark-test--read-json file) :cooling) :null)))
            (pilish-tu-bench--validate-verdict-contract)))
      (delete-file file)
      (dolist (artifact (list pilish-tu-bench-cooling-slices-file pilish-tu-bench-commands-file
                              pilish-tu-bench-report-file))
        (when (file-exists-p artifact) (delete-file artifact))))))

(ert-deftest pilish-test-benchmark-status-verdict-matrix ()
  "Reject absent or invalid required rows, including forged exemptions."
  (dolist (gui '(nil t))
    (let ((pilish-tu-bench-display-buffers gui))
      (dolist (category '("behavior" "cooling-policy" "scheduler-contract" "viewport"))
        (dolist (status '("pass" "fail" "not-applicable" nil "" "unknown" t ["pass"]))
          (let* ((row (list :name "matrix" :category category :status status))
                 (metrics (pilish-tu-bench--metrics-with-verdict
                           (list :settled t :checks (list row))))
                 (expected (or (equal status "pass")
                               (and (not gui) (equal category "viewport")
                                    (equal status "not-applicable")))))
            (should (eq (eq (plist-get metrics :ok) t) expected))
            (should-not (pilish-tu-bench--metrics-ok-p
                         (list :settled :json-false :checks (list row)))))))
      (dolist (checks '(nil [] "checks" (nil) (garbage) (42)
                           ((:name "old-schema" :ok t))
                           ((:name "unknown" :category "other" :status "pass"))
                           ((:name "" :category "behavior" :status "pass"))
                           ((:category "behavior" :status "pass"))))
        (should-not (pilish-tu-bench--metrics-ok-p (list :settled t :checks checks)))))))

(ert-deftest pilish-test-benchmark-missing-window-evidence ()
  "A missing GUI window fails; a batch observation never invents view success."
  (dolist (gui '(nil t))
    (let* ((pilish-tu-bench-display-buffers gui)
           (pilish-tu-bench--cooling-chat-buffer nil)
           (window (pilish-tu-bench--capture-window-state)))
      (should (eq (plist-get window :available) :json-false))
      (should (equal (plist-get window :status) (if gui "fail" "not-applicable")))))
  (save-window-excursion
    (with-temp-buffer
      (insert "COOLING-WINDOW-SENTINEL\nnot a sentinel\n")
      (let ((pilish-tu-bench-display-buffers t)
            (pilish-tu-bench--cooling-chat-buffer (current-buffer))
            (pilish-tu-bench--command-last-route "sentinel")
            (window (selected-window)))
        (set-window-buffer window (current-buffer))
        (set-window-start window (point-min))
        (set-window-point window (point-min))
        (let ((state (pilish-tu-bench--capture-window-state)))
          (should (eq (plist-get state :available) t))
          (should (equal (plist-get state :status) "pass"))
          (should (equal (plist-get state :startLine) "COOLING-WINDOW-SENTINEL")))
        (set-window-point window (point-max))
        (should (equal (plist-get (pilish-tu-bench--capture-window-state) :status) "fail"))))))

(ert-deftest pilish-test-benchmark-viewport-and-routing-independent ()
  "Require nonempty GUI view observations without weakening command routing."
  (let ((lines (pilish-benchmark-test--cooling-lines "$ ")))
    (dolist (case '(missing-window missing-geometry wrong-geometry malformed-geometry missing-table
                   missing-commands missing-slices missing-final-window
                   bad-command-window bad-slice-window bad-hook))
      (dolist (gui '(nil t))
        (let* ((metrics
                (pilish-benchmark-test--cooling-metrics
                 lines lines gui nil
                 (lambda (drain state)
                   (pcase case
                     ('missing-window (setf (plist-get state :window) nil))
                     ('missing-geometry (setf (plist-get state :geometry) nil))
                     ('wrong-geometry (setf (plist-get state :geometry)
                                            '(:frameColumns 119 :frameLines 40)))
                     ('malformed-geometry (setf (plist-get state :geometry)
                                                '(:frameColumns "120" :frameLines 40)))
                     ('missing-table (setf (plist-get state :tableOverlays) 0))
                     ('missing-commands (setq pilish-tu-bench--command-log nil))
                     ('missing-slices (setq pilish-tu-bench--cooling-slice-log nil))
                     ('missing-final-window (setf (plist-get drain :finalWindow) nil))
                     ('bad-command-window
                      (setf (plist-get (car pilish-tu-bench--command-log) :window)
                            '(:available t :status "unknown")))
                     ('bad-slice-window
                      (setf (plist-get (car pilish-tu-bench--cooling-slice-log) :window)
                            '(:available t :status "not-applicable")))
                     ('bad-hook
                      (setf (plist-get (car pilish-tu-bench--command-log) :preHook) nil))))))
               (checks (plist-get metrics :checks))
               (routing (seq-find (lambda (row) (equal (plist-get row :name)
                                                        "command-loop-scroll-heartbeats-routed")) checks))
               (table (seq-find (lambda (row) (equal (plist-get row :name)
                                                      "adjacent-hot-tail-table-remains-usable")) checks)))
          (should (equal (plist-get routing :status)
                         (if (memq case '(missing-commands bad-hook)) "fail" "pass")))
          (should (equal (plist-get table :status) "pass"))
          (let* ((name (pcase case
                         ((or 'missing-window 'missing-geometry 'wrong-geometry 'malformed-geometry)
                          "gui-frame-is-120x40")
                         ('missing-table "adjacent-hot-tail-table-overlay-present")
                         ('bad-hook "command-loop-scroll-heartbeats-routed")
                         (_ "command-and-cooling-viewport-preserved")))
                 (row (seq-find (lambda (entry) (equal (plist-get entry :name) name)) checks)))
            (should (equal (plist-get row :status)
                           (if (or gui (eq case 'bad-hook)) "fail" "not-applicable"))))
          (dolist (row checks)
            (when (equal (plist-get row :category) "viewport")
              (when (not gui) (should (equal (plist-get row :status) "not-applicable")))))
          (should (eq (eq (plist-get metrics :ok) t)
                      (and (not gui) (not (memq case '(missing-commands missing-slices bad-hook)))))))))
    (dolist (evidence '(nil 42 "bad" [nil] (:status "pass")
                           (:available t) (:available t :status "")
                           (:available t :status "fail")
                           (:available :json-false :status "pass")))
      (should-not (pilish-tu-bench--window-passed-p evidence)))))

(defun pilish-benchmark-test--shell-summary (result mode)
  "Run the runner's actual Python summary on RESULT in MODE.
Return the exit status, CSV text and Markdown text.  No benchmark is run."
  (let* ((directory (make-temp-file "pilish-summary-" t))
         (run (expand-file-name "smoke/iter-01" directory))
         (script (expand-file-name "bench/run-tool-update-bench.sh"
                                   pilish-tu-bench-repo-root)))
    (unwind-protect
        (progn
          (make-directory run t)
          (with-temp-file (expand-file-name "result.json" run)
            (let ((json-false :json-false) (json-null nil)) (insert (json-encode result))))
          (let ((status
                 (with-temp-buffer
                   (insert-file-contents script)
                   (goto-char (point-min))
                   (search-forward "<<'PY'\n")
                   (delete-region (point-min) (point))
                   (goto-char (point-max))
                   (search-backward "\nPY")
                   (delete-region (point) (point-max))
                   (call-process-region (point-min) (point-max) "python3" nil nil nil
                                        "-" directory mode "1" "smoke"))))
            (list status
                  (with-temp-buffer
                    (insert-file-contents (expand-file-name "summary.csv" directory))
                    (buffer-string))
                  (with-temp-buffer
                    (insert-file-contents (expand-file-name "summary.md" directory))
                    (buffer-string)))))
      (delete-directory directory t))))

(ert-deftest pilish-test-benchmark-shell-summary-status-contract ()
  "The shell independently rejects invalid rows and contradictory verdicts."
  (dolist (mode '("batch" "gui-xvfb"))
    (dolist (category '("behavior" "cooling-policy" "scheduler-contract" "viewport" "unknown"))
      (dolist (status '("pass" "fail" "not-applicable" nil "" "unknown" t []))
        (let* ((expected (and (not (equal category "unknown"))
                              (or (equal status "pass")
                                  (and (equal mode "batch") (equal category "viewport")
                                       (equal status "not-applicable")))))
               (result (list :scenario "smoke" :iteration 1 :settled t :ok
                             (if expected t :json-false)
                             :checks (vector (list :name "summary-row" :category category :status status)))))
          (should (= (car (pilish-benchmark-test--shell-summary result mode))
                     (if expected 0 1)))
          (setf (plist-get result :ok) (if expected :json-false t))
          (let ((summary (pilish-benchmark-test--shell-summary result mode)))
            (should (= (car summary) 1))
            (should (string-match-p "result-ok-verdict-mismatch" (nth 1 summary)))))))
    (dolist (checks '(nil [] "bad" [nil] [42] [(:name "legacy" :ok t)]
                         [(:name "unknown-category" :status "pass")]
                         [(:category "behavior" :status "pass")]))
      (should (= (car (pilish-benchmark-test--shell-summary
                      (list :scenario "smoke" :iteration 1 :settled t :ok t :checks checks) mode)) 1))))
  (dolist (result '((:scenario "smoke" :iteration 1 :settled t :ok t)
                    (:scenario "smoke" :iteration 1 :settled :json-false :ok t
                     :checks [(:name "required" :category "behavior" :status "pass")])
                    (:scenario "smoke" :iteration 1 :ok t
                     :checks [(:name "required" :category "behavior" :status "pass")])))
    (should (= (car (pilish-benchmark-test--shell-summary result "batch")) 1)))
  (let ((summary (pilish-benchmark-test--shell-summary
                  '(:scenario "smoke" :iteration 1 :settled t :ok t
                    :checks [(:name "batch-view" :category "viewport" :status "not-applicable")])
                  "batch")))
    (should (= (car summary) 0))
    (should (string-match-p "notApplicableChecks" (nth 1 summary)))
    (should (string-match-p "batch-view" (nth 1 summary)))
    (should (string-match-p "Not applicable checks" (nth 2 summary)))
    (should (string-match-p "batch-view" (nth 2 summary)))))

(provide 'pilish-benchmark-test)
;;; pilish-benchmark-test.el ends here
