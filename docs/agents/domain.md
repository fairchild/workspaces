# Domain Docs

This is a single-context repo. The engineering skills should start with the root product and architecture docs, then read narrower docs for the surface being changed.

## Before Exploring, Read These

- `README.md` for product positioning, supported workflows, and user-facing behavior.
- `ARCHITECTURE.md` for system structure and architectural patterns.
- `docs/development/mergeability-standard.md` before planning PR-ready implementation work.
- `docs/decisions/` for architectural decisions. This repo uses `docs/decisions/` rather than `docs/adr/`.
- Area docs from the `AGENTS.md` Doc Navigation table when working on terminal focus, Lume, notifications, web dashboard, evidence, or runner behavior.

If a listed file does not exist in a future checkout, proceed silently and use the nearest existing repo documentation.

## Layout

```text
/
|-- README.md
|-- ARCHITECTURE.md
|-- AGENTS.md
|-- docs/
|   |-- decisions/
|   `-- development/
|-- Sources/
|-- Tests/
`-- web/
```

The root `GLOSSARY.md` (product domain language) and `CONTEXT-MAP.md` (which also maps the Agent Factory context in `docs/agents/GLOSSARY.md`) define the repo's glossary. Prefer their language for issue titles, refactor proposals, hypotheses, and test names. If they are missing in a checkout, proceed silently.

## Decision Conflicts

If a recommendation or implementation contradicts an existing decision under `docs/decisions/` or a development runbook, surface that conflict explicitly rather than silently overriding the repo convention.
