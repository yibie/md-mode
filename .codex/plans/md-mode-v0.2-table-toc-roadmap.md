# md-mode v0.2.0 Table and TOC — Work Plan

## TL;DR (For humans)

- **What you'll get**: One `v0.2.0` release with complete table lifecycle commands and a live Markdown heading TOC in a side window.
- **Approach**: Reuse the existing table formatter and Outline parser, expose one shared heading index to completion, Imenu, and the TOC, and build the sidebar from stock Emacs `special-mode` and side-window APIs.
- **What it will NOT do**: Import CSV/TSV, evaluate table formulas, support separator-less pipe blocks, index multiple files, parse Setext headings, or automatically track the currently active section.
- **Decisions I made**: Use no new dependencies; keep the implementation in `md-mode.el`; bind `C-c |` to create or align a table and `C-c C-t` to toggle the TOC; expose whole-table deletion through `M-x md-mode-delete-table` without a default destructive key binding.

## Grounding

- Table parsing and formatting already live in `md-mode.el`, especially `md-mode--table-bounds`, `md-mode--format-table`, and `md-mode--replace-table-rows`.
- Row and column insertion, deletion, and movement already work. The missing lifecycle operations are creating and deleting a complete table.
- Heading parsing already lives in `md-mode--outline-search`, and `md-mode--heading-candidates` already feeds `md-mode-goto-heading`.
- Rendered View removes the visible heading markers, so the shared heading collector must understand both editable ATX headings and rendered headings carrying `md-render-source`.
- Emacs 29.1 already provides Imenu, `special-mode`, markers, text-property keymaps, and `display-buffer-in-side-window`.
- Reference implementations:
  - [Emacs Imenu](https://www.gnu.org/software/emacs/manual/html_node/elisp/Imenu.html)
  - [Emacs Side Windows](https://www.gnu.org/software/emacs/manual/html_node/elisp/Side-Windows.html)
  - [imenu-list](https://github.com/bmag/imenu-list)
  - [markdown-mode](https://github.com/jrblevin/markdown-mode)

## Scope

### In

- Create a standard Markdown table from a `columns × body rows` size.
- Delete the complete standard Markdown table at point.
- Keep existing row/column editing, auto-alignment, overflow handling, and source-preserving rendering unchanged.
- Build one structured heading-entry API for Edit View and Rendered View.
- Add nested Imenu integration.
- Add a per-source-buffer TOC side window with hierarchical headings and jump actions.
- Refresh the TOC after edits and explicit source/render transitions.
- Clean up windows, hooks, timers, buffers, and markers when either buffer or the major mode exits.
- Document the new commands and bump the package version to `0.2.0`.

### Out

- CSV, TSV, or region-to-table conversion.
- Table formulas, sorting, spreadsheet operations, or `org-table` reuse.
- Separator-less pipe-block creation/deletion.
- Setext headings.
- Multi-file or project-wide TOC.
- Automatic current-section tracking in the TOC.
- New runtime dependencies.
- Creating a Git tag or GitHub Release.

## Public Interaction Contract

### Tables

- `M-x md-mode-insert-table` prompts for `columns × body rows`, defaulting to `3 × 2`.
- The generated table contains a header, separator, and the requested number of empty body rows.
- Point lands in the first header cell.
- `M-x md-mode-delete-table` removes the complete table at point without consuming unrelated surrounding blank lines.
- Both operations signal `user-error` in Rendered View; deletion also signals `user-error` outside a standard Markdown table.
- `C-c |` creates a table outside a table and aligns the current table inside one.

### TOC

- `C-c C-t` and `M-x md-mode-toggle-toc` toggle the current Markdown buffer's TOC.
- The TOC opens on the left, 30 columns wide by default.
- `md-mode-toc-side` and `md-mode-toc-width` allow users to change those defaults.
- Entries are indented by ATX heading level and exclude headings inside fenced code blocks.
- `RET` and `mouse-1` jump to the source heading and reveal it if folded.
- `g` refreshes and `q` closes the TOC.
- Duplicate heading names remain distinct because entries target markers rather than title strings.
- The TOC works in both Edit View and Rendered View.

## Task Dependency Graph

| Task | Depends On | Blocks | Reason |
|---|---|---|---|
| 1. Complete table lifecycle | None | 5, 6 | Independent use of the existing table engine |
| 2. Unify heading indexing and Imenu | None | 3, 4, 5, 6 | One heading source of truth is required before building UI |
| 3. Build the TOC side window | 2 | 4, 5, 6 | UI consumes structured heading entries |
| 4. Add refresh and lifecycle handling | 2, 3 | 5, 6 | Requires the final TOC buffer and jump model |
| 5. Document and version the release | 1, 4 | 6 | Documentation must reflect finished interactions |
| 6. Run release verification | 1, 2, 3, 4, 5 | None | Final evidence covers the integrated release |

## Parallel Execution Waves

```text
Wave 1:
├── Task 1: Complete table lifecycle
└── Task 2: Unify heading indexing and Imenu

Wave 2:
└── Task 3: Build the TOC side window

Wave 3:
└── Task 4: Add refresh and lifecycle handling

Wave 4:
└── Task 5: Document and version the release

Wave 5:
└── Task 6: Run release verification
```

## Tasks

### Task 1: Complete table lifecycle

- **What**:
  - Add public autoloaded `md-mode-insert-table`.
  - Parse and validate positive `columns × body rows` input.
  - Construct the row data expected by `md-mode--format-table`; do not add another table formatter.
  - Insert the table at point, preserve surrounding text, fontify it, and move point to the first header cell.
  - Add public autoloaded `md-mode-delete-table` using `md-mode--table-bounds`.
  - Add `md-mode-table`, bound to `C-c |`, to align at point or interactively create outside a table.
  - Mirror the new non-destructive binding in the Hel normal-state keymap.
- **Files**:
  - `md-mode.el`
  - `test/md-mode-tests.el`
- **Agent**: `executor` — small public-command implementation with behavioral tests.
- **Skills**: `tdd` — lock insertion, deletion, point placement, and error behavior before implementation.
- **Depends**: None.
- **Blocks**: Tasks 5 and 6.
- **Acceptance**:
  - Default creation produces a valid 3-column table with two body rows.
  - Explicit sizes produce the requested dimensions.
  - The created separator is standard Markdown and is recognized by `md-mode--table-bounds`.
  - Deletion removes exactly the detected table and is undoable.
  - Code fences, surrounding blank lines, indentation, and EOF without a newline are covered.
  - Invalid sizes, Rendered View edits, deletion outside a table, and deletion of a separator-less pipe block signal `user-error`.
  - Existing row/column operations and the “do not load `org-table`” test still pass.
- **QA**:
  - Happy path: run focused ERT selectors for table creation, whole-table deletion, alignment, and row/column editing.
  - Failure path: run focused ERT selectors for invalid dimensions, non-table deletion, Rendered View, fenced code, and separator-less input.
- **Commit**: `Make complete table lifecycle operations first-class`

### Task 2: Unify heading indexing and Imenu

- **What**:
  - Replace the one-use candidate scan with one structured heading collector containing title, level, and target marker.
  - In Edit View, reuse `md-mode--outline-search`; do not duplicate the fenced-code exclusion logic.
  - In Rendered View, scan `md-render-source` properties and accept only source strings matching ATX headings.
  - Refactor `md-mode--heading-candidates` and `md-mode-goto-heading` to consume the shared entries.
  - Build a nested Imenu alist from the same entries and set `imenu-create-index-function` buffer-locally in `md-mode`.
- **Files**:
  - `md-mode.el`
  - `test/md-mode-tests.el`
- **Agent**: `executor` — shared data-path refactor with compatibility tests.
- **Skills**: `tdd` — protect existing navigation while adding Edit/View and Imenu cases.
- **Depends**: None.
- **Blocks**: Tasks 3, 4, 5, and 6.
- **Acceptance**:
  - Existing `C-c C-j` behavior remains unchanged.
  - Nested Imenu represents heading hierarchy without losing duplicate titles.
  - Headings inside fenced blocks never appear.
  - Empty buffers and documents with skipped heading levels produce valid empty/nested indexes.
  - Edit View and Rendered View return the same ordered title/level sequence.
  - All stored target markers point into the correct source buffer.
- **QA**:
  - Happy path: ERT for nested ATX headings, duplicate titles, completion candidates, Imenu, and View parity.
  - Failure path: ERT for empty input, fenced pseudo-headings, killed markers, and malformed rendered source properties.
- **Commit**: `Give every heading consumer one source of truth`

### Task 3: Build the TOC side window

- **What**:
  - Add `md-mode-toc-side` and `md-mode-toc-width` customizations.
  - Add an internal `md-mode--toc-mode` derived from `special-mode`.
  - Give each source buffer its own TOC buffer and keep reciprocal buffer-local references.
  - Render hierarchical entries with target markers stored as text properties.
  - Add `RET`, `mouse-1`, `g`, and `q` interactions.
  - Add public autoloaded `md-mode-toggle-toc`, bind it to `C-c C-t`, and mirror the binding in the Hel normal-state keymap.
  - Display the TOC with `display-buffer-in-side-window`; do not mutate global `display-buffer-alist`.
- **Files**:
  - `md-mode.el`
  - `test/md-mode-tests.el`
- **Agent**: `executor` — implements the user-facing side-window UI.
- **Skills**: `tdd` — test the buffer model and jump target separately from visual presentation.
- **Depends**: Task 2.
- **Blocks**: Tasks 4, 5, and 6.
- **Acceptance**:
  - One TOC buffer is created per source buffer and toggling does not create duplicates.
  - The side window honors the configured side and width.
  - Visual indentation matches heading levels.
  - `RET` and `mouse-1` select the source window, jump to the exact marker, and reveal folded content.
  - `g` refreshes without changing the source buffer.
  - `q` closes only the relevant TOC window.
  - A dead source buffer produces a clear message and no error cascade.
- **QA**:
  - Happy path: ERT under `save-window-excursion` for toggle, hierarchy, jump, refresh, and close.
  - Failure path: ERT for empty documents, killed source buffers, dead markers, duplicate TOC toggles, and missing source windows.
- **Commit**: `Make Markdown structure visible beside the document`

### Task 4: Add refresh and lifecycle handling

- **What**:
  - Mark an open TOC dirty from the source buffer's `after-change-functions`.
  - Refresh once from a buffer-local `post-command-hook` only when dirty; do not rescan synchronously for every change.
  - Guard refresh against recursive changes and release old markers before rebuilding.
  - Explicitly refresh after `md-mode-render` and `md-mode-show-source`.
  - Close and detach the TOC on source-buffer kill or major-mode change.
  - Clear reciprocal references when the TOC buffer is killed directly.
  - Leave rendered-table reflow behavior unchanged when the sidebar changes window width.
- **Files**:
  - `md-mode.el`
  - `test/md-mode-tests.el`
- **Agent**: `executor` — owns buffer/window lifecycle and state transitions.
- **Skills**: `tdd`, `diagnosing-bugs` — lifecycle paths need regression tests and disciplined failure isolation.
- **Depends**: Tasks 2 and 3.
- **Blocks**: Tasks 5 and 6.
- **Acceptance**:
  - Heading edits refresh the TOC once after the editing command.
  - Non-heading edits do not corrupt or duplicate entries.
  - `C-c C-v` preserves a working TOC in both directions.
  - No stale hook, timer, TOC buffer, side window, or live marker remains after cleanup.
  - Refresh tests call synchronous helpers directly and do not sleep or depend on timer timing.
  - Opening or closing the TOC still triggers the existing table-overflow window refresh without changing Markdown source.
- **QA**:
  - Happy path: ERT for heading insert/rename/delete, source/render toggle, and manual refresh.
  - Failure path: ERT for rapid edits, source kill, TOC kill, major-mode change, repeated cleanup, and marker invalidation.
- **Commit**: `Keep the TOC correct across edits and view changes`

### Task 5: Document and version the release

- **What**:
  - Update the package version from `0.1.0` to `0.2.0`.
  - Add table creation/deletion and TOC usage to Quick Start and Key Bindings.
  - Document `md-mode-toc-side`, `md-mode-toc-width`, Edit/View support, and the ATX-only boundary.
  - Update the feature comparison without implying that `md-mode` replaces `markdown-mode` or `imenu-list`.
  - Keep the README concise; do not create a changelog framework for one release.
- **Files**:
  - `md-mode.el`
  - `README.md`
- **Agent**: `writer` — concise user-facing documentation and release wording.
- **Skills**: `edit-article` — keep the README coherent and avoid repeating the feature list.
- **Depends**: Tasks 1 and 4.
- **Blocks**: Task 6.
- **Acceptance**:
  - Every new public command, default key, and customization is documented.
  - Installation instructions remain correct.
  - Current limitations are explicit.
  - The version header is `0.2.0`.
- **QA**:
  - Happy path: follow README steps in a clean Emacs session and exercise both workflows.
  - Failure path: verify no documented command or key is missing from the package.
- **Commit**: `Make the v0.2 workflows discoverable`

### Task 6: Run release verification

- **What**:
  - Run the complete ERT suite.
  - Byte-compile distributable Elisp with warnings treated as errors.
  - Run Checkdoc on both distributable files.
  - Run package-lint with `md-mode.el` configured as the split package's main file.
  - Manually verify table creation/deletion and the TOC in Edit View and Rendered View.
  - Run the project visual-verdict gate on the TOC sidebar and persist its ignored state JSON under `.omx/state/md-mode-v0.2/`.
  - Review the final diff for accidental new dependencies, global side effects, or duplicate parsing.
- **Files**:
  - No planned product-file changes; fixes remain in the task that introduced the failure.
- **Agent**: `verifier` — independent completion evidence.
- **Skills**: `visual-verdict`, `code-review` — visual acceptance and final standards review.
- **Depends**: Tasks 1 through 5.
- **Blocks**: None.
- **Acceptance**:
  - All ERT tests pass.
  - Byte compilation, Checkdoc, and package-lint produce zero warnings.
  - Visual-verdict scores at least 90.
  - Edit/View source round-tripping remains exact.
  - `org-table` is not loaded.
  - The final worktree contains no generated `.elc`, demo source, or `.omx` state.
- **QA**:
  - Happy path: execute all automated and manual gates listed below.
  - Failure path: rerun the narrowest failing selector after each fix, then rerun the full gate.
- **Commit**: No commit unless verification finds a defect; put each fix in the owning task's commit.

## Verification Strategy

### Unit and integration

```sh
emacs -Q --batch \
  --eval '(setq native-comp-jit-compilation nil
                native-comp-enable-subr-trampolines nil
                comp-enable-subr-trampolines nil)' \
  -L . -L test \
  -l test/md-render-tests.el \
  -l test/md-mode-tests.el \
  -f ert-run-tests-batch-and-exit
```

### Byte compilation

- Compile `md-render.el` and `md-mode.el` with `byte-compile-error-on-warn` set to non-nil.
- Write `.elc` output outside the repository.

### Checkdoc

- Run `checkdoc-file` for `md-render.el` and `md-mode.el`.
- Accept no warnings.

### Package lint

- Set `package-lint-main-file` to `md-mode.el`.
- Lint both `md-mode.el` and `md-render.el`.
- Accept no warnings or errors.

### Manual and visual

- Create and delete tables at BOB, mid-buffer, EOF, and beside surrounding prose.
- Toggle the TOC repeatedly in Edit View and Rendered View.
- Resize the frame and switch buffers while the TOC is open.
- Confirm jump targets, folded-heading reveal, cleanup, and table overflow behavior.
- Capture the TOC beside a representative Markdown document and require visual-verdict `score >= 90`.

## Commit Strategy

- One atomic Lore commit per implementation task.
- Each commit leaves the complete existing suite passing.
- Commit subjects describe intent rather than listing changed files.
- Include useful Lore trailers:
  - `Constraint:` Emacs 29.1 and no new dependencies.
  - `Rejected:` duplicate table or heading parser, with the reason.
  - `Confidence:` and `Scope-risk:`.
  - `Directive:` preserve source round-tripping and per-buffer cleanup.
  - `Tested:` focused and full verification evidence.
  - `Not-tested:` any remaining platform or graphical-environment gaps.

## Success Criteria

- [ ] `v0.2.0` contains both table lifecycle and TOC sidebar features.
- [ ] A table can be created, aligned, structurally edited, and deleted without `org-table`.
- [ ] The TOC shows the correct ATX hierarchy and jumps reliably.
- [ ] Completion, Imenu, and TOC use one heading-entry source.
- [ ] Edit View and Rendered View expose the same TOC structure.
- [ ] Buffer/window lifecycle leaves no stale state.
- [ ] README and package version match the shipped interactions.
- [ ] Full ERT, byte compilation, Checkdoc, package-lint, and visual QA pass.
