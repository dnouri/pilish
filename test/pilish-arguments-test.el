;;; pilish-arguments-test.el --- Tests for bounded tool argument projection -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel Nouri

;; Author: Daniel Nouri <daniel.nouri@gmail.com>

;;; Commentary:


;;; Code:

(require 'ert)
(require 'pilish)
(require 'pilish-test-common)

(defun pilish-test--argument-rows (tool-name args &optional view)
  "Capture TOOL-NAME's ARGS into rows against VIEW (or a fresh ledger).
Return (ROWS . VIEW)."
  (let* ((view (or view (pilish--make-argument-view)))
         (charge nil)
         (result nil))
    (setq result (pilish--argument--walk tool-name args view t)
          charge (cdr result))
    (pilish--argument--view-apply view charge 1)
    (cons (car result) view)))

(defun pilish-test--argument-visible-rows (rows)
  "Return ROWS whose role makes them visible."
  (seq-filter (lambda (row)
                (memq (pilish--argument-row-role row)
                      '(ordinary input-needed omission)))
              rows))

(defun pilish-test--argument-row-plists (rows)
  "Return ROWS as (KEY ROLE TEXT CUT) plists for readable assertions."
  (mapcar (lambda (row)
            (list :key (pilish--argument-row-key row)
                  :role (pilish--argument-row-role row)
                  :text (pilish--argument-row-text row)
                  :cut (pilish--argument-row-cut row)))
          rows))


(ert-deftest pilish-test-argument-scalar-distinctions ()
  "Missing, null, false, true, zero and empty string stay distinct."
  (let* ((rows (car (pilish-test--argument-rows
                     "custom"
                     (list :null :null :false :false :true t :zero 0
                           :empty "" :missing nil))))
         (plists (pilish-test--argument-row-plists rows)))
    (dolist (expected '(("null" "null") ("false" "false") ("true" "true")
                        ("zero" "0") ("empty" "\"\"") ("missing" "null")))
      (let ((row (cl-find (car expected) plists
                          :key (lambda (r) (plist-get r :key))
                          :test #'equal)))
        (should row)
        (should (equal (plist-get row :text) (cadr expected)))
        (should (null (plist-get row :cut)))))))

(ert-deftest pilish-test-argument-string-escapes-controls ()
  "Control and bidi format characters escape; newlines stay real."
  (let* ((value (concat "a" (string #x202e) "b\nc\td"))
         (rendered (pilish--argument-value-text value)))
    (should-not (cdr rendered))
    (should (string-match-p (regexp-quote "\\u202E") (car rendered)))
    (should (string-match-p "b\nc" (car rendered)))
    (should (string-match-p (regexp-quote "\\t") (car rendered)))
    (should-not (cl-position #x202e (car rendered) :test #'=))))

(ert-deftest pilish-test-argument-literal-ellipsis-is-not-truncation ()
  "A literal … or ... in the source value sets no cut flag."
  (dolist (value '("wait…" "wait..." "…"))
    (let ((rendered (pilish--argument-value-text value)))
      (should (equal (car rendered) value))
      (should-not (cdr rendered)))))


(ert-deftest pilish-test-argument-containers-render-single-line ()
  "Nested plists and vectors render inline; newlines flatten inside."
  (let ((rendered (pilish--argument-value-text
                   '(:a 1 :b [2 "x\ny"] :c (:d :null)))))
    (should-not (cdr rendered))
    (should (equal (car rendered) "{a=1, b=[2, x\\ny], c={d=null}}"))))

(ert-deftest pilish-test-argument-depth-limit-marks-inert ()
  "Containers deeper than the limit render {…}/[…] without a cut flag."
  (let* ((deep '(:a (:b (:c (:d (:e 1))))))
         (rendered (pilish--argument-value-text deep)))
    (should (equal (car rendered) "{a={b={c={…}}}}"))
    (should-not (cdr rendered))))

(ert-deftest pilish-test-argument-empty-containers ()
  "Empty containers render as empty forms."
  (should (equal (car (pilish--argument-value-text [])) "[]"))
  (should (equal (car (pilish--argument-value-text '(:a []))) "{a=[]}")))


(ert-deftest pilish-test-argument-value-limit-cuts-truthfully ()
  "A value over the character limit is cut once, with a baked ellipsis."
  (let* ((long (make-string (1+ pilish--argument-limit-value-chars) ?x))
         (rendered (pilish--argument-value-text long)))
    (should (= (length (car rendered))
               (1+ pilish--argument-limit-value-chars)))
    (should (string-suffix-p "…" (car rendered)))
    (should (eq (cdr rendered) 'value))))

(ert-deftest pilish-test-argument-value-byte-limit ()
  "Multibyte values respect the UTF-8 byte limit."
  (let* ((wide (make-string pilish--argument-limit-value-chars #x1f600))
         (rendered (pilish--argument-value-text wide)))
    (should (<= (string-bytes (car rendered))
                (+ pilish--argument-limit-value-bytes 3)))
    (should (string-suffix-p "…" (car rendered)))
    (should (cdr rendered))))

(ert-deftest pilish-test-argument-key-limit ()
  "Clipped key spellings reserve an ellipsis inside their existing quotas."
  (let* ((long-key (intern (concat ":" (make-string 200 ?k))))
         (result (pilish-test--argument-rows "custom" (list long-key 1)))
         (row (caar result)))
    (should (equal (pilish--argument-row-key row)
                   (concat (make-string 125 ?k) "…")))
    (should (<= (length (pilish--argument-row-key row)) pilish--argument-limit-key-chars))
    (should (= (string-bytes (pilish--argument-row-key row)) pilish--argument-limit-key-chars))
    (should (pilish--argument-view-truncated-p (cdr result)))
    (should-not (pilish--argument-row-cut row))))

(ert-deftest pilish-test-argument-call-entries-limit ()
  "Entries past the per-call cap drop with one inert omission row."
  (let* ((args (cl-loop for i below 80 append
                        (list (intern (format ":k%d" i)) i)))
         (rows (car (pilish-test--argument-rows "custom" args)))
         (omission (seq-filter (lambda (row)
                                 (eq (pilish--argument-row-role row) 'omission))
                               rows)))
    (should (= (length rows) (1+ pilish--argument-limit-call-entries)))
    (should (= 1 (length omission)))
    (should (equal (pilish--argument-row-text (car omission)) "…"))
    (should (eq (pilish--argument-row-cut (car omission)) 'entries))))

(ert-deftest pilish-test-argument-block-budget-omits ()
  "Rows that exceed the block budget drop with a truthful omission row."
  (let ((view (pilish--make-argument-view)))
    (setf (pilish--argument-view-chars view)
          (- pilish--argument-limit-block-chars 3))
    (let ((rows (car (pilish-test--argument-rows
                      "custom" (list :x "1" :y "2") view))))
      (should (= 2 (length rows)))
      (should (eq (pilish--argument-row-role (car rows)) 'ordinary))
      (should (eq (pilish--argument-row-role (cadr rows)) 'omission))
      (should (eq (pilish--argument-row-cut (cadr rows)) 'budget))
      (should (pilish--argument-view-truncated-p view)))))

(ert-deftest pilish-test-argument-ledger-accounting ()
  "Charges sum exactly and a replacement observation releases its share."
  (let* ((view (pilish--make-argument-view))
         (block (pilish--make-tool-block))
         (call (pilish--make-nested-call :id "c1")))
    (setf (pilish--tool-block-argument-view block) view)
    (pilish--argument-observe block nil "custom" '(:a "1"))
    (let ((after-root (pilish--argument-view-chars view)))
      (should (> after-root 0))
      (pilish--argument-observe block call "custom" '(:b "22"))
      (should (> (pilish--argument-view-chars view) after-root))
      (pilish--argument-observe block call "custom" '(:b "22"))
      (let ((after-replace (pilish--argument-view-chars view)))
        (pilish--argument-observe block call "custom" nil)
        (should (= (pilish--argument-view-chars view) after-root))
        (should (<= after-replace pilish--argument-limit-block-chars))))))

(ert-deftest pilish-test-argument-cyclic-input-terminates ()
  "Cyclic or malformed values never hang or signal the visitor."
  (let* ((cyclic (list :a))
         (rendered nil))
    (setcdr cyclic cyclic)
    (setq rendered (pilish--argument-value-text cyclic))
    (should (stringp (car rendered)))
    (let ((rows (car (pilish-test--argument-rows "custom" cyclic))))
      (should (<= (length rows) 2))
      (should (eq (pilish--argument-row-cut (car (last rows))) 'cycle)))))

(ert-deftest pilish-test-argument-malformed-plist-stops-at-invalid-pair ()
  "A malformed tail cannot discard its valid prefix or force a full scan."
  (let ((rows (car (pilish-test--argument-rows "custom" '(:a 1 :b)))))
    (should (equal (pilish--argument-row-text (car rows)) "1"))
    (should (eq (pilish--argument-row-role (cadr rows)) 'omission))
    (should (eq (pilish--argument-row-cut (cadr rows)) 'malformed))))


(ert-deftest pilish-test-argument-policy-primary-and-alias ()
  "The effective path field is keyless; aliases stay visible rows."
  (let ((rows (car (pilish-test--argument-rows
                    "read" '(:path "/a" :file_path "/b" :offset 2)))))
    (should (eq (pilish--argument-row-role (nth 0 rows)) 'primary))
    (should (eq (pilish--argument-row-role (nth 1 rows)) 'ordinary))
    (should (eq (pilish--argument-row-role (nth 2 rows)) 'ordinary))
    (let ((alias-only (car (pilish-test--argument-rows
                            "read" '(:file_path "/b")))))
      (should (eq (pilish--argument-row-role (car alias-only)) 'primary)))))

(ert-deftest pilish-test-argument-policy-bash-command ()
  "Bash command is keyless primary; timeout stays an ordinary row."
  (let ((rows (car (pilish-test--argument-rows
                    "bash" '(:command "ls" :timeout 5)))))
    (should (eq (pilish--argument-row-role (nth 0 rows)) 'primary))
    (should (equal (pilish--argument-row-key (nth 0 rows)) "command"))
    (should (eq (pilish--argument-row-role (nth 1 rows)) 'ordinary))))

(ert-deftest pilish-test-argument-policy-settlement-keys ()
  "Write content and edit replacement input start hidden pending results."
  (let ((write-rows (car (pilish-test--argument-rows
                          "write" '(:path "/a" :content "body")))))
    (should (eq (pilish--argument-row-role (nth 1 write-rows)) 'settlement)))
  (let ((edit-rows (car (pilish-test--argument-rows
                         "edit" (list :path "/a"
                                      :edits [(:oldText "x" :newText "y")])))))
    (should (eq (pilish--argument-row-role (nth 1 edit-rows)) 'settlement)))
  (dolist (args '((:path "/a" :oldText "x" :newText "y")
                  (:path "/a" :edits "not-a-vector")
                  (:path "/a" :edits [(:oldText "x" :newText "y" :extra 1)])))
    (let ((rows (car (pilish-test--argument-rows "edit" args))))
      (if (pilish--tool-arg-member args :oldText)
          (should (eq (pilish--argument-row-role (nth 1 rows)) 'settlement))
        (should (eq (pilish--argument-row-role (nth 1 rows)) 'ordinary))))))

(ert-deftest pilish-test-argument-policy-unknown-keys-visible ()
  "Unknown keys on known tools are ordinary visible rows."
  (let ((rows (car (pilish-test--argument-rows
                    "bash" '(:command "ls" :surprise [1 2])))))
    (should (eq (pilish--argument-row-role (nth 1 rows)) 'ordinary))
    (should (equal (pilish--argument-row-key (nth 1 rows)) "surprise"))))

(ert-deftest pilish-test-argument-codemode-code-root-only ()
  "Codemode code is settlement input only at the root; children show it."
  (let* ((view (pilish--make-argument-view))
         (block (pilish--make-tool-block))
         (call (pilish--make-nested-call :id "c1")))
    (setf (pilish--tool-block-argument-view block) view)
    (pilish--argument-observe block nil "codemode" '(:code "1+1"))
    (should (eq (pilish--argument-row-role
                 (car (pilish--argument-view-root-rows view)))
                'settlement))
    (pilish--argument-observe block call "codemode" '(:code "1+1"))
    (should (eq (pilish--argument-row-role
                 (car (pilish--nested-call-argument-rows call)))
                'ordinary))))


(defun pilish-test--argument-settle-root (block tool-name outcome)
  "Settle BLOCK's root rows for TOOL-NAME with OUTCOME."
  (pilish--argument-settle block nil tool-name outcome))

(ert-deftest pilish-test-argument-settle-write-success-hides-input ()
  "Successful write marks content input-represented and keeps it hidden."
  (let ((block (pilish--make-tool-block)))
    (pilish--argument-observe block nil "write" '(:path "/a" :content "body"))
    (should-not (pilish-test--argument-settle-root
                 block "write" '(:result-present-p t :is-error nil :details nil)))
    (let ((row (nth 1 (pilish--argument-view-root-rows
                       (pilish--tool-block-argument-view block)))))
      (should (eq (pilish--argument-row-role row) 'input-represented)))))

(ert-deftest pilish-test-argument-settle-write-failure-shows-diagnostic ()
  "Failed or missing write results keep bounded diagnostic input."
  (dolist (outcome '((:result-present-p t :is-error t :details nil)
                     (:result-present-p nil :is-error nil :details nil)))
    (let ((block (pilish--make-tool-block)))
      (pilish--argument-observe block nil "write" '(:path "/a" :content "body"))
      (should (pilish-test--argument-settle-root block "write" outcome))
      (let ((row (nth 1 (pilish--argument-view-root-rows
                         (pilish--tool-block-argument-view block)))))
        (should (eq (pilish--argument-row-role row) 'input-needed))))))

(ert-deftest pilish-test-argument-settle-edit-diff-cases ()
  "Edit input hides only behind a successful usable numbered diff."
  (let ((usable '(:result-present-p t :is-error nil
                  :details (:diff "+ 7     code\n- 8     old"))))
    (let ((block (pilish--make-tool-block)))
      (pilish--argument-observe block nil "edit"
                                (list :path "/a" :edits [(:oldText "x" :newText "y")]))
      (pilish-test--argument-settle-root block "edit" usable)
      (should (eq (pilish--argument-row-role
                   (nth 1 (pilish--argument-view-root-rows
                           (pilish--tool-block-argument-view block))))
                  'input-represented))))
  (dolist (details '(nil
                     (:diff "")
                     (:diff "context only … no numbered rows")
                     (:diff "+notanumber row")))
    (let ((block (pilish--make-tool-block)))
      (pilish--argument-observe block nil "edit"
                                (list :path "/a" :edits [(:oldText "x" :newText "y")]))
      (pilish-test--argument-settle-root
       block "edit" (list :result-present-p t :is-error nil :details details))
      (should (eq (pilish--argument-row-role
                   (nth 1 (pilish--argument-view-root-rows
                           (pilish--tool-block-argument-view block))))
                  'input-needed)))))

(ert-deftest pilish-test-argument-settle-idempotent ()
  "Repeated settlement cannot flip a represented row back to diagnostic."
  (let ((block (pilish--make-tool-block)))
    (pilish--argument-observe block nil "write" '(:path "/a" :content "body"))
    (pilish-test--argument-settle-root
     block "write" '(:result-present-p t :is-error nil :details nil))
    (should-not (pilish-test--argument-settle-root
                 block "write" '(:result-present-p nil)))
    (should (eq (pilish--argument-row-role
                 (nth 1 (pilish--argument-view-root-rows
                         (pilish--tool-block-argument-view block))))
                'input-represented))))

(ert-deftest pilish-test-argument-settle-capture-cut-does-not-duplicate-write ()
  "A clipped capture does not duplicate content represented by a successful write."
  (let ((block (pilish--make-tool-block)))
    (pilish--argument-observe
     block nil "write"
     (list :path "/a" :content (make-string
                                (1+ pilish--argument-limit-value-chars) ?x)))
    (pilish-test--argument-settle-root
     block "write" '(:result-present-p t :is-error nil :details nil))
    (should (eq (pilish--argument-row-role
                 (nth 1 (pilish--argument-view-root-rows
                         (pilish--tool-block-argument-view block))))
                'input-represented))))

(ert-deftest pilish-test-argument-codemode-code-needs-script ()
  "Only an actual script presentation represents a root code argument."
  (dolist (outcome '((:result-present-p t :script-present-p t)
                     (:result-present-p nil)))
    (let ((block (pilish--make-tool-block)))
      (pilish--argument-observe block nil "codemode" '(:code "1+1"))
      (pilish-test--argument-settle-root block "codemode" outcome)
      (should (eq (pilish--argument-row-role
                   (car (pilish--argument-view-root-rows
                         (pilish--tool-block-argument-view block))))
                  (if (plist-get outcome :script-present-p)
                      'input-represented 'input-needed))))))


(defmacro pilish-arguments-test--with-chat (&rest body)
  "Run BODY in a temporary chat buffer."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (pilish-chat-mode)
     ,@body))

(defun pilish-arguments-test--execute (id tool-name args content &optional is-error details)
  "Drive one tool execution for ID with TOOL-NAME, ARGS and CONTENT text."
  (pilish--handle-display-event
   (list :type "tool_execution_start" :toolCallId id :toolName tool-name
         :args args))
  (pilish--handle-display-event
   (list :type "tool_execution_end" :toolCallId id :toolName tool-name
         :result (list :content (vector (list :type "text" :text content))
                       :details details)
         :isError is-error)))

(defun pilish-arguments-test--visible-text ()
  "Return the current buffer's visible text."
  (pilish--visible-text (point-min) (point-max)))

(defun pilish-arguments-test--goto-text (needle)
  "Move point to the start of NEEDLE in the current buffer."
  (goto-char (point-min))
  (let ((case-fold-search nil)) (search-forward needle))
  (goto-char (match-beginning 0)))

(defun pilish-arguments-test--all-tool-overlays ()
  "Return all tool block overlays in the current buffer."
  (seq-filter (lambda (overlay) (overlay-get overlay 'pilish-tool-block))
              (overlays-in (point-min) (point-max))))

(ert-deftest pilish-test-arguments-bash-compact-header-complete ()
  "A short Bash command fits completely and shows no fold control."
  (pilish-arguments-test--with-chat
    (pilish-arguments-test--execute "c1" "bash" '(:command "ls -la") "file.txt")
    (let ((visible (pilish-arguments-test--visible-text)))
      (should (string-match-p "^bash ls -la$" visible))
      (should-not (string-match-p "[▸▾]" visible))
      (should (string-match-p "file\\.txt" visible)))))

(ert-deftest pilish-test-arguments-read-header-and-rows ()
  "Read keeps a keyless path and packs its complete short argument list."
  (pilish-arguments-test--with-chat
    (pilish-arguments-test--execute
     "c1" "read" '(:path "src/main.py" :offset 4 :limit 8) "import sys")
    (let ((visible (pilish-arguments-test--visible-text)))
      (should (string-match-p "^read src/main\\.py offset=4 limit=8$" visible)))))

(ert-deftest pilish-test-arguments-contract-toggle-expand-collapse ()
  "A wide value contracts with a truthful ellipsis and toggles expanded."
  (pilish-arguments-test--with-chat
    (let ((command (concat "printf " (make-string 100 ?x))))
      (pilish-arguments-test--execute "c1" "bash" (list :command command) "done")
      (let ((visible (pilish-arguments-test--visible-text)))
        (should (string-match-p "^bash\nprintf x+…$" visible))
        (should-not (string-match-p (regexp-quote (make-string 100 ?x)) visible)))
      (pilish-arguments-test--goto-text "printf")
      (pilish-toggle-tool-section)
      (let ((visible (pilish-arguments-test--visible-text)))
        (should (string-match-p "^bash\nprintf" visible))
        (should (string-match-p (regexp-quote (make-string 100 ?x)) visible)))
      (pilish-arguments-test--goto-text "printf")
      (pilish-toggle-tool-section)
      (let ((visible (pilish-arguments-test--visible-text)))
        (should (string-match-p "^bash\nprintf x+…$" visible))
        (should-not (string-match-p (regexp-quote (make-string 100 ?x)) visible))))))

(ert-deftest pilish-test-arguments-multiline-contracted-shows-no-value-lines ()
  "A multiline value contracts to exactly one teaser line."
  (pilish-arguments-test--with-chat
    (pilish-arguments-test--execute
     "c1" "bash" '(:command "echo one\necho two\necho three") "out")
    (let ((visible (pilish-arguments-test--visible-text)))
      (should (string-match-p "^bash\necho one…$" visible))
      (should-not (string-match-p "echo two" visible)))
    (pilish-arguments-test--goto-text "echo one")
    (pilish-toggle-tool-section)
    (let ((visible (pilish-arguments-test--visible-text)))
      (should (string-match-p "^echo two$" visible))
      (should (string-match-p "^echo three$" visible)))))

(ert-deftest pilish-test-arguments-ellipsis-marks-only-real-cuts ()
  "A literal ellipsis in the value is not a truncation marker."
  (pilish-arguments-test--with-chat
    (pilish-arguments-test--execute
     "c1" "bash" '(:command "echo done…") "out")
    (let ((visible (pilish-arguments-test--visible-text)))
      (should (string-match-p "^bash echo done…$" visible))
      (should-not (string-match-p "▸" visible)))))

(ert-deftest pilish-test-arguments-generic-inline-layout ()
  "Complete single-line generic arguments compose on the title row."
  (pilish-arguments-test--with-chat
    (pilish-arguments-test--execute
     "c1" "custom_tool" '(:query "weather" :limit 3) "sunny")
    (let ((visible (pilish-arguments-test--visible-text)))
      (should (string-match-p "^custom_tool query=weather limit=3$" visible)))))

(ert-deftest pilish-test-arguments-generic-multiline-uses-rows ()
  "A multiline generic argument forces the one-row-per-line layout."
  (pilish-arguments-test--with-chat
    (pilish-arguments-test--execute
     "c1" "custom_tool" '(:query "weather" :note "line1\nline2") "sunny")
    (let ((visible (pilish-arguments-test--visible-text)))
      (should (string-match-p "^custom_tool$" visible))
      (should (string-match-p "^query=weather$" visible))
      (should (string-match-p "^note=line1…$" visible)))))

(ert-deftest pilish-test-arguments-generic-title-toggle-targets-first-expandable ()
  "TAB on a generic title toggles the first expandable argument row."
  (pilish-arguments-test--with-chat
    (pilish-arguments-test--execute
     "c1" "custom_tool" '(:query "weather" :note "line1\nline2") "sunny")
    (pilish-arguments-test--goto-text "custom_tool")
    (let ((locator (get-text-property (point) 'pilish-argument-locator)))
      (should (equal '(argument nil :title) locator)))
    (pilish-toggle-tool-section)
    (let ((visible (pilish-arguments-test--visible-text)))
      ;; Value lines are buffer text; hanging indent is display-only.
      (should (string-match-p "^line2$" visible))
      (should (string-match-p "^note=line1$" visible)))))

(ert-deftest pilish-test-arguments-write-success-represents-input ()
  "A successful write shows no content row; the body is the input."
  (pilish-arguments-test--with-chat
    (pilish-arguments-test--execute
     "c1" "write" '(:path "/tmp/a.txt" :content "hello") nil)
    (let ((visible (pilish-arguments-test--visible-text)))
      (should (string-match-p "^write /tmp/a\\.txt$" visible))
      (should-not (string-match-p "content=" visible))
      (should (string-match-p "hello" visible)))))

(ert-deftest pilish-test-arguments-write-failure-shows-diagnostic-input ()
  "A failed write keeps its bounded input visible and shows real output."
  (pilish-arguments-test--with-chat
    (pilish-arguments-test--execute
     "c1" "write" '(:path "/tmp/a.txt" :content "hello") "disk full" t)
    (let ((visible (pilish-arguments-test--visible-text)))
      (should (string-match-p "^write /tmp/a\\.txt$" visible))
      (should (string-match-p "^content=hello$" visible))
      (should (string-match-p "disk full" visible)))))

(ert-deftest pilish-test-arguments-edit-usable-diff-represents-input ()
  "An edit with a usable diff shows no input rows."
  (pilish-arguments-test--with-chat
    (pilish-arguments-test--execute
     "c1" "edit" '(:path "/tmp/a.txt" :oldText "a" :newText "b") "ok"
     nil '(:diff "- 1     a\n+ 1     b"))
    (let ((visible (pilish-arguments-test--visible-text)))
      (should (string-match-p "^edit /tmp/a\\.txt$" visible))
      (should-not (string-match-p "oldText=" visible))
      (should-not (string-match-p "newText=" visible)))))

(ert-deftest pilish-test-arguments-edit-failure-shows-diagnostic-input ()
  "A failed edit without a usable diff keeps bounded input rows."
  (pilish-arguments-test--with-chat
    (pilish-arguments-test--execute
     "c1" "edit" '(:path "/tmp/a.txt" :oldText "a" :newText "b")
     "no match" t nil)
    (let ((visible (pilish-arguments-test--visible-text)))
      (should (string-match-p "^oldText=a$" visible))
      (should (string-match-p "^newText=b$" visible))
      (should (string-match-p "no match" visible)))))

(ert-deftest pilish-test-arguments-missing-result-retains-input ()
  "Forced finalization without a result keeps bounded diagnostic input."
  (pilish-arguments-test--with-chat
    (pilish--handle-display-event
     '(:type "tool_execution_start" :toolCallId "c1"
       :toolName "custom_tool" :args (:query "weather")))
    (let ((block (pilish--tool-block-get "c1")))
      (pilish--tool-block-finalize block 'pilish-tool-block-error))
    (let ((visible (pilish-arguments-test--visible-text)))
      (should (string-match-p "custom_tool query=weather" visible)))))

(ert-deftest pilish-test-arguments-fold-does-not-collapse-output ()
  "Toggling an argument row leaves the output section visible."
  (pilish-arguments-test--with-chat
    (pilish-arguments-test--execute
     "c1" "custom_tool"
     (list :note (concat "line1\nline2 " (make-string 100 ?x))) "OUTPUT-BODY")
    (pilish-arguments-test--goto-text "note=")
    (pilish-toggle-tool-section)
    (let ((visible (pilish-arguments-test--visible-text)))
      (should (string-match-p "line2" visible))
      (should (string-match-p "OUTPUT-BODY" visible)))
    (pilish-toggle-tool-section)
    (let ((visible (pilish-arguments-test--visible-text)))
      (should-not (string-match-p "line2" visible))
      (should (string-match-p "OUTPUT-BODY" visible)))))

(ert-deftest pilish-test-arguments-toggle-preserves-buffer-point-on-control ()
  "Toggling an argument keeps buffer point on the toggled control's row."
  (pilish-arguments-test--with-chat
    (pilish-arguments-test--execute
     "c1" "custom_tool"
     '(:query "weather" :note "line1\nline2") "sunny")
    (pilish-arguments-test--goto-text "note=")
    (let ((locator (get-text-property (point) 'pilish-argument-locator)))
      (dotimes (_ 2)
        (pilish-toggle-tool-section)
        (should (equal locator (get-text-property (point) 'pilish-argument-locator)))
        (should (looking-at "note="))))))

(ert-deftest pilish-test-arguments-cooling-releases-controls ()
  "Cooling strips locators and triangles but preserves visible row text."
  (pilish-arguments-test--with-chat
    (pilish-arguments-test--execute
     "c1" "custom_tool"
     '(:query "weather" :note "line1\nline2") "sunny")
    (pilish-arguments-test--goto-text "note=")
    (pilish-toggle-tool-section)
    (should (string-match-p "line2" (pilish-arguments-test--visible-text)))
    (let ((overlay (car (pilish-arguments-test--all-tool-overlays))))
      (pilish--cool-completed-tool-blocks (list overlay)))
    (let ((visible (pilish-arguments-test--visible-text)))
      (should (string-match-p "line2" visible))
      (should-not (string-match-p "[▸▾]" visible)))
    (should-not (text-property-any (point-min) (point-max)
                                   'pilish-argument-locator '(argument nil 2)))
    (should-not (text-property-any (point-min) (point-max)
                                   'pilish-argument-triangle t))))

(ert-deftest pilish-test-arguments-cold-metadata-captured-after-release ()
  "Cold metadata describes the released header, not the pre-release one."
  (pilish-arguments-test--with-chat
    (pilish-arguments-test--execute
     "c1" "custom_tool"
     '(:query "weather" :note "line1\nline2") "sunny")
    (let* ((overlay (car (pilish-arguments-test--all-tool-overlays)))
           (block (pilish--tool-block-from-overlay overlay)))
      (pilish--cool-completed-tool-blocks (list overlay))
      (should-not (pilish--tool-block-argument-view block))
      (should-not (seq-some (lambda (fold)
                              (and (consp fold) (eq (car fold) 'argument)))
                            (pilish--tool-block-folds block))))))

(ert-deftest pilish-test-arguments-width-chosen-at-paint-time ()
  "The projection carries no recorded width; repaint reflects the width."
  (pilish-arguments-test--with-chat
    (pilish-arguments-test--execute
     "c1" "bash" (list :command (concat "printf " (make-string 100 ?x))) "done")
    (let* ((overlay (car (pilish-arguments-test--all-tool-overlays)))
           (block (pilish--tool-block-from-overlay overlay))
           (view (pilish--tool-block-argument-view block)))
      (should-not (assq 'width (cl-struct-slot-info 'pilish--argument-view)))
      (should view)
      (let* ((pilish--chat-display-width-override 200)
             (wide (substring-no-properties
                    (pilish--argument-header-text block "bash" nil)))
             (pilish--chat-display-width-override 40)
             (narrow (substring-no-properties
                      (pilish--argument-header-text block "bash" nil))))
        (should (string-prefix-p "bash printf" wide))
        (should (string-match-p (regexp-quote (make-string 100 ?x)) wide))
        (should (string-match-p "…" narrow))
        (should-not (string-match-p (regexp-quote (make-string 100 ?x)) narrow))))))

(ert-deftest pilish-test-arguments-ret-on-argument-rows-is-inert ()
  "RET inside argument title, rows and expanded values opens nothing.
Tool headers and argument rows are not visitable file targets; the
established file actions keep authority over real path references only."
  (pilish-arguments-test--with-chat
    (pilish-arguments-test--execute
     "c1" "custom_tool"
     '(:path "src/main.py" :note "line1\nline2") "sunny")
    (cl-letf (((symbol-function 'find-file)
               (lambda (&rest _) (ert-fail "arguments are not file targets"))))
      (pilish-arguments-test--goto-text "path=src")
      (should-error (pilish-visit-file) :type 'user-error)
      (pilish-arguments-test--goto-text "note=")
      (pilish-toggle-tool-section)
      (pilish-arguments-test--goto-text "line2")
      (should-error (pilish-visit-file) :type 'user-error))))

(ert-deftest pilish-test-arguments-adversarial-value-stays-contained ()
  "Fence and HTML-comment lines inside values cannot damage the parse."
  (pilish-arguments-test--with-chat
    (pilish-arguments-test--execute
     "c1" "custom_tool"
     (list :payload "before\n```\n<!-- hidden\nAFTER-MARKER") "BODY-ONE")
    (pilish-arguments-test--execute
     "c2" "bash" '(:command "echo tail") "BODY-TWO")
    (pilish-arguments-test--goto-text "payload=")
    (pilish-toggle-tool-section)
    (font-lock-ensure (point-min) (point-max))
    (let ((visible (pilish-arguments-test--visible-text)))
      ;; The value's own fence line is shown as literal content (the hidden
      ;; collision-safe guards contain it); the following tool block
      ;; survived the tree-sitter parse.
      (should (string-match-p "^```$" visible))
      (should (string-match-p "AFTER-MARKER" visible))
      (should (string-match-p "BODY-ONE" visible))
      (should (string-match-p "BODY-TWO" visible))
      (should (string-match-p "^bash echo tail$" visible)))
    (font-lock-flush (point-min) (point-max))
    (font-lock-ensure (point-min) (point-max))
    (let ((visible (pilish-arguments-test--visible-text)))
      (should (string-match-p "^```$" visible))
      (should (string-match-p "AFTER-MARKER" visible))
      (should (string-match-p "BODY-TWO" visible)))))


(defun pilish-arguments-test--child (tool args &optional output details)
  "Execute a real nested TOOL with ARGS, OUTPUT and DETAILS."
  (pilish--handle-display-event
   '(:type "tool_execution_start" :toolCallId "root" :toolName "codemode"
     :args (:code "1+1")))
  (pilish--handle-display-event
   (list :type "tool_execution_start" :toolCallId "child" :parentToolCallId "root"
         :toolName tool :args args))
  (pilish--handle-display-event
   (list :type "tool_execution_end" :toolCallId "child" :parentToolCallId "root"
         :toolName tool :result (list :content (vector (list :type "text" :text (or output "")))
                                     :details details)))
  (pilish--handle-display-event
   '(:type "tool_execution_end" :toolCallId "root" :toolName "codemode"
     :result (:content [(:type "text" :text "PARENT-OUTPUT")]))))

(defun pilish-arguments-test--node-types (position)
  "Return Markdown ancestor types at POSITION."
  ;; Inspect a character's enclosing node, not the next named leaf.  The
  ;; grammar's zero-width continuation leaves can have no navigable parent.
  (let ((node (treesit-node-on position (1+ position) 'markdown t)) types)
    (while node
      (push (treesit-node-type node) types)
      (setq node (treesit-node-parent node)))
    types))

(defun pilish-arguments-test--assert-following-markdown ()
  "Check the following paragraph and code through the real Markdown parser."
  (font-lock-flush)
  (font-lock-ensure)
  (pilish-arguments-test--goto-text "AFTER-PARAGRAPH")
  (should (member "paragraph" (pilish-arguments-test--node-types (point))))
  (should-not (eq (get-text-property (point) 'face) 'md-ts-code))
  (pilish-arguments-test--goto-text "AFTER-CODE")
  (should (member "fenced_code_block" (pilish-arguments-test--node-types (point))))
  (should (get-text-property (point) 'face)))

(ert-deftest pilish-test-arguments-reviewed-bounded-vector-work ()
  "Traversal stops at the same quota without testing every remaining element."
  (let (counts)
    (dolist (size '(2000 20000))
      (let ((checks 0)
            (original (symbol-function 'plist-get)))
        (cl-letf (((symbol-function 'plist-get)
                   (lambda (plist key &optional predicate)
                     (when (eq key :cut) (cl-incf checks))
                     (funcall original plist key predicate))))
          (pilish--argument-value-text (make-vector size 0)))
        (push checks counts)))
    (should (= (car counts) (cadr counts)))))

(ert-deftest pilish-test-arguments-reviewed-no-full-plist-prescan ()
  "Valid decoded plists are consumed without whole-tail validation scans."
  (let* ((args (cl-loop for i below 10000 append (list (intern (format ":k%d" i)) 0)))
         (original-length (symbol-function 'length))
         (original-proper (symbol-function 'proper-list-p)))
    (cl-letf (((symbol-function 'length)
               (lambda (object)
                 (should-not (eq object args))
                 (funcall original-length object)))
              ((symbol-function 'proper-list-p)
               (lambda (object)
                 (should-not (eq object args))
                 (funcall original-proper object))))
      (let ((rows (car (pilish-test--argument-rows "custom" args))))
        (should (eq (pilish--argument-row-role (car (last rows))) 'omission))))))

(ert-deftest pilish-test-arguments-reviewed-aggregate-visited-nodes ()
  "The actual visited values share one root and child node budget."
  (let ((block (pilish--make-tool-block))
        (visits 0)
        (original (symbol-function 'pilish--argument--emit-value)))
    (cl-letf (((symbol-function 'pilish--argument--emit-value)
               (lambda (&rest args)
                 (cl-incf visits)
                 (apply original args))))
      (pilish--argument-observe block nil "custom"
                                (list :a (make-vector 600 0) :b (make-vector 600 0)))
      (pilish--argument-observe block (pilish--make-nested-call :id "child")
                                "custom" '(:c [1 2 3])))
    (should (<= visits pilish--argument-limit-nodes))
    (should (= visits (pilish--argument-view-nodes
                       (pilish--tool-block-argument-view block))))))

(ert-deftest pilish-test-arguments-reviewed-aggregate-entries ()
  "Retained root and child argument rows cannot exceed the shared key quota."
  (let ((block (pilish--make-tool-block)) rows)
    (dotimes (i 5)
      (let ((node (and (> i 0) (pilish--make-nested-call :id (format "c%d" i)))))
        (setq rows
              (append rows (pilish--argument-observe
                            block node "custom"
                            (cl-loop for n below (if (= i 0) 63 64)
                                     append (list (intern (format ":k%d" n)) 0)))))))
    (should (<= (length (seq-remove (lambda (row)
                                      (eq (pilish--argument-row-role row) 'omission))
                                    rows))
                pilish--argument-limit-block-entries))))

(ert-deftest pilish-test-arguments-reviewed-nul-decoded-json ()
  "A real JSON NUL escapes without losing either side or fabricating dots."
  (pilish-arguments-test--with-chat
    (pilish--handle-display-event
     (pilish--parse-json-line
      "{\"type\":\"tool_execution_start\",\"toolCallId\":\"nul\",\"toolName\":\"custom\",\"args\":{\"payload\":\"BEFORE\\u0000AFTER\"}}"))
    (should (string-match-p (regexp-quote "payload=BEFORE\\x00AFTER")
                            (pilish-arguments-test--visible-text)))
    (should-not (pilish--argument-row-cut
                 (car (pilish--argument-view-root-rows
                       (pilish--tool-block-argument-view (pilish--tool-block-get "nul"))))))))

(ert-deftest pilish-test-arguments-reviewed-child-guard-and-cooling ()
  "Expanded child guards contain following Markdown before and after cooling."
  (dolist (child-output '("CHILD-OUTPUT" ""))
    (pilish-arguments-test--with-chat
      (pilish-arguments-test--child "custom" '(:payload "FIRST\nSECOND") child-output)
      (pilish--render-history-text
       "\nAFTER-PARAGRAPH **bold**.\n\n```elisp\n(message \"AFTER-CODE\")\n```")
      (pilish-arguments-test--assert-following-markdown)
      (pilish-arguments-test--goto-text "payload=")
      (pilish-toggle-tool-section)
      (should (string-match-p "payload=FIRST\nSECOND" (pilish-arguments-test--visible-text)))
      (pilish-arguments-test--assert-following-markdown)
      (pilish-arguments-test--goto-text "SECOND")
      (let ((prefix (get-text-property (point) 'line-prefix)))
        (should (stringp prefix))
        (pilish--cool-completed-tool-blocks (pilish-arguments-test--all-tool-overlays))
        (pilish-arguments-test--assert-following-markdown)
        (pilish-arguments-test--goto-text "SECOND")
        (should (equal prefix (get-text-property (point) 'line-prefix)))
        (should (equal prefix (get-text-property (point) 'wrap-prefix))))
      (let ((visible (pilish-arguments-test--visible-text)))
        (should (string-match-p "payload=FIRST\nSECOND" visible))
        (should-not (string-match-p "^[~`]\\{3,\\}.*Output" visible)))
      (let ((guard (text-property-any (point-min) (point-max) 'pilish-argument-guard t)))
        (should guard)
        (should (equal (get-text-property guard 'display) ""))))))

(ert-deftest pilish-test-arguments-reviewed-primary-locator-independent ()
  "A failed write's path and content each own their reachable argument fold."
  (pilish-arguments-test--with-chat
    (let ((path (concat "src/" (make-string 100 ?a) ".txt")))
      (pilish-arguments-test--execute "write" "write" (list :path path :content "a\nb") "disk full" t)
      (pilish-arguments-test--goto-text "write")
      (should (equal (get-text-property (point) 'pilish-argument-locator) '(argument nil 0)))
      (pilish-toggle-tool-section)
      (should (string-match-p (regexp-quote path) (pilish-arguments-test--visible-text)))
      (should-not (string-match-p "content=a\nb" (pilish-arguments-test--visible-text)))
      (pilish-arguments-test--goto-text "content=")
      (pilish-toggle-tool-section)
      (should (string-match-p "content=a\nb" (pilish-arguments-test--visible-text)))
      (should (string-match-p (regexp-quote path) (pilish-arguments-test--visible-text))))))

(ert-deftest pilish-test-arguments-reviewed-nested-primary-fold ()
  "A multiline nested Bash primary is keyless, truthful and independent of output."
  (pilish-arguments-test--with-chat
    (pilish-arguments-test--child "bash" '(:command "echo FIRST\necho SECOND") "CHILD-OUTPUT")
    (should (string-match-p "^bash\necho FIRST…" (pilish-arguments-test--visible-text)))
    (pilish-arguments-test--goto-text "echo FIRST")
    (should (equal (get-text-property (point) 'pilish-argument-locator) '(argument "child" 0)))
    (pilish-toggle-tool-section)
    (should (string-match-p "echo FIRST[^\n]*\necho SECOND" (pilish-arguments-test--visible-text)))
    (should-not (string-match-p "command=" (pilish-arguments-test--visible-text)))
    (should-not (string-match-p "CHILD-OUTPUT" (pilish-arguments-test--visible-text)))
    (pilish-arguments-test--goto-text "… 1 more line")
    (pilish-toggle-tool-section)
    (should (string-match-p "CHILD-OUTPUT" (pilish-arguments-test--visible-text)))
    (should (string-match-p "echo SECOND" (pilish-arguments-test--visible-text)))))

(ert-deftest pilish-test-arguments-reviewed-saved-title-after-tab ()
  "A generic saved declaration remains a working title button in either fold state."
  (pilish-arguments-test--with-chat
    (setq pilish--state '(:session-file "/tmp/pilish-argument-anchor.jsonl"))
    (pilish-arguments-test--execute
     "saved" "custom" '(:payload "one\ntwo") "RESULT" nil
     '(:savedConversations
       (:version 1 :root "/tmp/pilish-argument-saved/"
        :items [(:sessionId "child" :file "child.jsonl" :label "child label")])))
    (let (target)
      (dotimes (_ 3)
        (pilish-arguments-test--goto-text "child label")
        (let* ((button (button-at (point)))
               (captured (and button (button-get button 'pilish-subagent-name))))
          (should (pilish--snapshot-target-p captured))
          (if target (should (equal target captured)) (setq target captured))
          (let (opened)
            (cl-letf (((symbol-function 'pilish-open-subagent-snapshot)
                       (lambda (value) (setq opened value))))
              (button-activate button))
            (should (equal opened target))))
        (pilish-arguments-test--goto-text "payload=")
        (pilish-toggle-tool-section)))))

(defun pilish-arguments-test--two-window-row-mapping (second-value)
  "Check surviving row mapping with SECOND-VALUE, including inert short rows."
  (let ((chat (generate-new-buffer " *arguments-two-window*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer chat)
          (pilish-chat-mode)
          (pilish-arguments-test--execute "r" "custom" (list :first "A1\nA2" :second second-value) "RESULT")
          (pilish--render-history-text (mapconcat #'number-to-string (number-sequence 0 50) "\n"))
          (let ((other (split-window-below)))
            (set-window-buffer other chat)
            (pilish-arguments-test--goto-text "second=")
            (set-window-point other (+ (point) 3))
            (set-window-start other (line-beginning-position) t)
            (pilish-arguments-test--goto-text "first=")
            (pilish-toggle-tool-section)
            (pilish-arguments-test--goto-text "second=")
            (should (= (window-point other) (+ (point) 3)))
            (should (= (window-start other) (line-beginning-position)))))
      (with-current-buffer chat (set-buffer-modified-p nil))
      (kill-buffer chat))))

(ert-deftest pilish-test-arguments-reviewed-two-window-row-mapping ()
  "An unchanged second row keeps the other window's point and start offsets."
  (dolist (second-value '("B1\nB2" "B1"))
    (pilish-arguments-test--two-window-row-mapping second-value)))

(ert-deftest pilish-test-arguments-reviewed-large-success-not-duplicated ()
  "Capture clipping is not missing output for successful write and edit."
  (dolist (tool '("write" "edit"))
    (pilish-arguments-test--with-chat
      (let ((text (make-string 6000 ?x)))
        (pilish-arguments-test--execute
         "r" tool (if (equal tool "write") (list :path "/a" :content text)
                    (list :path "/a" :oldText text :newText "new"))
         "ok" nil (and (equal tool "edit") '(:diff "- 1 old\n+ 1 new")))
        (should-not (string-match-p "\\(content\\|oldText\\|newText\\)="
                                    (pilish-arguments-test--visible-text)))))))

(ert-deftest pilish-test-arguments-reviewed-nested-result-settlement ()
  "Live nested write and edit omit represented values, missing history keeps them."
  (dolist (tool '("write" "edit"))
    (let ((args (if (equal tool "write") '(:path "/a" :content "BODY")
                  '(:path "/a" :oldText "OLD" :newText "NEW"))))
      (pilish-arguments-test--with-chat
        (pilish-arguments-test--child tool args "ok"
                                     (and (equal tool "edit") '(:diff "- 1 OLD\n+ 1 NEW")))
        (should-not (string-match-p "\\(content\\|oldText\\|newText\\)="
                                    (pilish-arguments-test--visible-text))))
      (pilish-arguments-test--with-chat
        (pilish--render-history-tool
         '(:type "toolCall" :id "root" :name "codemode" :arguments (:code "1+1"))
         (list :content [] :nestedCalls
               (list :complete t :calls (vector (list :id "child" :name tool :status "ok" :arguments args)))))
        (should (string-match-p "\\(content=BODY\\|oldText=OLD\\)"
                                (pilish-arguments-test--visible-text)))))))

(ert-deftest pilish-test-arguments-reviewed-codemode-missing-result ()
  "Missing history has diagnostic code, actual script presentation does not duplicate it."
  (dolist (result '(nil (:content [(:type "text" :text "ok")])
                       (:content [(:type "text" :text "ok")] :details (:calls []))))
    (pilish-arguments-test--with-chat
      (pilish--render-history-tool
       '(:type "toolCall" :id "root" :name "codemode" :arguments (:code "SECRET-CODE-BODY")) result)
      (should (string-match-p "SECRET-CODE-BODY" (pilish-arguments-test--visible-text)))
      (should (eq (and (string-match-p "code=SECRET" (pilish-arguments-test--visible-text)) t)
                  (null (plist-get result :details)))))))

(ert-deftest pilish-test-arguments-shell-fontification-skips-mode-hooks ()
  "Expanded Bash arguments keep shell faces without running mode hooks."
  (require 'sh-script)
  (pilish-arguments-test--with-chat
    (let* ((calls 0)
           (sh-mode-hook (list (lambda () (cl-incf calls)))))
      (pilish-arguments-test--execute
       "r" "bash" '(:command "if true; then echo \"quoted-str\"; fi\necho second-line") "out")
      (should (= calls 0))
      (pilish-arguments-test--goto-text "if true")
      (pilish-toggle-tool-section)
      (dolist (expected '(("if true" . font-lock-keyword-face)
                          ("quoted-str" . font-lock-string-face)))
        (pilish-arguments-test--goto-text (car expected))
        (dolist (property '(face font-lock-face))
          (should (eq (get-text-property (point) property) (cdr expected)))))
      (should (= calls 0)))))

(ert-deftest pilish-test-arguments-reviewed-fontification-chunks ()
  "Real fontification and mid-value repair retain varying shell faces after cooling."
  (dolist (nested '(nil t))
    (pilish-arguments-test--with-chat
      (let ((args '(:command "if true; then echo \"quoted-str\"; fi\necho second-line")))
        (if nested (pilish-arguments-test--child "bash" args "out")
          (pilish-arguments-test--execute "r" "bash" args "out")))
      (pilish-arguments-test--goto-text "if true")
      (pilish-toggle-tool-section)
      (dolist (cold '(nil t))
        (when cold (pilish--cool-completed-tool-blocks (pilish-arguments-test--all-tool-overlays)))
        (font-lock-flush)
        (font-lock-ensure)
        (pilish-arguments-test--goto-text "if true")
        (let* ((start (point))
               (end (progn (search-forward "second-line") (point)))
               faces)
          (pilish--restore-tool-properties start end)
          (cl-loop for pos from start below end
                   do (push (get-text-property pos 'font-lock-face) faces)
                   when (get-text-property pos 'font-lock-face)
                   do (should (equal (get-text-property pos 'face)
                                     (get-text-property pos 'font-lock-face))))
          (should (> (length (delete-dups faces)) 1)))))))

(ert-deftest pilish-test-arguments-reviewed-primary-guards-and-saved-chrome ()
  "Root and child primaries keep literal guards and saved labels on the title line."
  (dolist (nested '(nil t))
    (pilish-arguments-test--with-chat
      (setq pilish--state '(:session-file "/tmp/pilish-argument-anchor.jsonl"))
      (let ((args '(:command "if true; then\necho literal\n```\n<!--\nfi"))
            (details '(:savedConversations
                       (:version 1 :root "/tmp/pilish-argument-saved/"
                        :items [(:sessionId "child" :file "child.jsonl" :label "saved label")]))))
        (if nested (pilish-arguments-test--child "bash" args "CHILD" details)
          (pilish-arguments-test--execute "r" "bash" args "OUTPUT" nil details)))
      (pilish--render-history-text
       "\nAFTER-PARAGRAPH **bold**.\n\n```elisp\n(message \"AFTER-CODE\")\n```")
      (pilish-arguments-test--goto-text "if true")
      (pilish-toggle-tool-section)
      (pilish-arguments-test--assert-following-markdown)
      (let ((visible (pilish-arguments-test--visible-text)))
        (should (string-match-p "^bash[^\n]*saved label[^\n]*\nif true; then\necho literal\n```\n<!--\nfi" visible)))
      (pilish-arguments-test--goto-text "saved label")
      (let ((target (get-text-property (point) 'pilish-subagent-name)))
        (should (pilish--snapshot-target-p target))
        (pilish--cool-completed-tool-blocks (pilish-arguments-test--all-tool-overlays))
        (pilish-arguments-test--assert-following-markdown)
        (pilish-arguments-test--goto-text "saved label")
        (should (equal target (button-get (button-at (point)) 'pilish-subagent-name))))
      (pilish-arguments-test--goto-text "echo literal")
      (should (stringp (get-text-property (point) 'line-prefix)))
      (should-not (get-text-property (point) 'pilish-argument-locator)))))

(ert-deftest pilish-test-arguments-reviewed-retained-character-byte-bounds ()
  "Actual retained rows and visited nested keys respect the aggregate quotas."
  (let ((block (pilish--make-tool-block)) (keys 0)
        (original (symbol-function 'pilish--argument--emit-key)))
    (cl-letf (((symbol-function 'pilish--argument--emit-key)
               (lambda (&rest args) (cl-incf keys) (apply original args))))
      (dotimes (n 12)
        (let ((node (and (> n 0) (pilish--make-nested-call :id (format "child%d" n)))))
          (when node (push node (pilish--tool-block-nested-calls block)))
          (pilish--argument-observe
           block node "custom"
           (list :a (make-string 9000 #x1f600) :b (make-string 9000 ?x)
                 :c [(:inside [1 2 3])])))))
    (let* ((view (pilish--tool-block-argument-view block))
           (rows (append (pilish--argument-view-root-rows view)
                         (mapcan (lambda (call) (copy-sequence (pilish--nested-call-argument-rows call)))
                                 (pilish--tool-block-nested-calls block))))
           (retained (seq-remove (lambda (row) (eq (pilish--argument-row-role row) 'omission)) rows))
           (text (mapconcat (lambda (row)
                              (concat (pilish--argument-row-key row) (pilish--argument-row-text row)))
                            retained "")))
      (should (<= (length text) pilish--argument-limit-block-chars))
      (should (<= (string-bytes text) pilish--argument-limit-block-bytes))
      (should (= (length text) (pilish--argument-view-chars view)))
      (should (= (string-bytes text) (pilish--argument-view-bytes view)))
      (should (= keys (pilish--argument-view-keys view))))))

(ert-deftest pilish-test-arguments-reviewed-large-edits-schema-after-display-cut ()
  "A clipped value does not duplicate recognized edits or hide unknown fields."
  (dolist (unknown '(nil t))
    (pilish-arguments-test--with-chat
      (let ((record (append (list :oldText (make-string 6000 ?x) :newText "new")
                            (when unknown '(:extra "diagnostic")))))
        (pilish-arguments-test--execute
         "r" "edit" (list :path "/a" :edits (vector record)) "ok" nil
         '(:diff "- 1 old\n+ 1 new")))
      (should (eq (and (string-match-p "edits=" (pilish-arguments-test--visible-text)) t)
                  unknown)))))

(ert-deftest pilish-test-arguments-reviewed-large-integer-work ()
  (dolist (value (list (expt 10 10000) (- (expt 10 10000))
                       pilish--argument-number-bound (- pilish--argument-number-bound)))
    (let ((block (pilish--make-tool-block))
          (original (symbol-function 'number-to-string)))
      (cl-letf (((symbol-function 'number-to-string)
                 (lambda (number)
                   (should-not (eq number value))
                   (funcall original number))))
        (pilish--argument-observe block nil "custom" (list :number value)))
      (let ((row (car (pilish--argument-view-root-rows
                      (pilish--tool-block-argument-view block)))))
        (should (pilish--argument-row-p row))
        (should (string-match-p "integer exceeds display limit" (pilish--argument-row-text row)))
        (should (eq (pilish--argument-row-cut row) 'value))))))

(ert-deftest pilish-test-arguments-reviewed-json-large-integer-display ()
  (dolist (literal '("9223372036854775807" "-9223372036854775808"
                     "9007199254740991" "0"))
    (let* ((args (pilish--parse-json-line (concat "{\"number\":" literal "}")))
           (value (plist-get args :number))
           (block (pilish--make-tool-block)))
      (should (integerp value))
      (should (= value (string-to-number literal)))
      (pilish--argument-observe block nil "custom" args)
      (let ((row (car (pilish--argument-view-root-rows
                      (pilish--tool-block-argument-view block)))))
        (should (pilish--argument-row-p row))
        (should (equal (pilish--argument-row-text row) literal))
        (should-not (pilish--argument-row-cut row))))))

(ert-deftest pilish-test-arguments-final-short-literals-hot-and-cold ()
  "Short argument data stays literal independently of fold actionability."
  (dolist (nested '(nil t))
    (dolist (rows '(nil t))
      (dolist (value '("[launch](https://example.com)" "**literal**" "`literal`"))
        (pilish-arguments-test--with-chat
          (let ((args (append (list :payload value) (when rows '(:other "A\nB")))))
            (if nested (pilish-arguments-test--child "custom" args "CHILD")
              (pilish-arguments-test--execute "r" "custom" args "OUT")))
          (pilish--render-history-text
           "\nAFTER-PARAGRAPH **bold** [real link](https://example.org).\n\n```elisp\n(message \"AFTER-CODE\")\n```")
          (dolist (cold '(nil t))
            (when cold (pilish--cool-completed-tool-blocks (pilish-arguments-test--all-tool-overlays)))
            (pilish-arguments-test--assert-following-markdown)
            (should (string-match-p (regexp-quote (concat "payload=" value))
                                    (pilish-arguments-test--visible-text)))
            (pilish-arguments-test--goto-text value)
            (let ((start (point)))
              (dotimes (offset (length value))
                (should-not (button-at (+ start offset)))
                (should-not (get-text-property (+ start offset) 'invisible))
                (should (equal (get-text-property (+ start offset) 'face)
                               'pilish-tool-command))))
            (when cold
              (should-not (text-property-not-all (point-min) (point-max) 'pilish-argument-address nil))
              (should-not (text-property-not-all (point-min) (point-max) 'pilish-argument-locator nil)))
            (pilish-arguments-test--goto-text "real link")
            (should (button-at (point)))))))))

(ert-deftest pilish-test-arguments-final-child-splice-preserves-output ()
  "Child argument TAB never deletes unchanged output or its diff overlays."
  (pilish-arguments-test--with-chat
    (pilish-arguments-test--child
     "edit" (list :path (concat "/tmp/" (make-string 130 ?a)) :note "A1\nA2\nA3")
     "OK" '(:diff "- 1 OLD\n+ 1 CHILD-DIFF\n  2 TAIL"))
    (pilish-arguments-test--goto-text "… 3 more lines")
    (pilish-toggle-tool-section)
    (pilish-arguments-test--goto-text "CHILD-DIFF")
    (let* ((block (pilish--nested-tool-owner "root"))
           (end-marker (pilish--tool-block-end-marker block))
           (output-marker (copy-marker (point)))
           (diff-overlays (seq-filter (lambda (ov) (overlay-get ov 'pilish-diff-overlay))
                                      (overlays-in (point-min) (point-max))))
           (mutations 0)
           (hook (lambda (&rest _) (cl-incf mutations)))
           (inhibit-read-only t))
      (should diff-overlays)
      (add-text-properties (point) (+ (point) (length "CHILD-DIFF"))
                           (list 'modification-hooks (list hook) 'pilish-test-output-identity hook))
      (dolist (needle '("note=" "edit"))
        (pilish-arguments-test--goto-text needle)
        (dotimes (_ 2)
          (pilish-toggle-tool-section)
          (should (= mutations 0))
          (should (eq end-marker (pilish--tool-block-end-marker block)))
          (should (equal (get-text-property (marker-position output-marker) 'pilish-test-output-identity) hook))
          (should (equal (buffer-substring-no-properties output-marker (+ output-marker 10)) "CHILD-DIFF"))
          (should (equal diff-overlays
                         (seq-filter (lambda (ov) (overlay-get ov 'pilish-diff-overlay))
                                     (overlays-in (point-min) (point-max)))))
          (should (equal (get-text-property (point) 'pilish-tool-section) '(child . "child")))
          (should-error (pilish-visit-file) :type 'user-error)))
      (set-marker output-marker nil))))

(defun pilish-arguments-test--child-output-two-window ()
  "Keep the other reader on the same child output text through argument TAB."
  (let ((chat (generate-new-buffer " *arguments-child-output*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer chat)
          (pilish-chat-mode)
          (pilish-arguments-test--child
           "custom" '(:first "A1\nA2\nA3" :second "B1\nB2")
           (mapconcat (lambda (n) (format "CHILD-LINE-%02d" n)) (number-sequence 0 50) "\n"))
          (pilish--render-history-text (mapconcat #'number-to-string (number-sequence 0 100) "\n"))
          (pilish-arguments-test--goto-text "… 51 more lines")
          (pilish-toggle-tool-section)
          (let ((active (selected-window)) (other (split-window-below)))
            (set-window-buffer other chat)
            (pilish-arguments-test--goto-text "CHILD-LINE-20")
            (set-window-point other (+ (point) 3))
            (set-window-start other (line-beginning-position) t)
            (pilish-arguments-test--goto-text "first=")
            (set-window-start active (line-beginning-position) t)
            (redisplay t)
            (let ((other-y (and (display-graphic-p)
                                (cdr (posn-x-y (posn-at-point (window-point other) other))))))
              (dotimes (_ 2)
                (pilish-toggle-tool-section)
                (redisplay t)
                (save-excursion
                  (pilish-arguments-test--goto-text "CHILD-LINE-20")
                  (should (= (window-point other) (+ (point) 3)))
                  (should (= (window-start other) (line-beginning-position))))
                (when other-y
                  (should (= other-y (cdr (posn-x-y (posn-at-point (window-point other) other))))))))))
      (when (buffer-live-p chat)
        (with-current-buffer chat (set-buffer-modified-p nil))
        (kill-buffer chat)))))

(ert-deftest pilish-test-arguments-final-child-output-two-window ()
  "An unchanged child output line retains point, start and character offset."
  (pilish-arguments-test--child-output-two-window))

(ert-deftest pilish-test-arguments-final-saved-input-actual-end-orders ()
  "Actual write/edit results refine saved diagnostic input in either order."
  (dolist (saved-first '(nil t))
    (dolist (tool '("write" "edit"))
      (ert-info ((format "tool=%s saved-first=%s" tool saved-first))
        (pilish-arguments-test--with-chat
          (pilish-arguments-test--execute "root" "codemode" '(:code "1+1") "ROOT")
          (let ((snapshot
                 (list :type "message_end" :message
                       (list :role "toolResult" :toolCallId "root" :toolName "codemode"
                             :content [(:type "text" :text "ROOT")]
                             :nestedCalls
                             (list :complete t :calls
                                   (vector (list :id "child" :name tool :status "unfinished"
                                                 :arguments (if (equal tool "write") '(:path "/a" :content "BODY")
                                                              '(:path "/a" :oldText "OLD" :newText "NEW"))))))))
                (end (list :type "tool_execution_end" :toolCallId "child" :parentToolCallId "root" :toolName tool
                           :result (list :content [(:type "text" :text "OK")]
                                         :details (when (equal tool "edit") '(:diff "- 1 OLD\n+ 1 NEW"))))))
            (pilish--handle-display-event (if saved-first snapshot end))
            (when saved-first
              (should (string-match-p "\\(content=BODY\\|oldText=OLD\\)" (pilish-arguments-test--visible-text))))
            (pilish--handle-display-event (if saved-first end snapshot))
            (pilish--handle-display-event snapshot)
            (let* ((root (pilish--nested-tool-owner "root"))
                   (call (pilish--nested-call-get root "child")))
              (should (eq (pilish--argument-row-role (cadr (pilish--nested-call-argument-rows call))) 'input-represented))
              (pilish--argument-settle-pending-children root)
              (should (eq (pilish--argument-row-role (cadr (pilish--nested-call-argument-rows call))) 'input-represented)))
            (should-not (string-match-p "\\(content\\|oldText\\|newText\\)=" (pilish-arguments-test--visible-text)))))))))

(ert-deftest pilish-test-arguments-final-settlement-reconciles-actual-evidence ()
  "Settlement converges on actual evidence; missing fallback never demotes it."
  (let ((block (pilish--make-tool-block)))
    (pilish--argument-observe block nil "write" '(:path "/a" :content "BODY"))
    (pilish--argument-settle block nil "write" '(:result-present-p nil))
    (should (pilish--argument-settle block nil "write" '(:result-present-p t)))
    (should-not (pilish--argument-settle block nil "write" '(:result-present-p t)))
    (should-not (pilish--argument-settle block nil "write" '(:result-present-p nil)))
    (should (pilish--argument-settle block nil "write" '(:result-present-p t :is-error t)))
    (should (eq (pilish--argument-row-role
                 (cadr (pilish--argument-view-root-rows (pilish--tool-block-argument-view block)))) 'input-needed))))

(ert-deftest pilish-test-arguments-final-header-only-cooling ()
  "Completed missing results cool without fabricated output or retained controls."
  (dolist (tool '("codemode" "custom" "read"))
    (pilish-arguments-test--with-chat
      (pilish--render-history-tool
       (list :type "toolCall" :id "missing" :name tool
             :arguments (if (equal tool "read") '(:path "/tmp/a.txt") '(:code "FIRST\nSECOND"))) nil)
      (when-let* ((control (text-property-not-all (point-min) (point-max) 'pilish-argument-locator nil)))
        (goto-char control)
        (pilish-toggle-tool-section))
      (let* ((overlay (car (pilish-arguments-test--all-tool-overlays)))
             (block (pilish--tool-block-from-overlay overlay))
             (header-length (- (marker-position (pilish--tool-block-header-end block))
                               (overlay-start overlay)))
             (before (pilish-arguments-test--visible-text)))
        (should (pilish--completed-tool-overlay-p overlay))
        (should (pilish--cool-tool-overlay-preserving-view overlay))
        (font-lock-flush)
        (font-lock-ensure)
        (should-not (overlay-buffer overlay))
        (should-not (pilish--tool-block-argument-view block))
        (should-not (text-property-not-all (point-min) (point-max) 'pilish-argument-locator nil))
        (should-not (text-property-not-all (point-min) (point-max) 'pilish-argument-address nil))
        (should (equal before (pilish-arguments-test--visible-text)))
        (let* ((start (text-property-not-all (point-min) (point-max) 'pilish-cold-tool-block nil))
               (metadata (get-text-property start 'pilish-cold-tool-block)))
          (should (= (plist-get metadata :header-length) header-length))
          (should-not (marker-buffer (pilish--tool-block-header-end block)))
          (should-not (marker-buffer (pilish--tool-block-end-marker block)))
          (should-not (pilish--tool-block-output-view block))
          (when (equal tool "read")
            (should (equal (plist-get metadata :path) "/tmp/a.txt"))))))))

(ert-deftest pilish-test-arguments-final-active-generation-not-cooled ()
  "Another pending header does not make an active generation preview completed."
  (pilish-arguments-test--with-chat
    (let* ((block (pilish--display-tool-start "custom" nil))
           (overlay (pilish--tool-block-overlay block)))
      (pilish--argument-observe block nil "custom" '(:payload "FIRST\nSECOND"))
      (pilish--display-tool-update-header "custom" nil block)
      (puthash 0 (pilish--make-toolcall-stream :block block) (pilish--ensure-toolcall-streams))
      (pilish--display-tool-start "custom" nil)
      (let ((before (buffer-string)) (view (pilish--tool-block-argument-view block)))
        (should-not (pilish--completed-tool-overlay-p overlay))
        (should-not (pilish--cool-tool-overlay-preserving-view overlay))
        (should (equal before (buffer-string)))
        (should (eq view (pilish--tool-block-argument-view block)))
        (should (overlay-buffer overlay))))))

(ert-deftest pilish-test-arguments-final-child-output-separate-visible-line ()
  "Output controls cannot appear to be part of multiline argument data."
  (dolist (tool '("custom" "bash"))
    (pilish-arguments-test--with-chat
      (pilish-arguments-test--child tool (if (equal tool "bash") '(:command "echo FIRST\necho LAST")
                                         '(:payload "FIRST\nLAST" :short "last")) "CHILD")
      (dotimes (fold 2)
        (let ((visible (pilish-arguments-test--visible-text)))
          (should (string-match-p "\n… 1 more line\n" visible))
          (should-not (string-match-p "\n\n… 1 more line" visible))
          (should-not (string-match-p "last … 1\\|LAST … 1" visible)))
        (pilish-arguments-test--goto-text "FIRST")
        (pilish-toggle-tool-section))
      (pilish-arguments-test--goto-text "FIRST")
      (pilish-toggle-tool-section)
      (pilish-arguments-test--goto-text "… 1 more line")
      (should-not (get-text-property (point) 'pilish-argument-literal))
      (when (equal tool "bash")
        (save-excursion
          (forward-line -2)
          (should (get-text-property (point) 'pilish-argument-guard))
          (should (looking-at "[~`]\\{3,\\}$"))))
      (pilish-toggle-tool-section)
      (should (string-match-p "\nCHILD\nShow less\n" (pilish-arguments-test--visible-text)))
      (pilish-arguments-test--goto-text "Show less")
      (should (equal (pilish-arguments-test--gutter (point)) "▾")))))

(ert-deftest pilish-test-arguments-final-child-primary-saved-button-after-splice ()
  "Local primary argument replacement keeps the real saved-name button."
  (pilish-arguments-test--with-chat
    (setq pilish--state '(:session-file "/tmp/pilish-argument-anchor.jsonl"))
    (pilish-arguments-test--child
     "bash" '(:command "echo FIRST\necho LAST") "CHILD"
     '(:savedConversations
       (:version 1 :root "/tmp/pilish-argument-saved/"
        :items [(:sessionId "child" :file "child.jsonl" :label "saved label")])))
    (let (target)
      (dotimes (_ 3)
        (pilish-arguments-test--goto-text "saved label")
        (let* ((button (button-at (point)))
               (captured (and button (button-get button 'pilish-subagent-name)))
               opened)
          (should (pilish--snapshot-target-p captured))
          (if target (should (equal target captured)) (setq target captured))
          (cl-letf (((symbol-function 'pilish-open-subagent-snapshot)
                     (lambda (value) (setq opened value))))
            (button-activate button))
          (should (equal opened target)))
        (pilish-arguments-test--goto-text "echo FIRST")
        (pilish-toggle-tool-section)))))

(ert-deftest pilish-test-arguments-final-child-output-ingestion-boundary ()
  "Later known arguments cannot become source-line coordinates for child output."
  (let ((chat (generate-new-buffer " *arguments-child-ingestion*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer chat)
          (pilish-chat-mode)
          (pilish-arguments-test--child
           "custom" nil
           (mapconcat (lambda (n) (format "CHILD-LINE-%02d" n)) (number-sequence 0 50) "\n"))
          (pilish--render-history-text (mapconcat #'number-to-string (number-sequence 0 100) "\n"))
          (pilish-arguments-test--goto-text "… 51 more lines")
          (pilish-toggle-tool-section)
          (let ((other (split-window-below)))
            (set-window-buffer other chat)
            (pilish-arguments-test--goto-text "CHILD-LINE-20")
            (set-window-point other (+ (point) 3))
            (set-window-start other (line-beginning-position) t)
            (pilish--handle-display-event
             '(:type "message_end" :message
               (:role "toolResult" :toolCallId "root" :toolName "codemode"
                :content [(:type "text" :text "ROOT")]
                :nestedCalls (:complete t :calls
                              [(:id "child" :name "custom" :status "ok"
                                :arguments (:first "A1\nA2\nA3" :second "B1\nB2"))]))))
            (pilish-arguments-test--goto-text "CHILD-LINE-20")
            (should (= (window-point other) (+ (point) 3)))
            (should (= (window-start other) (line-beginning-position)))))
      (when (buffer-live-p chat)
        (with-current-buffer chat (set-buffer-modified-p nil))
        (kill-buffer chat)))))

(ert-deftest pilish-test-arguments-final-active-output-label-and-cold-count ()
  "The bottom count becomes Show less and cools to one inert continuation."
  (pilish-arguments-test--with-chat
    (let ((pilish-tool-preview-lines 2))
      (pilish-arguments-test--execute "r" "custom" '(:value "ok")
                                      "one\ntwo\nthree\nfour\nfive\nsix")
      (let* ((overlay (car (pilish-arguments-test--all-tool-overlays)))
             (button (pilish--find-toggle-button-in-region (overlay-start overlay) (overlay-end overlay)))
             (view (pilish-test--output-view button))
             (hidden (plist-get (pilish--tool-output-view-excerpt view) :hidden-lines)))
        (should (= hidden 4))
        (should (equal (button-label button) "… 4 more lines"))
        (should (equal (pilish-arguments-test--gutter (button-start button)) "▸"))
        (button-activate button)
        (should (string-match-p "six" (pilish-arguments-test--visible-text)))
        (setq button (pilish--find-toggle-button-in-region (overlay-start overlay) (overlay-end overlay)))
        (should (equal (button-label button) "Show less"))
        (should (equal (pilish-arguments-test--gutter (button-start button)) "▾"))
        (should (eq view (pilish-test--output-view button)))
        (should (= hidden (plist-get (pilish--tool-output-view-excerpt view) :hidden-lines)))
        (button-activate button)
        (pilish--cool-completed-tool-blocks (list overlay))
        (should (= 2 (length (split-string (pilish-arguments-test--visible-text)
                                           "… 4 more lines"))))))))

(ert-deftest pilish-test-arguments-duration-copy-is-real-text-outside-the-control ()
  "Copy includes the actual newline and duration, never a caret or alignment stretch."
  (pilish-arguments-test--with-chat
    (let* ((pilish-bash-preview-lines 1)
           (block (pilish--display-tool-start "bash" '(:command "echo duration") "copy-duration"))
           (overlay (pilish--tool-block-overlay block)))
      (pilish--display-tool-end "bash" nil [(:type "text" :text "ONE\nTWO\nTHREE")]
                                nil nil block (pilish--recorded-tool-time 1234))
      (dolist (state '(head all cold))
        (when (eq state 'all)
          (button-activate (pilish--find-toggle-button-in-region (overlay-start overlay) (overlay-end overlay))))
        (when (eq state 'cold) (pilish--cool-tool-overlay overlay))
        (let* ((footer (text-property-not-all (point-min) (point-max) 'pilish-tool-output-footer nil))
               (end (next-single-property-change footer 'pilish-tool-output-footer nil (point-max)))
               (duration (save-excursion (goto-char footer) (search-forward "Took 1.2s") (match-beginning 0)))
               (expected (pcase state ('head "… 2 more lines\n Took 1.2s\n")
                                          ('all "Show less\n Took 1.2s\n") (_ " Took 1.2s\n"))))
          (font-lock-flush)
          (font-lock-ensure)
          (should-not (button-at duration))
          (should-not (get-text-property duration 'pilish-tool-toggle))
          (dolist (pilish-copy-raw-markdown '(nil t))
            (let ((copy (pilish--filter-buffer-substring footer end)))
              (should (equal copy expected))
              (should (equal-including-properties copy (substring-no-properties copy)))))
          (unless (eq state 'cold)
            (let ((button (pilish--find-toggle-button-in-region (overlay-start overlay) (overlay-end overlay))))
              (should (equal (button-label button) (if (eq state 'head) "… 2 more lines" "Show less")))
              (should (< (button-end button) duration)))))))))

(defun pilish-arguments-test--output-button-keyboard (kind key)
  "Check KIND's Output button through KEY and RET in a displayed buffer."
  (let ((chat (generate-new-buffer " *arguments-button-keyboard*"))
        (pilish-tool-preview-lines 2)
        (output "OUTPUT-ONE\nOUTPUT-TWO\nOUTPUT-HIDDEN\nOUTPUT-FOUR\nOUTPUT-FIVE\nOUTPUT-SIX"))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer chat)
          (pilish-chat-mode)
          (pilish--render-history-text "Prelude one\nPrelude two\nPrelude three\n")
          (pcase kind
            ('child
             (pilish-arguments-test--child "custom" '(:note "ARG-FIRST\nARG-LAST") output))
            (_
             (pilish-arguments-test--execute
              "root" (if (eq kind 'compound) "codemode" "custom")
              '(:code "1+1" :note "ARG-FIRST\nARG-LAST") output)))
          (let* ((block (pilish--tool-block-from-overlay
                         (car (pilish-arguments-test--all-tool-overlays))))
                 (section (pcase kind ('compound 'output) ('child '(child . "child")))))
            (pilish--render-history-text
             (mapconcat (lambda (n) (format "Distant line %d" n)) (number-sequence 1 80) "\n"))
            (pilish-arguments-test--execute "unrelated" "custom" nil output)
            (goto-char (point-min))
            (set-window-start (selected-window) (point-min) t)
            (redisplay t)
            (dolist (event (list key key (kbd "RET") (kbd "RET")))
              (let* ((overlay (pilish--tool-block-overlay block))
                     (button (pilish--find-toggle-button-in-region
                              (overlay-start overlay) (overlay-end overlay) section))
                     (expanded (eq (pilish--tool-output-view-selection
                                    (pilish-test--output-view button)) 'all))
                     (start (window-start)))
                (goto-char (button-start button))
                (should (button-at (point)))
                (should (eq (and (string-match-p "OUTPUT-HIDDEN" (pilish-arguments-test--visible-text)) t)
                            expanded))
                (execute-kbd-macro event)
                (redisplay t)
                (should (eq (and (string-match-p "OUTPUT-HIDDEN" (pilish-arguments-test--visible-text)) t)
                            (not expanded)))
                (should-not (string-match-p "ARG-LAST" (pilish-arguments-test--visible-text)))
                (should (= start (window-start)))
                (should (eq (pilish--tool-overlay-at-point) (pilish--tool-block-overlay block)))))
            (pilish-arguments-test--goto-text "note=")
            (execute-kbd-macro key)
            (should (string-match-p "ARG-LAST" (pilish-arguments-test--visible-text)))
            (should-not (string-match-p "OUTPUT-HIDDEN" (pilish-arguments-test--visible-text)))))
      (when (buffer-live-p chat)
        (with-current-buffer chat (set-buffer-modified-p nil))
        (kill-buffer chat)))))

(defun pilish-arguments-test--saved-button-keyboard (key)
  "Check that a saved button folds locally through KEY and opens through RET."
  (let ((chat (generate-new-buffer " *arguments-saved-keyboard*"))
        (pilish-tool-preview-lines 2))
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer chat)
          (pilish-chat-mode)
          (setq pilish--state '(:session-file "/tmp/pilish-argument-anchor.jsonl"))
          (pilish-arguments-test--execute
           "saved" "custom" '(:note "ARG-FIRST\nARG-LAST")
           "OUTPUT-ONE\nOUTPUT-TWO\nOUTPUT-HIDDEN\nOUTPUT-FOUR\nOUTPUT-FIVE\nOUTPUT-SIX" nil
           '(:savedConversations
             (:version 1 :root "/tmp/pilish-argument-saved/"
              :items [(:sessionId "child" :file "child.jsonl" :label "saved label")])))
          (pilish-arguments-test--goto-text "saved label")
          (let ((target (button-get (button-at (point)) 'pilish-subagent-name))
                opened)
            (should (pilish--snapshot-target-p target))
            (cl-letf (((symbol-function 'pilish-open-subagent-snapshot)
                       (lambda (value) (setq opened value))))
              (dotimes (iteration 2)
                (setq opened nil)
                (pilish-arguments-test--goto-text "saved label")
                (execute-kbd-macro key)
                (should-not opened)
                (should (eq (and (string-match-p "OUTPUT-HIDDEN" (pilish-arguments-test--visible-text)) t)
                            (= iteration 0)))
                (should-not (string-match-p "ARG-LAST" (pilish-arguments-test--visible-text)))
                (pilish-arguments-test--goto-text "saved label")
                (should (equal target (button-get (button-at (point)) 'pilish-subagent-name)))
                (execute-kbd-macro (kbd "RET"))
                (should (equal opened target))))))
      (when (buffer-live-p chat)
        (with-current-buffer chat (set-buffer-modified-p nil))
        (kill-buffer chat)))))

(ert-deftest pilish-test-arguments-saved-button-keyboard ()
  "Saved-name C-i folds local output while RET opens the captured target."
  (pilish-arguments-test--saved-button-keyboard (kbd "C-i")))

(ert-deftest pilish-test-arguments-output-button-keyboard-ordinary ()
  "C-i on ordinary Output reveals and collapses locally, as does RET."
  (pilish-arguments-test--output-button-keyboard 'ordinary (kbd "C-i")))

(ert-deftest pilish-test-arguments-output-button-keyboard-compound ()
  "C-i on compound Output reveals and collapses locally, as does RET."
  (pilish-arguments-test--output-button-keyboard 'compound (kbd "C-i")))

(ert-deftest pilish-test-arguments-output-button-keyboard-child ()
  "C-i on child Output leaves its argument fold independent and RET works."
  (pilish-arguments-test--output-button-keyboard 'child (kbd "C-i")))

(defun pilish-arguments-test--gutter (position)
  "Return POSITION's display-only tool disclosure glyph, or nil."
  (let ((prefix (get-text-property position 'line-prefix)))
    (when (stringp prefix)
      (cl-loop for index below (length prefix)
               for display = (get-text-property index 'display prefix)
               when (equal (car-safe display) '(margin left-margin))
               return (cadr display)))))

(ert-deftest pilish-test-polish-root-child-bash-layout ()
  "Root and child Bash headings leave multiline command data alone."
  (dolist (nested '(nil t))
    (pilish-arguments-test--with-chat
      (let ((command "printf FIRST\n  printf SECOND\nprintf LAST"))
        (if nested
            (pilish-arguments-test--child "bash" (list :command command :timeout 10) "CHILD")
          (pilish-arguments-test--execute "r" "bash" (list :command command :timeout 10) "ROOT"))
        (should (string-match-p "^bash timeout=10\nprintf FIRST…$" (pilish-arguments-test--visible-text)))
        (pilish-arguments-test--goto-text "printf FIRST")
        (should (equal (pilish-arguments-test--gutter (point)) "▸"))
        (pilish-toggle-tool-section)
        (pilish-arguments-test--goto-text "printf FIRST")
        (let ((start (point)))
          (search-forward "printf LAST")
          (should (equal (pilish--filter-buffer-substring start (point)) command))
          (should (equal (buffer-substring-no-properties start (point)) command)))
        (should (string-match-p "^bash timeout=10\nprintf FIRST\n  printf SECOND\nprintf LAST$"
                                (pilish-arguments-test--visible-text)))
        (should-not (string-match-p "✓\\|[0-9]ms\\|[0-9]\\.[0-9]s" (pilish-arguments-test--visible-text)))))))

(ert-deftest pilish-test-polish-multiline-teaser-width-boundaries ()
  "Root, child and named rows reserve a continuation marker within the width."
  (dolist (nested '(nil t))
    (dolist (named '(nil t))
      (dolist (width '(24 54))
        (dolist (delta '(-1 0 1))
          (ert-info ((format "nested=%S named=%S width=%d delta=%d" nested named width delta))
            (pilish-arguments-test--with-chat
              (let* ((overlay (make-overlay (point-min) (point-max)))
                     (block (pilish--make-tool-block :overlay overlay))
                     (tool (if named "custom" "bash"))
                     (node (and nested (pilish--make-nested-call :id "child" :name tool :status 'ok)))
                     (key-part (if named "payload=" ""))
                     (budget (- width 2 (length key-part)))
                     (first-length (+ budget delta))
                     (value (concat (make-string first-length ?x) "\nSECOND…"))
                     (locator (list 'argument (and nested "child") 0)))
                (overlay-put overlay 'pilish-tool-name tool)
                (pilish--argument-observe block node tool (list (if named :payload :command) value))
                (let* ((paint (pilish--tool-call-text block node width))
                       (line (with-temp-buffer
                               (insert (if named (cdr paint) (substring (car paint) (1+ (string-match-p "\n" (car paint))))))
                               (pilish--visible-text (point-min) (point-max))))
                       (prefix (get-text-property 0 'line-prefix line))
                       (alignment (cl-loop for index below (length prefix)
                                           unless (get-text-property index 'pilish-disclosure-hit prefix)
                                           sum (char-width (aref prefix index)))))
                  (should (= alignment 2))
                  (should (<= (+ alignment (string-width line)) width))
                  (should (equal (substring-no-properties line)
                                 (concat key-part (make-string (min first-length (1- budget)) ?x) "…")))
                  (should (equal (get-text-property 0 'pilish-argument-locator line) locator)))
                (setf (pilish--tool-block-folds block) (list locator))
                (let* ((paint (pilish--tool-call-text block node width))
                       (inhibit-read-only t))
                  (insert (if named (cdr paint) (car paint)))
                  (let ((start (text-property-any (point-min) (point-max) 'pilish-argument-value t)))
                    (should start)
                    (should (equal (buffer-substring-no-properties start (+ start (length value))) value))
                    (dolist (pilish-copy-raw-markdown '(nil t))
                      (should (equal (pilish--filter-buffer-substring start (+ start (length value))) value)))))))))))))

(ert-deftest pilish-test-polish-multiline-teaser-literal-ellipsis ()
  "A literal ellipsis stays data beside the required continuation marker."
  (dolist (nested '(nil t))
    (dolist (named '(nil t))
      (dolist (width '(24 54))
        (dolist (multiline '(nil t))
          (with-temp-buffer
            (let* ((overlay (make-overlay (point-min) (point-max)))
                   (block (pilish--make-tool-block :overlay overlay))
                   (tool (if named "custom" "bash"))
                   (node (and nested (pilish--make-nested-call :id "child" :name tool :status 'ok)))
                   (value (if multiline "wait…\nSECOND…" "wait…")))
              (overlay-put overlay 'pilish-tool-name tool)
              (pilish--argument-observe block node tool (list (if named :payload :command) value))
              (let* ((paint (pilish--tool-call-text block node width))
                     (text (with-temp-buffer
                             (insert (concat (car paint) (when (cdr paint) (concat "\n" (cdr paint)))))
                             (pilish--visible-text (point-min) (point-max)))))
                (should (string-suffix-p (if multiline "wait……" "wait…") text))
                (should-not (string-match-p "SECOND" text))))))))))

(ert-deftest pilish-test-polish-short-bash-timeout-is-not-shell-source ()
  "A short command title never absorbs timeout as if it were shell source."
  (dolist (nested '(nil t))
    (pilish-arguments-test--with-chat
      (if nested (pilish-arguments-test--child "bash" '(:command "ls -la" :timeout 10) "OUT")
        (pilish-arguments-test--execute "r" "bash" '(:command "ls -la" :timeout 10) "OUT"))
      (should (string-match-p "^bash ls -la\ntimeout=10$" (pilish-arguments-test--visible-text))))))

(ert-deftest pilish-test-polish-literal-triangles-survive-copy-and-cooling ()
  "Tool controls add no copy characters and never delete triangles in data."
  (pilish-arguments-test--with-chat
    (pilish-arguments-test--execute
     "r" "bash" '(:command "printf '▸ ▾'\n  echo SECOND") "stdout ▾ ▸")
    (pilish-arguments-test--goto-text "printf")
    (pilish-toggle-tool-section)
    (dolist (cold '(nil t))
      (when cold (pilish--cool-completed-tool-blocks (pilish-arguments-test--all-tool-overlays)))
      (dolist (pilish-copy-raw-markdown '(nil t))
        (let ((copy (pilish--filter-buffer-substring (point-min) (point-max))))
          (should (= 4 (cl-count-if (lambda (char) (memq char '(?▸ ?▾))) copy)))
          (should (string-match-p "printf '▸ ▾'\n  echo SECOND" copy))
          (should (string-match-p "stdout ▾ ▸" copy)))))))

(ert-deftest pilish-test-polish-empty-first-value-row-has-only-one-gutter ()
  "An empty first literal line owns its gutter without changing any value line."
  (pilish-arguments-test--with-chat
    (pilish-arguments-test--execute "r" "bash" '(:command "\n  echo SECOND\nlast") "OUT")
    (pilish-arguments-test--goto-text "bash")
    (pilish-toggle-tool-section)
    (let ((start (text-property-any (point-min) (point-max) 'pilish-argument-value t)))
      (should start)
      (should (eq (char-after start) ?\n))
      (should (equal (pilish-arguments-test--gutter start) "▾"))
      (pilish-arguments-test--goto-text "bash")
      (should-not (pilish-arguments-test--gutter (point)))
      (should-not (pilish-arguments-test--gutter (1+ start)))
      (should-not (get-text-property 0 'display (get-text-property (1+ start) 'wrap-prefix)))
      (should (equal (buffer-substring-no-properties start (+ start (length "\n  echo SECOND\nlast"))) "\n  echo SECOND\nlast")))))

(ert-deftest pilish-test-polish-prefix-face-hot-error-cold ()
  "Owned alignment follows the hot face and releases it without changing values."
  (dolist (is-error '(nil t))
    (pilish-arguments-test--with-chat
      (pilish-arguments-test--execute
       "r" "bash" '(:command "if true; then\n  echo 'SECOND'\nfi") "OUT" is-error)
      (pilish-arguments-test--goto-text "if true")
      (pilish-toggle-tool-section)
      (pilish-arguments-test--goto-text "SECOND")
      (let ((prefix (get-text-property (point) 'line-prefix))
            (value-face (get-text-property (point) 'font-lock-face)))
        (should (eq (get-text-property 0 'face prefix)
                    (if is-error 'pilish-tool-block-error 'pilish-tool-block)))
        (pilish--cool-completed-tool-blocks (pilish-arguments-test--all-tool-overlays))
        (pilish-arguments-test--goto-text "SECOND")
        (let ((cold-prefix (get-text-property (point) 'line-prefix)))
          (should (equal (substring-no-properties prefix) cold-prefix))
          (should-not (get-text-property 0 'face cold-prefix))
          (should (equal value-face (get-text-property (point) 'font-lock-face))))))))

(ert-deftest pilish-test-polish-equal-header-refreshes-prefix-properties ()
  "Equal header characters still receive changed display-only properties."
  (pilish-arguments-test--with-chat
    (pilish-arguments-test--execute "r" "bash" '(:command "echo FIRST\necho SECOND") "OUT")
    (let* ((overlay (car (pilish-arguments-test--all-tool-overlays)))
           (block (pilish--tool-block-from-overlay overlay))
           (start (overlay-start overlay))
           (end (1- (marker-position (pilish--tool-block-header-end block))))
           (header (buffer-substring start end))
           (marker (copy-marker (+ start 2)))
           (mutations 0)
           (hook (lambda (&rest _) (cl-incf mutations))))
      (put-text-property 0 1 'line-prefix "NEW-PREFIX" header)
      (let ((inhibit-read-only t))
        (put-text-property start end 'modification-hooks (list hook)))
      (pilish--replace-tool-header block header)
      (should (equal "NEW-PREFIX" (get-text-property start 'line-prefix)))
      (should (= mutations 0))
      (should (= (+ start 2) marker))
      (set-marker marker nil))))

(ert-deftest pilish-test-arguments-cold-release-is-not-a-text-edit ()
  "Releasing real root and child controls preserves the Emacs edit contract."
  (dolist (modified '(nil t))
    (dolist (undo-enabled '(nil t))
      (ert-info ((format "modified=%S undo-enabled=%S" modified undo-enabled))
        (pilish-arguments-test--with-chat
          (let* ((pilish-tool-preview-lines 1)
                 (root-args '(:code "1+1\n2+2" :rootNote "ROOT-FIRST\nROOT-SECOND"))
                 (child-args '(:path "/tmp/a" :oldText "a" :newText "b"
                                    :childNote "CHILD-FIRST\nCHILD-SECOND"))
                 (diff "- 1     a\n+ 1     b")
                 (before 0) (after 0) (property 0))
            (pilish--handle-display-event
             (list :type "tool_execution_start" :toolCallId "root"
                   :toolName "codemode" :args root-args))
            (pilish--handle-display-event
             (list :type "tool_execution_start" :toolCallId "child"
                   :parentToolCallId "root" :toolName "edit" :args child-args))
            (pilish--handle-display-event
             (list :type "tool_execution_end" :toolCallId "child"
                   :parentToolCallId "root" :toolName "edit"
                   :result (list :content [(:type "text" :text "CHILD-OUTPUT")]
                                 :details (list :diff diff))))
            (pilish--handle-display-event
             '(:type "tool_execution_end" :toolCallId "root" :toolName "codemode"
               :result (:content [(:type "text" :text "PARENT-OUTPUT")])))
            (dolist (label '("Script" "… 2 more lines" "rootNote=" "childNote="))
              (pilish-arguments-test--goto-text label)
              (pilish-toggle-tool-section))
            (font-lock-ensure)
            (let* ((block (pilish--tool-block-from-overlay
                           (car (pilish-arguments-test--all-tool-overlays))))
                   (child (car (pilish--tool-block-nested-calls block)))
                   (result (pilish--tool-block-result block))
                   (child-result (pilish--nested-call-result child))
                   (output (pilish--tool-block-output-view block))
                   (other-folds (seq-remove
                                 (lambda (fold) (eq (car-safe fold) 'argument))
                                 (pilish--tool-block-folds block))))
              (should (memq 'script other-folds))
              (should (derived-mode-p 'md-ts-mode))
              (should (treesit-parser-list))
              (should buffer-read-only)
              (dolist (text '("ROOT-FIRST\nROOT-SECOND" "CHILD-FIRST\nCHILD-SECOND"
                              "PARENT-OUTPUT" "- 1     a"))
                (should (string-match-p (regexp-quote text)
                                        (pilish-arguments-test--visible-text))))
              (should (pilish--tool-block-argument-view block))
              (should (pilish--nested-call-argument-rows child))
              (should (pilish--nested-call-argument-charge child))
              (should (seq-some (lambda (fold) (eq (car-safe fold) 'argument))
                                (pilish--tool-block-folds block)))
              (dolist (prop '(pilish-argument-locator pilish-argument-address
                             pilish-disclosure-hit pilish-argument-guard))
                (should (text-property-not-all (point-min) (point-max) prop nil)))
              (cl-labels
                  ((retained ()
                     (list (buffer-substring-no-properties (point-min) (point-max))
                           (pilish-arguments-test--visible-text)
                           (let ((pilish-copy-raw-markdown nil))
                             (pilish--filter-buffer-substring (point-min) (point-max)))
                           (let ((pilish-copy-raw-markdown t))
                             (pilish--filter-buffer-substring (point-min) (point-max)))
                           (cl-loop for pos from (point-min) below (point-max)
                                    collect
                                    (list (get-text-property pos 'pilish-argument-guard)
                                          (get-text-property pos 'pilish-argument-literal)
                                          (get-text-property pos 'display)
                                          (get-text-property pos 'pilish-no-fontify)
                                          (mapcar
                                           (lambda (prop)
                                             (let ((prefix (get-text-property pos prop)))
                                               (cl-loop for index below (length prefix)
                                                        unless (get-text-property
                                                                index 'pilish-disclosure-hit prefix)
                                                        concat (char-to-string (aref prefix index)))))
                                           '(line-prefix wrap-prefix)))))))
                (let ((inhibit-read-only t))
                  (put-text-property
                   (point-min) (point-max) 'modification-hooks
                   (list (lambda (&rest _) (cl-incf property)))))
                (setq buffer-undo-list (if undo-enabled (list nil) t))
                (set-buffer-modified-p modified)
                (let ((state (retained))
                      (tick (buffer-chars-modified-tick))
                      (undo buffer-undo-list)
                      (undo-copy (copy-tree buffer-undo-list))
                      (before-change-functions
                       (cons (lambda (&rest _) (cl-incf before)) before-change-functions))
                      (after-change-functions
                       (cons (lambda (&rest _) (cl-incf after)) after-change-functions)))
                  (setq property 0)
                  (dotimes (_ 2) (pilish--argument-release-cold block))
                  (should (= before 0))
                  (should (= after 0))
                  (should (= property 0))
                  (should (equal state (retained)))
                  (should (= tick (buffer-chars-modified-tick)))
                  (should (eq undo buffer-undo-list))
                  (should (equal undo-copy buffer-undo-list))
                  (should (eq modified (buffer-modified-p)))
                  (should buffer-read-only)
                  (should-not inhibit-read-only)
                  (should-not inhibit-modification-hooks)
                  (should-not (pilish--tool-block-argument-view block))
                  (should-not (pilish--nested-call-argument-rows child))
                  (should-not (pilish--nested-call-argument-charge child))
                  (should (equal other-folds (pilish--tool-block-folds block)))
                  (should (eq root-args (pilish--tool-block-args block)))
                  (should (eq child-args (pilish--nested-call-arguments child)))
                  (should (eq result (pilish--tool-block-result block)))
                  (should (eq child-result (pilish--nested-call-result child)))
                  (should (eq diff (plist-get (plist-get child-result :details) :diff)))
                  (should (eq output (pilish--tool-block-output-view block)))
                  (dolist (prop '(pilish-argument-locator pilish-argument-address
                                 pilish-disclosure-hit))
                    (should-not (text-property-not-all (point-min) (point-max) prop nil)))
                  (dolist (prop '(line-prefix wrap-prefix))
                    (dotimes (index (buffer-size))
                      (let ((prefix (get-text-property (+ (point-min) index) prop)))
                        (when (stringp prefix)
                          (should-not (text-property-not-all
                                       0 (length prefix) 'pilish-disclosure-hit nil prefix))))))
                  (pilish-arguments-test--goto-text "CHILD-SECOND")
                  (let ((inhibit-read-only t)) (delete-char 1))
                  (should (> before 0))
                  (should (> after 0))
                  (should (> property 0)))))))))))

(ert-deftest pilish-test-polish-output-only-cold-release-is-idempotent ()
  "Output-only blocks discard gutter controls even without an argument view."
  (pilish-arguments-test--with-chat
    (let* ((pilish-tool-preview-lines 1)
           (block (pilish--display-tool-start "custom" nil "r"))
           (overlay (pilish--tool-block-overlay block)))
      (pilish--display-tool-end "custom" nil [(:type "text" :text "one\ntwo\nthree")] nil nil block)
      (let ((button (pilish--find-toggle-button-in-region (overlay-start overlay) (overlay-end overlay))))
        (should (equal (button-label button) "… 2 more lines"))
        (should (equal (pilish-arguments-test--gutter (button-start button)) "▸")))
      (pilish--argument-release-cold block)
      (let ((before (buffer-string)))
        (pilish--argument-release-cold block)
        (should (equal-including-properties before (buffer-string))))
      (pilish--cool-completed-tool-blocks (list overlay))
      (should-not (string-match-p "[▸▾]" (buffer-string)))
      (should-not (text-property-not-all (point-min) (point-max) 'pilish-argument-locator nil)))))

(ert-deftest pilish-test-polish-codemode-banner-exact-original-boundary ()
  "Only an exact separate first banner with the actual outcome is omitted."
  (let ((ok "Script completed\nWall time 1.2 seconds\nOutput:\n")
        (failed "Script failed\nWall time 1.2 seconds\nOutput:\n"))
    (dolist (is-error '(nil t))
      (let* ((banner (if is-error failed ok))
             (original (vector (list :type "text" :text banner) '(:type "text" :text "STDOUT")))
             (copy (copy-tree original t)))
        (should (equal "STDOUT" (plist-get (pilish--tool-result-presentation
                                           "codemode" nil original nil is-error) :text)))
        (should (equal original copy))))
    (dolist (content (list (vector nil (list :type "text" :text ok))
                           (vector 7 (list :type "text" :text ok))
                           (vector (list :type "text" :text (concat ok "STDOUT")))
                           (vector (list :type "text" :text (string-trim-right ok)))
                           (vector (list :type "text" :text failed))
                           (vector '(:type "text" :text "STDOUT") (list :type "text" :text ok))))
      (should (string-match-p "Script " (plist-get (pilish--tool-result-presentation
                                                   "codemode" nil content nil nil) :text))))
    (should (string-match-p "Script completed" (plist-get (pilish--tool-result-presentation
                                                            "custom" nil (vector (list :type "text" :text ok)) nil nil) :text)))))

(ert-deftest pilish-test-polish-codemode-empty-image-error-path-output ()
  "Banner omission keeps diagnostics and images but creates no empty output."
  (pilish-arguments-test--with-chat
    (let ((pilish-tool-preview-lines 100))
      (pilish-arguments-test--execute "empty" "codemode" '(:code "1+1")
                                      "Script completed\nWall time 0.0 seconds\nOutput:\n")
      (should-not (string-match-p "Output\\|No output\\|Wall time" (pilish-arguments-test--visible-text)))
      (should (= 2 (pilish-test--count-matches "^```" (buffer-string))))))
  (let* ((content [(:type "text" :text "Script failed\nWall time 1.0 seconds\nOutput:\n")
                   (:type "text" :text "STDOUT matches child")
                   (:type "image" :mimeType "image/png" :data "invalid")
                   (:type "text" :text "Script error:\nTimed out; aborted; sandbox failure\nOutput truncated; spill failed")])
         (presentation (pilish--tool-result-presentation "codemode" nil content nil t)))
    (should (string-match-p "STDOUT matches child" (plist-get presentation :text)))
    (should (string-match-p "Script error:\nTimed out; aborted; sandbox failure\nOutput truncated; spill failed"
                            (plist-get presentation :text)))
    (should (plist-get presentation :image-content-p))
    (should (plist-get presentation :images)))
  (pilish-arguments-test--with-chat
    (pilish-arguments-test--execute
     "path" "codemode" '(:code "1+1") "Script completed\nWall time 0.0 seconds\nOutput:\n"
     nil '(:calls [] :fullOutputPath "/tmp/pilish-FULL-OUTPUT"))
    (should (string-match-p "Full output: /tmp/pilish-FULL-OUTPUT" (pilish-arguments-test--visible-text)))
    (should-not (string-match-p "Wall time\\|No output" (pilish-arguments-test--visible-text)))))

(ert-deftest pilish-test-polish-stacked-complete-primary-is-not-actionable ()
  "Moving a complete value below its heading does not invent a fold."
  (pilish-arguments-test--with-chat
    (let ((pilish--chat-display-width-override 36)
          (command (make-string 34 ?x)))
      (pilish-arguments-test--execute "r" "bash" (list :command command) "OUT")
      (should (string-match-p (regexp-quote (concat "bash\n" command))
                              (pilish-arguments-test--visible-text)))
      (pilish-arguments-test--goto-text "bash")
      (should-not (get-text-property (point) 'pilish-argument-locator))
      (should-not (pilish--toggle-tool-argument-at-point)))))

(ert-deftest pilish-test-polish-child-primary-width-change-keeps-owned-secondaries ()
  "A local primary splice cannot move secondary data into or out of its span."
  (dolist (initial-width '(24 80))
    (pilish-arguments-test--with-chat
      (let ((pilish--chat-display-width-override initial-width))
        (pilish-arguments-test--child
         "bash" '(:command "echo FIRST\necho SECOND" :timeout 10 :options "ABCDEFGH") "CHILD"))
      (pilish-arguments-test--goto-text "echo FIRST")
      (let ((pilish--chat-display-width-override (if (= initial-width 24) 80 24)))
        (pilish-toggle-tool-section))
      (let ((visible (pilish-arguments-test--visible-text)))
        (should (string-match-p "echo FIRST\necho SECOND" visible))
        (should (= 1 (pilish-test--count-matches "timeout=10" visible)))
        (should (= 1 (pilish-test--count-matches "options=ABCDEFGH" visible)))))))

(ert-deftest pilish-test-correction-codemode-banner-case-is-data ()
  "Differently capitalized banners remain received data even with case folding."
  (let ((case-fold-search t))
    (dolist (text '("SCRIPT COMPLETED\nWALL TIME 1.2 SECONDS\noutput:\n"
                    "script completed\nWall time 1.2 seconds\nOutput:\n"
                    "Script completed\nwall time 1.2 seconds\nOutput:\n"
                    "Script completed\nWall time 1.2 seconds\noutput:\n"))
      (pilish-arguments-test--with-chat
        (pilish-arguments-test--execute "r" "codemode" '(:code "1+1") text)
        (should (string-match-p (regexp-quote (string-trim-right text))
                                (pilish-arguments-test--visible-text)))))))

(ert-deftest pilish-test-correction-empty-ordinary-results-have-no-body ()
  "Ordinary, end-only and saved empty success stays header-only through cooling."
  (dolist (path '(ordinary end-only history))
    (dolist (content '([] [(:type "text" :text "Script completed\nWall time 0.0 seconds\nOutput:\n")]))
      (pilish-arguments-test--with-chat
        (pcase path
          ('ordinary
           (let ((block (pilish--display-tool-start "codemode" nil "r")))
             (pilish--display-tool-end "codemode" nil content nil nil block)))
          ('end-only
           (pilish--handle-display-event
            (list :type "tool_execution_end" :toolCallId "r" :toolName "codemode"
                  :result (list :content content))))
          ('history
           (pilish--render-history-tool
            '(:type "toolCall" :id "r" :name "codemode" :arguments (:code "1+1"))
            (list :content content))))
        (should-not (string-match-p "```\\|Output\\|No output" (buffer-string)))
        (let ((before (buffer-substring-no-properties (point-min) (point-max))))
          (pilish--cool-completed-tool-blocks (pilish-arguments-test--all-tool-overlays))
          (should (equal before (buffer-substring-no-properties (point-min) (point-max)))))))))

(ert-deftest pilish-test-correction-ordinary-images-errors-paths-survive ()
  "Omitting an empty text fence does not suppress images, errors or path details."
  (dolist (kind '(image error path))
    (pilish-arguments-test--with-chat
      (let* ((content (if (eq kind 'error)
                          [(:type "text" :text "Script error: Timed out; aborted; sandbox failure")]
                        (vconcat [(:type "text" :text "Script completed\nWall time 0.0 seconds\nOutput:\n")]
                                 (when (eq kind 'image) [(:type "image" :mimeType "image/png" :data "invalid")]))))
             (details (when (eq kind 'path) '(:fullOutputPath "/tmp/ordinary-full-output"))))
        (pilish--handle-display-event
         (list :type "tool_execution_end" :toolCallId "r" :toolName "codemode"
               :isError (eq kind 'error) :result (list :content content :details details)))
        (pcase kind
          ('image
           (should (text-property-any (point-min) (point-max) 'pilish-image-preview t))
           (should-not (string-match-p "```" (buffer-string))))
          ('error (should (string-match-p "Script error: Timed out; aborted; sandbox failure" (buffer-string))))
          ('path (should (string-match-p "/tmp/ordinary-full-output" (buffer-string)))))))))

(ert-deftest pilish-test-correction-image-only-ordinary-cooling ()
  "An ordinary image-only result cools without losing its presentation."
  (pilish-arguments-test--with-chat
    (pilish--handle-display-event
     '(:type "tool_execution_end" :toolCallId "r" :toolName "codemode"
       :result (:content [(:type "text" :text "Script completed\nWall time 0.0 seconds\nOutput:\n")
                          (:type "image" :mimeType "image/png" :data "invalid")])))
    (let ((overlay (car (pilish-arguments-test--all-tool-overlays)))
          (before (pilish-arguments-test--visible-text)))
      (pilish--cool-completed-tool-blocks (list overlay))
      (should-not (overlay-buffer overlay))
      (should (text-property-any (point-min) (point-max) 'pilish-image-preview t))
      (should (equal before (pilish-arguments-test--visible-text))))))

(ert-deftest pilish-test-correction-hidden-replay-prefix-placement ()
  "Hidden transcript replay places ordinary controls without a selected reader."
  (pilish-arguments-test--with-chat
    (should-not (eq (window-buffer (selected-window)) (current-buffer)))
    (let* ((pilish-tool-preview-lines 1)
           (block (pilish--display-tool-start "custom" nil "r"))
           (overlay (pilish--tool-block-overlay block)))
      (pilish--display-tool-end "custom" nil [(:type "text" :text "ONE\nTWO\nTHREE")] nil nil block)
      (dotimes (_ 3)
        (font-lock-flush)
        (font-lock-ensure)
        (let* ((button (pilish--find-toggle-button-in-region (overlay-start overlay) (overlay-end overlay)))
               (start (button-start button))
               (fence (save-excursion (goto-char start) (forward-line -1) (point))))
          (should (invisible-p fence))
          (should (equal (pilish-arguments-test--gutter fence) "▸"))
          (should (equal (pilish-arguments-test--gutter start) "▸"))
          (let ((bounds (pilish--tool-fenced-content-bounds
                         (marker-position (overlay-get overlay 'pilish-header-end))
                         (overlay-end overlay))))
            (should (> start (cdr bounds)))
            (should-not (pilish-arguments-test--gutter (car bounds)))))))))

(ert-deftest pilish-test-correction-prefix-owner-boundaries ()
  "Hidden wrapper propagation stops at another address, section or visible text."
  (dolist (disclosure '(nil t))
    (dolist (boundary '(address section visible none))
      (with-temp-buffer
        (let ((locator '(argument "c" 0)))
          (insert (propertize "OTHER\n" 'display "" 'pilish-tool-section 'output
                              'pilish-argument-address locator))
          (let ((wrapper-start (point)))
            (insert (propertize "```\n" 'display (unless (eq boundary 'visible) "")
                                'pilish-argument-address (if (eq boundary 'address) '(argument "other" 0) locator)
                                'pilish-tool-section (if (eq boundary 'section) 'script 'output)))
            (let ((row-start (point)))
              (insert (propertize (if disclosure
                                      (let ((text (copy-sequence "Output")))
                                        (pilish--put-disclosure 0 (length text) nil #'ignore text))
                                    (propertize "value" 'line-prefix (pilish--tool-prefix-spaces 2)))
                                  'pilish-argument-address locator 'pilish-tool-section 'output))
              (pilish--tool-place-prefixes wrapper-start (point-max))
              (if (eq boundary 'none)
                  (should (equal-including-properties (get-text-property wrapper-start 'line-prefix)
                                                       (get-text-property row-start 'line-prefix)))
                (should-not (get-text-property wrapper-start 'line-prefix)))
              (should (equal (pilish-arguments-test--gutter row-start) (and disclosure "▸")))
              (should-not (get-text-property (point-min) 'line-prefix)))))))))

(ert-deftest pilish-test-correction-output-buttons-graphical-return ()
  "Graphical Return activates output buttons but leaves arguments inert."
  (dolist (kind '(ordinary compound child))
    (let ((chat (generate-new-buffer " *pilish-graphical-return*"))
          (pilish-tool-preview-lines 1))
      (unwind-protect
          (save-window-excursion
            (switch-to-buffer chat)
            (pilish-chat-mode)
            (if (eq kind 'child)
                (pilish-arguments-test--child "custom" '(:note "ARG-FIRST\nARG-LAST") "ONE\nTWO\nTHREE")
              (pilish-arguments-test--execute
               "r" (if (eq kind 'compound) "codemode" "custom")
               '(:code "1+1" :note "ARG-FIRST\nARG-LAST") "ONE\nTWO\nTHREE"))
            (let* ((overlay (car (pilish-arguments-test--all-tool-overlays)))
                   (block (pilish--tool-block-from-overlay overlay))
                   (section (pcase kind ('compound 'output) ('child '(child . "child")))))
              (dolist (key (list (kbd "<return>") (kbd "RET")))
                (goto-char (button-start (pilish--find-toggle-button-in-region (overlay-start overlay) (overlay-end overlay) section)))
                (execute-kbd-macro key)
                (should (eq (and (string-match-p "THREE" (pilish-arguments-test--visible-text)) t)
                            (equal key (kbd "<return>")))))
              (pilish-arguments-test--goto-text "note=")
              (let ((folds (copy-tree (pilish--tool-block-folds block))))
                (should-error (execute-kbd-macro (kbd "<return>")) :type 'user-error)
                (should (equal folds (pilish--tool-block-folds block))))))
        (when (buffer-live-p chat)
          (with-current-buffer chat (set-buffer-modified-p nil))
          (kill-buffer chat))))))

(ert-deftest pilish-test-correction-saved-button-graphical-return ()
  "Graphical Return opens the exact declared saved target."
  (let ((chat (generate-new-buffer " *pilish-saved-return*")))
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer chat)
          (pilish-chat-mode)
          (setq pilish--state '(:session-file "/tmp/pilish-return-anchor.jsonl"))
          (pilish-arguments-test--execute
           "saved" "custom" nil "OUT" nil
           '(:savedConversations
             (:version 1 :root "/tmp/pilish-return-saved/"
              :items [(:sessionId "child" :file "child.jsonl" :label "saved label")])))
          (pilish-arguments-test--goto-text "saved label")
          (let ((target (get-text-property (point) 'pilish-subagent-name)) opened)
            (should (pilish--snapshot-target-p target))
            (cl-letf (((symbol-function 'pilish-open-subagent-snapshot)
                       (lambda (value) (setq opened value))))
              (execute-kbd-macro (kbd "<return>"))
              (should (equal target opened)))))
      (when (buffer-live-p chat)
        (with-current-buffer chat (set-buffer-modified-p nil))
        (kill-buffer chat)))))

(ert-deftest pilish-test-r1-primary-parser-containment-through-collapse-and-cold ()
  "Contracted root and child primaries cannot consume following Markdown."
  (dolist (nested '(nil t))
    (dolist (first '("```" "~~~" "<!--"))
      (ert-info ((format "nested=%S first=%S" nested first))
        (pilish-arguments-test--with-chat
          (let* ((command (concat first "\n  echo SECOND '▸ ▾'"))
                 (args (list :command command)))
            (if nested (pilish-arguments-test--child "bash" args "CHILD-OUT")
              (pilish-arguments-test--execute "r" "bash" args "ROOT-OUT" t))
            (pilish--render-history-text
             "\nAFTER-PARAGRAPH **bold**.\n\n```elisp\n(message \"AFTER-CODE\")\n```")
            (dolist (stage '(contracted expanded collapsed cold))
              (pcase stage
                ((or 'expanded 'collapsed)
                 (pilish-arguments-test--goto-text "bash")
                 (cl-letf (((symbol-function 'message) #'ignore))
                   (pilish-toggle-tool-section)))
                ('cold
                 (pilish--cool-completed-tool-blocks (pilish-arguments-test--all-tool-overlays))))
              (pilish-arguments-test--assert-following-markdown)
              (let ((value (if (eq stage 'expanded) command (concat first "…"))))
                (should (string-match-p (regexp-quote (concat "bash\n" value "\n"))
                                        (pilish-arguments-test--visible-text)))
                (pilish-arguments-test--goto-text value)
                (let ((start (point)))
                  (dolist (pilish-copy-raw-markdown '(nil t))
                    (should (equal (pilish--filter-buffer-substring start (+ start (length value))) value)))))
              (when (eq stage 'cold)
                (should-not (pilish-arguments-test--all-tool-overlays))
                (should-not (text-property-not-all (point-min) (point-max) 'pilish-argument-locator nil))))))))))

(ert-deftest pilish-test-r1-complete-stacked-primary-parser-containment ()
  "A complete stacked primary needs literal guards even without a fold action."
  (dolist (nested '(nil t))
    (dolist (first '("```" "~~~" "<!--"))
      (pilish-arguments-test--with-chat
        (let* ((pilish--chat-display-width-override 24)
               (command (concat first (make-string (- 22 (length first)) ?x))))
          (if nested (pilish-arguments-test--child "bash" (list :command command) "CHILD")
            (pilish-arguments-test--execute "r" "bash" (list :command command) "ROOT" t))
          (pilish--render-history-text
           "\nAFTER-PARAGRAPH **bold**.\n\n```elisp\n(message \"AFTER-CODE\")\n```")
          (dolist (cold '(nil t))
            (when cold (pilish--cool-completed-tool-blocks (pilish-arguments-test--all-tool-overlays)))
            (pilish-arguments-test--assert-following-markdown)
            (should (string-match-p (regexp-quote (concat "bash\n" command "\n"))
                                    (pilish-arguments-test--visible-text)))
            (pilish-arguments-test--goto-text command)
            (should-not (get-text-property (point) 'pilish-argument-locator))
            (should-not (pilish-arguments-test--gutter (point)))))))))

(ert-deftest pilish-test-r1-known-short-primary-equal-text-hot-history-and-cold ()
  "Known short command and path titles retain exact visible and copied data."
  (dolist (history '(nil t))
    (dolist (tool '("bash" "read" "write" "edit"))
      (dolist (literal '("[launch](https://example.com) **bold**" "`literal`" "**literal**"))
        (ert-info ((format "history=%S tool=%S literal=%S" history tool literal))
          (pilish-arguments-test--with-chat
            (let* ((value (concat (if (equal tool "bash") "echo " "src/") literal))
                   (args (list (if (equal tool "bash") :command :path) value))
                   (heading (concat tool " " value)))
              (if history
                  (pilish--render-history-tool
                   (list :name tool :id "r" :arguments args)
                   '(:content [(:type "text" :text "OUT")]))
                (pilish-arguments-test--execute "r" tool args "OUT"))
              (pilish--render-history-text "\nA real [link](https://example.org).\n")
              (dolist (cold '(nil t))
                (when cold (pilish--cool-completed-tool-blocks (pilish-arguments-test--all-tool-overlays)))
                (font-lock-flush)
                (font-lock-ensure)
                (should (equal (car (split-string (pilish-arguments-test--visible-text) "\n")) heading))
                (dolist (pilish-copy-raw-markdown '(nil t))
                  (should (equal (pilish--filter-buffer-substring (point-min) (+ (point-min) (length heading))) heading)))
                (pilish-arguments-test--goto-text value)
                (dotimes (offset (length value))
                  (let ((position (+ (point) offset)))
                    (should (get-text-property position 'pilish-argument-literal))
                    (should (get-text-property position 'pilish-no-fontify))
                    (should-not (button-at position))
                    (should-not (invisible-p position))))
                (pilish-arguments-test--goto-text "link")
                (should (button-at (point)))))))))))

(ert-deftest pilish-test-r1-equal-text-installs-literal-properties-without-mutation ()
  "A previously fontified specialized header loses Markdown buttons in place."
  (pilish-arguments-test--with-chat
    (let* ((args '(:command "echo [launch](https://example.com) **bold**"))
           (block (pilish--display-tool-start "bash" args "r"))
           (overlay (pilish--tool-block-overlay block))
           (start (overlay-start overlay))
           (end (1- (marker-position (pilish--tool-block-header-end block))))
           (original (buffer-substring-no-properties start end))
           (inside (copy-marker (+ start 8)))
           (mutations 0)
           (hook (lambda (&rest _) (cl-incf mutations))))
      (font-lock-flush)
      (font-lock-ensure)
      (pilish-arguments-test--goto-text "launch")
      (should (button-at (point)))
      (let ((inhibit-read-only t))
        (put-text-property start end 'modification-hooks (list hook)))
      (pilish--argument-observe block nil "bash" args)
      (pilish--display-tool-update-header "bash" args block)
      (should (= mutations 0))
      (should (= (+ start 8) inside))
      (should (equal original (buffer-substring-no-properties start end)))
      (should (equal original (pilish--visible-text start end)))
      (pilish-arguments-test--goto-text "launch")
      (should (get-text-property (point) 'pilish-argument-literal))
      (should (get-text-property (point) 'pilish-no-fontify))
      (should (get-text-property (point) 'rear-nonsticky))
      (should-not (button-at (point)))
      (set-marker inside nil))))

(ert-deftest pilish-test-r1-clipped-keys-and-nested-keys-charge-the-marker ()
  "Root and nested clipped keys show an inert marker charged to the ledger."
  (dolist (unit '("k" "界" "\t"))
    (let* ((block (pilish--make-tool-block))
           (left (intern (concat ":" (apply #'concat (make-list 150 unit)) "-LEFT")))
           (right (intern (concat ":" (apply #'concat (make-list 150 unit)) "-RIGHT")))
           (args (list left 1 right 2 :nested (list left 3 right 4)))
           (rows (pilish--argument-observe block nil "custom" args))
           (view (pilish--tool-block-argument-view block))
           (text (mapconcat (lambda (row) (concat (pilish--argument-row-key row) (pilish--argument-row-text row))) rows ""))
           (charge (copy-sequence (pilish--argument-view-root-charge view))))
      (dolist (row (butlast rows))
        (let ((key (pilish--argument-row-key row)))
          (should (string-suffix-p "…" key))
          (should (<= (length key) pilish--argument-limit-key-chars))
          (should (<= (string-bytes key) pilish--argument-limit-key-chars))
          (should-not (string-match-p "LEFT\\|RIGHT" key))
          (should-not (pilish--argument-row-cut row))))
      (should (equal (pilish--argument-row-text (car (last rows)))
                     (concat "{" (pilish--argument-row-key (car rows)) "=3, "
                             (pilish--argument-row-key (cadr rows)) "=4}")))
      (should (pilish--argument-view-truncated-p view))
      (should (= (length text) (pilish--argument-view-chars view)))
      (should (= (string-bytes text) (pilish--argument-view-bytes view)))
      (pilish--argument-observe block nil "custom" args)
      (should (equal charge (pilish--argument-view-root-charge view))))))

(ert-deftest pilish-test-r1-key-marker-under-shared-budget-exhaustion ()
  "A clipped key fits its marker or yields the existing inert omission row."
  (dolist (characters '(1 2 3 4 5 8))
    (dolist (bytes '(3 4 5 6 8 11))
      (let* ((view (pilish--make-argument-view
                    :chars (- pilish--argument-limit-block-chars characters)
                    :bytes (- pilish--argument-limit-block-bytes bytes)))
             (block (pilish--make-tool-block :argument-view view))
             (rows (pilish--argument-observe block nil "custom"
                                             (list (intern (concat ":" (make-string 200 ?k))) 1))))
        (dolist (row rows)
          (if (eq (pilish--argument-row-role row) 'omission)
              (should (equal (pilish--argument-row-text row) "…"))
            (should (string-suffix-p "…" (pilish--argument-row-key row)))))
        (should (<= (pilish--argument-view-chars view) pilish--argument-limit-block-chars))
        (should (<= (pilish--argument-view-bytes view) pilish--argument-limit-block-bytes))
        (should (pilish--argument-view-truncated-p view))))))

(ert-deftest pilish-test-r1-complete-key-literal-ellipsis-is-not-clipping ()
  "An exactly fitting key, including a literal ellipsis, remains complete."
  (dolist (key (list (make-string 128 ?k) (concat (make-string 125 ?k) "…")))
    (let* ((result (pilish-test--argument-rows "custom" (list (intern (concat ":" key)) 1)))
           (row (caar result)))
      (should (equal key (pilish--argument-row-key row)))
      (should-not (pilish--argument-row-cut row))
      (should-not (pilish--argument-view-truncated-p (cdr result))))))

(ert-deftest pilish-test-r1-clipped-key-does-not-promise-full-key-expansion ()
  "Only the value expands; an unavailable key suffix never appears."
  (dolist (nested '(nil t))
    (pilish-arguments-test--with-chat
      (let* ((key (intern (concat ":" (make-string 200 ?k) "-UNAVAILABLE-KEY-SUFFIX")))
             (args (list key "FIRST\nSECOND"))
             (spelling (concat (make-string 125 ?k) "…")))
        (if nested (pilish-arguments-test--child "custom" args "CHILD")
          (pilish-arguments-test--execute "r" "custom" args "ROOT"))
        (dolist (stage '(contracted expanded cold))
          (pcase stage
            ('expanded
             (pilish-arguments-test--goto-text "custom")
             (pilish-toggle-tool-section))
            ('cold (pilish--cool-completed-tool-blocks (pilish-arguments-test--all-tool-overlays))))
          (font-lock-flush)
          (font-lock-ensure)
          (let ((visible (pilish-arguments-test--visible-text)))
            (should (string-match-p (regexp-quote (concat spelling "=")) visible))
            (should-not (string-match-p "UNAVAILABLE-KEY-SUFFIX" visible))
            (when (memq stage '(expanded cold))
              (should (string-match-p (regexp-quote (concat spelling "=FIRST\nSECOND")) visible)))))))))

(ert-deftest pilish-test-r1-keyless-observer-fallback-is-not-inline ()
  "The visitor's unnamed fallback uses a row instead of a fabricated name."
  (dolist (value '([] "bare" 7))
    (pilish-arguments-test--with-chat
      (let* ((block (pilish--display-tool-start "custom" nil "r"))
             (rows (pilish--argument-observe block nil "custom" value)))
        (should-not (pilish--argument-inline-eligible-p rows))
        (pilish--display-tool-update-header "custom" nil block)
        (should (equal (pilish-arguments-test--visible-text)
                       (concat "custom\n=" (if (vectorp value) "[]" (format "%s" value)) "\n")))))))

(provide 'pilish-arguments-test)
;;; pilish-arguments-test.el ends here
