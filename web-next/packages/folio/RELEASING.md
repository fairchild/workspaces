# Releasing Folio

Folio follows semantic versioning. Before 1.0, breaking public API or visual
contract changes increment the minor version; backward-compatible fixes increment
the patch version. Every version updates `CHANGELOG.md` and the package version
in the same pull request.

Run the canonical release-candidate command from `web-next/`:

```bash
pnpm folio:package
```

It independently clean-builds and stages the compiled ESM, declarations,
JavaScript/CSS source maps, and standalone stylesheet twice; packs both staging
trees and requires identical SHA-256 checksums; enforces the file and size
allowlists; then copies the tarball and the anonymized external-host fixture into
a temporary project. For an accepted package version, the gate fails closed
unless the checked-in release receipt matches the remote Git tag, downloaded
release-asset checksum, and uncompressed tar payload. It installs that canonical
release asset with no workspace link, runs the public port contract, and runs a
production Next build. This provenance step requires network access to the
public Git remote and GitHub release. Review artifacts are written under
`artifacts/folio/`.

The artifact remains `private: true`. The first external-consumer proof (#1055)
does not itself authorize registry publication. A future publication gate must
decide package scope/ownership, provenance signing, npm trusted publishing, and
support expectations before removing `private` or adding a publish command.

Compatibility metadata is advisory and lives in `folioCompatibility`. React,
React DOM, and AI SDK are peer contracts; bundled code must not create duplicate
runtime identities. Next.js 15.5 is the clean-fixture and Workspaces reference
host for 0.1.x.
