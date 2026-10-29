# Contributing

Thanks for helping. This project follows the shared [alexisbcz Odin standards](https://github.com/alexisbcz/odin-standards/blob/main/STANDARDS.md). The short version is below.

## Before you open a pull request

Run the same checks as CI:

```sh
odin check . -vet -strict-style -disallow-do -no-entry-point
odin test tests -vet -strict-style -disallow-do
vale sync && vale *.md
```

All three must pass with zero errors. CI also builds every program under `examples/`.

## Spec conformance

The tests in `tests/spec_test.odin` run every example of the CommonMark spec, and each must match byte for byte. If you change parsing, run the whole suite, not only the tests you touched. When you fix a bug that the spec examples don't cover, add a focused test to `tests/markdown_test.odin` with the smallest input that shows it.

## Code

- Use snake_case for procedures and variables, Ada_Case for types, and SCREAMING_SNAKE_CASE for constants.
- Give every allocating procedure an `allocator := context.allocator` parameter and a matching destroy or delete procedure.
- Return `(T, Error)` from fallible procedures. Don't panic in library code.
- Write a doc comment for every exported declaration.
- Add a test under `tests/` for every bug fix and every new procedure.

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/). Write an imperative subject of 72 characters or fewer, a blank line, then a body of `-` bullet points that explain what changed and why:

```text
fix: keep list tight when a nested list ends the item

- a blank line after a nested list made the outer list loose
- compare the end line of the item's last child, as the spec requires
```

## Changelog

Add a line under `## [Unreleased]` in `CHANGELOG.md` for every change that users can see.
