;;; md-render-table.el --- Markdown tables as grids and TextUI widgets -*- lexical-binding: t; -*-

;; Copyright (C) 2026 yibie

;; Author: yibie <https://github.com/yibie>
;; URL: https://github.com/yibie/md-mode
;; SPDX-License-Identifier: GPL-3.0-or-later

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

;; Markdown pipe tables in two layouts.
;;
;; The text grid measures cells in columns and draws box borders.  It is
;; what `md-render-convert' produces, and the fallback on text terminals.
;;
;; The `md-render-table-widget' lays a table out in pixels for graphical
;; frames.  It implements TextUI's block widget protocol, so a host lays
;; it out with `textui-layout-widget' and attaches it with
;; `textui-attach-widget'.  Column widths in both layouts are shared out
;; with TextUI's layout geometry.

;;; Code:

(require 'cl-lib)
(require 'md-render-core)
(require 'subr-x)
(require 'textui-layout)
(require 'wid-edit)

;;;; Line grammar

(defconst md-render--table-row-regexp "[ \t]*|[^\n]+|[ \t]*$"
  "Regexp for a table row, matched at the start of a line.")

(defconst md-render--table-separator-regexp "[ \t]*|[-:| \t]+|[ \t]*$"
  "Regexp for a table separator row, matched at the start of a line.")

(defun md-render--table-row-at-p (pos)
  "Return non-nil when the line starting at POS is a table row."
  (save-excursion
    (goto-char pos)
    (looking-at-p md-render--table-row-regexp)))

;;;; Detection

(defun md-render--table-extension-end (end avoid-ranges)
  "Return how far raw rows extend a rendered table ending at END.
Rows inside AVOID-RANGES or starting with frozen text do not count."
  (when (and (< end (point-max)) (not (eq (char-after end) ?\n)))
    (setq end (md-render--line-end end)))
  (let ((done nil))
    (while (and (not done) (< end (point-max)) (eq (char-after end) ?\n))
      (let* ((line (1+ end))
             (line-end (md-render--line-end line)))
        (if (and (< line (point-max))
                 (md-render--table-row-at-p line)
                 (not (get-text-property line 'md-render-frozen))
                 (not (md-render-in-avoid-range-p line line-end
                                                  avoid-ranges)))
            (setq end line-end)
          (setq done t)))))
  end)

(defun md-render--raw-table-end (start avoid-ranges)
  "Return (END . ROWS) for the raw rows that begin at START.
Rows inside AVOID-RANGES or starting with frozen text end the table."
  (let ((end nil)
        (rows 0)
        (line start))
    (while (and (< line (point-max))
                (md-render--table-row-at-p line)
                (not (get-text-property line 'md-render-frozen))
                (not (md-render-in-avoid-range-p
                      line (md-render--line-end line) avoid-ranges)))
      (setq end (md-render--line-end line)
            rows (1+ rows)
            line (1+ end)))
    (cons end rows)))

(defun md-render--find-tables (&optional avoid-ranges)
  "Return the tables to render in the buffer, in buffer order.
Each table is a plist with `:start', `:end' and `:source'.  A rendered
table followed by newly streamed rows is returned with those rows
appended to its stored source.  AVOID-RANGES are skipped."
  (let ((inhibit-field-text-motion t)
        (pos (point-min))
        (tables nil))
    (while (< pos (point-max))
      (let ((range (md-render-in-avoid-range-p pos (1+ pos) avoid-ranges))
            (stored (get-text-property pos 'md-render-table-source)))
        (cond
         (range (setq pos (max (1+ pos) (cdr range))))
         (stored
          (let* ((rendered-end (next-single-property-change
                                pos 'md-render-table-source nil (point-max)))
                 (end (md-render--table-extension-end rendered-end
                                                      avoid-ranges)))
            (when (> end rendered-end)
              (push (list :start pos :end end
                          :source (concat stored
                                          (buffer-substring rendered-end end)))
                    tables))
            (setq pos end)))
         ((and (= pos (md-render--line-start pos))
               (not (get-text-property pos 'md-render-frozen))
               (md-render--table-row-at-p pos))
          (pcase-let ((`(,end . ,rows) (md-render--raw-table-end
                                        pos avoid-ranges)))
            (if (and end (>= rows 2))
                (progn
                  (push (list :start pos :end end
                              :source (buffer-substring pos end))
                        tables)
                  (setq pos (min (point-max) (1+ end))))
              (setq pos (min (point-max) (1+ (md-render--line-end pos)))))))
         (t (setq pos (min (point-max) (1+ (md-render--line-end pos))))))))
    (nreverse tables)))

(defun md-render-tables-present-p ()
  "Return non-nil when the buffer has a Markdown table to render."
  (and (md-render--find-tables) t))

;;;; Rows and cells

(defun md-render--collect-table-rows ()
  "Return the table rows at the start of the buffer as alists.
Each row has `:start', `:end', `:num' and `:separator'."
  (let ((inhibit-field-text-motion t)
        (rows nil)
        (num 0))
    (save-excursion
      (goto-char (point-min))
      (while (and (not (eobp)) (looking-at-p md-render--table-row-regexp))
        (push `((:start . ,(point))
                (:end . ,(pos-eol))
                (:num . ,num)
                (:separator . ,(looking-at-p
                                md-render--table-separator-regexp)))
              rows)
        (setq num (1+ num))
        (forward-line 1)))
    (nreverse rows)))

(defun md-render--table-row-cells (start end)
  "Return the trimmed cells of the table row between START and END.
Escaped and frozen pipes do not separate cells, and text after the
last pipe is dropped."
  (let ((pos start)
        (cells nil)
        cell-start)
    (while (and (< pos end) (memq (char-after pos) '(?\s ?\t)))
      (setq pos (1+ pos)))
    (when (eq (char-after pos) ?|)
      (setq pos (1+ pos)))
    (setq cell-start pos)
    (while (< pos end)
      (pcase (char-after pos)
        (?\\ (setq pos (+ pos 2)))
        ((and ?| (guard (not (get-text-property pos 'md-render-frozen))))
         (push (string-trim (buffer-substring cell-start pos)) cells)
         (setq pos (1+ pos)
               cell-start pos))
        (_ (setq pos (1+ pos)))))
    (nreverse cells)))

(defun md-render--table-alignment (cell)
  "Return the alignment that separator CELL declares."
  (let ((text (string-trim cell)))
    (cond
     ((and (string-prefix-p ":" text) (string-suffix-p ":" text)
           (> (length text) 1))
      'center)
     ((string-suffix-p ":" text) 'right)
     (t 'left))))

(defun md-render--fit-list (list count filler)
  "Return LIST cut or padded with FILLER to COUNT elements."
  (append (seq-take list count)
          (make-list (max 0 (- count (length list))) filler)))

(defun md-render--pixel-measurement-p (window)
  "Return non-nil when strings can be measured in pixels in WINDOW."
  (and window
       (window-live-p window)
       (fboundp 'window-text-pixel-size)
       (display-graphic-p)))

(defun md-render--ascii-p (string)
  "Return non-nil when STRING is pure ASCII."
  (string-match-p "\\`[[:ascii:]]*\\'" string))

(defun md-render--needs-pixels-p (string window)
  "Return non-nil when STRING must be measured in pixels in WINDOW."
  (and (md-render--pixel-measurement-p window)
       (or (not (md-render--ascii-p string))
           (md-render--text-has-face-p string))))

(defun md-render--table-cell-columns (string window)
  "Return the width of STRING in columns, measured in WINDOW if needed."
  (if (md-render--needs-pixels-p string window)
      (condition-case nil
          (ceiling (/ (float (md-render--table-measure-string string window))
                      (md-render--table-char-pixel-width window)))
        (error (string-width string)))
    (string-width string)))

(cl-defun md-render--preprocess-table (&key rows separator-row-num window)
  "Return the cells, faces, widths and alignments of table ROWS.
SEPARATOR-ROW-NUM is the number of the first separator row; rows
before it are headers.  WINDOW is used to measure cells.  The result
is an alist of `:natural-widths', `:alignments' and `:processed-rows',
where each processed row is (ROW . CELLS) and separators have no
cells."
  (let* ((first (car rows))
         (columns (length (md-render--table-row-cells
                           (alist-get :start first) (alist-get :end first))))
         (widths (make-list columns 0))
         (alignments nil)
         (data-index 0)
         (processed nil))
    (dolist (row rows)
      (let ((cells (md-render--fit-list
                    (md-render--table-row-cells (alist-get :start row)
                                                (alist-get :end row))
                    columns "")))
        (if (alist-get :separator row)
            (progn
              (setq alignments (mapcar #'md-render--table-alignment cells))
              (push (list row) processed))
          (let ((face (cond
                       ((and separator-row-num
                             (< (alist-get :num row) separator-row-num))
                        'md-render-table-header)
                       ((prog1 (and md-render-table-zebra-stripe
                                    (cl-oddp data-index))
                          (setq data-index (1+ data-index)))
                        'md-render-table-zebra))))
            (setq cells
                  (mapcar (lambda (cell)
                            (let ((cell (md-render--table-apply-height-scaling
                                         cell)))
                              (when face
                                (add-face-text-property 0 (length cell) face t
                                                        cell))
                              cell))
                          cells))
            (setq widths (cl-mapcar
                          (lambda (width cell)
                            (max width (md-render--table-cell-columns
                                        cell window)))
                          widths cells))
            (push (cons row cells) processed)))))
    `((:natural-widths . ,widths)
      (:alignments . ,(md-render--fit-list alignments columns 'left))
      (:processed-rows . ,(nreverse processed)))))

(defun md-render--parse-table (source window)
  "Return the preprocessed table SOURCE, measured in WINDOW."
  (with-temp-buffer
    (insert source)
    (let* ((rows (md-render--collect-table-rows))
           (separator (seq-find (lambda (row) (alist-get :separator row))
                                rows)))
      (md-render--preprocess-table
       :rows rows
       :separator-row-num (alist-get :num separator)
       :window window))))

;;;; Height scaling

(defvar md-render--table-line-height-scales (make-hash-table)
  "Cache of height scales per character; `none' means unscaled.")

(defvar md-render--table-default-line-height nil
  "Pixel height of a line of plain ASCII text, once measured.")

(defun md-render--table-line-height (string)
  "Return the pixel height of STRING shown in the selected window."
  (let ((window (selected-window)))
    (with-temp-buffer
      (insert string)
      (save-window-excursion
        (set-window-buffer window (current-buffer))
        (cdr (window-text-pixel-size window (point-min) (point-max)))))))

(defun md-render--table-height-scale (char)
  "Return the display height that fits CHAR into a default line, or nil."
  (let ((cached (gethash char md-render--table-line-height-scales)))
    (if cached
        (unless (eq cached 'none) cached)
      (let* ((default (or md-render--table-default-line-height
                          (setq md-render--table-default-line-height
                                (md-render--table-line-height "A"))))
             (height (md-render--table-line-height (string char)))
             (scale (and (> height default)
                         (let ((ratio (/ (float default) height)))
                           (and (>= ratio 0.75) ratio)))))
        (puthash char (or scale 'none) md-render--table-line-height-scales)
        scale))))

(defun md-render--table-apply-height-scaling (str)
  "Return STR with tall glyphs shrunk to the default line height.
On text terminals, and for ASCII text, return STR itself."
  (if (or (not (display-graphic-p)) (md-render--ascii-p str))
      str
    (let ((copy (copy-sequence str)))
      (dotimes (i (length copy))
        (let ((scale (or (md-render--table-height-scale (aref copy i))
                         (and (< (1+ i) (length copy))
                              (eq (aref copy (1+ i)) #xFE0F)
                              (md-render--table-height-scale #xFE0F)))))
          (when scale
            (put-text-property i (1+ i) 'display `(height ,scale) copy))))
      copy)))

;;;; Text grid

(defun md-render--line-breakable-p (char)
  "Return non-nil when a line may break after CHAR, as after CJK text."
  (aref (char-category-set char) ?|))

(defun md-render--table-break-after-p (text index)
  "Return non-nil when TEXT may break after the character at INDEX."
  (and (< (1+ index) (length text))
       (md-render--line-breakable-p (aref text index))
       (> (char-width (aref text (1+ index))) 0)))

(defun md-render--blank-char-p (char)
  "Return non-nil when CHAR is a space, tab or newline."
  (memq char '(?\s ?\t ?\n)))

(cl-defun md-render--table-longest-word (&key str window)
  "Return the width in columns of the widest unbreakable word of STR.
Measure in WINDOW when needed.  Each line-breakable character counts
as a word of its own."
  (let ((widest 0)
        (word-start nil)
        (length (length (or str ""))))
    (dotimes (i (1+ length))
      (let ((char (and (< i length) (aref str i))))
        (when (and word-start
                   (or (null char)
                       (md-render--blank-char-p char)
                       (md-render--line-breakable-p char)))
          (setq widest (max widest (md-render--table-cell-columns
                                    (substring str word-start i) window))
                word-start nil))
        (cond
         ((null char))
         ((md-render--blank-char-p char))
         ((md-render--line-breakable-p char)
          (setq widest (max widest (char-width char))))
         ((null word-start) (setq word-start i)))))
    widest))

(defvar-local md-render--table-face-width-ratios nil
  "Cache of face width ratios, as (FONT-WIDTH . HASH-TABLE).")

(defun md-render--table-face-width-ratio (face window)
  "Return how much wider FACE draws text than the default face in WINDOW."
  (with-current-buffer (window-buffer window)
    (let ((font-width (window-font-width window)))
      (unless (equal (car md-render--table-face-width-ratios) font-width)
        (setq md-render--table-face-width-ratios
              (cons font-width (make-hash-table :test #'equal))))
      (let ((table (cdr md-render--table-face-width-ratios)))
        (or (gethash face table)
            (let* ((sample (make-string 10 ?M))
                   (plain (md-render--table-measure-string sample window))
                   (styled (md-render--table-measure-string
                            (propertize sample 'face face) window)))
              (puthash face (if (zerop plain) 1.0 (/ (float styled) plain))
                       table)))))))

(defun md-render--table-wrap-char-width (text pos &optional window)
  "Return the width in columns of the character of TEXT at POS.
When WINDOW can measure pixels, scale by the width of the character's
face."
  (let ((char (aref text pos)))
    (if (eq char #xFE0F)
        1
      (let ((width (char-width char))
            (face (get-text-property pos 'face text)))
        (if (and face (md-render--pixel-measurement-p window))
            (condition-case nil
                (* width (md-render--table-face-width-ratio face window))
              (error width))
          width)))))

(defun md-render--table-wrap-text (text width &optional window)
  "Wrap TEXT into lines at most WIDTH columns wide and return them.
Measure characters in WINDOW when it can measure pixels."
  (if (or (null text) (string-empty-p text))
      (list "")
    (let* ((length (length text))
           (widths (mapcar (lambda (i)
                             (md-render--table-wrap-char-width text i window))
                           (number-sequence 0 (1- length))))
           (selectors (cl-count #xFE0F text)))
      (if (<= (apply #'+ widths) (- width selectors))
          (list text)
        (let ((widths (vconcat widths))
              (pos 0)
              (lines nil))
          (while (< pos length)
            (let ((end pos)
                  (used 0))
              (while (and (< end length)
                          (or (= end pos)
                              (<= (+ used (aref widths end)) width)))
                (setq used (+ used (aref widths end))
                      end (1+ end)))
              (when (< end length)
                (when-let* ((break (cl-loop
                                    for i downfrom (1- end) to pos
                                    when (or (and (> i pos)
                                                  (memq (aref text i)
                                                        '(?\s ?\t ?\n)))
                                             (md-render--table-break-after-p
                                              text i))
                                    return i)))
                  (setq end (1+ break))))
              (push (string-trim-right (substring text pos end)) lines)
              (setq pos end)
              (while (and (< pos length) (memq (aref text pos) '(?\s ?\t)))
                (setq pos (1+ pos)))))
          (nreverse lines))))))

(defun md-render--split-padding (amount alignment)
  "Split AMOUNT of padding into (BEFORE . AFTER) for ALIGNMENT."
  (pcase alignment
    ('right (cons amount 0))
    ('center (let ((before (/ amount 2)))
               (cons before (- amount before))))
    (_ (cons 0 amount))))

(defun md-render--pixel-padding (pixels space)
  "Return padding PIXELS wide made of spaces SPACE pixels wide."
  (concat (make-string (/ pixels space) ?\s)
          (let ((rest (% pixels space)))
            (if (> rest 0)
                (propertize " " 'display `(space :width (,rest)))
              ""))))

(cl-defun md-render--pad-table-string
    (&key str width window force-pixel (alignment 'left))
  "Pad STR to WIDTH columns according to ALIGNMENT.
Pad in pixels when WINDOW can measure them and STR is not plain ASCII
or FORCE-PIXEL is non-nil."
  (or (and (md-render--pixel-measurement-p window)
           (or force-pixel (md-render--needs-pixels-p str window))
           (condition-case nil
               (let* ((space (md-render--table-char-pixel-width window))
                      (padding (- (* width space)
                                  (md-render--table-measure-string
                                   str window))))
                 (if (<= padding 0)
                     str
                   (pcase-let ((`(,before . ,after)
                                (md-render--split-padding padding alignment)))
                     (concat (md-render--pixel-padding before space)
                             str
                             (md-render--pixel-padding after space)))))
             (error nil)))
      (let ((columns (string-width str)))
        (if (>= columns width)
            str
          (pcase-let ((`(,before . ,after)
                       (md-render--split-padding (- width columns) alignment)))
            (concat (make-string before ?\s) str
                    (make-string after ?\s)))))))

(defun md-render--table-glyphs ()
  "Return the border glyphs of the current border style as a plist."
  (if md-render-table-use-unicode-borders
      '(:vertical "│" :horizontal "─"
                  :top ("┌" "┬" "┐") :middle ("├" "┼" "┤")
                  :bottom ("└" "┴" "┘"))
    '(:vertical "|" :horizontal "-"
                :top ("+" "+" "+") :middle ("|" "|" "|")
                :bottom ("+" "+" "+"))))

(defun md-render--border (string)
  "Return STRING in the table border face."
  (propertize string 'face 'md-render-table-border))

(defun md-render--mark-cell-start (cell &optional skip-p)
  "Mark the first content character of CELL as a cell start.
SKIP-P, when given, is called with an index and says whether that
character is padding.  An empty cell is marked on index 1, or 0 when
it is shorter."
  (let* ((skip (or skip-p
                   (lambda (i) (memq (aref cell i) '(?\s ?\t)))))
         (index (or (cl-loop for i below (length cell)
                             unless (funcall skip i) return i)
                    (min 1 (1- (length cell))))))
    (when (>= index 0)
      (put-text-property index (1+ index) 'md-render-table-cell-start t cell))
    cell))

(defun md-render--text-grid-widths (natural cells-by-column window)
  "Return column widths for a text grid of NATURAL widths.
CELLS-BY-COLUMN lists every cell of each column, measured in WINDOW.
Wide tables shrink toward the width of their longest words."
  (let* ((target (and md-render-table-wrap-columns
                      (floor (* (md-render--display-width)
                                md-render-table-max-width-fraction))))
         (borders (1+ (* 3 (length natural)))))
    (if (or (null target) (<= (+ borders (apply #'+ natural)) target))
        natural
      (let ((minimums (cl-mapcar
                       (lambda (width cells)
                         (min width
                              (apply #'max 0
                                     (mapcar (lambda (cell)
                                               (md-render--table-longest-word
                                                :str cell :window window))
                                             cells))))
                       natural cells-by-column)))
        (md-render--shrink-columns natural minimums
                                   (- (+ borders (apply #'+ natural))
                                      target))))))

(defun md-render--shrink-columns (widths minimums excess)
  "Shrink WIDTHS toward MINIMUMS until EXCESS columns are recovered.
Every column gives up the same share of its slack, rounded so that no
column ends up wider than that share allows."
  (let* ((slacks (cl-mapcar (lambda (width minimum) (max 0 (- width minimum)))
                            widths minimums))
         (slack (apply #'+ slacks)))
    (if (<= slack 0)
        minimums
      (let ((ratio (min 1.0 (/ (float excess) slack))))
        (cl-mapcar (lambda (width minimum column-slack)
                     (max minimum (floor (- width (* column-slack ratio)))))
                   widths minimums slacks)))))

(defun md-render--text-grid-row (cells widths alignments face window)
  "Return the text grid lines of one row of CELLS.
WIDTHS and ALIGNMENTS describe the columns, FACE is the row face and
WINDOW measures the cells."
  (let* ((vertical (md-render--border
                    (plist-get (md-render--table-glyphs) :vertical)))
         (wrapped (cl-mapcar (lambda (cell width)
                               (md-render--table-wrap-text cell width window))
                             cells widths))
         (pixels (mapcar (lambda (cell)
                           (md-render--needs-pixels-p cell window))
                         cells))
         (height (apply #'max 1 (mapcar #'length wrapped)))
         (lines nil))
    (dotimes (line height)
      (let ((parts
             (cl-mapcar
              (lambda (cell-lines width alignment pixel)
                (let* ((text (or (nth line cell-lines) ""))
                       (padded (concat " "
                                       (md-render--pad-table-string
                                        :str text :width width :window window
                                        :force-pixel (and pixel
                                                          (not (string-empty-p
                                                                text)))
                                        :alignment alignment)
                                       " ")))
                  (when face
                    (add-face-text-property 0 (length padded) face t padded))
                  (if (zerop line)
                      (md-render--mark-cell-start padded)
                    padded)))
              wrapped widths alignments pixels)))
        (push (concat vertical (string-join parts vertical) vertical) lines)))
    (string-join (nreverse lines) "\n")))

(defun md-render--text-grid-rule (widths glyphs)
  "Return a horizontal rule over WIDTHS using the three GLYPHS."
  (pcase-let ((`(,left ,join ,right) glyphs)
              (horizontal (plist-get (md-render--table-glyphs) :horizontal)))
    (md-render--border
     (concat left
             (mapconcat (lambda (width)
                          (apply #'concat
                                 (make-list (+ width 2) horizontal)))
                        widths join)
             right))))

(cl-defun md-render--render-table-source (&key source window framed)
  "Return table SOURCE laid out as a text grid.
Measure cells in WINDOW.  When FRAMED is non-nil, add rules above and
below the table."
  (let* ((table (md-render--parse-table source window))
         (natural (alist-get :natural-widths table))
         (alignments (alist-get :alignments table))
         (rows (alist-get :processed-rows table))
         (data-rows (seq-remove (lambda (row) (null (cdr row))) rows))
         (widths (md-render--text-grid-widths
                  natural
                  (apply #'cl-mapcar #'list
                         (or (mapcar #'cdr data-rows)
                             (list (make-list (length natural) ""))))
                  window))
         (glyphs (md-render--table-glyphs))
         (lines
          (mapcar
           (lambda (row)
             (if (null (cdr row))
                 (md-render--text-grid-rule widths
                                            (plist-get glyphs :middle))
               (md-render--text-grid-row
                (cdr row) widths alignments
                (md-render--table-row-kind-face (car row) rows)
                window)))
           rows)))
    (string-join
     (append (when framed
               (list (md-render--text-grid-rule widths
                                                (plist-get glyphs :top))))
             lines
             (when framed
               (list (md-render--text-grid-rule widths
                                                (plist-get glyphs :bottom)))))
     "\n")))

(defun md-render--table-row-kind-face (row rows)
  "Return the face of ROW among the processed ROWS."
  (let* ((separator (seq-find (lambda (processed) (null (cdr processed)))
                              rows))
         (separator-num (and separator (alist-get :num (car separator)))))
    (if (and separator-num (< (alist-get :num row) separator-num))
        'md-render-table-header
      (when md-render-table-zebra-stripe
        (let ((index (cl-count-if
                      (lambda (processed)
                        (and (cdr processed)
                             (< (alist-get :num (car processed))
                                (alist-get :num row))
                             (not (and separator-num
                                       (< (alist-get :num (car processed))
                                          separator-num)))))
                      rows)))
          (when (cl-oddp index)
            'md-render-table-zebra))))))

;;;; Pixel measurement

(defun md-render--table-measure-string (string window)
  "Return the pixel width of STRING drawn in WINDOW's buffer.
The string is measured in the `fixed-pitch' face that rendered tables
use.  Disable line-number display only while measuring.
The buffer, point and undo history are left untouched."
  (if (string-empty-p string)
      0
    (with-current-buffer (window-buffer window)
      (let ((probe (copy-sequence string))
            (display-line-numbers nil))
        (add-face-text-property 0 (length probe) 'fixed-pitch nil probe)
        (put-text-property 0 (length probe) 'fontified t probe)
        (remove-text-properties 0 (length probe)
                                '(line-prefix nil wrap-prefix nil) probe)
        (save-excursion
          (save-restriction
            (widen)
            (with-silent-modifications
              (let ((start (point-max)))
                (goto-char start)
                (insert probe)
                (unwind-protect
                    (let ((end (point)))
                      (narrow-to-region start end)
                      (car (window-text-pixel-size window start end 100000)))
                  (delete-region start (+ start (length probe))))))))))))

(defvar-local md-render--table-char-pixel-cache nil
  "Pixel width of a space in this buffer, as (FONT-WIDTH . PIXELS).")

(defun md-render--table-char-pixel-width (window)
  "Return the pixel width of one space in WINDOW."
  (with-current-buffer (window-buffer window)
    (let ((font-width (window-font-width window)))
      (if (equal (car md-render--table-char-pixel-cache) font-width)
          (cdr md-render--table-char-pixel-cache)
        (let ((pixels (max 1 (md-render--table-measure-string " " window))))
          (setq md-render--table-char-pixel-cache (cons font-width pixels))
          pixels)))))

(define-hash-table-test 'md-render--string-properties
                        #'equal-including-properties #'sxhash-equal-including-properties)

(defvar-local md-render--table-widget-measure-cache nil
  "Measured string widths for table widgets, as (VALIDITY . HASH-TABLE).
VALIDITY records the font state the measurements belong to.")

(defconst md-render--table-widget-measure-cache-limit 50000
  "Number of measurements after which the widget cache starts over.")

(defun md-render--table-widget-measurements (window measure)
  "Return the table of widths that MEASURE produced in WINDOW's font.
The table is kept in WINDOW's buffer and replaced when the font
changes or the table grows too large."
  (with-current-buffer (window-buffer window)
    (let ((validity (list (window-font-width window)
                          (face-font 'fixed-pitch)
                          measure))
          (cache md-render--table-widget-measure-cache))
      (if (and cache
               (equal (car cache) validity)
               (< (hash-table-count (cdr cache))
                  md-render--table-widget-measure-cache-limit))
          (cdr cache)
        (let ((table (make-hash-table :test 'md-render--string-properties)))
          (setq md-render--table-widget-measure-cache (cons validity table))
          table)))))

;;;; Pixel layout

(defun md-render--table-widget-pixel-budget (width window)
  "Return the pixel width available to a table WIDTH columns wide.
Measure in WINDOW; in a real pixel window the budget never exceeds
the window body."
  (let ((pixels (md-render--table-measure-string (make-string width ?\s)
                                                 window)))
    (if (and (window-live-p window)
             (> (window-body-width window t) width)
             (>= width (md-render--window-columns window)))
        (min pixels (window-body-width window t))
      pixels)))

(defun md-render--table-widget-spacer (pixels)
  "Return an invisible spacer PIXELS wide, or an empty string."
  (if (> pixels 0)
      (propertize "​"
                  'display `(space :width (,pixels))
                  'md-render-table-synthetic-spacing t)
    ""))

(defun md-render--grapheme-end (text start)
  "Return the end of the grapheme cluster of TEXT that begins at START."
  (let* ((length (length text))
         (end (1+ start))
         (regional (lambda (char) (and char (<= #x1F1E6 char #x1F1FF)))))
    (when (and (< end length)
               (funcall regional (aref text start))
               (funcall regional (aref text end)))
      (setq end (1+ end)))
    (let ((done nil))
      (while (and (not done) (< end length))
        (let ((char (aref text end)))
          (cond
           ((eq char #x200D) (setq end (min length (+ end 2))))
           ((or (zerop (char-width char)) (<= #x1F3FB char #x1F3FF))
            (setq end (1+ end)))
           (t (setq done t))))))
    end))

(defun md-render--grapheme-ends (text start)
  "Return the ends of the grapheme clusters of TEXT after START."
  (let ((ends nil)
        (pos start))
    (while (< pos (length text))
      (setq pos (md-render--grapheme-end text pos))
      (push pos ends))
    (nreverse ends)))

(defun md-render--table-widget-widest-cluster (text window)
  "Return the pixel width of the widest grapheme cluster of TEXT.
Measure in WINDOW."
  (let ((widest 1)
        (start 0))
    (dolist (end (md-render--grapheme-ends text 0))
      (setq widest (max widest (md-render--table-measure-string
                                (substring text start end) window))
            start end))
    widest))

(defun md-render--table-widget-longest-token-pixels (text window)
  "Return the pixel width of the widest unbreakable token of TEXT.
Tokens end at blanks and after line-breakable characters.  Measure in
WINDOW."
  (let ((widest 0)
        (start nil)
        (length (length text)))
    (dotimes (i length)
      (let ((char (aref text i)))
        (cond
         ((memq char '(?\s ?\t))
          (when start
            (setq widest (max widest (md-render--table-measure-string
                                      (substring text start i) window))
                  start nil)))
         (t
          (unless start
            (setq start i))
          (when (md-render--table-break-after-p text i)
            (setq widest (max widest (md-render--table-measure-string
                                      (substring text start (1+ i)) window))
                  start nil))))))
    (when start
      (setq widest (max widest (md-render--table-measure-string
                                (substring text start) window))))
    widest))

(defun md-render--table-widget-wrap-pixels (text pixels window)
  "Wrap TEXT into lines at most PIXELS wide in WINDOW and return them.
Grapheme clusters are never split; a single cluster wider than PIXELS
takes a line of its own."
  (if (or (string-empty-p text)
          (<= (md-render--table-measure-string text window) pixels))
      (list text)
    (let ((length (length text))
          (pos 0)
          (lines nil))
      (while (< pos length)
        (let* ((ends (vconcat (md-render--grapheme-ends text pos)))
               (low 0)
               (high (1- (length ends)))
               (fit 0))
          (while (<= low high)
            (let ((middle (/ (+ low high) 2)))
              (if (<= (md-render--table-measure-string
                       (substring text pos (aref ends middle)) window)
                      pixels)
                  (setq fit middle
                        low (1+ middle))
                (setq high (1- middle)))))
          (let ((end (aref ends fit)))
            (when (< end length)
              (when-let* ((break (cl-loop
                                  for i downfrom (1- end) above pos
                                  when (and (< i (1- length))
                                            (or (memq (aref text i)
                                                      '(?\s ?\t))
                                                (md-render--table-break-after-p
                                                 text i)))
                                  return i)))
                (setq end (1+ break))))
            (push (string-trim-right (substring text pos end)) lines)
            (setq pos end)
            (while (and (< pos length) (memq (aref text pos) '(?\s ?\t)))
              (setq pos (1+ pos))))))
      (nreverse lines))))

(defun md-render--table-widget-column-widths (table available space window)
  "Return pixel widths for the columns of TABLE within AVAILABLE pixels.
SPACE is the pixel width of a space, and WINDOW measures cells.
Columns start at their natural widths and shrink toward their longest
tokens, with no column's floor allowed above half the table."
  (let* ((columns (length (alist-get :alignments table)))
         (cap (floor (* 0.5 available)))
         (floor-width (1+ (* 2 space)))
         (naturals (make-list columns floor-width))
         (minimums (make-list columns floor-width)))
    (dolist (row (alist-get :processed-rows table))
      (when (cdr row)
        (setq naturals
              (cl-mapcar (lambda (natural cell)
                           (max natural
                                (+ (* 2 space)
                                   (md-render--table-measure-string
                                    cell window))))
                         naturals (cdr row))
              minimums
              (cl-mapcar (lambda (minimum cell)
                           (max minimum
                                (+ (* 2 space)
                                   (max (md-render--table-widget-widest-cluster
                                         cell window)
                                        (min (md-render--table-widget-longest-token-pixels
                                              cell window)
                                             cap)))))
                         minimums (cdr row)))))
    (cond
     ((or (not md-render-table-wrap-columns)
          (<= (apply #'+ naturals) available))
      naturals)
     ((<= available (apply #'+ minimums)) minimums)
     (t
      (let ((weights (cl-mapcar (lambda (natural minimum)
                                  (max 1 (- (min natural cap) minimum)))
                                naturals minimums)))
        (cl-mapcar #'+ minimums
                   (textui-layout-shares (- available (apply #'+ minimums))
                                         weights)))))))

(cl-defun md-render--render-table-widget-source (&key source window width)
  "Return table SOURCE laid out in pixels for WIDTH columns of WINDOW."
  (let* ((table (md-render--parse-table source window))
         (alignments (alist-get :alignments table))
         (rows (alist-get :processed-rows table))
         (glyphs (md-render--table-glyphs))
         (space (md-render--table-char-pixel-width window))
         (budget (md-render--table-widget-pixel-budget width window))
         (boundary-glyphs (delete-dups
                           (append (list (plist-get glyphs :vertical))
                                   (plist-get glyphs :top)
                                   (plist-get glyphs :middle)
                                   (plist-get glyphs :bottom))))
         (boundary-widths (mapcar (lambda (glyph)
                                    (cons glyph
                                          (md-render--table-measure-string
                                           glyph window)))
                                  boundary-glyphs))
         (boundary (apply #'max (mapcar #'cdr boundary-widths)))
         (columns (length alignments))
         (available (- budget (* (1+ columns) boundary)))
         (widths (md-render--table-widget-column-widths
                  table available space window))
         (bound (lambda (glyph)
                  (md-render--border
                   (concat glyph
                           (md-render--table-widget-spacer
                            (- boundary
                               (alist-get glyph boundary-widths
                                          0 nil #'equal)))))))
         (horizontal (plist-get glyphs :horizontal))
         (horizontal-width (max 1 (md-render--table-measure-string
                                   horizontal window)))
         (rule (lambda (three)
                 (pcase-let ((`(,left ,join ,right) three))
                   (concat
                    (funcall bound left)
                    (mapconcat
                     (lambda (width)
                       (md-render--border
                        (concat (apply #'concat
                                       (make-list (/ width horizontal-width)
                                                  horizontal))
                                (md-render--table-widget-spacer
                                 (% width horizontal-width)))))
                     widths (funcall bound join))
                    (funcall bound right)))))
         (vertical (funcall bound (plist-get glyphs :vertical)))
         (lines (list (funcall rule (plist-get glyphs :top)))))
    (dolist (row rows)
      (if (null (cdr row))
          (push (funcall rule (plist-get glyphs :middle)) lines)
        (dolist (line (md-render--table-widget-row
                       (cdr row) widths alignments
                       (md-render--table-row-kind-face (car row) rows)
                       space window))
          (push (concat vertical (string-join line vertical) vertical)
                lines))))
    (push (funcall rule (plist-get glyphs :bottom)) lines)
    (let ((text (string-join (nreverse lines) "\n")))
      (add-face-text-property 0 (length text) 'fixed-pitch nil text)
      text)))

(defun md-render--table-widget-row (cells widths alignments face space window)
  "Return the physical lines of one widget row as lists of cell strings.
CELLS are laid out in the pixel WIDTHS with ALIGNMENTS and row FACE.
SPACE is the pixel width of a space and WINDOW measures the text."
  (let* ((contents (mapcar (lambda (width) (max 1 (- width (* 2 space))))
                           widths))
         (wrapped (cl-mapcar (lambda (cell content)
                               (md-render--table-widget-wrap-pixels
                                cell content window))
                             cells contents))
         (height (apply #'max 1 (mapcar #'length wrapped)))
         (lines nil))
    (dotimes (index height)
      (push
       (cl-mapcar
        (lambda (cell-lines content alignment)
          (let* ((text (or (nth index cell-lines) ""))
                 (padding (max 0 (- content (md-render--table-measure-string
                                             text window))))
                 (split (md-render--split-padding padding alignment))
                 (cell (concat " "
                               (md-render--table-widget-spacer (car split))
                               text
                               (md-render--table-widget-spacer (cdr split))
                               " ")))
            (when face
              (add-face-text-property 0 (length cell) face t cell))
            (if (zerop index)
                (md-render--mark-cell-start
                 cell
                 (lambda (i)
                   (or (eq (aref cell i) ?\s)
                       (get-text-property i 'md-render-table-synthetic-spacing
                                          cell))))
              cell)))
        wrapped contents alignments)
       lines))
    (nreverse lines)))

;;;; Widget

(defun md-render--table-widget-layout (widget width)
  "Lay out table WIDGET for WIDTH columns and return the text.
Graphical windows get a pixel layout whose measurements are cached per
buffer; other displays get a framed text grid."
  (let ((source (widget-get widget :value))
        (window (or (get-buffer-window (current-buffer))
                    (selected-window))))
    (if (and (window-live-p window)
             (display-graphic-p)
             (fboundp 'window-text-pixel-size))
        (let* ((measure (symbol-function 'md-render--table-measure-string))
               (table (md-render--table-widget-measurements window measure)))
          (cl-letf (((symbol-function 'md-render--table-measure-string)
                     (lambda (string destination)
                       (let ((known (gethash string table 'unknown)))
                         (if (eq known 'unknown)
                             (puthash (copy-sequence string)
                                      (funcall measure string destination)
                                      table)
                           known)))))
            (md-render--render-table-widget-source
             :source source :window window :width width)))
      (let ((md-render-table-max-width-fraction 1.0))
        (cl-letf (((symbol-function 'md-render--display-width)
                   (lambda () width)))
          (md-render--render-table-source
           :source source :window window :framed t))))))

(defun md-render--table-widget-attach (widget from to)
  "Record that table WIDGET covers the text from FROM to TO."
  (widget-put widget :from (copy-marker from t))
  (widget-put widget :to (copy-marker to nil))
  (widget-put widget :delete #'widget-leave-text)
  (widget-put widget :textui-attached t)
  widget)

(define-widget 'md-render-table-widget 'default
  "A Markdown table laid out for the width of its window."
  :format "%v"
  :keymap widget-keymap
  :textui-layout #'md-render--table-widget-layout
  :textui-attach #'md-render--table-widget-attach)

;;;; In-buffer tables

(cl-defun md-render--style-tables (&key avoid-ranges defer)
  "Render the tables outside AVOID-RANGES in place.
With DEFER, keep each table's styled source as its text so that a
widget can lay it out later."
  (when md-render-prettify-tables
    (dolist (table (reverse (md-render--find-tables avoid-ranges)))
      (let* ((start (plist-get table :start))
             (end (plist-get table :end))
             (source (plist-get table :source))
             (original (md-render-reconstruct start end))
             (window (or (get-buffer-window (current-buffer))
                         (selected-window)))
             (text (if defer
                       (copy-sequence source)
                     (md-render--render-table-source :source source
                                                     :window window)))
             (carried (md-render--carry-properties start)))
        (add-face-text-property 0 (length text) 'fixed-pitch nil text)
        (goto-char start)
        (delete-region start end)
        (insert text)
        (when carried
          (add-text-properties start (point) carried))
        (add-text-properties
         start (point)
         `(md-render-frozen t
                            md-render-table-source ,source
                            md-render-source ,original
                            rear-nonsticky (md-render-frozen
                                            md-render-table-source
                                            md-render-source)))))))

;;;; Cell navigation

(defun md-render--table-cell-starts ()
  "Return the cell start positions of the table at point, in order."
  (when (get-text-property (point) 'md-render-table-source)
    (let* ((start (or (previous-single-property-change
                       (1+ (point)) 'md-render-table-source)
                      (point-min)))
           (end (next-single-property-change
                 (point) 'md-render-table-source nil (point-max)))
           (pos start)
           (starts nil))
      (while (< pos end)
        (when (and (eq (get-text-property pos 'md-render-table-cell-start) t)
                   (or (= pos start)
                       (not (eq (get-text-property
                                 (1- pos) 'md-render-table-cell-start)
                                t))))
          (push pos starts))
        (setq pos (next-single-property-change
                   pos 'md-render-table-cell-start nil end)))
      (nreverse starts))))

(defun md-render--table-move-cell (step)
  "Move point STEP cells through the table at point."
  (let* ((starts (md-render--table-cell-starts))
         (current (or (cl-position-if (lambda (pos) (<= pos (point)))
                                      starts :from-end t)
                      -1))
         (target (+ current step)))
    (if (and starts (<= 0 target (1- (length starts))))
        (goto-char (nth target starts))
      (user-error "No more cells left"))))

(defun md-render-table-next-cell ()
  "Move point to the next cell of the rendered table."
  (interactive)
  (md-render--table-move-cell 1))

(defun md-render-table-previous-cell ()
  "Move point to the previous cell of the rendered table."
  (interactive)
  (md-render--table-move-cell -1))

(provide 'md-render-table)
;;; md-render-table.el ends here
