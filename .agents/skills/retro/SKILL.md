---
name: retro
description: >
  Run an end-of-arc retrospective whose output is shipped encodings, not a
  report. Use when a milestone closes, a plan moves to backlog/done/, or the
  user asks to step back. Triggers: "retro", "retrospective", "what did we
  learn", "reflect on this session/arc", arc or milestone completion.
---

# retro: close an arc by compounding it

An arc is not finished when the last PR merges — it is finished when what the
arc taught is cheaper for the next session than it was for this one. Process
proven 2026-07-02 (milestone #7 cycle → PRs #735/#736/#739).

## Two passes, in order

1. **Work reflection** — fresh eyes on what shipped. Consistent patterns
   (good and bad), issues created or left behind, simplification
   opportunities. Judge from the code and CI history, not the tracker or
   your own summaries. Name what the arc made stale.
2. **Session retro** — how the work happened. What made it fast (keep), what
   cost rounds/tokens/redos (change), including your own errors — a retro
   that finds no self-inflicted cost wasn't looking. Quantify where cheap:
   agent token spend, redo count, rounds-to-merge before vs after authority
   was settled.

## Rules

- **Output is diffs and issues, not prose.** Every lesson either ships (doc
  edit, skill edit, script, gate) or files (issue with the right lane label)
  or is deliberately dropped — say which. A retro that only produces a
  report has failed.
- **Place each lesson by the encoding ladder** (see `AGENTS.md` § Startup
  Instruction Budget): machinery > skill > linked doc > AGENTS.md, matched
  to the moment the lesson must fire. Promote recurring prose upward and
  delete what the promotion replaces.
- **Workarounds name their own obsolescence condition** so the next retro
  can trim them by lookup instead of judgment.
- **File human-lane items immediately** (`ops`/`human` labels) — they are
  the owner's queue, not the report's appendix.
- Add the narrative as a dated file in `docs/retros/` (the archive layer),
  dated, newest-first — after the encodings ship, referencing them.

## Definition of done

- [ ] Encoding PR(s) merged (or explicitly deferred with a reason)
- [ ] Issues filed for non-encodable actions, each in its lane
- [ ] docs/retros/ entry references the shipped encodings
- [ ] Anything the arc made stale (docs, tracker rows) is fixed or filed
