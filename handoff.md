# Session Handoff

## Current Task
Built @agent chat with compute backend abstraction for the Spaces web app. Designed, implemented, tested, reviewed, and merged.

## Progress
- Explored existing chat system, agent definitions, and GitHub Discussion bridge
- Collaborative design session: architecture decisions for @mention → agent session flow
- Implemented ComputeProvider abstraction mirroring Swift WorkspaceProviderProtocol
- Built Vercel Sandbox provider using `@vercel/sandbox` SDK (Firecracker microVMs)
- Built persona resolution from `.agents/skills/*/references/*.md` (full hyphenated names)
- Built session manager, SSE streaming API route, and frontend streaming client
- E2E smoke test: April Clearwater responded from inside a Vercel Sandbox reading actual repo
- Reflection found and fixed 6 bugs (file path mismatch, broken streaming, shell injection, wrong CLI flags, buffered streaming, require() in ESM)
- Code review found and fixed 4 more issues (race condition, missing error handling, SSE client hang, unused import)
- Access gated to `fairchild` GitHub user
- Dispatched sandbox-testing agent via cmux orchestrator for next-session follow-up
- Fixed cmux-orchestrator skill: replaced `claude -p` with interactive mode for agent dispatch

## Key Decisions
- **Full agent names** (`@april-clearwater` not `@april`) — avoids GitHub user conflicts
- **Conversational first** — every @mention starts conversational; dispatch is escalation
- **Vercel Sandbox default** — Firecracker microVMs, swappable via ComputeProvider interface
- **Synchronous runCommand** over detached+poll — simpler, works within 5-min SSE timeout
- **Interactive mode for agent dispatch** — `claude -p` is single-shot text only; interactive mode gives full tool access

## Next Steps
1. **Browser testing** — add GitHub OAuth callback URL for localhost to test full UI flow
2. **True token streaming** — replace synchronous runCommand with Agent SDK or stream-json
3. **Private repo support** — pass GitHub token in clone URL
4. **Session resume** — in-memory sandbox Map needs Sandbox.get() for cross-request persistence
5. **Check sandbox-testing agent** in cmux workspace:29 for results

## Relevant Files
- `web/src/lib/agent-runtime/` — compute provider abstraction (types, registry, vercel-sandbox, session-manager, persona-loader)
- `web/src/lib/agent-sessions.ts` — Turso DB layer for session tracking
- `web/src/app/api/chat/agent-stream/route.ts` — SSE streaming endpoint
- `web/src/app/api/chat/messages/route.ts` — modified to detect agent personas and redirect
- `web/src/app/dashboard/components/chat-panel.tsx` — SSE client with streaming display
- `.agents/skills/sandbox/SKILL.md` — Vercel Sandbox SDK reference
- `~/.claude/skills/cmux-orchestrator/SKILL.md` — fixed agent dispatch pattern

## Open Questions
- Should we use the Agent SDK instead of CLI for the sandbox provider? (better streaming, programmatic control)
- How should per-agent memory work across web chat sessions? (Turso vs repo files vs hybrid)
- Should `@spaces` bot become a persona with its own SKILL.md?

---
*Session completed on 2026-03-30*
*PR: #257 — @agent chat with compute backend abstraction (merged)*
