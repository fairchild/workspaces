---
priority: 2
description: Polish items for the multi-agent terminal that didn't make the first polish PR
---

# Terminal Polish Follow-Ups

After the initial polish PR (resize bug + top 5 UX items), these are the rougher edges that remain. Listed roughly in order of user impact.

## 1. Cost awareness UI

Each sandbox costs ~$0.10/hr. With multiple agents per repo across multiple repos, this can add up unnoticed. Need:

- Header indicator: "● 3 active sandboxes"
- Hover/click → list of active sessions across all repos
- Estimated daily cost projection
- Auto-stop after N minutes idle setting

## 2. Backgrounded terminals lose output

When the user switches Terminal tab → another main tab, ghostty-web is currently kept mounted (post-polish PR). But the WebSocket might still close on long backgrounding. ttyd has a ring buffer; we need to verify reconnect-replay actually works after extended absence and add a smaller ring buffer in the proxy if not.

## 3. Resume preserves filesystem only, not shell process state

`Resume` restores the Vercel sandbox snapshot which captures the disk, but bash is a fresh process. So `cd somewhere`, `export VAR=...`, command history — all gone. Two options:

- **In-sandbox tmux**: run bash inside `tmux new -s shell` so the process survives. The sandbox can attach/detach.
- **UI disclosure**: spell out the limitation in the Resume button tooltip ("Resume restores files; shell session restarts").

## 4. Idle timeout / auto-stop / auto-snapshot

Standalone terminal sandboxes get the 30min default. User opens, walks away, comes back to "no active terminal". Should:

- Show countdown when terminal is idle ("idle for 25m, will stop in 5m unless used")
- Auto-snapshot before timeout so user can resume
- Configurable max idle minutes per sandbox

## 5. Sub-tab order is unstable

Sessions come from the DB ordered by `last_activity_at desc`. Sub-tab order changes when you interact with one. Confusing — should be alphabetical or first-created-first.

## 6. No keyboard shortcuts for sub-tabs

Cmd+1/2/3 switches main tabs. Need shortcuts for sub-tabs:
- Cmd+Shift+[ / Cmd+Shift+] for prev/next sub-tab
- Cmd+Shift+1..9 for direct sub-tab selection

## 7. Agents have isolated filesystems

By design, but surprising. User clones a branch in @april's terminal, switches to @plat's, the file isn't there. Either:

- Add a UI hint somewhere ("each agent has their own isolated workspace")
- Add a shared `/workspace/shared` volume mount that all agents see (Cloudflare R2 bucket via mountBucket)

## 8. agent_name column is overloaded

Means three different things in the `agent_sessions` table:
- The persona slug for chat agents (`april-clearwater`)
- The synthetic slot for ad-hoc shells (`shell`)
- The default agent identifier when no @mention

Refactor to a clearer model:
- `session_type: 'agent' | 'shell'`
- `agent_id: string | null` (only set for type=agent)
- Allow multiple shells per repo by promoting to `shell_name`

## 9. No visible cwd in fresh terminal

User sees `[vercel-sandbox@xxx repo]$` and has to type `pwd` to know where they are. A welcome banner like:

```
Welcome to fairchild/workspaces (sandbox)
working dir: /vercel/sandbox/repo
agent: shell  •  shutdown: 30 min idle

$
```

## 10. + button needs a picker, not a default action

Currently the `+` button just calls `startTerminal()` which uses the default agent slot. Should open a picker:

- `[default shell]`
- `[pick agent]` → submenu of available agents from agent discovery
- `[ad-hoc shell]` → arbitrary shell with a custom name

## 11. Sub-tab strip vs main tab strip visual confusion

Two horizontal nav bars stacked vertically with similar styling. Sub-tabs should be visually subordinate:
- Smaller font
- Left-indented (offset under the active main tab)
- Different background tint
- Or: collapsed into a dropdown when only one is active

## 12. Stale active reconciliation runs on every status poll

Each `/api/terminal/status` call iterates all sessions and calls `Sandbox.get()` for each. With 5 agents per repo, that's 5 HTTP calls every 10 seconds. Optimize:
- Cache sandbox state in the route for 5 seconds
- Or: batch the Sandbox.get calls (Vercel SDK doesn't support this today)
- Or: trust the DB more aggressively, only reconcile on demand

## 13. INP Issue toast pollutes screenshots

Vercel's dev INP feedback widget appears in the bottom-right of screenshots. Not our code but it's distracting. Either:
- Disable in dev mode somehow
- CSS to hide via `[data-vercel-feedback]` selector

## 14. No "session ended" notification on Stop

Click Stop → sub-tab disappears. No confirmation that it stopped, no undo, no "your sandbox was stopped" toast. Easy to misclick.

## References

- Initial polish PR: (this PR)
- Reflection thread: see Chronicle/notes from that session
- Architecture: `web/docs/architecture.md`
- Original multi-agent design: PR #298
