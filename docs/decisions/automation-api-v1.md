# Automation API V1 Decision

## Status

Accepted for the V1 experimental Automation API.

## Context

WorkSpaces has strong internal primitives for a local app-shell control plane:
terminal surfaces have host-session identity, `SurfaceStore` owns surface
registration, and the tile model can focus, split, and close terminal surfaces.
Trusted coding agents and scripts running inside a WorkSpaces terminal need a
small way to ask the app shell about their context and request nearby tile
changes.

The risk is that a broad API could accidentally become cmux-style remote
control before the product has reviewed safety, user expectations, browser
mutation, input injection, and cross-workspace authority.

## Decision

V1 ships as a local-only, same-user, experimental API exposed through a Unix
domain socket named `automation.sock`. It is separate from the Claude hook
listener and has its own lock file.

Only terminal surfaces receive discovery environment:

```bash
WORKSPACES_AUTOMATION_SOCKET=/path/to/automation.sock
WORKSPACES_AUTOMATION_HANDLE=<opaque capability handle>
```

The opaque handle is the authority for scoped requests. Requests do not get to
name their target tile, surface, or host session. The app resolves the handle
against the live terminal-surface mapping and derives:

- live host session
- tile identity
- surface kind
- window scope
- app scope
- capabilities

V1 exposes only:

- unauthenticated liveness
- caller context
- in-scope surface listing
- tile focus relative to the caller
- tile split from a primary terminal tile
- caller tile close through the normal close path

## Consequences

This keeps the first API useful for shell ergonomics and coding-agent
coordination while preserving strong boundaries:

- no caller-supplied target identifiers for scoped mutations
- no raw reducer action exposure
- no terminal input injection
- no browser mutation
- no global cross-workspace control
- no authority based on raw environment tile IDs

The API can grow only by adding stable product verbs over reviewed operations.
Future V2 capabilities should each define their own authority model, user
expectation, audit surface, tests, and documentation before landing.

## Rejected Alternatives

### Reuse The Claude Hook Listener

Rejected. The hook listener ingests events and status from agents. Automation
mutations need a separate transport, lock, audit stream, and failure behavior.

### Trust Raw Tile IDs In Environment

Rejected. A raw tile or surface ID in environment would be easy to copy and
would turn identity into authority. V1 uses an opaque live handle instead.

### Expose Internal TileTree Actions

Rejected. Reducer actions are implementation detail. The public API should be a
stable projection over safe product operations.

### Ship Browser Or Input Mutation In V1

Rejected. Those capabilities have different safety and user-expectation
questions. They remain out of scope until separately designed.

## Documentation Contract

- [Automation API Guide](../automation-api.md) is the example-first user path.
- [Automation API Reference](../development/automation-api.md) is the wire and
  maintainer contract.
- This decision record explains why V1 is intentionally narrow.
