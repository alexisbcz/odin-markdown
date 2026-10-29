# Changelog

This file records all notable changes to this project.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-10-29

### Fixed

- HTML blocks of types 1 to 5 keep the blank lines at their end, as `cmark` and `commonmark.js` do. They used to lose them at the end of the document or of their container.
- A line holding only `</pre>`, `</script>`, `</style>`, `</textarea>` or a self-closing `<pre/>` now starts a type 7 HTML block, as it does in `cmark` and `commonmark.js`, instead of a paragraph.
- A list item that starts with a link reference definition no longer looks empty. A second blank line no longer ends it early, and a blank line after the definition now makes the list loose.
- A GFM table stops after it has added 524,288 (`0x80000`) empty cells to pad short rows, the `cmark-gfm` limit. Before, 18 KB of input could render to 90 MB of HTML.
- Unclosed inline comments, processing instructions, CDATA sections and declarations no longer take quadratic time.
- Link destinations allow at most 32 levels of nested parentheses, as in `cmark`. This keeps runs of `[a](` linear.

## [0.1.0] - 2026-10-29

### Added

- `to_html` converts CommonMark 0.31.2 Markdown to HTML and passes all 652 spec examples.
- `parse`, `render_html`, `render_node_html` and `document_destroy` expose the syntax tree as linked `Node` values with source line numbers.
- Block parsing for ATX and setext headings, paragraphs, block quotes, tight and loose lists, fenced and indented code, thematic breaks, the seven kinds of HTML blocks and link reference definitions.
- Inline parsing for emphasis with the full delimiter algorithm, code spans, inline, reference and shortcut links, images, autolinks, raw HTML, backslash escapes, hard and soft line breaks, and all 2,125 HTML5 named entities.
- Optional GitHub Flavored Markdown pipe tables with column alignment, and strikethrough with one or two tildes.
- `Options.safe` omits raw HTML and drops `javascript:`, `vbscript:`, `file:` and non-image `data:` URLs.
- `Options.max_nesting` caps block nesting and reports `.Nesting_Too_Deep`.
- NUL bytes and invalid UTF-8 become U+FFFD instead of failing.
- Examples `basic` and `toc`.

[Unreleased]: https://github.com/alexisbcz/odin-markdown/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/alexisbcz/odin-markdown/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/alexisbcz/odin-markdown/releases/tag/v0.1.0
