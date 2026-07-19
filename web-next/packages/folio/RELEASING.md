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
a temporary project. Every package version requires an accepted release record;
the default gate fails closed unless that record matches the canonical remote
Git tag, downloaded release-asset checksum, and uncompressed tar payload. It
installs that canonical release asset with no workspace link, runs the public
port contract, and runs a production Next build. The record also names the
release packing toolchain so a payload mismatch can distinguish source changes
from toolchain drift. This strict provenance step requires network access to the
public Git remote and GitHub release. Review artifacts are written under
`artifacts/folio/`.

## Advancing the accepted version

The strict command intentionally cannot mint its own trust record. Advancing a
version is a serialized operator flow:

1. On a release branch, update Folio source, `CHANGELOG.md`, and the package
   version, then commit with a clean worktree.
2. Run `pnpm folio:package:candidate`. This explicit local-only command refuses
   CI and an already accepted version. It writes the candidate source commit,
   compressed checksum, and tar-payload checksum to `artifacts/folio/manifest.json`
   and proves the local candidate in the clean consumer.
3. Tag that exact candidate commit as `folio-vX.Y.Z`, push the tag, and create a
   GitHub prerelease carrying the generated `.tgz`. Do not rebuild the asset
   after recording its hashes.
4. Update `fixtures/external-consumer/accepted-release.json` with the tag,
   candidate commit, both checksums, and Node/pnpm major versions. Commit the
   receipt and rerun the strict `pnpm folio:package`; it must now verify the
   canonical tag and downloaded prerelease asset.
5. Merge the release PR with a merge commit, not squash or rebase, so the tagged
   candidate remains an ancestor of `main`. Promote the prerelease only after
   the merge and post-merge strict gate pass.

Intermediate branch CI may be red between steps 1 and 4; the branch is not
mergeable until the strict gate passes. Candidate mode is never a CI bypass.

The artifact remains `private: true`. The first external-consumer proof (#1055)
does not itself authorize registry publication. A future publication gate must
decide package scope/ownership, provenance signing, npm trusted publishing, and
support expectations before removing `private` or adding a publish command.

Compatibility metadata is advisory and lives in `folioCompatibility`. React,
React DOM, and AI SDK are peer contracts; bundled code must not create duplicate
runtime identities. Next.js 15.5 is the clean-fixture and Workspaces reference
host for 0.1.x.
