# Folio 0.1 External Consumer Evidence

Status: accepted compatibility proof for W7 (2026-07-12)

## Artifact under test

- Release: `folio-v0.1.0`
- Package: `@fairchild/folio@0.1.0`
- Source commit: `ac2b5bb8bd74dbba34401d50eeb4304eb87c55e0`
- Compressed SHA-256: `f5da5f28ee25e952681fca92b183700958670483215fde6436fed67c5238bde4`
- Tar payload SHA-256: `68b1383f7ce3ceb4db682b271a9ead9f5032fc50c49404cc334a582418c175a9`

The canonical release asset carries the compressed checksum above. Local
rebuilds may produce a different outer gzip stream, so the public package gate
also decompresses the tarball and requires its payload to match the accepted
release payload exactly.

The consumer is private. Its name, repository, routes, hostnames, screenshots,
and operational configuration are intentionally omitted. This document records
only the portable contract evidence.

## Compatibility matrix

| Contract | Private consumer result | Public regression encoding |
|---|---|---|
| Install without source copy or workspace link | Passed from the released tarball | `pnpm folio:package` standalone install and build |
| Consumer-owned conversation adapter | Passed through the public port | `fixtures/external-consumer/host-adapter.mjs` |
| Create and durable reload | Passed across server restart and browser reload | External fixture create, serialize, restore test |
| Send and ordered stream | Passed through the consumer's real deterministic runner | External fixture public-event replay test |
| Disconnect and cursor resume | Passed without duplicate message content | External fixture disconnect/resume test |
| Stop and terminal failure | Passed with host-calculated capabilities | External fixture stop/failure test |
| Artifact and review projection | Passed with consumer-owned evidence | External fixture artifact/review test |
| Workspace and publication authority | Passed without package-side credentials or Git access | External fixture authority-command test |
| Responsive and accessible session surface | Passed at desktop and 390 by 844 phone viewports | Folio browser suite plus standalone consumer build |
| Workspaces strict consumer | Passed with the same `0.1.0` API | Workspaces adapter and package-boundary tests |

## Outcome

No consumer-specific conditional import, source fork, or private package change
was required. The reusable fixes landed in the public package and adapter
contracts before the consumer cutover. Remaining consumer policy stays in its
host: authentication, persistence, agent execution, workspaces, review, and
publication.
