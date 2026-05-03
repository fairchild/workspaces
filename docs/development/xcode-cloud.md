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
