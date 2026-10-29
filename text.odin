package markdown

import "base:runtime"
import "core:unicode"
import "core:unicode/utf8"

// Entity is one HTML5 named character reference.
@(private)
Entity :: struct {
	name:  string,
	value: string,
}

@(private)
peek :: #force_inline proc "contextless" (s: string, i: int) -> int {
	if i < 0 || i >= len(s) {
		return -1
	}
	return int(s[i])
}

@(private)
is_space_or_tab :: #force_inline proc "contextless" (c: int) -> bool {
	return c == ' ' || c == '\t'
}

@(private)
is_ascii_digit :: #force_inline proc "contextless" (c: int) -> bool {
	return c >= '0' && c <= '9'
}

@(private)
is_ascii_alpha :: #force_inline proc "contextless" (c: int) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

@(private)
is_ascii_alnum :: #force_inline proc "contextless" (c: int) -> bool {
	return is_ascii_alpha(c) || is_ascii_digit(c)
}

@(private)
is_hex_digit :: #force_inline proc "contextless" (c: int) -> bool {
	return is_ascii_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

// is_ascii_punct reports whether `c` is one of the characters a backslash can escape.
@(private)
is_ascii_punct :: proc "contextless" (c: int) -> bool {
	switch c {
	case '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/',
	     ':', ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^', '_', '`', '{', '|', '}', '~':
		return true
	}
	return false
}

// is_ascii_whitespace matches the characters JavaScript's trim and cmark's isspace agree on.
@(private)
is_ascii_whitespace :: #force_inline proc "contextless" (c: int) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f'
}

// is_unicode_whitespace implements the spec's "Unicode whitespace character": Zs, tab, LF, FF and CR.
@(private)
is_unicode_whitespace :: proc(r: rune) -> bool {
	switch r {
	case '\t', '\n', '\f', '\r', ' ', 0xA0, 0x1680, 0x2000 ..= 0x200A, 0x202F, 0x205F, 0x3000:
		return true
	}
	return false
}

// is_unicode_punct implements the spec's "Unicode punctuation character": categories P and S.
@(private)
is_unicode_punct :: proc(r: rune) -> bool {
	if r < 0x80 {
		return is_ascii_punct(int(r))
	}
	return unicode.is_punct(r) || unicode.is_symbol(r)
}

@(private)
trim_ascii_whitespace :: proc(s: string) -> string {
	start, end := 0, len(s)
	for start < end && is_ascii_whitespace(int(s[start])) {
		start += 1
	}
	for end > start && is_ascii_whitespace(int(s[end - 1])) {
		end -= 1
	}
	return s[start:end]
}

@(private)
trim_spaces_tabs :: proc(s: string) -> string {
	start, end := 0, len(s)
	for start < end && is_space_or_tab(int(s[start])) {
		start += 1
	}
	for end > start && is_space_or_tab(int(s[end - 1])) {
		end -= 1
	}
	return s[start:end]
}

@(private)
is_blank :: proc(s: string) -> bool {
	for i in 0 ..< len(s) {
		if !is_ascii_whitespace(int(s[i])) {
			return false
		}
	}
	return true
}

@(private)
has_prefix_fold :: proc(s, prefix: string) -> bool {
	if len(s) < len(prefix) {
		return false
	}
	for i in 0 ..< len(prefix) {
		if ascii_lower(s[i]) != ascii_lower(prefix[i]) {
			return false
		}
	}
	return true
}

@(private)
contains_fold :: proc(s, needle: string) -> bool {
	for i in 0 ..= len(s) - len(needle) {
		if has_prefix_fold(s[i:], needle) {
			return true
		}
	}
	return false
}

@(private)
contains :: proc(s, needle: string) -> bool {
	for i in 0 ..= len(s) - len(needle) {
		if s[i:i + len(needle)] == needle {
			return true
		}
	}
	return false
}

@(private)
ascii_lower :: #force_inline proc "contextless" (c: byte) -> byte {
	if c >= 'A' && c <= 'Z' {
		return c + ('a' - 'A')
	}
	return c
}

@(private)
write_string :: proc(buf: ^[dynamic]byte, s: string) -> runtime.Allocator_Error {
	_, err := append(buf, s)
	return err
}

@(private)
write_byte :: proc(buf: ^[dynamic]byte, b: byte) -> runtime.Allocator_Error {
	_, err := append(buf, b)
	return err
}

@(private)
write_rune :: proc(buf: ^[dynamic]byte, r: rune) -> runtime.Allocator_Error {
	bytes, n := utf8.encode_rune(r)
	_, err := append(buf, ..bytes[:n])
	return err
}

// lookup_entity returns the value of the named character reference `name`, given without `&` and `;`.
@(private)
lookup_entity :: proc(name: string) -> (value: string, ok: bool) {
	lo, hi := 0, len(ENTITIES)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		e := ENTITIES[mid].name
		if e == name {
			return ENTITIES[mid].value, true
		} else if e < name {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return "", false
}

/*
scan_entity recognizes an entity or numeric character reference at the start
of `s`. It returns the number of bytes it spans and the code point or named
value, or 0 when `s` doesn't start with a valid reference.
*/
@(private)
scan_entity :: proc(s: string) -> (n: int, named: string, code: rune) {
	if len(s) < 3 || s[0] != '&' {
		return 0, "", 0
	}
	if s[1] == '#' {
		i := 2
		value := 0
		digits := 0
		if i < len(s) && (s[i] == 'x' || s[i] == 'X') {
			i += 1
			for i < len(s) && is_hex_digit(int(s[i])) && digits < 7 {
				c := int(s[i])
				d := c - '0' if is_ascii_digit(c) else int(ascii_lower(s[i])) - 'a' + 10
				value = value * 16 + d
				i += 1
				digits += 1
			}
			if digits == 0 || digits > 6 {
				return 0, "", 0
			}
		} else {
			for i < len(s) && is_ascii_digit(int(s[i])) && digits < 8 {
				value = value * 10 + int(s[i] - '0')
				i += 1
				digits += 1
			}
			if digits == 0 || digits > 7 {
				return 0, "", 0
			}
		}
		if i >= len(s) || s[i] != ';' {
			return 0, "", 0
		}
		if value == 0 || value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF) {
			value = 0xFFFD
		}
		return i + 1, "", rune(value)
	}
	i := 1
	for i < len(s) && i - 1 < 32 && is_ascii_alnum(int(s[i])) {
		i += 1
	}
	if i < 3 || i >= len(s) || s[i] != ';' || !is_ascii_alpha(int(s[1])) {
		return 0, "", 0
	}
	value, ok := lookup_entity(s[1:i])
	if !ok {
		return 0, "", 0
	}
	return i + 1, value, 0
}

/*
unescape_string decodes backslash escapes and character references in `s`, as
the spec requires for link destinations, titles and info strings. It returns
`s` itself when there is nothing to decode.
*/
@(private)
unescape_string :: proc(s: string, allocator: runtime.Allocator) -> (result: string, err: runtime.Allocator_Error) {
	needs := false
	for i in 0 ..< len(s) {
		if s[i] == '\\' || s[i] == '&' {
			needs = true
			break
		}
	}
	if !needs {
		return s, nil
	}
	buf := make([dynamic]byte, 0, len(s), allocator) or_return
	i := 0
	for i < len(s) {
		c := s[i]
		if c == '\\' && i + 1 < len(s) && is_ascii_punct(int(s[i + 1])) {
			write_byte(&buf, s[i + 1]) or_return
			i += 2
			continue
		}
		if c == '&' {
			n, named, code := scan_entity(s[i:])
			if n > 0 {
				if named != "" {
					write_string(&buf, named) or_return
				} else {
					write_rune(&buf, code) or_return
				}
				i += n
				continue
			}
		}
		write_byte(&buf, c) or_return
		i += 1
	}
	return string(buf[:]), nil
}

/*
normalize_reference turns a link label into the key used to match references:
it drops the surrounding brackets, collapses internal whitespace to one space,
trims it and applies Unicode case folding.
*/
@(private)
normalize_reference :: proc(label: string, allocator: runtime.Allocator) -> (key: string, err: runtime.Allocator_Error) {
	inner := label
	if len(inner) >= 2 && inner[0] == '[' && inner[len(inner) - 1] == ']' {
		inner = inner[1:len(inner) - 1]
	}
	inner = trim_ascii_whitespace(inner)
	buf := make([dynamic]byte, 0, len(inner), allocator) or_return
	pending_space := false
	for r in inner {
		if r == ' ' || r == '\t' || r == '\n' || r == '\r' {
			pending_space = true
			continue
		}
		if pending_space {
			write_byte(&buf, ' ') or_return
			pending_space = false
		}
		lower := unicode.to_lower(r)
		if lower == 0xDF {
			// U+00DF and U+1E9E fold to "SS", as `toLowerCase().toUpperCase()` does.
			write_string(&buf, "SS") or_return
			continue
		}
		write_rune(&buf, unicode.to_upper(lower)) or_return
	}
	return string(buf[:]), nil
}

@(private, rodata)
HEX_UPPER := "0123456789ABCDEF"

/*
normalize_uri percent-encodes every byte of `s` that isn't safe in a URL,
keeping existing `%XX` escapes, the way the reference implementation does.
*/
@(private)
normalize_uri :: proc(s: string, allocator: runtime.Allocator) -> (result: string, err: runtime.Allocator_Error) {
	needs := false
	for i in 0 ..< len(s) {
		if !uri_byte_is_safe(s, i) {
			needs = true
			break
		}
	}
	if !needs {
		return s, nil
	}
	buf := make([dynamic]byte, 0, len(s) + 16, allocator) or_return
	for i in 0 ..< len(s) {
		c := s[i]
		if uri_byte_is_safe(s, i) {
			write_byte(&buf, c) or_return
		} else {
			write_byte(&buf, '%') or_return
			write_byte(&buf, HEX_UPPER[c >> 4]) or_return
			write_byte(&buf, HEX_UPPER[c & 0xF]) or_return
		}
	}
	return string(buf[:]), nil
}

@(private)
uri_byte_is_safe :: proc(s: string, i: int) -> bool {
	c := int(s[i])
	if is_ascii_alnum(c) {
		return true
	}
	switch c {
	case ';', '/', '?', ':', '@', '&', '=', '+', '$', ',', '-', '_', '.', '!', '~', '*', '\'', '(', ')', '#':
		return true
	case '%':
		return i + 2 < len(s) && is_hex_digit(int(s[i + 1])) && is_hex_digit(int(s[i + 2]))
	}
	return false
}

// is_unsafe_url reports whether `url` uses a scheme that safe mode removes.
@(private)
is_unsafe_url :: proc(url: string) -> bool {
	if has_prefix_fold(url, "javascript:") || has_prefix_fold(url, "vbscript:") || has_prefix_fold(url, "file:") {
		return true
	}
	if has_prefix_fold(url, "data:") {
		for safe in ([]string{"data:image/png", "data:image/gif", "data:image/jpeg", "data:image/webp"}) {
			if has_prefix_fold(url, safe) {
				return false
			}
		}
		return true
	}
	return false
}
