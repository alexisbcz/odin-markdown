package markdown

import "base:runtime"
import "core:unicode/utf8"

// The inline parser follows the reference implementation: a single left to
// right pass that builds text nodes, a delimiter stack for emphasis and a
// bracket stack for links and images.

@(private)
Delimiter :: struct {
	cc:         byte,
	numdelims:  int,
	origdelims: int,
	node:       ^Node,
	previous:   ^Delimiter,
	next:       ^Delimiter,
	can_open:   bool,
	can_close:  bool,
}

@(private)
Bracket :: struct {
	node:               ^Node,
	previous:           ^Bracket,
	previous_delimiter: ^Delimiter,
	index:              int,
	image:              bool,
	active:             bool,
	bracket_after:      bool,
}

@(private)
TICK_CACHE_SIZE :: 64

@(private)
Inline_Parser :: struct {
	p:                ^Parser,
	allocator:        runtime.Allocator,
	subject:          string,
	pos:              int,
	delimiters:       ^Delimiter,
	brackets:         ^Bracket,
	// no_closing_ticks[n] is true once a scan found no closing run of n backticks after some opener.
	no_closing_ticks: [TICK_CACHE_SIZE]bool,
}

@(private)
parse_inlines :: proc(p: ^Parser, block: ^Node) -> Error {
	ip := Inline_Parser {
		p         = p,
		allocator = p.allocator,
		subject   = trim_ascii_whitespace(block.state.text),
	}
	for ip.pos < len(ip.subject) {
		parse_inline(&ip, block) or_return
	}
	return process_emphasis(&ip, nil)
}

@(private)
add_inline :: proc(ip: ^Inline_Parser, block: ^Node, kind: Node_Kind) -> (node: ^Node, err: runtime.Allocator_Error) {
	node = new_node(kind, ip.allocator) or_return
	append_child(block, node)
	return node, nil
}

@(private)
add_text :: proc(ip: ^Inline_Parser, block: ^Node, s: string) -> (node: ^Node, err: runtime.Allocator_Error) {
	node = add_inline(ip, block, .Text) or_return
	node.literal = s
	return node, nil
}

@(private)
is_special_char :: proc(ip: ^Inline_Parser, c: byte) -> bool {
	switch c {
	case '\n', '`', '[', ']', '\\', '!', '<', '&', '*', '_':
		return true
	case '~':
		return .Strikethrough in ip.p.options.extensions
	}
	return false
}

@(private)
parse_inline :: proc(ip: ^Inline_Parser, block: ^Node) -> Error {
	c := ip.subject[ip.pos]
	handled := true
	switch c {
	case '\n':
		parse_newline(ip, block) or_return
	case '\\':
		parse_backslash(ip, block) or_return
	case '`':
		parse_backticks(ip, block) or_return
	case '*', '_':
		handle_delim(ip, block, c) or_return
	case '~':
		if .Strikethrough in ip.p.options.extensions {
			handle_delim(ip, block, c) or_return
		} else {
			parse_string(ip, block) or_return
		}
	case '[':
		parse_open_bracket(ip, block) or_return
	case '!':
		parse_bang(ip, block) or_return
	case ']':
		parse_close_bracket(ip, block) or_return
	case '<':
		handled = parse_autolink(ip, block) or_return
		if !handled {
			handled = parse_html_tag(ip, block) or_return
		}
	case '&':
		handled = parse_entity(ip, block) or_return
	case:
		parse_string(ip, block) or_return
	}
	if !handled {
		add_text(ip, block, ip.subject[ip.pos:ip.pos + 1]) or_return
		ip.pos += 1
	}
	return nil
}

@(private)
parse_string :: proc(ip: ^Inline_Parser, block: ^Node) -> runtime.Allocator_Error {
	start := ip.pos
	ip.pos += 1
	for ip.pos < len(ip.subject) && !is_special_char(ip, ip.subject[ip.pos]) {
		ip.pos += 1
	}
	_, err := add_text(ip, block, ip.subject[start:ip.pos])
	return err
}

@(private)
parse_newline :: proc(ip: ^Inline_Parser, block: ^Node) -> runtime.Allocator_Error {
	ip.pos += 1
	kind := Node_Kind.Soft_Break
	last := block.last_child
	if last != nil && last.kind == .Text && len(last.literal) > 0 && last.literal[len(last.literal) - 1] == ' ' {
		lit := last.literal
		if len(lit) >= 2 && lit[len(lit) - 2] == ' ' {
			kind = .Line_Break
		}
		end := len(lit)
		for end > 0 && lit[end - 1] == ' ' {
			end -= 1
		}
		last.literal = lit[:end]
	}
	add_inline(ip, block, kind) or_return
	for ip.pos < len(ip.subject) && ip.subject[ip.pos] == ' ' {
		ip.pos += 1
	}
	return nil
}

@(private)
parse_backslash :: proc(ip: ^Inline_Parser, block: ^Node) -> runtime.Allocator_Error {
	ip.pos += 1
	c := peek(ip.subject, ip.pos)
	if c == '\n' {
		ip.pos += 1
		add_inline(ip, block, .Line_Break) or_return
	} else if is_ascii_punct(c) {
		add_text(ip, block, ip.subject[ip.pos:ip.pos + 1]) or_return
		ip.pos += 1
	} else {
		add_text(ip, block, "\\") or_return
	}
	return nil
}

@(private)
parse_backticks :: proc(ip: ^Inline_Parser, block: ^Node) -> runtime.Allocator_Error {
	s := ip.subject
	start := ip.pos
	for ip.pos < len(s) && s[ip.pos] == '`' {
		ip.pos += 1
	}
	ticks := ip.pos - start
	after_open := ip.pos
	if ticks >= TICK_CACHE_SIZE || !ip.no_closing_ticks[ticks] {
		for i := after_open; i < len(s); {
			if s[i] != '`' {
				i += 1
				continue
			}
			j := i
			for j < len(s) && s[j] == '`' {
				j += 1
			}
			if j - i == ticks {
				node := add_inline(ip, block, .Code) or_return
				node.literal = code_span_content(s[after_open:i], ip.allocator) or_return
				ip.pos = j
				return nil
			}
			i = j
		}
		if ticks < TICK_CACHE_SIZE {
			ip.no_closing_ticks[ticks] = true
		}
	}
	_, err := add_text(ip, block, s[start:after_open])
	return err
}

// code_span_content turns line endings into spaces and strips one space from each side when both are present.
@(private)
code_span_content :: proc(raw: string, allocator: runtime.Allocator) -> (result: string, err: runtime.Allocator_Error) {
	s := raw
	has_newline := false
	for i in 0 ..< len(s) {
		if s[i] == '\n' {
			has_newline = true
			break
		}
	}
	if has_newline {
		buf := make([]byte, len(s), allocator) or_return
		for i in 0 ..< len(s) {
			buf[i] = ' ' if s[i] == '\n' else s[i]
		}
		s = string(buf)
	}
	if len(s) >= 2 && s[0] == ' ' && s[len(s) - 1] == ' ' {
		for i in 0 ..< len(s) {
			if s[i] != ' ' {
				return s[1:len(s) - 1], nil
			}
		}
	}
	return s, nil
}

// scan_delims counts a run of `cc` at the current position and works out whether it can open or close emphasis.
@(private)
scan_delims :: proc(ip: ^Inline_Parser, cc: byte) -> (numdelims: int, can_open, can_close: bool) {
	s := ip.subject
	start := ip.pos
	before: rune = '\n'
	if start > 0 {
		before, _ = utf8.decode_last_rune_in_string(s[:start])
	}
	i := start
	for i < len(s) && s[i] == cc {
		i += 1
	}
	numdelims = i - start
	after: rune = '\n'
	if i < len(s) {
		after, _ = utf8.decode_rune_in_string(s[i:])
	}
	after_ws := is_unicode_whitespace(after)
	after_punct := is_unicode_punct(after)
	before_ws := is_unicode_whitespace(before)
	before_punct := is_unicode_punct(before)
	left_flanking := !after_ws && (!after_punct || before_ws || before_punct)
	right_flanking := !before_ws && (!before_punct || after_ws || after_punct)
	if cc == '_' {
		can_open = left_flanking && (!right_flanking || before_punct)
		can_close = right_flanking && (!left_flanking || after_punct)
	} else {
		can_open = left_flanking
		can_close = right_flanking
	}
	return
}

@(private)
handle_delim :: proc(ip: ^Inline_Parser, block: ^Node, cc: byte) -> runtime.Allocator_Error {
	numdelims, can_open, can_close := scan_delims(ip, cc)
	start := ip.pos
	ip.pos += numdelims
	node := add_text(ip, block, ip.subject[start:ip.pos]) or_return
	if cc == '~' && numdelims > 2 {
		// GFM strikethrough uses one or two tildes; longer runs stay literal.
		return nil
	}
	if can_open || can_close {
		d := new(Delimiter, ip.allocator) or_return
		d^ = Delimiter {
			cc         = cc,
			numdelims  = numdelims,
			origdelims = numdelims,
			node       = node,
			previous   = ip.delimiters,
			can_open   = can_open,
			can_close  = can_close,
		}
		if d.previous != nil {
			d.previous.next = d
		}
		ip.delimiters = d
	}
	return nil
}

@(private)
remove_delimiter :: proc(ip: ^Inline_Parser, d: ^Delimiter) {
	if d.previous != nil {
		d.previous.next = d.next
	}
	if d.next == nil {
		ip.delimiters = d.previous
	} else {
		d.next.previous = d.previous
	}
}

@(private)
delimiter_index :: proc(cc: byte) -> int {
	switch cc {
	case '*':
		return 0
	case '_':
		return 1
	}
	return 2
}

// process_emphasis runs the spec's "process emphasis" procedure on delimiters above `stack_bottom`.
@(private)
process_emphasis :: proc(ip: ^Inline_Parser, stack_bottom: ^Delimiter) -> Error {
	openers_bottom: [3][6]^Delimiter
	for &row in openers_bottom {
		for &bottom in row {
			bottom = stack_bottom
		}
	}
	closer := ip.delimiters
	for closer != nil && closer.previous != stack_bottom {
		closer = closer.previous
	}
	for closer != nil {
		if !closer.can_close {
			closer = closer.next
			continue
		}
		ci := delimiter_index(closer.cc)
		bi := (3 if closer.can_open else 0) + closer.origdelims % 3
		opener := closer.previous
		found := false
		for opener != nil && opener != stack_bottom && opener != openers_bottom[ci][bi] {
			if opener.cc == closer.cc && opener.can_open {
				if closer.cc == '~' {
					if opener.numdelims == closer.numdelims {
						found = true
						break
					}
				} else {
					odd_match :=
						(closer.can_open || opener.can_close) &&
						closer.origdelims % 3 != 0 &&
						(opener.origdelims + closer.origdelims) % 3 == 0
					if !odd_match {
						found = true
						break
					}
				}
			}
			opener = opener.previous
		}
		if !found {
			old_closer := closer
			closer = closer.next
			openers_bottom[ci][bi] = old_closer.previous
			if !old_closer.can_open {
				remove_delimiter(ip, old_closer)
			}
			continue
		}

		use: int
		kind: Node_Kind
		if closer.cc == '~' {
			use = closer.numdelims
			kind = .Strikethrough
		} else {
			use = 2 if closer.numdelims >= 2 && opener.numdelims >= 2 else 1
			kind = .Strong if use == 2 else .Emphasis
		}
		opener_inl := opener.node
		closer_inl := closer.node
		opener.numdelims -= use
		closer.numdelims -= use
		opener_inl.literal = opener_inl.literal[:len(opener_inl.literal) - use]
		closer_inl.literal = closer_inl.literal[:len(closer_inl.literal) - use]

		emph := new_node(kind, ip.allocator) or_return
		for tmp := opener_inl.next; tmp != nil && tmp != closer_inl; {
			next := tmp.next
			unlink(tmp)
			append_child(emph, tmp)
			tmp = next
		}
		insert_after(opener_inl, emph)

		// Drop the delimiters between opener and closer; they can no longer match.
		if opener.next != closer {
			opener.next = closer
			closer.previous = opener
		}
		if opener.numdelims == 0 {
			unlink(opener_inl)
			remove_delimiter(ip, opener)
		}
		if closer.numdelims == 0 {
			unlink(closer_inl)
			next := closer.next
			remove_delimiter(ip, closer)
			closer = next
		}
	}
	for ip.delimiters != nil && ip.delimiters != stack_bottom {
		remove_delimiter(ip, ip.delimiters)
	}
	return nil
}

@(private)
add_bracket :: proc(ip: ^Inline_Parser, node: ^Node, index: int, image: bool) -> runtime.Allocator_Error {
	if ip.brackets != nil {
		ip.brackets.bracket_after = true
	}
	b := new(Bracket, ip.allocator) or_return
	b^ = Bracket {
		node               = node,
		previous           = ip.brackets,
		previous_delimiter = ip.delimiters,
		index              = index,
		image              = image,
		active             = true,
	}
	ip.brackets = b
	return nil
}

@(private)
parse_open_bracket :: proc(ip: ^Inline_Parser, block: ^Node) -> runtime.Allocator_Error {
	start := ip.pos
	ip.pos += 1
	node := add_text(ip, block, "[") or_return
	return add_bracket(ip, node, start, false)
}

@(private)
parse_bang :: proc(ip: ^Inline_Parser, block: ^Node) -> runtime.Allocator_Error {
	start := ip.pos
	ip.pos += 1
	if peek(ip.subject, ip.pos) == '[' {
		ip.pos += 1
		node := add_text(ip, block, "![") or_return
		return add_bracket(ip, node, start + 1, true)
	}
	_, err := add_text(ip, block, "!")
	return err
}

// spnl skips optional spaces and tabs, including up to one line ending.
@(private)
spnl :: proc(ip: ^Inline_Parser) {
	s := ip.subject
	for ip.pos < len(s) && is_space_or_tab(int(s[ip.pos])) {
		ip.pos += 1
	}
	if ip.pos < len(s) && s[ip.pos] == '\n' {
		ip.pos += 1
		for ip.pos < len(s) && is_space_or_tab(int(s[ip.pos])) {
			ip.pos += 1
		}
	}
}

// parse_link_label consumes a link label like `[foo]` and returns its length, or 0 without moving.
@(private)
parse_link_label :: proc(ip: ^Inline_Parser) -> int {
	s := ip.subject
	start := ip.pos
	if peek(s, start) != '[' {
		return 0
	}
	chars := 0
	for i := start + 1; i < len(s); {
		c := s[i]
		switch c {
		case '\\':
			if i + 1 >= len(s) {
				return 0
			}
			i += 2
			chars += 2
			continue
		case '[':
			return 0
		case ']':
			if chars > 999 {
				return 0
			}
			ip.pos = i + 1
			return i + 1 - start
		}
		if c & 0xC0 != 0x80 {
			chars += 1
		}
		i += 1
	}
	return 0
}

// parse_link_destination consumes a link destination and returns it unescaped and percent-encoded.
@(private)
parse_link_destination :: proc(ip: ^Inline_Parser) -> (dest: string, ok: bool, err: runtime.Allocator_Error) {
	s := ip.subject
	start := ip.pos
	raw: string
	if peek(s, start) == '<' {
		i := start + 1
		for {
			if i >= len(s) {
				return "", false, nil
			}
			c := s[i]
			if c == '\\' && i + 1 < len(s) && s[i + 1] != '\n' {
				i += 2
				continue
			}
			if c == '>' {
				break
			}
			if c == '<' || c == '\n' || c == '\\' {
				return "", false, nil
			}
			i += 1
		}
		raw = s[start + 1:i]
		ip.pos = i + 1
	} else {
		i := start
		parens := 0
		for i < len(s) {
			c := s[i]
			if c == '\\' && i + 1 < len(s) && is_ascii_punct(int(s[i + 1])) {
				i += 2
				continue
			}
			if c == '(' {
				parens += 1
			} else if c == ')' {
				if parens < 1 {
					break
				}
				parens -= 1
			} else if c <= ' ' || c == 0x7F {
				break
			}
			i += 1
		}
		if (i == start && peek(s, i) != ')') || parens != 0 {
			return "", false, nil
		}
		raw = s[start:i]
		ip.pos = i
	}
	unescaped := unescape_string(raw, ip.allocator) or_return
	dest = normalize_uri(unescaped, ip.allocator) or_return
	return dest, true, nil
}

// parse_link_title consumes a quoted or parenthesized link title and returns it unescaped.
@(private)
parse_link_title :: proc(ip: ^Inline_Parser) -> (title: string, ok: bool, err: runtime.Allocator_Error) {
	s := ip.subject
	start := ip.pos
	open := peek(s, start)
	close: int
	switch open {
	case '"', '\'':
		close = open
	case '(':
		close = ')'
	case:
		return "", false, nil
	}
	for i := start + 1; i < len(s); i += 1 {
		c := int(s[i])
		if c == '\\' && i + 1 < len(s) && is_ascii_punct(int(s[i + 1])) {
			i += 1
			continue
		}
		if c == close {
			title = unescape_string(s[start + 1:i], ip.allocator) or_return
			ip.pos = i + 1
			return title, true, nil
		}
		if open == '(' && c == '(' {
			return "", false, nil
		}
	}
	return "", false, nil
}

@(private)
parse_close_bracket :: proc(ip: ^Inline_Parser, block: ^Node) -> Error {
	s := ip.subject
	ip.pos += 1
	start := ip.pos
	opener := ip.brackets
	if opener == nil {
		add_text(ip, block, "]") or_return
		return nil
	}
	if !opener.active {
		add_text(ip, block, "]") or_return
		ip.brackets = opener.previous
		return nil
	}
	is_image := opener.image
	matched := false
	dest, title: string

	// An inline link: `(destination "title")`.
	if peek(s, ip.pos) == '(' {
		ip.pos += 1
		spnl(ip)
		d, ok := parse_link_destination(ip) or_return
		if ok {
			dest = d
			spnl(ip)
			if is_ascii_whitespace(peek(s, ip.pos - 1)) {
				t, has_title := parse_link_title(ip) or_return
				if has_title {
					title = t
				}
			}
			spnl(ip)
			if peek(s, ip.pos) == ')' {
				ip.pos += 1
				matched = true
			}
		}
		if !matched {
			ip.pos = start
			title = ""
		}
	}

	// A full, collapsed or shortcut reference link.
	if !matched {
		before_label := ip.pos
		n := parse_link_label(ip)
		label: string
		has_label := false
		if n > 2 {
			label = s[before_label:before_label + n]
			has_label = true
		} else if !opener.bracket_after {
			label = s[opener.index:start]
			has_label = true
		}
		if n == 0 {
			ip.pos = start
		}
		if has_label {
			key := normalize_reference(label, ip.allocator) or_return
			if ref, found := ip.p.refmap[key]; found {
				dest = ref.destination
				title = ref.title
				matched = true
			}
		}
	}

	if !matched {
		ip.brackets = opener.previous
		ip.pos = start
		add_text(ip, block, "]") or_return
		return nil
	}

	node := add_inline(ip, block, .Image if is_image else .Link) or_return
	node.destination = dest
	node.title = title
	// Move everything after the opening bracket into the link.
	for tmp := opener.node.next; tmp != nil && tmp != node; {
		next := tmp.next
		unlink(tmp)
		append_child(node, tmp)
		tmp = next
	}
	process_emphasis(ip, opener.previous_delimiter) or_return
	ip.brackets = opener.previous
	unlink(opener.node)
	// Links can't contain other links, so deactivate earlier link openers.
	if !is_image {
		for b := ip.brackets; b != nil; b = b.previous {
			if !b.image {
				b.active = false
			}
		}
	}
	return nil
}

@(private)
parse_autolink :: proc(ip: ^Inline_Parser, block: ^Node) -> (handled: bool, err: Error) {
	rest := ip.subject[ip.pos:]
	dest: string
	n := scan_autolink_email(rest)
	if n > 0 {
		inner := rest[1:n - 1]
		buf := make([dynamic]byte, 0, len(inner) + 7, ip.allocator) or_return
		write_string(&buf, "mailto:") or_return
		write_string(&buf, inner) or_return
		dest = normalize_uri(string(buf[:]), ip.allocator) or_return
	} else {
		n = scan_autolink_uri(rest)
		if n == 0 {
			return false, nil
		}
		dest = normalize_uri(rest[1:n - 1], ip.allocator) or_return
	}
	link := add_inline(ip, block, .Link) or_return
	link.destination = dest
	add_text(ip, link, rest[1:n - 1]) or_return
	ip.pos += n
	return true, nil
}

@(private)
parse_html_tag :: proc(ip: ^Inline_Parser, block: ^Node) -> (handled: bool, err: Error) {
	n := scan_html_tag(ip.subject[ip.pos:])
	if n == 0 {
		return false, nil
	}
	node := add_inline(ip, block, .Html_Inline) or_return
	node.literal = ip.subject[ip.pos:ip.pos + n]
	ip.pos += n
	return true, nil
}

@(private)
parse_entity :: proc(ip: ^Inline_Parser, block: ^Node) -> (handled: bool, err: Error) {
	n, named, code := scan_entity(ip.subject[ip.pos:])
	if n == 0 {
		return false, nil
	}
	value := named
	if value == "" {
		buf := make([dynamic]byte, 0, 4, ip.allocator) or_return
		write_rune(&buf, code) or_return
		value = string(buf[:])
	}
	add_text(ip, block, value) or_return
	ip.pos += n
	return true, nil
}

/*
parse_reference consumes one link reference definition at the start of `s`
and records it, unless the label is already defined. It returns the number
of bytes consumed, or 0 when `s` doesn't start with a definition.
*/
@(private)
parse_reference :: proc(p: ^Parser, s: string) -> (consumed: int, err: Error) {
	ip := Inline_Parser {
		p         = p,
		allocator = p.allocator,
		subject   = s,
	}
	n := parse_link_label(&ip)
	if n == 0 {
		return 0, nil
	}
	label := s[:n]
	if peek(s, ip.pos) != ':' {
		return 0, nil
	}
	ip.pos += 1
	spnl(&ip)
	dest, ok := parse_link_destination(&ip) or_return
	if !ok {
		return 0, nil
	}
	before_title := ip.pos
	spnl(&ip)
	title: string
	has_title := false
	if ip.pos != before_title {
		title, has_title = parse_link_title(&ip) or_return
	}
	if !has_title {
		ip.pos = before_title
	}
	if !at_line_end(&ip) {
		if !has_title {
			return 0, nil
		}
		// The title isn't followed by a line ending, but the definition may still end before it.
		title = ""
		ip.pos = before_title
		if !at_line_end(&ip) {
			return 0, nil
		}
	}
	key := normalize_reference(label, p.allocator) or_return
	if key == "" {
		return 0, nil
	}
	// The first definition of a label wins.
	_, value, inserted := map_entry(&p.refmap, key) or_return
	if inserted {
		value^ = Reference{destination = dest, title = title}
	}
	return ip.pos, nil
}

// at_line_end skips spaces and tabs and consumes a line ending, or reports false without moving.
@(private)
at_line_end :: proc(ip: ^Inline_Parser) -> bool {
	i := ip.pos
	for i < len(ip.subject) && is_space_or_tab(int(ip.subject[i])) {
		i += 1
	}
	if i == len(ip.subject) {
		ip.pos = i
		return true
	}
	if ip.subject[i] == '\n' {
		ip.pos = i + 1
		return true
	}
	return false
}
