# Persistent Sandbox via Snapshot API for Conversation Continuity

**Status**: Ready for implementation
**Priority**: High — unlocks true conversational agent experience
**Depends on**: improve-webspace-chat branch (UX fixes + context injection already shipped)

## Problem

Each @agent mention in the web chat creates a fresh Vercel Sandbox (ephemeral, 10min timeout). The agent has no memory of prior interactions — even with the recently added context injection (last 10 messages + history file), the agent starts fresh each time: new sandbox, new clone, new Claude Code CLI invocation.

Users expect conversational continuity: "what did I ask you last?" should work naturally, and the agent should remember files it read, decisions it made, and context it built up.

## Solution: Snapshot-Based Session Persistence

Use the Vercel Sandbox SDK's snapshot/restore API to persist sandbox state across invocations within a conversation thread.

### Architecture

```
First mention in thread:
  1. Create sandbox from base snapshot (existing flow)
  2. Run agent, stream response (existing flow)  
  3. NEW: Take snapshot after response completes
  4. Store snapshot ID in agent_sessions table
  5. Stop sandbox (free resources)

Follow-up mention in same thread:
  1. Look up active session for thread (existing flow)
  2. NEW: Restore from snapshot (instead of creating fresh)
  3. Run agent with --resume flag (or prepend conversation state)
  4. Stream response
  5. Take new snapshot, store ID
  6. Stop sandbox
```

### Key Files to Modify

| File | Change |
|------|--------|
| `web/src/lib/agent-runtime/vercel-sandbox.ts` | Add `snapshotAfterResponse()`, modify `createSandbox` to accept snapshot source, add `restoreFromSnapshot()` |
| `web/src/lib/agent-runtime/session-manager.ts` | After streaming completes, call `snapshotAfterResponse()`. On resume, call `restoreFromSnapshot()` instead of `createSandbox()` |
| `web/src/lib/agent-sessions.ts` | Add `snapshot_id` column to `agent_sessions` table, add `updateSnapshotId()` function |
| `web/src/lib/agent-runtime/types.ts` | Add `snapshotId?: string` to `SandboxResult`, add `RestoreRequest` type |

### Vercel Sandbox SDK Reference

The SDK (v1.9.0 installed) already supports this:

```typescript
// Snapshot after work
const snapshot = await sandbox.snapshot({ expiration: ms("7d") });
// snapshot.snapshotId → store this

// Restore later
const sandbox = await Sandbox.create({
  ...getCredentials(),
  source: { type: "snapshot", snapshotId: storedSnapshotId },
  timeout: ms("10m"),
  // ... same config
});
```

The existing `VercelSandboxProvider` already implements `SnapshotCapable` interface with `createSnapshot()` and `restoreSnapshot()` methods — they just aren't wired into the session lifecycle.

### Claude Code CLI Conversation Continuity

Two approaches, from simpler to fuller:

**Approach A: Context file (already implemented)**
- Recent messages prepended to each invocation
- Chat history file at `/vercel/sandbox/chat-history.txt`
- Survives snapshot/restore since it's on the filesystem
- Pro: Simple, works now. Con: Agent doesn't remember its own reasoning, tool calls, etc.

**Approach B: Claude Code `--resume` (fuller continuity)**
- Claude Code CLI stores session data in `~/.claude/` on the filesystem
- After snapshot/restore, session data persists
- Invoke with `claude --resume <session-id>` instead of `claude -p`
- Pro: Full conversation memory. Con: Need to capture and pass session ID, change runner script.

**Recommendation**: Start with Approach A (already done) + snapshot persistence. Add `--resume` as a follow-up once snapshot lifecycle is stable.

### Database Migration

```sql
ALTER TABLE agent_sessions ADD COLUMN snapshot_id TEXT;
-- Index for snapshot lookups
CREATE INDEX idx_agent_sessions_snapshot ON agent_sessions(snapshot_id);
```

### Session Lifecycle State Machine

```
                  ┌─────────┐
                  │ starting │
                  └────┬─────┘
                       │ createSandbox()
                  ┌────▼─────┐
                  │ streaming │
                  └────┬─────┘
                       │ response complete
                  ┌────▼─────┐
            ┌─────┤  active   ├──────┐
            │     └──────────┘      │
            │ snapshotAfterResponse()│ timeout / explicit end
            │                       │
       ┌────▼─────┐           ┌─────▼────┐
       │ snapshot- │           │completed │
       │   ted     │           └──────────┘
       └────┬─────┘
            │ follow-up mention
            │ restoreFromSnapshot()
       ┌────▼─────┐
       │ streaming │ (back to active flow)
       └──────────┘
```

### Snapshot Expiration & Cleanup

- Set snapshot expiration to 7 days (`ms("7d")`)
- Store `snapshot_created_at` alongside `snapshot_id`
- Periodic cleanup: delete sessions where snapshot is > 7 days old
- Each new snapshot in a thread replaces the previous one (keep only latest)

### Edge Cases

1. **Snapshot creation fails**: Log warning, continue as if ephemeral. Next mention creates fresh sandbox.
2. **Snapshot restore fails (expired/deleted)**: Fall back to fresh sandbox creation. Clear stale snapshot_id.
3. **Concurrent mentions in same thread**: Lock on thread_id to prevent duplicate snapshots. The existing `getActiveSessionForThread()` check handles this partially.
4. **Sandbox timeout during snapshot**: Increase timeout window. Or snapshot eagerly (before the 10min timeout).

### Network Policy Note

The snapshot preserves env vars (including `ANTHROPIC_API_KEY`). Ensure the restored sandbox's network policy matches the original. The `Sandbox.create` call with `source: { type: "snapshot" }` should include the same `networkPolicy`.

### Testing Plan

1. Unit test: Mock snapshot/restore cycle, verify session state transitions
2. Integration test: Create sandbox → snapshot → restore → verify filesystem state persists
3. Manual test: Send two @agent messages in same thread, verify second message has context from first
4. Expiration test: Verify stale snapshots are handled gracefully

### Cost Consideration

Snapshots are stored by Vercel and count toward storage. At 7-day expiration with ~1 snapshot per conversation thread, storage should be manageable. Monitor via Vercel dashboard.
