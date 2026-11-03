;;; pilish-terminal-image.el --- Inline images on capable text terminals -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026 Daniel Nouri

;; Author: Daniel Nouri <daniel.nouri@gmail.com>
;; Maintainer: Daniel Nouri <daniel.nouri@gmail.com>
;; URL: https://github.com/dnouri/pilish

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Emacs cannot draw images on text terminals, so an image preview there
;; shows its text label.  Terminals with the Kitty graphics protocol can
;; paint a stored image over Unicode placeholder cells.  A cell is U+10EEEE
;; plus row, column and id diacritics, and its foreground color carries the
;; low 24 bits of the image id.  Those cells are ordinary text to Emacs, so
;; scrolling, clipping and window splits need no extra work.  Each cell
;; must be a static composition: Emacs otherwise gives the diacritics
;; columns of their own.
;;
;; The label's `display' property stays the image spec for graphical
;; frames.  A `display' condition cannot tell which frame is being drawn,
;; because it sees the selected frame, so each capable terminal window
;; gets its own overlay, scoped by the `window' property.
;;
;; A placement has one size, so every size of an image on a terminal is
;; stored under its own id.  Windows of different sizes, also in different
;; chats, then never resize each other's images.  Ids are random 32-bit
;; numbers because a terminal's image store is shared with other programs
;; and outlives this Emacs; an image no window on a terminal shows any
;; more is deleted from it.
;;
;; Previews are handled only near the visible part of a window: images
;; reach the terminal through a blocking write, which a long chat of
;; screenshots must not impose on the whole Emacs session.  Formats other
;; than PNG are converted by ImageMagick in the background, a few at a
;; time, with bounded time, memory and output.
;;
;; `pilish-terminal-image-mode' is opt-in.  Only exact Kitty-capable
;; terminal types qualify, which also leaves
;; `mosh', `tmux' and similar intermediaries with the label: they do not
;; pass the protocol through and do not report these types.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'pilish-ui)

(defcustom pilish-terminal-image-types
  "\\`xterm-\\(?:ghostty\\|kitty\\)\\(?:-\\|\\'\\)"
  "Regexp of `tty-type' values whose terminals show inline images.
These terminals must support Unicode placeholders of the Kitty graphics
protocol.  A frame also needs 24-bit color, because the foreground color
carries the image id.  nil keeps the text label on all terminals."
  :type '(choice (const :tag "Disabled" nil) regexp)
  :group 'pilish)

(defconst pilish--terminal-image-placeholder #x10EEEE
  "The Kitty graphics protocol's Unicode placeholder character.")

(defconst pilish--terminal-image-diacritics
  [#x0305 #x030D #x030E #x0310 #x0312 #x033D #x033E #x033F #x0346
  #x034A #x034B #x034C #x0350 #x0351 #x0352 #x0357 #x035B #x0363
  #x0364 #x0365 #x0366 #x0367 #x0368 #x0369 #x036A #x036B #x036C
  #x036D #x036E #x036F #x0483 #x0484 #x0485 #x0486 #x0487 #x0592
  #x0593 #x0594 #x0595 #x0597 #x0598 #x0599 #x059C #x059D #x059E
  #x059F #x05A0 #x05A1 #x05A8 #x05A9 #x05AB #x05AC #x05AF #x05C4
  #x0610 #x0611 #x0612 #x0613 #x0614 #x0615 #x0616 #x0617 #x0657
  #x0658 #x0659 #x065A #x065B #x065D #x065E #x06D6 #x06D7 #x06D8
  #x06D9 #x06DA #x06DB #x06DC #x06DF #x06E0 #x06E1 #x06E2 #x06E4
  #x06E7 #x06E8 #x06EB #x06EC #x0730 #x0732 #x0733 #x0735 #x0736
  #x073A #x073D #x073F #x0740 #x0741 #x0743 #x0745 #x0747 #x0749
  #x074A #x07EB #x07EC #x07ED #x07EE #x07EF #x07F0 #x07F1 #x07F3
  #x0816 #x0817 #x0818 #x0819 #x081B #x081C #x081D #x081E #x081F
  #x0820 #x0821 #x0822 #x0823 #x0825 #x0826 #x0827 #x0829 #x082A
  #x082B #x082C #x082D #x0951 #x0953 #x0954 #x0F82 #x0F83 #x0F86
  #x0F87 #x135D #x135E #x135F #x17DD #x193A #x1A17 #x1A75 #x1A76
  #x1A77 #x1A78 #x1A79 #x1A7A #x1A7B #x1A7C #x1B6B #x1B6D #x1B6E
  #x1B6F #x1B70 #x1B71 #x1B72 #x1B73 #x1CD0 #x1CD1 #x1CD2 #x1CDA
  #x1CDB #x1CE0 #x1DC0 #x1DC1 #x1DC3 #x1DC4 #x1DC5 #x1DC6 #x1DC7
  #x1DC8 #x1DC9 #x1DCB #x1DCC #x1DD1 #x1DD2 #x1DD3 #x1DD4 #x1DD5
  #x1DD6 #x1DD7 #x1DD8 #x1DD9 #x1DDA #x1DDB #x1DDC #x1DDD #x1DDE
  #x1DDF #x1DE0 #x1DE1 #x1DE2 #x1DE3 #x1DE4 #x1DE5 #x1DE6 #x1DFE
  #x20D0 #x20D1 #x20D4 #x20D5 #x20D6 #x20D7 #x20DB #x20DC #x20E1
  #x20E7 #x20E9 #x20F0 #x2CEF #x2CF0 #x2CF1 #x2DE0 #x2DE1 #x2DE2
  #x2DE3 #x2DE4 #x2DE5 #x2DE6 #x2DE7 #x2DE8 #x2DE9 #x2DEA #x2DEB
  #x2DEC #x2DED #x2DEE #x2DEF #x2DF0 #x2DF1 #x2DF2 #x2DF3 #x2DF4
  #x2DF5 #x2DF6 #x2DF7 #x2DF8 #x2DF9 #x2DFA #x2DFB #x2DFC #x2DFD
  #x2DFE #x2DFF #xA66F #xA67C #xA67D #xA6F0 #xA6F1 #xA8E0 #xA8E1
  #xA8E2 #xA8E3 #xA8E4 #xA8E5 #xA8E6 #xA8E7 #xA8E8 #xA8E9 #xA8EA
  #xA8EB #xA8EC #xA8ED #xA8EE #xA8EF #xA8F0 #xA8F1 #xAAB0 #xAAB2
  #xAAB3 #xAAB7 #xAAB8 #xAABE #xAABF #xAAC1 #xFE20 #xFE21 #xFE22
  #xFE23 #xFE24 #xFE25 #xFE26 #x10A0F #x10A38 #x1D185 #x1D186 #x1D187
  #x1D188 #x1D189 #x1D1AA #x1D1AB #x1D1AC #x1D1AD #x1D242 #x1D243 #x1D244]
  "Combining marks numbering placeholder rows and columns, in protocol order.")

(defconst pilish--terminal-image-chunk-size 4096
  "Largest base64 payload of one Kitty graphics escape sequence.")

(defconst pilish--terminal-image-cell-width 8
  "Nominal cell width in pixels, for scaling images to columns.
Terminals fit an image inside its placement, so this only sets how many
columns an image of a given size may use.")

(defconst pilish--terminal-image-margin 20000
  "Characters around a window's visible text in which to prepare previews.")

(defconst pilish--terminal-image-delay 0.05
  "Seconds to gather changes before updating terminal images.")

(defvar pilish--terminal-image-conversion-timeout 10
  "Seconds after which an image conversion is stopped and fails.")

(defvar pilish--terminal-image-conversion-max-bytes (* 16 1024 1024)
  "Largest PNG output accepted from one image conversion.")

(defvar pilish--terminal-image-conversion-slots 2
  "Number of image conversions that may run at the same time.")

(defconst pilish--terminal-image-conversion-limits
  '("-limit" "memory" "256MiB" "-limit" "map" "512MiB"
    "-limit" "disk" "1GiB")
  "ImageMagick resource limits for converting agent-supplied images.")

(defconst pilish--terminal-image-conversion-geometry "2048x2048>"
  "ImageMagick geometry that shrinks converted images to this bound.")

(cl-defstruct (pilish--timage
               (:constructor pilish--timage-create (hash png width height)))
  "An image as sent to terminals: its PNG bytes, their hash and pixel size."
  hash png width height)

(defvar pilish--terminal-images (make-hash-table :test 'eq :weakness 'key)
  "Map image spec data to its `pilish--timage', `pending' or `unsupported'.")

(defvar pilish--terminal-image-conversions nil
  "Running image conversion processes.")

(defvar pilish--terminal-image-queue nil
  "Image conversions waiting for a slot, as (DATA . TYPE), oldest first.")

(defvar-local pilish--terminal-image-overlays nil
  "Overlays showing placeholder cells in this chat.")

(defvar-local pilish--terminal-image-timer nil
  "Pending update of this chat's terminal images.")

;;;###autoload
(define-minor-mode pilish-terminal-image-mode
  "Show inline image previews in Kitty and Ghostty text terminals.
This global mode is disabled by default.  PNG needs no external program;
JPEG, GIF and WebP need ImageMagick.  Unsupported images keep their label.
Graphical windows retain Emacs's normal image display."
  :global t :group 'pilish
  (unless pilish-terminal-image-mode
    (pilish--terminal-image-cancel-conversions))
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'pilish-transcript-mode)
        (if pilish-terminal-image-mode
            (progn (pilish--terminal-image-setup)
                   (pilish--terminal-image-schedule))
          (pilish--terminal-image-cleanup)))))
  (unless pilish-terminal-image-mode
    (condition-case err
        (pilish--terminal-image-collect)
      (error
       (message "Pi: Deleting terminal images failed: %s"
                (error-message-string err))))))

(defun pilish--terminal-image-frame-p (frame)
  "Return non-nil when FRAME's terminal can show placeholder images."
  (and pilish-terminal-image-mode
       pilish-terminal-image-types
       (eq (framep frame) t)
       (stringp (frame-parameter frame 'tty-type))
       (string-match-p pilish-terminal-image-types
                       (frame-parameter frame 'tty-type))
       (>= (display-color-cells frame) 16777216)))

(defun pilish--terminal-image-png-size (png)
  "Return the (WIDTH . HEIGHT) in pixels of PNG bytes, or nil."
  (when (and (>= (length png) 24)
             (string-prefix-p (unibyte-string 137 80 78 71 13 10 26 10) png)
             (equal (substring png 12 16) "IHDR"))
    (cl-flet ((read-u32 (offset)
                (seq-reduce (lambda (value byte) (+ (* value 256) byte))
                            (substring png offset (+ offset 4)) 0)))
      (let ((width (read-u32 16)) (height (read-u32 20)))
        (when (and (> width 0) (> height 0))
          (cons width height))))))

(defun pilish--terminal-image-from-png (png)
  "Return the `pilish--timage' of PNG bytes, or `unsupported'."
  (if-let* ((size (pilish--terminal-image-png-size png)))
      (pilish--timage-create (secure-hash 'sha1 png) png (car size) (cdr size))
    'unsupported))

(defun pilish--terminal-image-for-spec (spec)
  "Return the `pilish--timage' of image SPEC, or nil.
PNG data is used as is.  JPEG, GIF and WebP start a background
conversion; until it finishes, and when it fails, the result is nil.  The
input format is named explicitly so that only these raster decoders see
agent-supplied data; SVG in particular stays out of ImageMagick."
  (when-let* (((eq (car-safe spec) 'image))
              (data (plist-get (cdr spec) :data))
              ((stringp data)))
    (let ((image (gethash data pilish--terminal-images)))
      (unless image
        (setq image
              (pcase (plist-get (cdr spec) :type)
                ('png (pilish--terminal-image-from-png data))
                ((and type (or 'jpeg 'gif 'webp))
                 (if (pilish--terminal-image-converter)
                     (progn
                       (setq pilish--terminal-image-queue
                             (nconc pilish--terminal-image-queue
                                    (list (cons data type))))
                       'pending)
                   'unsupported))
                (_ 'unsupported)))
        (puthash data image pilish--terminal-images)
        (when (eq image 'pending)
          (pilish--terminal-image-start-conversions)))
      (and (pilish--timage-p image) image))))

;;;; Conversion

(defun pilish--terminal-image-converter ()
  "Return the ImageMagick program, or nil when it is not installed."
  (or (executable-find "magick") (executable-find "convert")))

(defun pilish--terminal-image-start-conversions ()
  "Start queued conversions while slots are free."
  (while (and pilish--terminal-image-queue
              (< (length pilish--terminal-image-conversions)
                 pilish--terminal-image-conversion-slots))
    (let ((job (pop pilish--terminal-image-queue)))
      (condition-case err
          (push (pilish--terminal-image-start-conversion (car job) (cdr job))
                pilish--terminal-image-conversions)
        (error
         (puthash (car job) 'unsupported pilish--terminal-images)
         (message "Pi: Image conversion failed to start: %s"
                  (error-message-string err)))))))

(defun pilish--terminal-image-start-conversion (data type)
  "Start converting image DATA of Emacs image TYPE to PNG; return the process.
The process reads a private temporary file, as named format TYPE, and
writes PNG to its output buffer."
  (let ((file (make-temp-file "pilish-image-"))
        (output (generate-new-buffer " *pilish-terminal-image*" t))
        (stderr (generate-new-buffer " *pilish-terminal-image-stderr*" t)))
    (condition-case err
        (let ((process
               (let ((coding-system-for-write 'binary))
                 (write-region data nil file nil 'silent)
                 (make-process
                  :name "pilish-terminal-image"
                  :buffer output
                  :command (append
                            (list (pilish--terminal-image-converter))
                            pilish--terminal-image-conversion-limits
                            (list "-limit" "time"
                                  (number-to-string
                                   (ceiling pilish--terminal-image-conversion-timeout))
                                  (format "%s:%s[0]" type file)
                                  "-resize" pilish--terminal-image-conversion-geometry
                                  "png:-"))
                  :coding 'binary
                  :connection-type 'pipe
                  :noquery t
                  :stderr stderr
                  :filter #'pilish--terminal-image-conversion-output
                  :sentinel #'pilish--terminal-image-conversion-done))))
          (with-current-buffer output (set-buffer-multibyte nil))
          (when-let* ((stderr-process (get-buffer-process stderr)))
            (set-process-query-on-exit-flag stderr-process nil))
          (process-put process 'pilish-data data)
          (process-put process 'pilish-file file)
          (process-put process 'pilish-stderr stderr)
          (process-put process 'pilish-timer
                       (run-with-timer pilish--terminal-image-conversion-timeout nil
                                       #'pilish--terminal-image-conversion-stop
                                       process "timed out"))
          process)
      (error
       (delete-file file)
       (kill-buffer output)
       (when-let* ((stderr-process (get-buffer-process stderr)))
         (delete-process stderr-process))
       (kill-buffer stderr)
       (signal (car err) (cdr err))))))

(defun pilish--terminal-image-conversion-stop (process reason)
  "Stop conversion PROCESS, which then fails for REASON."
  (when (process-live-p process)
    (process-put process 'pilish-failure reason)
    (delete-process process)))

(defun pilish--terminal-image-conversion-output (process string)
  "Collect STRING from conversion PROCESS, stopping output that is too large."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (goto-char (point-max))
      (insert string)
      (when (> (buffer-size) pilish--terminal-image-conversion-max-bytes)
        (pilish--terminal-image-conversion-stop process "output too large")))))

(defun pilish--terminal-image-conversion-release (process)
  "Release the timer, file and buffers of conversion PROCESS."
  (setq pilish--terminal-image-conversions
        (delq process pilish--terminal-image-conversions))
  (when (timerp (process-get process 'pilish-timer))
    (cancel-timer (process-get process 'pilish-timer)))
  (let ((file (process-get process 'pilish-file)))
    (when (and file (file-exists-p file))
      (delete-file file)))
  (dolist (buffer (list (process-buffer process)
                        (process-get process 'pilish-stderr)))
    (when (buffer-live-p buffer)
      (when-let* ((buffer-process (get-buffer-process buffer)))
        (delete-process buffer-process))
      (kill-buffer buffer))))

(defun pilish--terminal-image-conversion-done (process _event)
  "Record the result of finished conversion PROCESS and update chats."
  (when (and (not (process-live-p process))
             (memq process pilish--terminal-image-conversions))
    (let* ((png (and (not (process-get process 'pilish-failure))
                     (eq (process-status process) 'exit)
                     (eql 0 (process-exit-status process))
                     (buffer-live-p (process-buffer process))
                     (with-current-buffer (process-buffer process)
                       (buffer-string))))
           (image (if png (pilish--terminal-image-from-png png) 'unsupported)))
      (pilish--terminal-image-conversion-release process)
      (puthash (process-get process 'pilish-data) image pilish--terminal-images)
      (pilish--terminal-image-start-conversions)
      (when (pilish--timage-p image)
        (dolist (buffer (buffer-list))
          (with-current-buffer buffer
            (when (and (derived-mode-p 'pilish-transcript-mode)
                       (pilish--terminal-image-windows))
              (pilish--terminal-image-schedule))))))))

(defun pilish--terminal-image-cancel-conversions ()
  "Stop all conversions and forget their pending results."
  (dolist (job pilish--terminal-image-queue)
    (remhash (car job) pilish--terminal-images))
  (setq pilish--terminal-image-queue nil)
  (dolist (process pilish--terminal-image-conversions)
    (set-process-sentinel process #'ignore)
    (delete-process process)
    (remhash (process-get process 'pilish-data) pilish--terminal-images)
    (pilish--terminal-image-conversion-release process))
  (setq pilish--terminal-image-conversions nil))

;;;; Terminal protocol

(defun pilish--terminal-image-sequences (id png)
  "Return the escape sequence storing PNG bytes as image ID.
q=2 stops replies, which would otherwise arrive as keyboard input."
  (let* ((payload (base64-encode-string png t))
         (size (length payload))
         (start 0)
         sequences)
    (while (< start size)
      (let ((end (min size (+ start pilish--terminal-image-chunk-size))))
        (push (format "\e_G%sq=2,m=%d;%s\e\\"
                      (if (= start 0) (format "a=t,f=100,i=%d," id) "")
                      (if (< end size) 1 0)
                      (substring payload start end))
              sequences)
        (setq start end)))
    (apply #'concat (nreverse sequences))))

(defun pilish--terminal-image-placement (id size)
  "Return the escape sequence fitting image ID to SIZE, a (COLS . ROWS) pair."
  (format "\e_Ga=p,U=1,q=2,i=%d,p=1,c=%d,r=%d\e\\" id (car size) (cdr size)))

(defun pilish--terminal-image-deletion (id)
  "Return the escape sequence deleting image ID and its data."
  (format "\e_Ga=d,d=I,q=2,i=%d\e\\" id))

(defun pilish--terminal-image-cell (row column high)
  "Return one placeholder cell for ROW and COLUMN of an image id's HIGH byte."
  (compose-string
   (string pilish--terminal-image-placeholder
           (aref pilish--terminal-image-diacritics row)
           (aref pilish--terminal-image-diacritics column)
           (aref pilish--terminal-image-diacritics high))))

(defun pilish--terminal-image-grid (id size)
  "Return placeholder text showing image ID at SIZE, a (COLS . ROWS) pair."
  (let ((high (ash id -24)))
    (propertize
     (mapconcat
      (lambda (row)
        (mapconcat (lambda (column) (pilish--terminal-image-cell row column high))
                   (number-sequence 0 (1- (car size))) ""))
      (number-sequence 0 (1- (cdr size))) "\n")
     'face (list :foreground (format "#%06x" (logand id #xFFFFFF))))))

(defun pilish--terminal-image-table (terminal)
  "Return TERMINAL's table of stored images, mapping (HASH SIZE) to an id."
  (or (terminal-parameter terminal 'pilish-terminal-images)
      (let ((table (make-hash-table :test 'equal)))
        (set-terminal-parameter terminal 'pilish-terminal-images table)
        table)))

(defun pilish--terminal-image-new-id (table)
  "Return a random 32-bit image id that TABLE does not use.
The low 24 bits, the foreground color, are neither zero nor white.  A
terminal's image store is shared with other programs, so random ids make
collisions with their images unlikely, not impossible."
  (let ((used (hash-table-values table)) id)
    (while (or (null id) (memql id used))
      (setq id (logior (ash (random 256) 24) (1+ (random #xFFFFFE)))))
    id))

(defun pilish--terminal-image-send (image size frame)
  "Make IMAGE available at SIZE on the terminal of FRAME; return its id."
  (let* ((terminal (frame-terminal frame))
         (table (pilish--terminal-image-table terminal))
         (key (list (pilish--timage-hash image) size)))
    (or (gethash key table)
        (let ((id (pilish--terminal-image-new-id table)))
          (send-string-to-terminal
           (pilish--terminal-image-sequences id (pilish--timage-png image))
           terminal)
          (send-string-to-terminal (pilish--terminal-image-placement id size)
                                   terminal)
          (puthash key id table)))))

(defun pilish--terminal-image-collect ()
  "Delete stored images that no chat window on their terminal shows.
Without the mode, delete all of them."
  (let ((used (make-hash-table :test 'equal)))
    (when pilish-terminal-image-mode
      (dolist (buffer (buffer-list))
        (dolist (overlay (buffer-local-value 'pilish--terminal-image-overlays buffer))
          (let ((window (overlay-get overlay 'window)))
            (when (and (overlay-buffer overlay) (window-live-p window))
              (puthash (cons (frame-terminal (window-frame window))
                             (car (overlay-get overlay 'pilish-terminal-image)))
                       t used))))))
    (dolist (terminal (terminal-list))
      (when-let* ((table (terminal-parameter terminal 'pilish-terminal-images)))
        (maphash (lambda (key id)
                   (unless (gethash (cons terminal id) used)
                     (send-string-to-terminal
                      (pilish--terminal-image-deletion id) terminal)
                     (remhash key table)))
                 table)))))

;;;; Chat windows

(defun pilish--terminal-image-size (image windows)
  "Return the (COLS . ROWS) of IMAGE for all of WINDOWS.
The smallest window decides.  Cells are taken to be twice as high as
wide; terminals keep the aspect ratio when that is not exact."
  (let* ((width (pilish--timage-width image))
         (height (pilish--timage-height image))
         (limit (length pilish--terminal-image-diacritics))
         (max-cols (apply #'min limit
                          (ceiling width (float pilish--terminal-image-cell-width))
                          (append
                           (when (natnump pilish-image-preview-max-width)
                             (list (/ pilish-image-preview-max-width
                                      pilish--terminal-image-cell-width)))
                           (mapcar (lambda (window)
                                     (- (window-body-width window) 2))
                                   windows))))
         (max-rows (apply #'min limit
                          (mapcar (lambda (window)
                                    (/ (window-body-height window) 2))
                                  windows)))
         (cols (max 1 max-cols))
         (rows (ceiling (* cols height) (* 2.0 width))))
    (when (> rows (max 1 max-rows))
      (setq rows (max 1 max-rows)
            cols (max 1 (min cols (ceiling (* rows 2.0 width) height)))))
    (cons cols rows)))

(defun pilish--terminal-image-windows ()
  "Return windows showing this buffer on capable terminals."
  (seq-filter (lambda (window)
                (pilish--terminal-image-frame-p (window-frame window)))
              (get-buffer-window-list (current-buffer) nil t)))

(defun pilish--terminal-image-range (window)
  "Return the (START . END) of WINDOW's text worth preparing."
  (cons (max (point-min)
             (- (window-start window) pilish--terminal-image-margin))
        (min (point-max)
             (+ (window-end window t) pilish--terminal-image-margin))))

(defun pilish--terminal-image-previews (range)
  "Return (START END SPEC) of each image preview within RANGE."
  (let ((position (car range)) (end (cdr range)) previews)
    (while (< position end)
      (let ((next (next-single-property-change
                   position 'pilish-image-preview nil end)))
        (when (get-text-property position 'pilish-image-preview)
          (push (list position next (get-text-property position 'display))
                previews))
        (setq position next)))
    (nreverse previews)))

(defun pilish--terminal-image-overlay-start (start)
  "Return where the overlay of a preview at START begins.
An overlay string with newlines right after a hidden line stops upward
line motion and scrolling, so the overlay takes in a closing code fence."
  (save-excursion
    (goto-char start)
    (if (and (zerop (forward-line -1))
             (looking-at-p "```+[ \t]*$"))
        (point)
      start)))

(defun pilish--terminal-image-overlay (window start end id size)
  "Return WINDOW's overlay showing image ID at SIZE over START..END."
  (let ((key (list id size)))
    (or (seq-find (lambda (overlay)
                    (and (eq (overlay-get overlay 'window) window)
                         (eql (overlay-start overlay) start)
                         (eql (overlay-end overlay) end)
                         (equal (overlay-get overlay 'pilish-terminal-image) key)))
                  pilish--terminal-image-overlays)
        (let ((overlay (make-overlay start end nil t nil)))
          (overlay-put overlay 'window window)
          (overlay-put overlay 'evaporate t)
          (overlay-put overlay 'pilish-terminal-image key)
          (overlay-put overlay 'display (pilish--terminal-image-grid id size))
          (push overlay pilish--terminal-image-overlays)
          overlay))))

(defun pilish--terminal-image-after-change (start end length)
  "Update terminal images when START..END changes a preview.
LENGTH is the length of the replaced text."
  (when (or (> length 0)
            (text-property-not-all start end 'pilish-image-preview nil))
    (pilish--terminal-image-schedule)))

(defun pilish--terminal-image-update ()
  "Bring this chat's terminal image overlays up to date.
Each window sizes its images on its own."
  (let ((windows (pilish--terminal-image-windows))
        ranges kept)
    (if windows
        (add-hook 'after-change-functions
                  #'pilish--terminal-image-after-change nil t)
      (remove-hook 'after-change-functions
                   #'pilish--terminal-image-after-change t))
    (save-restriction
      (widen)
      (dolist (window windows)
        (let ((range (pilish--terminal-image-range window)))
          (push (cons window range) ranges)
          (pcase-dolist (`(,start ,end ,spec)
                         (pilish--terminal-image-previews range))
            (when-let* ((image (pilish--terminal-image-for-spec spec)))
              (let* ((size (pilish--terminal-image-size image (list window)))
                     (id (pilish--terminal-image-send
                          image size (window-frame window))))
                (push (pilish--terminal-image-overlay
                       window (pilish--terminal-image-overlay-start start) end
                       id size)
                      kept)))))))
    ;; Overlays out of range stay, so that scrolling back finds them.
    (setq pilish--terminal-image-overlays
          (seq-filter
           (lambda (overlay)
             (let* ((window (overlay-get overlay 'window))
                    (range (alist-get window ranges))
                    (stale (or (not (overlay-buffer overlay))
                               (not (memq window windows))
                               (and (not (memq overlay kept))
                                    (<= (car range) (overlay-start overlay))
                                    (< (overlay-start overlay) (cdr range))))))
               (when stale (delete-overlay overlay))
               (not stale)))
           pilish--terminal-image-overlays))
    (pilish--terminal-image-collect)))

(defun pilish--terminal-image-refresh (buffer)
  "Update the terminal images of chat BUFFER, reporting failures."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq pilish--terminal-image-timer nil)
      (condition-case err
          (pilish--terminal-image-update)
        (error
         ;; Never leave a placeholder grid for an image that was not sent.
         (mapc #'delete-overlay pilish--terminal-image-overlays)
         (setq pilish--terminal-image-overlays nil)
         (message "Pi: Terminal image update failed: %s"
                  (error-message-string err)))))))

(defun pilish--terminal-image-schedule ()
  "Update this chat's terminal images soon."
  (unless pilish--terminal-image-timer
    (setq pilish--terminal-image-timer
          (run-with-timer pilish--terminal-image-delay nil
                          #'pilish--terminal-image-refresh (current-buffer)))))

(defun pilish--terminal-image-window-changed (window &rest _)
  "Note that WINDOW, showing a chat, changed its buffer, size or start."
  (with-current-buffer (window-buffer window)
    (when (or pilish--terminal-image-overlays
              (pilish--terminal-image-frame-p (window-frame window)))
      (pilish--terminal-image-schedule))))

(defun pilish--terminal-image-cleanup ()
  "Cancel updates and restore this chat's ordinary image display."
  (when (timerp pilish--terminal-image-timer)
    (cancel-timer pilish--terminal-image-timer))
  (setq pilish--terminal-image-timer nil)
  (mapc #'delete-overlay pilish--terminal-image-overlays)
  (setq pilish--terminal-image-overlays nil)
  (remove-hook 'after-change-functions #'pilish--terminal-image-after-change t)
  (dolist (hook '(window-buffer-change-functions
                  window-size-change-functions
                  window-scroll-functions))
    (remove-hook hook #'pilish--terminal-image-window-changed t)))

(defun pilish--terminal-image-setup ()
  "Track the windows that display the current chat buffer when enabled."
  (when pilish-terminal-image-mode
    (dolist (hook '(window-buffer-change-functions
                    window-size-change-functions
                    window-scroll-functions))
      (add-hook hook #'pilish--terminal-image-window-changed nil t))
    (add-hook 'kill-buffer-hook #'pilish--terminal-image-cleanup nil t)))

(add-hook 'pilish-transcript-mode-hook #'pilish--terminal-image-setup)

(provide 'pilish-terminal-image)
;;; pilish-terminal-image.el ends here
