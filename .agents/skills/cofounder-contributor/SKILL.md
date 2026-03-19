---
name: cofounder-contributor
description: >-
  Run the cofounder contributor workflow for this repo's standing personas.
  Use when you want April Clearwater or Plat Ironwood to sweep open PRs,
  discussions, and issues, then produce one structured action: proposal,
  discussion comment, PR review, or issue execution that pushes a branch
  and opens or updates a PR.
---

# Cofounder Contributor

Use this skill to run the shared contributor runtime with one of the repo's cofounder personas.

## Personas

- `references/april-clearwater.md` — application/UI/UX lead
- `references/plat-ironwood.md` — platform/CI/infra lead

## Runtime

- `scripts/run-contributor.py`
- `scripts/sync-execution-state.py`
- `scripts/validate-agent-output.py`
- `scripts/parse-frontmatter.py`

## What the runtime does

1. Load the selected persona prompt.
2. Gather current repo and GitHub context.
3. Sync execution-state labels (`agent:ready`, `agent:claimed`) from discussion approval, blockers, open PRs, and stale claims.
4. Run Claude Code with the persona and appended context.
5. Validate the YAML frontmatter output.
6. Route the result back into GitHub as a proposal, discussion comment, PR review, or issue execution with branch/PR management.

## Usage

April dry run:

```bash
uv run .agents/skills/cofounder-contributor/scripts/run-contributor.py \
  --prompt-file .agents/skills/cofounder-contributor/references/april-clearwater.md \
  --dry-run
```

Plat execution:

```bash
uv run .agents/skills/cofounder-contributor/scripts/run-contributor.py \
  --prompt-file .agents/skills/cofounder-contributor/references/plat-ironwood.md
```

## Evidence upload

When running on the `lume-macos` runner (macOS VM), agents can capture and upload screenshots as PR evidence:

```bash
# Capture a screenshot
screencapture -x /tmp/evidence.png

# Upload and get a public URL for PR markdown
EVIDENCE_UPLOAD_TOKEN=<token> uv run scripts/upload-evidence.py /tmp/evidence.png \
  --repo workspaces --pr <number> --name <slug> --breadcrumb
```

The upload script returns a URL like `https://evidence.cloudcompute.com/workspaces/pr-142/20260318-sidebar-toggle.png` that renders inline in GitHub markdown. The `--breadcrumb` flag leaves a copy on `~/Desktop` and appends to `~/Desktop/april-runs.log`.

See `docs/development/lume-runner-setup.md` for full details on the R2 evidence store architecture.

## Guardrails

- Work through the persona priority order instead of freelancing.
- Produce exactly one action.
- Keep the final output valid YAML frontmatter with no preamble.
- Deduplicate new ideas before posting them.
- Treat issue `requested_evidence` as required PR accounting: execution PRs must include `## Evidence Status`, and approval reviews cannot pass while requested evidence is missing or blocked.
