# Session Handoff

## Current Task
Web frontend performance: fixed 7,225ms INP on compose bar and reduced re-renders across the dashboard.

## Progress
- Fixed INP root cause: streaming state no longer recreates `handleSend` callback (streaming ref pattern)
- Extracted StreamingBubble as isolated sibling so SSE updates don't touch MessageList tree
- Batched SSE chunks via requestAnimationFrame (max 60 renders/sec, was 100+)
- Wrapped ComposeBar, ChatMessageRow, EventGroupRow in React.memo
- Stabilized polling with compare-before-replace (length + first/last ID)
- Stabilized handleNewChatMessage via activeTabRef (created once)
- Cached formatTime (30s TTL) and dayKey (permanent) to reduce Date allocations
- Fixed double tryParseDispatchMetadata call in message-list render
- Rebased on main's persistent sandbox PR (#277), resolved 5 conflicts integrating streaming status states + optimistic rendering with perf architecture
- Reverted mention debounce during /reflect — added latency for negligible gain

## Key Decisions
- **Streaming ref over state for handleSend guard**: The core INP fix. `streamingRef.current` breaks the dependency chain so `handleSend` is stable during streaming. ComposeBar's `onSend` prop stops changing.
- **StreamingBubble as sibling, not inside MessageList**: Trades scroll-with-messages for render isolation. The bubble pins above compose bar — acceptable UX, significant perf win.
- **Compare-before-replace for polling**: `setEntries(prev => same ? prev : data)` avoids reference changes on identical polls. Uses length + first/last ID — sufficient for append-only timelines.
- **RAF batching, not debounce**: Accumulate SSE chunks in ref, flush once per animation frame. Preserves streaming responsiveness while capping renders.
- **No mention debounce**: Reverted during reflect. The regex is trivial; 150ms delay made autocomplete feel sluggish for no real gain.

## Next Steps
1. Fill in bot command routing TODO stubs (5 tests for @spaces status/pipeline)
2. Seed test data for remaining E2E placeholders (repo detail, activity feed, day separators)
3. Visual QA collapsed events with live webhook data on Vercel preview
4. Consider list virtualization (Phase 5 from plan) if timelines exceed ~200 entries

## Relevant Files
- `web/src/app/dashboard/components/chat-panel.tsx` — streaming ref, RAF batching, optimistic sends
- `web/src/app/dashboard/components/streaming-bubble.tsx` — NEW: isolated streaming display with status labels
- `web/src/app/dashboard/components/compose-bar.tsx` — React.memo wrapped
- `web/src/app/dashboard/components/message-list.tsx` — removed streaming, memo ChatMessageRow, ChatOrDispatchRow
- `web/src/app/dashboard/components/event-group-row.tsx` — React.memo wrapped
- `web/src/app/dashboard/components/activity-feed.tsx` — stable setEvents comparison
- `web/src/app/dashboard/components/dashboard-shell.tsx` — stable handleNewChatMessage via activeTabRef
- `web/src/app/dashboard/components/timeline-utils.ts` — cached formatTime
- `web/src/lib/timeline-utils.ts` — cached dayKey

## Open Questions
- Pre-existing race: rapid stream switching can null newer stream via old finally block (narrow window, not introduced by this PR)
- `agents ?? []` in chat-panel creates new empty array each render when no agents — breaks memo in loading state, low impact

---
*Session completed on 2026-04-02*
*PR: #280 — perf(web): fix INP on compose bar and reduce re-renders*
