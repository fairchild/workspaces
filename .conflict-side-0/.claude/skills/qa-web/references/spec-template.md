# Spec template

Every test starts life as a Markdown spec under `web/specs/<slug>.md`. The spec is the durable source of intent; the `.spec.ts` is a runnable artifact of it.

## Template

```markdown
# Behavior: <imperative statement of what the user can do or observe>

## Preconditions
- <what must be seeded / logged in / URL state>

## Steps
1. <user-visible step — click, type, navigate>
2. ...

## Assertions (the oracle)
- <observable outcome — role, text, URL, network response, absence of errors>

## Negative cases
- <what should NOT happen>

## Notes
- **Viewport**: desktop (1440×900) / mobile (375×667) / both
- **Layer**: e2e-full / e2e-fast / integration / unit
- **Why E2E and not integration**: <justification, or "promote to src/**/__tests__/">
```

## Why each field exists

- **Behavior** — imperative, from the user's POV. Not "the component renders" but "the user sees their selected repo highlighted." If it can't be stated from the user's POV, it's probably implementation detail.
- **Preconditions** — the setup the test needs. Matches what `web/e2e/seed.ts` provides, plus whatever the test creates.
- **Steps** — user-visible only. No "call the function" — user clicks, types, navigates.
- **Assertions** — the oracle. At least one role-based or text-based check. Network/URL assertions count.
- **Negative cases** — what should NOT happen. Forces you to think about the inverse. Usually catches tautologies.
- **Notes: Viewport** — mobile gets forgotten. Force a choice.
- **Notes: Layer** — forces trophy-shape discipline. Most specs should end up as integration, not E2E.
- **Notes: Why E2E** — the justification. If you can't write a reason, promote the spec to integration/unit.

## Example

```markdown
# Behavior: user can send a chat message by pressing Enter, and the message appears in the timeline

## Preconditions
- Auth bypass active (`DEV_BYPASS_AUTH=1`).
- Seeded repo with at least one prior message exists (from `e2e/seed.ts`).
- User is on `/dashboard/fairchild/workspaces?tab=chat`.

## Steps
1. Focus the compose textarea (should be autofocused on page load).
2. Type "hello world".
3. Press Enter.

## Assertions (the oracle)
- The timeline contains a message whose author is the current user and whose content is "hello world".
- The compose textarea is cleared.
- A `POST /api/chat/messages` fires with body containing `"content":"hello world"`.

## Negative cases
- Pressing Enter on an empty textarea does NOT send.
- Pressing Shift+Enter does NOT send (inserts a newline instead).

## Notes
- **Viewport**: both — Enter behavior on mobile keyboards differs; verify on 375×667 too.
- **Layer**: e2e-full
- **Why E2E and not integration**: relies on the real SSE response loop and the server echoing the message back; an integration test with MSW would mock the same handler we're trying to verify wires up.
```

## Bad spec (reject if the agent produces this)

```markdown
# Behavior: the send button works

## Steps
1. Click send.

## Assertions
- The function is called.
```

Why bad: "the function is called" is not user-observable. "Works" is not a behavior. No preconditions. No negative cases. The test this spawns is tautological.
