# Anonymized External Consumer Fixture

This fixture records the reusable part of Folio's first private-consumer proof.
It contains no private repository name, URL, data, credentials, or operational
details. The host is intentionally generic and imports only the installed
`@fairchild/folio/conversation` entry.

`pnpm folio:package` copies `host-adapter.mjs` and `contract.test.mjs` into a
temporary standalone Next application beside the packed tarball. It installs
that tarball without a workspace link, runs these contract tests, and then runs
a production build using the package's component, stylesheet, theme, format,
and testing exports.

For the accepted `0.1.0` release, `accepted-release.json` also pins the source,
release-asset checksum, and uncompressed tar-payload checksum. The package gate
requires a locally rebuilt `0.1.0` payload to match that accepted payload
exactly; the outer gzip stream may differ between packaging environments.

The fixture covers:

- host-owned conversation creation and durable reload;
- ordered send/stream projection;
- conversation-scoped cursors, disconnect at a durable cursor, duplicate-free
  resume, and restore-time cursor sequence/order validation (event content
  remains host-owned and trusted);
- cancellation and fail-closed errors;
- transitional stop/active-turn invariants plus queued-message, approval,
  review, workspace, and publication authority; and
- foreign-cursor and abort handling.

The real private-consumer browser evidence is summarized in
[`../../docs/external-consumer-evidence.md`](../../docs/external-consumer-evidence.md).
