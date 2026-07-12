# Folio Package Boundary

Status: accepted for W7 (2026-07-11)

## Decision

Folio evolves as the `@fairchild/folio` workspace package inside `web-next/`.
Workspaces is its first strict consumer and imports only the package's named
entry point. We are not copying the interface into consumers, creating a fork,
or moving it to a third repository before the package and its release pressure
are understood.

This keeps design and implementation in the flagship open-source project while
making the same code installable by another host. A future repository split is
a release/ownership decision, not a prerequisite for reuse.

## Ownership

Folio owns:

- the conversation document, turn framing, compose, status, approvals, tool
  ledger, diffs, receipts, and theme presentation;
- the typed data required to render those surfaces; and
- stable public exports from `packages/folio/src/index.ts`.

The host owns:

- identity, authentication, authorization, and tenancy;
- conversation persistence, streaming transport, reconnect/resume, and agent
  execution;
- repositories, workspaces, terminals, Git, and publication authority; and
- projection from host events into Folio view data and action callbacks.

Folio may request a host action through an explicit callback or port. It never
acquires host authority merely because it renders the control.

## Boundary rules

- Package source uses an independent TypeScript configuration, relative imports
  internally, and never imports the Workspaces `@/` alias or application modules.
- Workspaces imports Folio through its declared `@fairchild/folio` exports,
  never package-private source paths. Pure server-safe helpers use the explicit
  `@fairchild/folio/format` entry so component modules cannot enter server graphs;
  app shells use the server-safe `@fairchild/folio/theme`; interactive surfaces
  use `@fairchild/folio/theme-toggle` so the compiled artifact preserves the
  React Server Component boundary without loading the conversation graph.
- Conversation authority uses the server-safe `@fairchild/folio/conversation`
  entry. The testing entry imports that runtime rather than bundling a second
  copy, so exported error identities remain stable across entries.
- React, React DOM, and AI SDK identity are peer contracts; Folio-owned Radix
  primitives are package dependencies.
- The workspace is source-first; `pnpm folio:package` produces the install
  surface as a compiled `private` tarball with deterministic checksum/file/size
  gates and a clean non-workspace consumer build. Public-registry publication
  remains a separate owner decision after the external-consumer proof.
- Folio supplies its scoped stylesheet and tokens through the declared
  `@fairchild/folio/styles.css` export; hosts retain the narrow documented token
  override seam.

## Workspaces strict-consumer proof

Workspaces crosses the conversation boundary in one application-owned module:
`src/lib/folio/workspaces-conversation-adapter.ts`.

- The authenticated session page and API routes keep identity and authorization;
  Folio receives only the already-authorized author's display metadata.
- `useChat` and the append-only session event log keep streaming, persistence,
  reload, and resume authority. The live view projects that current state into a
  `FolioConversationSnapshot` instead of teaching Folio about AI SDK transport.
- The adapter implements `FolioConversationPort` through the public package
  export. Its capability checks translate sends, queue cancellation, mutable
  session settings, approvals, turn stop, sandbox stop, and PR publication into
  explicit Workspaces callbacks.
- `FolioConversationController.fromSnapshot()` supports hosts that already own
  a live projection, avoiding a second state owner or a redundant asynchronous
  snapshot read. The controller still derives the package's action membrane.

Deleting the Workspaces adapter removes this host integration without removing
or partially disabling any Folio package module. The package compiles and tests
under its independent TypeScript configuration, and the boundary test scans
both production and test imports for package-private paths.

## Sequence

1. #1050 establishes the package and makes Workspaces a strict consumer.
2. #1051 replaces action callbacks/data coupling with host-neutral ports.
3. #1052 makes Folio styles and assets independently installable.
4. #1053 proves Workspaces has no privileged internal path.
5. #1054 creates the versioned install artifact and clean fixture.
6. #1055 proves a real external consumer without publishing private details.

## Non-goals

- Publishing to a registry in this slice.
- Moving Workspaces runtime, database, auth, or API routes into Folio.
- Preserving old package-private import paths for compatibility.
- Designing consumer-specific conditionals into the package.
