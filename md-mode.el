;;; md-mode.el --- Edit and render Markdown buffers -*- lexical-binding: t; -*-

;; Copyright (C) 2026 LuciusChen

;; Author: LuciusChen
;; URL: https://github.com/yibie/md-mode
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: wp, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Assisted-by: Codex:gpt-5.5

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this file.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; `md-mode' keeps Markdown source editable while font-lock displays its
;; structure.  A complete read-only rendering remains available on demand.
;; `md-mode-show-source' reconstructs the exact source before editing, saving,
;; reverting, or changing major modes.

;;; Code:

(require 'md-render)
(require 'browse-url)
(require 'cl-lib)
(require 'face-remap)
(require 'fringe)
(require 'imenu)
(require 'outline)
(require 'seq)
(require 'subr-x)
(require 'text-property-search)

(declare-function hel-keymap-local-set "hel-core" (&rest args))

(defgroup md nil
  "Edit and render Markdown buffers."
  :group 'text)

(defcustom md-mode-auto-align-tables t
  "When non-nil, align Markdown tables when entering `md-mode'."
  :type 'boolean
  :group 'md)

(defcustom md-mode-fold-front-matter-on-open nil
  "When non-nil, fold front matter when entering `md-mode'."
  :type 'boolean
  :group 'md)

(defcustom md-mode-use-markdown-mode-faces t
  "When non-nil, reuse available `markdown-mode' faces.

Only faces that are already defined are reused.  This option does
not load or require `markdown-mode'."
  :type 'boolean
  :group 'md)

(defcustom md-mode-toc-side 'left
  "Side on which to display the Markdown table of contents."
  :type '(choice (const :tag "Left" left)
                 (const :tag "Right" right))
  :group 'md)

(defcustom md-mode-toc-width 30
  "Width in columns of the Markdown table of contents."
  :type 'natnum
  :group 'md)

(defface md-mode-callout
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for GitHub-style Markdown callout markers."
  :group 'md)

(defface md-mode-markup
  '((t :inherit shadow))
  "Face for editable Markdown delimiters."
  :group 'md)

(defvar-local md-mode--rendered-p nil
  "Non-nil when the current buffer displays rendered Markdown.")

(defvar-local md-mode--toc-buffer nil
  "Table of contents buffer associated with this Markdown buffer.")

(defvar-local md-mode--toc-source-buffer nil
  "Markdown source buffer associated with this TOC buffer.")

(defvar-local md-mode--toc-markers nil
  "Heading markers currently displayed in this TOC buffer.")

(defvar-local md-mode--toc-dirty-p nil
  "Non-nil when the associated TOC needs to be refreshed.")

(defvar-local md-mode--toc-refreshing-p nil
  "Non-nil while the current TOC buffer is being rebuilt.")

(define-fringe-bitmap
  'md-mode--table-overflow-dots
  [0 0 0 0 0 0 0 0 0 0 0 219 219] nil nil 'center)

(defvar-keymap md-mode-style-map
  :doc "Keymap for inserting Markdown links and styled blocks."
  "l" #'md-mode-insert-link
  "i" #'md-mode-insert-image
  "q" #'md-mode-insert-blockquote
  "c" #'md-mode-insert-code
  "a" #'md-mode-insert-callout)

(defvar-keymap md-mode--toc-mode-map
  :parent special-mode-map
  "RET" #'md-mode--toc-visit
  "<mouse-1>" #'md-mode--toc-mouse-visit
  "g" #'md-mode--toc-refresh
  "q" #'md-mode--toc-quit)

(define-derived-mode md-mode--toc-mode special-mode "MD TOC"
  "Major mode for a Markdown table of contents."
  (setq-local truncate-lines t)
  (add-hook 'kill-buffer-hook #'md-mode--toc-detach nil t))

(defvar-keymap md-mode-map
  :parent text-mode-map
  "M-RET" #'md-mode-insert-list-item
  "M-S-RET" #'md-mode-insert-todo-item
  "M-S-<return>" #'md-mode-insert-todo-item
  "C-c C-c" #'md-mode-context-action
  "C-RET" #'md-mode-insert-heading
  "M-<up>" #'md-mode-move-up
  "M-<down>" #'md-mode-move-down
  "M-S-<left>" #'md-mode-delete-table-column
  "M-S-<right>" #'md-mode-insert-table-column
  "M-S-<up>" #'md-mode-delete-table-row
  "M-S-<down>" #'md-mode-insert-table-row
  "M-<left>" #'md-mode-promote-heading
  "M-<right>" #'md-mode-demote-heading
  "TAB" #'md-mode-tab
  "S-TAB" #'md-mode-backtab
  "<backtab>" #'md-mode-backtab
  "C-c C-n" #'md-mode-next-heading
  "C-c C-p" #'md-mode-previous-heading
  "C-c C-u" #'md-mode-up-heading
  "C-c C-f" #'md-mode-forward-same-level
  "C-c C-b" #'md-mode-backward-same-level
  "C-c C-j" #'md-mode-goto-heading
  "C-c C-o" #'md-mode-open-at-point
  "C-c C-t" #'md-mode-toggle-toc
  "C-c |" #'md-mode-table
  "C-c -" #'md-mode-cycle-list-marker
  "M-h" #'md-mode-mark-element
  "C-c @" #'md-mode-mark-subtree
  "C-c C-l" #'md-mode-insert-link
  "C-c C-i" #'md-mode-insert-image
  "C-c C-s" md-mode-style-map
  "C-c C-v" #'md-mode-toggle-markup)

(defconst md-mode--table-row-regexp
  "^[^\n]*|[^\n]*$"
  "Regexp matching a possible Markdown table row.")

(defconst md-mode--fence-regexp
  "^[ \t]*\\(```\\).*$"
  "Regexp matching a fenced code block delimiter.")

(defconst md-mode--heading-regexp
  "^[ \t]*\\(#\\{1,6\\}\\)[ \t]+"
  "Regexp matching an ATX Markdown heading.")

(defconst md-mode--list-item-regexp
  "^\\([ \t]*\\)\\(?:\\([-+*]\\)\\|\\([0-9]+\\)\\([.)]\\)\\)[ \t]+\\(.*\\)$"
  "Regexp matching an ordered or unordered Markdown list item.")

(defconst md-mode--todo-item-regexp
  "^[ \t]*\\(?:[-+*]\\|[0-9]+[.)]\\)[ \t]+\\[\\([ xX]\\)\\]"
  "Regexp matching a Markdown task item.")

(defconst md-mode--link-regexp
  "\\(!?\\)\\[\\([^]\n]*\\)\\](\\(?:<\\([^>\n]+\\)>\\|\\([^) \n]+\\)\\))"
  "Regexp matching an inline Markdown link or image.")

(defconst md-mode--callout-types
  '("NOTE" "TIP" "IMPORTANT" "WARNING" "CAUTION")
  "Supported GitHub-style Markdown callout types.")

(defconst md-mode--markdown-face-alist
  '((md-mode-markup . markdown-markup-face)
    (md-render-bold . markdown-bold-face)
    (md-render-italic . markdown-italic-face)
    (md-render-strikethrough . markdown-strike-through-face)
    (md-render-inline-code . markdown-inline-code-face)
    (md-render-link . markdown-link-face)
    (md-render-blockquote . markdown-blockquote-face)
    (md-render-table-header . markdown-table-face)
    (md-render-table-border . markdown-table-face)
    (md-render-table-zebra . markdown-table-face)
    (md-render-source-block . markdown-code-face)
    (md-render-source-block-language . markdown-language-info-face))
  "Map md-mode faces to compatible `markdown-mode' faces.")

(defconst md-mode--heading-faces
  '(md-render-header-1
    md-render-header-2
    md-render-header-3
    md-render-header-4
    md-render-header-5
    md-render-header-6)
  "Faces used for rendered Markdown headings.")

(defun md-mode--set-heading-scaling-values (symbol values)
  "Set SYMBOL to heading scaling VALUES and update heading faces."
  (unless
      (and (proper-list-p values)
           (= (length values) (length md-mode--heading-faces))
           (seq-every-p
            (lambda (value)
              (and (floatp value) (> value 0)))
            values))
    (error "Heading scaling values must be six positive floats"))
  (set-default symbol values)
  (cl-mapc
   (lambda (face height)
     (unless (get face 'saved-face)
       (set-face-attribute face nil :height height)))
   md-mode--heading-faces values))

(defcustom md-mode-heading-scaling-values
  '(2.0 1.7 1.4 1.1 1.0 1.0)
  "Relative face heights for heading levels one through six."
  :type '(list (float :tag "Level 1")
               (float :tag "Level 2")
               (float :tag "Level 3")
               (float :tag "Level 4")
               (float :tag "Level 5")
               (float :tag "Level 6"))
  :set #'md-mode--set-heading-scaling-values
  :group 'md)

(defun md-mode--scale-heading-fallback-font ()
  "Let fallback fonts follow Markdown heading face heights."
  (when-let* ((window (get-buffer-window (current-buffer) t))
              (frame (window-frame window))
              ((display-graphic-p
                (frame-parameter frame 'display)))
              (han-position
               (save-excursion
                 (goto-char (point-min))
                 (catch 'han
                   (while (< (point) (point-max))
                     (when (eq (aref char-script-table (char-after)) 'han)
                       (throw 'han (point)))
                     (forward-char 1)))))
              (han-font (font-at han-position window))
              (han-family (font-get han-font :family)))
    (let* ((fontsets
            (delete-dups
             (delq nil
                   (mapcar
                    (lambda (face)
                      (let ((fontset
                             (face-attribute
                              face :fontset frame 'default)))
                        (and (stringp fontset) fontset)))
                    md-mode--heading-faces))))
           (configuration (cons han-family fontsets))
           (cached
            (frame-parameter frame 'md-mode--heading-fonts-cache)))
      (when (and fontsets (not (equal configuration cached)))
        (dolist (fontset fontsets)
          (set-fontset-font
           fontset 'han (font-spec :family han-family)
           frame 'prepend))
        (set-frame-parameter
         frame 'md-mode--heading-fonts-cache configuration)
        (redraw-frame frame)))))

(defconst md-mode--front-matter-delimiter-regexp
  "^\\(?:---\\|\\.\\.\\.\\)[ \t]*$"
  "Regexp matching a Markdown front matter delimiter.")

(defun md-mode--remap-markdown-mode-faces ()
  "Reuse compatible `markdown-mode' faces in the current buffer."
  (when md-mode-use-markdown-mode-faces
    (mapc
     (pcase-lambda (`(,md-face . ,markdown-face))
       (when (facep markdown-face)
         (face-remap-add-relative md-face markdown-face)))
     md-mode--markdown-face-alist)))

(defun md-mode--inside-fenced-block-p (&optional position)
  "Return non-nil when POSITION or point is inside a fenced code block."
  (let ((end (or position (point)))
        inside)
    (save-match-data
      (save-excursion
        (goto-char (point-min))
        (while (re-search-forward md-mode--fence-regexp end t)
          (setq inside (not inside)))))
    inside))

(defun md-mode--front-matter-fold-bounds ()
  "Return fold bounds when point is on the front matter opener."
  (save-excursion
    (beginning-of-line)
    (when (and (= (point) (point-min))
               (looking-at "^---[ \t]*$"))
      (forward-line 1)
      (let ((begin (point)))
        (when (re-search-forward
               md-mode--front-matter-delimiter-regexp nil t)
          (forward-line 1)
          (cons begin (point)))))))

(defun md-mode--fenced-block-fold-bounds ()
  "Return fold bounds when point is on a fenced code block opener."
  (save-excursion
    (beginning-of-line)
    (when (and (looking-at md-mode--fence-regexp)
               (not (md-mode--inside-fenced-block-p (point))))
      (forward-line 1)
      (let ((begin (point)))
        (when (re-search-forward md-mode--fence-regexp nil t)
          (forward-line 1)
          (cons begin (point)))))))

(defun md-mode--block-fold-bounds ()
  "Return front matter or fenced code fold bounds at point."
  (or (md-mode--front-matter-fold-bounds)
      (md-mode--fenced-block-fold-bounds)))

(defun md-mode--fold-initial-front-matter ()
  "Fold front matter according to the current user option."
  (when md-mode-fold-front-matter-on-open
    (save-excursion
      (goto-char (point-min))
      (when-let* ((bounds (md-mode--front-matter-fold-bounds)))
        (pcase-let ((`(,begin . ,end) bounds))
          (outline-flag-region begin end t))))))

(defun md-mode--find-heading (direction)
  "Find a Markdown heading in DIRECTION and return its position."
  (let ((search (if (> direction 0)
                    #'re-search-forward
                  #'re-search-backward))
        found)
    (while (and (not found)
                (funcall search md-mode--heading-regexp nil t))
      (unless (or (md-mode--inside-fenced-block-p (match-beginning 0))
                  (outline-invisible-p (match-beginning 0)))
        (setq found (match-beginning 0))))
    found))

(defun md-mode--outline-search (&optional bound move backward looking-at)
  "Search for a Markdown heading for Outline mode.

BOUND, MOVE, BACKWARD, and LOOKING-AT follow the contract of
`outline-search-function'.  Headings inside fenced blocks are
ignored."
  (let ((origin (point))
        (limit (or bound (if backward (point-min) (point-max))))
        found)
    (if looking-at
        (setq found
              (and (looking-at md-mode--heading-regexp)
                   (not (md-mode--inside-fenced-block-p))))
      (while (and (not found)
                  (if backward
                      (re-search-backward
                       md-mode--heading-regexp limit t)
                    (re-search-forward
                     md-mode--heading-regexp limit t)))
        (unless (md-mode--inside-fenced-block-p (match-beginning 0))
          (setq found t)))
      (unless found
        (goto-char (if move limit origin))))
    found))

(defun md-mode--outline-level ()
  "Return the Markdown heading level at point."
  (length (match-string 1)))

(defun md-mode--move-heading (direction count)
  "Move across COUNT Markdown headings in DIRECTION."
  (when (< count 0)
    (setq direction (- direction)
          count (- count)))
  (let ((origin (point))
        found)
    (dotimes (_ count)
      (if (> direction 0)
          (when (save-excursion
                  (beginning-of-line)
                  (looking-at md-mode--heading-regexp))
            (end-of-line))
        (beginning-of-line))
      (setq found (md-mode--find-heading direction))
      (unless found
        (goto-char origin)
        (user-error "No %s heading"
                    (if (> direction 0) "next" "previous")))
      (goto-char found))))

;;;###autoload
(defun md-mode-next-heading (&optional count)
  "Move to the next Markdown heading COUNT times."
  (interactive "p")
  (md-mode--ensure-mode)
  (md-mode--move-heading 1 (or count 1)))

;;;###autoload
(defun md-mode-previous-heading (&optional count)
  "Move to the previous Markdown heading COUNT times."
  (interactive "p")
  (md-mode--ensure-mode)
  (md-mode--move-heading -1 (or count 1)))

(defun md-mode--heading-level-at-point ()
  "Return the heading level at point, or nil."
  (save-excursion
    (beginning-of-line)
    (when (and (looking-at md-mode--heading-regexp)
               (not (md-mode--inside-fenced-block-p)))
      (length (match-string 1)))))

;;;###autoload
(defun md-mode-insert-list-item ()
  "Insert the next Markdown list item after the current one."
  (interactive)
  (md-mode--ensure-mode)
  (when (md-mode--inside-fenced-block-p)
    (user-error "List operation is unavailable inside a fenced block"))
  (beginning-of-line)
  (unless (looking-at md-mode--list-item-regexp)
    (user-error "Not on a Markdown list item"))
  (let ((indent (match-string 1))
        (bullet (match-string 2))
        (number (match-string 3))
        (delimiter (match-string 4))
        (content (match-string 5)))
    (if (string-empty-p (string-trim content))
        (delete-region (line-beginning-position) (line-end-position))
      (end-of-line)
      (insert "\n" indent
              (or bullet
                  (format "%d%s"
                          (1+ (string-to-number number))
                          delimiter))
              " "))))

;;;###autoload
(defun md-mode-insert-todo-item ()
  "Insert an unchecked Markdown task item after the current line."
  (interactive)
  (md-mode--ensure-mode)
  (when (md-mode--inside-fenced-block-p)
    (user-error "Task operation is unavailable inside a fenced block"))
  (beginning-of-line)
  (let ((indent "")
        (bullet "-"))
    (when (looking-at md-mode--list-item-regexp)
      (setq indent (match-string 1)
            bullet (or (match-string 2) "-")))
    (if (looking-at-p "[ \t]*$")
        (delete-region (line-beginning-position) (line-end-position))
      (end-of-line)
      (insert "\n"))
    (insert indent bullet " [ ] ")))

;;;###autoload
(defun md-mode-toggle-todo ()
  "Toggle the Markdown task item on the current line."
  (interactive)
  (md-mode--ensure-mode)
  (when (md-mode--inside-fenced-block-p)
    (user-error "Task operation is unavailable inside a fenced block"))
  (save-excursion
    (beginning-of-line)
    (unless (looking-at md-mode--todo-item-regexp)
      (user-error "Not on a Markdown task item"))
    (replace-match
     (if (string= (match-string 1) " ") "x" " ")
     t t nil 1)))

;;;###autoload
(defun md-mode-context-action ()
  "Perform the primary action for the Markdown structure at point."
  (interactive)
  (md-mode--ensure-mode)
  (cond
   ((save-excursion
      (beginning-of-line)
      (looking-at md-mode--todo-item-regexp))
    (md-mode-toggle-todo))
   ((md-mode--table-bounds)
    (let* ((bounds (md-mode--table-bounds))
           (begin (car bounds))
           (row (count-lines begin (line-beginning-position)))
           (column (md-mode--table-cell-index)))
      (md-mode--align-table-at-point bounds)
      (md-mode--goto-table-cell begin row column)
      (font-lock-flush begin (line-end-position))))
   (t
    (user-error "No Markdown action at point"))))

(defun md-mode--list-item-info ()
  "Return structural information for the list item at point."
  (save-excursion
    (beginning-of-line)
    (when (and (looking-at md-mode--list-item-regexp)
               (not (md-mode--inside-fenced-block-p)))
      (let ((begin (point))
            (indent (current-indentation))
            scanning)
        (forward-line 1)
        (setq scanning t)
        (while (and scanning (not (eobp)))
          (cond
           ((looking-at-p "[ \t]*$")
            (if (save-excursion
                  (forward-line 1)
                  (and (not (eobp))
                       (> (current-indentation) indent)))
                (forward-line 1)
              (setq scanning nil)))
           ((> (current-indentation) indent)
            (forward-line 1))
           (t
            (setq scanning nil))))
        (list :begin begin :end (point) :indent indent)))))

(defun md-mode--list-sibling (direction info)
  "Return the list sibling of INFO in DIRECTION."
  (let ((indent (plist-get info :indent))
        sibling
        searching)
    (save-excursion
      (goto-char (if (> direction 0)
                     (plist-get info :end)
                   (plist-get info :begin)))
      (setq searching t)
      (while (and searching
                  (if (> direction 0)
                      (not (eobp))
                    (= (forward-line -1) 0)))
        (cond
         ((looking-at-p "[ \t]*$")
          (when (> direction 0)
            (forward-line 1)))
         ((looking-at md-mode--list-item-regexp)
          (let ((candidate-indent (current-indentation)))
            (cond
             ((= candidate-indent indent)
              (setq sibling (md-mode--list-item-info)
                    searching nil))
             ((< candidate-indent indent)
              (setq searching nil))
             ((> direction 0)
              (forward-line 1)))))
         ((> direction 0)
          (setq searching nil))))
      sibling)))

(defun md-mode--move-list-item (direction)
  "Move the current Markdown list item in DIRECTION."
  (let* ((info (md-mode--list-item-info))
         (sibling (and info (md-mode--list-sibling direction info))))
    (unless info
      (user-error "Not on a Markdown list item"))
    (unless sibling
      (user-error "No list sibling in that direction"))
    (let* ((begin (plist-get info :begin))
           (end (plist-get info :end))
           (sibling-begin (plist-get sibling :begin))
           (sibling-end (plist-get sibling :end))
           (item-length (- end begin))
           (target (if (> direction 0)
                       (- sibling-end item-length)
                     sibling-begin)))
      (if (> direction 0)
          (transpose-regions begin end sibling-begin sibling-end)
        (transpose-regions sibling-begin sibling-end begin end))
      (goto-char target)
      (font-lock-flush
       (min begin sibling-begin) (max end sibling-end)))))

;;;###autoload
(defun md-mode-indent-list-item ()
  "Indent the current Markdown list item and its nested content."
  (interactive)
  (md-mode--ensure-mode)
  (if-let* ((info (md-mode--list-item-info)))
      (indent-rigidly (plist-get info :begin)
                      (plist-get info :end) 2)
    (user-error "Not on a Markdown list item")))

;;;###autoload
(defun md-mode-outdent-list-item ()
  "Outdent the current Markdown list item and its nested content."
  (interactive)
  (md-mode--ensure-mode)
  (if-let* ((info (md-mode--list-item-info)))
      (let ((amount (min 2 (plist-get info :indent))))
        (when (zerop amount)
          (user-error "List item is already at the outermost level"))
        (indent-rigidly (plist-get info :begin)
                        (plist-get info :end) (- amount)))
    (user-error "Not on a Markdown list item")))

;;;###autoload
(defun md-mode-cycle-list-marker ()
  "Cycle the current Markdown list marker."
  (interactive)
  (md-mode--ensure-mode)
  (beginning-of-line)
  (unless (and (looking-at md-mode--list-item-regexp)
               (not (md-mode--inside-fenced-block-p)))
    (user-error "Not on a Markdown list item"))
  (let* ((bullet (match-string 2))
         (replacement
          (cond
           ((equal bullet "-") "*")
           (bullet "1.")
           (t "-")))
         (begin (or (match-beginning 2) (match-beginning 3)))
         (end (or (match-end 2) (match-end 4))))
    (goto-char begin)
    (delete-region begin end)
    (insert replacement)))

;;;###autoload
(defun md-mode-insert-heading ()
  "Insert a Markdown heading at the nearest heading's level."
  (interactive)
  (md-mode--ensure-mode)
  (when (md-mode--inside-fenced-block-p)
    (user-error "Heading operation is unavailable inside a fenced block"))
  (let ((level (or (md-mode--heading-level-at-point)
                   (save-excursion
                     (beginning-of-line)
                     (when (md-mode--find-heading -1)
                       (md-mode--heading-level-at-point)))
                   1)))
    (if (save-excursion
          (beginning-of-line)
          (looking-at-p "[ \t]*$"))
        (delete-region (line-beginning-position) (line-end-position))
      (end-of-line)
      (insert "\n"))
    (insert (make-string level ?#) " ")))

(defun md-mode--heading-subtree-entries ()
  "Return markers and levels for headings in the current subtree."
  (let ((end (save-excursion
               (outline-end-of-subtree)
               (copy-marker (point) t)))
        entries)
    (save-excursion
      (beginning-of-line)
      (while (md-mode--outline-search end)
        (push (cons (copy-marker (match-beginning 1))
                    (length (match-string 1)))
              entries)))
    (set-marker end nil)
    (nreverse entries)))

(defun md-mode--adjust-heading-level (change)
  "Adjust the current Markdown heading subtree by CHANGE levels."
  (unless (md-mode--heading-level-at-point)
    (user-error "Not on a Markdown heading"))
  (let ((entries (md-mode--heading-subtree-entries)))
    (unwind-protect
        (progn
          (dolist (entry entries)
            (unless (<= 1 (+ (cdr entry) change) 6)
              (user-error
               "Markdown heading level must be between 1 and 6")))
          (save-excursion
            (dolist (entry entries)
              (goto-char (car entry))
              (if (> change 0)
                  (insert "#")
                (delete-char 1)))))
      (dolist (entry entries)
        (set-marker (car entry) nil)))))

;;;###autoload
(defun md-mode-promote-heading ()
  "Promote or move the Markdown structure at point left."
  (interactive)
  (md-mode--ensure-mode)
  (cond
   ((md-mode--table-bounds)
    (md-mode--move-table-column -1))
   ((md-mode--heading-level-at-point)
    (md-mode--adjust-heading-level -1))
   ((md-mode--list-item-info)
    (md-mode-outdent-list-item))
   (t
    (user-error "Not on an adjustable Markdown structure"))))

;;;###autoload
(defun md-mode-demote-heading ()
  "Demote or move the Markdown structure at point right."
  (interactive)
  (md-mode--ensure-mode)
  (cond
   ((md-mode--table-bounds)
    (md-mode--move-table-column 1))
   ((md-mode--heading-level-at-point)
    (md-mode--adjust-heading-level 1))
   ((md-mode--list-item-info)
    (md-mode-indent-list-item))
   (t
    (user-error "Not on an adjustable Markdown structure"))))

;;;###autoload
(defun md-mode-move-up (&optional count)
  "Move the current Markdown structure up COUNT siblings."
  (interactive "p")
  (md-mode--ensure-mode)
  (setq count (or count 1))
  (when (< count 0)
    (md-mode-move-down (- count))
    (setq count 0))
  (unless (zerop count)
    (cond
     ((md-mode--table-bounds)
      (dotimes (_ count)
        (md-mode--move-table-row -1)))
     ((md-mode--heading-level-at-point)
      (outline-move-subtree-up count))
     ((md-mode--list-item-info)
      (dotimes (_ count)
        (md-mode--move-list-item -1)))
     (t
      (user-error "Not on a movable Markdown structure")))))

;;;###autoload
(defun md-mode-move-down (&optional count)
  "Move the current Markdown structure down COUNT siblings."
  (interactive "p")
  (md-mode--ensure-mode)
  (setq count (or count 1))
  (when (< count 0)
    (md-mode-move-up (- count))
    (setq count 0))
  (unless (zerop count)
    (cond
     ((md-mode--table-bounds)
      (dotimes (_ count)
        (md-mode--move-table-row 1)))
     ((md-mode--heading-level-at-point)
      (outline-move-subtree-down count))
     ((md-mode--list-item-info)
      (dotimes (_ count)
        (md-mode--move-list-item 1)))
     (t
      (user-error "Not on a movable Markdown structure")))))

(defun md-mode--back-to-heading ()
  "Move to the current Markdown heading or signal a user error."
  (condition-case nil
      (outline-back-to-heading t)
    (outline-before-first-heading
     (user-error "Before first Markdown heading"))))

;;;###autoload
(defun md-mode-up-heading (&optional count)
  "Move up COUNT levels in the Markdown heading tree."
  (interactive "p")
  (md-mode--ensure-mode)
  (md-mode--back-to-heading)
  (outline-up-heading (or count 1) t))

;;;###autoload
(defun md-mode-forward-same-level (&optional count)
  "Move forward COUNT Markdown headings at the same level."
  (interactive "p")
  (md-mode--ensure-mode)
  (md-mode--back-to-heading)
  (outline-forward-same-level (or count 1)))

;;;###autoload
(defun md-mode-backward-same-level (&optional count)
  "Move backward COUNT Markdown headings at the same level."
  (interactive "p")
  (md-mode--ensure-mode)
  (md-mode--back-to-heading)
  (outline-backward-same-level (or count 1)))

(defun md-mode--heading-entries ()
  "Return Markdown headings as title, level, and target marker plists."
  (let (entries)
    (save-excursion
      (goto-char (point-min))
      (if md-mode--rendered-p
          (while-let
              ((match (text-property-search-forward
                       'md-render-source)))
            (let ((source (prop-match-value match)))
              (when (and (stringp source)
                         (string-match md-mode--heading-regexp source)
                         (= (match-beginning 0) 0))
                (push (list
                       :title (string-trim
                               (substring source (match-end 0)))
                       :level (length (match-string 1 source))
                       :marker (copy-marker
                                (prop-match-beginning match)))
                      entries))))
        (while (md-mode--outline-search)
          (let* ((level (length (match-string 1)))
                 (title (string-trim
                         (buffer-substring-no-properties
                          (point) (line-end-position)))))
            (push (list :title title
                        :level level
                        :marker (copy-marker (match-beginning 0)))
                  entries)))))
    (nreverse entries)))

(defun md-mode--heading-candidates ()
  "Return completion candidates for Markdown headings."
  (mapcar
   (lambda (entry)
     (let ((level (plist-get entry :level))
           (title (plist-get entry :title))
           (marker (plist-get entry :marker)))
       (cons (format "%s %s — line %d"
                     (make-string level ?#)
                     title (line-number-at-pos marker))
             marker)))
   (md-mode--heading-entries)))

(defun md-mode--imenu-node (node)
  "Convert heading tree NODE to an Imenu entry."
  (pcase-let ((`(,entry . ,child-nodes) node))
    (let* ((title (or (plist-get entry :imenu-label)
                      (plist-get entry :title)))
           (marker (plist-get entry :marker))
           (children (mapcar #'md-mode--imenu-node
                             (reverse child-nodes))))
      (if children
          (cons title (cons (cons title marker) children))
        (cons title marker)))))

(defun md-mode--imenu-index ()
  "Return a nested Imenu index for the current Markdown buffer."
  (let ((entries (md-mode--heading-entries))
        (counts (make-hash-table :test #'equal))
        roots stack)
    (dolist (entry entries)
      (let ((title (plist-get entry :title)))
        (puthash title (1+ (gethash title counts 0)) counts)))
    (dolist (entry entries)
      (let ((title (plist-get entry :title)))
        (when (> (gethash title counts) 1)
          (setq entry
                (plist-put
                 entry :imenu-label
                 (format "%s — line %d"
                         title
                         (line-number-at-pos
                          (plist-get entry :marker)))))))
      (let ((level (plist-get entry :level)))
        (while (and stack
                    (pcase-let* ((`(,parent-node . ,_) stack)
                                 (`(,parent-entry . ,_) parent-node))
                      (>= (plist-get parent-entry :level) level)))
          (pop stack))
        (let ((node (list entry)))
          (if stack
              (pcase-let* ((`(,parent-node . ,_) stack)
                           (`(,_ . ,children) parent-node))
                (setcdr parent-node (cons node children)))
            (push node roots))
          (push node stack))))
    (mapcar #'md-mode--imenu-node (nreverse roots))))

(defun md-mode--get-toc-buffer ()
  "Return the TOC buffer for the current Markdown source buffer."
  (unless (buffer-live-p md-mode--toc-buffer)
    (let ((source (current-buffer)))
      (setq md-mode--toc-buffer
            (generate-new-buffer
             (format "*MD TOC: %s*" (buffer-name source))))
      (with-current-buffer md-mode--toc-buffer
        (md-mode--toc-mode)
        (setq md-mode--toc-source-buffer source))))
  md-mode--toc-buffer)

(defun md-mode--toc-release-markers ()
  "Release all heading markers owned by the current TOC buffer."
  (dolist (marker md-mode--toc-markers)
    (set-marker marker nil))
  (setq md-mode--toc-markers nil))

(defun md-mode--toc-refresh ()
  "Refresh the current Markdown TOC buffer."
  (interactive)
  (unless (derived-mode-p 'md-mode--toc-mode)
    (user-error "Not in an md-mode TOC"))
  (unless md-mode--toc-refreshing-p
    (let ((md-mode--toc-refreshing-p t))
      (md-mode--toc-release-markers)
      (let ((source md-mode--toc-source-buffer)
            (inhibit-read-only t))
        (erase-buffer)
        (if (not (buffer-live-p source))
            (insert "Source buffer is no longer available.\n")
          (setq-local header-line-format
                      (format " %s" (buffer-name source)))
          (let ((entries
                 (with-current-buffer source
                   (md-mode--heading-entries))))
            (if (not entries)
                (insert "No headings.\n")
              (dolist (entry entries)
                (let* ((level (plist-get entry :level))
                       (marker (plist-get entry :marker))
                       (begin (point)))
                  (insert (make-string (* 2 (1- level)) ?\s)
                          (plist-get entry :title)
                          "\n")
                  (add-text-properties
                   begin (1- (point))
                   `(md-mode-toc-target ,marker
                     mouse-face highlight
                     help-echo "RET or mouse-1: visit heading"
                     face ((:height 1.0)
                           ,(intern
                             (format "md-render-header-%d"
                                     (min level 6)))
                           ,(intern
                             (format "outline-%d" (min level 8))))))
                  (push marker md-mode--toc-markers))))))
        (when (buffer-live-p source)
          (with-current-buffer source
            (setq md-mode--toc-dirty-p nil))))
      (goto-char (point-min)))))

(defun md-mode--toc-mark-dirty (_begin _end _length)
  "Mark the current source buffer's TOC dirty after a change."
  (when (and (buffer-live-p md-mode--toc-buffer)
             (get-buffer-window md-mode--toc-buffer t))
    (setq md-mode--toc-dirty-p t)))

(defun md-mode--toc-refresh-if-dirty ()
  "Refresh the current source buffer's TOC when it is dirty."
  (when md-mode--toc-dirty-p
    (md-mode--refresh-toc)))

(defun md-mode--refresh-toc ()
  "Refresh the current source buffer's TOC when it is live."
  (when (buffer-live-p md-mode--toc-buffer)
    (with-current-buffer md-mode--toc-buffer
      (md-mode--toc-refresh))))

(defun md-mode--toc-detach ()
  "Detach the current TOC buffer from its Markdown source."
  (md-mode--toc-release-markers)
  (let ((source md-mode--toc-source-buffer)
        (toc (current-buffer)))
    (setq md-mode--toc-source-buffer nil)
    (when (buffer-live-p source)
      (with-current-buffer source
        (when (eq md-mode--toc-buffer toc)
          (setq md-mode--toc-buffer nil
                md-mode--toc-dirty-p nil))))))

(defun md-mode--toc-cleanup ()
  "Remove the TOC associated with the current Markdown source buffer."
  (let ((toc md-mode--toc-buffer))
    (setq md-mode--toc-buffer nil
          md-mode--toc-dirty-p nil)
    (when (buffer-live-p toc)
      (with-current-buffer toc
        (setq md-mode--toc-source-buffer nil)
        (md-mode--toc-release-markers))
      (delete-windows-on toc)
      (kill-buffer toc))))

(defun md-mode--toc-target-at-point ()
  "Return the heading marker on the current TOC line."
  (or (get-text-property (point) 'md-mode-toc-target)
      (let ((end (line-end-position)))
        (and (> end (line-beginning-position))
             (get-text-property (1- end)
                                'md-mode-toc-target)))))

(defun md-mode--toc-visit ()
  "Visit the Markdown heading on the current TOC line."
  (interactive)
  (let ((target (md-mode--toc-target-at-point)))
    (unless (and (markerp target)
                 (marker-buffer target)
                 (marker-position target))
      (user-error "No live Markdown heading on this line"))
    (let ((source (marker-buffer target)))
      (if-let* ((window (get-buffer-window source)))
          (select-window window)
        (pop-to-buffer source))
      (goto-char target)
      (unless md-mode--rendered-p
        (outline-show-entry))
      (beginning-of-line))))

(defun md-mode--toc-mouse-visit (event)
  "Visit the Markdown heading clicked by mouse EVENT."
  (interactive "e")
  (mouse-set-point event)
  (md-mode--toc-visit))

(defun md-mode--toc-quit ()
  "Close the selected Markdown TOC window."
  (interactive)
  (quit-window nil (selected-window)))

;;;###autoload
(defun md-mode-toggle-toc ()
  "Toggle the table of contents for the current Markdown buffer."
  (interactive)
  (md-mode--ensure-mode)
  (let* ((toc (md-mode--get-toc-buffer))
         (window (get-buffer-window toc)))
    (if window
        (delete-window window)
      (with-current-buffer toc
        (md-mode--toc-refresh))
      (display-buffer-in-side-window
       toc
       `((side . ,md-mode-toc-side)
         (slot . 0)
         (window-width . ,(max 1 md-mode-toc-width))
         (preserve-size . (t . nil)))))))

;;;###autoload
(defun md-mode-goto-heading (position)
  "Go to the Markdown heading at POSITION."
  (interactive
   (let* ((candidates (md-mode--heading-candidates))
          (_ (unless candidates
               (user-error "No Markdown headings")))
          (choice (completing-read
                   "Heading: " candidates nil t)))
     (list (cdr (assoc choice candidates)))))
  (md-mode--ensure-mode)
  (goto-char position)
  (beginning-of-line))

;;;###autoload
(defun md-mode-mark-subtree ()
  "Mark the current Markdown heading subtree."
  (interactive)
  (md-mode--ensure-mode)
  (md-mode--back-to-heading)
  (outline-mark-subtree))

(defun md-mode--fenced-block-bounds ()
  "Return bounds of the fenced block at point."
  (let ((origin (line-beginning-position))
        opening)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward md-mode--fence-regexp origin t)
        (setq opening (and (not opening) (match-beginning 0))))
      (goto-char origin)
      (cond
       ((looking-at md-mode--fence-regexp)
        (if opening
            (cons opening
                  (min (point-max) (1+ (line-end-position))))
          (let ((begin origin))
            (forward-line 1)
            (if (re-search-forward md-mode--fence-regexp nil t)
                (cons begin
                      (min (point-max) (1+ (line-end-position))))
              (cons begin (point-max))))))
       (opening
        (if (re-search-forward md-mode--fence-regexp nil t)
            (cons opening
                  (min (point-max) (1+ (line-end-position))))
          (cons opening (point-max))))))))

(defun md-mode--blockquote-bounds ()
  "Return bounds of the Markdown blockquote at point."
  (save-excursion
    (beginning-of-line)
    (when (looking-at-p "[ \t]*>")
      (while (and (= (forward-line -1) 0)
                  (looking-at-p "[ \t]*>")))
      (unless (looking-at-p "[ \t]*>")
        (forward-line 1))
      (let ((begin (point)))
        (while (and (not (eobp))
                    (looking-at-p "[ \t]*>"))
          (forward-line 1))
        (cons begin (point))))))

(defun md-mode--element-bounds ()
  "Return bounds of the Markdown element at point."
  (or (let ((bounds (md-mode--table-bounds)))
        (and bounds (cons (nth 0 bounds) (nth 1 bounds))))
      (md-mode--fenced-block-bounds)
      (md-mode--blockquote-bounds)
      (when-let* ((info (md-mode--list-item-info)))
        (cons (plist-get info :begin) (plist-get info :end)))
      (when (md-mode--heading-level-at-point)
        (cons (line-beginning-position)
              (save-excursion
                (outline-end-of-subtree)
                (min (point-max) (1+ (point))))))
      (save-excursion
        (let ((end (progn (forward-paragraph) (point))))
          (backward-paragraph)
          (cons (point) end)))))

;;;###autoload
(defun md-mode-mark-element ()
  "Mark the Markdown element at point."
  (interactive)
  (md-mode--ensure-mode)
  (pcase-let ((`(,begin . ,end) (md-mode--element-bounds)))
    (goto-char begin)
    (push-mark end nil t)))

(defun md-mode--take-region ()
  "Delete and return the active region, or nil when none is active."
  (when (use-region-p)
    (let ((text (buffer-substring-no-properties
                 (region-beginning) (region-end))))
      (delete-region (region-beginning) (region-end))
      text)))

(defun md-mode--link-destination (target)
  "Return a Markdown link destination for TARGET."
  (if (string-match-p "[ \t()]" target)
      (format "<%s>" target)
    target))

(defun md-mode--link-at-point ()
  "Return the Markdown link surrounding point."
  (let ((position (point))
        found)
    (save-excursion
      (beginning-of-line)
      (while (and (not found)
                  (re-search-forward
                   md-mode--link-regexp (line-end-position) t))
        (when (<= (match-beginning 0) position (match-end 0))
          (let* ((image (equal (match-string 1) "!"))
                 (target (or (match-string-no-properties 3)
                             (match-string-no-properties 4)))
                 (type
                  (cond
                   (image 'image)
                   ((string-prefix-p "mailto:" target) 'email)
                   ((string-match-p "\\`https?://" target) 'web)
                   (t 'file))))
            (setq found
                  (list :begin (match-beginning 0)
                        :end (match-end 0)
                        :type type
                        :label (match-string-no-properties 2)
                        :target target))))))
    found))

;;;###autoload
(defun md-mode-insert-link (type target &optional label)
  "Insert a Markdown TYPE link to TARGET with optional LABEL.

TYPE is one of `web', `file', `email', or `image'.  An active
region is used as the label.  Replace the link at point when one
is present."
  (interactive
   (let* ((existing (md-mode--link-at-point))
          (type (or (plist-get existing :type)
                    (intern
                     (completing-read
                      "Link type: " '("web" "file" "email")
                      nil t nil nil "web"))))
          (target
           (if existing
               (read-string "Target: "
                            (plist-get existing :target))
             (pcase type
               ('file
                (file-relative-name
                 (read-file-name "File: " nil nil t)
                 default-directory))
               ('email (read-string "Email: "))
               (_ (read-string "URL: ")))))
          (default
           (or (plist-get existing :label)
               (pcase type
                 ((or 'file 'image)
                  (file-name-nondirectory target))
                 ('email (string-remove-prefix "mailto:" target))
                 (_ target))))
          (label
           (unless (use-region-p)
             (read-string "Label: " nil nil default))))
     (list type target label)))
  (md-mode--ensure-mode)
  (let* ((existing (md-mode--link-at-point))
         (region (unless existing (md-mode--take-region)))
         (destination
          (pcase type
            ('email (concat "mailto:"
                            (string-remove-prefix "mailto:" target)))
            ((or 'web 'file 'image) target)
            (_ (user-error "Unknown link type: %s" type))))
         (text (or region label
                   (if (memq type '(file image))
                       (file-name-nondirectory target)
                     (string-remove-prefix "mailto:" target))))
         (prefix (if (eq type 'image) "!" "")))
    (when existing
      (delete-region (plist-get existing :begin)
                     (plist-get existing :end))
      (goto-char (plist-get existing :begin)))
    (insert prefix "[" text "]("
            (md-mode--link-destination destination) ")")))

;;;###autoload
(defun md-mode-insert-image (target &optional alt)
  "Insert a Markdown image for TARGET with optional ALT text.

An active region is used as the alt text."
  (interactive
   (let ((target (read-string "Image URL or file: ")))
     (list target
           (unless (use-region-p)
             (read-string "Alt text: " nil nil
                          (file-name-base target))))))
  (md-mode-insert-link 'image target alt))

;;;###autoload
(defun md-mode-open-at-point ()
  "Open the Markdown link at point."
  (interactive)
  (md-mode--ensure-mode)
  (if-let* ((link (md-mode--link-at-point))
            (target (plist-get link :target)))
      (if (string-match-p
           "\\`[[:alpha:]][[:alnum:]+.-]*:" target)
          (browse-url target)
        (find-file (expand-file-name target default-directory)))
    (user-error "No Markdown link at point")))

;;;###autoload
(defun md-mode-insert-blockquote ()
  "Quote the active region or current Markdown line."
  (interactive)
  (md-mode--ensure-mode)
  (if-let* ((text (md-mode--take-region)))
      (insert (replace-regexp-in-string "^" "> " text))
    (beginning-of-line)
    (insert "> ")))

;;;###autoload
(defun md-mode-insert-code (&optional block language)
  "Insert Markdown code markup.

Wrap a single-line region as inline code.  Wrap a multiline
region, or use prefix argument BLOCK, as a fenced block labeled
with optional LANGUAGE."
  (interactive
   (let* ((multiline
           (and (use-region-p)
                (string-match-p
                 "\n"
                 (buffer-substring-no-properties
                  (region-beginning) (region-end)))))
          (block (or current-prefix-arg multiline)))
     (list block
           (and block (read-string "Language (optional): ")))))
  (md-mode--ensure-mode)
  (let ((text (md-mode--take-region)))
    (setq block (or block (and text (string-match-p "\n" text))))
    (if (not block)
        (if text
            (insert "`" text "`")
          (insert "``")
          (backward-char))
      (insert "```" (or language "") "\n")
      (let ((body-start (point)))
        (when text
          (insert text))
        (unless (bolp)
          (insert "\n"))
        (insert "```")
        (unless text
          (goto-char body-start))))))

;;;###autoload
(defun md-mode-insert-callout (type)
  "Insert a GitHub-style Markdown callout of TYPE.

When the region is active, use its lines as the callout body."
  (interactive
   (list (completing-read
          "Callout type: " md-mode--callout-types
          nil t nil nil "NOTE")))
  (md-mode--ensure-mode)
  (setq type (upcase type))
  (unless (member type md-mode--callout-types)
    (user-error "Unknown callout type: %s" type))
  (let ((text (md-mode--take-region)))
    (insert "> [!" type "]\n> ")
    (when text
      (insert (replace-regexp-in-string "\n" "\n> " text)))))

(defun md-mode--split-table-row (line)
  "Return Markdown cells parsed from LINE, or nil when it has no pipe."
  (let ((backslashes 0)
        (begin 0)
        cells)
    (dotimes (index (length line))
      (let ((character (aref line index)))
        (cond
         ((eq character ?\\)
          (setq backslashes (1+ backslashes)))
         ((eq character ?|)
          (when (zerop (% backslashes 2))
            (push (substring line begin index) cells)
            (setq begin (1+ index)))
          (setq backslashes 0))
         (t
          (setq backslashes 0)))))
    (when cells
      (push (substring line begin) cells)
      (setq cells (nreverse cells))
      (when (string-empty-p (string-trim (car cells)))
        (setq cells (cdr cells)))
      (when (and cells
                 (string-empty-p (string-trim (car (last cells)))))
        (setq cells (butlast cells)))
      (mapcar #'string-trim cells))))

(defun md-mode--table-row-cells ()
  "Return Markdown cells on the current line, or nil."
  (md-mode--split-table-row
   (buffer-substring-no-properties
    (line-beginning-position) (line-end-position))))

(defun md-mode--separator-cells-p (cells)
  "Return non-nil when CELLS form a Markdown table separator."
  (and cells
       (let ((valid t))
         (dolist (cell cells valid)
           (unless (string-match-p "\\`:?-\\{3,\\}:?\\'" cell)
             (setq valid nil))))))

(defun md-mode--table-separator-line-p ()
  "Return non-nil when point is on a Markdown table separator."
  (md-mode--separator-cells-p (md-mode--table-row-cells)))

(defun md-mode--table-bounds ()
  "Return (BEGIN END COLUMNS) for the Markdown table at point."
  (save-excursion
    (beginning-of-line)
    (let ((origin (point))
          separator)
      (cond
       ((md-mode--table-separator-line-p)
        (setq separator (point)))
       ((save-excursion
          (forward-line 1)
          (when (md-mode--table-separator-line-p)
            (setq separator (line-beginning-position)))))
       (t
        (let ((searching t))
          (while (and searching (md-mode--table-row-cells))
            (if (md-mode--table-separator-line-p)
                (setq separator (point)
                      searching nil)
              (unless (= (forward-line -1) 0)
                (setq searching nil)))))))
      (when separator
        (goto-char separator)
        (let ((separator-cells (md-mode--table-row-cells)))
          (when (= (forward-line -1) 0)
            (let ((begin (point))
                  (header-cells (md-mode--table-row-cells)))
              (when (and (= (length header-cells)
                            (length separator-cells))
                         (not (md-mode--inside-fenced-block-p separator)))
                (goto-char separator)
                (forward-line 1)
                (while (and (< (point) (point-max))
                            (md-mode--table-row-cells))
                  (forward-line 1))
                (when (and (>= origin begin) (< origin (point)))
                  (list begin (point) (length separator-cells)))))))))))

(defun md-mode--table-line-p ()
  "Return non-nil when point is in a Markdown table."
  (and (md-mode--table-bounds) t))

(defun md-mode--match-table-header (limit)
  "Find a Markdown table header before LIMIT."
  (let (matched)
    (while (and (not matched)
                (re-search-forward md-mode--table-row-regexp limit t))
      (let ((begin (match-beginning 0))
            (end (match-end 0)))
        (when (and (not (md-mode--inside-fenced-block-p begin))
                   (save-excursion
                     (goto-char begin)
                     (let ((bounds (md-mode--table-bounds)))
                       (and bounds (= begin (car bounds))))))
          (set-match-data (list begin end))
          (setq matched t))))
    matched))

(defun md-mode--match-table-row (limit)
  "Find a Markdown table row before LIMIT."
  (let (matched)
    (while (and (not matched)
                (re-search-forward md-mode--table-row-regexp limit t))
      (let ((begin (match-beginning 0))
            (end (match-end 0)))
        (when (md-mode--table-line-p)
          (set-match-data (list begin end))
          (setq matched t))))
    matched))

(defun md-mode--table-marker-display (position end)
  "Return box-drawing display for table marker from POSITION to END."
  (if (eq (char-after position) ?-)
      (propertize
       (make-string (- end position) ?\s)
       'face '(md-render-table-border fixed-pitch (:strike-through t)))
    (if (not (md-mode--table-separator-line-p))
        "│"
      (let ((line-begin (line-beginning-position))
            (line-end (line-end-position)))
        (cond
         ((save-excursion
            (goto-char position)
            (skip-chars-backward " \t" line-begin)
            (= (point) line-begin))
          "├")
         ((save-excursion
            (goto-char (1+ position))
            (skip-chars-forward " \t" line-end)
            (= (point) line-end))
          "┤")
         (t "┼"))))))

(defun md-mode--match-table-marker (limit)
  "Find and display a Markdown table marker before LIMIT."
  (let (matched)
    (while (and (not matched)
                (re-search-forward "|\\|-+" limit t))
      (let ((begin (match-beginning 0))
            (end (match-end 0)))
        (when (and (md-mode--table-line-p)
                   (or (eq (char-after begin) ?|)
                       (md-mode--table-separator-line-p))
                   (or (not (eq (char-after begin) ?|))
                       (not (md-mode--escaped-p begin))))
          (with-silent-modifications
            (put-text-property
             begin end 'display
             (md-mode--table-marker-display begin end)))
          (set-match-data (list begin end))
          (setq matched t))))
    matched))

(defun md-mode--match-table-padding (limit)
  "Find table padding before LIMIT and align its following pipe."
  (let (matched)
    (while (and (not matched)
                (re-search-forward "[ \t]+|" limit t))
      (let ((begin (match-beginning 0))
            (pipe (1- (match-end 0))))
        (when (and (md-mode--table-line-p)
                   (not (md-mode--table-separator-line-p))
                   (not (md-mode--escaped-p pipe)))
          (when (and (display-graphic-p)
                     (fboundp 'string-pixel-width))
            (let* ((line-begin (line-beginning-position))
                   (columns
                    (string-width
                     (buffer-substring-no-properties line-begin pipe)))
                   (target (* columns
                              (string-pixel-width
                               (propertize " " 'face 'fixed-pitch))))
                   (content
                    (string-pixel-width
                     (buffer-substring line-begin begin)))
                   (padding (- target content)))
              (when (> padding 0)
                (with-silent-modifications
                  (put-text-property
                   begin pipe 'display
                   `(space :width (,padding)))))))
          (set-match-data (list begin pipe))
          (setq matched t))))
    matched))

;; Adapted from lte.el's window-local overlay model:
;; https://github.com/fredericgiquel/lte.el
(defun md-mode--visual-line-end-position ()
  "Return the visible end of the current line."
  (let ((truncate-lines t))
    (save-excursion
      (end-of-visual-line)
      (point))))

(defun md-mode--table-regions (start end)
  "Return Markdown table regions intersecting START and END."
  (save-excursion
    (goto-char start)
    (beginning-of-line)
    (let (regions)
      (while (< (point) end)
        (let ((bounds (md-mode--table-bounds)))
          (if bounds
              (progn
                (push (cons (nth 0 bounds) (nth 1 bounds)) regions)
                (goto-char (nth 1 bounds)))
            (forward-line 1))))
      (nreverse regions))))

(defun md-mode--remove-table-overflow (start end window)
  "Remove table overflow overlays between START and END for WINDOW."
  (dolist (overlay (overlays-in start end))
    (when (and (eq (overlay-get overlay 'category)
                   'md-mode-table-overflow)
               (eq (overlay-get overlay 'window) window))
      (delete-overlay overlay))))

(defun md-mode--add-table-overflow (start end window)
  "Add table overflow overlays between START and END for WINDOW."
  (with-selected-window window
    (save-excursion
      (goto-char start)
      (while (< (point) end)
        (let ((visible-end (md-mode--visual-line-end-position))
              (line-end (line-end-position)))
          (when (< visible-end line-end)
            (let ((overlay
                   (make-overlay
                    (max (line-beginning-position) (1- visible-end))
                    line-end)))
              (overlay-put overlay 'category 'md-mode-table-overflow)
              (overlay-put overlay 'display
                           (if (display-graphic-p)
                               '(right-fringe md-mode--table-overflow-dots)
                             '(right-margin "…")))
              (overlay-put overlay 'invisible t)
              (overlay-put overlay 'window window)
              (overlay-put overlay 'evaporate t))))
        (forward-line 1)))))

(defun md-mode--truncate-tables-in-region (start end)
  "Refresh wide table overlays between START and END."
  (let ((regions (md-mode--table-regions start end)))
    (dolist (window (get-buffer-window-list (current-buffer) nil t))
      (dolist (region regions)
        (md-mode--remove-table-overflow
         (car region) (cdr region) window)
        (md-mode--add-table-overflow
         (car region) (cdr region) window)))))

(defun md-mode--truncate-tables-in-buffer ()
  "Refresh wide table overlays in the current buffer."
  (remove-overlays
   (point-min) (point-max) 'category 'md-mode-table-overflow)
  (md-mode--truncate-tables-in-region (point-min) (point-max)))

(defun md-mode--stop-table-overflow ()
  "Stop refreshing and remove table overflow overlays."
  (jit-lock-unregister #'md-mode--truncate-tables-in-region)
  (remove-overlays
   (point-min) (point-max) 'category 'md-mode-table-overflow))

(defun md-mode--syntax-propertize-extend-region (start end)
  "Extend syntax propertization from START and END to whole lines."
  (cons (save-excursion
          (goto-char start)
          (line-beginning-position))
        (save-excursion
          (goto-char end)
          (min (point-max) (1+ (line-end-position))))))

(defun md-mode--syntax-propertize (start end)
  "Mark fenced code block delimiters between START and END."
  (goto-char start)
  (let ((opening (not (md-mode--inside-fenced-block-p start))))
    (while (re-search-forward md-mode--fence-regexp end t)
      (let ((position (match-beginning 1)))
        (put-text-property
         position (1+ position) 'syntax-table
         (string-to-syntax (if opening "< b" "> b")))
        (setq opening (not opening))))))

(defun md-mode--syntactic-face (state)
  "Return the face for syntactic parse STATE."
  (when (nth 4 state)
    'md-render-source-block))

(defconst md-mode--font-lock-keywords
  `(("^[ \t]*```.*$" (0 'md-render-source-block-language t))
    ("^[ \t]*>[ \t]+\\(\\[!\\(?:NOTE\\|TIP\\|IMPORTANT\\|WARNING\\|CAUTION\\)\\]\\)"
     (1 'md-mode-callout prepend))
    ("^\\(######\\)[ \t]+\\(.+\\)$"
     (1 'md-mode-markup) (2 'md-render-header-6))
    ("^\\(#####\\)[ \t]+\\(.+\\)$"
     (1 'md-mode-markup) (2 'md-render-header-5))
    ("^\\(####\\)[ \t]+\\(.+\\)$"
     (1 'md-mode-markup) (2 'md-render-header-4))
    ("^\\(###\\)[ \t]+\\(.+\\)$"
     (1 'md-mode-markup) (2 'md-render-header-3))
    ("^\\(##\\)[ \t]+\\(.+\\)$"
     (1 'md-mode-markup) (2 'md-render-header-2))
    ("^\\(#\\)[ \t]+\\(.+\\)$"
     (1 'md-mode-markup) (2 'md-render-header-1))
    ("\\(`\\)\\([^`\n]+\\)\\(`\\)"
     (1 'md-mode-markup) (2 'md-render-inline-code)
     (3 'md-mode-markup))
    ("\\(\\*\\*\\)\\([^*\n]+\\)\\(\\*\\*\\)"
     (1 'md-mode-markup) (2 'md-render-bold) (3 'md-mode-markup))
    ("\\(__\\)\\([^_\n]+\\)\\(__\\)"
     (1 'md-mode-markup) (2 'md-render-bold) (3 'md-mode-markup))
    ("\\(~~\\)\\([^~\n]+\\)\\(~~\\)"
     (1 'md-mode-markup) (2 'md-render-strikethrough)
     (3 'md-mode-markup))
    ("\\(?:^\\|[^*]\\)\\(\\*\\)\\([^*\n]+\\)\\(\\*\\)"
     (1 'md-mode-markup) (2 'md-render-italic)
     (3 'md-mode-markup))
    ("\\(?:^\\|[^[:alnum:]_]\\)\\(_\\)\\([^_\n]+\\)\\(_\\)"
     (1 'md-mode-markup) (2 'md-render-italic)
     (3 'md-mode-markup))
    ("!?\\[\\([^]\n]+\\)\\](\\([^) \n]+\\))"
     (1 'md-render-link) (2 'md-mode-markup))
    ("^[ \t]*>+[ \t]+\\(.+\\)$"
     (1 'md-render-blockquote))
    (md-mode--match-table-header
     (0 'md-render-table-header prepend))
    (md-mode--match-table-marker
     (0 'md-render-table-border prepend))
    (md-mode--match-table-row
     (0 'fixed-pitch prepend))
    md-mode--match-table-padding)
  "Font-lock rules for editable Markdown source.")

(defun md-mode--ensure-mode ()
  "Signal a user error unless the current buffer uses `md-mode'."
  (unless (derived-mode-p 'md-mode)
    (user-error "Not in md-mode")))

(defun md-mode--set-rendered-p (rendered)
  "Set the current buffer's rendered state to RENDERED."
  (setq md-mode--rendered-p rendered
        buffer-read-only rendered
        mode-name (if rendered "MD View" "MD")
        font-lock-extra-managed-props
        (if rendered
            (delq 'display font-lock-extra-managed-props)
          (cons 'display
                (delq 'display font-lock-extra-managed-props))))
  (force-mode-line-update))

(defun md-mode--escaped-p (position)
  "Return non-nil when the character at POSITION is escaped."
  (let ((backslashes 0))
    (while (and (> position (line-beginning-position))
                (eq (char-before position) ?\\))
      (setq backslashes (1+ backslashes)
            position (1- position)))
    (= (% backslashes 2) 1)))

(defun md-mode--table-alignment (separator)
  "Return the Markdown alignment declared by SEPARATOR."
  (cond
   ((and (string-prefix-p ":" separator)
         (string-suffix-p ":" separator))
    'center)
   ((string-suffix-p ":" separator)
    'right)
   (t 'left)))

(defun md-mode--format-table-cell (cell width alignment)
  "Pad CELL to display WIDTH using Markdown ALIGNMENT."
  (let* ((padding (- width (string-width cell)))
         (left (pcase alignment
                 ('right (1- padding))
                 ('center (/ padding 2))
                 (_ 1)))
         (right (- padding left)))
    (concat (make-string left ?\s)
            cell
            (make-string right ?\s))))

(defun md-mode--format-table-separator (separator width)
  "Format Markdown SEPARATOR to display WIDTH."
  (let* ((left (string-prefix-p ":" separator))
         (right (string-suffix-p ":" separator))
         (dashes (- width (if left 1 0) (if right 1 0))))
    (concat (and left ":")
            (make-string dashes ?-)
            (and right ":"))))

(defun md-mode--table-rows (begin end)
  "Return parsed table rows between BEGIN and END."
  (save-excursion
    (goto-char begin)
    (let (rows)
      (while (< (point) end)
        (let* ((line (buffer-substring-no-properties
                      (line-beginning-position) (line-end-position)))
               (indent (progn
                         (string-match "\\`[ \t]*" line)
                         (match-string 0 line))))
          (push (cons indent (md-mode--split-table-row line)) rows))
        (forward-line 1))
      (nreverse rows))))

(defun md-mode--format-table (rows columns)
  "Return aligned Markdown for ROWS with COLUMNS columns."
  (let ((alignments (make-vector columns 'left))
        (widths (make-vector columns 3))
        (separator-cells (cdr (nth 1 rows))))
    (dotimes (column columns)
      (let* ((separator (nth column separator-cells))
             (alignment (md-mode--table-alignment separator))
             (minimum (+ 3
                         (if (string-prefix-p ":" separator) 1 0)
                         (if (string-suffix-p ":" separator) 1 0))))
        (aset alignments column alignment)
        (aset widths column (max (aref widths column) minimum))))
    (let ((row-number 0))
      (dolist (row rows)
        (unless (= row-number 1)
          (dotimes (column columns)
            (aset widths column
                  (max (aref widths column)
                       (+ 2 (string-width
                             (or (nth column (cdr row)) "")))))))
        (setq row-number (1+ row-number))))
    (let ((row-number 0)
          formatted)
      (dolist (row rows)
        (let (cells)
          (dotimes (column columns)
            (push
             (if (= row-number 1)
                 (md-mode--format-table-separator
                  (nth column separator-cells)
                  (aref widths column))
               (md-mode--format-table-cell
                (or (nth column (cdr row)) "")
                (aref widths column)
                (aref alignments column)))
             cells))
          (dolist (extra (nthcdr columns (cdr row)))
            (push (concat " " extra " ") cells))
          (push (concat (car row) "|"
                        (mapconcat #'identity (nreverse cells) "|")
                        "|")
                formatted))
        (setq row-number (1+ row-number)))
      (mapconcat #'identity (nreverse formatted) "\n"))))

(defun md-mode--table-context ()
  "Return the Markdown table context at point."
  (when-let* ((bounds (md-mode--table-bounds)))
    (let ((columns (nth 2 bounds)))
      (list :bounds bounds
            :row (count-lines
                  (nth 0 bounds) (line-beginning-position))
            :column (min (1- columns)
                         (md-mode--table-cell-index))
            :rows (md-mode--table-rows
                   (nth 0 bounds) (nth 1 bounds))
            :columns columns))))

(defun md-mode--replace-table-rows
    (bounds rows row column)
  "Replace table BOUNDS with ROWS and move to ROW and COLUMN."
  (let* ((begin (nth 0 bounds))
         (source (buffer-substring-no-properties
                  begin (nth 1 bounds)))
         (newline (string-suffix-p "\n" source))
         (formatted
          (concat (md-mode--format-table
                   rows (length (cdr (car rows))))
                  (and newline "\n"))))
    (goto-char begin)
    (delete-region begin (nth 1 bounds))
    (insert formatted)
    (font-lock-flush begin (+ begin (length formatted)))
    (md-mode--goto-table-cell begin row column)))

;;;###autoload
(defun md-mode-insert-table (columns rows)
  "Insert a Markdown table with COLUMNS and ROWS body rows."
  (interactive
   (let ((size (read-string
                "Table size (columns x body rows): " nil nil "3 x 2")))
     (unless
         (string-match
          "\\`[ \t]*\\([1-9][0-9]*\\)[ \t]*[xX×][ \t]*\\([1-9][0-9]*\\)[ \t]*\\'"
          size)
       (user-error "Invalid table size: %s" size))
     (list (string-to-number (match-string 1 size))
           (string-to-number (match-string 2 size)))))
  (md-mode--ensure-mode)
  (when md-mode--rendered-p
    (user-error "Table editing is unavailable in rendered view"))
  (unless (and (integerp columns) (> columns 0)
               (integerp rows) (> rows 0))
    (user-error "Table dimensions are not positive integers"))
  (when (md-mode--inside-fenced-block-p (point))
    (user-error "Inside a fenced code block"))
  (let* ((line (buffer-substring-no-properties
                (line-beginning-position) (line-end-position)))
         (blank (string-match-p "\\`[ \t]*\\'" line))
         (indent (if blank line ""))
         (empty-row (cons indent (make-list columns "")))
         (table (md-mode--format-table
                 (append
                  (list empty-row
                        (cons indent (make-list columns "---")))
                  (make-list rows empty-row))
                 columns)))
    (if blank
        (delete-region (line-beginning-position) (line-end-position))
      (end-of-line)
      (insert "\n"))
    (let ((begin (point)))
      (insert table)
      (font-lock-flush begin (point))
      (goto-char begin)
      (search-forward "|" (line-end-position))
      (when (eq (char-after) ?\s)
        (forward-char)))))

;;;###autoload
(defun md-mode-delete-table ()
  "Delete the complete Markdown table at point."
  (interactive)
  (md-mode--ensure-mode)
  (when md-mode--rendered-p
    (user-error "Table editing is unavailable in rendered view"))
  (if-let* ((bounds (md-mode--table-bounds)))
      (progn
        (delete-region (nth 0 bounds) (nth 1 bounds))
        (font-lock-flush))
    (user-error "Not in a Markdown table")))

(defun md-mode--swap-table-cells (row from to)
  "Return ROW with cells FROM and TO exchanged."
  (let* ((cells (vconcat (cdr row)))
         (value (aref cells from)))
    (aset cells from (aref cells to))
    (aset cells to value)
    (cons (car row) (append cells nil))))

(defun md-mode--move-table-column (direction)
  "Move the current Markdown table column in DIRECTION."
  (if-let* ((context (md-mode--table-context)))
      (let* ((column (plist-get context :column))
             (target (+ column direction))
             (columns (plist-get context :columns)))
        (unless (< -1 target columns)
          (user-error "No table column in that direction"))
        (md-mode--replace-table-rows
         (plist-get context :bounds)
         (mapcar
          (lambda (row)
            (md-mode--swap-table-cells row column target))
          (plist-get context :rows))
         (plist-get context :row) target))
    (user-error "Not in a Markdown table")))

(defun md-mode--move-table-row (direction)
  "Move the current Markdown table row in DIRECTION."
  (if-let* ((context (md-mode--table-context)))
      (let* ((row (plist-get context :row))
             (target (+ row direction))
             (rows (vconcat (plist-get context :rows))))
        (when (< row 2)
          (user-error "Header rows cannot be moved"))
        (unless (< 1 target (length rows))
          (user-error "No table row in that direction"))
        (let ((value (aref rows row)))
          (aset rows row (aref rows target))
          (aset rows target value))
        (md-mode--replace-table-rows
         (plist-get context :bounds)
         (append rows nil) target
         (plist-get context :column)))
    (user-error "Not in a Markdown table")))

;;;###autoload
(defun md-mode-insert-table-column ()
  "Insert a Markdown table column after the current column."
  (interactive)
  (md-mode--ensure-mode)
  (if-let* ((context (md-mode--table-context)))
      (let ((column (1+ (plist-get context :column)))
            (row-number 0)
            rows)
        (dolist (row (plist-get context :rows))
          (let ((value (if (= row-number 1) "---" "")))
            (push
             (cons (car row)
                   (append
                    (seq-take (cdr row) column)
                    (list value)
                    (seq-drop (cdr row) column)))
             rows))
          (setq row-number (1+ row-number)))
        (md-mode--replace-table-rows
         (plist-get context :bounds)
         (nreverse rows) (plist-get context :row) column))
    (user-error "Not in a Markdown table")))

;;;###autoload
(defun md-mode-delete-table-column ()
  "Delete the current Markdown table column."
  (interactive)
  (md-mode--ensure-mode)
  (if-let* ((context (md-mode--table-context)))
      (let* ((column (plist-get context :column))
             (columns (plist-get context :columns)))
        (when (= columns 1)
          (user-error "Cannot delete the only table column"))
        (md-mode--replace-table-rows
         (plist-get context :bounds)
         (mapcar
          (lambda (row)
            (cons (car row)
                  (append
                   (seq-take (cdr row) column)
                   (seq-drop (cdr row) (1+ column)))))
          (plist-get context :rows))
         (plist-get context :row)
         (min column (- columns 2))))
    (user-error "Not in a Markdown table")))

;;;###autoload
(defun md-mode-insert-table-row ()
  "Insert a Markdown table row after the current row."
  (interactive)
  (md-mode--ensure-mode)
  (if-let* ((context (md-mode--table-context)))
      (pcase-let* ((rows (plist-get context :rows))
                   (`((,indent . ,_) . ,_) rows)
                   (row (max 2 (1+ (plist-get context :row))))
                   (new-row
                    (cons indent
                          (make-list (plist-get context :columns) ""))))
        (md-mode--replace-table-rows
         (plist-get context :bounds)
         (append (seq-take rows row)
                 (list new-row)
                 (seq-drop rows row))
         row (plist-get context :column)))
    (user-error "Not in a Markdown table")))

;;;###autoload
(defun md-mode-delete-table-row ()
  "Delete the current Markdown table row."
  (interactive)
  (md-mode--ensure-mode)
  (if-let* ((context (md-mode--table-context)))
      (let* ((row (plist-get context :row))
             (rows (plist-get context :rows)))
        (when (< row 2)
          (user-error "Header rows cannot be deleted"))
        (setq rows (append (seq-take rows row)
                           (seq-drop rows (1+ row))))
        (md-mode--replace-table-rows
         (plist-get context :bounds) rows
         (if (> (length rows) 2)
             (min row (1- (length rows)))
           0)
         (plist-get context :column)))
    (user-error "Not in a Markdown table")))

(defun md-mode--align-table-at-point (&optional bounds)
  "Align the Markdown table at point using optional BOUNDS."
  (let* ((bounds (or bounds (md-mode--table-bounds)))
         (begin (nth 0 bounds))
         (end (nth 1 bounds))
         (source (buffer-substring-no-properties begin end))
         (newline (string-suffix-p "\n" source))
         (formatted (concat
                     (md-mode--format-table
                      (md-mode--table-rows begin end)
                      (nth 2 bounds))
                     (and newline "\n"))))
    (unless (equal source formatted)
      (goto-char begin)
      (delete-region begin end)
      (insert formatted))
    (+ begin (length formatted))))

;;;###autoload
(defun md-mode-table ()
  "Align the table at point, or create one outside a table."
  (interactive)
  (md-mode--ensure-mode)
  (when md-mode--rendered-p
    (user-error "Table editing is unavailable in rendered view"))
  (if-let* ((bounds (md-mode--table-bounds)))
      (let ((begin (nth 0 bounds))
            end)
        (save-excursion
          (setq end (md-mode--align-table-at-point bounds)))
        (font-lock-flush begin end))
    (call-interactively #'md-mode-insert-table)))

(defun md-mode--table-cell-index ()
  "Return the zero-based Markdown table cell index at point."
  (let ((end (point))
        (position (line-beginning-position))
        (pipes 0)
        (leading nil))
    (save-excursion
      (goto-char position)
      (skip-chars-forward " \t")
      (setq leading (eq (char-after) ?|))
      (while (search-forward "|" end t)
        (unless (md-mode--escaped-p (1- (point)))
          (setq pipes (1+ pipes)))))
    (max 0 (- pipes (if leading 1 0)))))

(defun md-mode--goto-table-cell (begin row column)
  "Move to COLUMN in table ROW starting at BEGIN."
  (goto-char begin)
  (forward-line row)
  (let ((remaining (1+ column)))
    (while (> remaining 0)
      (search-forward "|" (line-end-position) t)
      (unless (md-mode--escaped-p (1- (point)))
        (setq remaining (1- remaining)))))
  (skip-chars-forward " "))

;;;###autoload
(defun md-mode-align-tables ()
  "Align every Markdown table in the current buffer."
  (interactive)
  (md-mode--ensure-mode)
  (save-restriction
    (widen)
    (save-excursion
      (goto-char (point-min))
      (while (< (point) (point-max))
        (let ((bounds (md-mode--table-bounds)))
          (if (and bounds (= (point) (car bounds)))
              (goto-char (md-mode--align-table-at-point bounds))
            (forward-line 1))))))
  (font-lock-flush))

(defun md-mode--auto-align-tables ()
  "Align tables without changing the buffer's modification state."
  (when md-mode-auto-align-tables
    (let ((modified (buffer-modified-p))
          (buffer-undo-list t)
          (inhibit-read-only t))
      (md-mode-align-tables)
      (set-buffer-modified-p modified))))

;;;###autoload
(defun md-mode-tab ()
  "Cycle a heading, advance in a table, or indent normally."
  (interactive)
  (let ((table-bounds (md-mode--table-bounds))
        (block-bounds (md-mode--block-fold-bounds)))
    (cond
     (table-bounds
      (let* ((begin (car table-bounds))
             (row (count-lines begin (line-beginning-position)))
             (column (md-mode--table-cell-index))
             (columns (nth 2 table-bounds))
             (rows (count-lines begin (nth 1 table-bounds)))
             (next-column (1+ column))
             (next-row row))
        (when (or (= row 1) (>= next-column columns))
          (setq next-column 0
                next-row (if (= row 1) 2 (1+ row)))
          (when (= next-row 1)
            (setq next-row 2))
          (when (>= next-row rows)
            (setq next-row 0)))
        (md-mode--align-table-at-point table-bounds)
        (md-mode--goto-table-cell begin next-row next-column)
        (font-lock-flush begin (line-end-position))))
     (block-bounds
      (md-mode-cycle-block))
     ((md-mode--heading-level-at-point)
      (outline-cycle))
     ((md-mode--list-item-info)
      (md-mode-indent-list-item))
     (t
      (indent-for-tab-command)))))

;;;###autoload
(defun md-mode-cycle-block ()
  "Fold or reveal front matter or a fenced code block at point."
  (interactive)
  (md-mode--ensure-mode)
  (when md-mode--rendered-p
    (user-error "Block folding is unavailable in rendered view"))
  (if-let* ((bounds (md-mode--block-fold-bounds)))
      (pcase-let ((`(,begin . ,end) bounds))
        (outline-flag-region
         begin end (not (outline-invisible-p begin))))
    (user-error "Not on a front matter or code block opener")))

;;;###autoload
(defun md-mode-backtab ()
  "Outdent a list item or cycle all Markdown headings."
  (interactive)
  (md-mode--ensure-mode)
  (if (md-mode--list-item-info)
      (md-mode-outdent-list-item)
    (outline-cycle-buffer)))

(defun md-mode--source-position-at-point ()
  "Return the source position corresponding to point in rendered Markdown."
  (let* ((position (point))
         (source (and (< position (point-max))
                      (get-text-property position 'md-render-source)))
         (run-start
          (and source
               (previous-single-property-change
                (min (1+ position) (point-max))
                'md-render-source nil (point-min))))
         (run-end
          (and source
               (next-single-property-change
                position 'md-render-source nil (point-max))))
         (visible
          (and run-start run-end
               (buffer-substring-no-properties run-start run-end)))
         (source-offset
          (and visible
               (string-search visible (substring-no-properties source))))
         (prefix-end (if source-offset run-start position)))
    (+ (point-min)
       (length (md-render-reconstruct (point-min) prefix-end))
       (if source-offset
           (+ source-offset (- position run-start))
         0))))

;;;###autoload
(defun md-mode-render ()
  "Render Markdown in the current buffer and make it read-only."
  (interactive)
  (md-mode--ensure-mode)
  (unless md-mode--rendered-p
    (outline-show-all)
    (let ((modified (buffer-modified-p))
          (buffer-undo-list t)
          (inhibit-read-only t)
          ;; Rendering is a view change, not an edit: a nil
          ;; `buffer-file-name' skips the supersession prompt ("changed
          ;; on disk; really edit the buffer?") that would otherwise
          ;; abort the first render after an external tool rewrites the
          ;; visited file (e.g. a doc regenerated while previewing).
          (buffer-file-name nil)
          (buffer-file-truename nil))
      (save-restriction
        (widen)
        (when font-lock-mode
          (font-lock-ensure))
        (with-silent-modifications
          (md-render-replace-markup :force t)))
      (md-mode--set-rendered-p t)
      (md-mode--scale-heading-fallback-font)
      (set-buffer-modified-p modified)
      (md-mode--refresh-toc))))

;;;###autoload
(defun md-mode-show-source ()
  "Restore editable Markdown source in the current buffer."
  (interactive)
  (when md-mode--rendered-p
    (let ((modified (buffer-modified-p))
          (source-point nil)
          (buffer-undo-list t)
          (inhibit-read-only t)
          ;; Restoring source is a view change, not an edit — see
          ;; `md-mode-render'.  This also runs from `before-revert-hook',
          ;; where the visited file is stale by definition and the
          ;; supersession prompt would block the revert.
          (buffer-file-name nil)
          (buffer-file-truename nil))
      (save-restriction
        (widen)
        (setq source-point (md-mode--source-position-at-point))
        (with-silent-modifications
          (let ((source (md-render-reconstruct (point-min) (point-max))))
            (erase-buffer)
            (insert source))))
      (md-mode--set-rendered-p nil)
      (font-lock-flush)
      (goto-char (min source-point (point-max)))
      (set-buffer-modified-p modified)
      (md-mode--refresh-toc))))

;;;###autoload
(defun md-mode-toggle-markup ()
  "Toggle between editable Markdown source and rendered view."
  (interactive)
  (md-mode--ensure-mode)
  (let* ((window (selected-window))
         (displayed-p (eq (window-buffer window) (current-buffer)))
         (screen-row
          (and displayed-p
               (or (nth 1 (window-line-height nil window))
                   (max 0
                        (1- (count-screen-lines
                             (window-start window) (point) nil
                             window)))))))
    (if md-mode--rendered-p
        (md-mode-show-source)
      (md-mode-render))
    (when screen-row
      (recenter screen-row))))

;;;###autoload
(define-derived-mode md-mode text-mode "MD"
  "Major mode for editing and rendering Markdown source."
  (setq-local md-mode--rendered-p nil)
  (setq-local font-lock-defaults '(md-mode--font-lock-keywords))
  (setq-local font-lock-extra-managed-props
              (cons 'display font-lock-extra-managed-props))
  (setq-local font-lock-syntactic-face-function #'md-mode--syntactic-face)
  (setq-local syntax-propertize-function #'md-mode--syntax-propertize)
  (setq-local outline-search-function #'md-mode--outline-search)
  (setq-local outline-level #'md-mode--outline-level)
  (setq-local imenu-create-index-function #'md-mode--imenu-index)
  (md-mode--remap-markdown-mode-faces)
  (add-to-invisibility-spec '(outline . t))
  (when (fboundp 'hel-keymap-local-set)
    (hel-keymap-local-set
      :state 'normal
      "M-RET" #'md-mode-insert-list-item
      "M-S-RET" #'md-mode-insert-todo-item
      "M-S-<return>" #'md-mode-insert-todo-item
      "C-c C-c" #'md-mode-context-action
      "C-RET" #'md-mode-insert-heading
      "M-<up>" #'md-mode-move-up
      "M-<down>" #'md-mode-move-down
      "M-S-<left>" #'md-mode-delete-table-column
      "M-S-<right>" #'md-mode-insert-table-column
      "M-S-<up>" #'md-mode-delete-table-row
      "M-S-<down>" #'md-mode-insert-table-row
      "M-<left>" #'md-mode-promote-heading
      "M-<right>" #'md-mode-demote-heading
      "TAB" #'md-mode-tab
      "S-TAB" #'md-mode-backtab
      "<backtab>" #'md-mode-backtab
      "C-c C-n" #'md-mode-next-heading
      "C-c C-p" #'md-mode-previous-heading
      "C-c C-u" #'md-mode-up-heading
      "C-c C-f" #'md-mode-forward-same-level
      "C-c C-b" #'md-mode-backward-same-level
      "C-c C-j" #'md-mode-goto-heading
      "C-c C-o" #'md-mode-open-at-point
      "C-c C-t" #'md-mode-toggle-toc
      "C-c |" #'md-mode-table
      "C-c -" #'md-mode-cycle-list-marker
      "M-h" #'md-mode-mark-element
      "C-c @" #'md-mode-mark-subtree))
  (add-hook 'syntax-propertize-extend-region-functions
            #'md-mode--syntax-propertize-extend-region nil t)
  (add-hook 'after-change-functions #'md-mode--toc-mark-dirty nil t)
  (add-hook 'post-command-hook #'md-mode--toc-refresh-if-dirty nil t)
  (add-hook 'before-save-hook #'md-mode-show-source nil t)
  (add-hook 'before-revert-hook #'md-mode-show-source nil t)
  (add-hook 'change-major-mode-hook #'md-mode-show-source nil t)
  (add-hook 'change-major-mode-hook #'md-mode--stop-table-overflow nil t)
  (add-hook 'change-major-mode-hook #'md-mode--toc-cleanup nil t)
  (add-hook 'kill-buffer-hook #'md-mode--toc-cleanup nil t)
  (add-hook 'window-configuration-change-hook
            #'md-mode--truncate-tables-in-buffer nil t)
  (add-hook 'text-scale-mode-hook
            #'md-mode--truncate-tables-in-buffer nil t)
  (jit-lock-register #'md-mode--truncate-tables-in-region)
  (md-mode--auto-align-tables)
  (md-mode--fold-initial-front-matter)
  (md-mode--truncate-tables-in-buffer))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.md\\'" . md-mode))

(provide 'md-mode)

;;; md-mode.el ends here
