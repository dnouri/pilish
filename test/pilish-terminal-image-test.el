;;; pilish-terminal-image-test.el --- Tests for terminal images -*- lexical-binding: t; -*-

;;; Commentary:

;; Terminal image logic without a terminal.  The real path through Ghostty
;; needs a display and is covered by the verification feature map.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'pilish-test-common)
(require 'pilish-terminal-image)

(defconst pilish-test--terminal-png
  (base64-decode-string
   "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0eNT6AAAADklEQVR4nGP4z8DwHwAFAAH/yVgdOQAAAABJRU5ErkJggg==")
  "A two-by-one PNG.")

(defmacro pilish-test--with-terminal-images (&rest body)
  "Run BODY with fresh terminal image caches and conversions."
  (declare (indent 0) (debug t))
  `(let ((pilish--terminal-images (make-hash-table :test 'eq :weakness 'key))
         (pilish--terminal-image-conversions nil)
         (pilish--terminal-image-queue nil))
     (unwind-protect (progn ,@body)
       (pilish--terminal-image-cancel-conversions))))

(defmacro pilish-test--with-terminal-window (&rest body)
  "Run BODY in a chat where the selected window counts as a capable terminal.
SENT holds the strings written to the terminal, newest first."
  (declare (indent 0) (debug t))
  `(let (sent (inhibit-read-only t) (pilish-terminal-image-mode t))
     (pilish-test--with-terminal-images
       (with-temp-buffer
         (pilish-chat-mode)
         (cl-letf (((symbol-function 'pilish--terminal-image-frame-p) (lambda (_) t))
                   ((symbol-function 'pilish--terminal-image-windows)
                    (lambda () (list (selected-window))))
                   ((symbol-function 'window-body-width) (lambda (&rest _) 80))
                   ((symbol-function 'window-body-height) (lambda (&rest _) 24))
                   ((symbol-function 'send-string-to-terminal)
                    (lambda (string &rest _) (push string sent)))
                   ((symbol-function 'terminal-parameter)
                    (let ((table (make-hash-table :test 'equal)))
                      (lambda (&rest _) table)))
                   ((symbol-function 'pilish--terminal-image-range)
                    (lambda (_) (cons (point-min) (point-max)))))
           ,@body)))))

(defun pilish-test--terminal-image-overlay-id (&optional buffer)
  "Return the image id of the only terminal image overlay in BUFFER."
  (let ((overlays (buffer-local-value 'pilish--terminal-image-overlays
                                      (or buffer (current-buffer)))))
    (should (= 1 (length overlays)))
    (car (overlay-get (car overlays) 'pilish-terminal-image))))

(defun pilish-test--await-terminal-image-conversions ()
  "Wait until no image conversion is queued or running."
  (let ((deadline (+ (float-time) 10)))
    (while (and (or pilish--terminal-image-conversions
                    pilish--terminal-image-queue)
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (should-not pilish--terminal-image-conversions)
    (should-not pilish--terminal-image-queue)))

(defun pilish-test--fake-converter (script)
  "Return an executable shell SCRIPT standing in for ImageMagick."
  (let ((file (make-temp-file "pilish-fake-magick-" nil ".sh"
                              (concat "#!/bin/sh\n" script "\n"))))
    (set-file-modes file #o700)
    file))

(defconst pilish-test--terminal-jpeg
  (base64-decode-string
   (concat
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkK"
    "DA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/2wBDAQMDAwQDBAgEBAgQCwkLEBAQEBAQEBAQEBAQ"
    "EBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBD/wAARCAACAAQDAREAAhEBAxEB/8QA"
    "FAABAAAAAAAAAAAAAAAAAAAACP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/xAAVAQEBAAAAAAAAAAAAAAAA"
    "AAAHCf/EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAMAwEAAhEDEQA/ADoDFU3/2Q=="))
  "A four-by-two JPEG.")

(defun pilish-test--insert-terminal-preview ()
  "Insert an image preview for the test PNG at point."
  (insert (pilish--image-preview-string
           "Image: image/png, 71 B"
           (list 'image :type 'png :data pilish-test--terminal-png))
          "\n"))

(ert-deftest pilish-test-terminal-image-frame-needs-type-and-truecolor ()
  "Only exact terminal types with 24-bit color qualify."
  (let ((frame (selected-frame)) (type "xterm-ghostty") (cells 16777216)
        (pilish-terminal-image-mode t))
    (cl-letf (((symbol-function 'framep) (lambda (_) t))
              ((symbol-function 'frame-parameter) (lambda (&rest _) type))
              ((symbol-function 'display-color-cells) (lambda (&rest _) cells)))
      (dolist (good '("xterm-ghostty" "xterm-ghostty-truecolor" "xterm-kitty"))
        (setq type good)
        (should (pilish--terminal-image-frame-p frame)))
      ;; mosh, tmux and unknown terminals keep the label.
      (dolist (bad '("xterm-256color" "tmux-256color" "xterm-ghostty2" nil))
        (setq type bad)
        (should-not (pilish--terminal-image-frame-p frame)))
      (setq type "xterm-ghostty" cells 256)
      (should-not (pilish--terminal-image-frame-p frame))
      (setq cells 16777216)
      (let ((pilish-terminal-image-types nil))
        (should-not (pilish--terminal-image-frame-p frame)))
      (let ((pilish-terminal-image-mode nil))
        (should-not (pilish--terminal-image-frame-p frame))))))

(ert-deftest pilish-test-terminal-image-png-size ()
  "PNG dimensions come from the header; short data has none."
  (should (equal '(2 . 1) (pilish--terminal-image-png-size pilish-test--terminal-png)))
  (should-not (pilish--terminal-image-png-size "short"))
  (should-not (pilish--terminal-image-png-size (make-string 24 ?x))))

(ert-deftest pilish-test-terminal-image-sequences-chunk-and-silence ()
  "Sequences keep the size limit, and every chunk suppresses replies."
  (let* ((png (make-string 10000 ?a))
         (sequences (pilish--terminal-image-sequences 7 png))
         (chunks (split-string sequences "\e\\\\" t)))
    (should (> (length chunks) 1))
    (should (string-prefix-p "\e_Ga=t,f=100,i=7,q=2,m=1;" (car chunks)))
    (should (string-prefix-p "\e_Gq=2,m=0;" (car (last chunks))))
    (dolist (chunk chunks)
      (should (string-match-p "q=2" chunk))
      (should (<= (length (cadr (split-string chunk ";")))
                  pilish--terminal-image-chunk-size)))
    (should (equal (base64-encode-string png t)
                   (mapconcat (lambda (chunk) (cadr (split-string chunk ";")))
                              chunks "")))))

(ert-deftest pilish-test-terminal-image-grid-uses-composed-cells ()
  "Grid cells carry row and column marks as compositions, and the id as color."
  (let* ((grid (pilish--terminal-image-grid #x000102 '(2 . 2)))
         (lines (split-string grid "\n")))
    (should (= 2 (length lines)))
    (should (= (string-to-char (substring grid 0 1))
               pilish--terminal-image-placeholder))
    (should (equal (substring-no-properties grid 0 4)
                   (string #x10EEEE #x0305 #x0305 #x0305)))
    ;; Without a composition Emacs gives each mark a column of its own.
    (should (get-text-property 0 'composition grid))
    (should (equal "#000102" (plist-get (get-text-property 0 'face grid) :foreground)))
    ;; The id's high byte is the third mark of every cell.
    (let ((high (pilish--terminal-image-grid #x05000102 '(2 . 1))))
      (should (equal (substring-no-properties high 4 8)
                     (string #x10EEEE #x0305 #x030D #x033D)))
      (should (equal "#000102"
                     (plist-get (get-text-property 0 'face high) :foreground))))))

(ert-deftest pilish-test-terminal-image-size-keeps-shape-within-windows ()
  "Size follows the image and shrinks to the window and configured width."
  (let ((pilish-image-preview-max-width 900))
    (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 100))
              ((symbol-function 'window-body-height) (lambda (&rest _) 40)))
      (cl-flet ((size (width height)
                  (pilish--terminal-image-size
                   (pilish--timage-create 1 "" width height) '(window))))
        ;; An icon stays small.
        (should (equal '(2 . 1) (size 16 16)))
        ;; Width follows the window until the height limit shapes the box.
        (should (equal '(98 . 10) (size 2000 400)))
        (should (equal '(80 . 20) (size 2000 1000)))
        ;; A tall image is limited to half the window height.
        (should (equal '(20 . 20) (size 1000 2000)))))))

(ert-deftest pilish-test-terminal-image-update-overlays-only-the-window ()
  "A preview gets a window-scoped overlay and keeps its image for GUI frames."
  (pilish-test--with-terminal-window
    (pilish-test--insert-terminal-preview)
    (pilish--terminal-image-update)
    (should (= 1 (length pilish--terminal-image-overlays)))
    (let ((overlay (car pilish--terminal-image-overlays)))
      (should (eq (selected-window) (overlay-get overlay 'window)))
      (should (string-prefix-p (string pilish--terminal-image-placeholder)
                               (overlay-get overlay 'display))))
    (should (eq 'image (car (get-text-property (point-min) 'display))))))

(ert-deftest pilish-test-terminal-image-overlay-takes-in-closing-fence ()
  "The overlay covers a hidden fence, which would otherwise trap upward motion."
  (pilish-test--with-terminal-window
    (insert "```text\nRead image file\n```\n")
    (let ((fence (line-beginning-position 0)))
      (pilish-test--insert-terminal-preview)
      (pilish--terminal-image-update)
      (should (= fence (overlay-start (car pilish--terminal-image-overlays))))
      (pilish--terminal-image-update)
      (should (= 1 (length pilish--terminal-image-overlays))))))

(ert-deftest pilish-test-terminal-image-update-sends-once-per-terminal ()
  "Repeated updates reuse the terminal's copy and the overlay."
  (pilish-test--with-terminal-window
    (pilish-test--insert-terminal-preview)
    (pilish--terminal-image-update)
    (let ((overlay (car pilish--terminal-image-overlays)))
      (should (= 2 (length sent)))
      (pilish--terminal-image-update)
      (should (= 2 (length sent)))
      (should (equal (list overlay) pilish--terminal-image-overlays)))))

(ert-deftest pilish-test-terminal-image-update-stores-new-size-and-deletes-old ()
  "A new size is stored under a new id; the unused old id is deleted."
  (pilish-test--with-terminal-window
    (let ((image (list 'image :type 'png :data (make-string 40 ?x))))
      (cl-letf (((symbol-function 'pilish--terminal-image-for-spec)
                 (lambda (_) (pilish--timage-create "hash" "png" 800 400)))
                ((symbol-function 'window-body-width) (lambda (&rest _) 40)))
        (insert (pilish--image-preview-string "Image" image) "\n")
        (pilish--terminal-image-update)
        (should (= 2 (length sent)))
        (let ((old (pilish-test--terminal-image-overlay-id)))
          (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 30)))
            (pilish--terminal-image-update))
          (should (= 5 (length sent)))
          (should-not (= old (pilish-test--terminal-image-overlay-id)))
          (should (string-match-p "c=28" (nth 1 sent)))
          (should (equal (pilish--terminal-image-deletion old) (car sent))))))))

(ert-deftest pilish-test-terminal-image-chats-keep-their-own-sizes ()
  "The same image in differently sized chats gets one placement per size.
The id of a size stays stored while any chat still shows it."
  (pilish-test--with-terminal-window
    (let ((width 40) first-id second-id)
      (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) width))
                ((symbol-function 'pilish--terminal-image-for-spec)
                 (lambda (_) (pilish--timage-create "hash" "png" 800 400))))
        (pilish-test--insert-terminal-preview)
        (let ((first (current-buffer)))
          (pilish--terminal-image-update)
          (setq first-id (pilish-test--terminal-image-overlay-id))
          (with-temp-buffer
            (pilish-chat-mode)
            (pilish-test--insert-terminal-preview)
            (setq width 30)
            (pilish--terminal-image-update)
            (setq second-id (pilish-test--terminal-image-overlay-id))
            (should-not (= first-id second-id))
            (should (= 4 (length sent)))
            (should (member (pilish--terminal-image-placement first-id '(38 . 10)) sent))
            (should (member (pilish--terminal-image-placement second-id '(28 . 7)) sent))
            (should (= first-id (pilish-test--terminal-image-overlay-id first))))
          ;; The second chat is gone; its size's id is deleted with the next update.
          (setq width 40)
          (pilish--terminal-image-update)
          (should (equal (pilish--terminal-image-deletion second-id) (car sent)))
          (should (= 5 (length sent))))))))

(ert-deftest pilish-test-terminal-image-unsupported-keeps-label ()
  "An image without a PNG form stays the text label."
  (pilish-test--with-terminal-window
    (cl-letf (((symbol-function 'pilish--terminal-image-converter) #'ignore))
      (insert (pilish--image-preview-string
               "Image: image/jpeg"
               (list 'image :type 'jpeg :data (make-string 40 ?j)))
              "\n")
      (pilish--terminal-image-update)
      (should-not pilish--terminal-image-overlays)
      (should-not sent))))

(ert-deftest pilish-test-terminal-image-svg-never-reaches-converter ()
  "SVG stays out of ImageMagick, which could follow its references."
  (pilish-test--with-terminal-images
    (cl-letf (((symbol-function 'pilish--terminal-image-converter)
               (lambda () (ert-fail "Converter consulted for SVG")))
              ((symbol-function 'make-process)
               (lambda (&rest _) (ert-fail "Process started for SVG"))))
      (should-not (pilish--terminal-image-for-spec
                   (list 'image :type 'svg :data "<svg/>")))
      (should-not pilish--terminal-image-queue))))

(ert-deftest pilish-test-terminal-image-converts-jpeg-in-background ()
  "JPEG becomes PNG in the background, without temporary files left behind."
  (skip-unless (pilish--terminal-image-converter))
  (pilish-test--with-terminal-images
    (let ((spec (list 'image :type 'jpeg :data pilish-test--terminal-jpeg))
          file)
      (should-not (pilish--terminal-image-for-spec spec))
      (should (= 1 (length pilish--terminal-image-conversions)))
      (setq file (process-get (car pilish--terminal-image-conversions) 'pilish-file))
      (should (file-exists-p file))
      (pilish-test--await-terminal-image-conversions)
      (let ((image (pilish--terminal-image-for-spec spec)))
        (should (pilish--timage-p image))
        (should (= 4 (pilish--timage-width image)))
        (should (= 2 (pilish--timage-height image))))
      (should-not (file-exists-p file))
      (should-not (seq-find (lambda (buffer)
                              (string-prefix-p " *pilish-terminal-image"
                                               (buffer-name buffer)))
                            (buffer-list))))))

(ert-deftest pilish-test-terminal-image-failed-conversions-keep-label ()
  "Failing, slow and oversized conversions end as unsupported and clean up."
  (pilish-test--with-terminal-images
    (let ((pilish--terminal-image-conversion-timeout 0.3)
          (pilish--terminal-image-conversion-max-bytes 1000)
          (scripts (list (pilish-test--fake-converter "exit 1")
                         (pilish-test--fake-converter "exec sleep 30")
                         (pilish-test--fake-converter
                          "exec head -c 100000 /dev/zero"))))
      (unwind-protect
          (dolist (script scripts)
            (cl-letf (((symbol-function 'pilish--terminal-image-converter)
                       (lambda () script)))
              (let ((spec (list 'image :type 'gif :data (copy-sequence "GIF89a")))
                    process)
                (should-not (pilish--terminal-image-for-spec spec))
                (setq process (car pilish--terminal-image-conversions))
                (pilish-test--await-terminal-image-conversions)
                (should-not (process-live-p process))
                (should-not (file-exists-p (process-get process 'pilish-file)))
                (should (eq 'unsupported
                            (gethash (plist-get (cdr spec) :data)
                                     pilish--terminal-images))))))
        (mapc #'delete-file scripts)))))

(ert-deftest pilish-test-terminal-image-conversions-wait-for-slots-and-cancel ()
  "Conversions run a few at a time; disabling the mode stops all of them."
  (pilish-test--with-terminal-images
    (let ((pilish--terminal-image-conversion-slots 1)
          (pilish-terminal-image-mode t)
          (script (pilish-test--fake-converter "exec sleep 30"))
          (first (list 'image :type 'jpeg :data (copy-sequence "one")))
          (second (list 'image :type 'webp :data (copy-sequence "two"))))
      (unwind-protect
          (cl-letf (((symbol-function 'pilish--terminal-image-converter)
                     (lambda () script))
                    ((symbol-function 'pilish--terminal-image-collect) #'ignore))
            (should-not (pilish--terminal-image-for-spec first))
            (should-not (pilish--terminal-image-for-spec second))
            (should-not (pilish--terminal-image-for-spec second))
            (should (= 1 (length pilish--terminal-image-conversions)))
            (should (equal (list (cons (plist-get (cdr second) :data) 'webp))
                           pilish--terminal-image-queue))
            (let* ((process (car pilish--terminal-image-conversions))
                   (file (process-get process 'pilish-file)))
              (pilish-terminal-image-mode -1)
              (should-not (process-live-p process))
              (should-not (file-exists-p file))
              (should-not pilish--terminal-image-conversions)
              (should-not pilish--terminal-image-queue)
              (should (= 0 (hash-table-count pilish--terminal-images)))))
        (delete-file script)))))

(ert-deftest pilish-test-terminal-image-update-drops-overlays-of-gone-windows ()
  "Overlays of windows no longer showing the chat are removed."
  (pilish-test--with-terminal-window
    (pilish-test--insert-terminal-preview)
    (pilish--terminal-image-update)
    (let ((overlay (car pilish--terminal-image-overlays)))
      (cl-letf (((symbol-function 'pilish--terminal-image-windows) #'ignore))
        (pilish--terminal-image-update))
      (should-not pilish--terminal-image-overlays)
      (should-not (overlay-buffer overlay)))))

(ert-deftest pilish-test-terminal-image-preview-insertion-schedules-update ()
  "Inserting a preview while a terminal window shows the chat updates it."
  (pilish-test--with-terminal-window
    (let (scheduled)
      (pilish--terminal-image-update)
      (cl-letf (((symbol-function 'pilish--terminal-image-schedule)
                 (lambda () (setq scheduled t))))
        (insert "ordinary text")
        (should-not scheduled)
        (pilish-test--insert-terminal-preview)
        (should scheduled)))))

(ert-deftest pilish-test-terminal-image-graphical-windows-schedule-nothing ()
  "Windows without capable terminals cost no updates."
  (with-temp-buffer
    (pilish-chat-mode)
    (cl-letf (((symbol-function 'pilish--terminal-image-frame-p) #'ignore))
      (pilish--terminal-image-window-changed (selected-window))
      (should-not pilish--terminal-image-timer))))

(ert-deftest pilish-test-terminal-image-mode-disable-cleans-up ()
  "Disabling the global mode restores image specs and cancels pending work."
  (pilish-test--with-terminal-window
    (pilish-test--insert-terminal-preview)
    (pilish--terminal-image-update)
    (pilish--terminal-image-schedule)
    (let ((timer pilish--terminal-image-timer)
          (overlay (car pilish--terminal-image-overlays)))
      (pilish-terminal-image-mode -1)
      (should-not (memq timer timer-list))
      (should-not (overlay-buffer overlay))
      (should-not pilish--terminal-image-timer)
      (should-not (memq #'pilish--terminal-image-after-change after-change-functions))
      (should (eq 'image (car (get-text-property (point-min) 'display)))))))

(ert-deftest pilish-test-terminal-image-send-failure-keeps-label-and-retries ()
  "A failed write installs no overlay or successful placement entry."
  (pilish-test--with-terminal-window
    (pilish-test--insert-terminal-preview)
    (cl-letf (((symbol-function 'send-string-to-terminal)
               (lambda (&rest _) (error "Terminal disconnected"))))
      (pilish--terminal-image-refresh (current-buffer)))
    (should-not pilish--terminal-image-overlays)
    (pilish--terminal-image-update)
    (should (= 2 (length sent)))
    (should (= 1 (length pilish--terminal-image-overlays)))))

(ert-deftest pilish-test-terminal-image-separate-terminal-transmissions ()
  "New terminal objects get their own image and placement transmissions."
  (let ((tables (make-hash-table)) sent
        (image (pilish--timage-create "hash" "png" 100 50)))
    (cl-letf (((symbol-function 'frame-terminal) #'identity)
              ((symbol-function 'terminal-parameter)
               (lambda (terminal _key) (gethash terminal tables)))
              ((symbol-function 'set-terminal-parameter)
               (lambda (terminal _key value) (puthash terminal value tables)))
              ((symbol-function 'send-string-to-terminal)
               (lambda (_text terminal) (push terminal sent))))
      (pilish--terminal-image-send image '(20 . 5) 'first)
      (pilish--terminal-image-send image '(20 . 5) 'first)
      (pilish--terminal-image-send image '(20 . 5) 'second)
      (should (equal '(second second first first) sent)))))

(ert-deftest pilish-test-terminal-image-saved-transcript-tracks-windows ()
  "Saved conversations inherit the same opt-in terminal display as chats."
  (let ((pilish-terminal-image-mode t))
    (with-temp-buffer
      (pilish-snapshot-mode)
      (should (memq #'pilish--terminal-image-window-changed
                    window-buffer-change-functions))
      (should (memq #'pilish--terminal-image-cleanup kill-buffer-hook)))))

(ert-deftest pilish-test-terminal-image-ids-are-random-and-unused ()
  "Ids are random 32-bit numbers with a usable colour, unused on the terminal."
  (let ((table (make-hash-table :test 'equal))
        (draws (list 0 0 0 1 255 (1- #xFFFFFE))))
    (puthash '("taken" (1 . 1)) 1 table)
    (cl-letf (((symbol-function 'random) (lambda (_) (pop draws))))
      ;; 1 is taken, so the next draw decides.
      (should (= 2 (pilish--terminal-image-new-id table)))
      (should (= #xFFFFFFFE (pilish--terminal-image-new-id table)))))
  (let ((table (make-hash-table :test 'equal)))
    (dotimes (_ 200)
      (let ((id (pilish--terminal-image-new-id table)))
        (should (< 0 (logand id #xFFFFFF) #xFFFFFF))
        (should (< id (ash 1 32)))
        (puthash (list id) id table)))
    (should (= 200 (length (delete-dups (hash-table-values table)))))))

(provide 'pilish-terminal-image-test)
;;; pilish-terminal-image-test.el ends here
