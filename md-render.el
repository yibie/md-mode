;;; md-render.el --- Render Markdown as propertized text -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Alvaro Ramirez

;; Author: Alvaro Ramirez https://xenodium.com
;; Source: https://github.com/xenodium/agent-shell/blob/main/agent-shell-markdown.el
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This package is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This package is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Convert a Markdown string into propertized text:
;;
;;   (md-render-convert "hello **world**")
;;
;; Or rewrite the current buffer in place:
;;
;;   (md-render-replace-markup)
;;
;; Both remove the markup characters and leave behind face text
;; properties.  Supported markup:
;;
;;   bold        `**X**' / `__X__'        face `md-render-bold'
;;   italic      `*X*'   / `_X_'          face `md-render-italic'
;;   strike      `~~X~~'                  face `md-render-strikethrough'
;;   header      `# X' .. `###### X'      face `md-render-header-1' .. `-6'
;;   inline code `` `X` ``                face `md-render-inline-code'
;;   link        `[title](url)'           face `md-render-link', keymap opens URL
;;                 (`(<url>)' also OK — angle brackets allow spaces in the url)
;;   image       `![alt](url)'            `display' property carries image
;;                 (`(<url>)' also OK — angle brackets allow spaces in the url)
;;   image path  bare image path on a line  same as `![alt](url)' (no markup)
;;   divider     `---' / `***' / `___'    rendered as an underlined rule line
;;   fenced code ```LANG\nX\n```          body syntax-highlighted via LANG mode
;;   LaTeX math `\(X\)', `\[X\]', `$$X$$' optional local SVG preview
;;   Mermaid     ```mermaid\nX\n```       optional local image preview
;;   PlantUML    ```plantuml\nX\n```      optional local SVG preview
;;   Graphviz    ```dot\nX\n```           optional local SVG preview
;;   tables      `| A | B |' grid rows    rendered with aligned columns,
;;                                         unicode borders, header/zebra rows
;;                                         and wrap-to-window-width support
;;
;; All md-render-* faces inherit from conventional faces
;; (`bold', `italic', etc.) so default rendering is
;; unchanged, while still letting users customize markdown output
;; without disturbing the source faces elsewhere.
;;
;; Open / streaming fenced blocks (no closing fence yet) are
;; left alone so their contents stay protected as the buffer
;; grows.

;;; Code:

(require 'cl-lib)
(require 'color)
(require 'map)
(require 'seq)
(require 'org-faces)
(require 'url)
(require 'url-parse)
(require 'url-util)

(defgroup md-render nil
  "Render Markdown text into propertized form."
  :group 'text)

(defface md-render-bold
  '((t :inherit bold))
  "Face for bold text rendered by `md-render-convert'."
  :group 'md-render)

(defface md-render-italic
  '((t :inherit italic))
  "Face for italic text rendered by `md-render-convert'."
  :group 'md-render)

(defface md-render-strikethrough
  '((t :strike-through t))
  "Face for strikethrough text rendered by `md-render-convert'."
  :group 'md-render)

(defface md-render-inline-code
  '((t :inherit org-code))
  "Face for inline code rendered by `md-render-convert'."
  :group 'md-render)

(defface md-render-link
  '((t :inherit link))
  "Face for link titles rendered by `md-render-convert'."
  :group 'md-render)

(defface md-render-blockquote
  '((t :inherit font-lock-comment-face))
  "Face for blockquoted text rendered by `md-render-convert'."
  :group 'md-render)

(defface md-render-callout
  '((t :inherit org-block :foreground unspecified :extend t))
  "Background face for GitHub-style callout panels."
  :group 'md-render)

(defface md-render-callout-title
  '((t :inherit bold))
  "Face for GitHub-style callout titles."
  :group 'md-render)

(defconst md-render--callout-specs
  '(("NOTE" "Note" font-lock-constant-face)
    ("TIP" "Tip" success)
    ("IMPORTANT" "Important" font-lock-keyword-face)
    ("WARNING" "Warning" warning)
    ("CAUTION" "Caution" error))
  "Display title and accent face for each supported callout type.")

(defface md-render-header-1
  '((((type tty) (background dark))
     :inherit org-level-1 :foreground "#ffffff")
    (((type tty) (background light))
     :inherit org-level-1 :foreground "#000000")
    (t :inherit bold :height 2.0))
  "Face for level-1 headers rendered by `md-render-convert'."
  :group 'md-render)

(defface md-render-header-2
  '((((type tty) (background dark))
     :inherit org-level-2 :foreground "#d2b580")
    (((type tty) (background light))
     :inherit org-level-2 :foreground "#624416")
    (t :inherit bold :height 1.7))
  "Face for level-2 headers rendered by `md-render-convert'."
  :group 'md-render)

(defface md-render-header-3
  '((((type tty) (background dark))
     :inherit org-level-3 :foreground "#82b0ec")
    (((type tty) (background light))
     :inherit org-level-3 :foreground "#193668")
    (t :inherit bold :height 1.4))
  "Face for level-3 headers rendered by `md-render-convert'."
  :group 'md-render)

(defface md-render-header-4
  '((((type tty) (background dark))
     :inherit org-level-4 :foreground "#feacd0")
    (((type tty) (background light))
     :inherit org-level-4 :foreground "#721045")
    (t :inherit bold :height 1.1))
  "Face for level-4 headers rendered by `md-render-convert'."
  :group 'md-render)

(defface md-render-header-5
  '((((type tty) (background dark))
     :inherit org-level-5 :foreground "#88ca9f")
    (((type tty) (background light))
     :inherit org-level-5 :foreground "#2a5045")
    (t :inherit bold :height 1.0))
  "Face for level-5 headers rendered by `md-render-convert'."
  :group 'md-render)

(defface md-render-header-6
  '((((type tty) (background dark))
     :inherit org-level-6 :foreground "#ff9580")
    (((type tty) (background light))
     :inherit org-level-6 :foreground "#7f0000")
    (t :inherit bold :height 1.0))
  "Face for level-6 headers rendered by `md-render-convert'."
  :group 'md-render)

(defface md-render-table-header
  '((t :inherit bold))
  "Face for table header row content."
  :group 'md-render)

(defface md-render-table-border
  '((t :inherit shadow))
  "Face for table borders (pipes and dashes)."
  :group 'md-render)

(defface md-render-table-zebra
  '((((class color) (background light)) :background "gray95")
    (((class color) (background dark)) :background "gray20")
    (t :inherit highlight))
  "Face for alternating (zebra) data rows in tables."
  :group 'md-render)

(defface md-render-source-block
  '((t :inherit org-block :foreground unspecified :extend t))
  "Background face applied to rendered fenced source-block bodies.
Inherits background from `org-block'.  `:foreground unspecified'
preserves font-lock colors.  `:extend t' fills the line to the
window edge."
  :group 'md-render)

(defface md-render-source-block-language
  '((t :inherit (italic font-lock-type-face md-render-source-block)))
  "Face for the language label shown above a fenced source block."
  :group 'md-render)

(defcustom md-render-image-max-width 0.4
  "Maximum width for inline images rendered from `![alt](url)'.
An integer is taken as pixels.  A float between 0 and 1 is a
ratio of the window body width."
  :type '(choice integer float)
  :group 'md-render)

(defcustom md-render-prettify-tables t
  "When non-nil, render Markdown tables with aligned columns."
  :type 'boolean
  :group 'md-render)

(defcustom md-render-table-use-unicode-borders t
  "When non-nil, use Unicode box-drawing chars (│ ─ ┼ ├ ┤) for borders.
When nil, fall back to ASCII pipes and dashes."
  :type 'boolean
  :group 'md-render)

(defcustom md-render-table-wrap-columns nil
  "When non-nil, wrap table columns to fit within window width.

When nil (the default), tables render at their natural width —
wide tables overflow the window edge and can be reached with
horizontal scrolling."
  :type 'boolean
  :group 'md-render)

(defcustom md-render-table-max-width-fraction 0.9
  "Fraction of window width to use as max table width when wrapping."
  :type 'float
  :group 'md-render)

(defcustom md-render-table-zebra-stripe t
  "When non-nil, alternate row backgrounds in tables for readability."
  :type 'boolean
  :group 'md-render)

(defcustom md-render-math-enabled t
  "When non-nil, render LaTeX math as SVG when local tools are available.

Rendering requires the `emacs', `latex', and `dvisvgm'
executables.  Complete math remains literal when those tools are
unavailable."
  :type 'boolean
  :group 'md-render)

(defcustom md-render-mermaid-enabled t
  "When non-nil, render complete Mermaid fenced blocks as PNG images.

Rendering requires `md-render-mermaid-command'.  When it is
unavailable, Mermaid fences retain the normal source-block
rendering."
  :type 'boolean
  :group 'md-render)

(defcustom md-render-mermaid-command "mmdc"
  "Executable used to render Mermaid fenced blocks."
  :type 'string
  :group 'md-render)

(defcustom md-render-mermaid-browser nil
  "Browser executable used by Mermaid CLI.

Nil means detect Chrome or Chromium automatically.  Set this when
`mmdc' cannot find the browser installation to use."
  :type '(choice (const :tag "Auto-detect" nil)
                 (file :must-match t))
  :group 'md-render)

(defcustom md-render-plantuml-enabled t
  "When non-nil, render complete PlantUML fenced blocks as SVG.

Rendering requires `md-render-plantuml-command'.  When it is
unavailable, `plantuml' and `puml' fences retain the normal
source-block rendering."
  :type 'boolean
  :group 'md-render)

(defcustom md-render-plantuml-command "plantuml"
  "Executable used to render PlantUML fenced blocks."
  :type 'string
  :group 'md-render)

(defcustom md-render-graphviz-enabled t
  "When non-nil, render complete Graphviz fenced blocks as SVG.

Rendering requires `md-render-graphviz-command'.  When it is
unavailable, `dot' and `graphviz' fences retain the normal
source-block rendering."
  :type 'boolean
  :group 'md-render)

(defcustom md-render-graphviz-command "dot"
  "Executable used to render Graphviz fenced blocks."
  :type 'string
  :group 'md-render)

(defcustom md-render-cache-directory
  (locate-user-emacs-file "md-render/")
  "Directory where generated preview images are cached."
  :type 'directory
  :group 'md-render)

(defcustom md-render-math-scale 1.0
  "Scale applied to generated LaTeX math previews."
  :type 'float
  :group 'md-render)

(defcustom md-render-language-mapping
  '(("elisp" . "emacs-lisp")
    ("objective-c" . "objc")
    ("objectivec" . "objc")
    ("cpp" . "c++"))
  "Map of fenced-block language aliases to Emacs major mode prefixes.
Keys are lower-case language names as written after the opening
backticks; values are the corresponding Emacs mode prefix (the
`-mode' suffix is appended internally).  Example:

  (\"elisp\" . \"emacs-lisp\")  ; ```elisp -> emacs-lisp-mode"
  :type '(alist :key-type string :value-type string)
  :group 'md-render)

(defcustom md-render-render-functions '(md-render--render-media)
  "Abnormal hook of external renderers, run before the styling passes.

Lets a third-party package (e.g. a LaTeX-math renderer) claim and
render regions of the buffer that the built-in passes should not
touch.  Each function receives a single alist CONTEXT and runs with
the buffer narrowed to the streaming region.  A renderer renders
its regions in place and tags the rendered chars with text
property `md-render-frozen' so the built-in passes
\(bold, italic, links, tables, ...) leave them alone, the same
mechanism fenced code blocks use.  Renderers run before the
emphasis passes, so raw delimiters are claimed before those passes
could mangle them; a renderer should skip already-frozen content
so streaming re-runs don't reprocess it.

To support `md-render-reconstruct', a renderer should also put the
`md-render-source' text property on its
rendered region, holding the original markdown (e.g. the `$$...$$'
LaTeX) as a string.  Copying reconstructs each fully-selected span
from that property, so the region yields its source rather than its
visible text — the same mechanism fenced blocks and tables use.  A
text property (not an overlay) is required so it survives being
copied into another buffer (e.g. the viewport).

CONTEXT keys:

  :source-blocks  List of fenced-block descriptors (see
                  `md-render--source-blocks'), so a
                  renderer can claim blocks of its own language
                  (e.g. math, latex) and skip delimiters that fall
                  inside other code.  Each descriptor is an alist
                  with :language, :block (a :start/:end marker
                  range), :body, and :complete.

  :inline-code-ranges  List of (start . end) marker ranges covering
                  inline `code' span bodies, so a renderer can skip
                  delimiters that fall inside a verbatim span (e.g. a
                  literal `\\(x\\)' the agent meant as code, not math).

Each function returns an alist (nil for no-op).  Recognised keys:

  :watermark  Buffer position the streaming frontier must not pass,
              so an unclosed delimiter at the buffer tail (e.g. an
              open `$$') is re-examined on the next chunk.  The
              earliest :watermark across all renderers is honoured.

For example, a renderer holding the frontier behind an open `$$'
at position 1200 returns:

  ((:watermark . 1200))"
  :type 'hook
  :group 'md-render)

(defvar md-render--media-jobs (make-hash-table :test #'equal)
  "Active media render jobs keyed by their output file.")

(defconst md-render--media-cache-version 3
  "Version of the generated media cache format.")

(cl-defun md-render-convert (markdown)
  "Convert MARKDOWN string into propertized text.

Bold, italic, strikethrough, headers, and inline code are
rendered as text properties on the inner text; the markup
characters are removed.  See `md-render-replace-markup' for
the in-buffer equivalent.

For example:

  (md-render-convert \"_my_ **text**\")
  => #(\"my text\" 0 2 (face italic) 3 7 (face bold))"
  (with-temp-buffer
    (insert markdown)
    (md-render-replace-markup)
    (buffer-string)))

(cl-defun md-render-replace-markup (&key force
                                                    (render-images t)
                                                    (highlight-blocks t)
                                                    image-cache-directory)
  "Replace Markdown markup in current buffer with propertized text.

Rewrites the buffer in place: markup characters are removed and
the remaining text carries face properties.  Faces compose, so a
span nested inside another type ends up with all applicable
faces.

Markup inside fenced code blocks and inline code spans is left
alone.  Streaming-friendly: an unclosed fence protects the rest
of the buffer, an unclosed inline backtick protects the rest of
its line, and incomplete bold/italic/strike spans are skipped
until their closing delimiter arrives.

Before the built-in passes, each function in
`md-render-render-functions' runs so an external package
can claim and render regions (e.g. LaTeX math) that the built-in
passes should leave alone.

Italic, bold, and strike passes loop until a full round makes no
changes, so adjacent delimiters peel one layer per round
such as when `**_X_**' resolves in two rounds.  Headers, inline code,
links, images, bare image-path lines, dividers, source-block
styling, and table styling run once after the loop.

The buffer is narrowed to the streaming watermark for the
duration of the passes — content before the watermark is already
rendered and stable, so every regex / property scan starts there
instead of `point-min'.  The watermark is read off the
`md-render-watermark' text property on the first
character and re-stamped at the end of the call.  Pass FORCE
non-nil to drop the watermark and re-render the whole buffer
after mid-buffer edits or in tests.

RENDER-IMAGES, when non-nil (the default), replaces `![alt](url)'
markup with displayed images where the URL resolves to an image
file; nil leaves the markup as-is.  IMAGE-CACHE-DIRECTORY is where
remote (http) image URLs are downloaded and cached; when nil
\(the default), remote images are not fetched and their markup is
left as text.  HIGHLIGHT-BLOCKS, when non-nil by default, runs the
fenced-block body through the language's
major-mode font-lock to colour keywords / strings / etc.; nil
strips the fences and inserts the action label but leaves the
body un-fontified."
  (save-excursion
    (when force
      (with-silent-modifications
        (remove-text-properties (point-min) (point-max)
                                '(md-render-watermark nil))))
    (let ((watermark (md-render--watermark-start))
          (external-results)
          (context)
          (source-blocks)
          (source-ranges)
          (rendered-ranges)
          (inline-ranges)
          (avoid-ranges))
      (save-restriction
        (narrow-to-region watermark (point-max))
        ;; Build the render context (fenced-block descriptors + inline
        ;; `code' ranges) once, via the same function any external code
        ;; renders a static region through, so the two cannot drift.
        (setq context (md-render-context))
        (setq source-blocks (map-elt context :source-blocks))
        ;; Inline `code' spans, computed before the renderers run so an
        ;; external renderer can skip verbatim spans the same way it skips
        ;; fenced blocks.  The markers survive any buffer edits a renderer
        ;; makes and are reused as an avoid-range for the built-in passes
        ;; below.
        (setq inline-ranges (map-elt context :inline-code-ranges))
        ;; Re-project the fenced-block descriptors to the plain (start . end)
        ;; ranges the avoid-range machinery expects.  `md-render-context'
        ;; is the single source of truth; this is a cheap derivation from
        ;; its result.
        (setq source-ranges (md-render--source-block-ranges source-blocks))
        ;; Run external renderers (when any are registered) before the
        ;; styling passes.  They tag their regions
        ;; `md-render-frozen', so the frozen ranges captured
        ;; below (and `avoid-ranges') pick them up and the styling passes
        ;; skip them.
        (when md-render-render-functions
          (setq external-results (md-render--run-render-functions
                                  context)))
        (setq rendered-ranges (md-render--make-markers
                               (md-render--frozen-ranges)))
        (setq avoid-ranges (md-render-sort-ranges
                            source-ranges rendered-ranges inline-ranges))
        (while (let ((italic-changed (md-render--replace-italics
                                      :avoid-ranges avoid-ranges))
                     (bold-changed (md-render--replace-bolds
                                    :avoid-ranges avoid-ranges))
                     (strike-changed (md-render--replace-strikethroughs
                                      :avoid-ranges avoid-ranges)))
                 (or italic-changed bold-changed strike-changed)))
        (md-render--replace-headers :avoid-ranges avoid-ranges)
        (md-render--style-inline-code :avoid-ranges source-ranges)
        (md-render--replace-links :avoid-ranges avoid-ranges)
        (when render-images
          (md-render--replace-images
           :avoid-ranges avoid-ranges
           :image-cache-directory image-cache-directory)
          (md-render--replace-image-file-paths
           :avoid-ranges avoid-ranges))
        (md-render--style-dividers :avoid-ranges avoid-ranges)
        (md-render--style-callouts :avoid-ranges avoid-ranges)
        (md-render--style-blockquotes :avoid-ranges avoid-ranges)
        (md-render--style-source-blocks
         :highlight-blocks highlight-blocks)
        ;; Tables run last so cell content has already been processed by
        ;; every other pass (bold, italic, links, inline code, etc.).
        ;; The cell parser respects face and `md-render-frozen'
        ;; so it doesn't mis-split on pipes that got swallowed by other
        ;; markup.  AVOID-RANGES protects content inside still-open
        ;; fenced blocks (where the closing fence hasn't streamed in
        ;; yet) — without it a table inside a code block would render
        ;; eagerly and the fences would then strip out, leaving a
        ;; rendered table.  Watermark backs off past any rendered
        ;; table whose extension is still possible (see
        ;; `--update-watermark'), so `--find-tables' under the narrow
        ;; always sees the existing `md-render-table-source'
        ;; needed to fold new rows in.
        (md-render--style-tables :avoid-ranges source-ranges)
        ;; Mirror every `face' we composed onto `font-lock-face' so our
        ;; styling survives `font-lock-mode' re-fontification — comint
        ;; / shell-maker / agent-shell buffers fontify on every output
        ;; chunk and would otherwise clear our `face' properties.
        (md-render--mirror-face-to-font-lock-face
         (point-min) (point-max))
        ;; Tag rendered chars so a yank into another buffer drops the
        ;; styling, display overrides, internal markers, and keymaps
        ;; we layered on — paste should give plain chars, not our
        ;; implementation cruft.
        (put-text-property (point-min) (point-max)
                           'yank-handler
                           (list (lambda (s)
                                   (insert (substring-no-properties s)))))
        ;; Mark rendered chars `fontified' so jit-lock never re-runs over
        ;; them during a mouse drag.  We style via `face'/`font-lock-face'
        ;; text properties, not font-lock keywords (`font-lock-defaults'
        ;; is `(nil t)'), so an in-drag jit-lock pass applies nothing —
        ;; but firing at all disturbs drag tracking and collapses the
        ;; selection to empty, silently breaking mouse copy of rendered
        ;; text (keyboard selection is unaffected).
        (put-text-property (point-min) (point-max) 'fontified t))
      (md-render--update-watermark
       :source-blocks source-blocks
       :external-candidates (seq-keep (lambda (result) (map-elt result :watermark))
                                      external-results)))))

(defun md-render--source-block-ranges (source-blocks)
  "Project SOURCE-BLOCKS to sorted (START . END) marker ranges.

Each descriptor in SOURCE-BLOCKS (see
`md-render--source-blocks') carries a `:block' marker
range; this returns just those ranges as plain (START . END) conses,
sorted — the form the avoid-range machinery
\(`md-render-in-avoid-range-p',
`md-render-sort-ranges') expects."
  (md-render-sort-ranges
   (mapcar (lambda (source-block)
             (cons (map-nested-elt source-block '(:block :start))
                   (map-nested-elt source-block '(:block :end))))
           source-blocks)))

(defun md-render-context ()
  "Return the render context for the current narrowed region.

Builds the same CONTEXT alist that
`md-render-replace-markup' hands to the functions in
`md-render-render-functions', but for whatever region
the buffer is narrowed to right now:

  ((:source-blocks . SOURCE-BLOCKS)
   (:inline-code-ranges . INLINE-CODE-RANGES))

SOURCE-BLOCKS are the fenced-block descriptors from
`md-render--source-blocks'.  INLINE-CODE-RANGES are
marker ranges covering inline `code' span bodies, computed with the
fenced blocks as avoid-ranges so backticks inside a fenced block are
not mistaken for an inline span.  See
`md-render-render-functions' for the meaning of each key.

`md-render-replace-markup' builds its context through
this function too, so code that renders a static (non-streamed)
region — which never passes through the streaming render hook — can
obtain the identical context and stay in sync with the streaming
path."
  (let* ((source-blocks (md-render--source-blocks))
         (source-ranges (md-render--source-block-ranges source-blocks))
         (inline-ranges (md-render--make-markers
                         (md-render--inline-code-ranges
                          :avoid-ranges source-ranges))))
    (list (cons :source-blocks source-blocks)
          (cons :inline-code-ranges inline-ranges))))

(defun md-render--run-render-functions (context)
  "Run `md-render-render-functions' with CONTEXT.

CONTEXT is the alist from `md-render-context', holding
\(:source-blocks . SOURCE-BLOCKS) and (:inline-code-ranges .
INLINE-CODE-RANGES).  Each registered function is called with it
and may render and freeze regions of the current (narrowed) buffer.
Returns the list of non-nil result alists, in hook order.

For example, with one renderer returning `((:watermark . 1200))'
this returns `(((:watermark . 1200)))'."
  (let ((results '()))
    (run-hook-wrapped 'md-render-render-functions
                      (lambda (fn)
                        (when-let* ((result (funcall fn context)))
                          (push result results))
                        nil))
    (nreverse results)))

(defun md-render--dark-background-p ()
  "Return non-nil when the current default face has a dark background."
  (if-let* ((background (face-background 'default nil t))
            ((stringp background))
            (rgb (ignore-errors (color-name-to-rgb background))))
      (color-dark-p rgb)
    (eq (frame-parameter nil 'background-mode) 'dark)))

(defun md-render--theme-foreground ()
  "Return the current default foreground as a renderer-safe color."
  (let ((foreground (face-foreground 'default nil t)))
    (if (and (stringp foreground)
             (ignore-errors (color-name-to-rgb foreground)))
        foreground
      (if (md-render--dark-background-p) "#ffffff" "#000000"))))

(defun md-render--media-cache-file (backend source)
  "Return the cached image path for BACKEND rendering SOURCE."
  (let* ((appearance
          (pcase backend
            ('math
             (list md-render-math-scale
                   (md-render--theme-foreground)
                   (face-background 'default nil t)))
            ((or 'mermaid 'plantuml 'graphviz)
             (list (md-render--theme-foreground)
                   (face-background 'default nil t)
                   (md-render--dark-background-p)))))
         (digest
          (secure-hash 'sha256
                       (prin1-to-string
                        (list md-render--media-cache-version
                              backend appearance source)))))
    (expand-file-name
     (concat digest
             (pcase backend
               ('mermaid ".png")
               ((or 'math 'plantuml 'graphviz) ".svg")))
     md-render-cache-directory)))

(defun md-render--media-image (file backend)
  "Create a displayed image from FILE rendered by BACKEND."
  (create-image file nil nil
                :max-width
                (if (memq backend '(mermaid plantuml graphviz))
                    (if-let* ((window
                               (get-buffer-window
                                (current-buffer) t)))
                        (floor (* 0.9 (window-body-width window t)))
                      (md-render--image-max-width))
                  (md-render--image-max-width))
                :ascent 'center))

(defun md-render--media-apply (watcher file error-message)
  "Apply FILE or ERROR-MESSAGE to a live media WATCHER."
  (pcase-let ((`(,buffer ,marker ,label ,backend) watcher))
    (when (and (buffer-live-p buffer)
               (marker-buffer marker))
      (with-current-buffer buffer
        (let ((position (marker-position marker)))
          (when (equal (get-text-property position 'md-render-media-file)
                       file)
            (let ((inhibit-read-only t))
              (with-silent-modifications
                (condition-case err
                    (put-text-property
                     position (1+ position) 'display
                     (if error-message
                         (propertize
                          (format "⚠ %s" label)
                          'face 'error
                          'help-echo error-message)
                       (md-render--media-image file backend)))
                  (error
                   (put-text-property
                    position (1+ position) 'display
                    (propertize
                     (format "⚠ %s" label)
                     'face 'error
                     'help-echo (error-message-string err)))))))
            (force-window-update buffer)))))))

(defun md-render--finish-media-job (file error-message)
  "Finish the media job for FILE, showing ERROR-MESSAGE on failure."
  (let ((watchers (gethash file md-render--media-jobs)))
    (remhash file md-render--media-jobs)
    (dolist (watcher watchers)
      (md-render--media-apply watcher file error-message))))

(defun md-render--media-process-error (process)
  "Return a concise error message from failed PROCESS."
  (let ((buffer (process-buffer process)))
    (if (buffer-live-p buffer)
        (with-current-buffer buffer
          (string-trim
           (buffer-substring-no-properties
            (max (point-min) (- (point-max) 1000))
            (point-max))))
      (format "Renderer exited with status %s"
              (process-exit-status process)))))

(defun md-render--plantuml-themed-source (source)
  "Add theme-aware defaults to PlantUML SOURCE."
  (if (string-match "^@startuml[^\n]*\n" source)
      (concat
       (substring source 0 (match-end 0))
       "skinparam BackgroundColor transparent\n"
       "skinparam Monochrome "
       (if (md-render--dark-background-p) "reverse\n" "true\n")
       (substring source (match-end 0)))
    source))

(defun md-render--start-media-process (backend source file)
  "Start an asynchronous BACKEND job rendering SOURCE to FILE."
  (make-directory md-render-cache-directory t)
  (let* ((input
          (expand-file-name
           (concat (file-name-base file)
                   (pcase backend
                     ('math ".formula")
                     ('mermaid ".mmd")
                     ('plantuml ".puml")
                     ('graphviz ".dot")))
           md-render-cache-directory))
         (log-buffer
          (generate-new-buffer
           (format " *md-render-%s*" backend)))
         (command
          (pcase backend
            ('math
             (let ((emacs (executable-find "emacs"))
                   (foreground (md-render--theme-foreground)))
               (list
                emacs "-Q" "--batch" "--eval"
                (prin1-to-string
                 `(progn
                    (require 'org)
                    (let ((options
                           (copy-sequence org-format-latex-options)))
                      (setq options
                            (plist-put options :foreground ,foreground))
                      (setq options
                            (plist-put options :background "Transparent"))
                      (setq options
                            (plist-put options :scale
                                       ,md-render-math-scale))
                      (org-create-formula-image
                       (with-temp-buffer
                         (insert-file-contents ,input)
                         (buffer-string))
                       ,file options t 'dvisvgm)))))))
            ('mermaid
             (list (executable-find md-render-mermaid-command)
                   "--input" input
                   "--output" file
                   "--theme"
                   (if (md-render--dark-background-p)
                       "dark"
                     "default")
                   "--backgroundColor" "transparent"
                   "--scale" "1"))
            ('plantuml
             (list (executable-find md-render-plantuml-command)
                   "-tsvg" input))
            ('graphviz
             (let ((foreground (md-render--theme-foreground)))
               (list (executable-find md-render-graphviz-command)
                     "-Tsvg"
                     "-Gbgcolor=transparent"
                     (format "-Gfontcolor=%s" foreground)
                     (format "-Ncolor=%s" foreground)
                     (format "-Nfontcolor=%s" foreground)
                     (format "-Ecolor=%s" foreground)
                     (format "-Efontcolor=%s" foreground)
                     input "-o" file))))))
    (write-region
     (if (eq backend 'plantuml)
         (md-render--plantuml-themed-source source)
       source)
     nil input nil 'silent)
    (condition-case err
        (let ((process-environment
               (pcase backend
                 ('mermaid
                  (if-let* ((browser (md-render--mermaid-browser)))
                      (cons
                       (concat "PUPPETEER_EXECUTABLE_PATH=" browser)
                       process-environment)
                    process-environment))
                 ('plantuml
                  (cons "PLANTUML_SECURITY_PROFILE=SANDBOX"
                        process-environment))
                 ('graphviz
                  (cons "SERVER_NAME=md-render"
                        process-environment))
                 (_ process-environment))))
          (make-process
           :name (format "md-render-%s-%s"
                         backend (substring (file-name-base file) 0 8))
           :buffer log-buffer
           :command command
           :connection-type 'pipe
           :noquery t
           :sentinel
           (lambda (process _event)
             (when (memq (process-status process) '(exit signal))
               (let ((error-message
                      (unless (and (zerop (process-exit-status process))
                                   (file-exists-p file))
                        (md-render--media-process-error process))))
                 (when (file-exists-p input)
                   (delete-file input))
                 (when (buffer-live-p log-buffer)
                   (kill-buffer log-buffer))
                 (md-render--finish-media-job file error-message))))))
      (error
       (when (file-exists-p input)
         (delete-file input))
       (when (buffer-live-p log-buffer)
         (kill-buffer log-buffer))
       (md-render--finish-media-job file (error-message-string err))))))

(defun md-render--watch-media (backend source file marker label)
  "Display BACKEND output for SOURCE at MARKER using FILE and LABEL."
  (let ((watcher (list (current-buffer) marker label backend)))
    (if (file-exists-p file)
        (md-render--media-apply watcher file nil)
      (let ((watchers (gethash file md-render--media-jobs)))
        (puthash file (cons watcher watchers) md-render--media-jobs)
        (unless watchers
          (md-render--start-media-process backend source file))))))

(cl-defun md-render--insert-media (&key start end source render-source
                                        backend block-p label)
  "Replace START..END with a BACKEND placeholder for SOURCE.

RENDER-SOURCE is passed to the renderer.  BLOCK-P controls whether
the placeholder occupies its own paragraph.  LABEL identifies
rendering errors."
  (let* ((file (md-render--media-cache-file backend render-source))
         (carried (md-render--carry-properties start))
         (placeholder (if block-p "\n \n\n" " "))
         image-position)
    (delete-region start end)
    (goto-char start)
    (insert placeholder)
    (setq image-position (if block-p (1+ start) start))
    (add-text-properties
     start (point)
     (append
      carried
      (list 'md-render-frozen t
            'md-render-source source
            'rear-nonsticky '(md-render-frozen
                              md-render-source
                              md-render-media-file))))
    (put-text-property image-position (1+ image-position)
                       'md-render-media-file file)
    (md-render--watch-media
     backend render-source file (copy-marker image-position) label)))

(defun md-render--math-tools-available-p ()
  "Return non-nil when the local SVG math toolchain is available."
  (and (executable-find "emacs")
       (executable-find "latex")
       (executable-find "dvisvgm")))

(defun md-render--mermaid-tool-available-p ()
  "Return non-nil when the configured Mermaid command is available."
  (executable-find md-render-mermaid-command))

(defun md-render--plantuml-tool-available-p ()
  "Return non-nil when the configured PlantUML command is available."
  (executable-find md-render-plantuml-command))

(defun md-render--graphviz-tool-available-p ()
  "Return non-nil when the configured Graphviz command is available."
  (executable-find md-render-graphviz-command))

(defun md-render--mermaid-browser ()
  "Return the browser executable Mermaid CLI should use, or nil."
  (or md-render-mermaid-browser
      (seq-find
       #'file-executable-p
       '("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
         "/Applications/Chromium.app/Contents/MacOS/Chromium"
         "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"))
      (executable-find "google-chrome")
      (executable-find "chromium")
      (executable-find "chromium-browser")))

(defun md-render--fenced-media-backend (language available-backends)
  "Return the backend for LANGUAGE when present in AVAILABLE-BACKENDS."
  (cond
   ((and (memq 'math available-backends)
         (member language '("math" "latex")))
    'math)
   ((and (memq 'mermaid available-backends)
         (equal language "mermaid"))
    'mermaid)
   ((and (memq 'plantuml available-backends)
         (member language '("plantuml" "puml")))
    'plantuml)
   ((and (memq 'graphviz available-backends)
         (member language '("dot" "graphviz")))
    'graphviz)))

(defun md-render--render-fenced-media (context available-backends)
  "Render complete fenced media from CONTEXT using AVAILABLE-BACKENDS."
  (dolist (block (reverse (map-elt context :source-blocks)))
    (let* ((language (map-elt block :language))
           (backend
            (and (map-elt block :complete)
                 (md-render--fenced-media-backend
                  language available-backends))))
      (when backend
        (let* ((start (map-nested-elt block '(:block :start)))
               (end (map-nested-elt block '(:block :end)))
               (body (map-elt block :body))
               (source (buffer-substring-no-properties start end))
               (math-p (eq backend 'math)))
          (md-render--insert-media
           :start start
           :end end
           :source source
           :render-source (if math-p
                              (format "\\[\n%s\n\\]" body)
                            body)
           :backend backend
           :block-p t
           :label
           (pcase backend
             ('math "Math")
             ('mermaid "Mermaid")
             ('plantuml "PlantUML")
             ('graphviz "Graphviz"))))))))

(defun md-render--render-inline-math (context available)
  "Render inline and block math from CONTEXT when AVAILABLE.

Return the earliest incomplete math delimiter, or nil."
  (let ((avoid-ranges
         (md-render-sort-ranges
          (md-render--source-block-ranges
           (map-elt context :source-blocks))
          (map-elt context :inline-code-ranges)))
        watermark)
    (dolist (spec '(("\\(" "\\)") ("\\[" "\\]") ("$$" "$$")))
      (save-excursion
        (goto-char (point-min))
        (while (search-forward (car spec) nil t)
          (let* ((start (- (point) (length (car spec))))
                 (avoid
                  (md-render-in-avoid-range-p
                   start (1+ start) avoid-ranges)))
            (cond
             (avoid
              (goto-char (cdr avoid)))
             ((search-forward (cadr spec) nil t)
              (let ((end (point)))
                (unless (get-text-property start 'md-render-frozen)
                  (if available
                      (let ((source
                             (buffer-substring-no-properties start end)))
                        (md-render--insert-media
                         :start start
                         :end end
                         :source source
                         :render-source source
                         :backend 'math
                         :block-p (not (equal (car spec) "\\("))
                         :label "Math"))
                    (put-text-property start end
                                       'md-render-frozen t)))))
             (t
              (setq watermark
                    (if watermark (min watermark start) start))
              (goto-char (point-max))))))))
    watermark))

(defun md-render--render-media (context)
  "Render supported Math and Mermaid regions described by CONTEXT."
  (when (display-graphic-p)
    (let ((math-available
           (and md-render-math-enabled
                (md-render--math-tools-available-p)))
          available-backends
          watermark)
      (setq available-backends
            (delq
             nil
             (list
              (and math-available 'math)
              (and md-render-mermaid-enabled
                   (md-render--mermaid-tool-available-p)
                   'mermaid)
              (and md-render-plantuml-enabled
                   (md-render--plantuml-tool-available-p)
                   'plantuml)
              (and md-render-graphviz-enabled
                   (md-render--graphviz-tool-available-p)
                   'graphviz))))
      (when md-render-math-enabled
        (setq watermark
              (md-render--render-inline-math context math-available)))
      (md-render--render-fenced-media context available-backends)
      (and watermark (list (cons :watermark watermark))))))

(cl-defun md-render--replace-bolds (&key avoid-ranges)
  "Replace `**X**' / `__X__' spans in current buffer with bold X.

Markup characters are deleted; remaining inner text carries face
`md-render-bold' layered on top of any existing face
properties.  Spans that fall inside any of AVOID-RANGES are left
untouched.  Returns non-nil if at least one replacement was made.

For example, the buffer \"hello **world**.\" becomes \"hello
world.\" with face `md-render-bold' on \"world\"."
  (let ((case-fold-search nil)
        (changed nil))
    (goto-char (point-min))
    (while (re-search-forward
            (rx (or line-start (syntax whitespace))
                (group
                 (or (seq "**" (group (one-or-more (not (any "\n*")))) "**")
                     (seq "__" (group (one-or-more (not (any "\n_")))) "__")))
                (or (syntax punctuation) (syntax whitespace) line-end))
            nil t)
      (let* ((markup-start (match-beginning 1))
             (markup-end (match-end 1))
             (avoid (md-render-in-avoid-range-p
                     markup-start markup-end avoid-ranges)))
        (if avoid
            (goto-char (cdr avoid))
          (let ((text (buffer-substring
                       (or (match-beginning 2) (match-beginning 3))
                       (or (match-end 2) (match-end 3))))
                (source (unless (get-text-property markup-start
                                                   'md-render-source)
                          (md-render-reconstruct
                           markup-start markup-end))))
            (delete-region markup-start markup-end)
            (goto-char markup-start)
            (insert text)
            (let ((end (+ markup-start (length text))))
              (add-face-text-property markup-start end 'md-render-bold)
              (when source
                (put-text-property markup-start end
                                   'md-render-source source)))
            (setq changed t)))))
    changed))

(cl-defun md-render--replace-italics (&key avoid-ranges)
  "Replace `*X*' / `_X_' spans in current buffer with italic X.

Markup characters are deleted; remaining inner text carries face
`md-render-italic' layered on top of any existing face
properties.  Spans that fall inside any of AVOID-RANGES are left
untouched.  Returns non-nil if at least one replacement was made.

A `_X_' span must be followed by punctuation, whitespace, or a line
end, so intraword underscores such as \"_hello_world\" are left as
literal text rather than emphasized.

For example, the buffer \"hello *world*.\" becomes \"hello
world.\" with face `md-render-italic' on \"world\"."
  (let ((case-fold-search nil)
        (changed nil))
    (goto-char (point-min))
    (while (re-search-forward
            (rx (or (seq (or bol (one-or-more (any "\n \t")))
                         (group "*" (group (one-or-more (not (any "\n*")))) "*"))
                    (seq (or bol (one-or-more (any "\n \t")))
                         (group "_" (group (one-or-more (not (any "\n_")))) "_")
                         (or (syntax punctuation) (syntax whitespace) line-end))))
            nil t)
      (let* ((markup-start (or (match-beginning 1) (match-beginning 3)))
             (markup-end (or (match-end 1) (match-end 3)))
             (avoid (md-render-in-avoid-range-p
                     markup-start markup-end avoid-ranges)))
        (if avoid
            (goto-char (cdr avoid))
          (let ((text (buffer-substring
                       (or (match-beginning 2) (match-beginning 4))
                       (or (match-end 2) (match-end 4))))
                (source (unless (get-text-property markup-start
                                                   'md-render-source)
                          (md-render-reconstruct
                           markup-start markup-end))))
            (delete-region markup-start markup-end)
            (goto-char markup-start)
            (insert text)
            (let ((end (+ markup-start (length text))))
              (add-face-text-property markup-start end 'md-render-italic)
              (when source
                (put-text-property markup-start end
                                   'md-render-source source)))
            (setq changed t)))))
    changed))

(cl-defun md-render--replace-strikethroughs (&key avoid-ranges)
  "Replace `~~X~~' spans in current buffer with strike-through-faced X.

Markup characters are deleted; remaining inner text carries face
`md-render-strikethrough' layered on top of any existing face
properties.  Spans inside any of AVOID-RANGES are left untouched.
Returns non-nil if at least one replacement was made.

For example, the buffer \"a ~~b~~ c\" becomes \"a b c\" with face
`md-render-strikethrough' on \"b\"."
  (let ((case-fold-search nil)
        (changed nil))
    (goto-char (point-min))
    (while (re-search-forward
            (rx "~~" (group (one-or-more (not (any "\n~")))) "~~")
            nil t)
      (let* ((markup-start (match-beginning 0))
             (markup-end (match-end 0))
             (avoid (md-render-in-avoid-range-p
                     markup-start markup-end avoid-ranges)))
        (if avoid
            (goto-char (cdr avoid))
          (let ((text (buffer-substring (match-beginning 1) (match-end 1)))
                (source (unless (get-text-property markup-start
                                                   'md-render-source)
                          (md-render-reconstruct
                           markup-start markup-end))))
            (delete-region markup-start markup-end)
            (goto-char markup-start)
            (insert text)
            (let ((end (+ markup-start (length text))))
              (add-face-text-property markup-start end
                                      'md-render-strikethrough)
              (when source
                (put-text-property markup-start end
                                   'md-render-source source)))
            (setq changed t)))))
    changed))

(cl-defun md-render--replace-headers (&key avoid-ranges)
  "Replace `# X' / `## X' / ... headers with X faced as `org-level-N'.

The `#' prefix and one or more separator spaces are stripped; the
title text is left with face `md-render-header-N' where N is
the number of `#' characters clamped to 1..6.  Headers inside any
of AVOID-RANGES are left untouched.

Requires an explicit trailing newline — a header at end-of-buffer
without `\\n' is treated as still streaming and left raw, so a
chunk that lands `# He' followed later by `llo World\\n' renders
the full `Hello World' on the second call rather than eagerly
facing `He' and leaving `llo World' plain.

For example, the buffer \"## My title\\n\" becomes \"My title\\n\"
with face `md-render-header-2' on \"My title\"."
  (let ((case-fold-search nil))
    (goto-char (point-min))
    (while (re-search-forward
            (rx bol (zero-or-more blank) (group (one-or-more "#"))
                (one-or-more blank)
                (group (one-or-more (not (any "\n")))) "\n")
            nil t)
      (let* ((markup-start (match-beginning 0))
             (markup-end (match-end 0))
             (avoid (md-render-in-avoid-range-p
                     markup-start markup-end avoid-ranges)))
        (if avoid
            (goto-char (cdr avoid))
          (let* ((level (- (match-end 1) (match-beginning 1)))
                 (text (buffer-substring (match-beginning 2) (match-end 2)))
                 (source (unless (get-text-property markup-start
                                                    'md-render-source)
                           (md-render-reconstruct
                            markup-start (match-end 2))))
                 ;; `text' keeps the title's own properties.  Carry the newline
                 ;; separately so its trailing-whitespace invisibility does not
                 ;; hide the title.
                 (newline-properties
                  (md-render--carry-properties (1- markup-end))))
            (delete-region markup-start markup-end)
            (goto-char markup-start)
            (insert text)
            (let ((end (point)))
              (insert "\n")
              (when newline-properties
                (add-text-properties end (point) newline-properties))
              (add-face-text-property
               markup-start end
               (intern (format "md-render-header-%d"
                               (min (max level 1) 6))))
              (when source
                (put-text-property markup-start end
                                   'md-render-source source)))))))))

(cl-defun md-render--style-inline-code (&key avoid-ranges)
  "Strip backticks from complete inline `X` spans and face the body.

The body of each well-formed `` `X` `` is left in place with
face `md-render-inline-code' and tagged with the text
property `md-render-frozen t' so it is never re-processed
on subsequent calls (the body can legitimately contain
markdown-looking chars like `**' once the surrounding backticks
are gone).  Spans inside any of AVOID-RANGES (typically fenced
code blocks) are left untouched.

For example, the buffer \"a `code` b\" becomes \"a code b\" with
face `md-render-inline-code' on \"code\"."
  (let ((case-fold-search nil))
    (goto-char (point-min))
    (while (re-search-forward "`\\([^`\n]+\\)`" nil t)
      (let* ((markup-start (match-beginning 0))
             (markup-end (match-end 0))
             (avoid (md-render-in-avoid-range-p
                     markup-start markup-end avoid-ranges)))
        (if avoid
            (goto-char (cdr avoid))
          (let ((text (buffer-substring (match-beginning 1) (match-end 1)))
                (source (unless (get-text-property markup-start
                                                   'md-render-source)
                          (md-render-reconstruct
                           markup-start markup-end))))
            (delete-region markup-start markup-end)
            (goto-char markup-start)
            (insert text)
            (let ((end (+ markup-start (length text))))
              (add-face-text-property markup-start end 'md-render-inline-code)
              (add-text-properties markup-start end
                                   '(md-render-frozen t
                                                                 rear-nonsticky (md-render-frozen)))
              (when source
                (put-text-property markup-start end
                                   'md-render-source source)))))))))

(cl-defun md-render--link-markup-regexp (&key as-image?)
  "Return a regexp matching link (or image, when AS-IMAGE?) markup.

The destination accepts both the bare `(url)' form and the
CommonMark angle-bracketed `(<url>)' form, the latter allowing the
URL to contain spaces (e.g. `(</path/with spaces.png>)').

Capture groups: group 1 is the label (link title or image alt);
group 2 is the angle-bracketed destination body; group 3 is the
bare destination body.  Exactly one of groups 2 and 3 participates
in any match — read the URL from whichever did."
  (rx-to-string
   `(seq ,@(when as-image? '("!"))
         "["
         (group (,(if as-image? 'zero-or-more 'one-or-more) (not (any "]"))))
         "]"
         "("
         (or (seq "<" (group (zero-or-more (not (any "<" ">" "\n")))) ">")
             (group (one-or-more (not (any ")")))))
         ")")
   t))

(defun md-render--link-markup-url ()
  "Return the URL from the last `md-render--link-markup-regexp' match.
Reads capture group 2 (angle-bracketed form) when it participated,
otherwise group 3 (bare form)."
  (let ((group (if (match-beginning 2) 2 3)))
    (buffer-substring-no-properties (match-beginning group) (match-end group))))

(cl-defun md-render--replace-links (&key avoid-ranges)
  "Replace `[title](url)' markup with title faced as link.

The bracket/parenthesis markup is stripped; the title is left
with face `md-render-link' and a keymap text property that
opens the URL on RET or a mouse click.  Matches preceded by `!' (the
image syntax) are skipped, as are links inside any of
AVOID-RANGES.

A bare `(url)' destination and the CommonMark angle-bracketed
`(<url>)' form are both accepted; the latter allows spaces in the
URL (see `md-render--link-markup-regexp').

For example, the buffer \"see [docs](https://example.com)\"
becomes \"see docs\" with face `md-render-link' on \"docs\"
and a keymap that opens the URL."
  (let ((case-fold-search nil)
        (regexp (md-render--link-markup-regexp)))
    (goto-char (point-min))
    (while (re-search-forward regexp nil t)
      (let* ((markup-start (match-beginning 0))
             (markup-end (match-end 0))
             (is-image (eq (char-before markup-start) ?!))
             (avoid (unless is-image
                      (md-render-in-avoid-range-p
                       markup-start markup-end avoid-ranges))))
        (cond
         (avoid (goto-char (cdr avoid)))
         (is-image nil)
         (t
          (let ((title (buffer-substring (match-beginning 1) (match-end 1)))
                (url (md-render--link-markup-url))
                (source (unless (get-text-property markup-start
                                                   'md-render-source)
                          (md-render-reconstruct
                           markup-start markup-end))))
            (delete-region markup-start markup-end)
            (goto-char markup-start)
            (insert title)
            (let ((end (+ markup-start (length title))))
              (add-face-text-property markup-start end 'md-render-link)
              (put-text-property markup-start end 'keymap
                                 (md-render--make-ret-binding-map
                                  (lambda () (interactive)
                                    (md-render--open-link url))))
              (put-text-property markup-start end 'mouse-face 'highlight)
              ;; Expose the target as recoverable metadata so copy/export
              ;; integrations can reconstruct the link once the `(url)' is
              ;; gone from the buffer (see
              ;; `md-render-link-url-at-point').
              (put-text-property markup-start end 'md-render-url url)
              (when source
                (put-text-property markup-start end
                                   'md-render-source source))))))))))

(cl-defun md-render--replace-images (&key avoid-ranges image-cache-directory)
  "Replace `![alt](url)' image markup with displayed images.

If URL resolves to an existing local file that is image-supported
and a graphical display is available, the full markup is replaced
by the alt text (or a single space if alt is empty) carrying a
`display' property with the image and a keymap that opens the
file on RET or a mouse click.  Remote (http) URLs are downloaded into
IMAGE-CACHE-DIRECTORY first (see
`md-render--fetch-remote-image').

When a remote image can't be shown inline (no IMAGE-CACHE-DIRECTORY,
the download failed, or a non-graphical display), its markup is
replaced by a link -- the alt text, or the URL when alt is empty --
faced as `md-render-link' with a keymap that opens the
URL on RET or a mouse click.  Any other unresolvable markup is left
untouched.  Images inside any of AVOID-RANGES are left alone.

A bare `(url)' destination and the CommonMark angle-bracketed
`(<url>)' form are both accepted; the latter allows spaces in the
URL (see `md-render--link-markup-regexp').

For example, the buffer \"see ![logo](logo.png)\" becomes
\"see logo\" with the image shown in place of \"logo\"."
  (let ((case-fold-search nil)
        (regexp (md-render--link-markup-regexp :as-image? t)))
    (goto-char (point-min))
    (while (re-search-forward regexp nil t)
      (let* ((markup-start (match-beginning 0))
             (markup-end (match-end 0))
             (avoid (md-render-in-avoid-range-p
                     markup-start markup-end avoid-ranges)))
        (cond
         (avoid (goto-char (cdr avoid)))
         (t
          (let* ((alt (buffer-substring-no-properties
                       (match-beginning 1) (match-end 1)))
                 ;; The placeholder that replaces the markup must carry the
                 ;; surrounding text's properties -- the shell tags the whole
                 ;; body run with caller section properties, read-only, and an
                 ;; invisibility state, and the fragment layer locates the body
                 ;; by that contiguous run.  Reinserting a bare string (as
                 ;; `buffer-substring-no-properties' would give) punches a hole
                 ;; in the run, so the next streaming chunk mis-locates the body
                 ;; and hides the text after the image.  Mirror
                 ;; `--replace-links': keep the alt's properties for a non-empty
                 ;; alt, and inherit the markup's own properties for the empty
                 ;; case (space placeholder).
                 (placeholder (if (string-empty-p alt)
                                  (apply #'propertize " "
                                         (text-properties-at markup-start))
                                (buffer-substring (match-beginning 1)
                                                  (match-end 1))))
                 (url (md-render--link-markup-url))
                 ;; Stash the original `![alt](url)' markup so
                 ;; `md-render-reconstruct' round-trips the image back to
                 ;; source rather than yielding the bare alt placeholder (mirrors
                 ;; `--replace-links').  Guarded so a re-render doesn't overwrite
                 ;; an already-captured source.
                 (source (unless (get-text-property markup-start
                                                    'md-render-source)
                           (md-render-reconstruct markup-start markup-end)))
                 (path (md-render--resolve-image-url
                        url image-cache-directory)))
            (cond
             ((and path
                   (image-supported-file-p path)
                   (display-graphic-p))
              (let ((image (create-image
                            path nil nil
                            :max-width (md-render--image-max-width))))
                (image-flush image)
                (delete-region markup-start markup-end)
                (goto-char markup-start)
                (insert placeholder)
                (let ((end (+ markup-start (length placeholder))))
                  (put-text-property markup-start end 'display image)
                  (put-text-property markup-start end 'keymap
                                     (md-render--make-ret-binding-map
                                      (lambda () (interactive)
                                        (find-file path))))
                  (put-text-property markup-start end 'mouse-face 'highlight)
                  (when source
                    (put-text-property markup-start end
                                       'md-render-source source)))))
             ;; Remote image we couldn't show inline (no cache configured, the
             ;; download failed, or a non-graphical display): render a link
             ;; that opens the url, rather than leaving raw `![alt](url)' text.
             ((string-match-p "\\`https?://" url)
              (let ((label (if (string-empty-p alt)
                               (apply #'propertize url
                                      (text-properties-at markup-start))
                             placeholder)))
                (delete-region markup-start markup-end)
                (goto-char markup-start)
                (insert label)
                (let ((end (+ markup-start (length label))))
                  (add-face-text-property markup-start end 'md-render-link)
                  (put-text-property markup-start end 'keymap
                                     (md-render--make-ret-binding-map
                                      (lambda () (interactive)
                                        (md-render--open-link url))))
                  (put-text-property markup-start end 'mouse-face 'highlight)
                  (when source
                    (put-text-property markup-start end
                                       'md-render-source source)))))))))))))

(cl-defun md-render--replace-image-file-paths (&key avoid-ranges)
  "Render bare image-path lines as displayed images.

A line that is solely a local path or `file://' URI ending in a
supported image extension is treated like an `![alt](url)' image:
when the path resolves to an existing image-supported file and a
graphical display is available, the line text is left in place
carrying a `display' property with the image and a keymap that
opens the file.  Lines inside any of AVOID-RANGES are left
untouched, as are unresolvable paths.

For example, a buffer line containing just `/abs/path/img.png'
renders the image in place of that text."
  (let* ((case-fold-search t)
         (ext-re (regexp-opt image-file-name-extensions))
         (regex (concat "^[ \t]*\\(\\(?:file://\\|[/~.]\\)[^ \t\n]*\\."
                        ext-re
                        "\\)[ \t]*$")))
    (goto-char (point-min))
    (while (re-search-forward regex nil t)
      (let* ((line-start (match-beginning 0))
             (line-end (match-end 0))
             (avoid (md-render-in-avoid-range-p
                     line-start line-end avoid-ranges)))
        (cond
         (avoid (goto-char (cdr avoid)))
         (t
          (let* ((path-start (match-beginning 1))
                 (path-end (match-end 1))
                 (raw (buffer-substring-no-properties path-start path-end))
                 (resolved (md-render--resolve-image-url raw)))
            (when (and resolved
                       (image-supported-file-p resolved)
                       (display-graphic-p))
              (let ((image (create-image
                            resolved nil nil
                            :max-width (md-render--image-max-width))))
                (image-flush image)
                (put-text-property path-start path-end 'display image)
                (put-text-property path-start path-end 'keymap
                                   (md-render--make-ret-binding-map
                                    (lambda () (interactive)
                                      (find-file resolved))))
                (put-text-property path-start path-end 'mouse-face 'highlight)
                (add-text-properties path-start path-end
                                     '(md-render-frozen t
                                                                   rear-nonsticky (md-render-frozen))))))))))))

(cl-defun md-render--style-dividers (&key avoid-ranges)
  "Render `---' / `***' / `___' horizontal-rule lines as styled rules.

Each line consisting of 3+ matching dash/star/underscore chars,
with optional surrounding spaces or tabs, gets a `display' text
property that draws an underlined rule across the window, plus a
`md-render-frozen' tag so subsequent calls don't re-process
it.  Dividers inside any of AVOID-RANGES are left untouched.

The chars themselves remain in the buffer beneath the display
property, so the source markdown round-trips through copy/save."
  (let ((case-fold-search nil))
    (goto-char (point-min))
    (while (re-search-forward
            (rx bol (zero-or-more blank)
                (or (seq "***" (zero-or-more "*"))
                    (seq "---" (zero-or-more "-"))
                    (seq "___" (zero-or-more "_")))
                (zero-or-more blank) eol)
            nil t)
      (let* ((rule-start (match-beginning 0))
             (rule-end (match-end 0))
             (avoid (md-render-in-avoid-range-p
                     rule-start rule-end avoid-ranges)))
        (if avoid
            (goto-char (cdr avoid))
          (add-text-properties
           rule-start rule-end
           (list 'display
                 (concat (propertize (make-string 12 ?\s)
                                     'face '(:underline t))
                         "\n")
                 'md-render-frozen t
                 'rear-nonsticky '(display md-render-frozen))))))))

(cl-defun md-render--style-callouts (&key avoid-ranges)
  "Render complete GitHub-style callouts as accented panels.

The underlying Markdown remains unchanged.  AVOID-RANGES are left
untouched."
  (let ((case-fold-search nil))
    (goto-char (point-min))
    (while (re-search-forward
            (rx bol (zero-or-more blank)
                (group ">")
                (group (one-or-more blank)
                       "[!" (group (or "NOTE" "TIP" "IMPORTANT"
                                      "WARNING" "CAUTION")) "]")
                (zero-or-more blank) "\n")
            nil t)
      (let* ((callout-start (match-beginning 0))
             (callout-end (match-end 0))
             (marker-start (match-beginning 2))
             (marker-end (match-end 2))
             (type-name (match-string-no-properties 3))
             (spec (assoc type-name md-render--callout-specs))
             (type (intern type-name))
             (title (nth 1 spec))
             (accent (nth 2 spec))
             (avoid (md-render-in-avoid-range-p
                     callout-start callout-end avoid-ranges)))
        (if avoid
            (goto-char (cdr avoid))
          (save-excursion
            (goto-char callout-end)
            (while (looking-at
                    (rx bol (zero-or-more blank) ">"
                        (zero-or-more (not (any "\n"))) "\n"))
              (goto-char (match-end 0)))
            (setq callout-end (point)))
          (add-face-text-property callout-start callout-end
                                  'md-render-callout t)
          (add-text-properties
           callout-start callout-end
           (list 'md-render-callout type
                 'md-render-frozen t
                 'rear-nonsticky
                 '(md-render-callout md-render-frozen)))
          (put-text-property
           marker-start marker-end 'display
           (propertize (concat " " title)
                       'face (list 'md-render-callout-title accent
                                   'md-render-callout)))
          (save-excursion
            (goto-char callout-start)
            (while (< (point) callout-end)
              (let ((line-end (line-end-position)))
                (skip-chars-forward " \t" line-end)
                (when (eq (char-after) ?>)
                  (put-text-property
                   (point) (1+ (point)) 'display
                   (propertize "▎"
                               'face (list accent
                                           'md-render-callout)))))
              (forward-line 1)))
          (goto-char callout-end))))))

(cl-defun md-render--style-blockquotes (&key avoid-ranges)
  "Render `>'-prefixed lines as blockquotes with vertical bars.

Each leading `>' character on the line is shown as `▌' via a
`display' text property; the underlying `>' chars stay in the
buffer so the source markdown round-trips through copy/save and
re-rendering remains idempotent.  Remaining content on the line
gets face `md-render-blockquote' (composes with any
face already applied by an earlier pass — bold/italic/inline-code
inside a blockquote still render).

Multiple nesting levels are supported: each leading `>' renders
as its own bar, so `>> text' shows two bars and `>>> text' three.
Whitespace between `>'s is preserved literally.

Requires an explicit trailing newline — a blockquote line at
end-of-buffer without `\\n' is treated as still streaming and
left raw, matching the header behaviour.

Lines inside any of AVOID-RANGES (e.g. fenced code blocks) are
left untouched."
  (let ((case-fold-search nil)
        (bar (propertize "▌" 'face 'md-render-blockquote)))
    (goto-char (point-min))
    (while (re-search-forward
            (rx bol (zero-or-more blank)
                ">" (zero-or-more (any " \t>"))
                (zero-or-more (not (any "\n"))) "\n")
            nil t)
      (let* ((line-start (match-beginning 0))
             (line-end (match-end 0))
             (avoid (md-render-in-avoid-range-p
                     line-start line-end avoid-ranges)))
        (cond
         (avoid
          (goto-char (cdr avoid)))
         ((get-text-property line-start 'md-render-callout))
         (t
          (save-excursion
            (goto-char line-start)
            (skip-chars-forward " \t" line-end)
            (while (eq (char-after) ?>)
              (put-text-property (point) (1+ (point)) 'display bar)
              (forward-char 1)
              (skip-chars-forward " \t" line-end)))
          (add-face-text-property line-start (1- line-end)
                                  'md-render-blockquote)
          (add-text-properties
           line-start line-end
           '(md-render-frozen t
                              rear-nonsticky (md-render-frozen)))))))))

(defun md-render--display-width ()
  "Return a usable display width for divider rendering.
Tries the selected window's body width and falls back to 80
characters when no usable window is available (e.g. batch)."
  (or (ignore-errors (window-body-width))
      80))

(cl-defun md-render--style-source-blocks (&key (highlight-blocks t))
  "Strip fenced code block markup and syntax-highlight the body.

For each complete `\\`\\`\\`LANG' / `\\`\\`\\`' fenced block,
the opening and closing fence lines are deleted from the buffer.
The body text stays in place with face properties from LANG's
major mode (when loadable) and a `md-render-frozen t' text
property tagging it as rendered output.  That tag is read back
as an avoid-range on subsequent calls, so the body is never
re-processed as inline markup even though its surrounding
fences are gone.

Open / streaming fences (no closing line yet) are left alone.

When HIGHLIGHT-BLOCKS is nil, fences are still stripped and the
action label inserted, but the body is left un-fontified (no
language-mode keyword colours).  Useful when the caller wants the
panel layout without paying the syntax-highlighting cost.

For example, the buffer:

  ```elisp
  (message \"hi\")
  ```

becomes:

  (message \"hi\")

with `emacs-lisp-mode' face properties on the body and a
`md-render-frozen' tag covering those same chars."
  (let ((case-fold-search nil))
    (goto-char (point-min))
    ;; Group 2 captures the opening backtick run; `backref' on the
    ;; closer matches the same literal run, so a 4-backtick outer
    ;; fence requires a 4-backtick close — a 3-backtick line inside
    ;; is just body.  Note this is slightly tighter than CommonMark
    ;; (which permits close > open), but every-LLM-I've-seen emits
    ;; matched counts, so the simplification is worth it.
    (while (re-search-forward
            (rx (group bol (zero-or-more blank)
                       (group (>= 3 "`"))
                       (zero-or-more blank)
                       (group (zero-or-more (or alphanumeric "-" "+" "#")))
                       (zero-or-more blank) "\n")
                (group (*? anychar))
                "\n"
                (group bol (zero-or-more blank)
                       (backref 2)
                       (zero-or-more blank) (or "\n" eol)))
            nil t)
      ;; Honor `md-render-frozen'.
      (unless (get-text-property (match-beginning 4)
                                 'md-render-frozen)
        (let* ((open-start (match-beginning 1))
               (open-end (match-end 1))
               (lang (buffer-substring-no-properties (match-beginning 3)
                                                     (match-end 3)))
               (body-start (copy-marker (match-beginning 4)))
               (body-end (copy-marker (match-end 4)))
               (close-start (match-beginning 5))
               (close-end (match-end 5))
               (source (buffer-substring-no-properties open-start close-end))
               (highlighted (when highlight-blocks
                              (md-render--highlight-code
                               (buffer-substring-no-properties body-start body-end)
                               lang))))
          ;; Delete in reverse position order so earlier offsets stay
          ;; valid; body markers adjust automatically.
          (delete-region close-start close-end)
          (delete-region open-start open-end)
          ;; Seed the bg panel on body chars first, then layer language
          ;; font-lock faces on top — the foreground colors take priority
          ;; per glyph while the `:extend t' background fills the gaps
          ;; and reaches the right edge of the window.  Include the
          ;; trailing `\\n' (the one that sat between body and close
          ;; fence, preserved by the deletes above): `:extend t' only
          ;; extends the background when the face is in effect at
          ;; end-of-line, so without the `\\n' carrying the face the
          ;; last body line's bg would stop at the last content char.
          (let ((body-bg-end (min (1+ (marker-position body-end))
                                  (point-max)))
                ;; `line-prefix' / `wrap-prefix' visually inset each
                ;; rendered line: 2 plain cols then 2 bg-tinted cols.
                ;; Copying chars out of the block yanks raw source with
                ;; no leading indentation.  `wrap-prefix' handles long
                ;; lines that wrap.  Splitting the prefix this way keeps
                ;; the panel from running hard to the window's left edge
                ;; while still drawing a clear tinted gutter.
                (prefix (concat "  "
                                (propertize
                                 "  " 'face
                                 'md-render-source-block))))
            (put-text-property (marker-position body-start) body-bg-end
                               'face 'md-render-source-block)
            (md-render--apply-faces-from highlighted
                                                    (marker-position body-start))
            (add-text-properties (marker-position body-start) body-bg-end
                                 `(md-render-frozen t
                                                               md-render-non-trimmable t
                                                               rear-nonsticky (md-render-frozen
                                                                               md-render-non-trimmable)
                                                               line-prefix ,prefix
                                                               wrap-prefix ,prefix))
            ;; Insert an actionable "LANG ⧉" / "snippet ⧉" label and the
            ;; surrounding panel padding as REAL BUFFER TEXT — no
            ;; `display' properties (which previously caused the body's
            ;; first char to be hidden / clipped, see #597 "Make code
            ;; block label actual buffer text"), no overlays.  Layout
            ;; relative to the original body: `<vpad>\\n<label>\\n\\n
            ;; <body>\\n<vpad>\\n', where each padding `\\n' carries the
            ;; panel bg face so its line renders as a tinted blank line.
            ;; RET or mouse-1 on the label kills the body to the kill
            ;; ring.  `content-start' uses insertion-type t so it stays
            ;; AFTER the inserted prefix, giving the kill-action a
            ;; stable pointer to body content even though `body-start'
            ;; itself collapses to the leading vpad's first char.
            ;; After insertion we carry the body's caller-set properties
            ;; (`invisible', caller block/section markers,
            ;; `read-only', etc.) onto the inserted chars — propertize'd
            ;; inserts ignore stickiness, and without this the inserted
            ;; prefix punches a hole in the caller's contiguous block
            ;; range and breaks toggle/replace operations.
            (let* ((label-text (concat (if (string-empty-p lang) "snippet" lang)
                                       " ⧉"))
                   (content-start (copy-marker (marker-position body-start) t))
                   (kill-action (lambda ()
                                  (interactive)
                                  ;; Locate the body by text property in
                                  ;; the current buffer so copy works in
                                  ;; any buffer that received a propertized
                                  ;; copy of the rendered block (e.g. the
                                  ;; viewport).
                                  (when-let* ((start (next-single-property-change
                                                      (point)
                                                      'md-render-source-block-body))
                                              ((get-text-property
                                                start
                                                'md-render-source-block-body))
                                              (end (next-single-property-change
                                                    start
                                                    'md-render-source-block-body)))
                                    (kill-new (buffer-substring-no-properties start end))
                                    (message "Copied"))))
                   (vpad-line (propertize "\n"
                                          'face 'md-render-source-block
                                          'line-prefix prefix
                                          'wrap-prefix prefix
                                          'md-render-non-trimmable t
                                          'rear-nonsticky
                                          '(md-render-non-trimmable)))
                   (label (propertize
                           label-text
                           'face 'md-render-source-block-language
                           'mouse-face 'highlight
                           'pointer 'hand
                           'keymap (md-render--make-ret-binding-map
                                    kill-action)
                           'cursor-sensor-functions
                           (list (lambda (_window _old-pos sensor-action)
                                   (when (eq sensor-action 'entered)
                                     (message "Press RET to copy"))))
                           'md-render-frozen t
                           'rear-nonsticky '(md-render-frozen)
                           'line-prefix prefix
                           'wrap-prefix prefix))
                   ;; Top vpad `\\n' + label + middle vpad `\\n' + a
                   ;; second `\\n' that becomes the first column of the
                   ;; line carrying body content.
                   (header (concat vpad-line label vpad-line vpad-line))
                   (carried (md-render--carry-properties body-start)))
              (goto-char body-start)
              (insert header)
              (when carried
                (add-text-properties (marker-position body-start)
                                     (marker-position content-start)
                                     carried))
              ;; Tag body content so the label's copy action can locate
              ;; it by text property, survives a propertized copy into
              ;; another buffer (e.g. viewport).
              (put-text-property (marker-position content-start)
                                 (marker-position body-end)
                                 'md-render-source-block-body t)
              ;; Bottom vpad: insert a single tinted `\\n' AFTER the
              ;; body's trailing newline so the panel ends on a blank
              ;; tinted line below the last body line.  body-end
              ;; (insertion-type nil) stays put across this insert; the
              ;; vpad lives at [body-end, body-end+1) within the buffer.
              (let ((panel-bottom (marker-position body-end)))
                (save-excursion
                  (when (and (< (marker-position body-end) (point-max))
                             (eq (char-after (marker-position body-end)) ?\n))
                    (goto-char (1+ (marker-position body-end)))
                    (let ((vpad-start (point)))
                      (insert vpad-line)
                      (when carried
                        (add-text-properties vpad-start (point) carried))
                      (setq panel-bottom (point)))))
                ;; The inserted panel chrome (language label, copy icon,
                ;; padding) is not markdown, so give it an empty source: a
                ;; selection that contains it reconstructs to nothing
                ;; rather than leaking e.g. "python ⧉".  The body content
                ;; carries the fenced source.
                (put-text-property (marker-position body-start) panel-bottom
                                   'md-render-source "")
                (put-text-property (marker-position content-start)
                                   (marker-position body-end)
                                   'md-render-source source))
              ;; Move point past the body so the outer `re-search-forward'
              ;; loop doesn't backtrack into body content (e.g. shorter
              ;; inner fences inside a wider outer fence).
              (goto-char (marker-position body-end)))))))))

(defconst md-render--table-line-regexp
  (rx line-start
      (zero-or-more (any " \t"))
      "|"
      (one-or-more (not (any "\n")))
      "|"
      (zero-or-more (any " \t"))
      line-end)
  "Regexp matching a single line of a markdown table.")

(defconst md-render--table-pending-line-regexp
  (rx line-start (zero-or-more (any " \t")) "|")
  "Match a line that might still be streaming into a table row.
This accepts anything starting with `|' after optional leading
whitespace.  It lets `--extending-table-start' back the watermark
up past a partial separator like `|---|---|----' that has not
grown its closing `|' yet.")

(defconst md-render--table-separator-regexp
  (rx line-start
      (zero-or-more (any " \t"))
      "|"
      (one-or-more (or "-" ":" "|" " " "\t"))
      "|"
      (zero-or-more (any " \t"))
      line-end)
  "Regexp matching a table separator row (e.g. `|---|---|').")

(cl-defun md-render--find-tables (&key avoid-ranges)
  "Return tables to (re-)render in current buffer.

Each element is an alist with keys :start, :end (the region to
replace), and :source (the markdown table source — a propertized
string — that should be rendered into that region).

Two flavours of region are collected:

  - Pure ASCII tables: 2 or more consecutive `|...|' lines, not
    in a frozen region.  A `|---|...' separator row is optional
    — when present it splits header from data; when absent all
    rows are rendered as data.

  - Rendered table + extension: a previously-rendered table
    carries its original source on each char via the
    `md-render-table-source' property.  Chars immediately
    after the rendered region are folded back in: characters up
    to the next `\\n' are continuation of the rendered table's
    last source row (i.e. a chunk boundary that split a row mid-
    cell), and any complete `|...|' lines that follow extend the
    table with new rows.  The combined source is stashed and the
    region is re-rendered.

A rendered table with no extension is skipped — re-rendering
unchanged source is a no-op.  Tables inside AVOID-RANGES are
skipped."
  ;; agent-shell tags its body chars with `field output' while the
  ;; `\\n's between rows may not carry the same field value; without
  ;; this binding, `forward-line' / `line-end-position' would stop at
  ;; those field boundaries and silently truncate table rows.
  (let ((inhibit-field-text-motion t)
        (tables '())
        (pos (point-min)))
    (save-excursion
      (while (< pos (point-max))
        (goto-char pos)
        (cond
         ;; Skip past any avoid-range containing POS in one hop —
         ;; otherwise multi-line ranges (open fences, big rendered
         ;; spans) make us walk every line just to fall through.
         ;; Query with `[pos, pos+1)' so a range whose half-open
         ;; exclusive END equals POS doesn't match (would otherwise
         ;; setq POS back to itself → infinite loop).
         ((let ((avoid (md-render-in-avoid-range-p
                        pos (1+ pos) avoid-ranges)))
            (when avoid (setq pos (cdr avoid)) t)))
         ((get-text-property pos 'md-render-table-source)
          (let* ((stashed (get-text-property pos 'md-render-table-source))
                 (rendered-end (or (next-single-property-change
                                    pos 'md-render-table-source
                                    nil (point-max))
                                   (point-max)))
                 (trailing-end rendered-end))
            ;; Scan forward from rendered-end accumulating chars that
            ;; extend the rendered table: first any continuation chars
            ;; on the same physical line (a chunk boundary that split
            ;; a row mid-cell), then complete table rows after the
            ;; next `\n'.  Both kinds end up in one substring that
            ;; `concat'-ing onto STASHED yields valid markdown,
            ;; because the trailing substring's own `\n's handle the
            ;; row boundaries.
            (save-excursion
              (goto-char rendered-end)
              (when (and (< (point) (point-max))
                         (not (eq (char-after) ?\n)))
                (end-of-line)
                (setq trailing-end (point)))
              (when (and (< (point) (point-max))
                         (eq (char-after) ?\n))
                (forward-char 1)
                (while (and (not (eobp))
                            (looking-at md-render--table-line-regexp)
                            (not (get-text-property (point)
                                                    'md-render-frozen))
                            (not (md-render-in-avoid-range-p
                                  (point) (line-end-position) avoid-ranges)))
                  (setq trailing-end (line-end-position))
                  (forward-line 1))))
            (if (> trailing-end rendered-end)
                (let ((combined (concat stashed
                                        (buffer-substring rendered-end
                                                          trailing-end))))
                  (push `((:start . ,pos)
                          (:end . ,trailing-end)
                          (:source . ,combined))
                        tables)
                  (setq pos trailing-end))
              ;; Nothing to fold — re-rendering unchanged source would
              ;; be a no-op, so skip past the rendered region.
              (setq pos rendered-end))))
         ((and (looking-at md-render--table-line-regexp)
               (not (get-text-property pos 'md-render-frozen)))
          (let ((table-start pos)
                (table-end nil)
                (row-count 0))
            ;; Greedily consume rows that match the table regex.  Mid-
            ;; stream chunk boundaries that split a row are handled by
            ;; the streaming-extension branch above, which folds
            ;; continuation chars back into the rendered table's last
            ;; row on the next render.  AVOID-RANGES (e.g. an open
            ;; fenced block whose closing fence hasn't streamed in
            ;; yet) keeps the contained rows raw.
            (while (and (not (eobp))
                        (looking-at md-render--table-line-regexp)
                        (not (get-text-property (point)
                                                'md-render-frozen))
                        (not (md-render-in-avoid-range-p
                              (point) (line-end-position) avoid-ranges)))
              (setq table-end (line-end-position))
              (setq row-count (1+ row-count))
              (forward-line 1))
            ;; >=2 pipe rows is enough to render; a separator
            ;; (`|---|...') is not required.  When present it splits
            ;; header from data (and styles the header).  When absent
            ;; all rows are data.
            (when (>= row-count 2)
              (push `((:start . ,table-start)
                      (:end . ,table-end)
                      (:source . ,(buffer-substring table-start table-end)))
                    tables))
            ;; If we matched table rows, `table-end' is past them.
            ;; Otherwise advance to the next line — the table regex
            ;; needs `bol' to match, so scanning the rest of this line
            ;; char-by-char can never produce a hit.
            (setq pos (or table-end
                          (progn (forward-line 1) (point))))))
         (t
          ;; No table-source here and no table starts at this position.
          ;; The table regex requires `bol', so jump straight to the
          ;; next line start rather than crawling each char.
          (forward-line 1)
          (setq pos (point))))))
    (nreverse tables)))

(defun md-render--parse-table-row (start end)
  "Parse table row from START to END into cells.

Returns a list of alists with :start, :end, :content for each
cell, where :content carries any text properties applied by the
earlier passes (bold, italic, inline-code, link, etc.).

A `|' is treated as a cell separator unless it (a) is preceded by
a `\\' escape, or (b) carries `md-render-frozen' — in which
case it lives inside a region one of our passes has already
rendered (e.g. inline-code body containing a literal `|') and
isn't a real delimiter.  We deliberately don't check `face' so
that pipes faced by external font-lock (markdown-mode, etc.)
are still parsed as cell separators."
  (let ((cells '()))
    (save-excursion
      (goto-char start)
      (when (looking-at (rx (zero-or-more (any " \t")) "|"))
        (goto-char (match-end 0)))
      (let ((cell-start (point)))
        (while (< (point) end)
          (if (re-search-forward (rx (any "|\\")) end t)
              (let ((ch (char-before))
                    (pipe-pos (1- (point))))
                (cond
                 ((and (eq ch ?|)
                       (not (get-text-property pipe-pos
                                               'md-render-frozen)))
                  (let ((cell-end pipe-pos))
                    (push `((:start . ,cell-start)
                            (:end . ,cell-end)
                            (:content . ,(string-trim
                                          (buffer-substring
                                           cell-start cell-end))))
                          cells)
                    (setq cell-start (point))))
                 ((eq ch ?\\)
                  (when (< (point) end) (forward-char 1)))))
            (goto-char end)))))
    (nreverse cells)))

(defvar-local md-render--table-char-pixel-cache nil
  "Cons cell (FONT-WIDTH . SPACE-PIXELS).
Caches the rendered pixel width of a single space in the buffer;
invalidated when the font width changes (e.g. text scaling).
Stored in the destination buffer (the one displayed in the
window passed to the measurement helpers), so cache lookups are
per-destination.")

(defconst md-render--table-measure-x-limit 100000
  "Maximum X in pixels for `window-text-pixel-size' measurements.

Without an X limit the measurement is clipped at the window
width, which would under-measure wide table cells and skew
natural column widths.")

(defun md-render--table-measure-string (str window)
  "Return real pixel width of STR rendered at point-max of WINDOW's buffer.

STR is pinned to `fixed-pitch' before measuring so widths stay
font-independent — `variable-pitch-mode' remaps the buffer's
default face, which would otherwise skew the padding math.

Briefly inserts STR, measures with `window-text-pixel-size', and
deletes; `inhibit-modification-hooks' and the modified flag are
preserved so callers never observe the mutation."
  (add-face-text-property 0 (length str) 'fixed-pitch nil str)
  (with-current-buffer (window-buffer window)
    (let ((inhibit-read-only t)
          (inhibit-modification-hooks t)
          (modified (buffer-modified-p))
          real)
      (save-excursion
        (goto-char (point-max))
        (let ((m (point-marker)))
          (set-marker-insertion-type m nil)
          (insert str)
          ;; Mark the probe `fontified' so the display iterator doesn't
          ;; run font-lock over it — fontifying would strip the pinned
          ;; `fixed-pitch' face and measure in the buffer's remapped
          ;; default face (variable-pitch).
          (put-text-property m (point) 'fontified t)
          ;; Strip `line-prefix' / `wrap-prefix' before measuring
          (remove-text-properties m (point) '(line-prefix nil wrap-prefix nil))
          ;; X-LIMIT keeps `window-text-pixel-size' from clipping the
          ;; measurement at the window width — long cells (wide tables)
          ;; would otherwise under-measure their natural column widths.
          (setq real (car (window-text-pixel-size
                           window m (point)
                           md-render--table-measure-x-limit)))
          (delete-region m (point))
          (set-marker m nil)))
      (set-buffer-modified-p modified)
      real)))

(defun md-render--table-char-pixel-width (window)
  "Return real pixel width of a single space in WINDOW, cached.
Cache lives in the destination buffer and is invalidated when
its font width changes."
  (with-current-buffer (window-buffer window)
    (let ((fw (window-font-width window)))
      (if (and md-render--table-char-pixel-cache
               (= fw (car md-render--table-char-pixel-cache)))
          (cdr md-render--table-char-pixel-cache)
        (let ((sw (md-render--table-measure-string " " window)))
          (setq md-render--table-char-pixel-cache (cons fw sw))
          sw)))))

(defvar md-render--table-default-line-height nil
  "Cached default line height in pixels.
Computed once per session by `md-render--table-char-height-scale'.")

(defconst md-render--table-min-height-scale 0.75
  "Minimum height scale factor.
Characters needing more aggressive scaling than this are left
unscaled — shrinking text below 75% makes it unreadable.  This
allows emoji (~0.77) and CJK (~0.90) through while skipping
scripts with tall ascenders/descenders like Arabic (~0.63).")

(defvar md-render--table-height-scale-cache (make-hash-table :test 'eq)
  "Cache of height scale factors keyed by character.")

(defun md-render--table-measure-line-height (win str)
  "Return the rendered pixel height of STR as a single line in WIN."
  (with-temp-buffer
    (set-window-buffer win (current-buffer))
    (insert str "\n")
    (cdr (window-text-pixel-size win 1 3))))

(defun md-render--table-char-height-scale (char)
  "Return the display height scale needed for CHAR, or nil if none.

Color emoji and CJK glyphs typically render taller than the default
line height, which makes cells containing them taller than ASCII-only
cells in the same row.  When a table has rows of mixed glyph types,
the vertical borders end up at different y-positions and the
column lines look broken.  Scaling tall glyphs down via the
`display' `height' property forces a uniform line height across
all rows so borders connect cleanly.

The needed scale is just `default-h / char-h' — the factor that
brings the glyph back to the default height.  Results are cached."
  (let ((cached (gethash char md-render--table-height-scale-cache
                         'miss)))
    (if (eq cached 'miss)
        (let ((scale
               (let ((win (selected-window))
                     (orig-buf (window-buffer)))
                 (unwind-protect
                     (let* ((default-h
                             (or md-render--table-default-line-height
                                 (setq md-render--table-default-line-height
                                       (md-render--table-measure-line-height
                                        win "A"))))
                            (char-h (md-render--table-measure-line-height
                                     win (string char))))
                       (when (> char-h default-h)
                         (let ((ratio (/ (float default-h) char-h)))
                           (and (>= ratio
                                    md-render--table-min-height-scale)
                                ratio))))
                   (set-window-buffer win orig-buf)))))
          (puthash char scale md-render--table-height-scale-cache)
          scale)
      cached)))

(defun md-render--table-apply-height-scaling (str)
  "Add display height scaling to tall characters in STR.
Returns a new string with `display' `(height N)' on glyphs that
would otherwise cause uneven row heights — emoji, CJK, etc.
ASCII-only strings short-circuit and are returned unchanged."
  (if (or (not (display-graphic-p))
          (string-match-p (rx bos (* ascii) eos) str))
      str
    (let ((result (copy-sequence str))
          (len (length str)))
      (dotimes (i len)
        (let* ((ch (seq-elt result i))
               (scale (md-render--table-char-height-scale ch)))
          ;; Also scale a base char that's about to be widened by VS-16
          ;; (forces emoji presentation, which is what makes ⚠ become ⚠️).
          (unless scale
            (when (and (< (1+ i) len)
                       (= (seq-elt result (1+ i)) #xFE0F))
              (setq scale (md-render--table-char-height-scale
                           #xFE0F))))
          (when scale
            (put-text-property i (1+ i) 'display
                               `(height ,scale)
                               result))))
      result)))

(cl-defun md-render--table-display-width (&key str window)
  "Return display width of STR in character units.

ASCII content with no face properties uses the cheap
`string-width'.  Non-ASCII content, or ASCII content carrying a
`face' property (whose font may render at a different pixel
width — e.g. a theme styling inline-code with a wider family),
routes through `window-text-pixel-size' so column widths reflect
the actual rendered pixel width rather than a `string-width'
approximation.  Mixing the two paths within a column (some rows
ASCII-padded, some pixel-padded) accumulates fractional drift on
the right edge of the column and visibly misaligns the vertical
pipes between rows.  WINDOW supplies the active display metrics."
  (if (and window
           (window-live-p window)
           (fboundp 'window-text-pixel-size)
           (display-graphic-p)
           (or (not (string-match-p (rx bos (* ascii) eos) str))
               (md-render--text-has-face-p str)))
      (condition-case nil
          (let ((char-px (md-render--table-char-pixel-width window))
                (real-px (md-render--table-measure-string str window)))
            (ceiling (/ (float real-px) char-px)))
        (error (string-width str)))
    (string-width str)))

(cl-defun md-render--table-longest-word (&key str window)
  "Return display width of the longest unbreakable unit in STR.

Runs of non-breakable characters form unbreakable words, measured
via `md-render--table-display-width' (pixel-accurate
when WINDOW is given).  Line-breakable characters (category `|':
CJK ideographs, kana, Hangul, etc.) can wrap anywhere, so each
contributes only its own `char-width'.  Otherwise a
whitespace-free CJK sentence would count as one word and pin its
column at the full sentence width.

For example, \"foo bar\" yields 3 (\"foo\"), \"日本語\" yields 2,
and \"日本のfoo語\" yields 3 (\"foo\")."
  (if (or (null str) (string-empty-p str))
      0
    (let ((len (length str))
          (longest 0)
          (word-start nil))
      (dotimes (i (1+ len))
        (let* ((ch (and (< i len) (seq-elt str i)))
               (separator (or (null ch) (memq ch '(?\s ?\t ?\n))))
               (breakable (and (not separator)
                               (aref (char-category-set ch) ?|))))
          (when (and word-start (or separator breakable))
            (setq longest (max longest
                               (md-render--table-display-width
                                :str (substring str word-start i)
                                :window window)))
            (setq word-start nil))
          (cond
           (breakable (setq longest (max longest (char-width ch))))
           ((and (not separator) (not word-start))
            (setq word-start i)))))
      longest)))

(defun md-render--table-total-width (widths)
  "Return total rendered width for a table with column WIDTHS.
Accounts for borders and padding (`| X | Y |' = 2 padding +
1 pipe per column, plus one leading pipe)."
  (+ 1 (seq-reduce (lambda (acc w) (+ acc w 3)) widths 0)))

(defun md-render--table-allocate-widths (natural-widths min-widths target)
  "Shrink NATURAL-WIDTHS proportionally to fit TARGET, respecting MIN-WIDTHS."
  (let* ((total (md-render--table-total-width natural-widths))
         (excess (- total target)))
    (if (<= excess 0)
        natural-widths
      (let* ((shrinkable (seq-mapn (lambda (w m) (max 0 (- w m)))
                                   natural-widths min-widths))
             (total-shrinkable (seq-reduce #'+ shrinkable 0)))
        (if (<= total-shrinkable 0)
            min-widths
          (let ((ratio (min 1.0 (/ (float excess) total-shrinkable))))
            (seq-mapn (lambda (w m s)
                        (max m (floor (- w (* s ratio)))))
                      natural-widths min-widths shrinkable)))))))

(defun md-render--text-has-face-p (text)
  "Return non-nil if TEXT carries any `face' text property.
Used to decide whether table cell measurement / wrap must take the
pixel-accurate path: a face like `md-render-inline-code'
that pulls in a different font family or weight can render at a
different pixel width than `string-width' reports."
  (or (get-text-property 0 'face text)
      (next-single-property-change 0 'face text)))

(defvar-local md-render--table-face-width-cache nil
  "Hash table mapping face value → pixel-width ratio vs unfaced text.
Cache lives in the destination buffer so per-buffer font settings
such as text scaling and face remapping get their own ratios.  Lazily
initialized.")

(defun md-render--table-face-width-ratio (face window)
  "Return pixel-width ratio of FACE-styled text vs unfaced text in WINDOW.
A ratio of 1.0 means FACE doesn't affect rendered char width.
Cached per face in the destination buffer.

Ratios are always positive floats, so nil from `gethash' reliably
means \"not cached yet\" — no sentinel needed."
  (with-current-buffer (window-buffer window)
    (unless md-render--table-face-width-cache
      (setq md-render--table-face-width-cache
            (make-hash-table :test 'equal)))
    (or (gethash face md-render--table-face-width-cache)
        (let* ((sample "MMMMMMMMMM")
               (plain-px (md-render--table-measure-string
                          sample window)))
          (puthash face
                   (if (zerop plain-px) 1.0
                     (/ (float (md-render--table-measure-string
                                (propertize sample 'face face) window))
                        plain-px))
                   md-render--table-face-width-cache)))))

(cl-defun md-render--table-wrap-char-width (text pos &optional window)
  "Return the display width contribution of the char at POS in TEXT.

Mostly `char-width', but with one correction: U+FE0F VARIATION
SELECTOR-16 forces emoji presentation on the preceding char,
widening that glyph to 2 cells (e.g. `⚠' alone renders 1 col,
`⚠\\uFE0F' / `⚠️' renders 2).  `char-width' reports 1 for `⚠' and
0 for VS-16 — summing to 1 — even though the combined grapheme
takes 2 cells.  We compensate by attributing width 1 to VS-16
itself so the running total over the grapheme equals 2.

When WINDOW is a live graphic window and the char carries a `face'
property, the result is scaled by the face's measured pixel-width
ratio (see `md-render--table-face-width-ratio') so wrap
decisions match the rendered width.  This catches themes where
inline-code or bold faces pull in a wider/narrower font and the
unscaled `char-width' undercounts — letting an N-char wrap line
overflow an N-cell column and push the right pipe out of line."
  (let* ((ch (seq-elt text pos))
         (base (if (= ch #xFE0F) 1 (char-width ch))))
    (if-let* ((face (and window
                         (window-live-p window)
                         (display-graphic-p)
                         (fboundp 'window-text-pixel-size)
                         (get-text-property pos 'face text))))
        (condition-case nil
            (* base (md-render--table-face-width-ratio
                     face window))
          (error base))
      base)))

(defun md-render--table-wrap-string-width (text window)
  "Return face-aware display width of TEXT in cells.
Like `string-width' but, when WINDOW is graphic, scales each char
by its face's measured pixel-width ratio so the result tracks the
rendered width rather than the unstyled char count."
  (let ((sum 0))
    (dotimes (i (length text))
      (setq sum (+ sum
                   (md-render--table-wrap-char-width
                    text i window))))
    sum))

(defun md-render--table-break-after-p (text i)
  "Return non-nil when a wrapped line may break after index I in TEXT.
I + 1 must be a valid index into TEXT.  Breaks are allowed after a
line-breakable character (category `|': CJK ideographs, kana,
Hangul, etc.), unless the next character is zero-width (combining
character, variation selector, ZWJ) and must stay attached."
  (and (aref (char-category-set (seq-elt text i)) ?|)
       (> (char-width (seq-elt text (1+ i))) 0)))

(cl-defun md-render--table-wrap-text (text width &optional window)
  "Wrap TEXT to fit within WIDTH, returning a list of lines.
Preserves text properties across wrapped lines.

Breaks after whitespace or a line-breakable (CJK) character; a
run with no break point splits at the width limit.

Uses the VS-16-aware width helper so that emoji presentation
sequences (`⚠️') count as their actual rendered width (2 cells)
rather than the `string-width' approximation (1 cell), which
would otherwise let a 9-rendered-col cell fit inside a 8-col
column and overflow the table border on render.

When WINDOW is a live graphic window, char widths also factor in
any `face' property's pixel-width ratio so wrap lines fit the
column in pixel terms — themes that style inline-code with a
different font would otherwise produce wrap lines whose pixel
width exceeds the column budget, drifting the right pipe."
  (cond
   ((or (null text) (string-empty-p text)) (list ""))
   ((<= (md-render--table-wrap-string-width text window)
        ;; Subtract VS-16 occurrences from WIDTH for the fit check —
        ;; each VS-16 widens its base char by 1 cell beyond what
        ;; `string-width' reports, so the effective budget shrinks
        ;; by one per VS-16 present.
        (- width
           (seq-count (lambda (c) (= c #xFE0F)) text)))
    (list text))
   (t
    (let ((lines '())
          (pos 0)
          (len (length text)))
      (while (< pos len)
        ;; Greedily consume chars until adding the next one would
        ;; exceed WIDTH (using VS-16-aware widths).
        (let ((end-pos pos)
              (line-width 0))
          (while (and (< end-pos len)
                      (<= (+ line-width
                             (md-render--table-wrap-char-width
                              text end-pos window))
                          width))
            (setq line-width
                  (+ line-width
                     (md-render--table-wrap-char-width
                      text end-pos window)))
            (setq end-pos (1+ end-pos)))
          ;; Make sure at least one char advances even when the very
          ;; first char already exceeds WIDTH (e.g. wide glyph).
          (when (= end-pos pos)
            (setq end-pos (1+ pos)))
          ;; Try to break at the last clean break point within
          ;; [pos, end-pos): after whitespace, or after a
          ;; line-breakable (CJK) character.
          (let ((break-pos end-pos))
            (when (< end-pos len)
              (let ((scan (1- end-pos)))
                (while (and (>= scan pos)
                            (not (and (> scan pos)
                                      (memq (seq-elt text scan) '(?\s ?\t))))
                            (not (md-render--table-break-after-p
                                  text scan)))
                  (setq scan (1- scan)))
                (when (>= scan pos)
                  (setq break-pos (1+ scan)))))
            (push (string-trim-right (substring text pos break-pos)) lines)
            (setq pos break-pos)
            (while (and (< pos len)
                        (memq (seq-elt text pos) '(?\s ?\t)))
              (setq pos (1+ pos))))))
      (nreverse lines)))))

(cl-defun md-render--pad-table-string (&key str width window force-pixel)
  "Pad STR with spaces to reach WIDTH columns.

ASCII-only strings take the cheap `string-width' + spaces path.
Any non-ASCII content (single-codepoint emoji, CJK, ZWJ
sequences, regional-indicator flags, VS-16 emoji) routes through
pixel-accurate measurement.  Mixing the two paths within a
column accumulates fractional drift between rows and visibly
misaligns the right-edge pipes.

When FORCE-PIXEL is non-nil, the pixel path is taken regardless of
STR's content.  Callers use this to keep all wrapped lines of one
multi-line cell on the same path — otherwise a wrapped cell that
splits non-ASCII content (e.g. an em dash) onto one line and pure
ASCII content onto another would render those continuation lines
via different paths and drift sub-pixel on their right edge.
WINDOW supplies the active display metrics."
  (if (and window
           (window-live-p window)
           (fboundp 'window-text-pixel-size)
           (display-graphic-p)
           (or force-pixel
               (not (string-match-p (rx bos (* ascii) eos) str))
               (md-render--text-has-face-p str)))
      (condition-case nil
          (let* ((char-px (md-render--table-char-pixel-width window))
                 (target-px (* width char-px))
                 (content-px (md-render--table-measure-string str window))
                 (pad-px (- target-px content-px)))
            (if (<= pad-px 0)
                str
              (let* ((full-spaces (floor (/ (float pad-px) char-px)))
                     (remaining-px (- pad-px (* full-spaces char-px))))
                (concat str
                        (make-string full-spaces ?\s)
                        (if (> remaining-px 0)
                            (propertize " " 'display
                                        `(space :width (,remaining-px)))
                          "")))))
        (error (md-render--pad-table-string-ascii :str str :width width)))
    (md-render--pad-table-string-ascii :str str :width width)))

(cl-defun md-render--pad-table-string-ascii (&key str width)
  "Append spaces to STR until it reaches WIDTH columns."
  (let ((current (string-width str)))
    (if (>= current width)
        str
      (concat str (make-string (- width current) ?\s)))))

(defun md-render--make-table-separator-cell (width)
  "Return a separator-cell string of WIDTH dashes."
  (make-string width
               (if md-render-table-use-unicode-borders ?─ ?-)))

(defun md-render--table-row-face (row separator-row-num data-row-num)
  "Return the display face for ROW at DATA-ROW-NUM.
SEPARATOR-ROW-NUM identifies the row separating headers from data."
  (let ((row-num (map-elt row :num)))
    (cond
     ((and separator-row-num (< row-num separator-row-num))
      'md-render-table-header)
     ((and md-render-table-zebra-stripe
           (not (map-elt row :separator))
           (= (mod data-row-num 2) 1))
      'md-render-table-zebra))))

(defun md-render--render-table-separator-row (col-widths)
  "Build the rendered separator line for COL-WIDTHS."
  (let ((pipe (if md-render-table-use-unicode-borders "┼" "|"))
        (left (if md-render-table-use-unicode-borders "├" "|"))
        (right (if md-render-table-use-unicode-borders "┤" "|")))
    (concat
     (propertize left 'face 'md-render-table-border)
     (mapconcat
      (lambda (w)
        (propertize (md-render--make-table-separator-cell (+ w 2))
                    'face 'md-render-table-border))
      col-widths
      (propertize pipe 'face 'md-render-table-border))
     (propertize right 'face 'md-render-table-border))))

(cl-defun md-render--render-table-data-row (&key processed-cells col-widths row-face window)
  "Build the rendered string for a data row, possibly multi-line.

PROCESSED-CELLS is the list of propertized cell strings.
COL-WIDTHS is the list of column widths.  ROW-FACE, when non-nil,
is layered on top of the row content (preserving inline faces).
WINDOW, when given, is forwarded to `md-render--pad-table-string'
for pixel-accurate padding of non-ASCII content.

Each cell on the first physical line of a wrapped row carries
`md-render-table-cell-start' on its leading padding char so
`md-render-table-next-cell' / `-previous-cell' can navigate
logical rows (skipping the visual continuation lines)."
  (let* ((pipe (if md-render-table-use-unicode-borders "│" "|"))
         (styled-pipe (propertize pipe 'face 'md-render-table-border))
         (wrapped (seq-mapn
                   (lambda (cell width)
                     (md-render--table-wrap-text
                      cell width window))
                   processed-cells col-widths))
         ;; Per-cell "force pixel padding" flag, decided once from the
         ;; un-wrapped cell content and applied to every wrapped line
         ;; of that cell.  Without this, a cell whose wrap splits
         ;; non-ASCII content (e.g. an em dash) onto one line and pure
         ;; ASCII onto another would render those lines via different
         ;; padding paths and drift sub-pixel apart on their right edge.
         ;; Face-styled cells (e.g. inline-code) also need the pixel
         ;; path so padding pins the right edge to the column's pixel
         ;; budget — when a theme styles inline-code with a wider font
         ;; the ASCII path's `string-width' undercounts and the right
         ;; pipe drifts past the column boundary.
         (force-pixel-flags
          (mapcar (lambda (cell)
                    (or (not (string-match-p (rx bos (* ascii) eos) cell))
                        (md-render--text-has-face-p cell)))
                  processed-cells))
         (max-lines (apply #'max 1 (mapcar #'length wrapped)))
         (lines '()))
    (dotimes (line-idx max-lines)
      (let ((parts '()))
        (seq-mapn
         (lambda (cell-lines width force-pixel)
           (let* ((line (if (< line-idx (length cell-lines))
                            (nth line-idx cell-lines)
                          ""))
                  (padded (concat " "
                                  (md-render--pad-table-string
                                   :str line :width width :window window
                                   ;; Empty continuation lines have no
                                   ;; content to measure — leaving them
                                   ;; on the ASCII path avoids a wasted
                                   ;; pixel measurement that some Emacs
                                   ;; builds appear to mishandle for an
                                   ;; empty range.
                                   :force-pixel (and force-pixel
                                                     (not (string-empty-p
                                                           line))))
                                  " ")))
             (when row-face
               (add-face-text-property 0 (length padded) row-face t padded))
             ;; Mark first physical line of each cell as navigable —
             ;; continuation lines of a wrapped row aren't standalone
             ;; cells.  Tag the first content char (index 1, past the
             ;; leading padding space) so navigation lands cursor on
             ;; the content rather than the border-adjacent space.
             (when (and (zerop line-idx) (> (length padded) 1))
               (put-text-property 1 2 'md-render-table-cell-start t padded))
             (push padded parts)))
         wrapped col-widths force-pixel-flags)
        (push (concat styled-pipe
                      (string-join (nreverse parts) styled-pipe)
                      styled-pipe)
              lines)))
    (mapconcat #'identity (nreverse lines) "\n")))

(cl-defun md-render--preprocess-table (&key rows separator-row-num window)
  "Parse cells in ROWS and compute natural column widths.
Returns an alist with `:natural-widths' and `:processed-rows'.

SEPARATOR-ROW-NUM identifies the row separating headers from data.
`:min-widths' (wrap-allocation widths from longest words) is no
longer computed here — it's only needed when the table has to be
allocated narrower than its natural total, and computing it for
every cell on every render is a substantial cost.  Callers that
need it should use `md-render--table-min-widths'.

When WINDOW is given, cell widths are measured with
pixel-accurate `md-render--table-display-width' so columns
containing emoji/CJK line up with the column's right border."
  (let ((data-row-num 0)
        (widths nil)
        (processed-rows nil))
    (dolist (row rows)
      (if (map-elt row :separator)
          (push (cons row nil) processed-rows)
        (let ((cells (md-render--parse-table-row
                      (map-elt row :start) (map-elt row :end)))
              (col 0)
              (processed-cells nil)
              (row-face (md-render--table-row-face
                         row separator-row-num data-row-num)))
          (dolist (cell cells)
            (let ((processed (md-render--table-apply-height-scaling
                              (map-elt cell :content))))
              (when row-face
                (add-face-text-property
                 0 (length processed) row-face t processed))
              (let ((dw (md-render--table-display-width
                         :str processed :window window)))
                (push processed processed-cells)
                (if (nth col widths)
                    (setf (nth col widths) (max (nth col widths) dw))
                  (setq widths (append widths (list dw))))
                (setq col (1+ col)))))
          (push (cons row (nreverse processed-cells)) processed-rows)
          (unless (and separator-row-num
                       (< (map-elt row :num) separator-row-num))
            (setq data-row-num (1+ data-row-num))))))
    (list (cons :natural-widths widths)
          (cons :processed-rows (nreverse processed-rows)))))

(cl-defun md-render--table-min-widths (&key processed-rows window)
  "Return the minimum (longest-word) widths per column.
Compute them from PROCESSED-ROWS using display metrics from WINDOW.
This runs only when a table must be narrower than its natural total;
see `md-render--render-table-source'."
  (let ((min-widths nil))
    (dolist (entry processed-rows)
      (let ((cells (cdr entry))
            (col 0))
        (dolist (processed cells)
          (let ((mw (md-render--table-longest-word
                     :str processed :window window)))
            (if (nth col min-widths)
                (setf (nth col min-widths) (max (nth col min-widths) mw))
              (setq min-widths (append min-widths (list mw))))
            (setq col (1+ col))))))
    min-widths))

(defun md-render--render-table (table)
  "Render TABLE by replacing [:start, :end] with the rendered :source.

The rendered chars carry:
  - a prepended `fixed-pitch' face — pinning the family keeps
    padding, borders, and cell fonts aligned even under
    `variable-pitch-mode' (mirrors the source view's rule).
  - `md-render-frozen t' — so subsequent passes skip them.
  - `md-render-table-source SOURCE' — the original markdown
    source, stashed so a future `md-render-replace-markup'
    call can combine it with freshly-streamed rows that arrive
    right after, then re-render the whole table with updated
    column widths.

Caller-set text properties at the table's start position (e.g.,
`read-only', application-specific tags like an agent-shell block
id) are also carried onto the rendered region — otherwise the
delete+insert would drop them and break callers that look up
regions by text property.

`rear-nonsticky' prevents new chars inserted just after the
rendered region from inheriting either of our two properties."
  (let* ((source (map-elt table :source))
         (table-start (map-elt table :start))
         (table-end (map-elt table :end))
         ;; Capture the destination window for pixel-accurate
         ;; measurement of non-ASCII cells.  This is the window into
         ;; which we're rendering; the render-table-source helper
         ;; forwards it through to width / padding measurement.
         (window (or (get-buffer-window (current-buffer))
                     (selected-window)))
         (rendered (md-render--render-table-source
                    :source source :window window))
         (carried (md-render--carry-properties table-start)))
    ;; Pin the family on the output itself (see docstring): the
    ;; default face gets remapped by `variable-pitch-mode' and the
    ;; padding math assumes monospace, so alignment must not depend
    ;; on which face is active when the table renders.
    (add-face-text-property 0 (length rendered) 'fixed-pitch nil rendered)
    (delete-region table-start table-end)
    (goto-char table-start)
    (insert rendered)
    (let ((end (+ table-start (length rendered))))
      (when carried
        (add-text-properties table-start end carried))
      (add-text-properties
       table-start end
       `(md-render-frozen t
                                     md-render-table-source ,source
                                     ;; Mirror the source under the generic property that
                                     ;; `md-render-reconstruct' reads, so tables reconstruct
                                     ;; the same way every other block does.
                                     md-render-source ,source
                                     rear-nonsticky (md-render-frozen
                                                     md-render-table-source
                                                     md-render-source))))))

(defun md-render--carry-properties (pos)
  "Return a plist of properties at POS to carry across our delete+insert.

Filters out presentation properties such as `face', `font-lock-face',
and `display', plus rendering properties such as `md-render-frozen',
`md-render-table-source', `md-render-source', and `rear-nonsticky'.
This lets application-level properties such as read-only state and
agent-shell block ids survive on the rendered output."
  (let ((props (text-properties-at pos))
        (carried nil))
    (while props
      (let ((key (car props))
            (val (cadr props)))
        (unless (memq key '(face
                            font-lock-face
                            display
                            md-render-frozen
                            md-render-table-source
                            md-render-source
                            rear-nonsticky))
          (setq carried (cons val (cons key carried))))
        (setq props (cddr props))))
    (nreverse carried)))

(defun md-render-reconstruct (beg end)
  "Return the text between BEG and END with the original markdown restored.

Each rendered construct stashes the markdown for its span on the
`md-render-source' text property.  A span fully contained
in [BEG, END) contributes its stored source; a span whose source is
empty (inserted chrome, e.g. a code-block's language label) always
contributes nothing; other partially-selected and unrendered text
contribute their visible buffer text verbatim.

This reconstructs source removed by `md-render-replace-markup'.
The styling passes also call it (guarded, before deleting their
markup) to capture a construct's own source: expanding the markup
span in place lets the delimiters and un-rendered inner markup pass
through verbatim, while any nested run a deeper construct already
stashed is substituted with that construct's source (such runs are
always fully inside the markup span, so the containment test holds)."
  (let ((pos beg)
        (parts '()))
    (while (< pos end)
      (let* ((source (get-text-property pos 'md-render-source))
             (run-end (next-single-property-change
                       pos 'md-render-source nil (point-max)))
             (limit (min run-end end)))
        (push
         (cond
          ;; Inserted chrome (empty source, e.g. a code-block label) is
          ;; not markdown, so it vanishes whether wholly or partly
          ;; selected.
          ((equal source "") "")
          ;; A stashed span contributes its source only when wholly inside
          ;; [BEG, END).  Test the cheap bound before the backward scan.
          ((and source
                (<= run-end end)
                (>= (previous-single-property-change
                     (min (1+ pos) (point-max))
                     'md-render-source nil (point-min))
                    beg))
           source)
          ;; Plain text, or a partially-selected span: emit as shown.
          (t (buffer-substring-no-properties pos limit)))
         parts)
        (setq pos limit)))
    (apply #'concat (nreverse parts))))

(defun md-render-link-url-at-point (&optional pos)
  "Return the rendered Markdown link URL at POS (or point), when available.

The renderer stamps `[title](url)' links with the target URL on the
`md-render-url' text property, so copy/export integrations
can recover the link once the `(url)' markup is gone from the buffer.
Returns nil when POS is not on a rendered link."
  (get-text-property (or pos (point)) 'md-render-url))

(defun md-render-source-block-at-point (&optional pos)
  "Return the rendered fenced code block body at POS (or point), when available.

Returns the code body (without the fences or the language label) when
POS lands on a rendered block's body, the region the renderer tags
with `md-render-source-block-body'.  Returns nil otherwise;
the language label above the body copies its own body via RET."
  (setq pos (or pos (point)))
  (when (get-text-property pos 'md-render-source-block-body)
    (buffer-substring-no-properties
     (or (previous-single-property-change
          (min (1+ pos) (point-max))
          'md-render-source-block-body)
         (point-min))
     (or (next-single-property-change
          pos 'md-render-source-block-body)
         (point-max)))))

(cl-defun md-render--render-table-source (&key source window)
  "Render SOURCE (markdown table text) to a propertized string.

SOURCE may carry text properties from earlier passes (bold faces
on cell content, `md-render-frozen' on inline-code bodies,
etc.); these are preserved through to the rendered output via
the cell parser.

WINDOW, when given, is the destination window used for pixel-
accurate width measurement of non-ASCII cell content (emoji,
CJK) so right borders align across rows.  Without it,
measurement falls back to `string-width' — fine for ASCII but
prone to a few-pixel drift on emoji-heavy tables."
  (with-temp-buffer
    (insert source)
    ;; SOURCE inherits `field' text properties from the calling buffer
    ;; (e.g. agent-shell tags chars with `field output'); inter-row
    ;; `\\n's may carry different field values, which would otherwise
    ;; cause `forward-line' / `line-end-position' in the parsers below
    ;; to stop at field boundaries and silently drop rows.
    (setq-local inhibit-field-text-motion t)
    (let* ((rows (md-render--collect-table-rows))
           (separator-row-num (md-render--find-separator-row-num rows))
           (preprocessed (md-render--preprocess-table
                          :rows rows
                          :separator-row-num separator-row-num
                          :window window))
           (natural-widths (map-elt preprocessed :natural-widths))
           (processed-rows (map-elt preprocessed :processed-rows))
           (target-width (when md-render-table-wrap-columns
                           (floor (* (md-render--display-width)
                                     md-render-table-max-width-fraction))))
           (needs-allocation (and target-width
                                  (> (md-render--table-total-width
                                      natural-widths)
                                     target-width)))
           ;; `:min-widths' is expensive (longest-word per cell) and only
           ;; consumed by allocation, which kicks in only when the
           ;; natural total exceeds the target.  Compute lazily.
           (col-widths (if needs-allocation
                           (md-render--table-allocate-widths
                            natural-widths
                            (md-render--table-min-widths
                             :processed-rows processed-rows
                             :window window)
                            target-width)
                         natural-widths))
           (data-row-num 0)
           (rendered-rows '()))
      (dolist (entry processed-rows)
        (let* ((row (car entry))
               (processed-cells (cdr entry))
               (row-num (map-elt row :num))
               (is-separator (map-elt row :separator))
               (row-face (md-render--table-row-face
                          row separator-row-num data-row-num)))
          (unless (or (and separator-row-num
                           (< row-num separator-row-num))
                      is-separator)
            (setq data-row-num (1+ data-row-num)))
          (push (if is-separator
                    (md-render--render-table-separator-row col-widths)
                  (md-render--render-table-data-row
                   :processed-cells processed-cells
                   :col-widths col-widths
                  :row-face row-face
                  :window window))
                rendered-rows)))
      (string-join (nreverse rendered-rows) "\n"))))

(defun md-render--collect-table-rows ()
  "Collect table rows in current buffer (typically a temp buffer).
Each row is an alist with :start, :end, :num, :separator."
  (save-excursion
    (goto-char (point-min))
    (let ((rows '())
          (row-num 0))
      (while (and (not (eobp))
                  (looking-at md-render--table-line-regexp))
        (push `((:start . ,(point))
                (:end . ,(line-end-position))
                (:num . ,row-num)
                (:separator . ,(looking-at
                                md-render--table-separator-regexp)))
              rows)
        (setq row-num (1+ row-num))
        (forward-line 1))
      (nreverse rows))))

(defun md-render--find-separator-row-num (rows)
  "Return the index of the first separator row in ROWS, or nil."
  (let ((idx 0) (result nil))
    (dolist (row rows)
      (when (and (not result) (map-elt row :separator))
        (setq result idx))
      (setq idx (1+ idx)))
    result))

(cl-defun md-render--style-tables (&key avoid-ranges)
  "Render markdown tables found in current buffer.

Each detected table has its source rows deleted from the buffer
and the prettified rendering inserted in their place; the
inserted text carries `md-render-frozen' so subsequent calls
skip it.  Tables whose first row is already frozen — meaning
they live inside a fenced block, an inline-code body, or a
previously-rendered table — are left alone.

AVOID-RANGES is a list of (START . END) cons cells covering
regions the renderer must not touch (e.g. still-open fenced code
blocks whose closing fence hasn't streamed in yet).

Honours `md-render-prettify-tables'.  Cell content is taken
directly from the buffer (with text properties preserved from
the earlier inline passes), so bold/italic/inline-code/link
rendering inside cells is provided for free."
  (when md-render-prettify-tables
    ;; Process tables in reverse so earlier positions stay valid as
    ;; each replacement shifts everything after it.
    (dolist (table (nreverse (md-render--find-tables
                              :avoid-ranges avoid-ranges)))
      (md-render--render-table table))))

(defun md-render-table-next-cell ()
  "Move point to the start of the next table cell.
Wraps from the end of a row to the first cell of the next row.
Skips the separator row.  Signals `No more cells left' when
point is at or past the last cell of the table at point.

For example, with point inside cell `A' of:

  │ A │ B │
  ├───┼───┤
  │ 1 │ 2 │

a single call lands point on `B', another lands on `1', another
on `2', and a fourth signals `No more cells left'."
  (interactive)
  (md-render--table-move-cell :forward))

(defun md-render-table-previous-cell ()
  "Move point to the start of the previous table cell.
Wraps from the start of a row to the last cell of the previous
row.  Skips the separator row.  Signals `No more cells left'
when point is at or before the first cell of the table at point.

Inverse of `md-render-table-next-cell'."
  (interactive)
  (md-render--table-move-cell :backward))

(defun md-render--table-move-cell (direction)
  "Move point to the next or previous cell in the table at point.
DIRECTION is `:forward' or `:backward'.  Signals `user-error' when
there's no cell in that direction."
  (let* ((cells (md-render--table-cell-starts))
         ;; Largest cell-start index whose position is <= point — the
         ;; cell currently containing point.  -1 means point is before
         ;; the first cell.  CELLS is sorted ascending so we just walk
         ;; it tracking the last index that still satisfies the bound.
         (point-pos (point))
         (current -1)
         (i 0))
    (dolist (c cells)
      (when (<= c point-pos)
        (setq current i))
      (setq i (1+ i)))
    (let ((target (if (eq direction :forward) (1+ current) (1- current))))
      (if (and cells (<= 0 target) (< target (length cells)))
          (goto-char (nth target cells))
        (user-error "No more cells left")))))

(defun md-render--table-cell-starts ()
  "Return a sorted list of cell-start positions in the table at point.
Returns nil when point isn't inside a rendered md-render
table.  Navigable cells are tagged by the renderer with the
`md-render-table-cell-start' text property, so separator rows
and continuation lines of wrapped rows are skipped automatically."
  (when-let* ((region (md-render--table-region-at-point)))
    (let ((positions nil))
      (save-excursion
        (save-restriction
          (narrow-to-region (car region) (cdr region))
          (goto-char (point-min))
          (while (let ((m (text-property-search-forward
                           'md-render-table-cell-start t t)))
                   (when m
                     (push (prop-match-beginning m) positions)
                     t)))))
      (nreverse positions))))

(defun md-render--table-region-at-point ()
  "Return (START . END) of the rendered table at point, or nil."
  (when (get-text-property (point) 'md-render-table-source)
    (cons (or (previous-single-property-change
               (1+ (point)) 'md-render-table-source nil (point-min))
              (point-min))
          (or (next-single-property-change
               (point) 'md-render-table-source nil (point-max))
              (point-max)))))

(defun md-render--apply-faces-from (propertized buffer-start)
  "Layer `face' properties from PROPERTIZED on chars at BUFFER-START..

Uses `add-face-text-property' with PREPEND so the language's
font-lock faces take priority in the cascade over whatever face
the caller seeded the region with (e.g. a background panel face).
Chars in PROPERTIZED without a `face' are left untouched, so the
caller's seeded face shows through."
  (let ((pos 0)
        (len (length propertized)))
    (while (< pos len)
      (let ((face (get-text-property pos 'face propertized))
            (next (or (next-single-property-change pos 'face propertized) len)))
        (when face
          (add-face-text-property (+ buffer-start pos) (+ buffer-start next)
                                  face))
        (setq pos next)))))

(defun md-render--mirror-face-to-font-lock-face (start end)
  "Copy each `face' run across [START, END) to `font-lock-face'.

`font-lock-mode' takes ownership of the `face' property and
clears it on re-fontification, which would wipe out our markup
styling in buffers that fontify continuously (comint, shell-maker,
agent-shell, etc.).  `font-lock-face' is the property reserved
for callers who want their face to coexist — when font-lock is
on, the display engine renders `font-lock-face' as if it were
`face' and font-lock leaves it alone; when font-lock is off,
`font-lock-face' is ignored and our plain `face' renders.
Setting both means we look right in both contexts.

Only positions with a non-nil `face' are mirrored; positions
already carrying a `font-lock-face' from elsewhere are
overwritten — md-render owns the styling for the chars it
produced."
  (let ((pos start))
    (while (< pos end)
      (let ((face (get-text-property pos 'face))
            (next (or (next-single-property-change pos 'face nil end) end)))
        (when face
          (put-text-property pos next 'font-lock-face face))
        (setq pos next)))))

(defun md-render--highlight-code (code lang)
  "Return CODE syntax-highlighted using LANG's major mode.

LANG is a language identifier as written after the opening
fence (e.g. \"python\", \"elisp\").  When the resolved mode is
loadable, CODE is fontified in a temporary buffer and returned
with face properties applied.  Otherwise CODE is returned
unchanged."
  (if-let* ((mode (md-render--resolve-lang-mode lang))
            ((fboundp mode)))
      (with-temp-buffer
        (insert code)
        (let ((inhibit-message t)
              (delay-mode-hooks t))
          (funcall mode)
          (font-lock-ensure))
        (buffer-string))
    code))

(defun md-render--resolve-lang-mode (lang)
  "Resolve LANG string to a major mode symbol, or nil.
LANG is case-folded and trimmed; `md-render-language-mapping'
is consulted for aliases before the `-mode' suffix is appended."
  (when (and lang (not (string-empty-p (string-trim lang))))
    (let* ((normalized (downcase (string-trim lang)))
           (resolved (or (map-elt md-render-language-mapping
                                  normalized)
                         normalized))
           (mode (intern (concat resolved "-mode"))))
      (when (fboundp mode)
        mode))))

(defun md-render--make-ret-binding-map (fun)
  "Return a sparse keymap binding RET and a mouse click to FUN."
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") fun)
    (define-key map [mouse-1] fun)
    (define-key map [remap self-insert-command] 'ignore)
    map))

(defun md-render--open-link (url)
  "Open URL.  Use local navigation for file links, `browse-url' otherwise."
  (unless (md-render--open-local-link url)
    (browse-url url)))

(defun md-render--open-externally (file)
  "Prompt to open FILE with the operating system's default external program.
Opens FILE only if the user confirms.  Uses `shell-command-do-open' on
Emacs 31+, falling back to `browse-url-of-file' on earlier versions."
  (when (y-or-n-p (format "Open %s externally? " (file-name-nondirectory file)))
    (if (fboundp 'shell-command-do-open)
        (shell-command-do-open (list file))
      (browse-url-of-file file))))

(defun md-render--binary-file-p (file)
  "Return non-nil when FILE looks binary (a NUL byte in its first 4KB).
This is the heuristic git uses to tell binary from text."
  (and (file-readable-p file)
       (with-temp-buffer
         (set-buffer-multibyte nil)
         (insert-file-contents-literally file nil 0 4096)
         (string-search "\0" (buffer-string)))))

(defun md-render--open-local-link (url)
  "Open URL as a local file link if possible.
Return non-nil if handled, nil otherwise.

Text/navigable files open in Emacs, jumping to the `#Lnnn' line when URL
carries one.  Binary files (which Emacs can't usefully display) instead
prompt to open with the operating system's default program, ignoring any
`#Lnnn' line (a line number is meaningless for binary)."
  (when-let* ((parsed (md-render--parse-local-link url)))
    (let ((file (car parsed))
          (line (cdr parsed)))
      (if (md-render--binary-file-p file)
          (md-render--open-externally file)
        (find-file file)
        (when line
          (goto-char (point-min))
          (forward-line (1- line)))))
    t))

(defun md-render--parse-local-link (url)
  "Parse URL as a local file link.
Return a (FILE . LINE) cons when URL points to an existing local
file (LINE may be nil), or nil otherwise.

For example:

  \"foo.el#L10\"             => (\"/abs/foo.el\" . 10)
  \"foo.el\"                 => (\"/abs/foo.el\" . nil)
  \"file:src/bar.el:5\"      => (\"/abs/src/bar.el\" . 5)
  \"file:///tmp/baz.el#L20\" => (\"/tmp/baz.el\" . 20)
  \"https://example.com\"    => nil"
  (when-let* ((match
               (cond
                ((string-match
                  (rx bos "file://"
                      (group (+? anything))
                      (optional (or (seq "#L" (group (one-or-more digit)))
                                    (seq ":" (group (one-or-more digit)))))
                      eos)
                  url)
                 (cons (match-string 1 url)
                       (or (match-string 2 url) (match-string 3 url))))
                ((string-match
                  (rx bos "file:"
                      (group (not (any "/")) (+? anything))
                      (optional (or (seq "#L" (group (one-or-more digit)))
                                    (seq ":" (group (one-or-more digit)))))
                      eos)
                  url)
                 (cons (match-string 1 url)
                       (or (match-string 2 url) (match-string 3 url))))
                ((string-match
                  (rx bos
                      (group (? (optional "/") alpha ":/")
                             (one-or-more (not (any ":#"))))
                      "#L" (group (one-or-more digit))
                      eos)
                  url)
                 (cons (match-string 1 url) (match-string 2 url)))
                ((string-match
                  (rx bos
                      (group (? (optional "/") alpha ":/")
                             (one-or-more (not (any ":#"))))
                      ":" (group (one-or-more digit))
                      eos)
                  url)
                 (cons (match-string 1 url) (match-string 2 url)))
                ((not (string-empty-p url))
                 (cons url nil))))
              (filepath (expand-file-name (car match))))
    (when (file-exists-p filepath)
      (cons filepath
            (when (cdr match)
              (string-to-number (cdr match)))))))

(cl-defun md-render--url-copy-file (&key url file (timeout 5.0) content-type-prefix)
  "Download URL to FILE, returning FILE on success or nil on failure.

A hardened `url-copy-file': the fetch is synchronous but bounded by TIMEOUT
seconds (`url-copy-file' itself has no timeout), the response must be HTTP
200, and -- when CONTENT-TYPE-PREFIX is non-nil -- its `Content-Type' must
start with that prefix (e.g. \"image/\").  FILE is left untouched unless the
response passes every check, so an error page is never written in place of
the expected content.  Returns nil rather than signaling on any failure."
  (when-let* ((buffer (url-retrieve-synchronously url t t timeout)))
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-min))
          (when (and (re-search-forward "^HTTP/[0-9.]+ 200" nil t)
                     (or (not content-type-prefix)
                         (save-excursion
                           (re-search-forward
                            (concat "^Content-Type:[ \t]*" (regexp-quote content-type-prefix))
                            nil t)))
                     (re-search-forward "\r?\n\r?\n" nil t))
            (make-directory (file-name-directory file) t)
            (let ((coding-system-for-write 'no-conversion))
              (write-region (point) (point-max) file))
            file))
      (kill-buffer buffer))))

(defun md-render--fetch-remote-image (url image-cache-directory)
  "Download the remote image at URL into IMAGE-CACHE-DIRECTORY; return its path.

Returns the local cache file path, or nil when IMAGE-CACHE-DIRECTORY is nil,
URL is not an http(s) image URL, the download fails, or the response isn't
an image.  Remote images are only fetched when an IMAGE-CACHE-DIRECTORY is
provided, so a renderer with no cache configured leaves remote image markup
as text.  The cache file is named from URL's md5 so the same URL is fetched
at most once.  Only URLs ending in a known image extension are fetched, and
the response must carry an `image/...' Content-Type before it is cached (see
`md-render--url-copy-file'), so an error page is never stored as
an image."
  (when-let* (((stringp url))
              ((stringp image-cache-directory))
              ((string-match-p "\\`https?://" url))
              (extension (downcase (or (file-name-extension
                                        (replace-regexp-in-string "[?#].*\\'" "" url))
                                       "")))
              ((seq-contains-p image-file-name-extensions extension))
              (cache-path (expand-file-name
                           (format "%s.%s" (md5 url) extension)
                           image-cache-directory)))
    (if (file-exists-p cache-path)
        cache-path
      (md-render--url-copy-file :url url
                                           :file cache-path
                                           :content-type-prefix "image/"))))

(defun md-render--resolve-image-url (url &optional image-cache-directory)
  "Resolve image URL to an absolute local file path, or nil.
Handles http(s) URLs (downloaded into IMAGE-CACHE-DIRECTORY and cached via
`md-render--fetch-remote-image'; not fetched when
IMAGE-CACHE-DIRECTORY is nil), file:// URIs, absolute paths, and paths
starting with `~/', `./', or `../'."
  (if (string-match-p "\\`https?://" url)
      (md-render--fetch-remote-image url image-cache-directory)
    (when-let* ((path (cond
                       ((string-prefix-p "file://" url)
                        (url-unhex-string
                         (url-filename (url-generic-parse-url url))))
                       ((string-prefix-p "file:" url)
                        (substring url (length "file:")))
                       ((or (file-name-absolute-p url)
                            (string-prefix-p "~" url)
                            (string-prefix-p "./" url)
                            (string-prefix-p "../" url))
                        url)))
                (expanded (expand-file-name path))
                ((file-exists-p expanded)))
      expanded)))

(defun md-render--image-max-width ()
  "Return the maximum image width in pixels.
Resolve `md-render-image-max-width' as either an integer pixel
count or a float between 0 and 1 representing window body width."
  (if (floatp md-render-image-max-width)
      (let ((window (or (get-buffer-window (current-buffer))
                        (frame-first-window))))
        (round (* md-render-image-max-width
                  (window-body-width window t))))
    md-render-image-max-width))

(defun md-render--watermark-start ()
  "Return the position the next scan should start from.

Reads the `md-render-watermark' text property off the
first character.  When absent or out of range, returns
`point-min' (whole-buffer scan — the conservative default for the
first call or after the watermark anchor has been rewritten away).

The property is stored on the rendered text itself so it travels
with the string when callers shuttle the buffer contents around
via `md-render-convert', avoiding a buffer-local
variable that wouldn't survive serialization."
  (let ((stored (and (> (point-max) (point-min))
                     (get-text-property (point-min)
                                        'md-render-watermark))))
    (if (and (integerp stored)
             (>= stored (point-min))
             (<= stored (point-max)))
        stored
      (point-min))))

(defun md-render--extending-table-start ()
  "Start of a table region whose rendering is still pending, or nil.

Walks lines backward from `point-max' through pipe-row
candidates.  Two cases warrant a backoff:

- A line already carries `md-render-table-source' —
  i.e. a previously-rendered table whose new rows we want
  `--find-tables' to fold in on the next call.

- An unbroken streak of raw pipe-rows leads back from
  `point-max' — i.e. a table whose rows have streamed in but
  whose row count has never been high enough at one call for
  `--find-tables' to render.  Without this backoff, the
  watermark advances past each row one chunk at a time and the
  table is silently never rendered.

Stops on the first non-pipe-row non-table line — past that
point, a table from there can no longer accumulate."
  (when (> (point-max) (point-min))
    (save-excursion
      ;; Walk from the last content line.  `forward-line 0' moves to
      ;; the start of the line containing point; if that landed us on
      ;; an empty trailing line (buffer ends with `\\n'), step one
      ;; line further back so the loop's first iteration examines
      ;; actual content rather than the empty tail.
      (goto-char (point-max))
      (forward-line 0)
      (when (and (eobp) (not (bobp)))
        (forward-line -1))
      (let (rendered-table-start
            pending-table-start
            (continue t))
        (while continue
          (cond
           ;; Hit a char already inside a rendered table — find its start.
           ((get-text-property (point) 'md-render-table-source)
            (setq rendered-table-start
                  (or (previous-single-property-change
                       (1+ (point))
                       'md-render-table-source)
                      (point-min)))
            (setq continue nil))
           ;; Pipe-row (or still-streaming partial of one) — remember
           ;; the earliest streak entry and step back another line.
           ;; The lenient regex also matches partial separators that
           ;; haven't grown their closing `|' yet, so the watermark
           ;; doesn't slip past the header while the separator is
           ;; mid-stream.
           ((looking-at md-render--table-pending-line-regexp)
            (setq pending-table-start (point))
            (if (bobp)
                (setq continue nil)
              (forward-line -1)))
           ;; Anything else — extension impossible from here.
           (t (setq continue nil))))
        (or rendered-table-start pending-table-start)))))

(cl-defun md-render--update-watermark (&key source-blocks external-candidates)
  "Stamp the safe-frontier on the first character as a text property.

SOURCE-BLOCKS is the descriptor list from
`md-render--source-blocks' taken earlier this pass.  Its
`:block' markers have tracked every edit since.  The open fence is
the final block whose `:block' end is still `point-max', and is read
from them directly rather than re-scanning.

Safe-frontier = start of the last line in the buffer, clamped
back to the start of:
- the oldest open fenced block (if any), so the closing fence on
  a future chunk gets matched;
- a rendered table that might still extend (see
  `--extending-table-start'), so `--find-tables' under the narrow
  on the next call still sees its stashed
  `md-render-table-source' and folds streamed rows in;
- any position in EXTERNAL-CANDIDATES, the `:watermark' values
  returned by functions in `md-render-render-functions',
  so a renderer can hold the watermark behind its own open
  delimiter (e.g. an unclosed `$$').

Any position before the frontier is fully rendered and stable;
any position from the frontier onward may still resolve into new
markup as more chunks stream in.  Single-line patterns (bold,
italic, strike, header, link, image, inline code, divider) cannot
span a newline, so backing off to start-of-last-line covers their
split-across-chunks case.  Open inline backticks already extend
only to end-of-line, so they're naturally within that zone."
  (when (> (point-max) (point-min))
    (let* ((open-fence-start
            (when-let* ((last-block (car (last source-blocks)))
                        ((= (map-nested-elt last-block '(:block :end)) (point-max))))
              (marker-position (map-nested-elt last-block '(:block :start)))))
           (extending-table-start
            (md-render--extending-table-start))
           (last-line-start
            (save-excursion (goto-char (point-max))
                            (line-beginning-position)))
           (frontier (apply #'min
                            (delq nil (append (list last-line-start
                                                    open-fence-start
                                                    extending-table-start)
                                              external-candidates)))))
      (with-silent-modifications
        (put-text-property (point-min) (1+ (point-min))
                           'md-render-watermark frontier)))))

(defun md-render--make-markers (ranges)
  "Convert each (start . end) in RANGES to (start-marker . end-marker)."
  (mapcar (lambda (range)
            (cons (copy-marker (car range))
                  (copy-marker (cdr range))))
          ranges))

(cl-defun md-render--make-range (&key start end)
  "Return a range alist `((:start . START) (:end . END))'.

For example, (md-render--make-range :start 1 :end 5)
returns `((:start . 1) (:end . 5))'."
  (list (cons :start start)
        (cons :end end)))

(defun md-render-sort-ranges (&rest range-collections)
  "Merge RANGE-COLLECTIONS into a vector sorted by start position.
Each collection is a sequence of (BEG . END) cons cells (a list or
a vector), so already-sorted vectors can be re-merged without
first being flattened.  Endpoints may be integers or markers.
Return a fresh vector of the cons cells sorted ascending by BEG,
suitable for O(log n) lookup with
`md-render-in-avoid-range-p'."
  (sort (apply #'vconcat range-collections)
        (lambda (a b) (< (car a) (car b)))))

(defun md-render-in-avoid-range-p (start end avoid-ranges)
  "Return the range in AVOID-RANGES fully containing START..END, or nil.

AVOID-RANGES is a vector of (BEG . END) cons cells sorted
ascending by BEG, as produced by `md-render-sort-ranges'.
Endpoints may be integers or markers.  Ranges are assumed
non-overlapping, so the first containing range is returned as its
own (BEG . END) cons cell.  Callers can advance point past its END
to avoid re-checking the same range on every match inside it."
  (when avoid-ranges
    (let ((lo 0)
          (hi (length avoid-ranges))
          (candidate nil))
      (while (< lo hi)
        (let* ((mid (/ (+ lo hi) 2))
               (range (seq-elt avoid-ranges mid)))
          (if (<= (car range) start)
              (setq candidate range
                    lo (1+ mid))
            (setq hi mid))))
      (when (and candidate (<= end (cdr candidate)))
        candidate))))

(defun md-render--source-blocks ()
  "Return descriptors for the fenced code blocks in the current buffer.

Scans the fenced blocks once and returns one descriptor per block,
handed to `md-render-render-functions' so a renderer can
claim fenced blocks of its own language (e.g. math, latex) and skip
delimiters that fall inside other code.  Each descriptor is an
alist:

  ((:language . LANGUAGE)   lower-case token after the opening fence
   (:block . RANGE)         a `:start'/`:end' marker range covering
                            the whole block, tracking buffer edits
   (:body . BODY)           body text, or nil while still streaming
   (:complete . COMPLETE))  t once the closing fence has arrived

RANGE is `((:start . MARKER) (:end . MARKER))' (see
`md-render--make-range') spanning the opening fence line
to the start of the line after the closing fence (or `point-max'
while open).  Fence widths pair like CommonMark: an opening fence
of N backticks (N>=3) is closed only by a fence line with M>=N
backticks, so a 4-backtick fence wraps any 3-backtick inner fence
as body rather than terminating on it.

The avoid-range projection in `md-render-replace-markup'
and `md-render--update-watermark' read the `:block'
markers from the same result, so the fence-pairing scan happens
once per pass.

For example, given the buffer:

  ```math
  \\frac{a}{b}
  ```

returns one descriptor with :language \"math\", :body
\"\\frac{a}{b}\", and :complete t."
  (let ((source-blocks '())
        (open-start nil)
        (open-count nil)
        (open-language nil)
        (body-start nil)
        (case-fold-search nil))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward
              (rx bol (zero-or-more whitespace)
                  (group (>= 3 "`"))
                  (zero-or-more blank)
                  (group (zero-or-more (or alphanumeric "-" "+" "#")))
                  (zero-or-more not-newline))
              nil t)
        (let ((count (- (match-end 1) (match-beginning 1))))
          (cond
           ((and open-count (>= count open-count))
            (let ((raw (buffer-substring-no-properties
                        body-start (match-beginning 0))))
              (push (list (cons :language open-language)
                          (cons :block (md-render--make-range
                                        :start (copy-marker open-start)
                                        :end (copy-marker (line-beginning-position 2))))
                          (cons :body (if (string-suffix-p "\n" raw)
                                          (substring raw 0 -1)
                                        raw))
                          (cons :complete t))
                    source-blocks))
            (setq open-start nil open-count nil
                  open-language nil body-start nil))
           ((not open-count)
            (setq open-start (match-beginning 0)
                  open-count count
                  open-language (downcase
                                 (buffer-substring-no-properties
                                  (match-beginning 2) (match-end 2)))
                  body-start (line-beginning-position 2))))))
      (when open-count
        (push (list (cons :language open-language)
                    (cons :block (md-render--make-range
                                  :start (copy-marker open-start)
                                  :end (copy-marker (point-max))))
                    (cons :body nil)
                    (cons :complete nil))
              source-blocks)))
    (nreverse source-blocks)))

(defun md-render--frozen-ranges ()
  "Return ranges of buffer chars tagged `md-render-frozen'.

The tag is written on rendered content whose body text could
otherwise look like markdown (e.g. inline code body or source
block body).  Treating tagged ranges as avoid-ranges keeps
subsequent calls from re-processing them — important for
streaming, where the convert/replace-markup function may be
invoked many times as content grows."
  (let ((ranges '())
        (pos (point-min))
        (limit (point-max)))
    (while (< pos limit)
      (if (get-text-property pos 'md-render-frozen)
          (let ((end (or (next-single-property-change
                          pos 'md-render-frozen nil limit)
                         limit)))
            (push (cons pos end) ranges)
            (setq pos end))
        (setq pos (or (next-single-property-change
                       pos 'md-render-frozen nil limit)
                      limit))))
    (nreverse ranges)))

(cl-defun md-render--inline-code-ranges (&key avoid-ranges)
  "Return list of (start . end) ranges covering inline `X` bodies.

Each range covers the text between backticks (the backticks
themselves are not included).  Backticks inside any of
AVOID-RANGES are ignored.  A line with an odd number of backticks
has its trailing unmatched backtick treated as still-streaming:
the range extends from that backtick to end-of-line.

For example, given the buffer \"a `code` b\" returns a list with
one range covering the body \"code\"."
  (let ((ranges '())
        (case-fold-search nil))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let ((line-end (line-end-position))
              (open nil))
          (while (re-search-forward "`" line-end t)
            (let ((pos (match-beginning 0)))
              (unless (md-render-in-avoid-range-p pos pos avoid-ranges)
                (if open
                    (progn
                      (push (cons (1+ open) pos) ranges)
                      (setq open nil))
                  (setq open pos)))))
          (when open
            (push (cons (1+ open) line-end) ranges)))
        (forward-line 1)))
    (nreverse ranges)))

(defun md-render--deconstruct (text)
  "Return TEXT broken into (SUBSTRING FACES) runs.

Each element is a contiguous run of characters with the same
`face' property value: SUBSTRING is the run text, FACES is a list
of face symbols (a single symbol is wrapped, an unfaced run gets
an empty list).  Adjacent runs merge when their face values are
`equal', not just `eq' — independently built but identical face
lists (e.g. from separate `add-face-text-property' calls) count
as one run.  Runs are returned in left-to-right order and cover
TEXT in full.

For example:

  (md-render--deconstruct
   (md-render-convert \"_my_ **text**\"))
  => ((\"my\" (italic)) (\" \" nil) (\"text\" (bold)))"
  (let ((runs '())
        (pos 0)
        (len (length text)))
    (while (< pos len)
      (let* ((face (get-text-property pos 'face text))
             (next (or (next-single-property-change pos 'face text)
                       len)))
        ;; `next-single-property-change' splits on `eq', but face
        ;; lists built by separate `add-face-text-property' calls
        ;; are `equal' without being `eq' — extend the run while
        ;; the value stays `equal'.
        (while (and (< next len)
                    (equal face (get-text-property next 'face text)))
          (setq next (or (next-single-property-change next 'face text)
                         len)))
        (push (list (substring-no-properties text pos next)
                    (cond ((null face) nil)
                          ((listp face) face)
                          (t (list face))))
              runs)
        (setq pos next)))
    (nreverse runs)))

(provide 'md-render)

;;; md-render.el ends here
