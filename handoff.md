# Session Handoff

## Current Task
Security review of the repo's public attack surface — GitHub Actions, agent automation, and infrastructure. Identified and mitigated the highest-risk paths.

## Progress
- Conducted comprehensive security review across workflows, agent scripts, and Cloudflare Workers
- Discovered `MENTION_AUTOMATIONS_ENABLED: false` repo variable existed but was not wired into any workflow
- Traced the full attack chain: public @mention → triage sanitization → label approval → raw payload re-fetch → LLM prompt injection surface
- Shipped three PRs, all merged:
  - **#256** — Wire mention kill switch + evidence store timing-safe token comparison + CORS restriction
  - **#260** — Gate scheduled agent cron runs (superseded by #261)
  - **#261** — Unified `AGENT_AUTOMATIONS_ENABLED` kill switch across all 6 agent workflows
- Deployed hardened evidence store to Cloudflare Workers
- Created single repo variable `AGENT_AUTOMATIONS_ENABLED: false` (deleted the two separate ones)

## Key Decisions
- **One kill switch, not two** — consolidated `MENTION_AUTOMATIONS_ENABLED` and `AGENT_SCHEDULED_RUNS_ENABLED` into `AGENT_AUTOMATIONS_ENABLED`. Simpler to reason about.
- **Manual dispatch always works** — `workflow_dispatch` bypasses the kill switch so you can still invoke agents on-demand. The gate is `github.event_name == 'workflow_dispatch' || vars.AGENT_AUTOMATIONS_ENABLED == 'true'`.
- **Peter Planner left ungated** — already owner-gated (`github.event.comment.user.login == github.repository_owner`), so no public user can trigger it.
- **Evidence store CORS restricted** — PUT removed from preflight since uploads come from CI, not browsers. GET keeps `*` for GitHub markdown rendering.

## Next Steps
1. **Audit GitHub App permissions** — confirm `APRIL_PRIVATE_KEY` and `WORKSPACE_AGENTS_PRIVATE_KEY` apps can't push directly to main. Branch protection with required reviews is the structural gate.
2. **Before re-enabling agents**: implement payload scope limiting (don't re-fetch raw GitHub content for mention-triggered runs) and output action allowlisting (mentions should only allow review comments, not code changes)
3. **Consider per-workflow token scoping** — `EVIDENCE_UPLOAD_TOKEN` and `CLAUDE_CODE_OAUTH_TOKEN` are shared across all agents. Per-agent tokens would reduce blast radius.
4. **Add rate limiting** to webhook relay `/auth/session` endpoint via Cloudflare rules

## Relevant Files
- `.github/workflows/agent-mention.yml` — public mention triage (gated)
- `.github/workflows/agent-executor.yml` — label-approved execution (gated)
- `.github/workflows/agent-april.yml` — April cron (gated)
- `.github/workflows/agent-plat.yml` — Plat cron (gated)
- `.github/workflows/agent-carl.yml` — Carl cron (gated, was previously ungated)
- `.github/workflows/agent-oliver.yml` — Oliver cron (gated)
- `infra/cloudflare-evidence-store/src/index.ts` — timing-safe auth + CORS fix (deployed)
- `scripts/agent-triage-request.py` — triage sanitization logic (reviewed, not modified)
- `.agents/skills/cofounder-contributor/scripts/run-contributor.py` — raw payload fetch path (reviewed, not modified)

## Open Questions
- Should `CLAUDE_CODE_OAUTH_TOKEN` be rotated now as a precaution?
- Is there a GitHub App permission audit tool worth running?
- Should the deferred hardening items become a backlog plan or a GitHub milestone?

---
*Session completed on 2026-03-30*
*PRs: #256, #260, #261 — security hardening and agent kill switch*
