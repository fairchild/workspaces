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

- Package source uses relative imports internally and never imports the
  Workspaces `@/` alias or application modules.
- Workspaces imports Folio through `@fairchild/folio`, never package-private
  source paths.
- React, React DOM, and AI SDK identity are peer contracts; Folio-owned Radix
  primitives are package dependencies.
- The package is source-first and `private` in this slice. W7's artifact issue
  defines compilation, semver, checksums, and the public-registry decision.
- Styles remain supplied by the Workspaces host only until #1052 moves tokens,
  assets, and scoped styles behind package-owned exports.

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
