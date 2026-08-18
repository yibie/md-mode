;;; md-mode-tests.el --- Test Markdown mode -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for source-preserving render and edit transitions.

;;; Code:

(require 'cl-lib)
(require 'ert)

(load-file (expand-file-name "../md-mode.el"
                             (file-name-directory
                              (or load-file-name buffer-file-name))))

(defconst md-mode-tests--source
  "# Title\n\nHello **world**, *italic*, and `code`.\n"
  "Markdown used by mode transition tests.")

(defun md-mode-tests--face-at (text)
  "Return the face at the start of TEXT in the current buffer."
  (goto-char (point-min))
  (search-forward text)
  (get-text-property (- (point) (length text)) 'face))

(defun md-mode-tests--has-face-p (text face)
  "Return non-nil when TEXT has FACE in the current buffer."
  (goto-char (point-min))
  (search-forward text)
  (let ((position (- (point) (length text))))
    (cl-some
     (lambda (value)
       (or (eq value face)
           (and (listp value) (memq face value))))
     (list (get-text-property position 'face)
           (get-text-property position 'font-lock-face)))))

(defun md-mode-tests--imenu-shape (index)
  "Return INDEX titles and hierarchy without target markers."
  (mapcar
   (lambda (entry)
     (pcase-let ((`(,title . ,target) entry))
       (if (markerp target)
           title
         (pcase-let ((`(,_self . ,children) target))
           (cons title
                 (md-mode-tests--imenu-shape children))))))
   index))

(ert-deftest md-mode-opens-in-editable-styled-source ()
  (with-temp-buffer
    (insert md-mode-tests--source)
    (md-mode)
    (font-lock-ensure)
    (should-not md-mode--rendered-p)
    (should-not buffer-read-only)
    (should (equal (buffer-string) md-mode-tests--source))
    (should (eq (md-mode-tests--face-at "Title") 'md-render-header-1))
    (should (eq (md-mode-tests--face-at "world") 'md-render-bold))
    (should (eq (md-mode-tests--face-at "italic") 'md-render-italic))
    (should (eq (md-mode-tests--face-at "code") 'md-render-inline-code))
    (goto-char (point-max))
    (insert "\n## Added while editing\n")
    (font-lock-ensure)
    (should (eq (md-mode-tests--face-at "Added while editing")
                'md-render-header-2))))

(ert-deftest md-mode-heading-faces-match-markdown-mode-scale ()
  (should
   (equal
    (mapcar
     (lambda (face)
       (face-attribute face :height nil nil))
     md-mode--heading-faces)
    '(2.0 1.7 1.4 1.1 1.0 1.0))))

(ert-deftest md-mode-heading-scale-is-customizable ()
  (let ((original-values
         (default-value 'md-mode-heading-scaling-values))
        (original-heights
         (mapcar
          (lambda (face)
            (face-attribute face :height nil nil))
          md-mode--heading-faces))
        (values '(1.8 1.6 1.4 1.2 1.0 0.9)))
    (unwind-protect
        (progn
          (customize-set-variable
           'md-mode-heading-scaling-values values)
          (should
           (equal
            (default-value 'md-mode-heading-scaling-values)
            values))
          (should
           (equal
            (mapcar
             (lambda (face)
               (face-attribute face :height nil nil))
             md-mode--heading-faces)
            values)))
      (set-default
       'md-mode-heading-scaling-values original-values)
      (cl-mapc
       (lambda (face height)
         (set-face-attribute face nil :height height))
       md-mode--heading-faces original-heights))))

(ert-deftest md-mode-custom-heading-face-wins-over-scaling-values ()
  (let ((original-values
         (default-value 'md-mode-heading-scaling-values))
        (saved-face
         (get 'md-render-header-1 'saved-face))
        updated-faces)
    (unwind-protect
        (progn
          (put 'md-render-header-1 'saved-face t)
          (cl-letf (((symbol-function 'set-face-attribute)
                     (lambda (face &rest _)
                       (push face updated-faces))))
            (md-mode--set-heading-scaling-values
             'md-mode-heading-scaling-values
             '(1.8 1.6 1.4 1.2 1.0 1.0))))
      (set-default
       'md-mode-heading-scaling-values original-values)
      (put 'md-render-header-1 'saved-face saved-face))
    (should-not (memq 'md-render-header-1 updated-faces))
    (should (= (length updated-faces) 5))))

(ert-deftest md-mode-render-scales-heading-fallback-fonts ()
  (with-temp-buffer
    (insert "## 中文 heading\n")
    (let (cache fontset-fonts redrawn-frame)
      (cl-letf (((symbol-function 'get-buffer-window)
                 (lambda (&rest _) 'window))
                ((symbol-function 'window-frame)
                 (lambda (_window) 'frame))
                ((symbol-function 'display-graphic-p)
                 (lambda (&rest _) t))
                ((symbol-function 'face-attribute)
                 (lambda (_face attribute _frame inherit)
                   (when (and (eq attribute :fontset)
                              (eq inherit 'default))
                     "heading-fontset")))
                ((symbol-function 'font-at)
                 (lambda (&rest _)
                   (font-spec :family "Fallback CJK" :size 16)))
                ((symbol-function 'frame-parameter)
                 (lambda (_frame parameter)
                   (and (eq parameter
                            'md-mode--heading-fonts-cache)
                        cache)))
                ((symbol-function 'set-frame-parameter)
                 (lambda (_frame _parameter value)
                   (setq cache value)))
                ((symbol-function 'set-fontset-font)
                 (lambda (&rest setting)
                   (push setting fontset-fonts)))
                ((symbol-function 'redraw-frame)
                 (lambda (frame)
                   (setq redrawn-frame frame))))
        (md-mode)
        (md-mode-render))
      (should (= (length fontset-fonts) 1))
      (should (eq redrawn-frame 'frame))
      (should
       (equal (car (car fontset-fonts))
              "heading-fontset"))
      (should (eq (cadr (car fontset-fonts)) 'han))
      (should
       (equal
        (symbol-name (font-get (nth 2 (car fontset-fonts)) :family))
        "Fallback CJK"))
      (should-not (font-get (nth 2 (car fontset-fonts)) :size))
      (setq fontset-fonts nil
            redrawn-frame nil)
      (md-mode-render)
      (should-not fontset-fonts)
      (should-not redrawn-frame))))

(ert-deftest md-mode-reuses-available-markdown-mode-faces ()
  (let ((md-mode-use-markdown-mode-faces t)
        remappings)
    (cl-letf (((symbol-function 'facep)
               (lambda (face &optional _frame)
                 (memq face
                       '(markdown-bold-face
                         markdown-header-face-1))))
              ((symbol-function 'face-remap-add-relative)
               (lambda (&rest remapping)
                 (push remapping remappings))))
      (with-temp-buffer
        (md-mode--remap-markdown-mode-faces)))
    (should
     (equal remappings
            '((md-render-bold markdown-bold-face))))))

(ert-deftest md-mode-heading-navigation-skips-fenced-code ()
  (with-temp-buffer
    (insert "# One\ntext\n```markdown\n# Not a heading\n```\n## Two\n### Three\n")
    (md-mode)
    (goto-char (point-min))
    (md-mode-next-heading)
    (should (looking-at "## Two"))
    (md-mode-next-heading)
    (should (looking-at "### Three"))
    (md-mode-previous-heading)
    (should (looking-at "## Two"))))

(ert-deftest md-mode-builds-nested-imenu ()
  (with-temp-buffer
    (insert (concat "# Root\n"
                    "## Child\n"
                    "#### Deep\n"
                    "## Child\n"
                    "# Next\n"
                    "```text\n# Hidden\n```\n"))
    (md-mode)
    (should (eq imenu-create-index-function #'md-mode--imenu-index))
    (pcase-let* ((`(,root ,next)
                   (funcall imenu-create-index-function))
                  (`(,root-label ,root-target
                     ,first-child ,second-child)
                   root)
                  (`(,next-label . ,_) next)
                  (`(,first-label ,_first-target . ,deep-children)
                   first-child)
                  (`(,second-label . ,_) second-child)
                  (`(,_ . ,root-marker) root-target))
      (should (equal (list root-label next-label) '("Root" "Next")))
      (should (string-prefix-p "Child" first-label))
      (should (string-prefix-p "Child" second-label))
      (should-not (equal first-label second-label))
      (should (equal (mapcar #'car deep-children)
                     '("Deep")))
      (should (marker-position root-marker))
      (should (eq (marker-buffer root-marker) (current-buffer))))))

(ert-deftest md-mode-imenu-matches-rendered-view ()
  (with-temp-buffer
    (insert (concat "# Root\n"
                    "## Child\n"
                    "#### Deep\n"
                    "# Next\n"
                    "```text\n# Hidden\n```\n"))
    (md-mode)
    (let ((shape (md-mode-tests--imenu-shape
                  (funcall imenu-create-index-function))))
      (should (equal shape '(("Root" ("Child" "Deep")) "Next")))
      (md-mode-render)
      (let ((index (funcall imenu-create-index-function)))
        (should (equal (md-mode-tests--imenu-shape index) shape))
        (pcase-let* ((`(,root . ,_) index)
                     (`(,_ ,target . ,_) root)
                     (`(,_ . ,marker) target))
          (should (eq (marker-buffer marker) (current-buffer))))))))

(ert-deftest md-mode-goto-heading-keeps-duplicate-titles ()
  (with-temp-buffer
    (insert "# Same\nBody\n## Same\n")
    (md-mode)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _)
                 (pcase-let ((`((,choice . ,_)) (last collection)))
                   choice))))
      (call-interactively #'md-mode-goto-heading))
    (should (looking-at "## Same"))))

(ert-deftest md-mode-imenu-handles-empty-and-stale-input ()
  (with-temp-buffer
    (md-mode)
    (should-not (funcall imenu-create-index-function)))
  (with-temp-buffer
    (insert "Bad\nGood\n")
    (md-mode)
    (put-text-property 1 4 'md-render-source 42)
    (put-text-property 5 9 'md-render-source "# Good")
    (md-mode--set-rendered-p t)
    (should (equal (mapcar #'car (funcall imenu-create-index-function))
                   '("Good"))))
  (let ((buffer (generate-new-buffer " *md-mode-imenu-marker*"))
        marker)
    (with-current-buffer buffer
      (insert "# Heading\n")
      (md-mode)
      (pcase-let* ((`(,entry) (funcall imenu-create-index-function))
                   (`(,_ . ,entry-marker) entry))
        (setq marker entry-marker)))
    (kill-buffer buffer)
    (should-not (marker-buffer marker))))

(ert-deftest md-mode-toggles-one-toc-per-source-buffer ()
  (save-window-excursion
    (let ((source (generate-new-buffer " *md-mode-toc-source*"))
          toc)
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) source)
            (with-current-buffer source
              (insert "# Root\n## Child\n")
              (md-mode)
              (should (eq (key-binding (kbd "C-c C-t"))
                          #'md-mode-toggle-toc))
              (let ((md-mode-toc-side 'right)
                    (md-mode-toc-width 24))
                (md-mode-toggle-toc)
                (setq toc md-mode--toc-buffer)
                (let ((window (get-buffer-window toc)))
                  (should (buffer-live-p toc))
                  (should (eq (buffer-local-value
                               'md-mode--toc-source-buffer toc)
                              source))
                  (should (eq (window-parameter window 'window-side)
                              'right))
                  (should (= (window-total-width window) 24)))
                (md-mode-toggle-toc)
                (should-not (get-buffer-window toc))
                (md-mode-toggle-toc)
                (should (eq md-mode--toc-buffer toc)))))
        (when (buffer-live-p toc)
          (kill-buffer toc))
        (kill-buffer source)))))

(ert-deftest md-mode-toc-renders-hierarchy-and-visits-headings ()
  (save-window-excursion
    (let ((source (generate-new-buffer " *md-mode-toc-visit*"))
          toc)
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) source)
            (with-current-buffer source
              (insert "# Root\nBody\n### Deep\n## Child\n")
              (md-mode)
              (md-mode-toggle-toc)
              (setq toc md-mode--toc-buffer)
              (goto-char (point-min))
              (outline-hide-subtree))
            (with-current-buffer toc
              (should (equal (buffer-string)
                             "Root\n    Deep\n  Child\n"))
              (goto-char (point-min))
              (should (equal (get-text-property (point) 'face)
                             '((:height 1.0)
                               md-render-header-1 outline-1)))
              (forward-line 1)
              (should (equal (get-text-property (point) 'face)
                             '((:height 1.0)
                               md-render-header-3 outline-3)))
              (forward-line 1)
              (should (equal (get-text-property (point) 'face)
                             '((:height 1.0)
                               md-render-header-2 outline-2)))
              (goto-char (point-min))
              (search-forward "Deep")
              (beginning-of-line)
              (let ((target (get-text-property
                             (point) 'md-mode-toc-target)))
                (should (markerp target))
                (should (eq (marker-buffer target) source))))
            (select-window (get-buffer-window toc))
            (with-current-buffer toc
              (goto-char (point-min))
              (search-forward "Deep")
              (md-mode--toc-visit))
            (should (eq (window-buffer (selected-window)) source))
            (with-current-buffer source
              (should (looking-at "### Deep"))
              (should-not (outline-invisible-p (point)))))
        (when (buffer-live-p toc)
          (kill-buffer toc))
        (kill-buffer source)))))

(ert-deftest md-mode-toc-refreshes-and-closes-its-window ()
  (save-window-excursion
    (let ((source (generate-new-buffer " *md-mode-toc-refresh*"))
          toc)
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) source)
            (with-current-buffer source
              (insert "# One\n")
              (md-mode)
              (md-mode-toggle-toc)
              (setq toc md-mode--toc-buffer)
              (goto-char (point-max))
              (insert "## Two\n"))
            (with-current-buffer toc
              (should (eq (key-binding (kbd "g"))
                          #'md-mode--toc-refresh))
              (should (eq (key-binding (kbd "q"))
                          #'md-mode--toc-quit))
              (should (eq (key-binding (kbd "<mouse-1>"))
                          #'md-mode--toc-mouse-visit))
              (md-mode--toc-refresh)
              (should (equal (buffer-string) "One\n  Two\n")))
            (select-window (get-buffer-window toc))
            (with-current-buffer toc
              (md-mode--toc-quit))
            (should-not (get-buffer-window toc))
            (should (get-buffer-window source)))
        (when (buffer-live-p toc)
          (kill-buffer toc))
        (kill-buffer source)))))

(ert-deftest md-mode-toc-refreshes-once-after-source-edits ()
  (save-window-excursion
    (let ((source (generate-new-buffer " *md-mode-toc-live*"))
          toc marker)
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) source)
            (with-current-buffer source
              (insert "# One\n")
              (md-mode)
              (md-mode-toggle-toc)
              (setq toc md-mode--toc-buffer)
              (goto-char (point-max))
              (insert "## Two\n")
              (should md-mode--toc-dirty-p)
              (with-current-buffer toc
                (should (equal (buffer-string) "One\n")))
              (md-mode--toc-refresh-if-dirty)
              (should-not md-mode--toc-dirty-p))
            (with-current-buffer toc
              (should (equal (buffer-string) "One\n  Two\n"))
              (setq marker (car md-mode--toc-markers)))
            (with-current-buffer source
              (md-mode--toc-refresh-if-dirty))
            (with-current-buffer toc
              (should (eq (car md-mode--toc-markers) marker))
              (let ((md-mode--toc-refreshing-p t))
                (md-mode--toc-refresh))
              (should (eq (car md-mode--toc-markers) marker))))
        (when (buffer-live-p toc)
          (kill-buffer toc))
        (kill-buffer source)))))

(ert-deftest md-mode-toc-refreshes-across-rendered-view ()
  (save-window-excursion
    (let ((source (generate-new-buffer " *md-mode-toc-view*"))
          toc source-marker view-marker)
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) source)
            (with-current-buffer source
              (insert "# Root\n## Child\n")
              (md-mode)
              (md-mode-toggle-toc)
              (setq toc md-mode--toc-buffer))
            (with-current-buffer toc
              (setq source-marker (car md-mode--toc-markers)))
            (with-current-buffer source
              (md-mode-render))
            (should-not (marker-buffer source-marker))
            (with-current-buffer toc
              (should (equal (buffer-string) "Root\n  Child\n"))
              (setq view-marker (car md-mode--toc-markers))
              (should (marker-position view-marker)))
            (with-current-buffer source
              (md-mode-show-source))
            (should-not (marker-buffer view-marker))
            (with-current-buffer toc
              (should (equal (buffer-string) "Root\n  Child\n"))))
        (when (buffer-live-p toc)
          (kill-buffer toc))
        (kill-buffer source)))))

(ert-deftest md-mode-source-kill-cleans-up-toc ()
  (save-window-excursion
    (let ((source (generate-new-buffer " *md-mode-toc-kill-source*"))
          toc marker)
      (set-window-buffer (selected-window) source)
      (with-current-buffer source
        (insert "# Heading\n")
        (md-mode)
        (md-mode-toggle-toc)
        (setq toc md-mode--toc-buffer))
      (with-current-buffer toc
        (setq marker (car md-mode--toc-markers)))
      (kill-buffer source)
      (should-not (buffer-live-p toc))
      (should-not (marker-buffer marker))
      (should-not (get-buffer-window toc)))))

(ert-deftest md-mode-toc-detaches-on-direct-kill-and-mode-change ()
  (save-window-excursion
    (let ((source (generate-new-buffer " *md-mode-toc-detach*"))
          toc toc-window replacement)
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) source)
            (with-current-buffer source
              (insert "# Heading\n")
              (md-mode)
              (md-mode-toggle-toc)
              (setq toc md-mode--toc-buffer
                    toc-window (get-buffer-window toc)))
            (kill-buffer toc)
            (should-not (window-live-p toc-window))
            (with-current-buffer source
              (should-not md-mode--toc-buffer)
              (should-not md-mode--toc-dirty-p)
              (md-mode-toggle-toc)
              (setq replacement md-mode--toc-buffer)
              (md-mode-render)
              (fundamental-mode)
              (should (equal (buffer-string) "# Heading\n")))
            (should-not (buffer-live-p replacement)))
        (when (buffer-live-p replacement)
          (kill-buffer replacement))
        (kill-buffer source)))))

(ert-deftest md-mode-inserts-list-items ()
  (with-temp-buffer
    (insert "7. ordered")
    (md-mode)
    (goto-char (point-max))
    (md-mode-insert-list-item)
    (should (equal (buffer-string) "7. ordered\n8. ")))
  (with-temp-buffer
    (insert "  - nested")
    (md-mode)
    (goto-char (point-max))
    (md-mode-insert-list-item)
    (should (equal (buffer-string) "  - nested\n  - "))))

(ert-deftest md-mode-edits-and-moves-list-structure ()
  (with-temp-buffer
    (insert "- One\n  - Child\n- Two\n")
    (md-mode)
    (goto-char (point-min))
    (md-mode-move-down)
    (should (equal (buffer-string)
                   "- Two\n- One\n  - Child\n"))
    (md-mode-tab)
    (should (looking-at "  - One"))
    (md-mode-backtab)
    (should (looking-at "- One"))
    (md-mode-cycle-list-marker)
    (beginning-of-line)
    (should (looking-at "\\* One"))
    (md-mode-cycle-list-marker)
    (beginning-of-line)
    (should (looking-at "1\\. One"))
    (md-mode-cycle-list-marker)
    (beginning-of-line)
    (should (looking-at "- One"))))

(ert-deftest md-mode-inserts-todo-items ()
  (with-temp-buffer
    (insert "  * [ ] First")
    (md-mode)
    (goto-char (point-max))
    (md-mode-insert-todo-item)
    (should (equal (buffer-string) "  * [ ] First\n  * [ ] ")))
  (with-temp-buffer
    (insert "Text")
    (md-mode)
    (goto-char (point-max))
    (md-mode-insert-todo-item)
    (should (equal (buffer-string) "Text\n- [ ] "))))

(ert-deftest md-mode-toggles-todo-items ()
  (with-temp-buffer
    (insert "- [ ] Open\n1. [x] Done")
    (md-mode)
    (goto-char (point-min))
    (md-mode-toggle-todo)
    (forward-line 1)
    (md-mode-toggle-todo)
    (should (equal (buffer-string) "- [x] Open\n1. [ ] Done")))
  (with-temp-buffer
    (insert "Prose [ ]")
    (md-mode)
    (should-error (md-mode-toggle-todo) :type 'user-error)))

(ert-deftest md-mode-inserts-and-adjusts-headings ()
  (with-temp-buffer
    (insert "## Section\nBody")
    (md-mode)
    (goto-char (point-max))
    (md-mode-insert-heading)
    (should (equal (buffer-string) "## Section\nBody\n## "))
    (insert "Sibling")
    (md-mode-promote-heading)
    (beginning-of-line)
    (should (looking-at "# Sibling"))
    (md-mode-demote-heading)
    (should (looking-at "## Sibling"))))

(ert-deftest md-mode-adjusts-and-moves-heading-subtrees ()
  (with-temp-buffer
    (insert (concat "# Parent\nBody\n## Child\nChild body\n"
                    "```markdown\n## Literal\n```\n# Next\n"))
    (md-mode)
    (goto-char (point-min))
    (md-mode-demote-heading)
    (should
     (equal (buffer-string)
            (concat "## Parent\nBody\n### Child\nChild body\n"
                    "```markdown\n## Literal\n```\n# Next\n")))
    (md-mode-promote-heading)
    (md-mode-move-down)
    (should
     (equal (buffer-string)
            (concat "# Next\n# Parent\nBody\n## Child\nChild body\n"
                    "```markdown\n## Literal\n```\n")))))

(ert-deftest md-mode-folds-and-navigates-heading-tree ()
  (with-temp-buffer
    (insert "# Root\nBody\n## One\nText\n## Two\nText\n# Next\n")
    (md-mode)
    (goto-char (point-min))
    (md-mode-tab)
    (should (outline-invisible-p (line-end-position)))
    (md-mode-tab)
    (md-mode-tab)
    (should-not (outline-invisible-p (line-end-position)))
    (search-forward "## One")
    (beginning-of-line)
    (md-mode-forward-same-level)
    (should (looking-at "## Two"))
    (md-mode-up-heading)
    (should (looking-at "# Root"))
    (md-mode-forward-same-level)
    (should (looking-at "# Next"))
    (md-mode-backward-same-level)
    (should (looking-at "# Root"))))

(ert-deftest md-mode-folds-front-matter-and-fenced-code ()
  (with-temp-buffer
    (insert (concat "---\ntitle: Example\ntags: [one, two]\n---\n"
                    "# Heading\n```elisp\n(message \"hello\")\n```\n"))
    (md-mode)
    (set-buffer-modified-p nil)
    (goto-char (point-min))
    (md-mode-tab)
    (should (outline-invisible-p (line-beginning-position 2)))
    (should-not (buffer-modified-p))
    (md-mode-tab)
    (should-not (outline-invisible-p (line-beginning-position 2)))
    (search-forward "```elisp")
    (beginning-of-line)
    (md-mode-tab)
    (should (outline-invisible-p (line-beginning-position 2)))
    (md-mode-tab)
    (should-not (outline-invisible-p (line-beginning-position 2)))))

(ert-deftest md-mode-optionally-folds-front-matter-on-open ()
  (with-temp-buffer
    (let ((md-mode-fold-front-matter-on-open t))
      (insert "---\ntitle: Example\n---\n# Heading\n")
      (md-mode)
      (goto-char (point-min))
      (should (outline-invisible-p (line-beginning-position 2))))))

(ert-deftest md-mode-org-style-key-bindings ()
  (with-temp-buffer
    (md-mode)
    (should (eq (key-binding (kbd "C-n")) #'next-line))
    (should (eq (key-binding (kbd "C-p")) #'previous-line))
    (should (eq (key-binding (kbd "M-RET")) #'md-mode-insert-list-item))
    (should (eq (key-binding (kbd "M-S-RET"))
                #'md-mode-insert-todo-item))
    (should (eq (key-binding (kbd "M-S-<return>"))
                #'md-mode-insert-todo-item))
    (should (eq (key-binding (kbd "C-c C-c"))
                #'md-mode-context-action))
    (should (eq (key-binding (kbd "S-TAB")) #'md-mode-backtab))
    (should (eq (key-binding (kbd "<backtab>")) #'md-mode-backtab))
    (should (eq (key-binding (kbd "M-<up>")) #'md-mode-move-up))
    (should (eq (key-binding (kbd "M-<down>")) #'md-mode-move-down))
    (should (eq (key-binding (kbd "M-S-<left>"))
                #'md-mode-delete-table-column))
    (should (eq (key-binding (kbd "M-S-<right>"))
                #'md-mode-insert-table-column))
    (should (eq (key-binding (kbd "M-S-<up>"))
                #'md-mode-delete-table-row))
    (should (eq (key-binding (kbd "M-S-<down>"))
                #'md-mode-insert-table-row))
    (should (eq (key-binding (kbd "C-c C-u")) #'md-mode-up-heading))
    (should (eq (key-binding (kbd "C-c C-n")) #'md-mode-next-heading))
    (should (eq (key-binding (kbd "C-c C-p"))
                #'md-mode-previous-heading))
    (should (eq (key-binding (kbd "C-c C-f"))
                #'md-mode-forward-same-level))
    (should (eq (key-binding (kbd "C-c C-b"))
                #'md-mode-backward-same-level))
    (should (eq (key-binding (kbd "C-c C-j")) #'md-mode-goto-heading))
    (should (eq (key-binding (kbd "C-c C-o")) #'md-mode-open-at-point))
    (should (eq (key-binding (kbd "C-c -"))
                #'md-mode-cycle-list-marker))
    (should (eq (key-binding (kbd "M-h")) #'md-mode-mark-element))
    (should (eq (key-binding (kbd "C-c @")) #'md-mode-mark-subtree))
    (should (eq (key-binding (kbd "C-RET")) #'md-mode-insert-heading))
    (should (eq (key-binding (kbd "M-<left>")) #'md-mode-promote-heading))
    (should (eq (key-binding (kbd "M-<right>")) #'md-mode-demote-heading))))

(ert-deftest md-mode-inserts-links-and-images ()
  (with-temp-buffer
    (md-mode)
    (md-mode-insert-link 'web "https://example.com" "Example")
    (insert "\n")
    (md-mode-insert-link 'file "docs/guide.md" "Guide")
    (insert "\n")
    (md-mode-insert-link 'email "me@example.com" "Mail")
    (insert "\n")
    (md-mode-insert-image "images/chart.png" "Chart")
    (insert "\n")
    (md-mode-insert-link 'file "docs/user guide.md" "User guide")
    (should
     (equal (buffer-string)
            (concat "[Example](https://example.com)\n"
                    "[Guide](docs/guide.md)\n"
                    "[Mail](mailto:me@example.com)\n"
                    "![Chart](images/chart.png)\n"
                    "[User guide](<docs/user guide.md>)")))))

(ert-deftest md-mode-edit-links-are-clickable ()
  (with-temp-buffer
    (insert "[web](https://example.com) [file](<docs/user guide.md>)")
    (md-mode)
    (font-lock-ensure)
    (dolist (label '("web" "file"))
      (goto-char (point-min))
      (search-forward label)
      (let ((map (get-text-property (1- (point)) 'keymap)))
        (should (keymapp map))
        (should (eq (lookup-key map [mouse-1])
                    #'md-mode--mouse-open-at-point))
        (should (eq (lookup-key map (kbd "RET"))
                    #'md-mode-open-at-point))
        (should (eq (get-text-property (1- (point)) 'mouse-face)
                    'highlight))))
    (let (opened)
      (cl-letf (((symbol-function 'mouse-set-point) (lambda (_event) nil))
                ((symbol-function 'find-file)
                 (lambda (file) (setq opened file))))
        (goto-char (point-min))
        (search-forward "file")
        (md-mode--mouse-open-at-point nil))
      (should (equal opened
                     (expand-file-name "docs/user guide.md"
                                       default-directory))))))

(ert-deftest md-mode-edits-and-opens-links-at-point ()
  (with-temp-buffer
    (insert "[Docs](guide.md)")
    (md-mode)
    (goto-char 3)
    (md-mode-insert-link 'file "new guide.md" "Guide")
    (should (equal (buffer-string) "[Guide](<new guide.md>)"))
    (let (opened)
      (cl-letf (((symbol-function 'find-file)
                 (lambda (file) (setq opened file))))
        (md-mode-open-at-point))
      (should (equal opened
                     (expand-file-name "new guide.md"
                                       default-directory))))))

(ert-deftest md-mode-inserts-quote-code-and-callout ()
  (with-temp-buffer
    (insert "quoted")
    (md-mode)
    (set-mark (point-min))
    (activate-mark)
    (md-mode-insert-blockquote)
    (should (equal (buffer-string) "> quoted")))
  (with-temp-buffer
    (insert "code")
    (md-mode)
    (set-mark (point-min))
    (activate-mark)
    (md-mode-insert-code)
    (should (equal (buffer-string) "`code`")))
  (with-temp-buffer
    (insert "line 1\nline 2")
    (md-mode)
    (set-mark (point-min))
    (activate-mark)
    (md-mode-insert-code nil "text")
    (should
     (equal (buffer-string)
            "```text\nline 1\nline 2\n```")))
  (with-temp-buffer
    (insert "first\nsecond")
    (md-mode)
    (set-mark (point-min))
    (activate-mark)
    (md-mode-insert-callout "TIP")
    (should
     (equal (buffer-string)
            "> [!TIP]\n> first\n> second"))))

(ert-deftest md-mode-styles-callouts-and-binds-insertion-commands ()
  (with-temp-buffer
    (insert "> [!WARNING]\n> Careful\n")
    (md-mode)
    (font-lock-ensure)
    (should (md-mode-tests--has-face-p "[!WARNING]" 'md-mode-callout))
    (should (eq (key-binding (kbd "C-c C-l")) #'md-mode-insert-link))
    (should (eq (key-binding (kbd "C-c C-i")) #'md-mode-insert-image))
    (should (eq (key-binding (kbd "C-c C-s l")) #'md-mode-insert-link))
    (should (eq (key-binding (kbd "C-c C-s q"))
                #'md-mode-insert-blockquote))
    (should (eq (key-binding (kbd "C-c C-s c")) #'md-mode-insert-code))
    (should (eq (key-binding (kbd "C-c C-s a"))
                #'md-mode-insert-callout))))

(ert-deftest md-mode-context-action-and-element-selection ()
  (with-temp-buffer
    (let ((md-mode-auto-align-tables nil))
      (insert "| A | B |\n|---|---|\n| longer | x |\n")
      (md-mode))
    (goto-char (point-min))
    (md-mode-context-action)
    (should (equal (buffer-string)
                   "| A      | B |\n|--------|---|\n| longer | x |\n"))
    (md-mode-mark-element)
    (should (equal (buffer-substring-no-properties
                    (region-beginning) (region-end))
                   (buffer-string))))
  (with-temp-buffer
    (insert "> One\n> Two\n\nParagraph\n")
    (md-mode)
    (goto-char (point-min))
    (md-mode-mark-element)
    (should (equal (buffer-substring-no-properties
                    (region-beginning) (region-end))
                   "> One\n> Two\n"))))

(ert-deftest md-mode-styles-fenced-code-blocks ()
  (with-temp-buffer
    (insert "```elisp\n(message \"**not bold**\")\n| A | B |\n|---|---|\n```\n")
    (md-mode)
    (font-lock-ensure)
    (should (md-mode-tests--has-face-p "```elisp"
                                      'md-render-source-block-language))
    (should (md-mode-tests--has-face-p "(message" 'md-render-source-block))
    (should-not (md-mode-tests--has-face-p "not bold" 'md-render-bold))
    (md-mode-tests--face-at "| A")
    (should-not (get-text-property (- (point) 3) 'display))))

(ert-deftest md-mode-syntax-propertize-respects-start ()
  (with-temp-buffer
    (insert "```text\nfirst\n```\n\n```text\nsecond\n```\n")
    (md-mode)
    (goto-char (point-min))
    (search-forward "```text")
    (let ((first-fence (match-beginning 0)))
      (search-forward "```text")
      (let ((start (match-beginning 0)))
        (remove-text-properties
         (point-min) start '(syntax-table nil syntax-multiline nil))
        (md-mode--syntax-propertize start (point-max))
        (should-not (get-text-property first-fence 'syntax-table))
        (should (get-text-property start 'syntax-table))))))

(ert-deftest md-mode-styles-and-aligns-tables ()
  (with-temp-buffer
    (let ((md-mode-auto-align-tables nil)
          (source
           "| Name | Description |\n|---|---|\n| A | Longer |\n\nprose | text\n"))
      (insert source)
      (md-mode)
      (font-lock-ensure)
      (should (equal (buffer-string) source)))
    (should (md-mode-tests--has-face-p "Name" 'md-render-table-header))
    (search-backward "Name")
    (should (eq (car (get-text-property (point) 'face)) 'fixed-pitch))
    (should (md-mode-tests--has-face-p "---" 'md-render-table-border))
    (goto-char (point-min))
    (should (equal (get-text-property (point) 'display) "│"))
    (forward-line 1)
    (should (equal (get-text-property (point) 'display) "├"))
    (search-forward "-")
    (should (string-match-p
             "\\` +\\'"
             (get-text-property (1- (point)) 'display)))
    (search-forward "|")
    (should (equal (get-text-property (1- (point)) 'display) "┼"))
    (search-forward "prose |")
    (should-not (get-text-property (1- (point)) 'display))
    (md-mode-tests--face-at "Name")
    (call-interactively (key-binding (kbd "TAB")))
    (should (looking-at "Description"))
    (should-not (string-match-p "+" (buffer-string)))
    (should (string-match-p "| A +| Longer +|" (buffer-string)))
    (font-lock-ensure)
    (goto-char (point-min))
    (should (equal (get-text-property (point) 'display) "│"))))

(ert-deftest md-mode-clip-wide-tables-option ()
  ;; Wide rows are scrollable by default in both views: `truncate-lines'
  ;; on, no overflow overlays.  Enabling the clip restores the
  ;; fringe-dot truncation.
  (let ((md-mode-clip-wide-tables nil))
    (with-temp-buffer
      (insert "| A | B |\n|---|---|\n| x | y |\n")
      (md-mode)
      (should truncate-lines)
      (should-not (overlays-in (point-min) (point-max)))
      (md-mode-toggle-markup)
      (should truncate-lines)))
  (let ((md-mode-clip-wide-tables t))
    (with-temp-buffer
      (insert "| A | B |\n|---|---|\n| x | y |\n")
      (md-mode)
      (should-not truncate-lines))))

(ert-deftest md-mode-aligns-table-padding-by-pixel-width ()
  (with-temp-buffer
    (let ((md-mode-auto-align-tables nil))
      (insert "| Name | Value |\n|---|---|\n| A | B |\n")
      (md-mode)
      (font-lock-ensure))
    (goto-char (point-min))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
              ((symbol-function 'string-pixel-width)
               (lambda (string)
                 (if (equal (substring-no-properties string) " ")
                     10
                   20))))
      (should (md-mode--match-table-padding (point-max)))
      (should (equal (get-text-property (match-beginning 0) 'display)
                     '(space :width (50)))))))

(ert-deftest md-mode-creates-standard-table ()
  (with-temp-buffer
    (md-mode)
    (md-mode-insert-table 3 2)
    (should
     (equal (buffer-string)
            (concat "|   |   |   |\n"
                    "|---|---|---|\n"
                    "|   |   |   |\n"
                    "|   |   |   |")))
    (should (= (line-number-at-pos) 1))
    (should (= (current-column) 2))))

(ert-deftest md-mode-rejects-invalid-table-creation ()
  (with-temp-buffer
    (md-mode)
    (should-error (md-mode-insert-table 0 2) :type 'user-error)
    (should-error (md-mode-insert-table 2 0) :type 'user-error)
    (should-error (md-mode-insert-table "2" 2) :type 'user-error)
    (insert "# Rendered\n")
    (md-mode-render)
    (should-error (md-mode-insert-table 2 2) :type 'user-error))
  (with-temp-buffer
    (insert "```text\ninside\n```\n")
    (md-mode)
    (goto-char (point-min))
    (forward-line 1)
    (should-error (md-mode-insert-table 2 2) :type 'user-error)))

(ert-deftest md-mode-prompts-for-table-size-once ()
  (with-temp-buffer
    (md-mode)
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _) "2 x 1")))
      (call-interactively #'md-mode-insert-table))
    (should
     (equal (buffer-string)
            (concat "|   |   |\n"
                    "|---|---|\n"
                    "|   |   |")))))

(ert-deftest md-mode-deletes-whole-table-only ()
  (with-temp-buffer
    (insert (concat "Before\n\n"
                    "| A | B |\n"
                    "|---|---|\n"
                    "| 1 | 2 |\n"
                    "\nAfter\n"))
    (md-mode)
    (goto-char (point-min))
    (search-forward "A")
    (md-mode-delete-table)
    (should (equal (buffer-string) "Before\n\n\nAfter\n"))))

(ert-deftest md-mode-rejects-invalid-table-deletion ()
  (with-temp-buffer
    (insert "| A | B |\n| 1 | 2 |\n")
    (md-mode)
    (should-error (md-mode-delete-table) :type 'user-error))
  (with-temp-buffer
    (insert "| A | B |\n|---|---|\n")
    (md-mode)
    (md-mode-render)
    (should-error (md-mode-delete-table) :type 'user-error)))

(ert-deftest md-mode-table-command-creates-or-aligns ()
  (with-temp-buffer
    (md-mode)
    (should (eq (key-binding (kbd "C-c |")) #'md-mode-table))
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _) "2 x 1")))
      (md-mode-table))
    (should (equal (buffer-string)
                   "|   |   |\n|---|---|\n|   |   |")))
  (with-temp-buffer
    (let ((md-mode-auto-align-tables nil))
      (insert "| Name | Use |\n|---|---|\n| A | Longer text |\n")
      (md-mode))
    (goto-char (point-min))
    (md-mode-table)
    (should
     (equal (buffer-string)
            (concat "| Name | Use         |\n"
                    "|------|-------------|\n"
                    "| A    | Longer text |\n")))))

(ert-deftest md-mode-table-lifecycle-preserves-context ()
  (with-temp-buffer
    (insert "Before\n  \nAfter\n")
    (md-mode)
    (goto-char (point-min))
    (forward-line 1)
    (md-mode-insert-table 2 1)
    (should
     (equal (buffer-string)
            (concat "Before\n"
                    "  |   |   |\n"
                    "  |---|---|\n"
                    "  |   |   |\n"
                    "After\n"))))
  (with-temp-buffer
    (insert "Before")
    (md-mode)
    (goto-char (point-max))
    (md-mode-insert-table 1 1)
    (should
     (equal (buffer-string)
            "Before\n|   |\n|---|\n|   |"))))

(ert-deftest md-mode-table-deletion-is-undoable ()
  (with-temp-buffer
    (insert "| A |\n|---|\n| 1 |\n")
    (md-mode)
    (buffer-enable-undo)
    (goto-char (point-min))
    (setq buffer-undo-list nil)
    (md-mode-delete-table)
    (undo-boundary)
    (undo)
    (should (equal (buffer-string) "| A |\n|---|\n| 1 |\n"))))

(ert-deftest md-mode-moves-table-rows-and-columns ()
  (with-temp-buffer
    (let ((md-mode-auto-align-tables nil))
      (insert (concat "| A | B | C |\n"
                      "|---|---|---|\n"
                      "| 1 | 2 | 3 |\n"
                      "| 4 | 5 | 6 |\n"))
      (md-mode))
    (goto-char (point-min))
    (search-forward "B")
    (md-mode-demote-heading)
    (should
     (equal (buffer-string)
            (concat "| A | C | B |\n"
                    "|---|---|---|\n"
                    "| 1 | 3 | 2 |\n"
                    "| 4 | 6 | 5 |\n"))))
  (with-temp-buffer
    (let ((md-mode-auto-align-tables nil))
      (insert (concat "| A | B |\n|---|---|\n"
                      "| 1 | 2 |\n| 3 | 4 |\n"))
      (md-mode))
    (goto-char (point-min))
    (forward-line 2)
    (md-mode-move-down)
    (should
     (equal (buffer-string)
            (concat "| A | B |\n|---|---|\n"
                    "| 3 | 4 |\n| 1 | 2 |\n")))))

(ert-deftest md-mode-inserts-and-deletes-table-rows-and-columns ()
  (with-temp-buffer
    (let ((md-mode-auto-align-tables nil))
      (insert "| A | B |\n|---|---|\n| 1 | 2 |\n")
      (md-mode))
    (goto-char (point-min))
    (search-forward "A")
    (md-mode-insert-table-column)
    (should (= (length (md-mode--table-row-cells)) 3))
    (md-mode-delete-table-column)
    (should (equal (buffer-string)
                   "| A | B |\n|---|---|\n| 1 | 2 |\n"))
    (forward-line 2)
    (md-mode-insert-table-row)
    (should (= (length (md-mode--table-rows
                        (nth 0 (md-mode--table-bounds))
                        (nth 1 (md-mode--table-bounds))))
               4))
    (md-mode-delete-table-row)
    (should (equal (buffer-string)
                   "| A | B |\n|---|---|\n| 1 | 2 |\n"))))

(ert-deftest md-mode-tables-do-not-load-org-table ()
  (should-not (featurep 'org-table)))

(ert-deftest md-mode-aligns-markdown-table-syntax ()
  (with-temp-buffer
    (let ((md-mode-auto-align-tables nil))
      (insert (concat "| Key | Alignment | Value |\n"
                      "| :--- | :---: | ---: |\n"
                      "| 0 | x \\| y | 12 |\n"))
      (md-mode))
    (md-mode-align-tables)
    (should
     (equal (buffer-string)
            (concat "| Key | Alignment | Value |\n"
                    "|:----|:---------:|------:|\n"
                    "| 0   |  x \\| y   |    12 |\n")))
    (font-lock-ensure)
    (goto-char (point-min))
    (search-forward "\\|")
    (should-not (get-text-property (1- (point)) 'display))))

(ert-deftest md-mode-table-separator-display-preserves-width ()
  (with-temp-buffer
    (insert "| Name | Width | Key Changes |\n|---|---|---|\n| Max | 1584px | Carbon max grid |\n")
    (md-mode)
    (font-lock-ensure)
    (goto-char (point-min))
    (forward-line 1)
    (re-search-forward "-+")
    (let ((source-width (- (match-end 0) (match-beginning 0)))
          (display (get-text-property (match-beginning 0) 'display)))
      (should (= (string-width display) source-width))
      (should (string-match-p "\\` +\\'" display)))))

(ert-deftest md-mode-truncates-wide-table-without-changing-source ()
  ;; With `md-mode-clip-wide-tables' enabled, wide rows get a
  ;; fringe-dots overflow overlay while the source stays untouched.
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *md-mode-wide-table*"))
          (md-mode-clip-wide-tables t))
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) buffer)
            (with-current-buffer buffer
              (let* ((md-mode-auto-align-tables nil)
                     (source
                      (concat "| Name | Description |\n"
                              "|---|---|\n"
                              "| A | "
                              (make-string (+ (window-body-width) 20) ?x)
                              " |\n")))
                (insert source)
                (setq-local truncate-lines nil)
                (md-mode)
                (font-lock-ensure)
                (let (overflow)
                  (dolist (overlay (overlays-in (point-min) (point-max)))
                    (when (eq (overlay-get overlay 'category)
                              'md-mode-table-overflow)
                      (setq overflow overlay)))
                  (should overflow)
                  (should (eq (overlay-get overflow 'window)
                              (selected-window)))
                  (should (overlay-get overflow 'invisible))
                  (should (equal (buffer-string) source))))))
        (kill-buffer buffer)))))

(ert-deftest md-mode-auto-aligns-tables-on-open ()
  (with-temp-buffer
    (insert "| Level | Treatment | Use |\n|---|---|---|\n| 0 | No shadow | Default |\n")
    (set-buffer-modified-p nil)
    (md-mode)
    (should-not (buffer-modified-p))
    (should
     (equal (buffer-string)
            (concat "| Level | Treatment | Use     |\n"
                    "|-------|-----------|---------|\n"
                    "| 0     | No shadow | Default |\n")))))

(ert-deftest md-mode-aligning-does-not-leak-syntax-markers ()
  (with-temp-buffer
    (let ((md-mode-auto-align-tables nil))
      (insert "| A | B |\n|---|---|\n| x | y |\n")
      (md-mode))
    (md-mode-align-tables)
    (internal--syntax-propertize (point-max))
    (let ((position (and syntax-ppss-wide (caar syntax-ppss-wide))))
      (should-not (and (markerp position)
                       (null (marker-buffer position)))))))

(ert-deftest md-mode-render-round-trips-source ()
  (with-temp-buffer
    (insert md-mode-tests--source)
    (md-mode)
    (set-buffer-modified-p nil)
    (md-mode-render)
    (should md-mode--rendered-p)
    (should buffer-read-only)
    (should-not (equal (buffer-string) md-mode-tests--source))
    (md-mode-show-source)
    (should-not md-mode--rendered-p)
    (should-not buffer-read-only)
    (should-not (buffer-modified-p))
    (should (equal (buffer-string) md-mode-tests--source))))

(ert-deftest md-mode-show-source-keeps-current-rendered-position ()
  (with-temp-buffer
    (insert "# First\n\n## Edit here.\n")
    (md-mode)
    (goto-char (point-min))
    (md-mode-render)
    (goto-char (point-min))
    (search-forward "Edit here.")
    (goto-char (match-beginning 0))
    (md-mode-show-source)
    (should (looking-at-p "Edit here."))))

(ert-deftest md-mode-toggle-markup-keeps-current-screen-row ()
  (save-window-excursion
    (with-temp-buffer
      (let ((window (selected-window)))
        (set-window-buffer window (current-buffer))
        (insert "# First\n\nBefore\n\n"
                "```text\none\ntwo\n```\n\n"
                "## Point B\nAfter\n")
        (md-mode)
        (goto-char (point-min))
        (search-forward "Point B")
        (goto-char (match-beginning 0))
        (set-window-start window (point-min))
        (let (recenter-rows)
          (cl-letf (((symbol-function 'window-line-height)
                     (lambda (&rest _) '(1 7 7 0)))
                    ((symbol-function 'recenter)
                     (lambda (row)
                       (push row recenter-rows))))
            (md-mode-toggle-markup)
            (should (looking-at-p "Point B"))
            (md-mode-toggle-markup)
            (should (looking-at-p "Point B")))
          (should (equal (nreverse recenter-rows) '(7 7))))))))

(ert-deftest md-mode-first-render-survives-initial-fontification ()
  (with-temp-buffer
    (insert "# Title\n\nBody\n")
    (md-mode)
    (md-mode-render)
    (font-lock-ensure)
    (should (md-mode-tests--has-face-p "Title"
                                      'md-render-header-1))
    (md-mode-show-source)
    (font-lock-ensure)
    (should (md-mode-tests--has-face-p "Title"
                                      'md-render-header-1))))

(ert-deftest md-mode-render-transitions-do-not-run-edit-hooks ()
  (with-temp-buffer
    (insert "# Title\n")
    (md-mode)
    (let ((changes 0))
      (add-hook 'after-change-functions
                (lambda (&rest _)
                  (setq changes (1+ changes)))
                nil t)
      (md-mode-render)
      (should (= changes 0))
      (md-mode-show-source)
      (should (= changes 0)))))

(ert-deftest md-mode-mermaid-renders-image-and-restores-code ()
  (with-temp-buffer
    (let ((source "```mermaid\ngraph TD\n  A --> B\n```\n")
          (md-render-math-enabled nil)
          (md-render-mermaid-enabled t))
      (cl-letf (((symbol-function 'display-graphic-p)
                 (lambda (&rest _) t))
                ((symbol-function 'executable-find)
                 (lambda (command)
                   (and (equal command "mmdc") "/fake/mmdc")))
                ((symbol-function 'file-exists-p)
                 (lambda (_file) t))
                ((symbol-function 'create-image)
                 (lambda (&rest _) '(image :type png :fake t))))
        (insert source)
        (md-mode)
        (should (equal (buffer-string) source))
        (md-mode-render)
        (should (equal (get-text-property 2 'display)
                       '(image :type png :fake t)))
        (md-mode-show-source)
        (should (equal (buffer-string) source))))))

(ert-deftest md-mode-first-render-applies-async-media-callback ()
  (let ((cache-directory (make-temp-file "md-mode-media-" t))
        sentinel)
    (unwind-protect
        (with-temp-buffer
          (let ((source "```mermaid\ngraph TD\n  A --> B\n```\n")
                (md-render-cache-directory cache-directory)
                (md-render-math-enabled nil)
                (md-render-mermaid-enabled t))
            (cl-letf (((symbol-function 'display-graphic-p)
                       (lambda (&rest _) t))
                      ((symbol-function 'executable-find)
                       (lambda (command)
                         (and (equal command "mmdc") "/fake/mmdc")))
                      ((symbol-function 'make-process)
                       (lambda (&rest arguments)
                         (setq sentinel (plist-get arguments :sentinel))
                         'fake-process))
                      ((symbol-function 'process-status)
                       (lambda (_process) 'exit))
                      ((symbol-function 'process-exit-status)
                       (lambda (_process) 0))
                      ((symbol-function 'create-image)
                       (lambda (&rest _) '(image :type png :fake t))))
              (insert source)
              (md-mode)
              (md-mode-render)
              (should sentinel)
              (let* ((position
                      (text-property-not-all
                       (point-min) (point-max)
                       'md-render-media-file nil))
                     (file
                      (and position
                           (get-text-property
                            position 'md-render-media-file))))
                (should position)
                (should-not (get-text-property position 'display))
                (write-region "" nil file nil 'silent)
                (funcall sentinel 'fake-process "finished\n")
                (should (equal (get-text-property position 'display)
                               '(image :type png :fake t))))
              (md-mode-show-source)
              (should (equal (buffer-string) source)))))
      (clrhash md-render--media-jobs)
      (delete-directory cache-directory t))))

(ert-deftest md-mode-render-preserves-callout-display-properties ()
  (with-temp-buffer
    (insert "> [!TIP]\n> Useful body\n")
    (md-mode)
    (font-lock-ensure)
    (md-mode-render)
    (font-lock-fontify-region (point-min) (point-max))
    (should (equal (substring-no-properties
                    (get-text-property (point-min) 'display))
                   "▎"))
    (md-mode-show-source)
    (should (memq 'display font-lock-extra-managed-props))))

(ert-deftest md-mode-save-writes-source ()
  (let ((file (make-temp-file "md-mode-test-" nil ".md")))
    (unwind-protect
        (with-temp-buffer
          (insert md-mode-tests--source)
          (set-visited-file-name file)
          (md-mode)
          (set-buffer-modified-p t)
          (md-mode-render)
          (save-buffer)
          (should-not md-mode--rendered-p)
          (should
           (equal (with-temp-buffer
                    (insert-file-contents file)
                    (buffer-string))
                  md-mode-tests--source)))
      (delete-file file))))

(ert-deftest md-mode-render-ignores-stale-visited-file ()
  "Toggling views must not trip the supersession check.
When an external tool rewrites the visited file (docs regenerated
while previewing), the buffer is stale; rendering and the
`before-revert-hook' source restore are view changes, not edits, so
they must not raise the \"changed on disk; really edit the
buffer?\" conflict (a hard error in batch)."
  (let ((file (make-temp-file "md-mode-test-" nil ".md")))
    (unwind-protect
        (with-current-buffer (find-file-noselect file)
          (insert md-mode-tests--source)
          (save-buffer)
          (md-mode)
          ;; Rewrite the file behind the buffer's back.
          (write-region "# Regenerated\n\nNew **body**.\n" nil file)
          ;; First render on a stale buffer must succeed.
          (md-mode-render)
          (should md-mode--rendered-p)
          ;; Auto-revert path: show-source runs from `before-revert-hook'
          ;; on the stale buffer, then the revert loads the new content.
          (revert-buffer :ignore-auto :noconfirm :preserve-modes)
          (should-not md-mode--rendered-p)
          (should (equal (buffer-string) "# Regenerated\n\nNew **body**.\n"))
          ;; And the next render picks up the reverted content.
          (md-mode-render)
          (should md-mode--rendered-p)
          (goto-char (point-min))
          (should-not (search-forward "**" nil t))
          (set-buffer-modified-p nil)
          (kill-buffer))
      (delete-file file))))

(ert-deftest md-mode-change-major-mode-restores-source ()
  (with-temp-buffer
    (insert md-mode-tests--source)
    (md-mode)
    (md-mode-render)
    (fundamental-mode)
    (should (equal (buffer-string) md-mode-tests--source))
    (should-not buffer-read-only)))

(provide 'md-mode-tests)

;;; md-mode-tests.el ends here
