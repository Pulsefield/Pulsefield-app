# AGENTS.md

Repository guidance for coding agents working in Pulsefield.

## Scope

These instructions apply to routine implementation, test writing, and documentation work in this repository.

## Tests

- Avoid overengineering tests.
- Write concrete and useful tests only.
- Prefer tests that validate user-visible behavior, feature-model transitions, domain mapping, or real regression boundaries.
- Do not add tests just to mirror implementation structure or inflate coverage.
- Do not introduce elaborate test harnesses, builders, mocks, or abstractions unless the current repo state clearly needs them.
- Keep tests easy to read, easy to change, and tightly scoped to real behavior.

## Docs

- When writing docs, always pin the current commit hash in the frontmatter.
- This applies to design explanations, future roadmap docs, and execution plan docs.
- The commit hash must describe the repo baseline the document is talking about.

### Doc Separation

- Clearly distinguish:
  - current repo status, architecture & design
  - future roadmap / proposed design
  - execution plan details
- Do not combine those categories in one file.

### Doc Count

- When documentation is needed, write only one doc by default.
- Give that doc a clear name and a single clear intention.
- Do not split documentation into multiple files unless the user explicitly asks for multiple docs.

### Naming

- Choose doc names that communicate intent directly.
