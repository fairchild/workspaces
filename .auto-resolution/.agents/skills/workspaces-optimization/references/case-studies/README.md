# Local Case Studies

Use this directory for optional, host-specific performance investigation notes.

## Purpose

- Keep machine-specific or session-specific notes in one conventional location.
- Avoid hard-coding one case study into the skill.
- Keep reusable guidance in committed docs, while allowing local notes to stay untracked by default.

## File naming

- Local-only case studies:
  - `YYYY-MM-DD-<slug>.local.md`
- If you intentionally want to commit a generalized example later:
  - `YYYY-MM-DD-<slug>.md`
  - only do this after removing machine-specific details and confirming it is broadly useful

## Default workflow

1. Start with the scripts and `references/hypothesis-map.md`.
2. If the current machine shows a pattern worth preserving, create a local note here from `TEMPLATE.md`.
3. Keep raw machine details, screenshots, and intermediate theories in the local case study.
4. When a pattern becomes generally useful, promote the durable lesson into:
   - `references/hypothesis-map.md`
   - one of the standalone scripts
   - `SKILL.md`
5. Leave the local case study untracked unless there is a specific reason to commit a generalized version.

## Lookup rule for agents

- When a task resembles a previously investigated pattern, scan `references/case-studies/` for matching files.
- Prefer the newest relevant note.
- Treat case studies as secondary evidence. Scripts, current measurements, and code still take priority.
