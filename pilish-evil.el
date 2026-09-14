;;; pilish-evil.el --- Evil keybindings for Pilish -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel Nouri

;; Author: Daniel Nouri <daniel.nouri@gmail.com>
;; Maintainer: Daniel Nouri <daniel.nouri@gmail.com>
;; URL: https://github.com/dnouri/pilish

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Optional Evil integration for Pilish, modeled on how Evil
;; and Magit cooperate: the read-only chat buffer starts in motion
;; state so navigation keys work unmodified, the input buffer starts
;; in insert state, and `?' opens the transient menu.
;;
;; This file loads automatically when a session is set up while Evil
;; is in use; set `pilish-evil-integration' to nil before
;; loading pilish to opt out.  It can also be loaded
;; explicitly:
;;
;;   (require 'pilish-evil)
;;
;; Loading the file runs `pilish-evil-setup', which is
;; idempotent and can also be called interactively to re-apply the
;; configuration after changing the user options below.
;;
;; Chat buffer (motion state):
;;
;;   n / p   next / previous message (like Magit's section motion)
;;   f       fork session at point
;;   w       copy an @path:line reference at point
;;   TAB     toggle tool/thinking section
;;   RET     visit file at point
;;   i / a   focus input window (append moves to end of input)
;;   ?       transient menu
;;   q       quit session
;;
;; Input buffer (normal state):
;;
;;   RET     send
;;   q       close input window
;;   ?       transient menu
;;
;; Session and tree browser buffers (motion state):
;;
;;   j / k   section navigation (Magit's own, unmodified)
;;   Every   documented browser key — sort, filters, search, scope,
;;          rename, delete, refresh, dispatch, RET — is also rebound
;;          in motion state, because the Evil and evil-collection
;;          keymap stack would otherwise swallow the letters:
;;          evil-snipe owns f/t, evil's motion state owns /, ?, and
;;          the g prefix, and setups that put magit-derived modes in
;;          normal state leave operators waiting on more keys.
;;
;; All bindings are registered with `evil-define-key' on the mode
;; keymaps, so user bindings via the same mechanism take precedence
;; when made after `pilish-evil-setup' runs.

;;; Code:

;; Require the submodules directly rather than `pilish': this
;; file may be loaded while pilish.el itself is still
;; loading, and requiring the top-level feature from here would be a
;; recursive require.
(require 'pilish-ui)
(require 'pilish-input)
(require 'pilish-menu)

;; Evil is an optional dependency: this file must byte-compile and
;; load in environments where Evil is not installed (e.g. MELPA
;; builds), and only activates when Evil is present.  Call the
;; function `evil-define-key*' rather than the `evil-define-key'
;; macro so byte-compiled output is correct regardless of whether
;; Evil was present at compile time.
(require 'evil nil t)

(declare-function evil-change-state "evil")
(declare-function evil-define-key* "evil")
(declare-function evil-set-initial-state "evil")
(declare-function evil-snipe-local-mode "evil-snipe")
(declare-function evil-snipe-override-local-mode "evil-snipe")

;; Browser and chat command declarations follow the menu/ui pattern:
;; declare the entry points without requiring their modules, keeping
;; this file's dependencies (ui, input, menu) acyclic with them.
(declare-function pilish-copy-file-reference "pilish-render")
(declare-function pilish-visit-file "pilish-render")
(declare-function pilish-toggle-tool-section "pilish-render")
(declare-function pilish-browse-refresh "pilish-browse")
(declare-function pilish-session-browser-cycle-sort "pilish-browse")
(declare-function pilish-session-browser-toggle-named "pilish-browse")
(declare-function pilish-session-browser-toggle-scope "pilish-browse")
(declare-function pilish-session-browser-search "pilish-browse")
(declare-function pilish-session-browser-rename "pilish-browse")
(declare-function pilish-session-browser-delete "pilish-browse")
(declare-function pilish-session-browser-switch "pilish-browse")
(declare-function pilish-session-browser-dispatch "pilish-browse")
(declare-function pilish-tree-browser-cycle-filter "pilish-browse")
(declare-function pilish-tree-browser-set-label "pilish-browse")
(declare-function pilish-tree-browser-search "pilish-browse")
(declare-function pilish-tree-browser-navigate "pilish-browse")
(declare-function pilish-tree-browser-dispatch "pilish-browse")

;; Keymaps defined by `define-derived-mode' in `pilish-browse', which
;; this file does not require (see the comment above).  `defvar' does
;; not reset an already-bound map, so load order does not matter.
(defvar pilish-session-browser-mode-map nil
  "Session browser keymap; the real map is defined by `pilish-browse'.")
(defvar pilish-tree-browser-mode-map nil
  "Tree browser keymap; the real map is defined by `pilish-browse'.")

;; Note on the evil-snipe references below: hook variables are only
;; ever quoted, and mode variables are tested with
;; `bound-and-true-p', so nothing needs declaring here.  Adding to
;; the hooks before evil-snipe loads is safe: the hooks exist as soon
;; as `add-hook' creates them, and `defvar' in evil-snipe does not
;; reset an already-bound variable.

(defcustom pilish-evil-chat-state 'motion
  "Initial Evil state for pi chat buffers.
The chat buffer is read-only; motion state provides navigation keys
while unbound keys fall through to the mode's own keymap."
  :type 'symbol
  :group 'pilish)

(defcustom pilish-evil-input-state 'insert
  "Evil state for pi input buffers.
Used both as the initial state when an input buffer is created and as
the state entered when focusing the input window from the chat
buffer with `pilish-evil-insert-input' or
`pilish-evil-append-input'."
  :type 'symbol
  :group 'pilish)

(defcustom pilish-evil-browse-state 'motion
  "Initial Evil state for Pilish browser buffers.
Motion state keeps j/k and other navigation keys working while unbound
keys fall through to the browser's own keymap; `pilish-evil-setup'
additionally rebinds the documented browser letters in motion state
so the Evil keymap stack (search keys, the g prefix, evil-snipe's
snipe keys, and normal-state operators in evil-collection style
setups) never swallows them.  `emacs' also works: every browser key
lives in the major-mode map itself."
  :type 'symbol
  :group 'pilish)

(defcustom pilish-evil-disable-snipe t
  "When non-nil, disable `evil-snipe' in pi chat and browser buffers.
evil-snipe's minor-mode keymaps take precedence over the chat mode's
own `f' binding (fork at point) and the browsers' f and t bindings
for the named-only filter, scope toggle, and tree filter, so
`pilish-evil-setup' turns the snipe minor modes off in those buffers
via `evil-snipe-local-mode-hook' and
`evil-snipe-override-local-mode-hook'.  Without evil-snipe, fork
stays on `f' while F, t, and T remain Evil's native char-finding
motions in the chat buffer, and the browser keys keep their
documented meanings."
  :type 'boolean
  :group 'pilish)

(defcustom pilish-evil-copy-raw-markdown t
  "When non-nil, yanking from the chat buffer copies raw Markdown.
`pilish-evil-setup' arranges for
`pilish-copy-raw-markdown' to be set buffer-locally in chat
buffers, so that `evil-yank' preserves code fences and markup.  Set
to nil before loading this file to keep the upstream default of
copying only visible text."
  :type 'boolean
  :group 'pilish)

(defun pilish-evil--copy-raw-markdown-in-chat ()
  "Set `pilish-copy-raw-markdown' buffer-locally.
Added to `pilish-chat-mode-hook' by
`pilish-evil-setup' when
`pilish-evil-copy-raw-markdown' is non-nil."
  (setq-local pilish-copy-raw-markdown t))

(defun pilish-evil--maybe-disable-snipe ()
  "Disable the `evil-snipe' minor modes in pi chat and browser buffers.
Added to `evil-snipe-local-mode-hook' and
`evil-snipe-override-local-mode-hook' by
`pilish-evil-setup' when `pilish-evil-disable-snipe'
is non-nil.  Mode hooks run on disable as well as enable, so guard
on the modes being active to avoid recursing."
  (when (derived-mode-p 'pilish-chat-mode 'pilish-browse-mode)
    (when (bound-and-true-p evil-snipe-local-mode)
      (evil-snipe-local-mode -1))
    (when (bound-and-true-p evil-snipe-override-local-mode)
      (evil-snipe-override-local-mode -1))))

(defun pilish-evil-insert-input ()
  "Focus the session input window and enter the configured input state.
Enter the state named by `pilish-evil-input-state' (insert
by default).  Restore the session window layout when no input window
is visible."
  (interactive)
  (pilish-evil--focus-input nil))

(defun pilish-evil-append-input ()
  "Focus the session input window at end of buffer.
Enter the state named by `pilish-evil-input-state' (insert
by default)."
  (interactive)
  (pilish-evil--focus-input t))

(defun pilish-evil--enter-input-state ()
  "Enter the state named by `pilish-evil-input-state'."
  (evil-change-state pilish-evil-input-state))

(defun pilish-evil--focus-input (append)
  "Focus the session input window and enter the configured input state.
When APPEND is non-nil, move point to the end of the input buffer."
  (let ((chat-buf (pilish--get-chat-buffer))
        (input-buf (pilish--get-input-buffer)))
    (unless (and (buffer-live-p chat-buf) (buffer-live-p input-buf))
      (user-error "No pi session for this buffer"))
    (if-let* ((input-win (get-buffer-window input-buf)))
        (select-window input-win)
      (pilish--display-buffers chat-buf input-buf))
    (when (derived-mode-p 'pilish-input-mode)
      (when append
        (goto-char (point-max)))
      (pilish-evil--enter-input-state))))

(defun pilish-evil-close-input ()
  "Close the session input window and select the chat window."
  (interactive)
  (when-let* ((input-buf (pilish--get-input-buffer))
              (input-win (get-buffer-window input-buf)))
    (when (window-parent input-win)
      (delete-window input-win)
      (when-let* ((chat-buf (pilish--get-chat-buffer))
                  (chat-win (get-buffer-window chat-buf)))
        (select-window chat-win)))))

;;;###autoload
(defun pilish-evil-setup ()
  "Set up Evil integration for Pilish.
Set initial buffer states, install keybindings, and apply the user
options `pilish-evil-chat-state',
`pilish-evil-input-state',
`pilish-evil-browse-state',
`pilish-evil-copy-raw-markdown', and
`pilish-evil-disable-snipe'.  Safe to call more than once."
  (interactive)
  (unless (featurep 'evil)
    (user-error "pilish-evil: Evil is not loaded"))
  (evil-set-initial-state 'pilish-chat-mode
                          pilish-evil-chat-state)
  (evil-set-initial-state 'pilish-input-mode
                          pilish-evil-input-state)
  ;; Explicit per-mode entries rather than one entry on the shared
  ;; base mode: `evil-initial-state' walks derived-mode parents, but
  ;; listing each concrete browse mode keeps the registration obvious
  ;; and immune to future restructuring of the mode hierarchy.
  (evil-set-initial-state 'pilish-browse-mode
                          pilish-evil-browse-state)
  (evil-set-initial-state 'pilish-session-browser-mode
                          pilish-evil-browse-state)
  (evil-set-initial-state 'pilish-tree-browser-mode
                          pilish-evil-browse-state)
  (evil-define-key* 'motion pilish-chat-mode-map
    "n" #'pilish-next-message
    "p" #'pilish-previous-message
    "f" #'pilish-fork-at-point
    "w" #'pilish-copy-file-reference
    "?" #'pilish-menu
    "q" #'pilish-quit
    "i" #'pilish-evil-insert-input
    "a" #'pilish-evil-append-input
    (kbd "RET") #'pilish-visit-file
    (kbd "TAB") #'pilish-toggle-tool-section
    [tab] #'pilish-toggle-tool-section)
  ;; Browsers: reclaim every documented letter in motion state.  The
  ;; Evil and evil-collection keymap stack otherwise wins — evil's
  ;; motion state owns `/', `?', and the `g' prefix; evil-snipe owns
  ;; `f' and `t' (see `pilish-evil--maybe-disable-snipe'); and setups
  ;; that put magit-derived modes in normal state leave operators
  ;; waiting on more keys.  The major-mode bindings stay authoritative
  ;; for every state, so `emacs' state users lose nothing.
  (evil-define-key* 'motion pilish-session-browser-mode-map
    "s" #'pilish-session-browser-cycle-sort
    "f" #'pilish-session-browser-toggle-named
    "t" #'pilish-session-browser-toggle-scope
    "/" #'pilish-session-browser-search
    "r" #'pilish-session-browser-rename
    "d" #'pilish-session-browser-delete
    "?" #'pilish-session-browser-dispatch
    "h" #'pilish-session-browser-dispatch
    "g" #'pilish-browse-refresh
    "q" #'quit-window
    (kbd "RET") #'pilish-session-browser-switch)
  (evil-define-key* 'motion pilish-tree-browser-mode-map
    "f" #'pilish-tree-browser-cycle-filter
    "l" #'pilish-tree-browser-set-label
    "/" #'pilish-tree-browser-search
    "?" #'pilish-tree-browser-dispatch
    "h" #'pilish-tree-browser-dispatch
    "g" #'pilish-browse-refresh
    "q" #'quit-window
    (kbd "RET") #'pilish-tree-browser-navigate)
  (evil-define-key* 'normal pilish-input-mode-map
    (kbd "RET") #'pilish-send
    "q" #'pilish-evil-close-input
    "?" #'pilish-menu)
  (when pilish-evil-copy-raw-markdown
    (add-hook 'pilish-chat-mode-hook
              #'pilish-evil--copy-raw-markdown-in-chat))
  (when pilish-evil-disable-snipe
    (add-hook 'evil-snipe-local-mode-hook
              #'pilish-evil--maybe-disable-snipe)
    (add-hook 'evil-snipe-override-local-mode-hook
              #'pilish-evil--maybe-disable-snipe)))

;; Activate on load when Evil is present.
(when (featurep 'evil)
  (pilish-evil-setup))

(provide 'pilish-evil)
;;; pilish-evil.el ends here
