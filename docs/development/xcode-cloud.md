# Xcode Cloud Harness

This repo stays SwiftPM-first. Xcode Cloud uses a lightweight committed Xcode project only as an optional adapter; the real WorkSpaces app still builds through Swift Package Manager.

## Naming Contract

- Product/display name: `WorkSpaces`
- Existing SwiftPM package and executable target: `WorkspaceManager`
- CLI product: `workspaces`
- Bundle identifier for the real app: `com.cloudcompute.workspaces`
- Xcode Cloud harness product: `WorkSpacesXcodeCloudHarness.framework`
- Xcode Cloud harness bundle identifier: `com.cloudcompute.workspaces.xcode-cloud-harness`

Do not rename the SwiftPM targets as part of Xcode Cloud setup. Do not use the real app bundle identifier for the harness. The harness is a framework so Xcode Cloud has a stable product to build without creating a fake `WorkSpaces.app`.

## Files

- `WorkSpacesCloudCI.xcodeproj` — stable Xcode project for Xcode Cloud onboarding.
- `XcodeCloudHarness/` — inert framework source used only by the harness project.
- `ci_scripts/ci_post_clone.sh` — installs/checks required tools and builds `Frameworks/GhosttyKit.xcframework`.
- `ci_scripts/ci_pre_xcodebuild.sh` — runs the canonical SwiftPM checks:
  - `swift-format lint --strict --recursive Sources/ Tests/`
  - `swift build`
  - `swift build -c release`
  - `swift test`

## Tooling Dependencies

`ci_post_clone.sh` installs the host tools that are not guaranteed by the Xcode
Cloud image:
- `mise` for the pinned Zig toolchain
- Homebrew `zig@0.15` for GhosttyKit's patched Darwin linker path on newer macOS SDKs
- `swift-format` for the SwiftPM validation gate
- `gettext` for Ghostty's `msgfmt` translation compilation step

Homebrew's `gettext` may be keg-only, so the script prepends
`$(brew --prefix gettext)/bin` before building GhosttyKit.

## Manual Xcode Cloud Setup

1. Open `WorkSpacesCloudCI.xcodeproj` in Xcode.
2. Confirm the `WorkSpacesCloudCI` scheme is shared.
3. In Xcode Settings > Accounts, sign in with the Apple Developer account.
4. Open the Report navigator, select the Cloud tab, and click Get Started.
5. Select the `WorkSpacesXcodeCloudHarness.framework` product.
6. Use the correct Apple Developer team if Xcode asks.
7. Do not create or select an App Store Connect app record for this harness.
8. Grant Xcode Cloud access to GitHub and install the Xcode Cloud GitHub app only on `fairchild/workspaces`.
9. Create the first workflow:
   - Name: `WorkSpaces PR Verification`
   - Start conditions: pull requests targeting `main`, branch changes on `main`, manual
   - Action: build `WorkSpacesCloudCI` for macOS
   - Distribution: none
10. Start a manual build and verify that the GitHub check reports back.

Keep release signing/notarization on the existing GitHub Actions signing-host lane until the Xcode Cloud validation lane has proven stable.

## Debugging Builds (read this before guessing)

First green builds: 594/595 on `4058f0fc` (2026-07-07), after five distinct
failure generations (license → xtrace-in-trap noise #795 → `/usr/local` brew
prefix #854 → silent x86_64 zig slice, diagnosed via probe #869 →
bootstrap-needs-sudo #907, refuted by build 574's log → cross-compile fix #925
+ ASC log access #928).

### Getting real logs

GitHub check-runs only ever carry Xcode Cloud's one-line summary
(`Running ci_post_clone.sh script failed (exited with code 1)`). Full script
stdout/stderr lives in App Store Connect LOG_BUNDLE artifacts, and the ASC API
credentials exist only as repo secrets — so the fetch runs inside Actions:

```sh
gh workflow run xcode-cloud-logs.yml -f sha=<full-commit-sha>
```

The job log prints structured `ciIssues` plus filtered log excerpts (usually
enough on its own); full bundles upload as a 5-day artifact. Implementation:
`scripts/fetch-xcode-cloud-logs.py`. The key must be a **Team** API key with
App Manager role — an individual key 401s.

### Watching builds

Pin to a commit SHA, never to `main`'s moving head:

```sh
gh api repos/fairchild/workspaces/commits/<SHA>/check-runs \
  --jq '.check_runs[] | select(.app.slug|test("xcode";"i")) | [.name, .status, .conclusion] | @tsv'
```

Cancellation on supersede is normal: when a newer commit lands on `main`
mid-build, Xcode Cloud cancels the in-flight build. A `cancelled` conclusion on
an older SHA is not a failure signal; check the newest head instead.

Two ASC-side workflows ("Default" and "Untitled Workflow") currently both build
every push, so each commit produces two identical build runs. Deleting one
requires the App Store Connect web UI.

### VM image quirks (all confirmed via real build logs)

- Host is arm64, but Homebrew runs from `/usr/local` and pours **x86_64**
  bottles — including zig. Ghostty resolves `-Dxcframework-target=native` from
  the zig **compiler binary's** baked-in arch, so an unpatched build silently
  produces an x86_64-only GhosttyKit that surfaces three stages later as
  `no such module 'GhosttyKit'`. `build-ghosttykit.sh` detects the mismatch,
  patches the pinned checkout to cross-compile the host-arch slice, and
  hard-asserts the result (lipo + Info.plist). Details and ruled-out
  alternatives: `docs/development/libghostty-integration.md` § "Zig 0.15.2
  with newer macOS SDKs".
- **The CI user has no sudo** (build 574): anything needing `/opt/homebrew`
  creation, installer scripts, or privileged paths fails. Do not reintroduce a
  bootstrap.
- VMs are fresh per build — no zig cache reuse; the GhosttyKit build costs a
  few minutes every run.

## Local Harness Verification

The Xcode project can be checked without running the expensive SwiftPM validation scripts:

```bash
xcodebuild -list -project WorkSpacesCloudCI.xcodeproj
xcodebuild \
  -project WorkSpacesCloudCI.xcodeproj \
  -scheme WorkSpacesCloudCI \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/workspaces-xcodecloud-harness-dd \
  CODE_SIGNING_ALLOWED=NO \
  build
```
