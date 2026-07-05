# Handoff — Issue #750: web-next real runtime (harness-backed `ComputeProvider`)

**For:** a Fable orchestrator driving #750 to completion in the next session.
**Prepared:** 2026-07-05 (Opus).
**Branch:** `fairchild/web-next-real-runtime-harness-backed-computeprov`.
**Issue:** [#750](https://github.com/fairchild/workspaces/issues/750) — **OPEN** (body refreshed 2026-07-05 to match this handoff).
**Milestone:** [#11 "Sessions-first web (web-next)"](https://github.com/fairchild/workspaces/milestone/11) — 11 closed / 5 open. #750 is the last **runtime** piece; siblings still open: #752 (terminal drawer), #753 (lifecycle/mobile), #754 (cutover), #790 (edit→diff view). Follow-on refinement lives in milestones #12 (a11y/resilience) and #13 (self-validation across envs).

### Already built this session (on the branch, not yet committed)

A **preflight health-check** was added to de-risk phase 2 — it proves every capability a real turn needs, in the environment it's deployed to:

- **`GET /api/diag/preflight`** (`web-next/src/app/api/diag/preflight/route.ts`) — auth-gated. Default run checks: **env** presence, **llm** (gateway or anthropic-direct), **github** (App JWT → discover installation → installation token → repo-read), **vercel** (token/team/project reachability, or OIDC note on-platform). Add **`?sandbox=1`** to also create a live Vercel sandbox and run **bash + `git clone --depth 1`** the repo inside it. Returns 200 all-pass / 503 otherwise; **never returns secret values**, redacts the clone token from captured output.
- Supporting: `web-next/src/lib/diag/preflight.ts` (checks) + `web-next/src/lib/diag/github-app.ts` (hand-rolled App JWT via `node:crypto`, no dep; accepts base64-or-PEM key; **reusable by the #750 provider for repo clone**) + `github-app.test.ts` (5 tests, green).
- Added dep: **`@vercel/sandbox@2.4.0`** (exact-pinned; aligns with the harness's `@vercel/sandbox ^2.0.1`).
- Gates: **typecheck ✓, lint ✓, unit tests ✓**. Should land as its own small PR with a green `preflight` run as evidence.
- ⚠️ **Clean `pnpm build` fails** — see "Open gate" in §7. Not caused by these additions (they're an API route + libs; `/500`/`/_error` are Next built-ins).

_(This overwrites a stale 2026-04-02 handoff for PR #280, an unrelated `web/` INP perf fix — this file is the repo's rolling session-handoff scratch doc.)_

---

## 1. TL;DR — where this stands

The goal: **a real Claude Code turn runs in a Vercel sandbox and streams into the Folio transcript**, behind the already-shipped `ComputeProvider` seam. Everything shipped so far (T0–T5) runs on a **mock** provider; no real agent has ever run.

**All preconditions from the issue body are already done** — the issue's "start here" orientation is stale (written 2026-07-04, several PRs have landed since):

- #777 (harness ADR), #779 (Folio turn frame), #781 (design doc) — **all MERGED**.
- #784 (reasoning treatment), #785 (adversarial mock) — **both CLOSED**, landed via **#787** (`eb7f7994`). Reasoning is fully wired end-to-end already (see §4).
- #780 (`next build` /404 failure) — **CLOSED**.
- Newer prep since the issue was written: **#796** (CONTRIBUTING — local dev + creds), **#797** (`/api/diag/gateway` credential smoke probe), **#803** (`architecture.html`).

So the runway is clear. **The real-runtime work itself has not been started.** This branch is the place to do it.

### Two corrections to the issue's mental model (important)

1. **Interface naming.** The ADR originally proposed a new `SessionRuntime` interface, then reconciled with shipped code: **the existing `ComputeProvider` seam _is_ that interface.** Do **not** build a `SessionRuntime` abstraction. Add an additive `ComputeProvider`; `StreamChunk` stays the internal currency; the ingest→log→tail pipeline is untouched. Where the brief still says "`SessionRuntime`," read "`ComputeProvider`."

2. **Issue scope vs. the brief's T-numbering.** The execution brief's internal numbering maps #750→"T6 Codex+Pi." **Ignore that — trust the GitHub issue.** Issue #750 is the **Claude Code real runtime**. Codex + Pi adapters + a runtime picker are explicitly **follow-on**, out of scope here.

---

## 2. The harness API — corrected against the shipped `.d.ts` (net-new intel)

The issue text says "drives `HarnessAgent(claudeCode)`." **That signature is wrong.** Verified against the published typings (`@ai-sdk/harness@1.0.18`, all three packages on a lockstep train, all marked *experimental*):

### Versions to exact-pin
```
@ai-sdk/harness              1.0.18
@ai-sdk/harness-claude-code  1.0.18
@ai-sdk/sandbox-vercel       1.0.18
```
⚠️ **`ai` version conflict to resolve first.** `@ai-sdk/harness@1.0.18` declares `ai@7.0.15` as a **direct dependency**. The repo currently pins `ai@^7.0.14` (lock resolves `7.0.14`). Installing the harness will pull `ai@7.0.15`. **Reconcile deliberately** — bump the repo to `ai@7.0.15` to match. Don't fight the transitive dep. (The ADR now records this correctly — it previously claimed the harness pins `ai@7.0.14`, corrected 2026-07-05.) (Also pulls `@vercel/sandbox@^2.0.1`, `@anthropic-ai/claude-agent-sdk`, `ws@^8.21.0`.)

### Construction (stateless agent, construct once at module scope)
```ts
import { HarnessAgent } from '@ai-sdk/harness';
import { claudeCode, createClaudeCode } from '@ai-sdk/harness-claude-code';
import { createVercelSandbox } from '@ai-sdk/sandbox-vercel';

const agent = new HarnessAgent({
  harness: claudeCode,                          // or createClaudeCode({ ... })
  sandbox: createVercelSandbox({ /* settings */ }), // a HarnessV1SandboxProvider, NOT a raw Sandbox
  permissionMode: 'allow-all',                  // default
  instructions,                                 // prepended once to first user msg of a fresh session
});
```

**Auth goes on the adapter, not the agent/sandbox:**
```ts
createClaudeCode({
  auth: { gateway: { apiKey: process.env.AI_GATEWAY_API_KEY } },   // preferred (spend cap)
  //  or: { anthropic: { apiKey: process.env.ANTHROPIC_API_KEY } },
  thinking: 'on',   // <-- turn on extended thinking so reasoning parts flow
  model,            // optional Anthropic model id; unset = CLI default
});
```

**Sandbox settings** (`createVercelSandbox`) — either wrap a caller-owned `@vercel/sandbox` (`{ sandbox, bridgePorts }`) or let the provider create/manage one (forwards `Sandbox.create` params + optional `name`). In managed mode it uses `Sandbox.getOrCreate` to keep a **persistent named template snapshot** keyed by the Claude Code bootstrap recipe and forks an ephemeral sandbox per session — this is the across-turn reuse the acceptance criteria want. `prepareHarnessSandboxTemplate(...)` (from `@ai-sdk/harness`) pre-bakes that snapshot from a CI/deploy step.

### Sessions are explicit and threaded through every call
```ts
const session = await agent.createSession({
  sessionId?,      // omit → generated; supply the original id to REATTACH
  resumeFrom?,     // HarnessAgentResumeSessionState from a prior detach()/stop()
});
session.sessionId  // <-- stable id you persist

const result = await agent.stream({ prompt, session });  // prompt: string | UserModelMessage
// consume result.fullStream (standard ai@7 StreamTextResult), switch on part.type
```

### The stream shape → map to `StreamChunk`
`result.fullStream` is a standard ai@7 stream. Part kinds that flow (from `HarnessV1StreamPart`):
- `text-start`/`text-delta`/`text-end` → **`text`**
- `reasoning-start`/`reasoning-delta`/`reasoning-end` → **`reasoning`** (gated by `thinking:'on'`)
- `tool-call` → **`tool_use`** (carry id + name + input into `metadata.toolUseId`/`toolName`/`input`); `tool-result` → **`tool_result`** (`metadata.isError`, `metadata.diff` where relevant)
- `finish`/`finish-step` (`finishReason`, `usage`) → **`done`** (`metadata.durationMs`, `tokenCount`)
- Harness extras: `file-change`, `compaction`, `error`, `raw`

⚠️ **Verify empirically once installed:** (a) whether reasoning deltas expose `.delta` vs `.text` on the consumer `fullStream` (harness internal type uses `delta`; ai@7 consumer type may differ); (b) whether `file-change`/`compaction` surface on the consumer stream or are adapter-internal. Don't guess — log the raw parts on the first real turn.

### Resume — the part to get exactly right
`resumeFrom` is **not** a stream token. It's returned by session lifecycle methods:
```ts
const resumeFrom = await session.detach();  // parks sandbox+runtime alive
//  or: await session.stop();               // persists state, stops runtime+sandbox
```
`resumeFrom: HarnessAgentResumeSessionState` = `{ harnessId, specificationVersion:'harness-v1', type:'resume-session', data: JSONValue, continueFrom? }`.

**Persist BOTH `session.sessionId` AND the `resumeFrom` object per app session.** The `sessionId` is the key the Vercel provider uses to reattach the same sandbox; `resumeFrom` carries the conversation-history pointer. One without the other won't reattach. Next turn: `agent.createSession({ sessionId, resumeFrom })` → `agent.stream(...)`.

(There's a finer-grained `suspendTurn()`→`continueFrom`→`continueStream()` path for freezing a mid-turn at a process boundary — that's the "workflow slice" for long turns, **not** needed for basic multi-turn continuity. Defer unless a turn genuinely outruns the serverless budget.)

Extracted `.d.ts` for re-inspection: `scratchpad/harness-inspect/{harness,harness-claude-code,sandbox-vercel}/package/dist/*.d.ts`.

---

## 3. The seam to fill — exact files & line refs

All paths under `web-next/`. The additive path is small and well-contained.

### Provider seam (`src/lib/agent-runtime/`)
- **`provider.ts:11-21`** — `ComputeProvider = { readonly id; runTurn(req: TurnRequest): AsyncIterable<StreamChunk> }`; `TurnRequest = { sessionId; userMessage }`.
- **`provider.ts:23-31`** — the registry is a plain in-module `Record` (`providers = { [mockProvider.id]: mockProvider }`) + `getProvider(id)` (throws on unknown). **Register the new provider here.**
- **`stream-chunk.ts:6-17`** — `StreamChunk = { type: "text"|"reasoning"|"tool_use"|"tool_result"|"status"|"error"|"done"; content: string; metadata?: Record<string,unknown> }`. Single interface, `type` discriminant, untyped `metadata` bag. `reasoning` already present.
- **`mock-provider.ts:58-192`** — reference implementation of a full scripted turn (`mockCodingTurn` → status/reasoning/text/tool_use/tool_result/done). Copy its shape.
- **`run-turn.ts:34-42`** — `runSessionTurn(handle, session, userText, provider=getProvider(session.provider))` → `{ fromSeq, ingest, stream: tailStream(...) }`. Provider resolved from `session.provider`. No per-request override.
- **`turn-ingest.ts:106-136`** — `ingestTurn` consumes `provider.runTurn(...)`, appends each chunk to `session_events`, guarantees exactly one terminal `done`, never rejects. **This is the #750 seam** (comment at `:16-19`). The contract you must honor: yield `StreamChunk`s, end with (or let it synthesize) a `done`.

### Persistence (`src/lib/db/`)
- **`client.ts:36-49`** — `SessionsTable`. Has `provider`, `claude_session_id` (`:45`, *"Claude CLI session id for snapshot/resume"* — **currently always written `null`; this is the placeholder the ADR names for the resume blob**). **No `resume_from` column exists.**
- **`client.ts:57-68`** — `SessionEventsTable` = `{ session_id, seq, role, kind, payload(JSON StreamChunk), created_at }`, PK `(session_id, seq)`.
- **`migrations.ts:147`** — ordered `MIGRATIONS[]`; `Migration = { id; up(db) }`. Append `0003_*` (never edit shipped ones; keep `up` idempotent — SQLite ADD COLUMN has no `IF NOT EXISTS`, guard it). Runner: `schema.ts` `ensureSchema`/`runMigrations`.
- **`sessions.ts`** — `NewSession`/`Session`/`rowToSession`/`createSession` (`:27,36,54,72`) thread `claude_session_id`↔`claudeSessionId`. **Mirror this to thread whatever you persist.** The harness needs **two** values (`sessionId` + `resumeFrom` blob), so a `resume_from` TEXT column (JSON) plus reusing `claude_session_id` for the id — or two new columns — is cleaner than overloading one.
- **`appendEvents` (`sessions.ts:127-165`)** — assigns monotonic seq in a txn, bumps `last_activity_at`, returns last seq. Natural place to also record the resume cursor.

### Streaming / tail (durable resume — leave untouched)
- **`turn-tail.ts:52-76`** — `resolveTurn` classifies the last turn from the log + liveness. **Known inefficiency:** reads the *entire* event log (`readEvents` with no `sinceSeq`, `:56`) to find `lastUserSeq` via linear scan. A `resume_from`/last-user-seq cursor on `sessions` makes this O(1). Carry-over from #773 review — address while here (non-blocking).
- **`turn-tail.ts:122-199`** — `tailChunks`/`tailStream` (seq-cursored, `toUIMessageChunkStream`, deterministic ids). `STALE_TURN_MS=30_000`, `DEFAULT_POLL_MS=250`.
- **Routes:** kickoff `POST /api/sessions/[id]/chat` (`chat/route.ts:43-54`, `runSessionTurn` + `after(()=>turn.ingest)` to keep the serverless invocation alive); reconnect `GET /api/sessions/[id]/stream` (`stream/route.ts`, returns 204 when nothing to resume).

### Provider selection today
`startSession` (`start-session.ts:34-38`) **hardcodes `provider: "mock"`**. To activate the real runtime: register the provider in `provider.ts`, then either flip that default or add provider selection to the new-session flow (gate on credentials being present — fall back to mock when unset, so local no-cred dev still works).

---

## 4. What's already built downstream (no work needed)

The whole render path already handles the full `StreamChunk` union **including reasoning** — verified. So mapping the harness stream to `StreamChunk` correctly is *all* the UI needs.

- **`src/lib/transcript/chunk-adapter.ts:43-177`** — `StreamChunk → UIMessageChunk`. Contiguous `reasoning` chunks coalesce into one reasoning part (`reasoning-start/delta/end`, `:90-103`); open text/reasoning parts mutually close; `tool_result` with `metadata.diff` → `data-diff` part.
- **`src/components/folio/reasoning.tsx`** — the collapsible "thinking" aside (Radix Collapsible): auto-opens while streaming, auto-collapses 1s after, replayed reasoning mounts collapsed. `data-testid="reasoning"`.
- **`src/components/folio/message.tsx:83-216`** — groups parts; reasoning→`<Reasoning>`, tools→`Workings`, diff→`DiffCard`.
- **`src/app/(app)/sessions/[id]/live-session-view.tsx`** — `useChat` (`@ai-sdk/react`), throttled paint (`TOKEN_THROTTLE_MS=50`).
- **Adversarial mock** (#785/#787) is a **UI fixture**, not a provider: `src/lib/fixtures/demo-session.ts:265+` (`adversarialSession()`), reachable at `/sessions/demo?scenario=adversarial` and `?scenario=long`. Useful to eyeball the design at scale; it never touches `ComputeProvider`.

---

## 5. Credentials — three things, three places (all gated)

Full matrix: `web-next/docs/deploy.md:42-67`; template `web-next/.env.local.example`; sourcing values `web-next/CONTRIBUTING.md`.

| Variable | Mac `.env.local` | Cloud dev | Vercel prod | Source |
|---|---|---|---|---|
| `AI_GATEWAY_API_KEY` (preferred) **or** `ANTHROPIC_API_KEY` | ✓ | ✓ | ✓ | `npx vercel ai-gateway api-keys create` / console.anthropic.com |
| `VERCEL_TOKEN` / `VERCEL_TEAM_ID` / `VERCEL_PROJECT_ID` | ✓ | ✓ | **✗** (prod uses auto-injected `VERCEL_OIDC_TOKEN`) | vercel.com/account/tokens (team **`cloudcompute`**) |
| `GITHUB_WEB_WORKSPACES_APP_ID` + `GITHUB_APP_PRIVATE_KEY` | ✓ | ✓ | ✓ | `workspace-agents` GitHub App; PEM as single-line base64 |

Concrete values from CONTRIBUTING: `VERCEL_TEAM_ID=team_oGt9u60VkiPutA2CiKDDGQKV`, `VERCEL_PROJECT_ID=prj_ucOY3JKR5BCrbtbfz8DTSFJe5U9m`, Vercel project `cloudcompute/web-next` (https://web-next-ivory-six.vercel.app). Repo clone uses **short-lived, repo-scoped GitHub App installation tokens** (1h) — not a personal/OAuth token.

**Local review needs NONE of these** — only `AUTH_BYPASS=1` + `ALLOWED_LOGINS=fairchild`. Keep the provider falling back to mock when creds are absent so no-cred dev keeps working.

**Credential smoke test (do this first): `GET /api/diag/gateway`** (`src/app/api/diag/gateway/route.ts`, #797). Auth-gated; makes one tiny real call through the AI Gateway (`anthropic/claude-haiku-4.5`, "Reply with exactly: gateway live"). Healthy: `{ ok:true, reply:"gateway live", model, usage, latencyMs }`. Prove creds + billing + routing work here *before* wiring the runtime. Note this probe reads `AI_GATEWAY_API_KEY` specifically — a bare `ANTHROPIC_API_KEY` won't satisfy it, though it *will* satisfy the harness adapter's `auth.anthropic` path.

### Provisioning status (verified 2026-07-05 — partial, NOT fully unblocked)

Michael began provisioning. Current state, checking key names only (values redacted):

| Credential | Status | Note |
|---|---|---|
| `ANTHROPIC_API_KEY` | ✓ set (root `./.env`) | model auth covered; gateway key optional |
| `AI_GATEWAY_API_KEY` | ✗ | not set — so `/api/diag/gateway` will 500 until added; harness can use `ANTHROPIC_API_KEY` instead |
| `VERCEL_TOKEN` | ✓ set (root `./.env` + Vercel prod) | see two corrections below |
| `VERCEL_TEAM_ID` / `VERCEL_PROJECT_ID` | ✗ | **required off-platform** alongside the token; values known (`team_oGt9u60VkiPutA2CiKDDGQKV` / `prj_ucOY3JKR5BCrbtbfz8DTSFJe5U9m`) or `npx vercel link` in `web-next/` |
| `GITHUB_WEB_WORKSPACES_APP_ID` | ✓ set (root `./.env`) | |
| `GITHUB_APP_PRIVATE_KEY` | ✗ | **the repo-clone credential** — App ID present but PEM missing; sandbox can stream but can't clone without it |

**Two corrections the orchestrator must make before phase 2 passes:**

1. **Env-file location.** The runtime vars are in the **repo-root `./.env`**, but Next.js loads env from the `web-next/` cwd. `web-next/.env.local` is **absent**, so the dev server sees none of these. Move/copy the runtime vars into `web-next/.env.local` (`cp .env.local.example .env.local`, fill in). This is why nothing is wired yet despite the secrets existing.
2. **Production `VERCEL_TOKEN` is contrary to the design.** It was added to the Vercel prod deployment, but `deploy.md:52,59` says prod authenticates the Sandbox via the **auto-injected `VERCEL_OIDC_TOKEN`** — a static token there is redundant and a larger blast radius. Verify OIDC works in prod with a sandbox smoke, then remove the static prod token. (Off-platform — Mac/cloud-dev — the static token is correct and needed.)

**Remaining to run a real turn:** move vars to `web-next/.env.local` · add `VERCEL_TEAM_ID`+`VERCEL_PROJECT_ID` · add `GITHUB_APP_PRIVATE_KEY` · (optionally `AI_GATEWAY_API_KEY` if you want the gateway spend-cap path + a green diag probe). Model auth is already covered. This is the escalation trigger (recurring cost + secrets): the acceptance criteria are explicitly **live**, so confirm the full set with Michael or have him run the live gate before declaring the criteria met.

---

## 6. Proposed plan (phased, each phase independently reviewable)

Serial, one concern at a time. The seam is additive; nothing below rewrites the pipeline.

1. **Deps + version reconcile.** Add the three harness packages **exact-pinned** (`1.0.18`), bump `ai` to `7.0.15`. `pnpm install`, then `pnpm -C web-next typecheck && build` clean (watch the #780 `/404` stale-`.next` trap → `rm -rf .next`).
2. **Credential preflight.** Vars are already in `web-next/.env.local`. Start the dev server and hit **`GET /api/diag/preflight?sandbox=1`** (built this session) — it proves model + GitHub clone + Vercel + live sandbox bash/clone in one call. (`/api/diag/gateway` is the narrow model-only probe.) Land the preflight as its own small PR first, with a green run as evidence. If a check fails → fix creds / escalate to Michael before wiring the provider.
3. **Persistence: resume columns.** Migration `0003_*` adding `resume_from` (TEXT/JSON) + reusing/adding a harness session-id column; thread through `client.ts` + `sessions.ts`; keep `docs/schema.md` in sync. Behavior test the roundtrip.
4. **The provider.** New `src/lib/agent-runtime/harness-provider.ts` — a `ComputeProvider` (`id: "vercel"` or `"claude-code"`) whose `runTurn` constructs/reuses the module-scope `HarnessAgent`, creates/reattaches a session (from persisted `sessionId`+`resumeFrom`), streams, maps `fullStream` parts → `StreamChunk`, and on turn end calls `detach()`/`stop()` and persists the new `resumeFrom`+`sessionId`. Register in `provider.ts`. **Log raw stream parts on the first run** to confirm the reasoning-delta field name and which extras surface (§2 caveats).
5. **Activate selection.** Flip `startSession` off hardcoded `"mock"` when creds present (fall back to mock otherwise). Optionally optimize `resolveTurn` to use the new cursor (folds in the #773 carry-over).
6. **Real turn + evidence.** Send a real coding message in the live app; confirm prose + reasoning + tool cards + diff + end-of-turn stats render in Folio, **both themes**. Capture **video** of a real turn (edit lands, tests run), light + dark. Record **TTFT** and the **across-turn sandbox-reuse delta** (turn 2 shouldn't re-clone). Run a **follow-up turn** to prove resume, and a **tab-close mid-turn → reopen** to prove durable replay still works.

---

## 7. Acceptance criteria (from #750) + process

**Acceptance — all required:**
- [ ] A real Claude Code turn streams (prose + tool cards + diff + end-of-turn stats) into Folio, both themes.
- [ ] Follow-up turns resume the harness session; durable resume across tab-close still works.
- [ ] Versions exact-pinned; harness confined to one provider file behind `ComputeProvider`.
- [ ] Evidence: **video** of a real coding turn (edit lands, tests run), light + dark; pinned versions listed.
- [ ] Perf: real TTFT recorded; across-turn sandbox-reuse delta shown.

**⚠️ Open gate — clean build (was #780).** A clean `pnpm -C web-next install && pnpm -C web-next build` currently **fails** at prerender of `/500` and `/_error` with `<Html> should not be imported outside of pages/_document`, even after `rm -rf .next` (verified 2026-07-05 on this branch). #780 is closed but reproduces from clean — it's unrelated to any diff (Next's built-in error pages). `typecheck`/`lint`/unit tests are green. Settle this (reopen #780) before the real-runtime PR can claim a green build; if `web-next` CI is currently green on main, confirm whether the CI lane actually runs the prod build or is masking this.

**Process (from the execution brief + repo CLAUDE.md):**
- **One issue at a time, in order.** Full autonomous mandate; **self-merge** PRs scoped to `web-next/` (+ own CI/docs) that meet the Definition of Done.
- **Escalate, don't work around:** open the PR but do **not** merge when a change incurs recurring cost, needs secrets, makes a one-way architectural call, has a security dimension, or CI fails the same way 3× — **and treat any harness API surprise (rename, missing capability, doc-contradicting behavior) as escalation-worthy.** #750 hits the "needs secrets + recurring cost" trigger directly.
- **Reviewer gate:** every PR touching the runtime/backend seam → run `/code-review` via a **separate reviewer subagent on Opus** before merge.
- **Author label:** add `author:fable-orchestrator` (or your agent slug) to the PR — the GitHub account is shared.
- **Evidence is a merge gate.** Upload via `evidence.sh`/`mise run web:evidence -- --pr <N> --name <slug>`; paste hosted URLs into the PR body. Light+dark screenshots for UI; before/after/delta for perf. Remote sessions: see `docs/development/remote-sessions.md` for the sanctioned workarounds.
- **DoD:** green `web-next` CI (lint/typecheck/unit/build/Playwright/perf, no skips), self-verification (drove the real flow), `/simplify` pass, behavior tests, `Closes #750`.
- **Env note:** Node 22 + **pnpm 10** (pnpm 11 breaks `pnpm run` here — delete any stray `web-next/pnpm-workspace.yaml`).

---

## 8. Canonical references

- **Issue:** #750 (open) · companions #784/#785/#780 (closed) · merged #777/#779/#781/#787/#793/#796/#797/#803.
- **ADR:** `docs/decisions/web-next-harness-runtime.md` — the governing spec (additive `ComputeProvider`, harness owns projection/sandbox/auth/resume; we own the wrapper + persistence + terminal + UI; exit strategy = hand-roll the same contract).
- **Contract:** `backlog/web-next-execution-brief.md` — autonomy, escalation, DoD.
- **Design:** `web-next/docs/design.md` (Folio; calm/iA-Writer).
- **Architecture + turn anatomy:** `web-next/docs/architecture.html` (#803).
- **Deploy/creds:** `web-next/docs/deploy.md`; template `web-next/.env.local.example`; `web-next/CONTRIBUTING.md`.
- **Schema doc:** `web-next/docs/schema.md` (keep in sync with the new migration).
- **Harness typings (local):** `scratchpad/harness-inspect/*/package/dist/*.d.ts`.

**Open questions to resolve empirically on the first real turn:** reasoning-delta field name (`delta` vs `text`); whether `file-change`/`compaction` reach the consumer stream; exact managed-sandbox snapshot behavior (does turn-2 truly skip re-clone). Instrument, don't guess — this repo's own lesson: "ship a diagnostic probe instead of your third guess."
