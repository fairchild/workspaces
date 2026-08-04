# Terminal Arc Retrospective — April 2026

A post-mortem on the eight-PR arc that took the web terminal from
"works, mostly" to "solid, verified end-to-end" — and the agent
chat path from "silently broken" to "actually working."

## Scope

PRs #299 through #309, one session of work. Mix of:

- `#299` Terminal resize bug + multi-agent UX polish
- `#302` Security fixes + correctness fixes (HMAC ttyd auth, fall-through, migration, SSE exec cleanup, panel refactor)
- `#303` 47-second INP block on Start button (fire-and-forget polling)
- `#305` ttyd auth gap in `createSandbox` + `useTerminalSessions` reset bug + `displayAgentName` cleanup
- `#306` `buildRunnerScript` extraction + `claudeAuthFiles` helper + backlog reconcile
- `#307` Real shell-script helper (replacing `echo $VAR` helper from #306)
- `#308` Temporary diagnostic probe in runner script
- `#309` The actual fix: `source env.sh` in the runner

By the end: the terminal tab works reliably, the agent chat path
actually reaches claude, and the backlog is organized into "small
polish" vs "architecture" files with no overlap.

## What went right

### Incremental refactors that paid off later

Each refactor set up the next fix:

- `#305` extracted `startTtyd(sandbox)` — the "one place decides how
  ttyd runs" helper. Without it, #302's ttyd auth gap would have
  required three-place edits and probably drifted again. **It
  cashed in again in #309** — the env.sh source pattern lives right
  next to `startTtyd` in the file, same reasoning.
- `#306` extracted `buildRunnerScript(tools)` — the "one place
  decides how the agent runs" helper. Without it, every attempted
  fix to the runner would have been an inline heredoc edit; with it,
  every attempted fix was a single function edit. When the actual
  fix landed in `#309`, it was a 4-line change to `buildRunnerScript`
  plus a new `buildEnvSource` function.

**Lesson:** extractions that seem like "I'm making it slightly cleaner
for the next person" routinely pay off in the very next PR. They're
not speculative — they're direct enablers.

### The diagnostic probe (#308)

**Highest-leverage commit in the whole arc.** Three ship cycles of
guess-fix-verify-fail (#306, #307, and the implicit pre-#306 state)
were replaced by one ship cycle of probe-observe-fix. The probe was
~30 lines of `echo` + `ls` + `cat` in the runner script. It took ~10
minutes to write, 2 minutes to ship, and the output conclusively
identified the root cause:

```
ANTHROPIC_API_KEY length: 0
ANTHROPIC_AUTH_TOKEN length: 0
CLAUDE_CONFIG_DIR:
--- ls -la  ---
ls: cannot access '': No such file or directory
```

`Sandbox.create({env: {...}})` was not propagating env vars to
`runCommand` subprocesses. Guessing would never have found that —
I would have kept iterating on `apiKeyHelper` variants assuming the
env was set.

**Lesson:** when you're on your second guess for a bug, stop
guessing. Ship a probe. One probe ship cycle beats three guess
cycles in total elapsed time, context spent, and confidence.

### The backlog reconciliation

Two terminal backlog files had grown overlapping items. Splitting
them into `terminal-polish-followup.md` (small, 1-PR scope) and
`terminal-architecture-followups.md` (design needed) along the
dimension that actually matters — not by "when we added it" or "who
wrote it" — made both files easier to scan and plan from.

The verification in #309's production test was literally "ask April
to list the 8 items in the new architecture file." That the agent
returned the exact 8 items proved both the fix AND the backlog
reorganization.

### Evidence discipline

Every merged PR has an uploaded evidence screenshot in the R2 store.
Every production-verified claim has a captured stream output or DOM
query in the PR comments. This made it easy to go back and see what
was actually proven vs. what was assumed — which is how I noticed
that #306 and #307 had NO end-to-end agent test in their evidence.

## What went wrong

### I shipped #306 and #307 without real verification

Both PRs had green tests, green lint, green CI, and production
screenshots showing the terminal tab working. **Neither one tested
the thing they were fixing.** The claude CLI auth bug only shows up
when the agent runner actually runs inside a provisioned sandbox,
and my test surface didn't include that.

I verified adjacent things — the terminal tab started, the
provisioning placeholder rendered, the ttyd auth URL had a token —
but not the actual thing the PR claimed to fix. Classic "verified
what was easy to verify, not what mattered."

**Cost:** two extra ship cycles, a chunk of context, and the time
cost of re-reading the file three times.

**Fix for next time:** for PRs that change sandbox creation code,
the test plan MUST include "send a real chat message to a named
agent in production, read the stream, confirm a model response."
No exceptions. The CLAUDE.md lesson captures this.

### I kept guessing after the first fix failed

#306 failed in production. I immediately wrote #307 (a different
apiKeyHelper approach) based on a new guess, without instrumenting
the real environment. #307 also failed. *Only then* did I ship
#308, the probe, which found the actual problem.

If I had shipped the probe first, I would have skipped two wasted
ship cycles. The right move after the first production failure is
"go look at what the sandbox actually contains," not "try a
different variant."

**Fix for next time:** after the second guess at a bug, stop and
instrument. The systematic-debugging skill says this. I didn't
follow it.

### The polishing arc drifted from "close out what's open" to "keep finding new things"

Around #305 and #306 I was doing a clean polish pass — finding things
in the code I'd just read, fixing them, moving on. That was the
right mode. But once I hit the claude CLI bug and it didn't fix on
the first try, the polishing arc became a debugging arc. I should
have acknowledged that shift explicitly instead of letting it
continue as "one more polish PR."

**Fix for next time:** when the work shifts from "tidying" to
"firefighting," name it. Pause, reset the plan, decide whether to
push through or defer.

## Key insights

### `Sandbox.create({env})` doesn't propagate — and nobody documents this

The Vercel sandbox SDK's `env` parameter on `Sandbox.create()` sets
env vars for... something. Not for subsequent `runCommand`
invocations. Not documented. Not flagged in the SDK types. The
only way to find it is to instrument the runner.

Worth a PR upstream to their docs.

### apiKeyHelper execution model

Claude CLI invokes `apiKeyHelper` via execve, not `/bin/sh -c`. That
means `"echo $VAR"` as a helper command is passed literally (the
command is split into argv `["echo", "$VAR"]`). Writing a real
shell script with `#!/bin/sh` and pointing `apiKeyHelper` at its
absolute path works.

This is documented but easy to miss — the docs just say "a shell
command whose stdout is the API key" which is ambiguous.

### The "one-place helper" pattern is cheap and effective

`startTtyd`, `buildRunnerScript`, `buildEnvSource`, `claudeAuthFiles`
— each took ~10 lines to extract and each prevented a bug class from
recurring. The cost is negligible and the benefit compounds every
time someone touches the area.

## Files changed over the arc

- `web/src/lib/agent-runtime/vercel-sandbox.ts` — the center of gravity. Several rounds of extraction + fix.
- `web/src/app/dashboard/components/terminal-canvas.tsx` — created in #302 (panel refactor).
- `web/src/app/dashboard/components/use-terminal-sessions.ts` — created in #302, fixed in #303 (INP) and #305 (reset effect).
- `web/src/app/dashboard/components/terminal-panel.tsx` — refactored in #302, simplified in #305.
- `web/src/lib/agent-sessions.ts` — migration for `terminal → shell` rename (#302).
- `backlog/done/terminal-polish-followup.md` — rewritten in #306.
- `backlog/done/terminal-architecture-followups.md` — renamed + rewritten in #306.
- `backlog/terminal-tmux-and-followups-plan.md` — deleted in #306.
- `docs/development/agent-chat-sandbox.md` — auth section added (this retrospective's PR).

## What's next

The architecture backlog is now the single source of truth for
bigger terminal items. Top three in priority order:

1. **tmux inside the sandbox** for real Resume continuity. The
   `startTtyd` extraction makes this a one-line change in one
   place — the value of that refactor cashes in again.
2. **Delete or commit-to-deploy the Cloudflare provider scaffold.**
   500 lines of dead code that future contributors will trip over.
   ~1 hour of work to delete.
3. **Reconciliation cost cache.** Small perf win, cheap to implement.

None of these are urgent. The agent chat path works, the terminal
tab works, and the next user-facing bug is more likely to come from
something we haven't touched yet.
