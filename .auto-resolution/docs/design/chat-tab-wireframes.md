# Chat Tab — Detailed Wireframes

Selected layout: **Chat as tab in main panel** alongside Overview and Agents tabs.

---

## State 1: Empty Chat (no repo selected)

```
┌──────────┬──────────────────────────────────┬───────────────┐
│ Repos    │                                  │ All Activity  │
│          │  Select a repo to start chatting  │               │
│   works… │                                  │ [CI] 3 commits│
│   beads  │  or type a message to dispatch   │ [PR] #243     │
│   bread  │  an agent across any repo:       │ [PUSH] beads  │
│   jrnl…  │                                  │               │
│          │  @april repo:workspaces fix #234  │               │
│          │                                  │               │
│          │                                  │               │
│          │                                  │               │
│          │                                  │               │
│          ├──────────────────────────────────┤               │
│          │ [@] Type a message...     [Send] │               │
└──────────┴──────────────────────────────────┴───────────────┘
```

---

## State 2: Repo Selected — Dashboard is Default Tab

The existing dashboard (stats, agent cards, pipeline) is the first tab.
Chat is a second tab you switch to when you want to interact.

```
┌──────────┬──────────────────────────────────┬───────────────┐
│ Repos    │ fairchild/workspaces             │ Activity      │
│          │ [Dashboard] [Chat •]             │               │
│ > works… │                                  │ [CI] 3 commits│
│   beads  │ Overview                         │ [PR] #243     │
│          │ ┌────┐┌────┐┌────┐┌────┐        │               │
│          │ │ 4  ││ 12 ││ 2  ││ 3  │        │               │
│          │ │agts││skls││PRs ││rdy │        │               │
│          │ └────┘└────┘└────┘└────┘        │               │
│          │                                  │               │
│          │ Agent Team                       │               │
│          │ ┌─april──────┐ ┌─peter─────┐    │               │
│          │ │ ● Active   │ │ ○ Idle    │    │               │
│          │ │ release,   │ │ planning, │    │               │
│          │ │ CI, fixes  │ │ specs     │    │               │
│          │ └────────────┘ └───────────┘    │               │
│          │                                  │               │
│          │ Issue Pipeline                   │               │
│          │ Ready │ Claimed │ Review │ Merge │               │
└──────────┴──────────────────────────────────┴───────────────┘
```

## State 3: Chat Tab with Mixed Timeline

Switching to Chat tab shows events and messages interleaved.
System events are compact; human/agent messages get full treatment.

```
┌──────────┬──────────────────────────────────┬───────────────┐
│ Repos    │ fairchild/workspaces             │ Activity      │
│          │ [Dashboard] [Chat •]             │               │
│ > works… │                                  │ [CI] 3 commits│
│   beads  │ ── Today ──────────────────────  │ [PR] #243     │
│          │                                  │               │
│          │  10:12  PUSH  3 commits to main  │               │
│          │  10:14  CI    ✗ tests failed      │               │
│          │                                  │               │
│          │  10:16  you                      │               │
│          │  @april the test_workspace_crud  │               │
│          │  test is flaky again. Fix it     │               │
│          │  and make sure CI is green.      │               │
│          │                                  │               │
│          │  10:16  spaces                   │               │
│          │  Dispatching april...            │               │
│          │  ┌─────────────────────────────┐ │               │
│          │  │ Task created: fix/flaky-234 │ │               │
│          │  │ Agent: april  Status: ● run │ │               │
│          │  └─────────────────────────────┘ │               │
│          │                                  │               │
│          │  10:22  april                    │               │
│          │  Found the issue — race in async │               │
│          │  setup. Opened PR #245.          │               │
│          │                                  │               │
│          │  10:23  PR  opened #245          │               │
│          │  10:24  CI  ✓ all checks passed   │               │
│          │                                  │               │
│          ├──────────────────────────────────┤               │
│          │ [@april] ...              [Send] │               │
└──────────┴──────────────────────────────────┴───────────────┘
```

### Message Types in Timeline

| Type | Style | Source |
|------|-------|--------|
| **System event** | Compact single line, muted color, event badge | Webhook |
| **User message** | Full bubble, right-aligned or labeled "you" | User input |
| **Bot message** | Full bubble, labeled "spaces" | Chat SDK bot |
| **Agent update** | Full bubble, labeled with agent name, card for status | Agent via Discussion |
| **Dispatch card** | Inline card with task ID, agent, branch, status | Bot response |

---

## State 4: @mention Autocomplete

```
│          │                                  │
│          ├──────────────────────────────────┤
│          │ [@ap                             │
│          │ ┌─────────────────────────────┐  │
│          │ │ ● april                     │  │
│          │ │   CI/CD, releases, bug fixes│  │
│          │ │                             │  │
│          │ │ ○ peter-planner             │  │
│          │ │   Planning, specs, roadmap  │  │
│          │ │                             │  │
│          │ │ ◆ spaces (bot)              │  │
│          │ │   Status queries, help      │  │
│          │ └─────────────────────────────┘  │
│          │                         [Send]   │
└──────────┴──────────────────────────────────┘
```

- Autocomplete triggers on `@` character
- Shows agent status dot (active/idle)
- Brief description of agent capabilities
- `spaces` (the bot) is always available for queries
- Tab/Enter to select, Escape to dismiss

---

## State 5: Dispatch Confirmation

After submitting a message with an @mention:

```
│          │                                  │
│          │  @april fix the flaky test #234  │
│          │                                  │
│          │ ┌─ Confirm dispatch ───────────┐ │
│          │ │                              │ │
│          │ │  Agent   ● april             │ │
│          │ │  Repo    fairchild/workspaces│ │
│          │ │  Task    fix the flaky test  │ │
│          │ │          in #234             │ │
│          │ │                              │ │
│          │ │  Creates a GitHub Discussion │ │
│          │ │  and dispatches the agent.   │ │
│          │ │                              │ │
│          │ │  [Cancel]       [Dispatch]   │ │
│          │ └──────────────────────────────┘ │
│          │                                  │
│          ├──────────────────────────────────┤
│          │ [@april] ...              [Send] │
└──────────┴──────────────────────────────────┘
```

---

## State 6: Agent Working — Live Progress

While an agent is active, its updates stream in:

```
│          │                                  │
│          │  10:16  spaces                   │
│          │  Dispatching april...            │
│          │  ┌─────────────────────────────┐ │
│          │  │ Task: fix flaky test #234   │ │
│          │  │ Branch: fix/flaky-234       │ │
│          │  │ Status: ● working           │ │
│          │  │ ━━━━━━━━━━━━━━━━━━━░░░░░░  │ │
│          │  │ Investigating test failure..│ │
│          │  └─────────────────────────────┘ │
│          │                                  │
│          │  10:19  april                    │
│          │  Root cause identified: race     │
│          │  condition in TestWorkspaceCrud  │
│          │  async setup. Applying fix...    │
│          │                                  │
│          │  10:22  april                    │
│          │  ┌─────────────────────────────┐ │
│          │  │ PR #245 opened             │ │
│          │  │ fix/flaky-234 → main        │ │
│          │  │ +12 -3  CI: ● running       │ │
│          │  │ [View PR]                   │ │
│          │  └─────────────────────────────┘ │
│          │                                  │
│          │  10:24  CI  ✓ all checks passed   │
│          │                                  │
│          │  ● april is typing...            │
│          │                                  │
```

---

## State 7: Bot Query (no dispatch)

Asking `@spaces` or `@status` returns info without dispatching:

```
│          │                                  │
│          │  11:00  you                      │
│          │  @spaces status                  │
│          │                                  │
│          │  11:00  spaces                   │
│          │  ┌─ Agent Status ─────────────┐  │
│          │  │                            │  │
│          │  │ ● april     Working on     │  │
│          │  │             PR #245        │  │
│          │  │             3m ago         │  │
│          │  │                            │  │
│          │  │ ○ peter     Idle           │  │
│          │  │             Last: planned  │  │
│          │  │             sprint 12      │  │
│          │  │             2h ago         │  │
│          │  │                            │  │
│          │  │ Pipeline: 3 ready,         │  │
│          │  │ 1 claimed, 2 in review     │  │
│          │  └────────────────────────────┘  │
│          │                                  │
```

---

## Compose Bar Details

```
┌─────────────────────────────────────────────────────┐
│ [@april ▼]  Type a message...               [Send]  │
│              ↑                                ↑      │
│         agent picker               Enter or click   │
│         (click to change)          Cmd+Enter = send  │
└─────────────────────────────────────────────────────┘
```

- **Agent picker** (left): shows currently targeted agent, click to change or clear
- **Text input**: auto-grows, supports markdown, code blocks
- **Send**: Enter sends (Shift+Enter for newline), or click button
- When no agent selected, messages go to `@spaces` bot by default

---

## Tab Bar with Unread Badge

```
  [Overview]  [Agents]  [Chat 3]
                          ↑
                    unread count badge
                    (appears when on other tabs
                     and new messages arrive)
```

---

## Navigation: Activity Feed → Chat

Clicking an event in the right-side activity feed can jump to Chat tab:

```
Activity panel:                    Main panel switches to Chat:
┌───────────────┐                 ┌──────────────────────────┐
│ [CI] ✗ failed │ ← click →      │ [Overview] [Agents] [Chat]
│               │                 │                          │
│               │                 │ Re: CI failure on main   │
│               │                 │ [@april] ...      [Send] │
└───────────────┘                 └──────────────────────────┘
```

This bridges the read-only activity feed with the interactive chat.
