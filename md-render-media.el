;;; md-render-media.el --- Images, math and diagrams in Markdown -*- lexical-binding: t; -*-

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

;; Everything that turns Markdown into pictures.  Image markup and bare
;; image paths display the image in place.  The media renderer, the
;; default member of `md-render-render-functions', replaces LaTeX math and
;; Mermaid, PlantUML and Graphviz fences with placeholders and fills them
;; asynchronously from a cache of SVG and PNG files produced by local
;; command-line tools.

;;; Code:

(require 'cl-lib)
(require 'color)
(require 'md-render-core)
(require 'md-render-inline)
(require 'url)
(require 'url-parse)
(require 'url-util)

;;;; Options

(defcustom md-render-math-enabled t
  "When non-nil, preview LaTeX math as images.
Previews need the `emacs', `latex' and `dvisvgm' executables; without
them math stays literal."
  :type 'boolean
  :group 'md-render)

(defcustom md-render-mermaid-enabled t
  "When non-nil, preview Mermaid fences as images.
Previews need `md-render-mermaid-command'."
  :type 'boolean
  :group 'md-render)

(defcustom md-render-mermaid-command "mmdc"
  "Executable of the Mermaid command-line interface."
  :type 'string
  :group 'md-render)

(defcustom md-render-mermaid-browser nil
  "Browser executable handed to the Mermaid command-line interface.
When nil, look for an installed Chrome, Chromium or Brave."
  :type '(choice (const :tag "Detect" nil) file)
  :group 'md-render)

(defcustom md-render-plantuml-enabled t
  "When non-nil, preview PlantUML fences as images.
Previews need `md-render-plantuml-command'."
  :type 'boolean
  :group 'md-render)

(defcustom md-render-plantuml-command "plantuml"
  "Executable of PlantUML."
  :type 'string
  :group 'md-render)

(defcustom md-render-graphviz-enabled t
  "When non-nil, preview Graphviz fences as images.
Previews need `md-render-graphviz-command'."
  :type 'boolean
  :group 'md-render)

(defcustom md-render-graphviz-command "dot"
  "Executable of Graphviz."
  :type 'string
  :group 'md-render)

(defcustom md-render-cache-directory (locate-user-emacs-file "md-render/")
  "Directory that holds generated preview images."
  :type 'directory
  :group 'md-render)

(defcustom md-render-math-scale 1.0
  "Scale factor of math previews."
  :type 'float
  :group 'md-render)

(defcustom md-render-render-functions '(md-render--render-media)
  "Functions that render parts of the buffer before the built-in passes.
Each function is called with the render context, see
`md-render-context', while the buffer is narrowed to the text being
rendered.  A function should mark its output with `md-render-frozen',
store the original Markdown on `md-render-source', and skip frozen
text.  It returns nil or an alist; a `:watermark' entry names a
position that streaming renders must not advance past."
  :type 'hook
  :group 'md-render)

;;;; Image files

(defun md-render--image-max-width ()
  "Return the maximum image width in pixels."
  (if (floatp md-render-image-max-width)
      (round (* md-render-image-max-width
                (window-body-width (or (get-buffer-window (current-buffer) t)
                                       (frame-first-window))
                                   t)))
    md-render-image-max-width))

(cl-defun md-render--url-copy-file
    (&key url file (timeout 5.0) content-type-prefix)
  "Download URL to FILE and return FILE, or nil on failure.
Wait at most TIMEOUT seconds.  When CONTENT-TYPE-PREFIX is non-nil the
response's content type must start with it."
  (when-let* ((buffer (url-retrieve-synchronously url t t timeout)))
    (unwind-protect
        (with-current-buffer buffer
          (let ((case-fold-search t))
            (goto-char (point-min))
            (when (and (re-search-forward "^HTTP/[^ \n]+ +200\\b" nil t)
                       (or (null content-type-prefix)
                           (progn
                             (goto-char (point-min))
                             (re-search-forward
                              (concat "^Content-Type:[ \t]*"
                                      (regexp-quote content-type-prefix))
                              nil t)))
                       (progn
                         (goto-char (point-min))
                         (re-search-forward "\r?\n\r?\n" nil t)))
              (make-directory (file-name-directory file) t)
              (let ((coding-system-for-write 'no-conversion))
                (write-region (point) (point-max) file nil 'silent))
              file)))
      (kill-buffer buffer))))

(defun md-render--fetch-remote-image (url image-cache-directory)
  "Return a cached copy of the image at URL, downloading it if needed.
The copy lives in IMAGE-CACHE-DIRECTORY.  Return nil when URL is not
an http(s) image or cannot be fetched."
  (when-let* (((stringp url))
              ((stringp image-cache-directory))
              ((string-match-p "\\`https?://" url))
              (extension (file-name-extension
                          (replace-regexp-in-string "[?#].*\\'" "" url)))
              (extension (downcase extension))
              ((member extension image-file-name-extensions)))
    (let ((file (expand-file-name (concat (md5 url) "." extension)
                                  image-cache-directory)))
      (if (file-exists-p file)
          file
        (md-render--url-copy-file :url url :file file
                                  :content-type-prefix "image/")))))

(defun md-render--resolve-image-url (url &optional image-cache-directory)
  "Return the existing local file that URL refers to, or nil.
Resolve relative paths against `default-directory'.
Remote images are fetched into IMAGE-CACHE-DIRECTORY when it is given."
  (if (string-match-p "\\`https?://" url)
      (md-render--fetch-remote-image url image-cache-directory)
    (when-let* ((path (cond
                       ((string-prefix-p "file://" url)
                        (url-unhex-string
                         (url-filename (url-generic-parse-url url))))
                       ((string-prefix-p "file:" url) (substring url 5))
                       ((or (file-name-absolute-p url)
                            (string-prefix-p "./" url)
                            (string-prefix-p "../" url))
                        url)
                       ((not (string-match-p
                              "\\`[[:alpha:]][[:alnum:]+.-]*:" url))
                        url)))
                (file (expand-file-name path))
                ((file-exists-p file)))
      file)))

(defun md-render--displayable-image-p (file)
  "Return non-nil when FILE can be displayed as an image here."
  (and file
       (file-exists-p file)
       (image-supported-file-p file)
       (display-graphic-p)))

(defun md-render--file-image (file)
  "Return an image of FILE limited to the maximum image width."
  (let ((image (create-image file nil nil
                             :max-width (md-render--image-max-width))))
    (image-flush image)
    image))

(defun md-render--visit-map (file)
  "Return a keymap that visits FILE."
  (md-render--action-map
   (lambda ()
     (interactive)
     (find-file file))))

;;;; Image markup

(defun md-render--style-images (avoid-ranges image-cache-directory)
  "Display image markup outside AVOID-RANGES.
Remote images are downloaded into IMAGE-CACHE-DIRECTORY when it is
non-nil.  Remote images that cannot be displayed become links; other
unresolvable images stay literal."
  (md-render--rewrite-matches
   (md-render--link-markup-regexp :as-image? t) 0 avoid-ranges
   (lambda ()
     (let* ((start (match-beginning 0))
            (end (match-end 0))
            (alt (match-string 1))
            (url (md-render--link-markup-url))
            (inherited (text-properties-at start))
            (placeholder (if (string-empty-p alt)
                             (apply #'propertize " " inherited)
                           alt))
            (file (md-render--resolve-image-url url image-cache-directory)))
       (cond
        ((md-render--displayable-image-p file)
         (let ((new-end (md-render--replace-markup start end placeholder)))
           (add-text-properties
            start new-end
            `(display ,(md-render--file-image file)
                      keymap ,(md-render--visit-map file)
                      mouse-face highlight))
           new-end))
        ((string-match-p "\\`https?://" url)
         (let ((new-end (md-render--replace-markup
                         start end
                         (if (string-empty-p alt)
                             (apply #'propertize url inherited)
                           alt))))
           (add-face-text-property start new-end 'md-render-link)
           (add-text-properties
            start new-end
            `(keymap ,(md-render--link-map url) mouse-face highlight))
           new-end)))))))

(defun md-render--style-image-paths (avoid-ranges)
  "Display lines that hold only an image path, outside AVOID-RANGES."
  (let ((case-fold-search t)
        (regexp (concat "^[ \t]*\\(\\(?:file://\\|[/~.]\\)[^ \t\n]*\\."
                        (regexp-opt image-file-name-extensions)
                        "\\)[ \t]*$")))
    (goto-char (point-min))
    (while (re-search-forward regexp nil t)
      (let* ((start (match-beginning 1))
             (end (match-end 1))
             (file (unless (md-render-in-avoid-range-p
                            (match-beginning 0) (match-end 0) avoid-ranges)
                     (md-render--resolve-image-url
                      (match-string-no-properties 1)))))
        (when (md-render--displayable-image-p file)
          (add-text-properties
           start end
           `(display ,(md-render--file-image file)
                     keymap ,(md-render--visit-map file)
                     mouse-face highlight
                     md-render-frozen t
                     rear-nonsticky (md-render-frozen))))))))

;;;; Media backends

(defvar md-render--media-jobs (make-hash-table :test #'equal)
  "Pending preview renders, keyed by output file.
Each value lists the watchers waiting for that file.")

(defconst md-render--media-cache-version 3
  "Version of the preview cache format.")

(defconst md-render--media-backends
  '((math :label "Math" :input ".formula" :output ".svg"
          :languages ("math" "latex"))
    (mermaid :label "Mermaid" :input ".mmd" :output ".png"
             :languages ("mermaid"))
    (plantuml :label "PlantUML" :input ".puml" :output ".svg"
              :languages ("plantuml" "puml"))
    (graphviz :label "Graphviz" :input ".dot" :output ".svg"
              :languages ("dot" "graphviz")))
  "Preview backends with their labels, file extensions and languages.")

(defun md-render--backend-property (backend property)
  "Return PROPERTY of media BACKEND."
  (plist-get (alist-get backend md-render--media-backends) property))

(defun md-render--available-backends ()
  "Return the media backends whose tools are installed and enabled."
  (append
   (when (and md-render-math-enabled
              (executable-find "emacs")
              (executable-find "latex")
              (executable-find "dvisvgm"))
     '(math))
   (when (and md-render-mermaid-enabled
              (executable-find md-render-mermaid-command))
     '(mermaid))
   (when (and md-render-plantuml-enabled
              (executable-find md-render-plantuml-command))
     '(plantuml))
   (when (and md-render-graphviz-enabled
              (executable-find md-render-graphviz-command))
     '(graphviz))))

(defun md-render--fenced-media-backend (language available)
  "Return the backend of fence LANGUAGE when it is in AVAILABLE."
  (let ((language (downcase (or language ""))))
    (cl-loop for (backend . properties) in md-render--media-backends
             when (and (member language (plist-get properties :languages))
                       (memq backend available))
             return backend)))

(defun md-render--dark-background-p ()
  "Return non-nil when the default background is dark."
  (let ((background (face-background 'default nil t)))
    (if (and (stringp background) (color-defined-p background))
        (color-dark-p (color-name-to-rgb background))
      (eq (frame-parameter nil 'background-mode) 'dark))))

(defun md-render--theme-foreground ()
  "Return the default foreground color as a string."
  (let ((foreground (face-foreground 'default nil t)))
    (cond
     ((and (stringp foreground) (color-defined-p foreground)) foreground)
     ((md-render--dark-background-p) "#ffffff")
     (t "#000000"))))

(defun md-render--media-cache-file (backend source)
  "Return the cache file for SOURCE rendered by BACKEND.
The name changes with the source and with the colors the preview uses."
  (let* ((background (face-background 'default nil t))
         (appearance (if (eq backend 'math)
                         (list md-render-math-scale
                               (md-render--theme-foreground)
                               background)
                       (list (md-render--theme-foreground)
                             background
                             (md-render--dark-background-p))))
         (key (prin1-to-string
               (list md-render--media-cache-version backend source
                     appearance))))
    (expand-file-name (concat (secure-hash 'sha256 key)
                              (md-render--backend-property backend :output))
                      md-render-cache-directory)))

(defun md-render--plantuml-themed-source (source)
  "Return PlantUML SOURCE adjusted to the current background."
  (if (string-match "^@startuml.*$" source)
      (let ((split (min (length source) (1+ (match-end 0)))))
        (concat (substring source 0 split)
                (if (= split (match-end 0)) "\n" "")
                "skinparam BackgroundColor transparent\n"
                (if (md-render--dark-background-p)
                    "skinparam Monochrome reverse\n"
                  "skinparam Monochrome true\n")
                (substring source split)))
    source))

(defun md-render--mermaid-browser ()
  "Return the browser executable for the Mermaid CLI, or nil."
  (or md-render-mermaid-browser
      (cl-loop for app in '("Google Chrome" "Chromium" "Brave Browser")
               for file = (format "/Applications/%s.app/Contents/MacOS/%s"
                                  app app)
               when (file-executable-p file)
               return file)
      (cl-some #'executable-find
               '("google-chrome" "chromium" "chromium-browser"))))

(defun md-render--math-command (input file)
  "Return the command that renders the math in INPUT to FILE."
  (let ((form
         `(progn
            (require 'org)
            (let ((formula (with-temp-buffer
                             (insert-file-contents ,input)
                             (buffer-string)))
                  (options (copy-sequence org-format-latex-options)))
              (setq options (plist-put options :foreground
                                       ,(md-render--theme-foreground)))
              (setq options (plist-put options :background "Transparent"))
              (setq options (plist-put options :scale ,md-render-math-scale))
              (with-temp-buffer
                (org-mode)
                (org-create-formula-image formula ,file options
                                          (current-buffer) 'dvisvgm))))))
    (list (or (executable-find "emacs") "emacs")
          "-Q" "--batch" "--eval" (prin1-to-string form))))

(defun md-render--media-command (backend input file)
  "Return (COMMAND . ENVIRONMENT) rendering INPUT to FILE with BACKEND."
  (let ((foreground (md-render--theme-foreground)))
    (pcase backend
      ('math (list (md-render--math-command input file)))
      ('mermaid
       (let ((browser (md-render--mermaid-browser)))
         (cons (list (or (executable-find md-render-mermaid-command)
                         md-render-mermaid-command)
                     "--input" input "--output" file
                     "--theme" (if (md-render--dark-background-p)
                                   "dark"
                                 "default")
                     "--backgroundColor" "transparent"
                     "--scale" "1")
               (when browser
                 (list (concat "PUPPETEER_EXECUTABLE_PATH=" browser))))))
      ('plantuml
       (cons (list (or (executable-find md-render-plantuml-command)
                       md-render-plantuml-command)
                   "-tsvg" input)
             '("PLANTUML_SECURITY_PROFILE=SANDBOX")))
      ('graphviz
       (cons (list (or (executable-find md-render-graphviz-command)
                       md-render-graphviz-command)
                   "-Tsvg" "-Gbgcolor=transparent"
                   (concat "-Gfontcolor=" foreground)
                   (concat "-Ncolor=" foreground)
                   (concat "-Nfontcolor=" foreground)
                   (concat "-Ecolor=" foreground)
                   (concat "-Efontcolor=" foreground)
                   input "-o" file)
             '("SERVER_NAME=md-render"))))))

(defun md-render--finish-media-job (file error-message)
  "Deliver FILE, or ERROR-MESSAGE, to every watcher waiting for FILE."
  (let ((watchers (gethash file md-render--media-jobs)))
    (remhash file md-render--media-jobs)
    (dolist (watcher watchers)
      (md-render--media-apply watcher file error-message))))

(defun md-render--media-log-tail (log status)
  "Return the end of LOG, or a message naming the exit STATUS."
  (if (buffer-live-p log)
      (with-current-buffer log
        (string-trim (buffer-substring-no-properties
                      (max (point-min) (- (point-max) 1000))
                      (point-max))))
    (format "Renderer exited with status %d" status)))

(defun md-render--start-media-process (backend source file)
  "Start rendering SOURCE with BACKEND into FILE in the background."
  (make-directory md-render-cache-directory t)
  (let* ((input (concat (file-name-sans-extension file)
                        (md-render--backend-property backend :input)))
         (log (generate-new-buffer (format " *md-render-%s*" backend)))
         (cleanup (lambda ()
                    (when (file-exists-p input)
                      (delete-file input))
                    (when (buffer-live-p log)
                      (kill-buffer log)))))
    (let ((coding-system-for-write 'utf-8))
      (write-region (if (eq backend 'plantuml)
                        (md-render--plantuml-themed-source source)
                      source)
                    nil input nil 'silent))
    (condition-case err
        (pcase-let* ((`(,command . ,environment)
                      (md-render--media-command backend input file))
                     (process-environment
                      (append environment process-environment)))
          (make-process
           :name (format "md-render-%s-%s" backend
                         (substring (file-name-base file) 0 8))
           :buffer log
           :command command
           :connection-type 'pipe
           :noquery t
           :sentinel
           (lambda (process _event)
             (when (memq (process-status process) '(exit signal))
               (let* ((status (process-exit-status process))
                      (message (unless (and (eq (process-status process) 'exit)
                                            (zerop status)
                                            (file-exists-p file))
                                 (md-render--media-log-tail log status))))
                 (funcall cleanup)
                 (md-render--finish-media-job file message))))))
      (error
       (funcall cleanup)
       (md-render--finish-media-job file (error-message-string err))))))

(defun md-render--watch-media (backend source file marker label)
  "Show FILE at MARKER once BACKEND has rendered SOURCE into it.
LABEL names the preview in error messages.  Renders of one file share
a single process."
  (let ((watcher (list (current-buffer) marker label backend)))
    (if (file-exists-p file)
        (md-render--media-apply watcher file nil)
      (let ((waiting (gethash file md-render--media-jobs)))
        (puthash file (append waiting (list watcher)) md-render--media-jobs)
        (unless waiting
          (md-render--start-media-process backend source file))))))

(defun md-render--media-apply (watcher file error-message)
  "Show FILE, or ERROR-MESSAGE, at the placeholder of WATCHER.
Placeholders that no longer expect FILE are left alone."
  (pcase-let ((`(,buffer ,marker ,label ,backend) watcher))
    (when (and (buffer-live-p buffer) (marker-position marker))
      (with-current-buffer buffer
        (let* ((pos (marker-position marker))
               (align (and (eq backend 'math)
                           (> pos (point-min))
                           (get-text-property (1- pos)
                                              'md-render-block-centered)
                           (1- pos))))
          (when (and (< pos (point-max))
                     (equal (get-text-property pos 'md-render-media-file)
                            file))
            (let ((inhibit-read-only t))
              (with-silent-modifications
                (condition-case err
                    (if error-message
                        (md-render--show-media-error pos align label
                                                     error-message)
                      (let ((image (create-image
                                    file nil nil
                                    :ascent 'center
                                    :max-width (md-render--image-max-width))))
                        (put-text-property pos (1+ pos) 'display image)
                        (when align
                          (put-text-property
                           align (1+ align) 'display
                           `(space :align-to (- center (0.5 . ,image)))))))
                  (error
                   (md-render--show-media-error
                    pos align label (error-message-string err))))))
            (force-window-update buffer)))))))

(defun md-render--show-media-error (pos align label message)
  "Show a failed LABEL preview at POS with MESSAGE as its help text.
ALIGN, when non-nil, is the alignment character to reset."
  (put-text-property pos (1+ pos) 'display
                     (propertize (concat "⚠ " label)
                                 'face 'error
                                 'help-echo message))
  (when align
    (remove-text-properties align (1+ align) '(display nil))))

;;;; Placeholders

(cl-defun md-render--insert-media
    (&key start end source render-source backend block-p label)
  "Replace START to END with a preview placeholder for BACKEND.
SOURCE is the Markdown the placeholder stands for and RENDER-SOURCE
the text handed to the renderer.  BLOCK-P selects a centered block
rather than an inline image, and LABEL names the preview.  Return the
end of the placeholder."
  (let* ((file (md-render--media-cache-file backend render-source))
         (carried (md-render--carry-properties start))
         (math-block (and block-p (eq backend 'math)))
         (text (cond (math-block "\n  \n\n")
                     (block-p "\n \n\n")
                     (t " ")))
         (image-pos (cond (math-block (+ start 2))
                          (block-p (1+ start))
                          (t start))))
    (goto-char start)
    (delete-region start end)
    (insert text)
    (let ((placeholder-end (point)))
      (when carried
        (add-text-properties start placeholder-end carried))
      (add-text-properties
       start placeholder-end
       `(md-render-frozen t
                          md-render-source ,source
                          rear-nonsticky (md-render-frozen
                                          md-render-source
                                          md-render-media-file)))
      (put-text-property image-pos (1+ image-pos) 'md-render-media-file file)
      (when math-block
        (put-text-property (1+ start) (+ start 2)
                           'md-render-block-centered t))
      (md-render--watch-media backend render-source file
                              (copy-marker image-pos) label)
      placeholder-end)))

(defun md-render--render-math (start end block-p available)
  "Render the math from START to END, or freeze it when unavailable.
BLOCK-P selects display math.  AVAILABLE is non-nil when the math
tools are installed."
  (if available
      (let ((source (buffer-substring-no-properties start end)))
        (md-render--insert-media :start start :end end
                                 :source source :render-source source
                                 :backend 'math :block-p block-p
                                 :label "Math"))
    (put-text-property start end 'md-render-frozen t)
    end))

;;;; Math delimiters

(defun md-render--escaped-p (pos)
  "Return non-nil when the character at POS is backslash-escaped."
  (let ((count 0))
    (while (eq (char-before (- pos count)) ?\\)
      (setq count (1+ count)))
    (cl-oddp count)))

(defun md-render--dollar-closer-p (pos)
  "Return non-nil when the `$' at POS can close inline math."
  (and (eq (char-after pos) ?$)
       (not (eq (char-before pos) ?$))
       (not (eq (char-after (1+ pos)) ?$))
       (not (md-render--escaped-p pos))
       (char-before pos)
       (not (memq (char-before pos) '(?\s ?\t ?\n ?\r)))
       (not (memq (char-after (1+ pos)) '(?0 ?1 ?2 ?3 ?4 ?5 ?6 ?7 ?8 ?9)))))

(defun md-render--overlaps-ranges-p (start end ranges)
  "Return non-nil when START to END overlaps any of RANGES."
  (cl-some (lambda (range) (and (< (car range) end) (> (cdr range) start)))
           ranges))

(defun md-render--dollar-closer (open protected)
  "Return the `$' closing the inline math opened at OPEN, or nil.
The span may not overlap PROTECTED ranges."
  (let ((eol (md-render--line-end open))
        (pos (1+ open))
        (found nil))
    (while (and (not found) (< pos eol))
      (when (and (md-render--dollar-closer-p pos)
                 (not (md-render--overlaps-ranges-p open (1+ pos) protected)))
        (setq found pos))
      (setq pos (1+ pos)))
    found))

(defun md-render--digit-p (char)
  "Return non-nil when CHAR is an ASCII digit."
  (and char (<= ?0 char ?9)))

(defun md-render--scan-single-dollar-math (protected)
  "Return (SPANS . PENDING) for `$...$' math outside PROTECTED ranges.
SPANS are (START . END) conses in buffer order; PENDING is the earliest
opener still waiting for its closer, or nil."
  (let ((spans nil)
        (pending nil))
    (goto-char (point-min))
    (while (search-forward "$" nil t)
      (let* ((open (1- (point)))
             (next (char-after (1+ open)))
             (range (md-render-in-avoid-range-p open (1+ open) protected)))
        (cond
         (range (goto-char (max (point) (cdr range))))
         ((md-render--escaped-p open)
          (when-let* ((closer (md-render--dollar-closer open nil)))
            (goto-char (1+ closer))))
         ((or (eq (char-before open) ?$)
              (eq next ?$)
              (null next)
              (memq next '(?\s ?\t ?\n ?\r))))
         (t
          (let* ((closer (md-render--dollar-closer open protected))
                 (content (and closer (buffer-substring-no-properties
                                       (1+ open) closer))))
            (if (and closer
                     (not (and (md-render--digit-p next)
                               (string-match-p "[ \t\n]" content))))
                (progn
                  (push (cons open (1+ closer)) spans)
                  (goto-char (1+ closer)))
              (unless (md-render--digit-p next)
                (setq pending (if pending (min pending open) open)))
              (goto-char (md-render--line-end open))))))))
    (cons (nreverse spans) pending)))

(defun md-render--render-delimited-math (protected available)
  "Render math delimiters outside PROTECTED ranges.
AVAILABLE is non-nil when the math tools are installed.  Return the
earliest opener still waiting for its closer, or nil."
  (pcase-let* ((`(,spans . ,pending)
                (md-render--scan-single-dollar-math protected))
               (pending (and pending (copy-marker pending))))
    (pcase-dolist (`(,start . ,end) (reverse spans))
      (unless (get-text-property start 'md-render-frozen)
        (md-render--render-math start end nil available)))
    (pcase-dolist (`(,opener ,closer ,block-p)
                   '(("\\(" "\\)" nil) ("\\[" "\\]" t) ("$$" "$$" t)))
      (goto-char (point-min))
      (let ((done nil))
        (while (and (not done) (search-forward opener nil t))
          (let* ((start (match-beginning 0))
                 (range (md-render-in-avoid-range-p start (1+ start)
                                                    protected)))
            (cond
             (range (goto-char (max (point) (cdr range))))
             ((search-forward closer nil t)
              (unless (get-text-property start 'md-render-frozen)
                (goto-char (md-render--render-math start (point) block-p
                                                   available))))
             (t
              (when (or (null pending) (< start pending))
                (setq pending (copy-marker start)))
              (setq done t)))))))
    (and pending (marker-position pending))))

;;;; Fenced media

(defun md-render--render-fenced-media (blocks available)
  "Replace complete BLOCKS whose language has an AVAILABLE backend."
  (dolist (block (reverse blocks))
    (when-let* (((alist-get :complete block))
                (backend (md-render--fenced-media-backend
                          (alist-get :language block) available)))
      (let* ((range (alist-get :block block))
             (start (marker-position (alist-get :start range)))
             (end (marker-position (alist-get :end range)))
             (body (alist-get :body block)))
        (md-render--insert-media
         :start start :end end
         :source (buffer-substring-no-properties start end)
         :render-source (if (eq backend 'math)
                            (concat "\\[\n" body "\n\\]")
                          body)
         :backend backend :block-p t
         :label (md-render--backend-property backend :label))))))

(defun md-render--render-media (context)
  "Render math and diagrams described by CONTEXT as image previews.
Do nothing on a text terminal.  Return a `:watermark' entry while a
math delimiter is still waiting for its closer."
  (when (display-graphic-p)
    (let* ((available (md-render--available-backends))
           (blocks (alist-get :source-blocks context))
           (protected (md-render-sort-ranges
                       (md-render--block-ranges blocks)
                       (alist-get :inline-code-ranges context)))
           (pending (save-excursion
                      (md-render--render-delimited-math
                       protected (memq 'math available)))))
      (save-excursion
        (md-render--render-fenced-media blocks available))
      (when pending
        `((:watermark . ,pending))))))

(provide 'md-render-media)
;;; md-render-media.el ends here
