---
status: done
issue: 528
completed: 2026-05-25
resolution: promoted-to-github-issue
priority: 2
description: Small terminal polish items — each fits in one PR and needs no architectural decision. Larger items live in terminal-architecture-followups.md.
---

# Terminal Polish Follow-Ups

Small UX and quality items for the multi-agent terminal. Each is scoped
to fit in one PR with no design discussion needed. Listed roughly in
order of user impact.

For larger items that need design discussion (tmux, reconciliation cost,
agent_name refactor, Cloudflare scaffold decision, cost UI), see
`terminal-architecture-followups.md`.

## 1. Backgrounded terminals — verify reconnect-replay actually works

When the user switches Terminal tab → another main tab, ghostty-web
stays mounted (kept around via `display: none` in `TerminalCanvas`).
But the WebSocket might still close on long backgrounding. ttyd has a
ring buffer; we need to verify reconnect-replay actually works after
extended absence and add a smaller ring buffer in the Cloudflare proxy
if not.

Verification: open the terminal tab, run `seq 1 1000`, switch to
Dashboard for 5 minutes, switch back. Expect to see all 1000 lines.

## 2. Sub-tab order is unstable

Sessions come from the DB ordered by `last_activity_at desc`. Sub-tab
order changes when you interact with one — confusing because the tab
you just clicked moves. Should be either alphabetical or
first-created-first.

Fix: order sub-tabs by `created_at asc` in `getSessionsForRepo` (or in
the panel after fetch). Keep `last_activity_at` ordering only for
"which session is the most recent" lookups.

## 3. No keyboard shortcuts for sub-tabs

Cmd+1/2/3 switches main tabs. Need shortcuts for sub-tabs:

- `Cmd+Shift+[` / `Cmd+Shift+]` for prev/next sub-tab
- `Cmd+Shift+1..9` for direct sub-tab selection

Wire into the same dashboard keyboard handler that owns Cmd+1/2/3.

## 4. No visible cwd / welcome banner in fresh terminal

User sees `[vercel-sandbox@xxx repo]$` and has to type `pwd` to know
where they are. A welcome banner like:

```
Welcome to fairchild/workspaces (sandbox)
working dir: /vercel/sandbox/repo
agent: shell  •  shutdown: 30 min idle

$
```

Implement by writing to ttyd's stdin via the sandbox runCommand before
detaching, or via a `.bashrc` snippet baked into the v3 base snapshot.

## 5. Sub-tab strip visual subordination

Two horizontal nav bars stacked vertically with similar styling. The
sub-tab strip should be visually subordinate to the main tab bar:

- Smaller font
- Different background tint
- Or: collapsed into a dropdown when only one is active

Pure CSS change, low risk.

## 6. "Session ended" notification on Stop

Click Stop → sub-tab disappears immediately. No confirmation, no undo,
no "your sandbox was stopped" toast. Easy to misclick. Add a brief
toast that says "Stopped <agent> sandbox" with a 5-second undo button
(re-creates the sandbox via createTerminalSandbox; doesn't restore
state — that's the tmux item in the architecture backlog).

## 7. Vercel INP feedback widget pollutes evidence screenshots

Vercel's dev INP feedback widget appears in the bottom-right of every
production screenshot. Not our code but it's distracting in evidence
uploads.

Fix: CSS to hide via `[data-vercel-feedback]` selector, OR set the
`vercel.feedback` cookie to disable, OR ignore in screenshot tooling.
Cheapest: a CSS rule scoped to a `?evidence=1` query param that
evidence.sh appends.

## 8. Agents have isolated filesystems — surface this

By design (each sandbox is its own /vercel/sandbox), but surprising.
User clones a branch in @april's terminal, switches to @plat's, the
file isn't there.

Easiest fix: a one-line hint in the welcome banner or the sub-tab
hover tooltip ("each agent has their own isolated workspace"). The
shared-volume option is an architectural item — see
`terminal-architecture-followups.md`.

## References

- Architecture items: `backlog/terminal-architecture-followups.md`
- Architecture overview: `web/docs/architecture.md`
- Original multi-agent design: PR #298
