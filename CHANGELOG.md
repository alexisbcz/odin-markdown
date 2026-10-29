# Changelog

This file records all notable changes to this project.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/alexisbcz/odin-markdown/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/alexisbcz/odin-markdown/releases/tag/v0.1.0
