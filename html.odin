package markdown

import "base:runtime"
import "core:strconv"

@(private)
Renderer :: struct {
	out:          [dynamic]byte,
	err:          runtime.Allocator_Error,
	options:      Options,
	// disable_tags counts open images; inside one, only alt text is written.
	disable_tags: int,
}

@(private)
out :: proc(r: ^Renderer, s: string) {
	if r.err == nil {
		r.err = write_string(&r.out, s)
	}
}

// cr writes a newline unless the output is empty or already ends with one.
@(private)
cr :: proc(r: ^Renderer) {
	if len(r.out) > 0 && r.out[len(r.out) - 1] != '\n' {
		out(r, "\n")
	}
}

@(private)
out_escaped :: proc(r: ^Renderer, s: string) {
	start := 0
	for i in 0 ..< len(s) {
		replacement: string
		switch s[i] {
		case '&':
			replacement = "&amp;"
		case '<':
			replacement = "&lt;"
		case '>':
			replacement = "&gt;"
		case '"':
			replacement = "&quot;"
		case:
			continue
		}
		out(r, s[start:i])
		out(r, replacement)
		start = i + 1
	}
	out(r, s[start:])
}

@(private)
out_int :: proc(r: ^Renderer, n: int) {
	buf: [32]byte
	out(r, strconv.write_int(buf[:], i64(n), 10))
}

@(private)
out_url :: proc(r: ^Renderer, url: string) {
	if r.options.safe && is_unsafe_url(url) {
		return
	}
	out_escaped(r, url)
}

// is_container_node reports whether the renderer visits `node` twice, entering and leaving.
@(private)
is_container_node :: proc(node: ^Node) -> bool {
	#partial switch node.kind {
	case .Code_Block, .Html_Block, .Thematic_Break, .Text, .Soft_Break, .Line_Break, .Code, .Html_Inline:
		return false
	}
	return true
}

@(private)
in_tight_list :: proc(paragraph: ^Node) -> bool {
	parent := paragraph.parent
	if parent == nil || parent.parent == nil {
		return false
	}
	grandparent := parent.parent
	return grandparent.kind == .List && grandparent.list.tight
}

@(private)
render :: proc(root: ^Node, options: Options, allocator: runtime.Allocator) -> (html: string, err: Error) {
	if root == nil {
		return "", nil
	}
	r := Renderer {
		options = options,
	}
	r.out.allocator = allocator
	reserve(&r.out, 256) or_return

	// Walk the tree without recursion so deeply nested input can't overflow the stack.
	node := root
	entering := true
	for {
		render_step(&r, node, entering)
		if entering && is_container_node(node) {
			if node.first_child != nil {
				node = node.first_child
			} else {
				entering = false
			}
			continue
		}
		if node == root {
			break
		}
		if node.next != nil {
			node = node.next
			entering = true
		} else {
			node = node.parent
			entering = false
		}
	}
	if r.err != nil {
		delete(r.out)
		return "", r.err
	}
	shrink(&r.out)
	return string(r.out[:]), nil
}

@(private)
render_step :: proc(r: ^Renderer, node: ^Node, entering: bool) {
	if r.disable_tags > 0 {
		render_alt_text(r, node, entering)
		return
	}
	switch node.kind {
	case .Document:
	case .Block_Quote:
		cr(r)
		out(r, "<blockquote>" if entering else "</blockquote>")
		cr(r)
	case .List:
		cr(r)
		if node.list.kind == .Bullet {
			out(r, "<ul>" if entering else "</ul>")
		} else if !entering {
			out(r, "</ol>")
		} else if node.list.start != 1 {
			out(r, "<ol start=\"")
			out_int(r, node.list.start)
			out(r, "\">")
		} else {
			out(r, "<ol>")
		}
		cr(r)
	case .Item:
		if entering {
			cr(r)
			out(r, "<li>")
		} else {
			out(r, "</li>")
			cr(r)
		}
	case .Paragraph:
		if in_tight_list(node) {
			return
		}
		if entering {
			cr(r)
			out(r, "<p>")
		} else {
			out(r, "</p>")
			cr(r)
		}
	case .Heading:
		level := clamp(node.level, 1, 6)
		digits := "123456"
		tag := digits[level - 1:level]
		if entering {
			cr(r)
			out(r, "<h")
		} else {
			out(r, "</h")
		}
		out(r, tag)
		out(r, ">")
		if !entering {
			cr(r)
		}
	case .Code_Block:
		cr(r)
		out(r, "<pre><code")
		language := node.info
		for i in 0 ..< len(language) {
			if is_ascii_whitespace(int(language[i])) {
				language = language[:i]
				break
			}
		}
		if language != "" {
			out(r, " class=\"language-")
			out_escaped(r, language)
			out(r, "\"")
		}
		out(r, ">")
		out_escaped(r, node.literal)
		out(r, "</code></pre>")
		cr(r)
	case .Html_Block:
		cr(r)
		out(r, "<!-- raw HTML omitted -->" if r.options.safe else node.literal)
		cr(r)
	case .Thematic_Break:
		cr(r)
		out(r, "<hr />")
		cr(r)
	case .Table:
		cr(r)
		if entering {
			out(r, "<table>")
		} else {
			if node.last_child != nil && !node.last_child.header {
				out(r, "</tbody>\n")
			}
			out(r, "</table>")
		}
		cr(r)
	case .Table_Row:
		if entering {
			if node.header {
				out(r, "<thead>\n")
			} else if node.prev != nil && node.prev.header {
				out(r, "<tbody>\n")
			}
			out(r, "<tr>\n")
		} else {
			out(r, "</tr>\n")
			if node.header {
				out(r, "</thead>\n")
			}
		}
	case .Table_Cell:
		tag := "th" if node.header else "td"
		if entering {
			out(r, "<")
			out(r, tag)
			switch node.alignment {
			case .None:
			case .Left:
				out(r, " align=\"left\"")
			case .Center:
				out(r, " align=\"center\"")
			case .Right:
				out(r, " align=\"right\"")
			}
			out(r, ">")
		} else {
			out(r, "</")
			out(r, tag)
			out(r, ">\n")
		}
	case .Text:
		out_escaped(r, node.literal)
	case .Soft_Break:
		out(r, "\n")
	case .Line_Break:
		out(r, "<br />\n")
	case .Code:
		out(r, "<code>")
		out_escaped(r, node.literal)
		out(r, "</code>")
	case .Emphasis:
		out(r, "<em>" if entering else "</em>")
	case .Strong:
		out(r, "<strong>" if entering else "</strong>")
	case .Strikethrough:
		out(r, "<del>" if entering else "</del>")
	case .Link:
		if entering {
			out(r, "<a href=\"")
			out_url(r, node.destination)
			out(r, "\"")
			if node.title != "" {
				out(r, " title=\"")
				out_escaped(r, node.title)
				out(r, "\"")
			}
			out(r, ">")
		} else {
			out(r, "</a>")
		}
	case .Image:
		if entering {
			out(r, "<img src=\"")
			out_url(r, node.destination)
			out(r, "\" alt=\"")
			// The walker visits the image again on exit, and render_alt_text closes the tag then.
			r.disable_tags += 1
		}
	case .Html_Inline:
		out(r, "<!-- raw HTML omitted -->" if r.options.safe else node.literal)
	}
}

// render_alt_text writes the plain text of an image description, then closes the `<img>` tag.
@(private)
render_alt_text :: proc(r: ^Renderer, node: ^Node, entering: bool) {
	#partial switch node.kind {
	case .Text, .Code, .Html_Inline:
		out_escaped(r, node.literal)
	case .Soft_Break, .Line_Break:
		out(r, "\n")
	case .Image:
		if entering {
			r.disable_tags += 1
			return
		}
		r.disable_tags -= 1
		if r.disable_tags == 0 {
			out(r, "\"")
			if node.title != "" {
				out(r, " title=\"")
				out_escaped(r, node.title)
				out(r, "\"")
			}
			out(r, " />")
		}
	}
}
