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
allowlists; then copies the tarball into a temporary project, installs with no
workspace link, and runs a production Next build. Review artifacts are written
under `artifacts/folio/`.

The artifact remains `private: true`. Public-registry publication is a separate
owner decision after the first external-consumer proof (#1055). That gate must
decide package scope/ownership, provenance signing, npm trusted publishing, and
support expectations before removing `private` or adding a publish command.

Compatibility metadata is advisory and lives in `folioCompatibility`. React,
React DOM, and AI SDK are peer contracts; bundled code must not create duplicate
runtime identities. Next.js 15.5 is the clean-fixture and Workspaces reference
host for 0.1.x.
