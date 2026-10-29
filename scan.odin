package markdown

// Scanners for raw HTML, autolinks and HTML block starts. Each takes the text
// at a candidate position and returns how many bytes match, or 0.

@(private)
is_tag_whitespace :: #force_inline proc "contextless" (c: int) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v'
}

@(private)
skip_tag_whitespace :: proc(s: string, i: int) -> int {
	j := i
	for j < len(s) && is_tag_whitespace(int(s[j])) {
		j += 1
	}
	return j
}

@(private)
index_of :: proc(s, needle: string, from: int) -> int {
	for i in from ..= len(s) - len(needle) {
		if s[i:i + len(needle)] == needle {
			return i
		}
	}
	return -1
}

// scan_tag_name returns the end of an HTML tag name starting at `i`, or -1.
@(private)
scan_tag_name :: proc(s: string, i: int) -> int {
	if !is_ascii_alpha(peek(s, i)) {
		return -1
	}
	j := i + 1
	for j < len(s) && (is_ascii_alnum(int(s[j])) || s[j] == '-') {
		j += 1
	}
	return j
}

// scan_open_tag matches an HTML open tag such as `<a href="x" b>` at the start of `s`.
@(private)
scan_open_tag :: proc(s: string) -> int {
	if peek(s, 0) != '<' {
		return 0
	}
	i := scan_tag_name(s, 1)
	if i < 0 {
		return 0
	}
	for {
		j := skip_tag_whitespace(s, i)
		c := peek(s, j)
		if c == '>' {
			return j + 1
		}
		if c == '/' {
			return j + 2 if peek(s, j + 1) == '>' else 0
		}
		if j == i {
			// An attribute needs whitespace before it.
			return 0
		}
		if !(is_ascii_alpha(c) || c == '_' || c == ':') {
			return 0
		}
		k := j + 1
		for k < len(s) {
			d := int(s[k])
			if !(is_ascii_alnum(d) || d == '_' || d == '.' || d == ':' || d == '-') {
				break
			}
			k += 1
		}
		m := skip_tag_whitespace(s, k)
		if peek(s, m) != '=' {
			i = k
			continue
		}
		m = skip_tag_whitespace(s, m + 1)
		q := peek(s, m)
		if q == -1 {
			return 0
		}
		if q == '"' || q == '\'' {
			e := m + 1
			for e < len(s) && int(s[e]) != q {
				e += 1
			}
			if e >= len(s) {
				return 0
			}
			i = e + 1
		} else {
			start := m
			for m < len(s) {
				d := int(s[m])
				if d <= ' ' || d == '"' || d == '\'' || d == '=' || d == '<' || d == '>' || d == '`' {
					break
				}
				m += 1
			}
			if m == start {
				return 0
			}
			i = m
		}
	}
}

// scan_closing_tag matches an HTML closing tag such as `</div >` at the start of `s`.
@(private)
scan_closing_tag :: proc(s: string) -> int {
	if peek(s, 0) != '<' || peek(s, 1) != '/' {
		return 0
	}
	i := scan_tag_name(s, 2)
	if i < 0 {
		return 0
	}
	i = skip_tag_whitespace(s, i)
	return i + 1 if peek(s, i) == '>' else 0
}

/*
scan_html_tag matches any raw HTML the spec allows inline: open and closing
tags, comments, processing instructions, declarations and CDATA sections.
*/
@(private)
scan_html_tag :: proc(s: string) -> int {
	if len(s) < 3 || s[0] != '<' {
		return 0
	}
	switch s[1] {
	case '/':
		return scan_closing_tag(s)
	case '?':
		e := index_of(s, "?>", 2)
		return e + 2 if e >= 0 else 0
	case '!':
		if len(s) >= 4 && s[:4] == "<!--" {
			if len(s) >= 5 && s[:5] == "<!-->" {
				return 5
			}
			if len(s) >= 6 && s[:6] == "<!--->" {
				return 6
			}
			e := index_of(s, "-->", 4)
			return e + 3 if e >= 0 else 0
		}
		if len(s) >= 9 && s[:9] == "<![CDATA[" {
			e := index_of(s, "]]>", 9)
			return e + 3 if e >= 0 else 0
		}
		if is_ascii_alpha(int(s[2])) {
			e := index_of(s, ">", 2)
			return e + 1 if e >= 0 else 0
		}
		return 0
	}
	return scan_open_tag(s)
}

// scan_autolink_uri matches `<scheme:rest>` with a 2 to 32 character scheme.
@(private)
scan_autolink_uri :: proc(s: string) -> int {
	if peek(s, 0) != '<' || !is_ascii_alpha(peek(s, 1)) {
		return 0
	}
	i := 2
	for i < len(s) && (is_ascii_alnum(int(s[i])) || s[i] == '+' || s[i] == '.' || s[i] == '-') {
		i += 1
	}
	scheme_len := i - 1
	if scheme_len < 2 || scheme_len > 32 || peek(s, i) != ':' {
		return 0
	}
	i += 1
	for i < len(s) {
		c := s[i]
		if c == '>' {
			return i + 1
		}
		if c == '<' || c <= ' ' {
			return 0
		}
		i += 1
	}
	return 0
}

// scan_autolink_email matches `<local@domain>` using the HTML5 email grammar the spec references.
@(private)
scan_autolink_email :: proc(s: string) -> int {
	if peek(s, 0) != '<' {
		return 0
	}
	i := 1
	for i < len(s) && is_email_local_char(int(s[i])) {
		i += 1
	}
	if i == 1 || peek(s, i) != '@' {
		return 0
	}
	i += 1
	for {
		start := i
		if !is_ascii_alnum(peek(s, i)) {
			return 0
		}
		for i < len(s) && (is_ascii_alnum(int(s[i])) || s[i] == '-') {
			i += 1
		}
		if i - start > 63 || s[i - 1] == '-' {
			return 0
		}
		c := peek(s, i)
		if c == '>' {
			return i + 1
		}
		if c != '.' {
			return 0
		}
		i += 1
	}
}

@(private)
is_email_local_char :: proc "contextless" (c: int) -> bool {
	if is_ascii_alnum(c) {
		return true
	}
	switch c {
	case '.', '!', '#', '$', '%', '&', '\'', '*', '+', '/', '=', '?', '^', '_', '`', '{', '|', '}', '~', '-':
		return true
	}
	return false
}

@(private, rodata)
HTML_BLOCK_TAGS := [?]string{
	"address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col",
	"colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure",
	"footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr",
	"html", "iframe", "legend", "li", "link", "main", "menu", "menuitem", "nav", "noframes", "ol",
	"optgroup", "option", "p", "param", "search", "section", "summary", "table", "tbody", "td", "tfoot",
	"th", "thead", "title", "tr", "track", "ul",
}

@(private, rodata)
HTML_RAW_TAGS := [?]string{"pre", "script", "style", "textarea"}

@(private)
equal_fold :: proc(a, b: string) -> bool {
	return len(a) == len(b) && has_prefix_fold(a, b)
}

/*
html_block_start returns the HTML block type, 1 to 7, that a line starting
with `s` opens, or 0. Type 7 can't interrupt a paragraph, so callers pass
`can_be_type_7 = false` while a paragraph is open.
*/
@(private)
html_block_start :: proc(s: string, can_be_type_7: bool) -> int {
	if peek(s, 0) != '<' {
		return 0
	}
	// Type 1: <pre, <script, <style or <textarea.
	for tag in HTML_RAW_TAGS {
		if has_prefix_fold(s[1:], tag) {
			c := peek(s, 1 + len(tag))
			if c == -1 || c == '>' || is_tag_whitespace(c) {
				return 1
			}
		}
	}
	if len(s) >= 4 && s[:4] == "<!--" {
		return 2
	}
	if peek(s, 1) == '?' {
		return 3
	}
	if len(s) >= 9 && s[:9] == "<![CDATA[" {
		return 5
	}
	if peek(s, 1) == '!' && is_ascii_alpha(peek(s, 2)) {
		return 4
	}
	// Type 6: a known block-level tag name.
	name_start := 2 if peek(s, 1) == '/' else 1
	name_end := name_start
	for name_end < len(s) && is_ascii_alnum(int(s[name_end])) {
		name_end += 1
	}
	if name_end > name_start {
		name := s[name_start:name_end]
		for tag in HTML_BLOCK_TAGS {
			if equal_fold(name, tag) {
				c := peek(s, name_end)
				if c == -1 || c == '>' || is_tag_whitespace(c) || (c == '/' && peek(s, name_end + 1) == '>') {
					return 6
				}
				break
			}
		}
	}
	if !can_be_type_7 {
		return 0
	}
	// Type 7: one complete open or closing tag, then only whitespace.
	// The spec text excludes pre, script, style and textarea here, but a line
	// that opens one of those as type 1 never reaches this point. Like cmark and
	// commonmark.js, accept the rest, such as `</pre>` or `<pre/>`.
	n := scan_closing_tag(s) if peek(s, 1) == '/' else scan_open_tag(s)
	if n == 0 || !is_blank(s[n:]) {
		return 0
	}
	return 7
}

// html_block_ends reports whether `line` contains the end condition of HTML block type 1 to 5.
@(private)
html_block_ends :: proc(html_type: int, line: string) -> bool {
	switch html_type {
	case 1:
		for tag in HTML_RAW_TAGS {
			buf: [16]byte
			closing := append_bytes(buf[:], "</", tag, ">")
			if contains_fold(line, string(closing)) {
				return true
			}
		}
		return false
	case 2:
		return contains(line, "-->")
	case 3:
		return contains(line, "?>")
	case 4:
		return contains(line, ">")
	case 5:
		return contains(line, "]]>")
	}
	return false
}

@(private)
append_bytes :: proc(buf: []byte, parts: ..string) -> []byte {
	n := 0
	for part in parts {
		n += copy(buf[n:], part)
	}
	return buf[:n]
}
