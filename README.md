# markdown

[![CI](https://github.com/alexisbcz/odin-markdown/actions/workflows/ci.yml/badge.svg)](https://github.com/alexisbcz/odin-markdown/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Odin](https://img.shields.io/badge/Odin-dev--2026--09-1e5a99.svg)](https://odin-lang.org)
[![CommonMark](https://img.shields.io/badge/CommonMark-0.31.2-brightgreen.svg)](https://spec.commonmark.org/0.31.2/)

A CommonMark Markdown to HTML renderer for Odin. It passes all 652 examples of the CommonMark 0.31.2 spec, adds optional GitHub Flavored Markdown tables and strikethrough, and depends on nothing outside `core`.

## Install

The repository root is the package, so you can vendor it in two ways.

As a Git submodule inside your project:

```sh
git submodule add https://github.com/alexisbcz/odin-markdown libs/markdown
```

```odin
import "libs/markdown"
```

As a copy in a shared collection that all your projects use:

```sh
git clone https://github.com/alexisbcz/odin-markdown ~/odin-shared/markdown
odin build . -collection:shared=$HOME/odin-shared
```

```odin
import "shared:markdown"
```

## Quick start

```odin
package main

import "core:fmt"
import "shared:markdown"

main :: proc() {
	html, err := markdown.to_html("# Hello\n\nSome *emphasis* and ~~strikethrough~~.\n", {extensions = markdown.GFM})
	if err != nil {
		fmt.eprintln("render failed:", err)
		return
	}
	defer delete(html)
	fmt.print(html)
}
```

The program prints:

```html
<h1>Hello</h1>
<p>Some <em>emphasis</em> and <del>strikethrough</del>.</p>
```

## Working with the syntax tree

Call `parse` to get a `Document`, walk or edit its nodes, then render it with `render_html` or throw it away. One call to `document_destroy` frees the whole tree.

```odin
package main

import "core:fmt"
import "shared:markdown"

main :: proc() {
	doc, err := markdown.parse("# Guide\n\n## Install\n\n## Usage\n")
	if err != nil {
		fmt.eprintln("parse failed:", err)
		return
	}
	defer markdown.document_destroy(doc)

	for node := doc.root.first_child; node != nil; node = node.next {
		if node.kind == .Heading && node.first_child != nil {
			fmt.println(node.level, node.first_child.literal)
		}
	}
}
```

Each `Node` has a `kind`, links to its parent, children and siblings, and the fields that apply to its kind: `literal` for text and code, `destination` and `title` for links and images, `level` for headings, `list` for lists and `info` for fenced code. Block nodes also record their `start_line` and `end_line` in the source.

## Options

| Field | Default | Effect |
| --- | --- | --- |
| `extensions` | `{}` | `.Tables` and `.Strikethrough`, or `markdown.GFM` for both. |
| `safe` | `false` | Replace raw HTML with `<!-- raw HTML omitted -->` and drop `javascript:`, `vbscript:`, `file:` and non-image `data:` URLs. |
| `max_nesting` | `256` | Deepest allowed nesting of block quotes and list items. Deeper input fails with `.Nesting_Too_Deep`. |

The zero value is strict CommonMark with raw HTML passed through, as the spec requires. Turn on `safe` when you render text from people you don't trust.

## API overview

| Declaration | Purpose | Allocates | Free with |
| --- | --- | --- | --- |
| `to_html(input, options, allocator)` | Convert Markdown to an HTML string | Yes | `delete` |
| `parse(input, options, allocator)` | Build a `Document` without rendering it | Yes | `document_destroy` |
| `render_html(doc, allocator)` | Render a whole `Document` with its options | Yes | `delete` |
| `render_node_html(node, options, allocator)` | Render one node and its descendants | Yes | `delete` |
| `document_destroy(doc)` | Free a `Document` and every node in it | No | Not needed |
| `Node`, `Node_Kind`, `List_Info`, `Alignment` | The syntax tree | No | Not needed |
| `Options`, `Extension`, `Extensions`, `GFM` | Parsing and rendering settings | No | Not needed |
| `Error` | Union of `Markdown_Error` and `runtime.Allocator_Error` | No | Not needed |

## Conformance

- CommonMark 0.31.2: all 652 spec examples pass byte for byte, including tabs, lazy continuation lines, list tightness, the seven kinds of HTML blocks, link reference definitions, the emphasis delimiter rules and all 2,125 HTML5 named entities.
- GitHub Flavored Markdown: pipe tables with alignment, escaped pipes and ragged rows, and strikethrough with one or two tildes. The other GFM extensions, such as task lists, extended autolinks and footnotes, aren't implemented yet.
- The parser guards against pathological input. Deeply nested brackets, emphasis, backticks and unclosed raw HTML run in linear or near-linear time, and the renderer walks the tree without recursion.
- Like `cmark`, the parser sets two limits that the spec permits. A link destination may nest at most 32 levels of parentheses. A GFM table stops after it adds 524,288 (`0x80000`) empty cells to pad short rows, as in `cmark-gfm`.
- A few cases that the spec examples don't cover follow `cmark` and `commonmark.js`. For example, a lone `</pre>` line starts an HTML block.

## Examples

Each directory under `examples/` is a runnable program:

```sh
odin run examples/basic   # render a document with tables and strikethrough
odin run examples/toc     # walk the syntax tree to print a table of contents
```

## Design notes

- Every allocating procedure takes `allocator := context.allocator` and says who owns the result.
- A `Document` keeps all its nodes and strings in an arena built on your allocator, so parsing makes few calls to it and `document_destroy` frees everything at once. The arena never allocates while it frees, so even an allocation failure part way through leaks nothing.
- Fallible procedures return `(T, Error)`. The library never panics on bad input: NUL bytes and invalid UTF-8 become U+FFFD.
- The package keeps no global mutable state, so it's safe to use from several threads as long as each `Document` stays on one thread.

## Testing

```sh
odin check . -vet -strict-style -disallow-do -no-entry-point
odin test tests -vet -strict-style -disallow-do
vale sync && vale *.md
```

The suite runs every CommonMark spec example, one test per spec section, plus focused tests for the extensions, safe mode, the syntax tree, error values and pathological input. One test fails every allocation in turn and checks with a tracking allocator that nothing leaks. The spec examples in `tests/testdata/` come from the [CommonMark Spec](https://spec.commonmark.org/0.31.2/) by John MacFarlane, licensed under CC BY-SA 4.0.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md). Commits follow Conventional Commits, and every change that users can see gets a line in [CHANGELOG.md](CHANGELOG.md).

## License

MIT. See [LICENSE](LICENSE). The CommonMark spec examples under `tests/testdata/` keep their own CC BY-SA 4.0 license.
