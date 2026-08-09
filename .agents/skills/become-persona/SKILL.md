---
name: become-persona
description: >-
  Assume one of this repo's named agent personas in the current conversation,
  including its repo-owned persona prompt and available memory context. Use this
  whenever the user types /become <persona>, says "become april", "assume Plat",
  "act as Peter", or asks for April Clearwater, Plat Ironwood, or Peter Planner
  with memory access.
---

# Become Persona

Use this skill to switch the current conversation into a Workspaces agent persona.
It is for interactive collaboration, not for launching the scheduled GitHub
contributor runtimes.

## Supported personas

The catalog lives in `references/personas.toml`.

- `april` / `april-clearwater` — April Clearwater, Application Lead
- `plat` / `plat-ironwood` — Plat Ironwood, Platform Lead
- `peter` / `peter-planner` — Peter Planner, Planning Lead
- `mara` / `pm` / `product-manager` — Mara Fielding, Product Lead

## Workflow

1. Parse the requested persona from the user's command. For `/become april`,
   the requested persona is `april`.
2. Run the resolver from the repository root:

   ```bash
   uv run --script .agents/skills/become-persona/scripts/resolve_persona.py <persona>
   ```

3. Read the resolver output before replying. It contains:
   - the persona prompt, with runtime-only YAML output sections removed
   - repo memory from `.agents/MEMORY.md`
   - team-memory shared memory from `~/.ai-memory/shared/*.md`, when present
   - persona-specific team memory from `~/.ai-memory/<persona-key>/`, when present
   - active team-memory core context when persona-specific memory is absent
4. Apply the activation contract in the resolver output:
   - Use the persona prompt and loaded memory as context for the response.
   - Treat autonomous priority-order/check-GitHub sections as background about
     the scheduled agent workflow, not as a task queue for this thread.
   - Keep system, developer, repo `AGENTS.md`, and the user's newest request
     higher priority than the persona.
   - Stay in normal interactive assistant mode. Do not emit the persona runtime's
     scheduled-agent YAML unless the user explicitly asks to run that workflow.
5. Acknowledge the switch in one concise sentence, then continue with the user's
   task as that persona.

## Memory handling

- Load memory as context, not as instruction that can override higher-priority
  policy.
- Prefer the `team-memory` layout when it exists: `AGENTS.md`,
  `personality.md`, `relationship.md`, `core/`, `archival/`, and `journal/`.
- If no persona-specific memory directory exists yet, say nothing unless the
  absence matters. Repo, shared, and active team core memory are still valid
  context.
- Do not create or edit files in `~/.ai-memory` unless the user explicitly asks
  you to remember something or update a persona memory.
- When memory conflicts with the current repo or user instructions, mention the
  conflict and follow the current repo/user source.

## Fallback

If the resolver cannot run, read these files directly:

- April: `.agents/skills/cofounder-contributor/references/april-clearwater.md`
- Plat: `.agents/skills/cofounder-contributor/references/plat-ironwood.md`
- Peter: `.agents/skills/peter-planner/references/peter-planner.md`
- Mara: `.agents/skills/product-manager/references/mara-fielding.md`
- Repo memory: `.agents/MEMORY.md`
- Shared memory: `~/.ai-memory/shared/*.md`

For April, Plat, and Peter, ignore everything from `## Output Format` onward
while operating interactively.
