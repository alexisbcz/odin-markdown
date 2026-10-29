// Package markdown_tests holds the unit tests for markdown. Run them with `odin test tests`.
package markdown_tests

import markdown ".."
import "core:mem"
import "core:strings"
import "core:testing"

// expect_html renders `input` with `options` and compares the result with `expected`.
expect_html :: proc(t: ^testing.T, input, expected: string, options := markdown.Options{}, loc := #caller_location) {
	html, err := markdown.to_html(input, options)
	defer delete(html)
	testing.expect_value(t, err, nil, loc)
	testing.expectf(t, html == expected, "\nmarkdown: %q\nexpected: %q\n     got: %q", input, expected, html, loc = loc)
}

GFM :: markdown.Options {
	extensions = markdown.GFM,
}

SAFE :: markdown.Options {
	safe = true,
}

// ---------------------------------------------------------------------------
// Basics and input handling

@(test)
test_empty_input_renders_nothing :: proc(t: ^testing.T) {
	expect_html(t, "", "")
	expect_html(t, "\n\n   \n", "")
}

@(test)
test_paragraph_and_heading :: proc(t: ^testing.T) {
	expect_html(t, "# Title\n\nSome *emphasis* and **strong** text.\n", "<h1>Title</h1>\n<p>Some <em>emphasis</em> and <strong>strong</strong> text.</p>\n")
}

@(test)
test_input_without_final_newline :: proc(t: ^testing.T) {
	expect_html(t, "a\nb", "<p>a\nb</p>\n")
}

@(test)
test_crlf_and_cr_line_endings :: proc(t: ^testing.T) {
	expect_html(t, "a\r\nb\r\n\r\nc", "<p>a\nb</p>\n<p>c</p>\n")
	expect_html(t, "a\rb\r\rc", "<p>a\nb</p>\n<p>c</p>\n")
	expect_html(t, "```\r\ncode\r\n```\r\n", "<pre><code>code\n</code></pre>\n")
}

@(test)
test_nul_becomes_replacement_character :: proc(t: ^testing.T) {
	expect_html(t, "a\x00b", "<p>a�b</p>\n")
}

@(test)
test_invalid_utf8_becomes_replacement_character :: proc(t: ^testing.T) {
	expect_html(t, "bad \xff\xfe byte", "<p>bad �� byte</p>\n")
	// A truncated multi-byte sequence at the very end.
	expect_html(t, "end \xe2\x82", "<p>end ��</p>\n")
}

@(test)
test_numeric_references_out_of_range :: proc(t: ^testing.T) {
	expect_html(t, "&#0; &#x110000; &#xD800;", "<p>� � �</p>\n")
}

@(test)
test_html_special_characters_are_escaped :: proc(t: ^testing.T) {
	expect_html(t, "5 > 3 & \"quotes\"", "<p>5 &gt; 3 &amp; &quot;quotes&quot;</p>\n")
}

@(test)
test_input_is_not_retained :: proc(t: ^testing.T) {
	source := strings.clone("# Kept\n\n[link](/url) and `code`\n")
	doc, err := markdown.parse(source)
	defer markdown.document_destroy(doc)
	testing.expect_value(t, err, nil)
	// Overwrite and free the input; the tree must not point into it.
	for i in 0 ..< len(source) {
		(transmute([]byte)source)[i] = 'x'
	}
	delete(source)
	html, render_err := markdown.render_html(doc)
	defer delete(html)
	testing.expect_value(t, render_err, nil)
	testing.expect_value(t, html, "<h1>Kept</h1>\n<p><a href=\"/url\">link</a> and <code>code</code></p>\n")
}

// ---------------------------------------------------------------------------
// GFM tables

@(test)
test_tables_are_off_by_default :: proc(t: ^testing.T) {
	expect_html(t, "| a | b |\n| - | - |\n", "<p>| a | b |\n| - | - |</p>\n")
}

@(test)
test_table_basic :: proc(t: ^testing.T) {
	expect_html(
		t,
		"| foo | bar |\n| --- | --- |\n| baz | bim |\n",
		"<table>\n<thead>\n<tr>\n<th>foo</th>\n<th>bar</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>baz</td>\n<td>bim</td>\n</tr>\n</tbody>\n</table>\n",
		GFM,
	)
}

@(test)
test_table_alignment :: proc(t: ^testing.T) {
	expect_html(
		t,
		"| abc | defghi | x |\n:-: | -----------: | :--\nbar | baz | y\n",
		"<table>\n<thead>\n<tr>\n<th align=\"center\">abc</th>\n<th align=\"right\">defghi</th>\n<th align=\"left\">x</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td align=\"center\">bar</td>\n<td align=\"right\">baz</td>\n<td align=\"left\">y</td>\n</tr>\n</tbody>\n</table>\n",
		GFM,
	)
}

@(test)
test_table_escaped_pipes :: proc(t: ^testing.T) {
	expect_html(
		t,
		"| f\\|oo  |\n| ------ |\n| b `\\|` az |\n| b **\\|** im |\n",
		"<table>\n<thead>\n<tr>\n<th>f|oo</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>b <code>|</code> az</td>\n</tr>\n<tr>\n<td>b <strong>|</strong> im</td>\n</tr>\n</tbody>\n</table>\n",
		GFM,
	)
}

@(test)
test_table_ends_at_block_quote :: proc(t: ^testing.T) {
	expect_html(
		t,
		"| abc | def |\n| --- | --- |\n| bar | baz |\n> bar\n",
		"<table>\n<thead>\n<tr>\n<th>abc</th>\n<th>def</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>bar</td>\n<td>baz</td>\n</tr>\n</tbody>\n</table>\n<blockquote>\n<p>bar</p>\n</blockquote>\n",
		GFM,
	)
}

@(test)
test_table_ends_at_blank_line :: proc(t: ^testing.T) {
	expect_html(
		t,
		"| abc | def |\n| --- | --- |\n| bar | baz |\nbar\n\nbar\n",
		"<table>\n<thead>\n<tr>\n<th>abc</th>\n<th>def</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>bar</td>\n<td>baz</td>\n</tr>\n<tr>\n<td>bar</td>\n<td></td>\n</tr>\n</tbody>\n</table>\n<p>bar</p>\n",
		GFM,
	)
}

@(test)
test_table_needs_matching_header :: proc(t: ^testing.T) {
	expect_html(t, "| abc | def |\n| --- |\n| bar |\n", "<p>| abc | def |\n| --- |\n| bar |</p>\n", GFM)
}

@(test)
test_table_pads_and_truncates_rows :: proc(t: ^testing.T) {
	expect_html(
		t,
		"| abc | def |\n| --- | --- |\n| bar |\n| bar | baz | boo |\n",
		"<table>\n<thead>\n<tr>\n<th>abc</th>\n<th>def</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>bar</td>\n<td></td>\n</tr>\n<tr>\n<td>bar</td>\n<td>baz</td>\n</tr>\n</tbody>\n</table>\n",
		GFM,
	)
}

@(test)
test_table_without_body :: proc(t: ^testing.T) {
	expect_html(
		t,
		"| abc | def |\n| --- | --- |\n",
		"<table>\n<thead>\n<tr>\n<th>abc</th>\n<th>def</th>\n</tr>\n</thead>\n</table>\n",
		GFM,
	)
}

@(test)
test_table_after_paragraph_lines :: proc(t: ^testing.T) {
	expect_html(
		t,
		"Intro text\n| a |\n| - |\n| 1 |\n",
		"<p>Intro text</p>\n<table>\n<thead>\n<tr>\n<th>a</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>1</td>\n</tr>\n</tbody>\n</table>\n",
		GFM,
	)
}

@(test)
test_setext_heading_still_wins_without_pipes :: proc(t: ^testing.T) {
	expect_html(t, "Title\n---\n", "<h2>Title</h2>\n", GFM)
}

// ---------------------------------------------------------------------------
// GFM strikethrough

@(test)
test_strikethrough :: proc(t: ^testing.T) {
	expect_html(t, "~~Hi~~ Hello, ~there~ world!\n", "<p><del>Hi</del> Hello, <del>there</del> world!</p>\n", GFM)
}

@(test)
test_strikethrough_does_not_span_paragraphs :: proc(t: ^testing.T) {
	expect_html(t, "This ~~has a\n\nnew paragraph~~.\n", "<p>This ~~has a</p>\n<p>new paragraph~~.</p>\n", GFM)
}

@(test)
test_strikethrough_needs_matching_runs :: proc(t: ^testing.T) {
	expect_html(t, "This will ~~~not~~~ strike.\n", "<p>This will ~~~not~~~ strike.</p>\n", GFM)
	expect_html(t, "~one~~\n", "<p>~one~~</p>\n", GFM)
}

@(test)
test_strikethrough_is_off_by_default :: proc(t: ^testing.T) {
	expect_html(t, "~~Hi~~\n", "<p>~~Hi~~</p>\n")
}

@(test)
test_strikethrough_nests_with_emphasis :: proc(t: ^testing.T) {
	expect_html(t, "~~*a* b~~ **~c~**\n", "<p><del><em>a</em> b</del> <strong><del>c</del></strong></p>\n", GFM)
}

// ---------------------------------------------------------------------------
// Safe mode

@(test)
test_safe_mode_omits_raw_html :: proc(t: ^testing.T) {
	expect_html(t, "<div>\n*hi*\n</div>\n\na <b>b</b>\n", "<!-- raw HTML omitted -->\n<p>a <!-- raw HTML omitted -->b<!-- raw HTML omitted --></p>\n", SAFE)
}

@(test)
test_safe_mode_drops_dangerous_urls :: proc(t: ^testing.T) {
	expect_html(
		t,
		"[a](javascript:alert(1)) [b](VBScript:x) [c](file:///etc/passwd) ![d](data:text/html,x)\n",
		"<p><a href=\"\">a</a> <a href=\"\">b</a> <a href=\"\">c</a> <img src=\"\" alt=\"d\" /></p>\n",
		SAFE,
	)
}

@(test)
test_safe_mode_keeps_safe_urls :: proc(t: ^testing.T) {
	expect_html(
		t,
		"[a](https://example.com) ![b](data:image/png;base64,AAAA)\n",
		"<p><a href=\"https://example.com\">a</a> <img src=\"data:image/png;base64,AAAA\" alt=\"b\" /></p>\n",
		SAFE,
	)
}

@(test)
test_unsafe_urls_pass_through_by_default :: proc(t: ^testing.T) {
	expect_html(t, "[a](javascript:x)\n", "<p><a href=\"javascript:x\">a</a></p>\n")
}

// ---------------------------------------------------------------------------
// Errors

@(test)
test_nesting_limit_block_quotes :: proc(t: ^testing.T) {
	input := strings.repeat(">", markdown.DEFAULT_MAX_NESTING + 1)
	defer delete(input)
	html, err := markdown.to_html(input)
	testing.expect_value(t, err, markdown.Error(markdown.Markdown_Error.Nesting_Too_Deep))
	testing.expect_value(t, html, "")
}

@(test)
test_nesting_limit_list_items :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i in 0 ..< 20 {
		for _ in 0 ..< i * 2 {
			strings.write_byte(&b, ' ')
		}
		strings.write_string(&b, "- item\n")
	}
	_, err := markdown.to_html(strings.to_string(b), {max_nesting = 10})
	testing.expect_value(t, err, markdown.Error(markdown.Markdown_Error.Nesting_Too_Deep))
}

@(test)
test_nesting_within_limit_succeeds :: proc(t: ^testing.T) {
	expect_html(t, "> > ok\n", "<blockquote>\n<blockquote>\n<p>ok</p>\n</blockquote>\n</blockquote>\n", {max_nesting = 2})
	_, err := markdown.to_html("> > > too deep\n", {max_nesting = 2})
	testing.expect_value(t, err, markdown.Error(markdown.Markdown_Error.Nesting_Too_Deep))
}

@(test)
test_parse_error_returns_nil_document :: proc(t: ^testing.T) {
	doc, err := markdown.parse("> > >\n", {max_nesting = 1})
	testing.expect_value(t, err, markdown.Error(markdown.Markdown_Error.Nesting_Too_Deep))
	testing.expect(t, doc == nil)
}

// Failing_Allocator fails every allocation once its budget runs out.
Failing_Allocator :: struct {
	backing:   mem.Allocator,
	remaining: int,
}

failing_allocator_proc :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]byte,
	mem.Allocator_Error,
) {
	f := (^Failing_Allocator)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if f.remaining <= 0 {
			return nil, .Out_Of_Memory
		}
		f.remaining -= 1
	}
	return f.backing.procedure(f.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

@(test)
test_allocation_failures_return_errors_without_leaks :: proc(t: ^testing.T) {
	input := strings.repeat("# Head\n\n> quote *em* [link][r]\n\n- a\n- b\n\n```\ncode\n```\n\n[r]: /url\n\n", 400)
	defer delete(input)

	succeeded := false
	for budget in 0 ..< 1000 {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer mem.tracking_allocator_destroy(&track)
		failing := Failing_Allocator {
			backing   = mem.tracking_allocator(&track),
			remaining = budget,
		}
		allocator := mem.Allocator{failing_allocator_proc, &failing}

		html, err := markdown.to_html(input, {}, allocator)
		if err == nil {
			testing.expect(t, strings.has_prefix(html, "<h1>Head</h1>"))
			delete(html, allocator)
			succeeded = true
		} else {
			testing.expect_value(t, err, markdown.Error(mem.Allocator_Error.Out_Of_Memory))
		}
		testing.expectf(t, len(track.allocation_map) == 0, "budget %d leaked %d allocations", budget, len(track.allocation_map))
		testing.expectf(t, len(track.bad_free_array) == 0, "budget %d made bad frees", budget)
		if succeeded {
			break
		}
	}
	testing.expect(t, succeeded, "rendering never succeeded")
}

@(test)
test_allocation_failures_with_every_construct :: proc(t: ^testing.T) {
	// Every construct, extensions and safe mode on, and big enough that the
	// arena needs several blocks plus a dedicated block for the input copy.
	unit :: "# H &amp; &copy;\n\nSetext\n---\n\n> - [l](/u \"t\") ![i](/p.png) <http://a.b> `c` \\* ~~s~~ **b** _e_\n>   1. x\n>\n>      y\n\n" +
		"| a | b |\n| :- | -: |\n| 1 | `2` |\n\n<div>\nraw\n</div>\n\n<!--\nc\n\n-->\n\n    indented\n\n~~~ odin\nf :: proc() {}\n~~~\n\n[r]: /ref\n[r] *<span>x</span>*\n\n***\n\n"
	input := strings.repeat(unit, 300)
	defer delete(input)
	testing.expect(t, len(input) > 64 * 1024)
	options := markdown.Options{extensions = markdown.GFM, safe = true}

	expected, expected_err := markdown.to_html(input, options)
	defer delete(expected)
	testing.expect_value(t, expected_err, nil)

	succeeded := false
	for budget in 0 ..< 10_000 {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer mem.tracking_allocator_destroy(&track)
		failing := Failing_Allocator {
			backing   = mem.tracking_allocator(&track),
			remaining = budget,
		}
		allocator := mem.Allocator{failing_allocator_proc, &failing}

		doc, err := markdown.parse(input, options, allocator)
		if err == nil {
			html, render_err := markdown.render_html(doc, allocator)
			if render_err == nil {
				testing.expect(t, html == expected, "output differs from the run with a normal allocator")
				delete(html, allocator)
				succeeded = true
			} else {
				testing.expect_value(t, render_err, markdown.Error(mem.Allocator_Error.Out_Of_Memory))
				testing.expect_value(t, html, "")
			}
			markdown.document_destroy(doc)
		} else {
			testing.expect_value(t, err, markdown.Error(mem.Allocator_Error.Out_Of_Memory))
			testing.expect(t, doc == nil)
		}
		testing.expectf(t, len(track.allocation_map) == 0, "budget %d leaked %d allocations", budget, len(track.allocation_map))
		testing.expectf(t, len(track.bad_free_array) == 0, "budget %d made bad frees", budget)
		if succeeded || len(track.allocation_map) > 0 {
			break
		}
	}
	testing.expect(t, succeeded, "rendering never succeeded")
}

@(test)
test_tracking_allocator_sees_no_leaks :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	doc, err := markdown.parse("| a |\n| - |\n| *b* |\n\n~~c~~ [d](/e \"f\")\n", {extensions = markdown.GFM}, allocator)
	testing.expect_value(t, err, nil)
	html, render_err := markdown.render_html(doc, allocator)
	testing.expect_value(t, render_err, nil)
	testing.expect(t, len(track.allocation_map) > 0)
	delete(html, allocator)
	markdown.document_destroy(doc)

	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

// ---------------------------------------------------------------------------
// Syntax tree

@(test)
test_parse_builds_tree :: proc(t: ^testing.T) {
	doc, err := markdown.parse("## Hello *world*\n\nText\n")
	defer markdown.document_destroy(doc)
	testing.expect_value(t, err, nil)
	root := doc.root
	testing.expect_value(t, root.kind, markdown.Node_Kind.Document)

	heading := root.first_child
	testing.expect_value(t, heading.kind, markdown.Node_Kind.Heading)
	testing.expect_value(t, heading.level, 2)
	testing.expect_value(t, heading.first_child.kind, markdown.Node_Kind.Text)
	testing.expect_value(t, heading.first_child.literal, "Hello ")
	emph := heading.last_child
	testing.expect_value(t, emph.kind, markdown.Node_Kind.Emphasis)
	testing.expect_value(t, emph.first_child.literal, "world")
	testing.expect(t, emph.parent == heading)

	paragraph := heading.next
	testing.expect_value(t, paragraph.kind, markdown.Node_Kind.Paragraph)
	testing.expect(t, paragraph.prev == heading)
	testing.expect(t, paragraph.next == nil)
	testing.expect(t, root.last_child == paragraph)
}

@(test)
test_parse_records_source_lines :: proc(t: ^testing.T) {
	doc, err := markdown.parse("first\nline\n\n```\ncode\n```\n")
	defer markdown.document_destroy(doc)
	testing.expect_value(t, err, nil)
	paragraph := doc.root.first_child
	testing.expect_value(t, paragraph.start_line, 1)
	testing.expect_value(t, paragraph.end_line, 2)
	code := paragraph.next
	testing.expect_value(t, code.start_line, 4)
	testing.expect_value(t, code.end_line, 6)
}

@(test)
test_parse_list_info :: proc(t: ^testing.T) {
	doc, err := markdown.parse("3) a\n4) b\n")
	defer markdown.document_destroy(doc)
	testing.expect_value(t, err, nil)
	list := doc.root.first_child
	testing.expect_value(t, list.kind, markdown.Node_Kind.List)
	testing.expect_value(t, list.list.kind, markdown.List_Kind.Ordered)
	testing.expect_value(t, list.list.start, 3)
	testing.expect_value(t, list.list.delimiter, ')')
	testing.expect(t, list.list.tight)
	testing.expect_value(t, list.first_child.kind, markdown.Node_Kind.Item)
	testing.expect_value(t, list.first_child.next.kind, markdown.Node_Kind.Item)
}

@(test)
test_loose_list_detected :: proc(t: ^testing.T) {
	doc, err := markdown.parse("* a\n\n* b\n")
	defer markdown.document_destroy(doc)
	testing.expect_value(t, err, nil)
	list := doc.root.first_child
	testing.expect_value(t, list.list.bullet, '*')
	testing.expect(t, !list.list.tight)
}

@(test)
test_parse_code_block_info_and_literal :: proc(t: ^testing.T) {
	doc, err := markdown.parse("~~~ odin linenos\nx := 1\n~~~\n")
	defer markdown.document_destroy(doc)
	testing.expect_value(t, err, nil)
	code := doc.root.first_child
	testing.expect_value(t, code.kind, markdown.Node_Kind.Code_Block)
	testing.expect_value(t, code.info, "odin linenos")
	testing.expect_value(t, code.literal, "x := 1\n")
}

@(test)
test_parse_link_destination_and_title :: proc(t: ^testing.T) {
	doc, err := markdown.parse("[a *b*][ref]\n\n[REF]: <my url> 'the &amp; title'\n")
	defer markdown.document_destroy(doc)
	testing.expect_value(t, err, nil)
	link := doc.root.first_child.first_child
	testing.expect_value(t, link.kind, markdown.Node_Kind.Link)
	testing.expect_value(t, link.destination, "my%20url")
	testing.expect_value(t, link.title, "the & title")
	testing.expect_value(t, link.last_child.kind, markdown.Node_Kind.Emphasis)
}

@(test)
test_parse_table_cells :: proc(t: ^testing.T) {
	doc, err := markdown.parse("| a | b |\n| :- | -: |\n| 1 | 2 |\n", {extensions = {.Tables}})
	defer markdown.document_destroy(doc)
	testing.expect_value(t, err, nil)
	table := doc.root.first_child
	testing.expect_value(t, table.kind, markdown.Node_Kind.Table)
	header := table.first_child
	testing.expect(t, header.header)
	testing.expect_value(t, header.first_child.alignment, markdown.Alignment.Left)
	testing.expect_value(t, header.last_child.alignment, markdown.Alignment.Right)
	body := header.next
	testing.expect(t, !body.header)
	testing.expect_value(t, body.last_child.first_child.literal, "2")
}

@(test)
test_render_node_html_renders_subtree :: proc(t: ^testing.T) {
	doc, err := markdown.parse("- *one*\n- two\n")
	defer markdown.document_destroy(doc)
	testing.expect_value(t, err, nil)
	item := doc.root.first_child.first_child
	html, render_err := markdown.render_node_html(item)
	defer delete(html)
	testing.expect_value(t, render_err, nil)
	testing.expect_value(t, html, "<li><em>one</em></li>\n")
}

@(test)
test_tree_edits_show_in_output :: proc(t: ^testing.T) {
	doc, err := markdown.parse("[docs](/old)\n")
	defer markdown.document_destroy(doc)
	testing.expect_value(t, err, nil)
	link := doc.root.first_child.first_child
	link.destination = "https://example.com/new"
	html, render_err := markdown.render_html(doc)
	defer delete(html)
	testing.expect_value(t, render_err, nil)
	testing.expect_value(t, html, "<p><a href=\"https://example.com/new\">docs</a></p>\n")
}

@(test)
test_render_html_uses_document_options :: proc(t: ^testing.T) {
	doc, err := markdown.parse("~~x~~ <b>y</b>\n", {extensions = {.Strikethrough}, safe = true})
	defer markdown.document_destroy(doc)
	testing.expect_value(t, err, nil)
	html, render_err := markdown.render_html(doc)
	defer delete(html)
	testing.expect_value(t, render_err, nil)
	testing.expect_value(t, html, "<p><del>x</del> <!-- raw HTML omitted -->y<!-- raw HTML omitted --></p>\n")
}

@(test)
test_nil_document_is_harmless :: proc(t: ^testing.T) {
	markdown.document_destroy(nil)
	html, err := markdown.render_html(nil)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, html, "")
}

// ---------------------------------------------------------------------------
// HTML blocks. These cases aren't in the spec examples; the expected output is
// what the cmark and commonmark.js reference implementations produce.

@(test)
test_html_block_keeps_trailing_blank_lines :: proc(t: ^testing.T) {
	// Types 1 to 5 only end at their end condition, so blank lines up to the
	// end of the document or container belong to the block.
	expect_html(t, "<!--\n\n", "<!--\n\n")
	expect_html(t, "<!--\n  \n", "<!--\n  \n")
	expect_html(t, "<pre>\nx\n\n\n", "<pre>\nx\n\n\n")
	expect_html(t, "> <!--\n>\n", "<blockquote>\n<!--\n\n</blockquote>\n")
	expect_html(t, "- <!--\n\n- x\n", "<ul>\n<li>\n<!--\n\n</li>\n<li>x</li>\n</ul>\n")
	// Types 6 and 7 end at a blank line, which stays outside the block.
	expect_html(t, "<div>\n\nx\n", "<div>\n<p>x</p>\n")
}

@(test)
test_html_block_type_7_closing_raw_tags :: proc(t: ^testing.T) {
	// No type 1 block starts with `</pre>`, so a lone closing tag is type 7.
	expect_html(t, "</pre>\n*x*\n", "</pre>\n*x*\n")
	expect_html(t, "</script>\n", "</script>\n")
	expect_html(t, "<pre/>\nx\n", "<pre/>\nx\n")
	// Type 7 still can't interrupt a paragraph.
	expect_html(t, "a\n</pre>\n", "<p>a\n</pre></p>\n")
}

@(test)
test_html_block_tree_literal_keeps_blank_lines :: proc(t: ^testing.T) {
	doc, err := markdown.parse("<!--\nx\n\n")
	defer markdown.document_destroy(doc)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, doc.root.first_child.literal, "<!--\nx\n\n")
}

// ---------------------------------------------------------------------------
// Link reference definitions are leaf blocks (spec section 4.7), so they count
// as list item content even though they render as nothing.

@(test)
test_reference_definition_makes_list_item_loose :: proc(t: ^testing.T) {
	expect_html(t, "- [x]: /u\n\n  b\n", "<ul>\n<li>\n<p>b</p>\n</li>\n</ul>\n")
}

@(test)
test_reference_definition_is_not_an_empty_item_start :: proc(t: ^testing.T) {
	// Only an item that starts with a blank line ends at a second blank line.
	expect_html(t, "- [x]: /u\n\n\n  b\n", "<ul>\n<li>\n<p>b</p>\n</li>\n</ul>\n")
	expect_html(t, "-\n\n  b\n", "<ul>\n<li></li>\n</ul>\n<p>b</p>\n")
}

@(test)
test_reference_definitions_leave_no_nodes :: proc(t: ^testing.T) {
	doc, err := markdown.parse("- [x]: /u\n\n  [x]\n\n[y]: /v\n")
	defer markdown.document_destroy(doc)
	testing.expect_value(t, err, nil)
	list := doc.root.first_child
	testing.expect_value(t, list.kind, markdown.Node_Kind.List)
	testing.expect(t, list.next == nil, "the trailing definition must not leave a node")
	item := list.first_child
	testing.expect(t, item.first_child != nil && item.first_child == item.last_child, "the item keeps only its paragraph")
	testing.expect_value(t, item.first_child.first_child.kind, markdown.Node_Kind.Link)
}

// ---------------------------------------------------------------------------
// Pathological input. Each case would take quadratic time or overflow the
// stack in a naive implementation; here they must finish quickly.

@(test)
test_pathological_nested_brackets :: proc(t: ^testing.T) {
	open := strings.repeat("[", 50_000)
	defer delete(open)
	close := strings.repeat("]", 50_000)
	defer delete(close)
	input := strings.concatenate({open, "a", close})
	defer delete(input)
	html, err := markdown.to_html(input)
	defer delete(html)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(html), len(input) + len("<p></p>\n"))
}

@(test)
test_pathological_unclosed_emphasis :: proc(t: ^testing.T) {
	input := strings.repeat("*a _b ", 30_000)
	defer delete(input)
	html, err := markdown.to_html(input)
	defer delete(html)
	testing.expect_value(t, err, nil)
	testing.expect(t, strings.has_prefix(html, "<p>*a _b *a _b"))
}

@(test)
test_pathological_deep_emphasis_nesting :: proc(t: ^testing.T) {
	open := strings.repeat("*", 20_000)
	defer delete(open)
	input := strings.concatenate({open, "a", open})
	defer delete(input)
	html, err := markdown.to_html(input)
	defer delete(html)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, strings.count(html, "<strong>"), 10_000)
}

@(test)
test_pathological_backtick_runs :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i in 1 ..= 2_000 {
		for _ in 0 ..< i % 60 + 1 {
			strings.write_byte(&b, '`')
		}
		strings.write_string(&b, "x")
	}
	html, err := markdown.to_html(strings.to_string(b))
	defer delete(html)
	testing.expect_value(t, err, nil)
	testing.expect(t, strings.has_prefix(html, "<p>"))
}

@(test)
test_pathological_deep_block_quotes_within_limit :: proc(t: ^testing.T) {
	input := strings.repeat("> ", markdown.DEFAULT_MAX_NESTING)
	defer delete(input)
	html, err := markdown.to_html(input)
	defer delete(html)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, strings.count(html, "<blockquote>"), markdown.DEFAULT_MAX_NESTING)
}

@(test)
test_many_reference_definitions :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i in 0 ..< 5_000 {
		strings.write_string(&b, "[r")
		strings.write_int(&b, i)
		strings.write_string(&b, "]: /u\n")
	}
	strings.write_string(&b, "\n[r4999] [R0]\n")
	expect_html(t, strings.to_string(b), "<p><a href=\"/u\">r4999</a> <a href=\"/u\">R0</a></p>\n")
}
