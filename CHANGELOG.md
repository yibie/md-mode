# Changelog

## Unreleased

### Fixed

- Keep graphical tables within the available window width when column
  wrapping is enabled, even when their combined word-preserving column
  widths would exceed it. Long words now wrap inside their cells as needed,
  while short columns remain compact.
- Preserve complete graphemes and cell contents while shrinking columns.
  Windows too narrow to fit the graphemes, cell padding and borders can
  still overflow rather than truncate content.
- Limit Mermaid, PlantUML and Graphviz previews by
  `md-render-image-max-width` instead of a fixed 90% of the window width
  (#15).

### Tests

- Add regression coverage for eight-column tables with long identifiers
  and CJK text, including width limits, border alignment and content
  preservation, plus combined emoji at physically impossible widths.
- Check that diagram previews respect `md-render-image-max-width`.
