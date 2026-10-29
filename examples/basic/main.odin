// Example basic renders a small Markdown document to HTML. Run it with `odin run examples/basic`.
package main

import markdown "../.."
import "core:fmt"
import "core:os"

SOURCE :: `# Release notes

Version **0.1.0** renders [CommonMark](https://commonmark.org) to HTML.

- Tight and loose lists
- Fenced code blocks
- ~~Bugs~~ Features

| Extension     | Enabled by |
| ------------- | :--------: |
| Tables        | .Tables    |
| Strikethrough | .Strikethrough |
`

main :: proc() {
	html, err := markdown.to_html(SOURCE, {extensions = markdown.GFM})
	if err != nil {
		fmt.eprintln("render failed:", err)
		os.exit(1)
	}
	defer delete(html)
	fmt.print(html)
}
