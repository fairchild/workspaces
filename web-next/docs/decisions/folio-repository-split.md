# Folio Repository Split

Status: in progress (2026-08-16). Amends `folio-package-boundary.md`, which
deferred a repository split until the package and its release pressure were
understood.

The extracted repository exists at `~/code/folio` (history via filter-repo,
tag `v0.1.0`; GitHub `fairchild/folio` once created, private first, then
public with GitHub Packages publishing). Its `docs/plan.md` is the master
plan; this file is the web-next-side record and the cutover checklist for
step 3 below. Steps 1–2 happen in that repository.

## What is being extracted

`@fairchild/folio` at `web-next/packages/folio` — the host-neutral React
conversation UI: ~3.2k lines of source, ~800 lines of vitest, one released
version (`folio-v0.1.0`, tag `ac2b5bb8`, source unchanged since except
`RELEASING.md`). Two consumers today: Workspaces `web-next` through
`workspace:*`, and MFWiki `web/folio-consumer` through the GitHub Release
tarball, verified against `folio-artifact.json`.

Not being extracted: MFWiki's consumer island (`mfwiki-port`,
`mfwiki-projection`, threads surface, `turn-follow.*` — host-owned by design),
Workspaces' adapter (`src/lib/folio/`), and Workspaces' product design doc
(`docs/design.md`). MFWiki's `raw/assets/folio-package/` is the unrelated
"personal folio" website design; `folio.cloudcompute.com` is the Workspaces
host deployment. Three things share the word; only the package moves.

## Decisions

**Repo.** `github.com/fairchild/folio`, public. Everything in the package is
already public under Apache-2.0 in `fairchild/workspaces`; there is nothing to
redact. Package name stays `@fairchild/folio` so neither consumer changes an
import.

**Distribution.** Unchanged: `private: true`, GitHub Release tarball, both
consumers pin by URL + integrity. Registry publication stays a separate
decision (`RELEASING.md` already says so); a dedicated repo makes npm trusted
publishing straightforward if that decision ever goes the other way. Tags
drop the `folio-` prefix (`v0.1.1`); the asset filename stays
`fairchild-folio-<version>.tgz`; `RELEASE_BASE_URL` and
`CANONICAL_GIT_REMOTE` in the release script point at the new repo. The
`folio-v0.1.0` release on `fairchild/workspaces` stays where it is forever —
MFWiki's lock pins it and nothing needs it moved.

**History.** `git filter-repo` on a fresh clone, keeping the package directory
and the pre-package `src/components/folio` + `src/lib/theme.*` lineage (16
commits back to #769) rather than `git subtree split` (8). Commits that also
touched host code become partial commits — acceptable; the PR numbers in
messages still resolve against `fairchild/workspaces`.

```sh
git clone --no-local https://github.com/fairchild/workspaces.git folio && cd folio
git filter-repo \
  --path web-next/packages/folio \
  --path web-next/src/components/folio \
  --path web-next/src/lib/theme.ts --path web-next/src/lib/theme.test.ts \
  --path-rename web-next/packages/folio/: \
  --path-rename web-next/src/components/folio/:src/ \
  --path-rename web-next/src/lib/:src/ \
  --tag-rename folio-v:v
```

Check `git log --oneline` reaches `ca156686`-era commits and `git tag` shows
`v0.1.0` at the rewritten `ac2b5bb8` before pushing.

**Toolchain.** pnpm 10 + Node 22, verbatim from web-next. The release script
guards on `npm_execpath`, packs with `pnpm pack`, and the accepted-release
record names `pnpmMajor`; porting it as-is is the smallest change. Moving the
package repo to bun is a later, separate change — it re-mints payload hashes at
whatever version it lands, so it costs nothing to defer.

**First standalone version.** `0.1.1`. No API or visual change; the
`repository` field and docs change, which changes the tar payload, which needs
a new accepted record anyway.

## What moves, what stays

| Moves to `fairchild/folio` | Stays in web-next |
| --- | --- |
| `packages/folio/{src,LICENSE,README,CHANGELOG,RELEASING,tsup.*,tsconfig}` → repo root | `src/lib/folio/workspaces-conversation-adapter.*` (host adapter) |
| `scripts/build-folio-css.mjs` → `scripts/build-css.mjs` | `tests/e2e/folio-styles.spec.ts` (needs `/sessions/demo`; browser proof of the sheet stays host-side for now) |
| `scripts/folio-artifact.mjs`, `folio-artifact-core.mjs`, `folio-artifact-core.test.mjs` → `scripts/release*.mjs` | `docs/design.md`, `docs/external-consumer-evidence.md` (historical) |
| `fixtures/external-consumer/*` (accepted record, anonymized host, contract test) | Consumer half of `scripts/folio-boundary.test.mjs` (public-entries-only) |
| Package half of `folio-boundary.test.mjs` (no `@/`, no `../`) | `next.config.ts` `transpilePackages` (keep — it is what makes `pnpm link ../folio` source-first) |
| `clean-core` targets `folio-build`/`folio-artifact` → a five-line `scripts/clean.mjs` | `docs/decisions/folio-package-boundary.md` (amend, do not delete) |

New in the package repo, because nothing hoists from a workspace root any
more: `tsup`, `typescript`, `vitest`, `tailwindcss`, `@tailwindcss/postcss`,
`postcss`, `react`, `react-dom`, `ai`, `@types/react`, `@types/react-dom`,
`@types/node` as devDependencies. The clean-consumer fixture keeps installing
`next` into its temp dir from the registry; it does not become a devDependency.
`folioCompatibility.next` and the Next-based fixture stay: they are the RSC
boundary proof for the `"use client"` banner and server-safe entries.

Add a short `docs/design.md` in the package repo carrying the visual contract
(the "Thesis" register, tokens, the `data-folio-root` scope) and linking to
Workspaces for the product context; the package README already documents the
port and CSS seams.

## Sequence

Ordered so nothing is broken between steps. Each step is one PR (or one
operator flow) with its own verification.

1. **Create the repo with history.** filter-repo as above; move package files
   to root; add devDependencies, scripts (`build`, `test`, `typecheck`,
   `release:candidate`, `release:verify`), CI (`install → typecheck → test →
   build → release:verify`), and the boundary test's package half. Extend
   the release manifest with per-file SHA-256 of the packed contents (see
   step 3 for why). Green
   means `pnpm install && pnpm test && pnpm build` and
   `pnpm release:candidate` succeed locally. `release:verify` cannot pass yet:
   the strict gate needs an accepted release in *this* repo, so CI stays
   red until step 2 — the same window `RELEASING.md` already allows.
2. **Cut `v0.1.1` from the new repo.** Follow `RELEASING.md` steps 1–5 with
   the new remote: bump version + CHANGELOG + `repository`, candidate pack,
   tag `v0.1.1`, GitHub Release with `.tgz` + `SHA256SUMS` + `manifest.json`
   + `files.txt` + `clean-fixture.log` (the same asset set as `folio-v0.1.0`),
   write `accepted-release.json`, rerun strict gate, merge with a merge
   commit. CI green from here.
3. **web-next cutover PR.** Replace `"@fairchild/folio": "workspace:*"` with
   the `v0.1.1` release URL. pnpm 10 records only
   `resolution: {tarball: <url>}` for a URL dependency — no integrity
   (verified against `folio-v0.1.0` on 2026-08-16) — so web-next keeps a
   consumer pin the way MFWiki does: `folio-release.json` (tag, source
   commit, compressed and payload SHA-256, per-file SHA-256 of the packed
   contents) and a `scripts/verify-folio-install.mjs` run after install in
   CI that hashes `node_modules/@fairchild/folio/**` against it. The per-file
   hashes come from the release `manifest.json`; step 1 extends
   `stagePackage` to emit them, since it already holds every dist file in
   memory. Then delete `packages/folio`, `pnpm-workspace.yaml` (folio is its
   only member),
   the `folio:*` scripts, the moved scripts and fixture, the vitest
   `packages/**` include, the eslint `packages/folio/dist` ignore, the CI
   "Package Folio" step + cache-key paths + `folio-package` artifact upload,
   and the `clean-core` targets. Update `CONTRIBUTING.md` (§ package location,
   § releasing) and amend `folio-package-boundary.md` with a pointer here.
   Green means `pnpm install --frozen-lockfile && pnpm lint && pnpm typecheck
   && pnpm test && pnpm build` and the e2e lane including
   `folio-styles.spec.ts`. Local co-development afterwards is
   `pnpm link ../folio` (source-first via `transpilePackages`), which is what
   the split costs: a host change that needs a package change now needs a
   package PR, a release, and a bump.
4. **MFWiki bump PR — only when the next bump is wanted.** Three files
   (`web/folio-consumer/package.json` URL, regenerated `package-lock.json`,
   `folio-artifact.json` with the new `releaseUrl`/`artifactUrl`/checksums/
   `sourceCommit`) plus the two "Workspaces GitHub Release" sentences in
   `docs/folio-consumer.md`. `verify_folio_consumer.mjs` and `build.mjs`
   hardcode no URL. `npm run folio:prepare && npm run folio:verify-clean` is
   the check. Nothing forces this; `0.1.0` on the old URL remains valid.

## Costs named

- Every cross-cutting UI change becomes package PR → release → bump PR in
  each host. That is the intended pressure of the split; it was free while
  web-next was source-first.
- The strict release gate now runs in a repo whose CI has no host app, so the
  clean-consumer fixture (a `next build` in a temp dir, ~1–2 min) is the only
  end-to-end proof there. Browser proof of the stylesheet stays in web-next
  and MFWiki e2e lanes until a package-repo demo page earns its keep.
- Two repos to keep `RELEASING.md` truthful in: the package repo owns the
  release flow; web-next's `CONTRIBUTING.md` points at it.

## Non-goals

- Publishing to npm.
- Moving MFWiki's threads surface, turn-follow animator, or Workspaces'
  adapter into the package.
- Changing the port, entries, or CSS contract as part of the move.

## Follow-up: Folio 0.2.0 moves turn follow into the package (2026-08-18)

`@fairchild/folio` 0.2.0 makes `SessionView` scroll the page itself — the ask
docks under the sticky chrome on send, the answer fills the space below it while
the page holds still, and following begins when the answer outgrows the page. It
is on by default (`autoScroll`, default `true`).

Taking 0.2.0 therefore means **deleting
`src/app/(app)/sessions/[id]/use-turn-follow.ts` (200 lines) and its call site**
in the same change. Two mechanisms driving one scroller fight: the package holds
the page height still for a whole turn using a runway after the last turn, and a
second animator chasing the tail would undo that.

Two things to set while doing it:

- `--folio-chrome-top` on an ancestor of the surface, if this host stacks
  anything sticky above the masthead. The masthead now sticks below it, and the
  docked ask parks below the masthead.
- `autoScroll={false}` *only* if the surface lives in its own scroll container
  rather than scrolling the page. `data-turn-follow-scope` and
  `data-compose-boundary` are unchanged and still selectable.

`scrollPreviousTurnPeek` (default `120`) is how much of the previous turn stays
visible above the docked ask, and `defaultScrollPosition` (`"last-anchor"`) is
where the surface looks on first render. The note in Folio's
`docs/design.md` § "Carried forward" records why the boundary moved.
