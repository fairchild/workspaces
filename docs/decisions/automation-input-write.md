# Automation Input Write Decision

## Status

Accepted as an experimental V1.1 capability, double-gated and off by default.

## Context

[Automation API V1](./automation-api-v1.md) deliberately excluded terminal
input injection: it has different safety and user-expectation questions than
read/arrange verbs, and the decision record required any future capability to
define its own authority model, user expectation, audit surface, tests, and
documentation before landing. This record is that design.

The product need is a keystone primitive for agent orchestration: a trusted
process inside a WorkSpaces terminal tile writes text into its own tile's PTY
(for example, a wrapper script that queues a prompt into the agent it is
running next to). The PTY write path already exists — keyboard input and
drag-and-drop both deliver bytes through `ghostty_surface_text` — so this adds
a capability surface, not a new subsystem.

## Decision

Add `POST /v1/input/write` guarded by a new `input.write` capability.

- **Caller-scoped only.** The opaque handle is the target, exactly as in V1.
  Request bodies must not name a tile, surface, or host session; the existing
  forbidden-target-ID rail applies. A caller can write only to the PTY of the
  tile that owns its handle.
- **Double experiment gate.** The capability is granted at handle upsert only
  while the `Automation Input Write` experiment
  (`WORKSPACES_AUTOMATION_INPUT_WRITE`) is enabled, and it is effective only
  when the base Automation API experiment is also on. Because handles outlive
  settings changes, the app-side controller re-checks the flag on every
  request and fails closed with `capability_denied`.
- **Not part of `v1Capabilities`.** Default handles never widen. The grant
  list is a separate `inputWriteCapabilities` constant so the V1 envelope
  contract (and its golden-string test) is unchanged when the experiment is
  off.
- **Bounded payloads.** `text` must be a non-empty string of at most 32 KiB
  UTF-8. `submit: true` appends a single carriage return (`\r`, what Enter
  sends to a PTY). No other transformation is applied.
- **Content-free audit.** The listener's audit log records route-level
  metadata and error codes for every allowed and denied request, and never
  the written text — the same contract the audit stream already documents.
- **IME bypass.** The write path calls the libghostty surface directly and
  does not divert into the in-flight keyboard IME accumulator, so an
  automation write cannot be swallowed by a half-composed keyboard event.

## Consequences

- Scripts and agents inside a tile can type into themselves; nothing can type
  into another tile. Cross-tile orchestration still requires the target tile's
  own cooperation (its own handle).
- Users who never enable the experiment see no change: capability lists,
  envelopes, and docs describe `input.write` as experimental and off by
  default.
- The submit semantics (`\r`) are verified against real shells; multi-line
  payloads into bracketed-paste-aware TUIs may need paste-bracket wrapping in
  a follow-up if smoke testing shows per-line autocomplete firing.

## Rejected Alternatives

### Targeted Write By Surface ID

Rejected for this iteration. Writing into an arbitrary sibling tile would turn
identity back into authority and needs a child-handle model (for example,
handles minted by `tile.split` for surfaces the caller created). Deferred
until that authority model is designed.

### Gate Only At Grant Time

Rejected. Handles live as long as their tile, so a user who turns the
experiment off would leave already-granted handles writable. The per-request
re-check makes the settings toggle authoritative.

### Add `input.write` To `v1Capabilities`

Rejected. It would silently widen every existing handle and change the stable
V1 capability envelope. A separate grant list keeps default behavior
byte-identical.

## Documentation Contract

- [Automation API Guide](../automation-api.md) documents the user-facing
  command and its gating.
- [Automation API Reference](../development/automation-api.md) documents the
  route, capability, and limits.
- This record explains why input injection is allowed now, in this shape.
