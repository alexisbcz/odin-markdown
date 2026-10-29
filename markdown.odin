/*
Package markdown renders CommonMark 0.31.2 Markdown to HTML.

It implements the whole CommonMark block and inline grammar, including tabs,
lazy continuation lines, tight and loose lists, HTML blocks, link reference
definitions, the emphasis delimiter algorithm and all HTML5 named entities. Two
GitHub Flavored Markdown extensions are available behind `Options.extensions`:
pipe tables and strikethrough.

Use to_html for a one-shot conversion. Use parse, render_html and
document_destroy when you want to inspect or change the syntax tree first.

Example:
	import "shared:markdown"

	main :: proc() {
		html, err := markdown.to_html("# Hello\n\nSome *emphasis*.\n")
		if err != nil {
			return
		}
		defer delete(html)
	}

Every procedure is safe to call from several threads at once, because the
package keeps no global mutable state. A Document is safe to use from one
thread at a time.
*/
package markdown

import "base:runtime"

// Extension names one optional syntax extension from GitHub Flavored Markdown.
Extension :: enum {
	// Pipe tables with a delimiter row, for example `| a | b |` over `| --- | :-: |`.
	Tables,
	// Strikethrough with one or two tildes, for example `~~gone~~`.
	Strikethrough,
}

// Extensions is a set of enabled syntax extensions. The empty set means strict CommonMark.
Extensions :: bit_set[Extension]

// GFM enables every supported GitHub Flavored Markdown extension.
GFM :: Extensions{.Tables, .Strikethrough}

// DEFAULT_MAX_NESTING is the container depth limit used when `Options.max_nesting` is 0.
DEFAULT_MAX_NESTING :: 256

/*
Options controls parsing and rendering. The zero value means strict CommonMark
with raw HTML passed through, which is what the CommonMark spec tests expect.
*/
Options :: struct {
	// extensions enables optional GitHub Flavored Markdown syntax.
	extensions:  Extensions,
	/*
	safe replaces raw HTML with `<!-- raw HTML omitted -->` and drops link and
	image destinations that use the `javascript:`, `vbscript:`, `file:` or
	`data:` schemes, except `data:image/png`, `gif`, `jpeg` and `webp`.
	Turn it on when rendering text from people you don't trust.
	*/
	safe:        bool,
	/*
	max_nesting limits how deeply block quotes and list items may nest. Input
	that nests deeper fails with `.Nesting_Too_Deep` instead of using
	unbounded memory. 0 means DEFAULT_MAX_NESTING.
	*/
	max_nesting: int,
}

// Markdown_Error lists the ways parsing can fail other than running out of memory.
Markdown_Error :: enum {
	None,
	// Block quotes and list items nest deeper than `Options.max_nesting` allows.
	Nesting_Too_Deep,
}

/*
Error is the error type returned by every fallible procedure in this package.
`nil` means success. Any input text is valid Markdown, so the only failures
are hitting the nesting limit and allocator errors.
*/
Error :: union #shared_nil {
	Markdown_Error,
	runtime.Allocator_Error,
}

// Node_Kind identifies what a Node represents. Block kinds come first, then inline kinds.
Node_Kind :: enum {
	// The root of every tree. Its children are blocks.
	Document,
	// A `>` block quote. Its children are blocks.
	Block_Quote,
	// A bullet or ordered list. Its children are Item nodes; see `Node.list`.
	List,
	// One list item. Its children are blocks.
	Item,
	// A paragraph. Its children are inlines.
	Paragraph,
	// An ATX or setext heading with `Node.level` from 1 to 6. Its children are inlines.
	Heading,
	// A fenced or indented code block. The code is in `Node.literal`, the info string in `Node.info`.
	Code_Block,
	// A raw HTML block, kept verbatim in `Node.literal`.
	Html_Block,
	// A thematic break, rendered as `<hr />`.
	Thematic_Break,
	// A GFM table. Its children are Table_Row nodes, the first of which is the header row.
	Table,
	// One table row. `Node.header` is true for the header row. Its children are Table_Cell nodes.
	Table_Row,
	// One table cell with `Node.alignment`. Its children are inlines.
	Table_Cell,
	// Literal text in `Node.literal`, with escapes and entities already decoded.
	Text,
	// A line ending inside a paragraph that renders as a newline.
	Soft_Break,
	// A hard line break, rendered as `<br />`.
	Line_Break,
	// A code span. The code is in `Node.literal`.
	Code,
	// Emphasis, rendered as `<em>`.
	Emphasis,
	// Strong emphasis, rendered as `<strong>`.
	Strong,
	// GFM strikethrough, rendered as `<del>`.
	Strikethrough,
	// A link to `Node.destination` with an optional `Node.title`. Its children are the link text.
	Link,
	// An image of `Node.destination` with an optional `Node.title`. Its children are the description.
	Image,
	// Raw inline HTML, kept verbatim in `Node.literal`.
	Html_Inline,
}

// List_Kind tells bullet lists from ordered lists.
List_Kind :: enum {
	Bullet,
	Ordered,
}

// List_Info describes a List node and each of its Item nodes.
List_Info :: struct {
	// kind is .Bullet or .Ordered.
	kind:      List_Kind,
	// tight is true when no blank line separates the items or their children, so paragraphs render without `<p>`.
	tight:     bool,
	// start is the number of the first item of an ordered list.
	start:     int,
	// delimiter is `.` or `)` for ordered lists, 0 for bullet lists.
	delimiter: byte,
	// bullet is `-`, `+` or `*` for bullet lists, 0 for ordered lists.
	bullet:    byte,
}

// Alignment is the column alignment of a GFM table cell.
Alignment :: enum {
	None,
	Left,
	Center,
	Right,
}

/*
Node is one element of the syntax tree. Children form a doubly linked list
through `first_child`, `last_child`, `prev` and `next`.

Every string in a Node, and the Node itself, lives in the memory of the
Document that owns it, so don't keep them after document_destroy. You may
relink nodes and replace strings, as long as new strings outlive the Document.
*/
Node :: struct {
	// kind says which of the other fields are meaningful.
	kind:        Node_Kind,
	// parent is nil only for the Document node.
	parent:      ^Node,
	// first_child is the first child, or nil.
	first_child: ^Node,
	// last_child is the last child, or nil.
	last_child:  ^Node,
	// prev is the previous sibling, or nil.
	prev:        ^Node,
	// next is the next sibling, or nil.
	next:        ^Node,
	// literal holds the content of Text, Code, Code_Block, Html_Block and Html_Inline nodes.
	literal:     string,
	// info is the info string after the opening fence of a fenced Code_Block, for example `odin`.
	info:        string,
	// destination is the URL of a Link or Image, already percent-encoded.
	destination: string,
	// title is the optional title of a Link or Image.
	title:       string,
	// level is the heading level, from 1 to 6.
	level:       int,
	// list describes List and Item nodes.
	list:        List_Info,
	// alignment is the column alignment of a Table_Cell.
	alignment:   Alignment,
	// header is true for the header Table_Row and its Table_Cell children.
	header:      bool,
	// start_line is the 1-based source line where a block starts. 0 for inline nodes.
	start_line:  int,
	// end_line is the 1-based source line where a block ends. 0 for inline nodes.
	end_line:    int,
	// state is parser bookkeeping. It isn't part of the API.
	state:       Block_State,
}

/*
Document owns a syntax tree and all of its memory. Create one with parse and
free it with document_destroy.
*/
Document :: struct {
	// root is the Document node.
	root:      ^Node,
	// options are the options the document was parsed with; render_html reuses them.
	options:   Options,
	// arena holds every node and string of the tree; document_destroy frees it in one go.
	arena:     Arena,
	// allocator is the allocator passed to parse. It backs the arena and the Document itself.
	allocator: runtime.Allocator,
}

/*
to_html converts Markdown `input` to an HTML fragment.

Inputs:
- input: Markdown text in UTF-8. Invalid bytes and NUL characters become U+FFFD.
- options: extensions and safety settings; the zero value is strict CommonMark.
- allocator: allocates the result and, temporarily, the syntax tree.

Returns:
- html: the rendered HTML, owned by the caller; free it with `delete(html, allocator)`.
- err: `.Nesting_Too_Deep` or an allocator error. On error `html` is empty and nothing leaks.

Example:
	html, err := markdown.to_html("~~old~~ new", {extensions = markdown.GFM})
	// html == "<p><del>old</del> new</p>\n"
*/
to_html :: proc(input: string, options := Options{}, allocator := context.allocator) -> (html: string, err: Error) {
	doc := parse(input, options, allocator) or_return
	defer document_destroy(doc)
	return render_html(doc, allocator)
}

/*
parse builds the syntax tree for `input` without rendering it.

Inputs:
- input: Markdown text in UTF-8. The Document copies what it needs, so you may free `input` right after the call.
- options: extensions and safety settings, stored in `doc.options`.
- allocator: allocates the Document and every node in it.

Returns:
- doc: the parsed Document, owned by the caller; free it with document_destroy.
- err: `.Nesting_Too_Deep` or an allocator error. On error `doc` is nil and nothing leaks.
*/
parse :: proc(input: string, options := Options{}, allocator := context.allocator) -> (doc: ^Document, err: Error) {
	doc = new(Document, allocator) or_return
	doc.allocator = allocator
	doc.options = options
	arena_init(&doc.arena, allocator)
	root, parse_err := parse_document(input, options, arena_allocator(&doc.arena))
	if parse_err != nil {
		document_destroy(doc)
		return nil, parse_err
	}
	doc.root = root
	return doc, nil
}

/*
document_destroy frees the Document and every node and string in it.
Passing nil does nothing.
*/
document_destroy :: proc(doc: ^Document) {
	if doc == nil {
		return
	}
	allocator := doc.allocator
	arena_destroy(&doc.arena)
	free(doc, allocator)
}

/*
render_html renders the tree of `doc` to HTML, using `doc.options`.

Returns:
- html: the rendered HTML, owned by the caller; free it with `delete(html, allocator)`.
- err: an allocator error. On error `html` is empty and nothing leaks.
*/
render_html :: proc(doc: ^Document, allocator := context.allocator) -> (html: string, err: Error) {
	if doc == nil || doc.root == nil {
		return "", nil
	}
	return render_node_html(doc.root, doc.options, allocator)
}

/*
render_node_html renders `node` and its descendants to HTML. Use it to render
part of a tree, for example a single list item.

Returns:
- html: the rendered HTML, owned by the caller; free it with `delete(html, allocator)`.
- err: an allocator error. On error `html` is empty and nothing leaks.
*/
render_node_html :: proc(node: ^Node, options := Options{}, allocator := context.allocator) -> (html: string, err: Error) {
	return render(node, options, allocator)
}
