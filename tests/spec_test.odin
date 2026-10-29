package markdown_tests

// These tests run every example from the CommonMark Spec 0.31.2, one test
// procedure per spec section. The examples in testdata/ come from
// https://spec.commonmark.org/0.31.2/spec.json, written by John MacFarlane and
// licensed under CC BY-SA 4.0.

import markdown ".."
import "core:encoding/json"
import "core:mem"
import "core:testing"

SPEC_JSON :: #load("testdata/commonmark-spec-0.31.2.json")

Spec_Example :: struct {
	markdown: string,
	html:     string,
	example:  int,
	section:  string,
}

// run_section renders every example of `section` and compares it byte for byte with the spec.
run_section :: proc(t: ^testing.T, section: string, loc := #caller_location) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)

	examples: []Spec_Example
	err := json.unmarshal(SPEC_JSON, &examples, allocator = mem.dynamic_arena_allocator(&arena))
	if !testing.expect_value(t, err, nil, loc) {
		return
	}
	count := 0
	for ex in examples {
		if ex.section != section {
			continue
		}
		count += 1
		html, render_err := markdown.to_html(ex.markdown)
		defer delete(html)
		testing.expectf(t, render_err == nil, "example %d: unexpected error %v", ex.example, render_err, loc = loc)
		testing.expectf(
			t,
			html == ex.html,
			"example %d (%s)\nmarkdown: %q\nexpected: %q\n     got: %q",
			ex.example,
			section,
			ex.markdown,
			ex.html,
			html,
			loc = loc,
		)
	}
	testing.expectf(t, count > 0, "no examples found for section %q", section, loc = loc)
}

@(test)
test_spec_tabs :: proc(t: ^testing.T) {
	run_section(t, "Tabs")
}

@(test)
test_spec_backslash_escapes :: proc(t: ^testing.T) {
	run_section(t, "Backslash escapes")
}

@(test)
test_spec_entity_references :: proc(t: ^testing.T) {
	run_section(t, "Entity and numeric character references")
}

@(test)
test_spec_precedence :: proc(t: ^testing.T) {
	run_section(t, "Precedence")
}

@(test)
test_spec_thematic_breaks :: proc(t: ^testing.T) {
	run_section(t, "Thematic breaks")
}

@(test)
test_spec_atx_headings :: proc(t: ^testing.T) {
	run_section(t, "ATX headings")
}

@(test)
test_spec_setext_headings :: proc(t: ^testing.T) {
	run_section(t, "Setext headings")
}

@(test)
test_spec_indented_code_blocks :: proc(t: ^testing.T) {
	run_section(t, "Indented code blocks")
}

@(test)
test_spec_fenced_code_blocks :: proc(t: ^testing.T) {
	run_section(t, "Fenced code blocks")
}

@(test)
test_spec_html_blocks :: proc(t: ^testing.T) {
	run_section(t, "HTML blocks")
}

@(test)
test_spec_link_reference_definitions :: proc(t: ^testing.T) {
	run_section(t, "Link reference definitions")
}

@(test)
test_spec_paragraphs :: proc(t: ^testing.T) {
	run_section(t, "Paragraphs")
}

@(test)
test_spec_blank_lines :: proc(t: ^testing.T) {
	run_section(t, "Blank lines")
}

@(test)
test_spec_block_quotes :: proc(t: ^testing.T) {
	run_section(t, "Block quotes")
}

@(test)
test_spec_list_items :: proc(t: ^testing.T) {
	run_section(t, "List items")
}

@(test)
test_spec_lists :: proc(t: ^testing.T) {
	run_section(t, "Lists")
}

@(test)
test_spec_inlines :: proc(t: ^testing.T) {
	run_section(t, "Inlines")
}

@(test)
test_spec_code_spans :: proc(t: ^testing.T) {
	run_section(t, "Code spans")
}

@(test)
test_spec_emphasis :: proc(t: ^testing.T) {
	run_section(t, "Emphasis and strong emphasis")
}

@(test)
test_spec_links :: proc(t: ^testing.T) {
	run_section(t, "Links")
}

@(test)
test_spec_images :: proc(t: ^testing.T) {
	run_section(t, "Images")
}

@(test)
test_spec_autolinks :: proc(t: ^testing.T) {
	run_section(t, "Autolinks")
}

@(test)
test_spec_raw_html :: proc(t: ^testing.T) {
	run_section(t, "Raw HTML")
}

@(test)
test_spec_hard_line_breaks :: proc(t: ^testing.T) {
	run_section(t, "Hard line breaks")
}

@(test)
test_spec_soft_line_breaks :: proc(t: ^testing.T) {
	run_section(t, "Soft line breaks")
}

@(test)
test_spec_textual_content :: proc(t: ^testing.T) {
	run_section(t, "Textual content")
}
