package markdown

import "base:runtime"

// GFM pipe tables. A table starts when the line after a paragraph line is a
// delimiter row with as many cells as that line. Rows continue until a blank
// line or the start of another block.

// split_row splits a table row into trimmed cells on unescaped pipes. Leading and trailing pipes are optional.
@(private)
split_row :: proc(line: string, allocator: runtime.Allocator) -> (cells: [dynamic]string, err: runtime.Allocator_Error) {
	cells = make([dynamic]string, 0, 8, allocator) or_return
	s := trim_ascii_whitespace(line)
	if len(s) > 0 && s[0] == '|' {
		s = s[1:]
	}
	if len(s) > 0 && s[len(s) - 1] == '|' && (len(s) < 2 || s[len(s) - 2] != '\\') {
		s = s[:len(s) - 1]
	}
	start := 0
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' {
			i += 1
			continue
		}
		if s[i] == '|' {
			append(&cells, trim_spaces_tabs(s[start:i])) or_return
			start = i + 1
		}
	}
	append(&cells, trim_spaces_tabs(s[start:])) or_return
	return cells, nil
}

// has_unescaped_pipe reports whether `s` contains a `|` that isn't preceded by a backslash.
@(private)
has_unescaped_pipe :: proc(s: string) -> bool {
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' {
			i += 1
		} else if s[i] == '|' {
			return true
		}
	}
	return false
}

// parse_delimiter_row returns the column alignments of a delimiter row like `| :-- | :-: |`, or ok = false.
@(private)
parse_delimiter_row :: proc(line: string, allocator: runtime.Allocator) -> (alignments: []Alignment, ok: bool, err: runtime.Allocator_Error) {
	cells := split_row(line, allocator) or_return
	result := make([]Alignment, len(cells), allocator) or_return
	for cell, i in cells {
		if len(cell) == 0 {
			return nil, false, nil
		}
		left := cell[0] == ':'
		right := cell[len(cell) - 1] == ':'
		lo := 1 if left else 0
		hi := len(cell) - 1 if right else len(cell)
		if lo >= hi {
			return nil, false, nil
		}
		dashes := cell[lo:hi]
		if len(dashes) == 0 {
			return nil, false, nil
		}
		for j in 0 ..< len(dashes) {
			if dashes[j] != '-' {
				return nil, false, nil
			}
		}
		switch {
		case left && right:
			result[i] = .Center
		case left:
			result[i] = .Left
		case right:
			result[i] = .Right
		case:
			result[i] = .None
		}
	}
	return result, true, nil
}

// unescape_pipes replaces `\|` with `|` in a cell, as GFM does before inline parsing.
@(private)
unescape_pipes :: proc(s: string, allocator: runtime.Allocator) -> (result: string, err: runtime.Allocator_Error) {
	buf := make([dynamic]byte, 0, len(s), allocator) or_return
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 1 < len(s) && s[i + 1] == '|' {
			continue
		}
		write_byte(&buf, s[i]) or_return
	}
	return string(buf[:]), nil
}

// add_row appends a row to `table`, padding or truncating `cells` to the table's column count.
@(private)
add_row :: proc(p: ^Parser, table: ^Node, cells: []string, header: bool) -> Error {
	row := new_node(.Table_Row, p.allocator) or_return
	row.header = header
	row.start_line = p.line_number
	row.end_line = p.line_number
	append_child(table, row)
	for alignment, i in table.state.alignments {
		cell := new_node(.Table_Cell, p.allocator) or_return
		cell.alignment = alignment
		cell.header = header
		cell.start_line = p.line_number
		cell.end_line = p.line_number
		if i < len(cells) {
			cell.state.text = unescape_pipes(cells[i], p.allocator) or_return
		}
		append_child(row, cell)
	}
	return nil
}

/*
MAX_AUTOCOMPLETED_CELLS caps how many empty cells one table may add to pad
short rows. Without it a wide header over many one-cell rows renders a few KB
of input into hundreds of MB. cmark-gfm uses the same limit.
*/
@(private)
MAX_AUTOCOMPLETED_CELLS :: 0x80000

// add_table_row appends the body row in `line`, or returns added = false when padding it would pass MAX_AUTOCOMPLETED_CELLS.
@(private)
add_table_row :: proc(p: ^Parser, table: ^Node, line: string) -> (added: bool, err: Error) {
	cells := split_row(line, p.allocator) or_return
	missing := max(len(table.state.alignments) - len(cells), 0)
	if table.state.autocompleted + missing > MAX_AUTOCOMPLETED_CELLS {
		return false, nil
	}
	table.state.autocompleted += missing
	add_row(p, table, cells[:], false) or_return
	return true, nil
}

@(private)
start_table :: proc(p: ^Parser, container: ^Node) -> (result: int, err: Error) {
	if p.indented || container.kind != .Paragraph {
		return 0, nil
	}
	delimiter_line := p.line[p.next_nonspace:]
	c := peek(delimiter_line, 0)
	if c != '|' && c != ':' && c != '-' {
		return 0, nil
	}
	alignments, ok := parse_delimiter_row(delimiter_line, p.allocator) or_return
	if !ok {
		return 0, nil
	}
	content := string(container.state.content[:])
	// The header is the last line of the paragraph; earlier lines stay a paragraph.
	end := len(content) - 1
	line_start := end
	for line_start > 0 && content[line_start - 1] != '\n' {
		line_start -= 1
	}
	header_line := content[line_start:end]
	if !has_unescaped_pipe(header_line) && !has_unescaped_pipe(delimiter_line) {
		return 0, nil
	}
	header := split_row(header_line, p.allocator) or_return
	if len(header) != len(alignments) {
		return 0, nil
	}
	close_unmatched_blocks(p) or_return

	table := new_node(.Table, p.allocator) or_return
	table.start_line = p.line_number - 1
	table.state.open = true
	table.state.depth = container.state.depth
	table.state.alignments = alignments
	insert_after(container, table)
	saved_line := p.line_number
	p.line_number -= 1
	add_row(p, table, header[:], true) or_return
	p.line_number = saved_line

	if line_start == 0 {
		unlink(container)
	} else {
		resize(&container.state.content, line_start) or_return
		finalize(p, container, p.line_number - 2) or_return
	}
	p.tip = table
	advance_offset(p, len(p.line) - p.offset, false)
	return 2, nil
}
