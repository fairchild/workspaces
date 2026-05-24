---
status: in_progress
category: plan
pr: null
branch: codex/privacy-first-sparkle-updates
score: null
retro_summary: null
completed: null
---

> **GitHub Issue**: https://github.com/fairchild/workspaces/issues/2

# Privacy-First Sparkle Update Integration

## Problem Statement

WorkSpaces is distributed directly as a notarized DMG, so users need a safer path than manually polling GitHub Releases. The updater must still fit highly restricted corporate environments: no update checks, telemetry, profiling, background downloads, or silent installs may happen by default.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Framework | Sparkle 2.x | Native macOS updater with EdDSA verification and SwiftPM support |
| Default network behavior | Off | No update request is made unless the user manually checks or explicitly enables automatic checks |
| Telemetry/system profiling | Off, with delegate guardrails | Sparkle profiling remains disabled and the delegate returns no profile keys or feed parameters |
| Automatic downloads/installs | Disabled | Corporate users should always confirm installs visibly |
| Appcast hosting | GitHub Release asset | `latest/download/appcast.xml` avoids GitHub Pages cache lag |
| Signing | Sparkle EdDSA | Private key stored outside the repo as `SPARKLE_PRIVATE_KEY`; public key committed in `Info.plist` |

## Implementation Shape

The app owns a single `SoftwareUpdateController` that wraps `SPUStandardUpdaterController`. The controller is shared by:

- App menu command: `Check for Updates...`
- Settings > Updates toggle: `Automatically check for updates`
- A defensive `SoftwareUpdateDelegate`

The first manual check shows a disclosure before invoking Sparkle. The disclosure states that WorkSpaces contacts GitHub Releases, sends no telemetry/system profile/custom parameters, and that GitHub may receive normal HTTP request metadata such as IP address.

Info.plist defaults:

- `SUFeedURL = https://github.com/fairchild/workspaces/releases/latest/download/appcast.xml`
- `SUEnableAutomaticChecks = false`
- `SUAutomaticallyUpdate = false`
- `SUAllowsAutomaticUpdates = false`
- `SUEnableSystemProfiling = false`
- `SUScheduledCheckInterval = 604800`
- `SUPublicEDKey = <production public key>`

## Release Integration

Release builds bundle `Sparkle.framework` into `Contents/Frameworks` and sign it with the rest of the app bundle. The release workflow requires `SPARKLE_PRIVATE_KEY`, generates `build/appcast.xml` after the DMG is created, and uploads the appcast beside the DMG assets.

Before appcast generation, `CHANGELOG.md` must contain a version-matched `## [<CFBundleShortVersionString>] - <date>` section. The appcast generator embeds that section in the item `<description>` and fails if the section is missing or empty, so release notes are part of the signed release artifact contract.

The generated appcast uses:

- `CFBundleVersion` for `sparkle:version`
- `CFBundleShortVersionString` for `sparkle:shortVersionString`
- `LSMinimumSystemVersion` for `sparkle:minimumSystemVersion`
- the matching `CHANGELOG.md` section for the item `<description>`
- the tagged `CHANGELOG.md` URL for `sparkle:fullReleaseNotesLink`
- Sparkle `sign_update` output for `sparkle:edSignature` and `length`
- the tagged GitHub Release DMG URL as the enclosure URL

## Verification

- `plutil -lint Sources/WorkspaceManager/Resources/Info.plist`
- `swift build`
- `swift test`
- `./scripts/build-release.sh --no-sign`
- `bash -n scripts/build-release.sh scripts/generate-sparkle-appcast.sh scripts/notarize.sh`
- Runtime screenshots of Settings > Updates and the first manual-check disclosure uploaded with `./scripts/evidence.sh`

## Rollback Plan

Remove the Sparkle dependency, updater controller, Settings section, Sparkle Info.plist keys, appcast generation step, and Sparkle framework bundling. Users can continue downloading DMGs manually from GitHub Releases.
