// Example toc walks the syntax tree to print a table of contents. Run it with `odin run examples/toc`.
package main

import markdown "../.."
import "core:fmt"
import "core:os"

SOURCE :: `# Guide

## Install

## Usage

### The *quick* way

### The thorough way

## License
`

main :: proc() {
	doc, err := markdown.parse(SOURCE)
	if err != nil {
		fmt.eprintln("parse failed:", err)
		os.exit(1)
	}
	defer markdown.document_destroy(doc)

	for node := doc.root.first_child; node != nil; node = node.next {
		if node.kind != .Heading {
			continue
		}
		for _ in 1 ..< node.level {
			fmt.print("  ")
		}
		fmt.print("- ")
		print_text(node)
		fmt.println()
	}
}

// print_text prints the plain text of an inline subtree, dropping the markup.
print_text :: proc(node: ^markdown.Node) {
	for child := node.first_child; child != nil; child = child.next {
		#partial switch child.kind {
		case .Text, .Code:
			fmt.print(child.literal)
		case .Soft_Break, .Line_Break:
			fmt.print(" ")
		case:
			print_text(child)
		}
	}
}
