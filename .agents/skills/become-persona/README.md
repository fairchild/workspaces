# `become-persona`

`become-persona` lets a local assistant thread temporarily operate through one
of the repo's standing agent personas. It is the machinery behind `/become
april`, `/become plat`, and `/become peter`.

This is not the scheduled GitHub automation path. It does not claim issues,
open PRs, post discussion comments, or run the contributor/planner runtimes by
itself. It only loads the persona prompt and relevant memory context, preferably
from `team-memory` when available, so the current interactive thread can answer
from that perspective.

## Why this exists

Workspaces has several named agents with stable areas of concern:

- April Clearwater: application, UI, UX, terminal behavior, native app feel
- Plat Ironwood: platform, CI, infrastructure, release, runner reliability
- Peter Planner: approved discussion to issue/milestone planning

Those personas already exist as workflow prompts. `/become` reuses those prompts
for local collaboration instead of duplicating them in a separate command. The
resolver also adds memory context so the persona can use durable project and
human preferences when available.

## File map

- `SKILL.md` - agent-facing instructions for invoking the skill correctly.
- `README.md` - human-facing explanation of the system.
- `references/personas.toml` - persona catalog, aliases, prompt paths, memory
  keys, and runtime-only sections to strip.
- `scripts/resolve_persona.py` - deterministic resolver used by the skill and
  command fallback.
- `scripts/test_resolve_persona.py` - stdlib tests for alias resolution,
  prompt stripping, memory discovery, and error handling.
- `.claude/commands/become.md` - slash command wrapper that delegates here.

## Flow

When a user types:

```text
/become april review this layout
```

the command/skill flow is:

1. Parse `april` as the requested persona and keep `review this layout` as the
   first task after switching.
2. Run:

   ```bash
   uv run --script .agents/skills/become-persona/scripts/resolve_persona.py april review this layout
   ```

3. Resolve `april` through `references/personas.toml`.
4. Load the prompt file, for example
   `.agents/skills/cofounder-contributor/references/april-clearwater.md`.
5. Strip runtime-only sections such as `## Output Format`, because interactive
   `/become` mode should not emit scheduled-agent YAML frontmatter.
6. Attach memory context:
   - repo memory from `.agents/MEMORY.md`
   - team-memory shared memory from `~/.ai-memory/shared/*.md`
   - persona team memory from `~/.ai-memory/<persona-key>/` or
     `~/.ai-memory/profiles/<persona-key>/`
   - active team-memory core context when persona-specific memory is absent
7. Render an activation contract that tells the assistant to use the persona as
   a lens while keeping system, developer, repo, and newest-user instructions
   higher priority.

## Resolver usage

List supported personas:

```bash
uv run --script .agents/skills/become-persona/scripts/resolve_persona.py --list
```

Render the human-readable activation context:

```bash
uv run --script .agents/skills/become-persona/scripts/resolve_persona.py april
```

Render JSON for debugging or future tooling:

```bash
uv run --script .agents/skills/become-persona/scripts/resolve_persona.py --json plat
```

Limit memory output while testing:

```bash
uv run --script .agents/skills/become-persona/scripts/resolve_persona.py --max-total-chars 1000 peter
```

## Team-memory integration

The resolver treats memory as context, not as higher-priority instructions.
Current user intent and repo policy still win.

The preferred memory shape is the `team-memory` layout:

```text
~/.ai-memory/
  active -> scout
  shared/
  <teammate>/
    AGENTS.md
    personality.md
    relationship.md
    core/
    archival/
    journal/
```

For `/become <persona>`, the resolver looks for:

- `.agents/MEMORY.md`
- `~/.ai-memory/shared/*.md`
- `~/.ai-memory/<memory-key>/AGENTS.md`
- `~/.ai-memory/<memory-key>/personality.md`
- `~/.ai-memory/<memory-key>/relationship.md`
- `~/.ai-memory/<memory-key>/core/*.md`
- the same files under `~/.ai-memory/profiles/<memory-key>/`

It still recognizes `CLAUDE.md` for older persona-memory directories.

When a persona-specific memory directory is missing, the resolver uses the
active team-memory teammate's `core/*.md` files as general context. It does not
inline the active teammate's `AGENTS.md`, `personality.md`, or `relationship.md`
in that fallback path, because those files describe a different identity.

Recall, journal, and archival files are listed as additional memory files but
not inlined by default. That keeps activation output useful without dumping an
entire long-term archive into every persona switch.

If no persona-specific memory exists, the resolver reports the checked paths.
That is a setup signal, not a failure.

If `~/.ai-memory` does not exist at all, the skill still succeeds with the
repo-owned persona prompt and `.agents/MEMORY.md` when present. That keeps the
skill portable to repos that have personas but have not adopted team-memory.

## Adding a persona

1. Add or choose a persona prompt file. The first heading should identify the
   display name and role, for example:

   ```markdown
   # Alex Example - Systems Lead
   ```

2. Add an entry to `references/personas.toml`:

   ```toml
   [personas.alex]
   display_name = "Alex Example"
   role = "Systems Lead"
   persona_path = ".agents/skills/example/references/alex-example.md"
   aliases = ["alex", "alex-example"]
   memory_keys = ["alex-example", "alex"]
   strip_sections_from = ["## Output Format"]
   ```

3. Add or update tests in `scripts/test_resolve_persona.py` if the new persona
   changes lookup behavior.
4. Run:

   ```bash
   uv run --script .agents/skills/become-persona/scripts/test_resolve_persona.py
   uv run --script .agents/skills/become-persona/scripts/resolve_persona.py --list
   ```

## Design constraints

- The catalog is explicit. The resolver does not scan every prompt file because
  `/become april` should be stable and predictable.
- Prompt stripping is per persona. Different runtimes can mark different
  sections as non-interactive.
- The skill does not write memory. Remembering something should be an explicit
  user request.
- Team-memory is opportunistic. Missing memory never blocks persona activation.
- The activation contract prevents scheduled-agent priority queues from taking
  over the local thread.
- The resolver is a single-file UV script with no dependencies, matching this
  repo's standalone Python preference.

## Troubleshooting

Unknown persona:

```text
error: unknown persona 'alex'. Available personas: april, peter, plat
```

Add the persona to `references/personas.toml` or use one of the listed aliases.

Prompt not found:

```text
error: persona prompt not found: ...
```

Check that `persona_path` is relative to the repository root and that the file
exists on the current branch.

Memory looks missing:

The resolver reports missing persona memory directories when none of the
configured `memory_keys` exist. Create a matching directory under
`~/.ai-memory/` or `~/.ai-memory/profiles/` only if that persona needs durable
local memory.

Runtime YAML appears in interactive answers:

Confirm the persona catalog includes the relevant heading under
`strip_sections_from`. April, Plat, and Peter all strip `## Output Format`.
