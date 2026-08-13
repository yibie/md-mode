;;; md-render-tests.el --- Test Markdown rendering -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Run via:
;;
;;   emacs -batch -l ert -l test/md-render-tests.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'cl-lib)
(require 'ert)

(load-file (expand-file-name "../md-render.el"
                             (file-name-directory
                              (or load-file-name buffer-file-name))))

(ert-deftest md-render-convert-bold ()
  (should (equal (md-render--deconstruct
                  (md-render-convert "hello **world**"))
                 '(("hello " nil)
                   ("world" (md-render-bold))))))

(ert-deftest md-render-convert-bold-underscore ()
  (should (equal (md-render--deconstruct
                  (md-render-convert "hello __world__"))
                 '(("hello " nil)
                   ("world" (md-render-bold))))))

(ert-deftest md-render-convert-italic ()
  (should (equal (md-render--deconstruct
                  (md-render-convert "hello *world*"))
                 '(("hello " nil)
                   ("world" (md-render-italic))))))

(ert-deftest md-render-convert-italic-underscore ()
  (should (equal (md-render--deconstruct
                  (md-render-convert "hello _world_"))
                 '(("hello " nil)
                   ("world" (md-render-italic))))))

(ert-deftest md-render-convert-italic-underscore-intraword ()
  (should (equal (md-render--deconstruct
                  (md-render-convert "Echo _hello_world"))
                 '(("Echo _hello_world" nil)))))

(ert-deftest md-render-convert-multiple ()
  (should (equal (md-render--deconstruct
                  (md-render-convert "_my_ **text**"))
                 '(("my" (md-render-italic))
                   (" " nil)
                   ("text" (md-render-bold))))))

(ert-deftest md-render-convert-italic-wrapping-bold ()
  (should (equal (md-render--deconstruct
                  (md-render-convert "_**my text**_"))
                 '(("my text" (md-render-bold md-render-italic))))))

(ert-deftest md-render-convert-bold-wrapping-italic ()
  (should (equal (md-render--deconstruct
                  (md-render-convert "**_my text_**"))
                 '(("my text" (md-render-italic md-render-bold))))))

(ert-deftest md-render-convert-bold-with-inner-italic ()
  (should (equal (md-render--deconstruct
                  (md-render-convert "**outer _both_ outer**"))
                 '(("outer " (md-render-bold))
                   ("both" (md-render-bold md-render-italic))
                   (" outer" (md-render-bold))))))

(ert-deftest md-render-convert-italic-with-inner-bold ()
  (should (equal (md-render--deconstruct
                  (md-render-convert "_outer **both** outer_"))
                 '(("outer " (md-render-italic))
                   ("both" (md-render-bold md-render-italic))
                   (" outer" (md-render-italic))))))

(ert-deftest md-render-convert-no-markup ()
  (should (equal (md-render--deconstruct
                  (md-render-convert "no markup here"))
                 '(("no markup here" nil)))))

(ert-deftest md-render-convert-empty ()
  (should (equal (md-render--deconstruct
                  (md-render-convert ""))
                 '())))

(ert-deftest md-render-convert-inline-code-protects-markup ()
  (should (equal (md-render--deconstruct
                  (md-render-convert
                   "before **b** and `**not bold**` after"))
                 '(("before " nil)
                   ("b" (md-render-bold))
                   (" and " nil)
                   ("**not bold**" (md-render-inline-code))
                   (" after" nil)))))

(ert-deftest md-render-convert-inline-code ()
  (should (equal (md-render--deconstruct
                  (md-render-convert "a `code` b"))
                 '(("a " nil)
                   ("code" (md-render-inline-code))
                   (" b" nil)))))

(ert-deftest md-render-convert-strikethrough ()
  (should (equal (md-render--deconstruct
                  (md-render-convert "a ~~b~~ c"))
                 '(("a " nil)
                   ("b" (md-render-strikethrough))
                   (" c" nil)))))

(ert-deftest md-render-convert-strikethrough-wrapping-bold ()
  (should (equal (md-render--deconstruct
                  (md-render-convert "~~**bold-strike**~~"))
                 '(("bold-strike" (md-render-bold md-render-strikethrough))))))

(ert-deftest md-render-convert-header-level-1 ()
  ;; Header rendering requires a trailing newline to complete; an
  ;; eob-only header is treated as still streaming and left raw.
  (should (equal (md-render--deconstruct
                  (md-render-convert "# Title\n"))
                 '(("Title" (md-render-header-1))
                   ("\n" nil)))))

(ert-deftest md-render-convert-header-level-3 ()
  (should (equal (md-render--deconstruct
                  (md-render-convert "### Title\n"))
                 '(("Title" (md-render-header-3))
                   ("\n" nil)))))

(ert-deftest md-render-convert-header-with-bold ()
  (should (equal (md-render--deconstruct
                  (md-render-convert "## **Big** title\n"))
                 '(("Big" (md-render-header-2 md-render-bold))
                   (" title" (md-render-header-2))
                   ("\n" nil)))))

(ert-deftest md-render-convert-fenced-block-protects-markup ()
  (should (equal (md-render--deconstruct
                  (md-render-convert
                   "before **b**
```
**not bold**
_not italic_
```
after **b2**"))
                 '(("before " nil)
                   ("b" (md-render-bold))
                   ("
" nil)
                   ("
" (md-render-source-block))
                   ("snippet ⧉" (md-render-source-block-language))
                   ("

**not bold**
_not italic_

" (md-render-source-block))
                   ("after " nil)
                   ("b2" (md-render-bold))))))

(ert-deftest md-render-convert-open-fence-protects-rest ()
  (should (equal (md-render--deconstruct
                  (md-render-convert
                   "before **b**
```
streaming **not bold**"))
                 '(("before " nil)
                   ("b" (md-render-bold))
                   ("
```
streaming **not bold**" nil)))))

(ert-deftest md-render-convert-open-inline-code-protects-rest-of-line ()
  (should (equal (md-render--deconstruct
                  (md-render-convert
                   "before **b** and `streaming *not italic*"))
                 '(("before " nil)
                   ("b" (md-render-bold))
                   (" and `streaming *not italic*" nil)))))

(ert-deftest md-render-convert-incomplete-bold-untouched ()
  (should (equal (md-render--deconstruct
                  (md-render-convert
                   "complete **b** and incomplete **par"))
                 '(("complete " nil)
                   ("b" (md-render-bold))
                   (" and incomplete **par" nil)))))

(ert-deftest md-render-convert-link ()
  (should (equal (md-render--deconstruct
                  (md-render-convert "see [docs](https://example.com) please"))
                 '(("see " nil)
                   ("docs" (md-render-link))
                   (" please" nil)))))

(ert-deftest md-render-convert-link-with-bold-inside-untouched ()
  ;; Bold inside link title is left literal (mirrors markdown-overlays:
  ;; bold regex requires whitespace/BOL before `**', and `[' isn't either).
  (should (equal (md-render--deconstruct
                  (md-render-convert "[**bold**](url)"))
                 '(("**bold**" (md-render-link))))))

(ert-deftest md-render-convert-link-after-image-not-confused ()
  ;; `[X](Y)' inside `![X](Y)' must not be treated as a link.
  (should (equal (md-render--deconstruct
                  (md-render-convert "![alt](missing.png)"))
                 '(("![alt](missing.png)" nil)))))

(ert-deftest md-render-convert-image-unresolvable-untouched ()
  (should (equal (md-render--deconstruct
                  (md-render-convert "see ![alt](/no/such/file.png) end"))
                 '(("see ![alt](/no/such/file.png) end" nil)))))

(ert-deftest md-render-convert-remote-image-falls-back-to-link ()
  ;; A remote image that can't be shown inline (no cache configured, and a
  ;; non-graphical display in batch) becomes a clickable link, not raw markup.
  (should (equal (md-render--deconstruct
                  (md-render-convert
                   "see ![docs](https://example.com/a.png) end"))
                 '(("see " nil)
                   ("docs" (md-render-link))
                   (" end" nil)))))

(ert-deftest md-render-convert-remote-image-empty-alt-uses-url ()
  ;; With no alt text, the link label is the URL itself.
  (should (equal (md-render--deconstruct
                  (md-render-convert "![](https://example.com/a.png)"))
                 '(("https://example.com/a.png" (md-render-link))))))

(ert-deftest md-render-image-render-preserves-surrounding-properties ()
  ;; Regression: an inline `![alt](file)' image renders by replacing the
  ;; markup with a placeholder carrying the `display' image.  That placeholder
  ;; must keep the properties of the surrounding text, otherwise it punches a
  ;; hole in an otherwise-contiguous property run.  The shell tags a whole
  ;; streamed message body with `agent-shell-ui-section' body; a hole there
  ;; makes the fragment layer mis-locate the body on the next chunk and hide
  ;; every line after the image.  (`[title](url)' links already do this by
  ;; capturing the title with its properties; images used to drop them.)
  (let ((image-file (make-temp-file "agent-shell-test" nil ".svg")))
    (unwind-protect
        (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _d) t))
                  ((symbol-function 'image-supported-file-p) (lambda (_f) t))
                  ((symbol-function 'create-image)
                   (lambda (&rest _) '(image :type svg :fake t)))
                  ((symbol-function 'image-flush) (lambda (&rest _) nil)))
    (with-temp-buffer
      (insert (format "before\n\n![svg graphics](%s)\n\nafter\n" image-file))
      (put-text-property (point-min) (point-max) 'agent-shell-ui-section 'body)
      (md-render-replace-markup :render-images t)
      ;; The markup is replaced by the alt-text placeholder shown as an image.
      (should (equal (substring-no-properties (buffer-string))
                     "before\n\nsvg graphics\n\nafter\n"))
      (goto-char (point-min))
      (search-forward "svg graphics")
      (let ((placeholder-start (match-beginning 0)))
        ;; The placeholder carries the `display' image...
        (should (get-text-property placeholder-start 'display))
        ;; ...and still carries the surrounding body-section tag.
        (should (eq (get-text-property placeholder-start 'agent-shell-ui-section)
                    'body)))
      ;; The whole body stays one contiguous `agent-shell-ui-section' run --
      ;; the image placeholder leaves no gap for the fragment layer to trip on.
      (should-not (text-property-any (point-min) (point-max)
                                     'agent-shell-ui-section nil))))
      (delete-file image-file))))

(ert-deftest md-render-image-reconstructs-to-source ()
  ;; A rendered `![alt](url)' image shows only the alt placeholder, but
  ;; `agent-shell-copy-as-markdown' must round-trip it back to the original
  ;; markdown.  The renderer stashes the source on `md-render-source'
  ;; (like links do) so `md-render-reconstruct' recovers it.
  (let ((image-file (make-temp-file "agent-shell-test" nil ".svg")))
    (unwind-protect
        (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _d) t))
                  ((symbol-function 'image-supported-file-p) (lambda (_f) t))
                  ((symbol-function 'create-image)
                   (lambda (&rest _) '(image :type svg :fake t)))
                  ((symbol-function 'image-flush) (lambda (&rest _) nil)))
          (with-temp-buffer
            (insert (format "see ![svg graphics](%s) end" image-file))
            (md-render-replace-markup :render-images t)
            ;; Visible text is the bare placeholder...
            (should (equal (substring-no-properties (buffer-string))
                           "see svg graphics end"))
            ;; ...but reconstruction restores the full markup.
            (should (equal (md-render-reconstruct (point-min) (point-max))
                           (format "see ![svg graphics](%s) end" image-file)))))
      (delete-file image-file))))

(ert-deftest md-render-remote-image-fallback-reconstructs-to-source ()
  ;; A remote image that falls back to a link (non-graphical display in batch)
  ;; also round-trips to its original `![alt](url)' markup, not the link label.
  (with-temp-buffer
    (insert "x ![](https://example.com/a.png) y")
    (md-render-replace-markup :render-images t)
    (should (equal (substring-no-properties (buffer-string))
                   "x https://example.com/a.png y"))
    (should (equal (md-render-reconstruct (point-min) (point-max))
                   "x ![](https://example.com/a.png) y"))))

(ert-deftest md-render-convert-link-angle-brackets ()
  ;; CommonMark angle-bracketed destination `[t](<url>)' renders like the
  ;; bare form, with both the brackets and the angle brackets stripped.
  (should (equal (md-render--deconstruct
                  (md-render-convert "see [docs](<https://example.com>) please"))
                 '(("see " nil)
                   ("docs" (md-render-link))
                   (" please" nil)))))

(ert-deftest md-render-convert-image-angle-brackets-remote-falls-back ()
  ;; A remote image whose destination is angle-bracketed still resolves to
  ;; the http url (brackets stripped), so the non-inline fallback is a link.
  (should (equal (md-render--deconstruct
                  (md-render-convert "![docs](<https://example.com/a.png>)"))
                 '(("docs" (md-render-link))))))

(ert-deftest md-render--link-markup-url-angle-allows-spaces ()
  ;; The whole point of the angle-bracket form: the url may contain spaces
  ;; (and parentheses), which the bare `(...)' form cannot represent.
  (with-temp-buffer
    (insert "[x](</path/with spaces (1).png>)")
    (goto-char (point-min))
    (should (re-search-forward (md-render--link-markup-regexp) nil t))
    (should (equal (md-render--link-markup-url)
                   "/path/with spaces (1).png"))))

(ert-deftest md-render--link-markup-url-bare-form ()
  ;; The bare destination is still captured (from group 3) unchanged.
  (with-temp-buffer
    (insert "[x](https://example.com)")
    (goto-char (point-min))
    (should (re-search-forward (md-render--link-markup-regexp) nil t))
    (should (equal (md-render--link-markup-url) "https://example.com"))))

(ert-deftest md-render--link-markup-regexp-image-empty-alt ()
  ;; Image alt may be empty; the angle-bracketed url is still captured.
  (with-temp-buffer
    (insert "![](<a b.png>)")
    (goto-char (point-min))
    (should (re-search-forward (md-render--link-markup-regexp :as-image? t) nil t))
    (should (equal (match-string 1) ""))
    (should (equal (md-render--link-markup-url) "a b.png"))))

(ert-deftest md-render-convert-link-in-fenced-block-untouched ()
  ;; The `[b](v)' inside fences stays literal — it isn't re-processed
  ;; as a link.  Body chars carry the `md-render-frozen'
  ;; tag (which `--deconstruct' doesn't surface).
  (should (equal (md-render--deconstruct
                  (md-render-convert
                   "before [a](u)
```
[b](v)
```
after [c](w)"))
                 '(("before " nil)
                   ("a" (md-render-link))
                   ("
" nil)
                   ("
" (md-render-source-block))
                   ("snippet ⧉" (md-render-source-block-language))
                   ("

[b](v)

" (md-render-source-block))
                   ("after " nil)
                   ("c" (md-render-link))))))

(ert-deftest md-render-convert-source-block-no-language ()
  ;; Plain fenced block (no language): fences deleted, a "snippet ⧉"
  ;; header is inserted directly above the body as real buffer text
  ;; (no display property), bracketed by tinted vpad newlines so the
  ;; panel reads as a contiguous block.  Body chars carry the
  ;; `md-render-frozen' tag (not surfaced by
  ;; `--deconstruct').
  (should (equal (md-render--deconstruct
                  (md-render-convert
                   "```
body
```"))
                 '(("
" (md-render-source-block))
                   ("snippet ⧉" (md-render-source-block-language))
                   ("

body

" (md-render-source-block))))))

(ert-deftest md-render-convert-source-block-language-label ()
  ;; Every fence renders with an actionable label inserted as real
  ;; buffer text directly above the body — "LANG ⧉" when a language
  ;; is declared, "snippet ⧉" otherwise.  No display property, no
  ;; overlays.  The label sits between tinted vpad newlines that
  ;; make the surrounding panel read as a contiguous block.  RET or
  ;; mouse-1 anywhere on the label kills the body to the kill ring.
  (let* ((with-lang (md-render-convert "```python
print(\"hi\")
```
"))
         (no-lang (md-render-convert "```
body
```
")))
    (should (string-prefix-p "\npython ⧉\n\nprint("
                             (substring-no-properties with-lang)))
    (should (string-prefix-p "\nsnippet ⧉\n\nbody"
                             (substring-no-properties no-lang)))
    ;; Label face + actionable props on both the first name char and
    ;; the ⧉ glyph.  The leading char is the tinted vpad `\\n', so the
    ;; label starts at index 1; "python " is 7 chars, so the ⧉ glyph
    ;; sits at index 8.
    (dolist (i '(1 8))
      (should (eq (get-text-property i 'face with-lang)
                  'md-render-source-block-language))
      (should (eq (get-text-property i 'mouse-face with-lang)
                  'highlight))
      (should (keymapp (get-text-property i 'keymap with-lang))))))

(ert-deftest md-render-convert-source-block-nested-fences ()
  ;; A 4-backtick outer fence wraps inner 3-backtick fences as
  ;; literal body — the inner ```python ... ``` is *not* re-rendered
  ;; as a code block.  Mirrors CommonMark's variable-width fence
  ;; rule: a closer must match the opener's backtick count, and a
  ;; shorter run inside is part of the body.  Face buckets vary by
  ;; env (markdown-mode's font-lock highlights ``` markup when the
  ;; mode is loadable; in bare batch it's not), so the contract is
  ;; asserted on the rendered text, not on the face cascade.
  (let ((rendered (substring-no-properties
                   (md-render-convert
                    "````markdown
```python
print(\"hi\")
```
````"))))
    (should (equal rendered "
markdown ⧉

```python
print(\"hi\")
```

"))))

(ert-deftest md-render-convert-source-block-with-language ()
  ;; `emacs-lisp' source block: fences deleted, an "emacs-lisp ⧉"
  ;; header is inserted as buffer text bracketed by tinted vpad
  ;; newlines, then the body chars get the language's `font-lock'
  ;; faces layered over the `md-render-source-block' bg.
  ;; In batch the keyword `if' is faced; the rest of the body stays
  ;; with just the panel bg.
  (should (equal (md-render--deconstruct
                  (md-render-convert
                   "```emacs-lisp
(if t nil)
```"))
                 '(("
" (md-render-source-block))
                   ("emacs-lisp ⧉" (md-render-source-block-language))
                   ("

(" (md-render-source-block))
                   ("if" (font-lock-keyword-face md-render-source-block))
                   (" t nil)

" (md-render-source-block))))))

(ert-deftest md-render-convert-source-block-body-tagged ()
  ;; Body chars carry `md-render-frozen t' so subsequent calls
  ;; treat them as an avoid-range (streaming-safe).  Rendered output
  ;; is `\\n<label>\\n\\n<body>\\n\\n' — the label and body chars are
  ;; tagged; the bracketing vpad `\\n's are not (they're styling, not
  ;; protected content).
  (let ((s (md-render-convert "```
**not bold**
```")))
    ;; Leading vpad `\\n' is not frozen.
    (should (null (get-text-property 0 'md-render-frozen s)))
    ;; Label start char "s" of "snippet" is frozen.
    (should (eq t (get-text-property 1 'md-render-frozen s)))
    ;; A body char ("n" in "**not bold**") is frozen.
    (should (eq t (get-text-property 14 'md-render-frozen s)))
    ;; Trailing vpad `\\n' is not frozen.
    (should (null (get-text-property (1- (length s)) 'md-render-frozen s)))))

(ert-deftest md-render-convert-inline-code-body-tagged ()
  ;; Inline code body chars are also `md-render-frozen t'-tagged
  ;; so a stray "**X**" inside backticks stays literal on re-runs.
  (let ((s (md-render-convert "a `**not bold**` b")))
    (should (eq t (get-text-property 2 'md-render-frozen s)))
    (should (eq t (get-text-property 13 'md-render-frozen s)))
    (should (null (get-text-property 0 'md-render-frozen s)))))

(ert-deftest md-render-convert-rendered-text-marked-fontified ()
  ;; Rendered chars carry `fontified t' so jit-lock never re-runs over
  ;; them.  We style via `face'/`font-lock-face' text properties, not
  ;; font-lock keywords, so a jit-lock pass applies nothing — but its
  ;; firing mid-drag disturbs mouse drag-tracking and collapses the
  ;; selection to empty, silently breaking mouse copy of rendered text.
  ;; Marking `fontified t' up front prevents that pass entirely.
  (let ((s (md-render-convert "hello **world**")))
    (should (eq t (get-text-property 0 'fontified s)))
    (should (eq t (get-text-property (1- (length s)) 'fontified s))))
  ;; Also holds for fenced source blocks (the reported failure case).
  (let ((s (md-render-convert "```\ncode\n```")))
    (should (eq t (get-text-property 1 'fontified s)))))

(ert-deftest md-render-source-block-streamed-in-chunks ()
  ;; Real-world LLM streaming: a fenced code block arrives in small
  ;; chunks that split the opening fence, the language line, body
  ;; chars, and the closing fence.  After every chunk the renderer
  ;; is called.  Once the closing fence lands, the final buffer
  ;; should show the inserted "python ⧉" label above the body, with
  ;; no raw fence markers remaining.
  (with-temp-buffer
    (dolist (chunk '("``" "`p" "yt" "hon\n"
                     "pri" "nt(" "\"hi\")\n"
                     "ra" "ise " "Sys" "temExit\n"
                     "``" "`\n"))
      (goto-char (point-max))
      (insert chunk)
      (md-render-replace-markup))
    (should (equal (substring-no-properties (buffer-string))
                   "
python ⧉

print(\"hi\")
raise SystemExit

"))))

(ert-deftest md-render-source-block-body-protected-across-calls ()
  ;; Streaming: render a block, then append more markdown and re-render.
  ;; The previously-rendered body (`md-render-frozen t') must stay
  ;; literal — its `**not bold**' must not turn into bold X on the
  ;; second pass, while newly-appended `**real bold**' does.
  (with-temp-buffer
    (insert "```
**not bold**
```")
    (md-render-replace-markup)
    (goto-char (point-max))
    (insert "
**real bold**")
    (md-render-replace-markup)
    (should (equal (md-render--deconstruct (buffer-string))
                   '(("
" (md-render-source-block))
                     ("snippet ⧉" (md-render-source-block-language))
                     ("

**not bold**

" (md-render-source-block))
                     ("
" nil)
                     ("real bold" (md-render-bold)))))))

(ert-deftest md-render-inline-code-body-protected-across-calls ()
  ;; Streaming counterpart for inline code: after the backticks
  ;; are gone, body chars must not be re-bolded on a second pass.
  (with-temp-buffer
    (insert "a `**not bold**` b")
    (md-render-replace-markup)
    (goto-char (point-max))
    (insert " **real bold**")
    (md-render-replace-markup)
    (should (equal (md-render--deconstruct (buffer-string))
                   '(("a " nil)
                     ("**not bold**" (md-render-inline-code))
                     (" b " nil)
                     ("real bold" (md-render-bold)))))))

(ert-deftest md-render-convert-divider-dashes ()
  ;; A `---' line gets a `display' property and `md-render-frozen'
  ;; tag.  The chars themselves stay in the buffer beneath the display.
  (let ((s (md-render-convert "above
---
below")))
    (should (eq t (get-text-property 6 'md-render-frozen s)))
    (should (get-text-property 6 'display s))))

(ert-deftest md-render-convert-divider-stars ()
  (let ((s (md-render-convert "above
***
below")))
    (should (eq t (get-text-property 6 'md-render-frozen s)))
    (should (get-text-property 6 'display s))))

(ert-deftest md-render-convert-divider-underscores ()
  (let ((s (md-render-convert "above
___
below")))
    (should (eq t (get-text-property 6 'md-render-frozen s)))
    (should (get-text-property 6 'display s))))

(ert-deftest md-render-convert-divider-not-matched-with-text ()
  ;; `*** hello ***' is not a divider — has other content on the line.
  (should (equal (md-render--deconstruct
                  (md-render-convert "*** hello ***"))
                 '(("*** hello ***" nil)))))

(ert-deftest md-render-convert-image-file-path-unresolvable-untouched ()
  ;; Path doesn't exist (and batch mode has no graphics anyway), so
  ;; the line is left untouched.
  (should (equal (md-render--deconstruct
                  (md-render-convert
                   "before
/no/such/img.png
after"))
                 '(("before
/no/such/img.png
after" nil)))))

(ert-deftest md-render-convert-table-basic ()
  ;; A complete table is replaced by its prettified rendering and the
  ;; inserted chars carry `md-render-frozen' so subsequent calls
  ;; skip them.  (Rendering shape is covered more thoroughly by the
  ;; `-output-*' tests.)
  (let ((s (md-render-convert "| A | B |
|---|---|
| 1 | 2 |")))
    (should (equal (substring-no-properties s)
                   "│ A │ B │
├───┼───┤
│ 1 │ 2 │"))
    (should (eq t (get-text-property 0 'md-render-frozen s)))))

(ert-deftest md-render-convert-table-without-separator-renders ()
  ;; A separator row (`|---|---|') is optional.  Two or more `|...|'
  ;; rows are enough to render — without a separator, all rows are
  ;; treated as data (no header styling, no separator border in the
  ;; output).
  (should (equal (substring-no-properties
                  (md-render-convert "| a | b |
| hello | world |"))
                 "│ a     │ b     │
│ hello │ world │")))

(ert-deftest md-render-convert-table-cell-uses-bold ()
  ;; Bold inside a cell is processed by the main pass; the rendered
  ;; table preserves the bold face on \"Alice\".
  (let* ((s (md-render-convert "| Name | Role |
|------|------|
| **Alice** | Engineer |"))
         (alice-pos (string-match "Alice" s)))
    (should alice-pos)
    ;; Rendered tables are pinned to `fixed-pitch' (so
    ;; `variable-pitch-mode' can't skew alignment), layered under the
    ;; cell's own faces.
    (should (memq 'md-render-bold (get-text-property alice-pos 'face s)))
    (should (memq 'fixed-pitch (get-text-property alice-pos 'face s)))))

(ert-deftest md-render-table-pins-fixed-pitch-everywhere ()
  ;; Borders, padding, and content all carry `fixed-pitch' so a
  ;; default-face remap (`variable-pitch-mode') can't break alignment.
  (let* ((s (md-render-convert "| A | B |
|---|---|
| 1 | 2 |"))
         (pipe-pos (string-match "│" s))
         (pad-pos (string-match " " s)))
    (should pipe-pos)
    (should pad-pos)
    (should (memq 'fixed-pitch (get-text-property pipe-pos 'face s)))
    (should (memq 'fixed-pitch (get-text-property pad-pos 'face s)))))

(ert-deftest md-render-convert-table-skips-frozen-cell-pipe ()
  ;; `| `a|b` | c |' — inline-code body contains a `|', which our
  ;; inline-code styling tags `md-render-frozen'.  The cell parser
  ;; should treat that pipe as part of the cell rather than a
  ;; separator, yielding 2 cells (not 3).
  (let* ((s (md-render-convert "| `a|b` | c |
|---|---|
| x | y |"))
         (header-line (car (split-string s "
")))
         ;; In a 2-column rendering, count the leading-pipe + col-pipe
         ;; + trailing-pipe = 3 borders. (For 3 cols there would be 4.)
         (pipe-count (length (seq-filter (lambda (c) (eq c ?│))
                                         header-line))))
    (should (eq 3 pipe-count))))

(ert-deftest md-render-convert-table-output-plain ()
  ;; End-to-end multi-line input → multi-line output comparison.
  ;; Checks the rendered text only (no text-property assertions).
  (should (equal (substring-no-properties
                  (md-render-convert
                   "| A | B |
|---|---|
| 1 | 2 |"))
                 "│ A │ B │
├───┼───┤
│ 1 │ 2 │")))

(ert-deftest md-render-convert-table-output-with-bold ()
  ;; Bold markup inside cells is stripped by the main pipeline before
  ;; the table is rendered, so the rendered string contains \"Alice\"
  ;; (the `**...**' is gone) and columns are sized for the stripped
  ;; content.  Compares text only.
  (should (equal (substring-no-properties
                  (md-render-convert
                   "| Name | Role |
|------|------|
| **Alice** | Engineer |
| Bob | Manager |"))
                 "│ Name  │ Role     │
├───────┼──────────┤
│ Alice │ Engineer │
│ Bob   │ Manager  │")))

(ert-deftest md-render-table-measures-row-faces-before-padding ()
  (with-temp-buffer
    (insert "| 类型 | 值 |\n|---|---|\n| Secret | token |\n| Variable | branch |")
    (let* ((rows (md-render--collect-table-rows))
           (processed
            (map-elt
             (md-render--preprocess-table
              :rows rows :separator-row-num 1)
             :processed-rows)))
      (should
       (eq (get-text-property 0 'face (cadr (nth 0 processed)))
           'md-render-table-header))
      (should
       (eq (get-text-property 0 'face (cadr (nth 3 processed)))
           'md-render-table-zebra)))))

(ert-deftest md-render-convert-table-output-wraps-one-cell ()
  ;; When the table's natural width exceeds the target, the widest
  ;; column shrinks and its content wraps at word boundaries.
  ;; Mocks `md-render--display-width' to 30 so the result is
  ;; deterministic.  Other columns stay at natural width.
  (let ((md-render-table-max-width-fraction 1.0))
    (cl-letf (((symbol-function 'md-render--display-width)
               (lambda () 30)))
      (should (equal (substring-no-properties
                      (md-render-convert
                       "| A | B |
|---|---|
| short | this is a much longer description |"))
                     "│ A     │ B                  │
├───────┼────────────────────┤
│ short │ this is a much     │
│       │ longer description │")))))

(ert-deftest md-render-convert-table-output-wraps-both-cells ()
  ;; Both columns shrink and wrap when both are too wide.  Column
  ;; widths are allocated proportionally to their natural width.
  (let ((md-render-table-max-width-fraction 1.0))
    (cl-letf (((symbol-function 'md-render--display-width)
               (lambda () 30)))
      (should (equal (substring-no-properties
                      (md-render-convert
                       "| Header A | Header B |
|---|---|
| first quite long content | second cell also long enough |"))
                     "│ Header A    │ Header B    │
├─────────────┼─────────────┤
│ first       │ second      │
│ quite long  │ cell also   │
│ content     │ long enough │")))))

(ert-deftest md-render-convert-table-output-wraps-cjk-cell-without-spaces ()
  ;; A whitespace-free CJK cell must still wrap: CJK characters are
  ;; individually breakable, while ASCII words (here \"Cage\", \"4\",
  ;; \"33\", \"20\") stay intact.
  (let ((md-render-table-max-width-fraction 1.0))
    (cl-letf (((symbol-function 'md-render--display-width)
               (lambda () 36)))
      (should (equal (substring-no-properties
                      (md-render-convert
                       "| 作曲家 | 主な特徴 |
|---|---|
| Cage | 「4分33秒」に代表される偶然性の音楽の導入で20世紀音楽の概念を根本から問い直した |"))
                     "│ 作曲 │ 主な特徴                 │
│ 家   │                          │
├──────┼──────────────────────────┤
│ Cage │ 「4分33秒」に代表される  │
│      │ 偶然性の音楽の導入で20世 │
│      │ 紀音楽の概念を根本から問 │
│      │ い直した                 │")))))

(ert-deftest md-render-table-longest-word-breaks-at-cjk-chars ()
  ;; Words are unbreakable; line-breakable (category `|') characters
  ;; contribute their own char-width.  Emoji sequences are not
  ;; breakable, so a modifier stays attached to its base.
  (should (= 0 (md-render--table-longest-word :str nil)))
  (should (= 0 (md-render--table-longest-word :str "")))
  (should (= 3 (md-render--table-longest-word :str "foo ba")))
  (should (= 2 (md-render--table-longest-word :str "現代音楽")))
  (should (= 3 (md-render--table-longest-word :str "日本のfoo語")))
  (should (= 4 (md-render--table-longest-word :str "👍🏽"))))

(ert-deftest md-render-table-wrap-text-breaks-after-cjk-not-inside-ascii ()
  ;; Wrapping breaks after CJK characters rather than inside an
  ;; embedded ASCII word.
  (should (equal (md-render--table-wrap-text "日本のfoo語" 3)
                 '("日" "本" "の" "foo" "語"))))

(ert-deftest md-render-mirrors-face-to-font-lock-face ()
  ;; Faces are mirrored to `font-lock-face' so our styling survives
  ;; `font-lock-mode' re-fontification in comint / shell-maker buffers.
  (let* ((s (md-render-convert "hello **world**"))
         (world-pos (string-match "world" s)))
    (should (eq 'md-render-bold (get-text-property world-pos 'face s)))
    (should (eq 'md-render-bold
                (get-text-property world-pos 'font-lock-face s)))
    ;; Composed faces (`(bold italic)') mirror as the same list.
    (let* ((composed (md-render-convert "_**X**_"))
           (x-pos (string-match "X" composed)))
      (should (equal '(md-render-bold md-render-italic)
                     (get-text-property x-pos 'face composed)))
      (should (equal '(md-render-bold md-render-italic)
                     (get-text-property x-pos 'font-lock-face composed))))))

(ert-deftest md-render-table-preserves-caller-text-properties ()
  ;; Caller-set text properties (here: a custom symbol) at the
  ;; table's start position must survive the render's delete+insert,
  ;; so callers can keep using text-property scans to bracket regions
  ;; — e.g., agent-shell uses `agent-shell-ui-state' to find blocks.
  (with-temp-buffer
    (insert "| A | B |
|---|---|
| 1 | 2 |")
    (put-text-property (point-min) (point-max) 'agent-shell-ui-state 'my-block)
    (md-render-replace-markup)
    ;; Every char in the rendered output should carry the tag.
    (should (eq 'my-block
                (get-text-property (point-min) 'agent-shell-ui-state)))
    (should (eq 'my-block
                (get-text-property (1- (point-max)) 'agent-shell-ui-state)))))

(ert-deftest md-render-table-drops-source-display-properties ()
  ;; Editable modes may prettify the opening pipe with a `display'
  ;; property.  Carrying that one-character presentation property
  ;; across the whole rendered table corrupts its visual layout.
  (with-temp-buffer
    (insert "| A | B |
|---|---|
| 1 | 2 |")
    (put-text-property (point-min) (1+ (point-min)) 'display "│")
    (md-render-replace-markup)
    (should-not
     (text-property-not-all (point-min) (point-max) 'display nil))))

(ert-deftest md-render-table-extends-on-streamed-rows ()
  ;; First render a 3-row table.  Then append a 4th data row to the
  ;; buffer (simulating an LLM streaming more content) and re-render.
  ;; The renderer should see the stashed source on the already-rendered
  ;; region, combine it with the new ASCII row, and emit a single
  ;; 4-row table with recomputed column widths.  Trailing newlines on
  ;; each row signal completeness — the renderer defers rendering of a
  ;; trailing row that isn't yet `\\n'-terminated, since a streaming
  ;; chunk may have ended mid-row.
  (with-temp-buffer
    (insert "| Col | Width |
|---|---|
| 1 | 2 |
")
    (md-render-replace-markup)
    (goto-char (point-max))
    (insert "| three | four |
")
    (md-render-replace-markup)
    (should (equal (substring-no-properties (buffer-string))
                   "│ Col   │ Width │
├───────┼───────┤
│ 1     │ 2     │
│ three │ four  │
"))))

(ert-deftest md-render-table-folds-mid-stream-continuation ()
  ;; A streamed chunk may end mid-row (chunk boundary splits a
  ;; row's cells).  Each render commits the latest chars to a
  ;; prettified table.  The next chunk's continuation chars (no
  ;; leading newline — they extend the current last row) get folded
  ;; back into the rendered table's last source row, so the final
  ;; render shows all rows with consistent column widths and no
  ;; orphan raw markdown stuck on a `│' line.
  (with-temp-buffer
    ;; Chunk 1: 3-row table.  The last row is intentionally short
    ;; (4 cells; header has 5) with no trailing newline — the chunk
    ;; boundary fell mid-row.
    (insert "| # | Name | Role | Country | Status |
|---|---|---|---|---|
| 1 | Alice | Engineer | USA |")
    (md-render-replace-markup)
    ;; Chunk 2: the continuation of row 1 (the missing `Status'
    ;; cell — note it starts with a space, not a newline) plus a
    ;; complete row 2.
    (goto-char (point-max))
    (insert " Active |
| 2 | Bob | Designer | UK | Historical |
")
    (md-render-replace-markup)
    ;; All rows render as a single 4-row table with the continuation
    ;; folded into row 1.  Column widths are consistent.
    (should (equal (substring-no-properties (buffer-string))
                   "│ # │ Name  │ Role     │ Country │ Status     │
├───┼───────┼──────────┼─────────┼────────────┤
│ 1 │ Alice │ Engineer │ USA     │ Active     │
│ 2 │ Bob   │ Designer │ UK      │ Historical │
"))))

(ert-deftest md-render-table-inside-open-fence-stays-raw ()
  ;; A table inside a fenced block whose closing fence hasn't
  ;; streamed in yet must NOT get table-rendered.  Otherwise the
  ;; rendered table would survive when the closing fence finally
  ;; arrives and the source-block pass strips the fences — the
  ;; user would see a styled table where they asked for verbatim
  ;; code.
  (with-temp-buffer
    (insert "```
| A | B |
|---|---|
| 1 | 2 |
")
    (md-render-replace-markup)
    ;; The pipes stay as ASCII `|', not unicode `│' — the table
    ;; renderer respected the open-fence range.
    (should (string-match-p "| A | B |" (buffer-string)))
    (should-not (string-match-p "│" (buffer-string)))))

(ert-deftest md-render-table-renders-final-row-without-trailing-newline ()
  ;; A complete table whose last row isn't terminated by `\n' (e.g.
  ;; the final chunk of a streaming response) must still render —
  ;; callers like agent-shell narrow to the body section, which
  ;; excludes the trailing `\n', so even when streaming has stopped
  ;; the row would appear unterminated within the narrow.
  (with-temp-buffer
    (insert "| Name | Age |
|---|---|
| Alice | 28 |
| Bob | 35 |")
    (md-render-replace-markup)
    (should (equal (substring-no-properties (buffer-string))
                   "│ Name  │ Age │
├───────┼─────┤
│ Alice │ 28  │
│ Bob   │ 35  │"))))

(ert-deftest md-render-table-renders-with-field-boundaries ()
  ;; Callers (e.g. agent-shell) tag body chars with the `field' text
  ;; property.  Streamed chunks may not propagate `field' onto inter-
  ;; row newlines uniformly, creating field boundaries inside the table
  ;; source.  `forward-line' / `line-end-position' are field-aware by
  ;; default, so without protection the parsers would stop at those
  ;; boundaries and render some rows as empty `││'.
  (with-temp-buffer
    (insert "| Name | Age |
|---|---|
| Alice | 28 |
| Bob | 35 |
| Carol | 42 |
")
    ;; Strip `field' from the inter-row newlines while leaving it on
    ;; the row content — mimics the agent-shell streaming-chunk shape
    ;; that triggered the original bug.
    (put-text-property (point-min) (point-max) 'field 'output)
    (save-excursion
      (goto-char (point-min))
      (while (search-forward "\n" nil t)
        (remove-text-properties (1- (point)) (point) '(field nil))))
    (md-render-replace-markup)
    (should (equal (substring-no-properties (buffer-string))
                   "│ Name  │ Age │
├───────┼─────┤
│ Alice │ 28  │
│ Bob   │ 35  │
│ Carol │ 42  │
"))))

(ert-deftest md-render-pad-table-string-accepts-force-pixel ()
  ;; `--pad-table-string' grew a `:force-pixel' keyword so the per-line
  ;; padding can be pinned to the pixel path for every wrapped line of
  ;; a non-ASCII cell.  This pins the keyword in the signature — if it
  ;; gets dropped, the row-renderer (which always passes it) would
  ;; error with "Keyword argument :force-pixel not one of ...".
  ;; In batch (no graphic display) the pixel path is unreachable, so
  ;; both `:force-pixel t' and `:force-pixel nil' fall back to the
  ;; ASCII path and produce the same string.  The test just guards the
  ;; signature and the ASCII-path result.
  (should (equal "hi  "
                 (md-render--pad-table-string
                  :str "hi" :width 4 :force-pixel nil)))
  (should (equal "hi  "
                 (md-render--pad-table-string
                  :str "hi" :width 4 :force-pixel t))))

(ert-deftest md-render-pad-table-string-empty-line ()
  ;; Empty continuation lines (the `""' a row-renderer hands to padding
  ;; when a cell wraps fewer times than the row's max) must always
  ;; render as exactly WIDTH spaces.  The pixel path used to be skipped
  ;; for empty strings via the row-renderer's caller-side guard — pin
  ;; the contract here so the guard stays in place.
  (should (equal "    "
                 (md-render--pad-table-string
                  :str "" :width 4)))
  (should (equal "    "
                 (md-render--pad-table-string
                  :str "" :width 4 :force-pixel t))))

(ert-deftest md-render-table-wrap-text-respects-vs-16-width ()
  ;; `⚠' alone has `string-width' 1, but `⚠\\uFE0F' (`⚠️') renders 2
  ;; cells (VS-16 forces emoji presentation).  `string-width' reports
  ;; 8 for `⚠️ Review' while the rendered width is 9 — without VS-16
  ;; awareness the wrap function lets it fit in a 8-col column and the
  ;; rendered cell overflows by 1, pushing every subsequent pipe right.
  ;; By contrast `❌ Killed' (`string-width' 9) wraps in the same
  ;; column, producing visibly asymmetric misalignment.  Both should
  ;; wrap.
  (should (equal '("⚠️" "Review")
                 (md-render--table-wrap-text "⚠️ Review" 8)))
  (should (equal '("❌" "Killed")
                 (md-render--table-wrap-text "❌ Killed" 8)))
  ;; Both fit at col 9 (matching their rendered widths).
  (should (equal '("⚠️ Review")
                 (md-render--table-wrap-text "⚠️ Review" 9)))
  (should (equal '("❌ Killed")
                 (md-render--table-wrap-text "❌ Killed" 9))))

(ert-deftest md-render-text-has-face-p ()
  ;; Detects whether a string carries a `face' property anywhere —
  ;; the trigger for routing table cell measurement through the
  ;; pixel-accurate path when a theme's inline-code/bold/etc. face
  ;; renders at a different pixel width than `string-width' reports.
  (should-not (md-render--text-has-face-p "plain"))
  (should (md-render--text-has-face-p
           (propertize "styled" 'face 'bold)))
  ;; Mid-string face is detected too — not just at position 0.
  (should (md-render--text-has-face-p
           (concat "a" (propertize "b" 'face 'bold) "c"))))

(ert-deftest md-render-table-wrap-text-accepts-window ()
  ;; `--table-wrap-text' grew an optional WINDOW arg so wrap decisions
  ;; can factor in face-induced pixel widening (themes that style
  ;; inline-code with a wider font would otherwise let an N-char wrap
  ;; line overflow an N-cell column in pixel terms and push the right
  ;; pipe out of line).  Pin the signature here and the no-window
  ;; behaviour (existing char-width path, unchanged).  In batch the
  ;; pixel path is unreachable, so a non-nil WINDOW falls back to the
  ;; char-width path and produces the same wrap as the 2-arg call.
  (should (equal '("hello" "world")
                 (md-render--table-wrap-text "hello world" 5)))
  (should (equal '("hello" "world")
                 (md-render--table-wrap-text
                  "hello world" 5 nil))))

(ert-deftest md-render-table-wrap-char-width-accepts-window ()
  ;; `--table-wrap-char-width' grew an optional WINDOW arg so styled
  ;; chars can scale by the face's measured pixel-width ratio.  Pin
  ;; the signature and the no-window behaviour (char-width / VS-16
  ;; correction unchanged).
  (should (= 1 (md-render--table-wrap-char-width "a" 0)))
  (should (= 1 (md-render--table-wrap-char-width "a" 0 nil)))
  ;; VS-16 still gets its width-1 attribution under both signatures.
  (should (= 1 (md-render--table-wrap-char-width "⚠️" 1)))
  (should (= 1 (md-render--table-wrap-char-width "⚠️" 1 nil))))

(ert-deftest md-render-table-apply-height-scaling-short-circuits ()
  ;; ASCII-only strings skip the per-char height measurement loop and
  ;; pass through unchanged (the costly `window-text-pixel-size'
  ;; measurement is only worth it when there are non-ASCII glyphs
  ;; that might render taller than the default line height).  In
  ;; non-graphic display (`display-graphic-p' nil — batch / TTY) the
  ;; whole pass is a no-op since the measurement APIs aren't available.
  (let ((input "Auth System"))
    (should (equal input
                   (md-render--table-apply-height-scaling input))))
  ;; In batch (no graphic display), even non-ASCII passes through
  ;; unchanged.  The function still returns a string.
  (should (stringp
           (md-render--table-apply-height-scaling "⚠️ Review"))))

(ert-deftest md-render-table-next-cell-walks-cells-in-order ()
  ;; Cells walk row-by-row, skipping the separator, and signal
  ;; `user-error' at the table boundary.
  (with-temp-buffer
    (insert "| A | B |
|---|---|
| 1 | 2 |
")
    (md-render-replace-markup)
    ;; Point at A.
    (goto-char (point-min))
    (search-forward "A")
    (backward-char)
    (md-render-table-next-cell)
    (should (eq (char-after) ?B))
    (md-render-table-next-cell)
    (should (eq (char-after) ?1))
    (md-render-table-next-cell)
    (should (eq (char-after) ?2))
    (should-error (md-render-table-next-cell) :type 'user-error)))

(ert-deftest md-render-table-previous-cell-walks-cells-in-reverse ()
  (with-temp-buffer
    (insert "| A | B |
|---|---|
| 1 | 2 |
")
    (md-render-replace-markup)
    ;; Point at 2.
    (goto-char (point-min))
    (search-forward "2")
    (backward-char)
    (md-render-table-previous-cell)
    (should (eq (char-after) ?1))
    (md-render-table-previous-cell)
    (should (eq (char-after) ?B))
    (md-render-table-previous-cell)
    (should (eq (char-after) ?A))
    (should-error (md-render-table-previous-cell) :type 'user-error)))

(ert-deftest md-render-table-next-cell-skips-wrapped-continuation ()
  ;; A wrapped row spans multiple physical lines; only the first
  ;; line carries navigable cells.  Continuation lines (with the
  ;; remainder of wrapped content in some cells, padding in others)
  ;; must not register as separate cells.
  (let ((md-render-table-max-width-fraction 1.0))
    (cl-letf (((symbol-function 'md-render--display-width)
               (lambda () 30)))
      (with-temp-buffer
        (insert "| A | B |
|---|---|
| short | this is a much longer description |
")
        (md-render-replace-markup)
        ;; The rendered table has the data row wrapped to 2 physical
        ;; lines.  There should be exactly 4 navigable cells: A, B
        ;; (header), short, "this is a much" (the data row's first
        ;; line — but logically one cell, "this is a much longer
        ;; description").
        (goto-char (point-min))
        (search-forward "A")
        (backward-char)
        (md-render-table-next-cell)
        (should (eq (char-after) ?B))
        (md-render-table-next-cell)
        (should (looking-at-p "short"))
        (md-render-table-next-cell)
        (should (looking-at-p "this is a much"))
        ;; The continuation line "longer description" is NOT a cell.
        (should-error (md-render-table-next-cell) :type 'user-error)))))

(ert-deftest md-render-table-next-cell-errors-outside-table ()
  (with-temp-buffer
    (insert "not a table at all")
    (goto-char (point-min))
    (should-error (md-render-table-next-cell) :type 'user-error)
    (should-error (md-render-table-previous-cell) :type 'user-error)))

(ert-deftest md-render-convert-table-in-fenced-block-untouched ()
  ;; A table inside a fenced block stays untouched (source-block body
  ;; is frozen, so table detection skips it — and source-block fences
  ;; are themselves deleted, but the body chars stay literal).
  (let ((s (md-render-convert "```
| A | B |
|---|---|
| 1 | 2 |
```")))
    (should (string-match-p "| A | B |" s))
    (should (not (string-match-p "│" s)))))

(ert-deftest md-render-convert-everything ()
  (should (equal
           (md-render--deconstruct
            (md-render-convert
             "# Top

Some **bold** and _italic_ with ~~strike~~ done.

---

## Sub with **mixed _both_ end**

A [link](https://example.com) and `code`.

```
**not bold**
```

![alt](/missing).

| A | B |
|---|---|
| 1 | 2 |"))
           '(("Top" (md-render-header-1))
             ("

Some " nil)
             ("bold" (md-render-bold))
             (" and " nil)
             ("italic" (md-render-italic))
             (" with " nil)
             ("strike" (md-render-strikethrough))
             (" done.

---

" nil)
             ("Sub with " (md-render-header-2))
             ("mixed " (md-render-header-2 md-render-bold))
             ("both" (md-render-header-2 md-render-bold md-render-italic))
             (" end" (md-render-header-2 md-render-bold))
             ("

A " nil)
             ("link" (md-render-link))
             (" and " nil)
             ("code" (md-render-inline-code))
             (".

" nil)
             ("
" (md-render-source-block))
             ("snippet ⧉" (md-render-source-block-language))
             ("

**not bold**

" (md-render-source-block))
             ("
![alt](/missing).

" nil)
             ("│" (fixed-pitch md-render-table-border))
             (" A " (fixed-pitch md-render-table-header))
             ("│" (fixed-pitch md-render-table-border))
             (" B " (fixed-pitch md-render-table-header))
             ("│" (fixed-pitch md-render-table-border))
             ("
" (fixed-pitch))
             ("├───┼───┤" (fixed-pitch md-render-table-border))
             ("
" (fixed-pitch))
             ("│" (fixed-pitch md-render-table-border))
             (" 1 " (fixed-pitch))
             ("│" (fixed-pitch md-render-table-border))
             (" 2 " (fixed-pitch))
             ("│" (fixed-pitch md-render-table-border))))))

(ert-deftest md-render-watermark-skips-prefix-on-streamed-append ()
  ;; After a render, the prefix carries the watermark text property and
  ;; the next render — narrowed to (watermark, point-max) — must not
  ;; revisit the rendered prefix.  Verify by injecting a sentinel
  ;; `font-lock-face' at point-min after the first render; the mirror
  ;; pass on the second render would overwrite it if the prefix were
  ;; re-scanned, but with the watermark in place it stays put.
  (with-temp-buffer
    (insert "**hello**\n")
    (md-render-replace-markup)
    (put-text-property (point-min) (1+ (point-min))
                       'font-lock-face 'md-render-test-sentinel)
    (goto-char (point-max))
    (insert "**world**\n")
    (md-render-replace-markup)
    (should (eq (get-text-property (point-min) 'font-lock-face)
                'md-render-test-sentinel))
    ;; And the newly-streamed bold still rendered normally.
    (should (string-match-p "^hello\nworld\n$"
                            (substring-no-properties (buffer-string))))))

(ert-deftest md-render-yank-strips-properties ()
  ;; Rendered chars carry a `yank-handler' that strips every text
  ;; property on paste — display overrides, internal markers, faces,
  ;; keymaps — so a copy/paste into another buffer gives plain chars,
  ;; not our implementation cruft.
  (with-temp-buffer
    (insert "**bold** and `code`\n")
    (md-render-replace-markup)
    (kill-new (buffer-substring (point-min) (point-max))))
  (with-temp-buffer
    (yank)
    (let ((pos (point-min)))
      (while (< pos (point-max))
        (should-not (text-properties-at pos))
        (setq pos (1+ pos))))))

(ert-deftest md-render-convert-blockquote-single-level ()
  ;; `> text\n' keeps the `>' in the buffer (source round-trips) but
  ;; shows `▌' as a display override.  The line content carries the
  ;; blockquote face.
  (let ((s (md-render-convert "> hello\n")))
    (should (equal (substring-no-properties s) "> hello\n"))
    (should (equal (get-text-property 0 'display s)
                   (propertize "▌"
                              'face 'md-render-blockquote)))
    (should (eq (get-text-property 2 'face s)
                'md-render-blockquote))
    (should (eq (get-text-property 0 'md-render-frozen s) t))))

(ert-deftest md-render-convert-callout-panel ()
  ;; GitHub callouts keep their Markdown source but render with a
  ;; type title, an accent bar, and a panel face across the body.
  (let* ((s (md-render-convert "> [!TIP]\n> Useful body\n"))
         (title-pos (string-match "\\[!TIP\\]" s))
         (body-pos (string-match "Useful body" s))
         (title-display (get-text-property title-pos 'display s))
         (bar-display (get-text-property 0 'display s)))
    (should (equal (substring-no-properties s)
                   "> [!TIP]\n> Useful body\n"))
    (should (equal (substring-no-properties title-display) " Tip"))
    (should (equal (substring-no-properties bar-display) "▎"))
    (should (eq (get-text-property body-pos 'md-render-callout s) 'TIP))
    (let ((face (get-text-property body-pos 'face s)))
      (should (or (eq face 'md-render-callout)
                  (and (listp face)
                       (memq 'md-render-callout face)))))))

(ert-deftest md-render-convert-blockquote-multi-level ()
  ;; Each leading `>' gets its own bar — `>> ' shows two, `>>> '
  ;; shows three.  Whitespace between `>'s is preserved.
  (let ((s (md-render-convert ">> level 2\n")))
    (should (equal (get-text-property 0 'display s)
                   (propertize "▌"
                              'face 'md-render-blockquote)))
    (should (equal (get-text-property 1 'display s)
                   (propertize "▌"
                              'face 'md-render-blockquote))))
  (let ((s (md-render-convert ">>> level 3\n")))
    (dolist (i '(0 1 2))
      (should (equal (get-text-property i 'display s)
                     (propertize "▌"
                                'face 'md-render-blockquote))))))

(ert-deftest md-render-convert-blockquote-with-bold ()
  ;; Inline markup inside a blockquote still renders — bold runs
  ;; before blockquote, and the blockquote face composes on top so
  ;; the bold text ends up with both faces.
  (should (equal (md-render--deconstruct
                  (md-render-convert "> hello **world**\n"))
                 '(("> hello " (md-render-blockquote))
                   ("world" (md-render-blockquote
                             md-render-bold))
                   ("\n" nil)))))

(ert-deftest md-render-blockquote-waits-for-newline-across-chunks ()
  ;; A blockquote line streamed across two chunks (`> hel' then `lo\n')
  ;; must not render until the line completes — otherwise `> hel'
  ;; would face only `hel' and leave the rest plain on the next call.
  (with-temp-buffer
    (insert "> hel")
    (md-render-replace-markup)
    (should (equal (substring-no-properties (buffer-string)) "> hel"))
    (should-not (get-text-property (point-min) 'display))
    (goto-char (point-max))
    (insert "lo\n")
    (md-render-replace-markup)
    (should (equal (get-text-property (point-min) 'display)
                   (propertize "▌"
                              'face 'md-render-blockquote)))
    (should (eq (get-text-property (+ (point-min) 2) 'face)
                'md-render-blockquote))))

(ert-deftest md-render-blockquote-inside-fence-stays-raw ()
  ;; A `>'-prefixed line inside a fenced code block must not be
  ;; styled as a blockquote — the source-block range is in
  ;; avoid-ranges.  The `>' carries the source-block's
  ;; `md-render-frozen' tag and no blockquote face.
  (let* ((s (md-render-convert "```
> not a quote
```
"))
         (quote-pos (string-match "> not a quote"
                                  (substring-no-properties s))))
    (should quote-pos)
    (should (eq t (get-text-property quote-pos 'md-render-frozen s)))
    (should-not (eq (get-text-property quote-pos 'face s)
                    'md-render-blockquote))))

(ert-deftest md-render-header-waits-for-newline-across-chunks ()
  ;; A header split across two chunks (chunk 1 = `# He', chunk 2 =
  ;; `llo World\\n') must not render eagerly on chunk 1 — the
  ;; trailing-newline gate keeps `# He' raw, and chunk 2's render
  ;; faces the entire `Hello World' once the line completes.
  (with-temp-buffer
    (insert "# He")
    (md-render-replace-markup)
    (should (equal (substring-no-properties (buffer-string)) "# He"))
    (goto-char (point-max))
    (insert "llo World\n")
    (md-render-replace-markup)
    (should (equal (substring-no-properties (buffer-string))
                   "Hello World\n"))
    (dotimes (i (length "Hello World"))
      (should (eq (get-text-property (+ (point-min) i) 'face)
                  'md-render-header-1)))))

(ert-deftest md-render-frozen-region-skips-header-pass ()
  ;; Callers (eg. `agent-shell--format-diff-as-text') tag pre-rendered
  ;; content with `md-render-frozen t' so it displays verbatim.
  ;; The header pass must respect that tag — a diff context line like
  ;; ` # Foo' must not be rewritten as an H1.  See PR #597.
  (with-temp-buffer
    (insert (propertize "@@ -1,2 +1,2 @@\n # Test Document Title\n-old\n+new\n"
                        'md-render-frozen t))
    (md-render-replace-markup)
    (should (equal (substring-no-properties (buffer-string))
                   "@@ -1,2 +1,2 @@\n # Test Document Title\n-old\n+new\n"))))

(ert-deftest md-render-header-keeps-properties-scoped ()
  (with-temp-buffer
    (insert (propertize "# "
                        'agent-shell-ui-section 'body
                        'invisible 'markdown-markup))
    (insert (propertize "Title"
                        'agent-shell-ui-section 'body))
    (insert (propertize "\n"
                        'agent-shell-ui-section 'body
                        'invisible t))
    (md-render-replace-markup)
    (should (equal (substring-no-properties (buffer-string))
                   "Title\n"))
    (dotimes (i (length "Title"))
      (let ((pos (+ (point-min) i)))
        (should (eq 'body
                    (get-text-property pos 'agent-shell-ui-section)))
        (should-not (get-text-property pos 'invisible))))
    (let ((newline-pos (+ (point-min) (length "Title"))))
      (should (eq 'body
                  (get-text-property newline-pos 'agent-shell-ui-section)))
      (should (eq t (get-text-property newline-pos 'invisible))))))

(ert-deftest md-render-header-preserves-caller-text-properties ()
  ;; The header pass deletes the matched `#…\n' and re-inserts the
  ;; faced title plus a fresh `\n'.  The inserted newline must carry
  ;; the caller's text properties — otherwise it punches a hole in any
  ;; contiguous block tagging (eg. `invisible' / `agent-shell-ui-section')
  ;; that brackets the body, breaking toggle/replace operations on the
  ;; surrounding fragment.  See PR #597.
  (with-temp-buffer
    (insert (propertize "# Title\nbody line\n"
                        'agent-shell-ui-section 'body
                        'invisible t))
    (md-render-replace-markup)
    (dotimes (i (1- (point-max)))
      (let ((pos (1+ i)))
        (should (eq 'body
                    (get-text-property pos 'agent-shell-ui-section)))
        (should (eq t (get-text-property pos 'invisible)))))))

(ert-deftest md-render-watermark-keeps-pending-table-in-scope ()
  ;; When table rows stream in one at a time, the table needs at least
  ;; two consecutive pipe-rows in scope before `--find-tables' will
  ;; render anything.  If the watermark advances past each row as it
  ;; arrives, the renderer never sees enough rows at once and the
  ;; whole table stays raw forever.  `--extending-table-start' has to
  ;; back off through a streak of raw pipe-rows just like it does
  ;; through a rendered table, so the next chunk's narrow includes the
  ;; whole accumulating table.
  (with-temp-buffer
    (insert "intro paragraph\n\n")
    (md-render-replace-markup)
    (dolist (row '("| A | B |\n"
                   "|---|---|\n"
                   "| 1 | 2 |\n"
                   "| 3 | 4 |\n"))
      (goto-char (point-max))
      (insert row)
      (md-render-replace-markup))
    (should (string-match-p "│"
                            (substring-no-properties (buffer-string))))
    (should-not (string-match-p "^| A | B |"
                                (substring-no-properties (buffer-string))))))

(ert-deftest md-render-watermark-keeps-pending-table-with-partial-separator ()
  ;; Real-world regression: an LLM streams a 5-column table cell-by-
  ;; cell and the separator row arrives as a sequence of `|-------'
  ;; chunks that aren't a complete pipe-row until the trailing `|'
  ;; lands.  While the separator is mid-stream, the strict pipe-row
  ;; regex doesn't match (it needs the closing `|'); the lenient
  ;; pending-line regex must still recognise it so the watermark
  ;; stays at the header line.  Otherwise the watermark slips past
  ;; the header and `--find-tables' eventually renders only
  ;; separator + data rows, leaving the header raw outside the table.
  (with-temp-buffer
    (dolist (chunk '("| Col 1 | Col 2 |\n"
                     "|-------"
                     "|-------"
                     "|"
                     "\n"
                     "| Row 1 | A |\n"
                     "| Row 2 | B |\n"))
      (goto-char (point-max))
      (insert chunk)
      (md-render-replace-markup))
    (let ((rendered (substring-no-properties (buffer-string))))
      ;; Header is part of the rendered Unicode table — no raw `|' on
      ;; its line.
      (should (string-match-p "│ Col 1 *│ Col 2 *│" rendered))
      (should-not (string-match-p "^| Col 1" rendered)))))

(ert-deftest md-render-inline-code-completes-across-chunk-boundary ()
  ;; LLM streams may split an inline-code span across chunks (e.g.
  ;; `\\`co' lands first, then `de\\`').  The first render sees an
  ;; unclosed backtick on the last line — `--inline-code-ranges' marks
  ;; the rest of the line as a still-streaming range so `--style-
  ;; inline-code's two-backtick regex doesn't match yet, and the
  ;; watermark stays at the start of that line.  When the closing
  ;; backtick arrives on the same line in the next chunk, the second
  ;; render matches the full span and strips both backticks.
  ;;
  ;; This regression-guards the watermark too: if a future change
  ;; advanced the watermark past the open backtick, the second render
  ;; would narrow past the opener and leave it raw.
  (with-temp-buffer
    (insert "text `co")
    (md-render-replace-markup)
    (should (string-match-p "`co"
                            (substring-no-properties (buffer-string))))
    (goto-char (point-max))
    (insert "de`")
    (md-render-replace-markup)
    (should (equal (substring-no-properties (buffer-string))
                   "text code"))
    (should (eq (get-text-property (- (point-max) 1) 'face)
                'md-render-inline-code))))

(ert-deftest md-render-replace-markup-force-clears-watermark ()
  ;; The `:force' key drops the stored watermark before the call, so
  ;; the whole buffer is re-scanned.  We simulate a maximally
  ;; advanced watermark by stamping one at `point-max' — a non-force
  ;; call narrows to (point-max, point-max) and is a no-op; a `:force
  ;; t' call clears the watermark first and renders normally.
  (with-temp-buffer
    (insert "**bold**\n")
    (with-silent-modifications
      (put-text-property (point-min) (1+ (point-min))
                         'md-render-watermark (point-max)))
    (md-render-replace-markup)
    (should (string-match-p "\\*\\*bold\\*\\*"
                            (substring-no-properties (buffer-string))))
    (md-render-replace-markup :force t)
    (should-not (string-match-p "\\*\\*"
                                (substring-no-properties (buffer-string))))))

(ert-deftest md-render--url-copy-file-test ()
  "Test `md-render--url-copy-file'.

Synchronously downloads a URL to a file, validating HTTP 200 and an optional
Content-Type prefix before writing.  `url-retrieve-synchronously' is stubbed
so the test never touches the network."
  (let* ((make-response
          (lambda (status content-type body)
            (lambda (&rest _)
              (let ((buffer (generate-new-buffer " *fake-http*")))
                (with-current-buffer buffer
                  (set-buffer-multibyte nil)
                  (insert (format "HTTP/1.1 %s\r\nContent-Type: %s\r\n\r\n"
                                  status content-type))
                  (insert body))
                buffer))))
         (dest (make-temp-file "agent-shell-url-copy")))
    (unwind-protect
        (progn
          ;; 200 + matching Content-Type prefix -> writes body, returns dest.
          (delete-file dest)
          (cl-letf (((symbol-function 'url-retrieve-synchronously)
                     (funcall make-response "200 OK" "image/png" "PNGBYTES")))
            (should (equal (md-render--url-copy-file
                            :url "https://example.com/a.png" :file dest
                            :content-type-prefix "image/")
                           dest))
            (should (file-exists-p dest)))

          ;; No Content-Type prefix -> any 200 response is written.
          (delete-file dest)
          (cl-letf (((symbol-function 'url-retrieve-synchronously)
                     (funcall make-response "200 OK" "text/plain" "hello")))
            (should (equal (md-render--url-copy-file
                            :url "https://example.com/a" :file dest)
                           dest))
            (should (file-exists-p dest)))

          ;; 200 but Content-Type prefix mismatch -> nil, nothing written.
          (delete-file dest)
          (cl-letf (((symbol-function 'url-retrieve-synchronously)
                     (funcall make-response "200 OK" "text/html" "<html>nope</html>")))
            (should-not (md-render--url-copy-file
                         :url "https://example.com/a" :file dest
                         :content-type-prefix "image/"))
            (should-not (file-exists-p dest)))

          ;; Non-200 -> nil, nothing written.
          (cl-letf (((symbol-function 'url-retrieve-synchronously)
                     (funcall make-response "404 Not Found" "image/png" "x")))
            (should-not (md-render--url-copy-file
                         :url "https://example.com/a.png" :file dest
                         :content-type-prefix "image/"))
            (should-not (file-exists-p dest)))

          ;; Connection failure (nil buffer) -> nil, nothing written.
          (cl-letf (((symbol-function 'url-retrieve-synchronously)
                     (lambda (&rest _) nil)))
            (should-not (md-render--url-copy-file
                         :url "https://example.com/a.png" :file dest))
            (should-not (file-exists-p dest))))
      (when (file-exists-p dest) (delete-file dest)))))

(ert-deftest md-render--fetch-remote-image-test ()
  "Test `md-render--fetch-remote-image'.

Owns the image policy (http-only, known image extension, md5-named cache);
the download itself is delegated to `md-render--url-copy-file',
which is stubbed here so the test exercises only the policy."
  ;; With a CACHE-DIRECTORY: cached path requested from the downloader and
  ;; returned, under that directory.
  (cl-letf (((symbol-function 'md-render--url-copy-file)
             (lambda (&rest args) (plist-get args :file))))
    (let ((file (md-render--fetch-remote-image
                 "https://example.com/a.png" "/tmp/img-cache")))
      (should (string-prefix-p "/tmp/img-cache/" file))
      (should (string-suffix-p ".png" file))
      (should (string-match-p "/[0-9a-f]+\\.png\\'" file))))

  ;; Without a CACHE-DIRECTORY: remote images are not fetched.
  (cl-letf (((symbol-function 'md-render--url-copy-file)
             (lambda (&rest _) (error "should not download"))))
    (should-not (md-render--fetch-remote-image "https://example.com/a.png" nil)))

  ;; A failed download -> nil (no silent path returned).
  (cl-letf (((symbol-function 'md-render--url-copy-file)
             (lambda (&rest _) nil)))
    (should-not (md-render--fetch-remote-image "https://example.com/b.png" "/tmp/img-cache")))

  ;; Non-http uris and extensionless urls are never downloaded.
  (cl-letf (((symbol-function 'md-render--url-copy-file)
             (lambda (&rest _) (error "should not download"))))
    (should-not (md-render--fetch-remote-image "file:///tmp/x.png" "/tmp/img-cache"))
    (should-not (md-render--fetch-remote-image "https://example.com/img?id=1" "/tmp/img-cache"))))

(ert-deftest md-render--resolve-image-url-remote-test ()
  "Test that `md-render--resolve-image-url' fetches http(s) urls.

A remote url is resolved through `md-render--fetch-remote-image'
\(stubbed), forwarding the injected cache directory; local-path resolution is
unaffected."
  (cl-letf (((symbol-function 'md-render--fetch-remote-image)
             (lambda (url image-cache-directory)
               (and (string-match-p "\\`https?://" url) image-cache-directory
                    (format "%s/x.png" image-cache-directory)))))
    ;; Remote url -> fetched; the image-cache-directory argument is forwarded.
    (should (equal (md-render--resolve-image-url
                    "https://example.com/x.png" "/injected")
                   "/injected/x.png"))
    ;; No image-cache-directory -> remote image is not fetched (nil).
    (should-not (md-render--resolve-image-url "https://example.com/x.png"))
    ;; A non-existent local path still resolves to nil (no fetch attempted).
    (should-not (md-render--resolve-image-url "/no/such/file.png"))))

(ert-deftest md-render--open-externally-test ()
  "Test `md-render--open-externally' gates on confirmation."
  (let ((opened nil))
    (cl-letf (((symbol-function 'shell-command-do-open)
               (lambda (files) (setq opened files)))
              ((symbol-function 'browse-url-of-file)
               (lambda (file) (setq opened (list file)))))
      ;; Confirmed -> opens.
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
        (setq opened nil)
        (md-render--open-externally "/tmp/x.bin")
        (should (equal opened '("/tmp/x.bin"))))
      ;; Declined -> does nothing.
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
        (setq opened nil)
        (md-render--open-externally "/tmp/x.bin")
        (should-not opened)))))

(ert-deftest md-render--binary-file-p-test ()
  "Test `md-render--binary-file-p' NUL-byte heuristic."
  (let ((text (make-temp-file "agent-shell-text"))
        (binary (make-temp-file "agent-shell-binary")))
    (unwind-protect
        (progn
          (with-temp-file text (insert "plain text\nmore"))
          (let ((coding-system-for-write 'binary))
            (with-temp-file binary (insert "abc\0def")))
          (should-not (md-render--binary-file-p text))
          (should (md-render--binary-file-p binary)))
      (delete-file text)
      (delete-file binary))))

(ert-deftest md-render--open-local-link-binary-vs-text-test ()
  "Test `md-render--open-local-link' routes by file type.
Text/navigable files open in Emacs; binary files open externally."
  (let ((text (make-temp-file "agent-shell-ol-text" nil ".txt"))
        (binary (make-temp-file "agent-shell-ol-bin" nil ".bin"))
        (action nil))
    (unwind-protect
        (progn
          (with-temp-file text (insert "hello"))
          (let ((coding-system-for-write 'binary))
            (with-temp-file binary (insert "x\0y")))
          (cl-letf (((symbol-function 'find-file)
                     (lambda (f) (setq action (cons 'find-file f))))
                    ((symbol-function 'md-render--open-externally)
                     (lambda (f) (setq action (cons 'external f)))))
            ;; Text file -> find-file (navigable in Emacs).
            (setq action nil)
            (should (md-render--open-local-link (concat "file://" text)))
            (should (equal action (cons 'find-file text)))
            ;; Binary file -> open externally.
            (setq action nil)
            (should (md-render--open-local-link (concat "file://" binary)))
            (should (equal action (cons 'external binary)))
            ;; Binary file with a line number -> still external (line ignored).
            (setq action nil)
            (should (md-render--open-local-link (concat "file://" binary "#L10")))
            (should (equal action (cons 'external binary)))))
      (delete-file text)
      (delete-file binary))))

(defun md-render-tests--source-blocks (markdown)
  "Return the `:source-blocks' descriptors a renderer sees for MARKDOWN.
Each :block marker range is replaced by the text it spans, so the
result is stable to compare against.  (The marker behaviour itself is
exercised by the editing in the -all-math-cases test.)"
  (let (blocks)
    (with-temp-buffer
      (let ((md-render-render-functions
             (list (lambda (context)
                     (setq blocks
                           (mapcar (lambda (b)
                                     (list (cons :language (map-elt b :language))
                                           (cons :block (buffer-substring-no-properties
                                                         (map-nested-elt b '(:block :start))
                                                         (map-nested-elt b '(:block :end))))
                                           (cons :body (map-elt b :body))
                                           (cons :complete (map-elt b :complete))))
                                   (map-elt context :source-blocks)))
                     nil))))
        (insert markdown)
        (md-render-replace-markup)))
    blocks))

(ert-deftest md-render-render-functions-receives-source-blocks ()
  ;; A render function is handed `:source-blocks' descriptors: the language,
  ;; the block's marker range (shown here as the text it spans), the body,
  ;; and completeness.
  (should (equal (md-render-tests--source-blocks
                  "text
```math
\\frac{a}{b}
```
")
                 '(((:language . "math")
                    (:block . "```math\n\\frac{a}{b}\n```\n")
                    (:body . "\\frac{a}{b}")
                    (:complete . t))))))

(ert-deftest md-render-render-functions-source-blocks-incomplete ()
  ;; A still-streaming fence is reported with `:complete' nil and no
  ;; `:body', so a renderer knows the language but not to claim it yet.
  (should (equal (md-render-tests--source-blocks
                  "```math
\\frac{a}{b")
                 '(((:language . "math")
                    (:block . "```math\n\\frac{a}{b")
                    (:body . nil)
                    (:complete . nil))))))

(ert-deftest md-render-render-functions-frozen-region-protected ()
  ;; A render function that tags its region `md-render-frozen'
  ;; has it treated as an avoid-range: the emphasis passes leave `_'/`*'
  ;; inside literal, while markup outside the region still renders.
  (with-temp-buffer
    (let ((md-render-render-functions
           (list (lambda (_context)
                   (goto-char (point-min))
                   (when (re-search-forward "\\$\\$.*?\\$\\$" nil t)
                     (put-text-property (match-beginning 0) (match-end 0)
                                        'md-render-frozen t))
                   nil))))
      (insert "see **bold** and $$a_b*c*$$ end")
      (md-render-replace-markup)
      (should (equal (md-render--deconstruct (buffer-string))
                     '(("see " nil)
                       ("bold" (md-render-bold))
                       (" and $$a_b*c*$$ end" nil)))))))

(ert-deftest md-render-render-functions-frozen-fenced-block-left-intact ()
  ;; A render function can claim a ```math / ```latex fence in place
  ;; (freezing the whole block without deleting its fences), and
  ;; `--style-source-blocks' honors `md-render-frozen' and
  ;; leaves it untouched.  Without this the source-block pass would strip
  ;; the fences and re-fontify the body as a code panel, clobbering the
  ;; renderer's overlay and forcing it to mutate the agent's original text.
  (with-temp-buffer
    (let ((md-render-render-functions
           (list (lambda (context)
                   (dolist (block (map-elt context :source-blocks))
                     (when (and (equal (map-elt block :language) "math")
                                (map-elt block :complete))
                       (put-text-property (map-nested-elt block '(:block :start))
                                          (map-nested-elt block '(:block :end))
                                          'md-render-frozen t)))
                   nil))))
      (insert "```math\n\\frac{a}{b}\n```\n")
      (md-render-replace-markup)
      ;; Fences and body survive verbatim: no code-panel "⧉" label was
      ;; inserted and the frozen claim still stands for later passes.
      (should (equal (substring-no-properties (buffer-string))
                     "```math\n\\frac{a}{b}\n```\n"))
      (should-not (string-match-p "⧉" (buffer-string)))
      (should (eq t (get-text-property (point-min)
                                       'md-render-frozen))))))

(ert-deftest md-render-render-functions-watermark-held-back ()
  ;; A render function returning `:watermark' holds the streaming frontier
  ;; behind its own open delimiter, even when it spans lines above the last
  ;; one (which the built-in start-of-last-line back-off wouldn't cover).
  (with-temp-buffer
    (let ((md-render-render-functions
           (list (lambda (_context)
                   (save-excursion
                     (goto-char (point-min))
                     (when (re-search-forward "\\$\\$" nil t)
                       (list (cons :watermark (match-beginning 0)))))))))
      (insert "intro\n$$\nx_y\nz_w")
      (let ((open-dollar (save-excursion
                           (goto-char (point-min))
                           (re-search-forward "\\$\\$")
                           (match-beginning 0))))
        (md-render-replace-markup)
        (should (= (get-text-property (point-min)
                                      'md-render-watermark)
                   open-dollar))))))

(ert-deftest md-render-render-functions-all-math-cases ()
  ;; A renderer that claims every math form the PR supports and wraps its
  ;; LaTeX in brackets: inline \(..\) as [..], and block \[..\], $$..$$ and
  ;; fenced ```math / ```latex as the multi-line [\n..\n].  It routes the
  ;; fenced blocks by `:language', keeps $$ inside a fenced code block
  ;; literal, and uses `:inline-code-ranges' to keep a \(..\) inside an
  ;; inline `code` span literal too.
  (with-temp-buffer
    (let ((md-render-render-functions
           (list
            (lambda (context)
              ;; Fenced ```math / ```latex blocks, claimed by language.
              ;; Back-to-front so replacing one block does not disturb the
              ;; markers of an adjacent earlier one.
              (dolist (block (reverse (map-elt context :source-blocks)))
                (when (and (member (map-elt block :language) '("math" "latex"))
                           (map-elt block :complete))
                  (let ((start (map-nested-elt block '(:block :start)))
                        (end (map-nested-elt block '(:block :end)))
                        (body (map-elt block :body)))
                    (delete-region start end)
                    (goto-char start)
                    (insert (format "[\n%s\n]\n\n" body))
                    (put-text-property start (point)
                                       'md-render-frozen t))))
              ;; Inline / block delimiters, skipping matches that fall
              ;; inside code: a non-math fenced block (so $$ in code stays
              ;; literal) or an inline `code` span from
              ;; `:inline-code-ranges' (so a literal \(..\) the agent meant
              ;; as code stays literal).
              (let ((code-ranges
                     (append
                      (map-elt context :inline-code-ranges)
                      (seq-keep
                       (lambda (b)
                         (unless (member (map-elt b :language) '("math" "latex"))
                           (cons (map-nested-elt b '(:block :start))
                                 (map-nested-elt b '(:block :end)))))
                       (map-elt context :source-blocks)))))
                (dolist (spec (list (list (rx "\\(" (group (*? anychar)) "\\)") "[%s]")
                                    (list (rx "\\[" (group (*? anychar)) "\\]") "[\n%s\n]\n")
                                    (list (rx "$$" (group (*? anychar)) "$$") "[\n%s\n]\n")))
                  (save-excursion
                    (goto-char (point-min))
                    (while (re-search-forward (car spec) nil t)
                      (let ((start (match-beginning 0))
                            (content (match-string 1)))
                        (unless (or (get-text-property start 'md-render-frozen)
                                    (seq-some (lambda (r) (and (>= start (car r))
                                                              (< start (cdr r))))
                                              code-ranges))
                          (replace-match (format (cadr spec) content) nil t)
                          (put-text-property start (point)
                                             'md-render-frozen t)))))))
              nil))))
      (insert "```python
q = \"$$not math$$\"
```
inline \\(a+b\\) here
verbatim `\\(z\\)` code
\\[x = y\\]
$$E = mc^2$$
```math
\\frac{a}{b}
```
```latex
\\alpha
```
")
      (md-render-replace-markup)
      ;; Every math form rendered with its LaTeX in brackets; the $$ inside
      ;; the python block stayed literal (its language kept it out of
      ;; reach), and the \(z\) inside the inline `code` span stayed literal
      ;; too (`:inline-code-ranges' kept it out of reach).
      (should (equal (buffer-substring-no-properties (point-min) (point-max))
                     "
python ⧉

q = \"$$not math$$\"

inline [a+b] here
verbatim \\(z\\) code
[
x = y
]

[
E = mc^2
]

[
\\frac{a}{b}
]

[
\\alpha
]

")))))

;;; Reconstructing markdown from rendered text (copy-as-markdown).

(defun md-render-tests--roundtrip (markdown)
  "Render MARKDOWN, then reconstruct it from the whole buffer.
Returns the reconstructed markdown, which should equal MARKDOWN
for a fully-selected buffer."
  (with-temp-buffer
    (insert markdown)
    (md-render-replace-markup :force t :render-images nil)
    (md-render-reconstruct (point-min) (point-max))))

(ert-deftest md-render-reconstruct-inline ()
  (should (equal (md-render-tests--roundtrip
                  "Some **bold**, *italic*, `code` and a [link](https://x.com).\n")
                 "Some **bold**, *italic*, `code` and a [link](https://x.com).\n")))

(ert-deftest md-render-reconstruct-header ()
  (should (equal (md-render-tests--roundtrip "## My title\n")
                 "## My title\n")))

(ert-deftest md-render-reconstruct-fenced-block ()
  (should (equal (md-render-tests--roundtrip
                  "```python\ndef foo():\n    return 1\n```\n")
                 "```python\ndef foo():\n    return 1\n```\n")))

(ert-deftest md-render-reconstruct-table ()
  (should (equal (md-render-tests--roundtrip
                  "| A | B |\n|---|---|\n| 1 | 2 |\n")
                 "| A | B |\n|---|---|\n| 1 | 2 |\n")))

(ert-deftest md-render-reconstruct-mixed ()
  (let ((markdown (concat "# Title\n\n"
                          "A **bold** paragraph.\n\n"
                          "```js\nx = 1\n```\n\n"
                          "> a quote\n\n"
                          "- item *one*\n- item two\n")))
    (should (equal (md-render-tests--roundtrip markdown) markdown))))

(ert-deftest md-render-reconstruct-nested ()
  ;; Nested and overlapping markup reconstructs faithfully, including
  ;; the mirror cases (`**_x_**' vs `[**b**](u)') where two constructs
  ;; land on the same characters.
  (dolist (markdown '("This is **bold _and italic_ inside**."
                      "**_x_**"
                      "a link with [**bold** text](https://x.com) inside"
                      "**bold `code` and _italic_ end**"
                      "## A **big** title\n"))
    (should (equal (md-render-tests--roundtrip markdown) markdown))))

(ert-deftest md-render-reconstruct-partial-selection-is-verbatim ()
  ;; A construct only partially covered by the region is copied as shown
  ;; (visible text), not reconstructed to its source.
  (with-temp-buffer
    (insert "Some **bold text** here.\n")
    (md-render-replace-markup :force t :render-images nil)
    ;; Rendered buffer is "Some bold text here.\n"; selecting from the
    ;; middle of the span through the end must not restore any `**'.
    (should (equal (md-render-reconstruct
                    (+ (point-min) 7) (point-max))
                   "ld text here.\n"))))

(ert-deftest md-render-reconstruct-across-streaming ()
  ;; Markup split unclosed across two render passes still reconstructs.
  (with-temp-buffer
    (insert "A **para")
    (md-render-replace-markup :render-images nil)
    (goto-char (point-max))
    (insert "graph** here.\n\nsecond line.\n")
    (md-render-replace-markup :render-images nil)
    (should (equal (md-render-reconstruct
                    (point-min) (point-max))
                   "A **paragraph** here.\n\nsecond line.\n"))))

;;; Exposing rendered link URLs (issue #669).

(ert-deftest md-render-link-exposes-url ()
  (with-temp-buffer
    (insert "see [docs](https://example.com) ok")
    (md-render-replace-markup :force t :render-images nil)
    ;; Markup is replaced with the visible title.
    (should (equal (buffer-string) "see docs ok"))
    (goto-char (point-min))
    (search-forward "docs")
    (let ((on-link (1- (point))))
      ;; The URL is recoverable from a text property on the title.
      (should (equal (md-render-link-url-at-point on-link)
                     "https://example.com"))
      ;; Click behaviour is preserved (keymap still on the title).
      (should (get-text-property on-link 'keymap)))
    ;; Off the link there is no URL.
    (should-not (md-render-link-url-at-point (point-min)))))

(ert-deftest md-render-link-url-at-point-defaults-to-point ()
  (with-temp-buffer
    (insert "[docs](https://example.com)")
    (md-render-replace-markup :force t :render-images nil)
    (goto-char (1+ (point-min)))
    (should (equal (md-render-link-url-at-point)
                   "https://example.com"))))

;;; Exposing rendered code block bodies at point.

(ert-deftest md-render-source-block-at-point ()
  (with-temp-buffer
    (insert "```python\ndef foo():\n    return 1\n```\n")
    (md-render-replace-markup :force t :render-images nil)
    (goto-char (point-min))
    (search-forward "def foo")
    ;; Point on the body returns the code without fences or label.
    (should (equal (md-render-source-block-at-point (1- (point)))
                   "def foo():\n    return 1"))
    ;; The language label above the body is not the body.
    (goto-char (point-min))
    (search-forward "⧉")
    (should-not (md-render-source-block-at-point (1- (point))))))

;;; Optional Math and Mermaid rendering.

(ert-deftest md-render-math-default-scale-matches-org-preview ()
  (should (= md-render-math-scale 1.0)))

(ert-deftest md-render-default-faces-adapt-to-display ()
  (cl-mapc
   (lambda (face org-face dark-color light-color)
     (let* ((spec (get face 'face-defface-spec))
            (tty-dark (nth 0 spec))
            (tty-light (nth 1 spec))
            (gui (nth 2 spec)))
       (should
        (equal (car tty-dark) '((type tty) (background dark))))
       (should
        (equal (car tty-light) '((type tty) (background light))))
       (should (eq (plist-get (cdr tty-dark) :inherit) org-face))
       (should (eq (plist-get (cdr tty-light) :inherit) org-face))
       (should (equal (plist-get (cdr tty-dark) :foreground)
                      dark-color))
       (should (equal (plist-get (cdr tty-light) :foreground)
                      light-color))
       (should (eq (car gui) t))
       (should (eq (plist-get (cdr gui) :inherit) 'bold))))
   '(md-render-header-1
     md-render-header-2
     md-render-header-3
     md-render-header-4
     md-render-header-5
     md-render-header-6)
   '(org-level-1
     org-level-2
     org-level-3
     org-level-4
     org-level-5
     org-level-6)
   '("#ffffff" "#d2b580" "#82b0ec" "#feacd0" "#88ca9f" "#ff9580")
   '("#000000" "#624416" "#193668" "#721045" "#2a5045" "#7f0000"))
  (should
   (eq (face-attribute 'md-render-table-border :inherit nil nil)
       'shadow))
  (should-not
   (eq (face-attribute 'md-render-table-zebra :inherit nil nil)
       'lazy-highlight)))

(ert-deftest md-render-diagram-cache-tracks-theme-colors ()
  (let ((md-render-cache-directory temporary-file-directory)
        (dark nil))
    (cl-letf (((symbol-function 'face-foreground)
               (lambda (&rest _)
                 (if dark "#ffffff" "#000000")))
              ((symbol-function 'face-background)
               (lambda (&rest _)
                 (if dark "#000000" "#ffffff")))
              ((symbol-function 'frame-parameter)
               (lambda (&rest _)
                 (if dark 'dark 'light))))
      (dolist (backend '(plantuml graphviz))
        (let ((light-file
               (md-render--media-cache-file backend "source")))
          (setq dark t)
          (should-not
           (equal light-file
                  (md-render--media-cache-file backend "source")))
          (setq dark nil))))))

(ert-deftest md-render-plantuml-source-follows-theme-background ()
  (let ((source "@startuml\nEdit -> Render: local SVG\n@enduml\n"))
    (cl-letf (((symbol-function 'md-render--dark-background-p)
               (lambda () nil)))
      (let ((themed (md-render--plantuml-themed-source source)))
        (should
         (string-match-p
          "skinparam BackgroundColor transparent" themed))
        (should
         (string-match-p "skinparam Monochrome true" themed))))
    (cl-letf (((symbol-function 'md-render--dark-background-p)
               (lambda () t)))
      (should
       (string-match-p
        "skinparam Monochrome reverse"
        (md-render--plantuml-themed-source source))))))

(ert-deftest md-render-cached-inline-math-displays-svg-and-reconstructs ()
  (with-temp-buffer
    (let ((md-render-math-enabled t)
          (md-render-mermaid-enabled nil)
          (md-render-render-functions '(md-render--render-media)))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (command)
                   (and (member command '("latex" "dvisvgm" "emacs"))
                        (concat "/fake/" command))))
                ((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                ((symbol-function 'file-exists-p) (lambda (_file) t))
                ((symbol-function 'create-image)
                 (lambda (&rest _) '(image :type svg :fake t))))
        (insert "before \\(a_b\\) and `\\(literal\\)` after")
        (let ((source (buffer-string)))
          (md-render-replace-markup :force t :render-images nil)
          (should (equal (md-render-reconstruct (point-min) (point-max))
                         source))
          (goto-char (point-min))
          (search-forward "before ")
          (should (equal (get-text-property (point) 'display)
                         '(image :type svg :fake t)))
          (should (get-text-property (point) 'md-render-frozen))
          (should (string-match-p
                   (regexp-quote "\\(literal\\)")
                   (buffer-substring-no-properties
                    (point-min) (point-max)))))))))

(ert-deftest md-render-cached-mermaid-displays-png-and-reconstructs ()
  (with-temp-buffer
    (let ((md-render-math-enabled nil)
          (md-render-mermaid-enabled t)
          (md-render-render-functions '(md-render--render-media)))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (command)
                   (and (equal command "mmdc") "/fake/mmdc")))
                ((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                ((symbol-function 'file-exists-p) (lambda (_file) t))
                ((symbol-function 'create-image)
                 (lambda (&rest _) '(image :type png :fake t))))
        (insert "```mermaid\ngraph TD\n  A --> B\n```\n")
        (let ((source (buffer-string)))
          (md-render-replace-markup :force t :render-images nil)
          (should (equal (md-render-reconstruct (point-min) (point-max))
                         source))
          (goto-char (point-min))
          (search-forward " ")
          (should (equal (get-text-property (1- (point)) 'display)
                         '(image :type png :fake t)))
          (should
           (string-suffix-p
            ".png"
            (get-text-property (1- (point)) 'md-render-media-file)))
          (should-not (string-match-p
                       "mermaid ⧉"
                       (buffer-substring-no-properties
                        (point-min) (point-max)))))))))

(ert-deftest md-render-mermaid-cache-miss-starts-async-process ()
  (let ((cache-directory (make-temp-file "md-render-media-" t))
        process-arguments
        process-browser)
    (unwind-protect
        (with-temp-buffer
          (let ((md-render-cache-directory cache-directory)
                (md-render-math-enabled nil)
                (md-render-mermaid-enabled t)
                (md-render-render-functions '(md-render--render-media)))
            (cl-letf (((symbol-function 'executable-find)
                       (lambda (command)
                         (and (equal command "mmdc") "/fake/mmdc")))
                      ((symbol-function 'display-graphic-p)
                       (lambda (&rest _) t))
                      ((symbol-function 'md-render--mermaid-browser)
                       (lambda () "/fake/chrome"))
                      ((symbol-function 'make-process)
                       (lambda (&rest arguments)
                         (setq process-arguments arguments)
                         (setq process-browser
                               (getenv "PUPPETEER_EXECUTABLE_PATH"))
                         'fake-process)))
              (insert "```mermaid\ngraph TD\n  A --> B\n```\n")
              (md-render-replace-markup :force t :render-images nil)
              (should process-arguments)
              (let ((command (plist-get process-arguments :command)))
                (should (equal (car command) "/fake/mmdc"))
                (should (equal (cadr (member "--scale" command)) "1")))
              (should (equal process-browser "/fake/chrome"))
              (should (functionp
                       (plist-get process-arguments :sentinel))))))
      (delete-directory cache-directory t))))

(ert-deftest md-render-fenced-diagram-backends-use-svg-caches ()
  (let ((md-render-cache-directory temporary-file-directory))
    (should
     (eq (md-render--fenced-media-backend
          "plantuml" '(plantuml graphviz))
         'plantuml))
    (should
     (eq (md-render--fenced-media-backend
          "puml" '(plantuml graphviz))
         'plantuml))
    (should
     (eq (md-render--fenced-media-backend
          "dot" '(plantuml graphviz))
         'graphviz))
    (should
     (eq (md-render--fenced-media-backend
          "graphviz" '(plantuml graphviz))
         'graphviz))
    (should
     (string-suffix-p
      ".svg"
      (md-render--media-cache-file 'plantuml "@startuml\n@enduml")))
    (should
     (string-suffix-p
      ".svg"
      (md-render--media-cache-file 'graphviz "digraph { a -> b }")))))

(ert-deftest md-render-cached-local-diagrams-display-and-reconstruct ()
  (dolist (case '(("plantuml" plantuml "plantuml"
                   "@startuml\nAlice -> Bob\n@enduml")
                  ("dot" graphviz "dot"
                   "digraph { a -> b }")))
    (pcase-let ((`(,language ,backend ,command ,body) case))
      (with-temp-buffer
        (let ((md-render-math-enabled nil)
              (md-render-mermaid-enabled nil)
              (md-render-plantuml-enabled (eq backend 'plantuml))
              (md-render-graphviz-enabled (eq backend 'graphviz))
              (md-render-render-functions '(md-render--render-media)))
          (cl-letf (((symbol-function 'executable-find)
                     (lambda (candidate)
                       (and (equal candidate command)
                            (concat "/fake/" candidate))))
                    ((symbol-function 'display-graphic-p)
                     (lambda (&rest _) t))
                    ((symbol-function 'file-exists-p)
                     (lambda (_file) t))
                    ((symbol-function 'create-image)
                     (lambda (&rest _) '(image :type svg :fake t))))
            (insert (format "```%s\n%s\n```\n" language body))
            (let ((source (buffer-string)))
              (md-render-replace-markup :force t :render-images nil)
              (should
               (equal (md-render-reconstruct (point-min) (point-max))
                      source))
              (goto-char (point-min))
              (search-forward " ")
              (should
               (equal (get-text-property (1- (point)) 'display)
                      '(image :type svg :fake t)))
              (should
               (string-suffix-p
                ".svg"
                (get-text-property
                 (1- (point)) 'md-render-media-file))))))))))

(ert-deftest md-render-local-diagram-processes-use-official-cli-shapes ()
  (let ((cache-directory (make-temp-file "md-render-diagrams-" t)))
    (unwind-protect
        (dolist (case '((plantuml "plantuml" ".svg")
                        (graphviz "dot" ".svg")))
          (pcase-let ((`(,backend ,executable ,extension) case))
            (let* ((md-render-cache-directory cache-directory)
                   (md-render-plantuml-command "plantuml")
                   (md-render-graphviz-command "dot")
                   (file (expand-file-name
                          (concat (symbol-name backend) extension)
                          cache-directory))
                   process-arguments
                   plantuml-security-profile
                   graphviz-server-name)
              (cl-letf (((symbol-function 'executable-find)
                         (lambda (candidate)
                           (and (equal candidate executable)
                                (concat "/fake/" candidate))))
                        ((symbol-function 'md-render--theme-foreground)
                         (lambda () "#123456"))
                        ((symbol-function 'make-process)
                         (lambda (&rest arguments)
                           (setq process-arguments arguments)
                           (setq plantuml-security-profile
                                 (getenv "PLANTUML_SECURITY_PROFILE"))
                           (setq graphviz-server-name
                                 (getenv "SERVER_NAME"))
                           'fake-process)))
                (md-render--start-media-process backend "source" file)
                (let ((command (plist-get process-arguments :command)))
                  (should (equal (car command)
                                 (concat "/fake/" executable)))
                  (pcase backend
                    ('plantuml
                     (should (equal (cadr command) "-tsvg"))
                     (should
                      (equal plantuml-security-profile "SANDBOX")))
                    ('graphviz
                     (should (equal
                              (list (cadr command)
                                    (car (last command 2)))
                              (list "-Tsvg" "-o")))
                     (should
                      (member "-Gbgcolor=transparent" command))
                     (should
                      (member "-Ncolor=#123456" command))
                     (should
                      (member "-Nfontcolor=#123456" command))
                     (should
                      (member "-Ecolor=#123456" command))
                     (should
                      (member "-Efontcolor=#123456" command))
                     (should
                      (equal graphviz-server-name "md-render")))))))))
      (delete-directory cache-directory t))))

(ert-deftest md-render-math-without-tools-preserves-literal-source ()
  (with-temp-buffer
    (let ((md-render-math-enabled t)
          (md-render-render-functions '(md-render--render-media)))
      (cl-letf (((symbol-function 'display-graphic-p)
                 (lambda (&rest _) t))
                ((symbol-function 'executable-find)
                 (lambda (_command) nil)))
        (insert "before \\(a_b\\) after")
        (md-render-replace-markup :force t :render-images nil)
        (should (equal (buffer-string) "before \\(a_b\\) after"))
        (search-backward "\\(a_b\\)")
        (should (get-text-property (point) 'md-render-frozen))))))

(provide 'md-render-tests)

;;; md-render-tests.el ends here
