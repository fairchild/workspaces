# Ghostty pins: desktop, web, mobile

Status as of 2026-11-08: all three surfaces name Ghostty's 1.0 cut (`vt-1.0.0`,
commit `0fa3d577a5614150ff8e2c152de5fb9d5c6d2dec`). The mobile and web pins are
in the tree; the desktop pin moves in #1843, and this page describes the desktop
as it is once that lands. Check it still holds: `scripts/build-ghosttykit.sh
--print-pin` prints `0fa3d577…`, `GHOSTTY_VT_RELEASE.version` in
`web-next/src/components/terminal/vt/ghostty-vt.ts` reads `1.0.0`, and the
`GhosttyVt` target in `ios/Packages/TerminalScreen/Package.swift` points at
`libghostty-vt/1.0.0/`.

Ghostty ships two C libraries from one source tree. The desktop app links the
full embedded terminal (GhosttyKit, `ghostty.h`), which has no stable ABI and
changes with every commit. The mobile package and the web app link the headless
VT library (libghostty-vt, `ghostty/vt.h`), whose ABI is stable from 1.0. The
repo therefore holds three pins, and they can differ on purpose: the desktop pin
follows whatever GhosttyKit fixes the app needs, while mobile and web follow vt
releases. Today they happen to name the same cut.

| Surface | Pin | Lives in | Artifact | What fails on a wrong pin |
|---|---|---|---|---|
| Desktop | `GHOSTTY_COMMIT` | `scripts/build-ghosttykit.sh` | `Frameworks/GhosttyKit.xcframework`, built from source | `scripts/verify-ghostty-pin.sh` (stamp mismatch), then the `build-and-test` job in `.github/workflows/ci.yml` |
| Web | `GHOSTTY_VT_RELEASE` | `web-next/src/components/terminal/vt/ghostty-vt.ts` | `ghostty-vt-<version>-small.wasm`, served from `web-next/public/ghostty-vt/` (gitignored) | `web-next/scripts/fetch-ghostty-vt.mjs` (digest), then the unit tests in `.github/workflows/web-next-ci.yml` |
| Mobile | `GhosttyVt` binary target | `ios/Packages/TerminalScreen/Package.swift` | Ghostty's release xcframework zip | SwiftPM's checksum check, then `swift test --package-path ios/Packages/TerminalScreen` in `ci.yml` |

No gate here is new: each row's last column already exists and already fails when
a pinned artifact or checksum is wrong.

## Desktop: GhosttyKit

**Where it lives.** `GHOSTTY_COMMIT` in `scripts/build-ghosttykit.sh` is the pin.
The same script holds `ZIG_VERSION` (`0.17.0` at this pin), which has to equal
`minimum_zig_version` in Ghostty's `build.zig.zon` at the pinned commit. Zig is
pinned in three more places that must agree with it: `zig` in `.mise.toml`, the
`[[tools.zig]]` entry in `mise.lock`, and `ZIG_VERSION` in
`scripts/verify-mise-security.sh`. Zig 0.17 dropped `--global-cache-dir`, so the
build passes `ZIG_GLOBAL_CACHE_DIR` instead. `Package.swift` consumes the output
as a path-based `.binaryTarget` on `Frameworks/GhosttyKit.xcframework`.

**How to move it.**

1. Pick the Ghostty commit. For a vt release, use the commit the `vt-*` tag points
   at; for a GhosttyKit fix, use the trunk commit that carries it.
2. At that commit, read `minimum_zig_version` in `build.zig.zon` and the archive
   name Ghostty emits inside the xcframework. Edit `GHOSTTY_COMMIT`, `ZIG_VERSION`
   and (if it was renamed) `GHOSTTY_ARCHIVE_NAME` in `scripts/build-ghosttykit.sh`,
   then the three Zig pins above.
3. Build with `./scripts/build-ghosttykit.sh`. If the Zig cache is suspect, add
   `--purge-cache`.
4. Run `swift package clean`, then `swift test` and `mise run lint`. Objects
   compiled against the previous framework survive an incremental rebuild.
5. Fix whatever the header change broke, only in the terminal integration files
   listed in `docs/development/libghostty-integration.md`.
6. Check surface teardown at both the old and the new pin, as described under
   "Teardown hang guard" below.

The step-by-step version, the Zig toolchain resolution order, and the smoke
checklist are in [libghostty-integration.md](libghostty-integration.md); this page
points there rather than repeating them.

**The worktree placeholder hazard.** `Frameworks/` is gitignored and expensive to
build, so a fresh worktree has none, and the quick fix is to copy one from another
checkout. A copy at the same pin is fine. A copy at a superseded pin links stale
objects and gives wrong answers rather than a build error (#1576).
`build-ghosttykit.sh` therefore writes the pinned commit into the xcframework as
`.ghostty-pin`, and `scripts/verify-ghostty-pin.sh` compares that stamp with the
script's `--print-pin` output. It runs in `scripts/launch-dev.sh`,
`scripts/build-release.sh` and `ci_scripts/ci_pre_xcodebuild.sh`. A framework with
no stamp only warns, unless its archive name proves it predates the pin. Copy from
a checkout whose script prints the same `GHOSTTY_COMMIT`, then run
`./scripts/verify-ghostty-pin.sh` before building.

**The link-time collision.** GhosttyKit and libghostty-vt both carry a Zig runtime
and the same vendored C libraries, so linking both static archives into one binary
fails with duplicate symbols (35 runtime symbols, and 834 more shared from wuffs,
simdutf and highway, in the test link at `vt-1.0.0` recorded in
[libghostty-vt.md](libghostty-vt.md#why-vt-stays-out-of-the-desktop-app)). The desktop
app does not link vt, and `ios/Packages/TerminalScreen` stays out of the root
`Package.swift` for the same reason. A change that adds libghostty-vt to the
desktop target, or GhosttyKit to the mobile package, hits this link error.

**Teardown hang guard.** Freeing a surface can deadlock when the app mailbox is
full: `ghostty_surface_free` on the main thread joins `io`, which joins an
`io-reader` blocked on a push into the 64-slot app mailbox that only the main
thread drains (#1842). It reproduces at both `492300ca` and `0fa3d57`, and #1856
tracks the app-side fix. `scripts/watch-swift-test.sh` runs a `swift test` command
and, when its log stops changing for `--stall` seconds, samples the test helper
into `<out>/hang.sample.txt`, kills the process tree and exits 124. Use it for any
long suite on a pin move. `GhosttySurfaceMailboxDeadlockTests`
(`Tests/WorkspaceManagerAppTests/GhosttySurfaceMailboxDeadlockTests.swift`) is the
deterministic reproducer, opt-in through an environment variable:

```bash
scripts/watch-swift-test.sh --stall 45 --out /tmp/deadlock -- \
  env WORKSPACES_MAILBOX_DEADLOCK_SURFACES=32 \
  swift test --skip-build --filter GhosttySurfaceMailboxDeadlock
```

The deadlock shows up on the full app suite under CPU load, so build each pin with
`GHOSTTY_KEEP_SYMBOLS=1` (a hang then names its frames) and compare hang counts
across several loaded runs, not one.

## Web: libghostty-vt wasm

**Where it lives.** `GHOSTTY_VT_RELEASE` in
`web-next/src/components/terminal/vt/ghostty-vt.ts` holds `version`, `file`,
`sha256`, `minisignKey`, `origin` and `servedFrom`. The artifact is Ghostty's
`ghostty-vt-<version>-small.wasm` from `origin`
(`https://release.files.ghostty.org/libghostty-vt/<version>/`), about 0.8 MB.

**Why same-origin.** The release host sends no CORS headers, so the page cannot
fetch the file from it. `web-next/scripts/fetch-ghostty-vt.mjs` downloads it into
`web-next/public/<servedFrom>` (`public/ghostty-vt/`, gitignored) and refuses any
file whose SHA-256 differs from the pin. `pnpm build`, `pnpm start` and the e2e
and evidence harnesses run it first, so a deploy never ships without the verified
file. In the browser, `loadGhosttyVt()` fetches `${servedFrom}${file}` and checks
the digest a second time before instantiating.

**How to verify and move it.**

1. Download `ghostty-vt-<version>-small.wasm` and its `.minisig` from the release
   directory, and run `minisign -Vm <file> -P <minisignKey>`. The signature is
   the one place trust enters; the digest pin is only as good as this check, and
   nothing in the repo re-runs it.
2. Record `shasum -a 256 <file>`.
3. Edit `version`, `file`, `sha256` and `origin` in `GHOSTTY_VT_RELEASE`.
   `servedFrom` only changes if the serving path does.
4. In `web-next/`, run `pnpm ghostty-vt:fetch && pnpm test`. In CI,
   `.github/workflows/web-next-ci.yml` runs the same fetch before the unit tests,
   and with `CI=true` a missing wasm fails `vt.test.ts` and
   `fixture-corpus.test.ts` instead of skipping them.
5. If the release changes a screen on purpose, regenerate the goldens (next
   section) and run the Swift suite too.

**The shared fixture corpus.** `fixtures/terminal-vt/` holds a `.vt` byte stream
and a `<name>.golden.json` of the final screen per fixture, with `corpus.json`
giving grid size and chunking. `fixture-corpus.test.ts` in
`web-next/src/components/terminal/vt/` and `FixtureCorpusTests` in
`ios/Packages/TerminalScreen` replay every fixture and compare row by row, so a
pin that changes a screen fails both bindings, and a binding that drifts from the
other fails on the fixture that shows it. It already found both bindings dropping
a painted spacer head (#1863). The procedure to add or regenerate a fixture is in
[libghostty-vt.md](libghostty-vt.md#the-shared-fixture-corpus).

## Mobile: TerminalScreen

**Where it lives.** The `GhosttyVt` `.binaryTarget` in
`ios/Packages/TerminalScreen/Package.swift` carries the release `url`
(`https://release.files.ghostty.org/libghostty-vt/<version>/ghostty-vt-<version>.xcframework.zip`)
and its `checksum`. `ios/project.yml` takes the package by path and holds no
second pin. `swift test --package-path ios/Packages/TerminalScreen` runs on a Mac
with no simulator and is what `ci.yml` runs in `build-and-test`.

**What uses it.** Only a debug-only terminal preview
(`ios/WorkSpacesMobile/TerminalPreviewView.swift`, behind `#if DEBUG`) replays a
recorded stream through `VirtualTerminal`. There is no live terminal on the phone
yet: no host exposes a byte stream for it. So this pin has no production surface
behind it today.

**How to move it.**

1. Take the release zip from `libghostty-vt/<version>/` and compute its checksum
   with `swift package compute-checksum <zip>`.
2. Edit `url` and `checksum` on the `GhosttyVt` target. SwiftPM refuses a
   download whose checksum differs, so a wrong value fails at resolve time.
3. Run `swift test --package-path ios/Packages/TerminalScreen`. It replays the
   fixture corpus, and its `Links libghostty-vt 1.x` test reads the library
   version at runtime.
4. In `ios/`, run `xcodegen`, build, and open the terminal preview. The release
   xcframework's simulator slice is arm64 only, which is why `ios/project.yml`
   excludes x86_64 for the simulator SDK.

The tree records no minisign check for the zip. Ghostty publishes a `.minisig`
beside it (the host answered 200 for the 1.0.0 one when this page was written);
whether it verifies against the key in `GHOSTTY_VT_RELEASE` is untested here.

## Keeping this page true

A pin move edits the pin, then the status line at the top of this page and the
status lines in [libghostty-vt.md](libghostty-vt.md) and
[libghostty-integration.md](libghostty-integration.md). A gate that now fails
differently, or a new place that names a pin, belongs in the table at the top.
