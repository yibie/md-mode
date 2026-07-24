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
  (let ((value (md-mode-tests--face-at text)))
    (or (eq value face)
        (and (listp value) (memq face value)))))

(defun md-mode-tests--imenu-shape (index)
  "Return INDEX titles and hierarchy without target markers."
  (mapcar
   (lambda (entry)
     (if (markerp (cdr entry))
         (car entry)
       (cons (car entry)
             (md-mode-tests--imenu-shape (cddr entry)))))
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

(ert-deftest md-mode-heading-faces-have-distinct-sizes ()
  (should (> (face-attribute 'md-render-header-1 :height nil nil)
             (face-attribute 'md-render-header-2 :height nil nil)))
  (should (> (face-attribute 'md-render-header-2 :height nil nil)
             (face-attribute 'md-render-header-3 :height nil nil))))

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
    (let* ((index (funcall imenu-create-index-function))
           (root (car index))
           (children (cddr root))
           (first-child (car children)))
      (should (equal (mapcar #'car index) '("Root" "Next")))
      (should (= (length children) 2))
      (should (string-prefix-p "Child" (caar children)))
      (should (string-prefix-p "Child" (caadr children)))
      (should-not (equal (caar children) (caadr children)))
      (should (equal (mapcar #'car (cddr first-child))
                     '("Deep")))
      (should (marker-position (cdadr root)))
      (should (eq (marker-buffer (cdadr root)) (current-buffer))))))

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
        (should
         (eq (marker-buffer (cdadar index)) (current-buffer)))))))

(ert-deftest md-mode-goto-heading-keeps-duplicate-titles ()
  (with-temp-buffer
    (insert "# Same\nBody\n## Same\n")
    (md-mode)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _)
                 (caar (last collection)))))
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
      (setq marker
            (cdar (funcall imenu-create-index-function))))
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

(ert-deftest md-mode-org-style-key-bindings ()
  (with-temp-buffer
    (md-mode)
    (should (eq (key-binding (kbd "C-n")) #'md-mode-next-heading))
    (should (eq (key-binding (kbd "C-p")) #'md-mode-previous-heading))
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
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *md-mode-wide-table*")))
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
