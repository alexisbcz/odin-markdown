package markdown

import "base:runtime"
import "core:unicode/utf8"

// The block parser follows the two-phase strategy from the CommonMark spec's
// appendix: lines are fed one at a time into a tree of open blocks, then the
// inline content of every leaf block is parsed once all references are known.

@(private)
CODE_INDENT :: 4

// Block_State holds parser bookkeeping for one node.
@(private)
Block_State :: struct {
	content:       [dynamic]byte,
	text:          string,
	open:          bool,
	fenced:        bool,
	fence_char:    byte,
	fence_length:  int,
	fence_offset:  int,
	html_type:     int,
	// refs_only marks a closed paragraph that held only link reference
	// definitions. It stays in the tree until block parsing ends, so list
	// tightness and the empty item rule still see it, as in commonmark.js.
	refs_only:     bool,
	// autocompleted counts the empty cells a Table has added to pad short rows.
	autocompleted: int,
	marker_offset: int,
	padding:       int,
	depth:         int,
	alignments:    []Alignment,
}

@(private)
Reference :: struct {
	destination: string,
	title:       string,
}

@(private)
Parser :: struct {
	allocator:              runtime.Allocator,
	options:                Options,
	max_nesting:            int,
	doc:                    ^Node,
	tip:                    ^Node,
	oldtip:                 ^Node,
	last_matched_container: ^Node,
	line:                   string,
	line_number:            int,
	offset:                 int,
	column:                 int,
	next_nonspace:          int,
	next_nonspace_column:   int,
	indent:                 int,
	indented:               bool,
	blank:                  bool,
	partially_consumed_tab: bool,
	all_closed:             bool,
	refmap:                 map[string]Reference,
}

@(private)
new_node :: proc(kind: Node_Kind, allocator: runtime.Allocator) -> (node: ^Node, err: runtime.Allocator_Error) {
	node = new(Node, allocator) or_return
	node.kind = kind
	node.state.content.allocator = allocator
	return node, nil
}

@(private)
append_child :: proc(parent, child: ^Node) {
	child.parent = parent
	child.next = nil
	child.prev = parent.last_child
	if parent.last_child != nil {
		parent.last_child.next = child
	} else {
		parent.first_child = child
	}
	parent.last_child = child
}

@(private)
unlink :: proc(node: ^Node) {
	if node.prev != nil {
		node.prev.next = node.next
	} else if node.parent != nil {
		node.parent.first_child = node.next
	}
	if node.next != nil {
		node.next.prev = node.prev
	} else if node.parent != nil {
		node.parent.last_child = node.prev
	}
	node.parent = nil
	node.next = nil
	node.prev = nil
}

@(private)
insert_after :: proc(node, sibling: ^Node) {
	unlink(sibling)
	sibling.next = node.next
	if sibling.next != nil {
		sibling.next.prev = sibling
	}
	sibling.prev = node
	node.next = sibling
	sibling.parent = node.parent
	if sibling.next == nil && sibling.parent != nil {
		sibling.parent.last_child = sibling
	}
}

// sanitize replaces NUL bytes and invalid UTF-8 with U+FFFD, copying only when needed.
@(private)
sanitize :: proc(input: string, allocator: runtime.Allocator) -> (result: string, err: runtime.Allocator_Error) {
	clean := true
	for i := 0; i < len(input); {
		r, size := utf8.decode_rune_in_string(input[i:])
		if r == 0 || (r == utf8.RUNE_ERROR && size == 1) {
			clean = false
			break
		}
		i += size
	}
	if clean {
		return input, nil
	}
	buf := make([dynamic]byte, 0, len(input) + 16, allocator) or_return
	for i := 0; i < len(input); {
		r, size := utf8.decode_rune_in_string(input[i:])
		if r == 0 || (r == utf8.RUNE_ERROR && size == 1) {
			write_string(&buf, "�") or_return
		} else {
			write_string(&buf, input[i:i + size]) or_return
		}
		i += size
	}
	return string(buf[:]), nil
}

@(private)
parse_document :: proc(input: string, options: Options, allocator: runtime.Allocator) -> (root: ^Node, err: Error) {
	p := Parser {
		allocator   = allocator,
		options     = options,
		max_nesting = options.max_nesting if options.max_nesting > 0 else DEFAULT_MAX_NESTING,
	}
	p.refmap = make(map[string]Reference, allocator)
	root = new_node(.Document, allocator) or_return
	root.state.open = true
	root.start_line = 1
	p.doc = root
	p.tip = root
	p.oldtip = root

	text := sanitize(input, allocator) or_return
	line_start := 0
	for i := 0; i < len(text); {
		c := text[i]
		if c != '\n' && c != '\r' {
			i += 1
			continue
		}
		incorporate_line(&p, text[line_start:i]) or_return
		if c == '\r' && i + 1 < len(text) && text[i + 1] == '\n' {
			i += 1
		}
		i += 1
		line_start = i
	}
	if line_start < len(text) {
		incorporate_line(&p, text[line_start:]) or_return
	}
	for p.tip != nil {
		finalize(&p, p.tip, p.line_number) or_return
	}
	root.end_line = p.line_number
	process_inlines(&p, root) or_return
	return root, nil
}

@(private)
find_next_nonspace :: proc(p: ^Parser) {
	i := p.offset
	cols := p.column
	c := -1
	for i < len(p.line) {
		c = int(p.line[i])
		if c == ' ' {
			i += 1
			cols += 1
		} else if c == '\t' {
			i += 1
			cols += 4 - (cols % 4)
		} else {
			break
		}
	}
	p.blank = i >= len(p.line)
	p.next_nonspace = i
	p.next_nonspace_column = cols
	p.indent = cols - p.column
	p.indented = p.indent >= CODE_INDENT
}

@(private)
advance_next_nonspace :: proc(p: ^Parser) {
	p.offset = p.next_nonspace
	p.column = p.next_nonspace_column
	p.partially_consumed_tab = false
}

// advance_offset moves forward `count` bytes, or `count` columns when `columns` is true, splitting tabs as needed.
@(private)
advance_offset :: proc(p: ^Parser, count: int, columns: bool) {
	count := count
	for count > 0 && p.offset < len(p.line) {
		if p.line[p.offset] == '\t' {
			chars_to_tab := 4 - (p.column % 4)
			if columns {
				p.partially_consumed_tab = chars_to_tab > count
				chars_to_advance := min(chars_to_tab, count)
				p.column += chars_to_advance
				if !p.partially_consumed_tab {
					p.offset += 1
				}
				count -= chars_to_advance
			} else {
				p.partially_consumed_tab = false
				p.column += chars_to_tab
				p.offset += 1
				count -= 1
			}
		} else {
			p.partially_consumed_tab = false
			p.offset += 1
			p.column += 1
			count -= 1
		}
	}
}

@(private)
add_line :: proc(p: ^Parser) -> runtime.Allocator_Error {
	buf := &p.tip.state.content
	if p.partially_consumed_tab {
		p.offset += 1
		chars_to_tab := 4 - (p.column % 4)
		for _ in 0 ..< chars_to_tab {
			write_byte(buf, ' ') or_return
		}
	}
	if p.offset < len(p.line) {
		write_string(buf, p.line[p.offset:]) or_return
	}
	return write_byte(buf, '\n')
}

@(private)
can_contain :: proc(parent, child: Node_Kind) -> bool {
	#partial switch parent {
	case .Document, .Block_Quote, .Item:
		return child != .Item
	case .List:
		return child == .Item
	}
	return false
}

@(private)
add_child :: proc(p: ^Parser, kind: Node_Kind) -> (node: ^Node, err: Error) {
	for !can_contain(p.tip.kind, kind) {
		finalize(p, p.tip, p.line_number - 1) or_return
	}
	node = new_node(kind, p.allocator) or_return
	node.start_line = p.line_number
	node.state.open = true
	node.state.depth = p.tip.state.depth
	if kind == .Block_Quote || kind == .Item {
		node.state.depth += 1
		if node.state.depth > p.max_nesting {
			return nil, .Nesting_Too_Deep
		}
	}
	append_child(p.tip, node)
	p.tip = node
	return node, nil
}

@(private)
close_unmatched_blocks :: proc(p: ^Parser) -> Error {
	if p.all_closed {
		return nil
	}
	for p.oldtip != p.last_matched_container {
		parent := p.oldtip.parent
		finalize(p, p.oldtip, p.line_number - 1) or_return
		p.oldtip = parent
	}
	p.all_closed = true
	return nil
}

// maybe_special is a fast check for characters that could start a block.
@(private)
maybe_special :: proc(p: ^Parser, c: int) -> bool {
	switch c {
	case '#', '`', '~', '*', '+', '_', '=', '<', '>', '-', '0' ..= '9':
		return true
	case '|', ':':
		return .Tables in p.options.extensions
	}
	return false
}

@(private)
incorporate_line :: proc(p: ^Parser, line: string) -> Error {
	container := p.doc
	p.oldtip = p.tip
	p.offset = 0
	p.column = 0
	p.blank = false
	p.partially_consumed_tab = false
	p.line_number += 1
	p.line = line

	// Match the line against each open container, outermost first.
	match_loop: for {
		last := container.last_child
		if last == nil || !last.state.open {
			break
		}
		container = last
		find_next_nonspace(p)
		switch block_continue(p, container) or_return {
		case 0:
		case 1:
			container = container.parent
			break match_loop
		case:
			// The line was fully consumed, for example by a closing code fence.
			return nil
		}
	}

	p.all_closed = container == p.oldtip
	p.last_matched_container = container

	matched_leaf := container.kind != .Paragraph && (container.kind == .Code_Block || container.kind == .Html_Block)
	for !matched_leaf {
		find_next_nonspace(p)
		if !p.indented && !maybe_special(p, peek(p.line, p.next_nonspace)) {
			advance_next_nonspace(p)
			break
		}
		res := try_block_starts(p, container) or_return
		if res == 0 {
			advance_next_nonspace(p)
			break
		}
		container = p.tip
		if res == 2 {
			matched_leaf = true
		}
	}

	if !p.all_closed && !p.blank && p.tip.kind == .Paragraph {
		// Lazy paragraph continuation.
		return add_line(p)
	}
	close_unmatched_blocks(p) or_return
	#partial switch container.kind {
	case .Code_Block, .Html_Block, .Paragraph:
		add_line(p) or_return
		ht := container.state.html_type
		if container.kind == .Html_Block && ht >= 1 && ht <= 5 && html_block_ends(ht, p.line[p.offset:]) {
			finalize(p, container, p.line_number) or_return
		}
	case .Table:
		// The delimiter row leaves the offset at the end of the line, so it adds no row.
		if p.offset < len(p.line) && !p.blank {
			added := add_table_row(p, container, p.line[p.offset:]) or_return
			if !added {
				// The table has padded too many cells; the line starts a paragraph instead.
				finalize(p, container, p.line_number - 1) or_return
				add_child(p, .Paragraph) or_return
				advance_next_nonspace(p)
				add_line(p) or_return
			}
		}
	case:
		if p.offset < len(p.line) && !p.blank {
			add_child(p, .Paragraph) or_return
			advance_next_nonspace(p)
			add_line(p) or_return
		}
	}
	return nil
}

// block_continue returns 0 when `container` matches the line, 1 when it doesn't, and 2 when the line is consumed.
@(private)
block_continue :: proc(p: ^Parser, container: ^Node) -> (result: int, err: Error) {
	st := &container.state
	switch container.kind {
	case .Document, .List:
		return 0, nil
	case .Block_Quote:
		if !p.indented && peek(p.line, p.next_nonspace) == '>' {
			advance_next_nonspace(p)
			advance_offset(p, 1, false)
			if is_space_or_tab(peek(p.line, p.offset)) {
				advance_offset(p, 1, true)
			}
			return 0, nil
		}
		return 1, nil
	case .Item:
		if p.blank {
			if container.first_child == nil {
				return 1, nil
			}
			advance_next_nonspace(p)
		} else if p.indent >= st.marker_offset + st.padding {
			advance_offset(p, st.marker_offset + st.padding, true)
		} else {
			return 1, nil
		}
		return 0, nil
	case .Heading, .Thematic_Break:
		return 1, nil
	case .Code_Block:
		if st.fenced {
			if p.indent <= 3 && peek(p.line, p.next_nonspace) == int(st.fence_char) {
				i := p.next_nonspace
				for i < len(p.line) && p.line[i] == st.fence_char {
					i += 1
				}
				run := i - p.next_nonspace
				if run >= st.fence_length && is_blank(p.line[i:]) {
					finalize(p, container, p.line_number) or_return
					return 2, nil
				}
			}
			// Skip the indentation of the opening fence.
			for i := st.fence_offset; i > 0 && is_space_or_tab(peek(p.line, p.offset)); i -= 1 {
				advance_offset(p, 1, true)
			}
			return 0, nil
		}
		if p.indent >= CODE_INDENT {
			advance_offset(p, CODE_INDENT, true)
		} else if p.blank {
			advance_next_nonspace(p)
		} else {
			return 1, nil
		}
		return 0, nil
	case .Html_Block:
		return 1 if p.blank && (st.html_type == 6 || st.html_type == 7) else 0, nil
	case .Paragraph, .Table:
		return 1 if p.blank else 0, nil
	case .Table_Row, .Table_Cell, .Text, .Soft_Break, .Line_Break, .Code, .Emphasis, .Strong, .Strikethrough, .Link, .Image, .Html_Inline:
		return 1, nil
	}
	return 1, nil
}

// try_block_starts tries each block start in precedence order. It returns 0 for none, 1 for a container, 2 for a leaf.
@(private)
try_block_starts :: proc(p: ^Parser, container: ^Node) -> (result: int, err: Error) {
	if r := start_block_quote(p) or_return; r != 0 {
		return r, nil
	}
	if r := start_atx_heading(p) or_return; r != 0 {
		return r, nil
	}
	if r := start_fenced_code(p) or_return; r != 0 {
		return r, nil
	}
	if r := start_html_block(p, container) or_return; r != 0 {
		return r, nil
	}
	if .Tables in p.options.extensions {
		if r := start_table(p, container) or_return; r != 0 {
			return r, nil
		}
	}
	if r := start_setext_heading(p, container) or_return; r != 0 {
		return r, nil
	}
	if r := start_thematic_break(p) or_return; r != 0 {
		return r, nil
	}
	if r := start_list_item(p, container) or_return; r != 0 {
		return r, nil
	}
	return start_indented_code(p)
}

@(private)
start_block_quote :: proc(p: ^Parser) -> (result: int, err: Error) {
	if p.indented || peek(p.line, p.next_nonspace) != '>' {
		return 0, nil
	}
	advance_next_nonspace(p)
	advance_offset(p, 1, false)
	if is_space_or_tab(peek(p.line, p.offset)) {
		advance_offset(p, 1, true)
	}
	close_unmatched_blocks(p) or_return
	add_child(p, .Block_Quote) or_return
	return 1, nil
}

@(private)
start_atx_heading :: proc(p: ^Parser) -> (result: int, err: Error) {
	if p.indented {
		return 0, nil
	}
	s := p.line[p.next_nonspace:]
	level := 0
	for level < len(s) && s[level] == '#' {
		level += 1
	}
	if level == 0 || level > 6 {
		return 0, nil
	}
	marker := level
	if marker < len(s) {
		if !is_space_or_tab(int(s[marker])) {
			return 0, nil
		}
		for marker < len(s) && is_space_or_tab(int(s[marker])) {
			marker += 1
		}
	}
	advance_next_nonspace(p)
	advance_offset(p, marker, false)
	close_unmatched_blocks(p) or_return
	heading := add_child(p, .Heading) or_return
	heading.level = level
	write_string(&heading.state.content, strip_closing_hashes(p.line[p.offset:])) or_return
	advance_offset(p, len(p.line) - p.offset, false)
	return 2, nil
}

// strip_closing_hashes removes an optional closing sequence of `#` from an ATX heading.
@(private)
strip_closing_hashes :: proc(s: string) -> string {
	end := len(s)
	for end > 0 && is_space_or_tab(int(s[end - 1])) {
		end -= 1
	}
	hashes := end
	for hashes > 0 && s[hashes - 1] == '#' {
		hashes -= 1
	}
	if hashes == end {
		return s
	}
	before := hashes
	for before > 0 && is_space_or_tab(int(s[before - 1])) {
		before -= 1
	}
	if before == 0 {
		return ""
	}
	if before < hashes {
		return s[:before]
	}
	return s
}

@(private)
start_fenced_code :: proc(p: ^Parser) -> (result: int, err: Error) {
	if p.indented {
		return 0, nil
	}
	s := p.line[p.next_nonspace:]
	c := peek(s, 0)
	if c != '`' && c != '~' {
		return 0, nil
	}
	n := 0
	for n < len(s) && int(s[n]) == c {
		n += 1
	}
	if n < 3 {
		return 0, nil
	}
	if c == '`' {
		for i in n ..< len(s) {
			if s[i] == '`' {
				return 0, nil
			}
		}
	}
	close_unmatched_blocks(p) or_return
	code := add_child(p, .Code_Block) or_return
	code.state.fenced = true
	code.state.fence_length = n
	code.state.fence_char = byte(c)
	code.state.fence_offset = p.indent
	advance_next_nonspace(p)
	advance_offset(p, n, false)
	return 2, nil
}

@(private)
start_html_block :: proc(p: ^Parser, container: ^Node) -> (result: int, err: Error) {
	if p.indented || peek(p.line, p.next_nonspace) != '<' {
		return 0, nil
	}
	lazy := !p.all_closed && !p.blank && p.tip.kind == .Paragraph
	html_type := html_block_start(p.line[p.next_nonspace:], container.kind != .Paragraph && !lazy)
	if html_type == 0 {
		return 0, nil
	}
	close_unmatched_blocks(p) or_return
	block := add_child(p, .Html_Block) or_return
	block.state.html_type = html_type
	return 2, nil
}

@(private)
start_setext_heading :: proc(p: ^Parser, container: ^Node) -> (result: int, err: Error) {
	if p.indented || container.kind != .Paragraph {
		return 0, nil
	}
	s := p.line[p.next_nonspace:]
	c := peek(s, 0)
	if c != '=' && c != '-' {
		return 0, nil
	}
	i := 0
	for i < len(s) && int(s[i]) == c {
		i += 1
	}
	if !is_blank(s[i:]) {
		return 0, nil
	}
	close_unmatched_blocks(p) or_return
	content := resolve_references(p, string(container.state.content[:])) or_return
	if is_blank(content) {
		container.state.content = nil
		container.state.content.allocator = p.allocator
		return 0, nil
	}
	heading := new_node(.Heading, p.allocator) or_return
	heading.level = 1 if c == '=' else 2
	heading.start_line = container.start_line
	heading.state.open = true
	heading.state.depth = container.state.depth
	heading.state.content.allocator = p.allocator
	write_string(&heading.state.content, content) or_return
	insert_after(container, heading)
	unlink(container)
	p.tip = heading
	advance_offset(p, len(p.line) - p.offset, false)
	return 2, nil
}

@(private)
is_thematic_break :: proc(s: string) -> bool {
	c := peek(s, 0)
	if c != '*' && c != '-' && c != '_' {
		return false
	}
	count := 0
	for i in 0 ..< len(s) {
		d := int(s[i])
		if d == c {
			count += 1
		} else if !is_space_or_tab(d) {
			return false
		}
	}
	return count >= 3
}

@(private)
start_thematic_break :: proc(p: ^Parser) -> (result: int, err: Error) {
	if p.indented || !is_thematic_break(p.line[p.next_nonspace:]) {
		return 0, nil
	}
	close_unmatched_blocks(p) or_return
	add_child(p, .Thematic_Break) or_return
	advance_offset(p, len(p.line) - p.offset, false)
	return 2, nil
}

// parse_list_marker recognizes a list marker at the next non-space position and consumes it and the spaces after it.
@(private)
parse_list_marker :: proc(p: ^Parser, container: ^Node) -> (info: List_Info, padding: int, ok: bool) {
	if p.indent >= 4 {
		return
	}
	rest := p.line[p.next_nonspace:]
	marker_len := 0
	c := peek(rest, 0)
	if c == '-' || c == '+' || c == '*' {
		info.kind = .Bullet
		info.bullet = byte(c)
		marker_len = 1
	} else if is_ascii_digit(c) {
		i, n := 0, 0
		for i < len(rest) && i < 9 && is_ascii_digit(int(rest[i])) {
			n = n * 10 + int(rest[i] - '0')
			i += 1
		}
		d := peek(rest, i)
		if d != '.' && d != ')' {
			return
		}
		if container.kind == .Paragraph && n != 1 {
			return
		}
		info.kind = .Ordered
		info.start = n
		info.delimiter = byte(d)
		marker_len = i + 1
	} else {
		return
	}
	next := peek(p.line, p.next_nonspace + marker_len)
	if next != -1 && next != '\t' && next != ' ' {
		return
	}
	if container.kind == .Paragraph && is_blank(p.line[p.next_nonspace + marker_len:]) {
		return
	}
	info.tight = true
	advance_next_nonspace(p)
	advance_offset(p, marker_len, true)
	spaces_start_col := p.column
	spaces_start_offset := p.offset
	for {
		advance_offset(p, 1, true)
		next = peek(p.line, p.offset)
		if !(p.column - spaces_start_col < 5 && is_space_or_tab(next)) {
			break
		}
	}
	blank_item := peek(p.line, p.offset) == -1
	spaces_after := p.column - spaces_start_col
	if spaces_after >= 5 || spaces_after < 1 || blank_item {
		padding = marker_len + 1
		p.column = spaces_start_col
		p.offset = spaces_start_offset
		if is_space_or_tab(peek(p.line, p.offset)) {
			advance_offset(p, 1, true)
		}
	} else {
		padding = marker_len + spaces_after
	}
	return info, padding, true
}

@(private)
start_list_item :: proc(p: ^Parser, container: ^Node) -> (result: int, err: Error) {
	if p.indented && container.kind != .List {
		return 0, nil
	}
	marker_offset := p.indent
	info, padding, ok := parse_list_marker(p, container)
	if !ok {
		return 0, nil
	}
	close_unmatched_blocks(p) or_return
	tip := p.tip
	if tip.kind != .List || tip.list.kind != info.kind || tip.list.delimiter != info.delimiter || tip.list.bullet != info.bullet {
		list := add_child(p, .List) or_return
		list.list = info
	}
	item := add_child(p, .Item) or_return
	item.list = info
	item.state.marker_offset = marker_offset
	item.state.padding = padding
	return 1, nil
}

@(private)
start_indented_code :: proc(p: ^Parser) -> (result: int, err: Error) {
	if !p.indented || p.tip.kind == .Paragraph || p.blank {
		return 0, nil
	}
	advance_offset(p, CODE_INDENT, true)
	close_unmatched_blocks(p) or_return
	add_child(p, .Code_Block) or_return
	return 2, nil
}

// trailing_blank_lines_start returns where the trailing `(\n *)+` run of `s` begins, or len(s).
@(private)
trailing_blank_lines_start :: proc(s: string) -> int {
	end := len(s)
	for {
		j := end
		for j > 0 && s[j - 1] == ' ' {
			j -= 1
		}
		if j > 0 && s[j - 1] == '\n' {
			end = j - 1
		} else {
			return end
		}
	}
}

@(private)
count_lines :: proc(s: string) -> int {
	n := 0
	for i in 0 ..< len(s) {
		if s[i] == '\n' {
			n += 1
		}
	}
	return n
}

// resolve_references consumes link reference definitions at the start of paragraph text and returns the rest.
@(private)
resolve_references :: proc(p: ^Parser, text: string) -> (rest: string, err: Error) {
	rest = text
	for len(rest) > 0 && rest[0] == '[' {
		n := parse_reference(p, rest) or_return
		if n == 0 {
			break
		}
		rest = rest[n:]
	}
	return rest, nil
}

@(private)
finalize :: proc(p: ^Parser, block: ^Node, line_number: int) -> Error {
	above := block.parent
	st := &block.state
	st.open = false
	block.end_line = line_number
	#partial switch block.kind {
	case .Paragraph:
		rest := resolve_references(p, string(st.content[:])) or_return
		if is_blank(rest) {
			st.refs_only = true
		} else {
			st.text = rest
		}
	case .Heading:
		st.text = string(st.content[:])
	case .Code_Block:
		content := string(st.content[:])
		if st.fenced {
			newline := 0
			for newline < len(content) && content[newline] != '\n' {
				newline += 1
			}
			block.info = unescape_string(trim_ascii_whitespace(content[:newline]), p.allocator) or_return
			block.literal = content[min(newline + 1, len(content)):]
		} else {
			end := trailing_blank_lines_start(content)
			if end < len(content) {
				end += 1
			}
			block.literal = content[:end]
			block.end_line = block.start_line + max(count_lines(block.literal) - 1, 0)
		}
	case .Html_Block:
		// Types 6 and 7 end before a blank line. Types 1 to 5 keep blank lines
		// up to their end condition or the end of their container, as cmark does.
		block.literal = string(st.content[:])
	case .Item:
		if block.last_child != nil {
			block.end_line = block.last_child.end_line
		} else {
			block.end_line = block.start_line
		}
	case .List:
		finalize_list(block)
	}
	p.tip = above
	return nil
}

@(private)
ends_with_blank_line :: proc(block: ^Node) -> bool {
	return block.next != nil && block.end_line != block.next.start_line - 1
}

// finalize_list decides whether a list is tight: no blank line between its items or their direct children.
@(private)
finalize_list :: proc(list: ^Node) {
	tight := true
	outer: for item := list.first_child; item != nil; item = item.next {
		if item.next != nil && ends_with_blank_line(item) {
			tight = false
			break
		}
		for sub := item.first_child; sub != nil; sub = sub.next {
			if sub.next != nil && ends_with_blank_line(sub) {
				tight = false
				break outer
			}
		}
	}
	list.list.tight = tight
	for item := list.first_child; item != nil; item = item.next {
		item.list.tight = tight
	}
	if list.last_child != nil {
		list.end_line = list.last_child.end_line
	}
}

// next_block_preorder walks the block tree without descending into leaf blocks.
@(private)
next_block_preorder :: proc(node, root: ^Node) -> ^Node {
	#partial switch node.kind {
	case .Document, .Block_Quote, .List, .Item, .Table, .Table_Row:
		if node.first_child != nil {
			return node.first_child
		}
	}
	for n := node; n != root; n = n.parent {
		if n.next != nil {
			return n.next
		}
	}
	return nil
}

@(private)
process_inlines :: proc(p: ^Parser, root: ^Node) -> Error {
	for node := root; node != nil; {
		// Find the next block first, because a paragraph may unlink itself.
		next := next_block_preorder(node, root)
		#partial switch node.kind {
		case .Paragraph:
			if node.state.refs_only {
				unlink(node)
			} else {
				parse_inlines(p, node) or_return
			}
		case .Heading, .Table_Cell:
			parse_inlines(p, node) or_return
		}
		node.state.content = nil
		node.state.text = ""
		node = next
	}
	return nil
}
