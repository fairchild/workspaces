---
status: pending
category: plan
pr: null
branch: null
score: null
retro_summary: null
completed: null
---

# Sparkle Auto-Update Integration

## Problem Statement

WorkspaceManager is distributed directly (notarized DMG) rather than through the Mac App Store. Without built-in auto-update capability, users must manually check for and download new versions, leading to:

- Fragmented user base on different versions
- Critical bug fixes not reaching users promptly
- Poor user experience for a developer tool

Sparkle is the de-facto standard for macOS app auto-updates, used by VS Code, Sublime Text, and most non-App Store apps.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Framework | Sparkle 2.x | Industry standard, Swift support, SPM compatible |
| Signing | EdDSA (ed25519) | Sparkle 2.x default, more secure than DSA |
| Appcast hosting | GitHub Pages | Free, reliable, version-controlled |
| Update channel | Single (stable) | Start simple, add beta channel later if needed |
| Check frequency | Weekly + manual | Balance between freshness and annoyance |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    WorkspaceManager.app                     │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ SPUStandardUpdaterController (Sparkle)               │   │
│  │ - Automatic check on launch (configurable)           │   │
│  │ - "Check for Updates" menu item                      │   │
│  │ - EdDSA signature verification                       │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼ HTTPS fetch
┌─────────────────────────────────────────────────────────────┐
│              GitHub Pages (appcast.xml)                     │
│  - Version info, release notes                              │
│  - Download URLs (GitHub Releases)                          │
│  - EdDSA signatures                                         │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼ Download
┌─────────────────────────────────────────────────────────────┐
│              GitHub Releases (DMG files)                    │
│  - WorkspaceManager-1.0.0.dmg                              │
│  - WorkspaceManager-1.1.0.dmg                              │
└─────────────────────────────────────────────────────────────┘
```

## Implementation Phases

### Phase 1: Add Sparkle Dependency

**Files to modify:**
- `Package.swift` - Add Sparkle package dependency

```swift
dependencies: [
    .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0")
],
targets: [
    .executableTarget(
        name: "WorkspaceManager",
        dependencies: [
            "WorkspaceManagerCore",
            "SwiftTerm",
            .product(name: "Sparkle", package: "Sparkle")
        ],
        ...
    )
]
```

**Acceptance criteria:**
- [ ] `swift build` succeeds with Sparkle dependency
- [ ] Sparkle framework included in app bundle

### Phase 2: Generate Signing Keys

**Files to create:**
- `scripts/generate-sparkle-keys.sh` - One-time key generation script

```bash
#!/bin/bash
# Generate EdDSA key pair for Sparkle updates
# Run once, store private key securely (never commit!)

./Sparkle/bin/generate_keys

# Output:
# - Private key: Add to CI secrets as SPARKLE_PRIVATE_KEY
# - Public key: Add to Info.plist as SUPublicEDKey
```

**Acceptance criteria:**
- [ ] EdDSA key pair generated
- [ ] Private key stored in secure location (1Password, GitHub Secrets)
- [ ] Public key ready for Info.plist

### Phase 3: Configure Info.plist

**Files to modify:**
- `Sources/WorkspaceManager/Resources/Info.plist` - Add Sparkle configuration

Required keys:
```xml
<!-- Sparkle Configuration -->
<key>SUFeedURL</key>
<string>https://cloudcompute.github.io/workspaces/appcast.xml</string>

<key>SUPublicEDKey</key>
<string>{PUBLIC_EDKEY_FROM_GENERATION}</string>

<key>SUEnableAutomaticChecks</key>
<true/>

<key>SUScheduledCheckInterval</key>
<integer>604800</integer> <!-- Weekly (7 * 24 * 60 * 60) -->

<key>SUAllowsAutomaticUpdates</key>
<true/>
```

**Acceptance criteria:**
- [ ] SUFeedURL points to valid appcast location
- [ ] SUPublicEDKey contains generated public key

### Phase 4: Integrate Updater in App

**Files to modify:**
- `WorkspaceManager/Sources/WorkspaceManager/App/WorkspaceManagerApp.swift` - Add updater controller

```swift
import Sparkle

@main
struct WorkspaceManagerApp: App {
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }
    }
}
```

**Files to create:**
- `WorkspaceManager/Sources/WorkspaceManager/Views/CheckForUpdatesView.swift`

```swift
import SwiftUI
import Sparkle

struct CheckForUpdatesView: View {
    @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel

    init(updater: SPUUpdater) {
        self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…", action: checkForUpdatesViewModel.checkForUpdates)
            .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
    }
}

final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}
```

**Acceptance criteria:**
- [ ] "Check for Updates…" appears in app menu
- [ ] Menu item disabled during check, enabled when idle
- [ ] Automatic check runs on app launch

### Phase 5: Set Up Appcast Infrastructure

**Files to create:**
- `docs/appcast.xml` - Initial appcast (empty or with v1.0.0)
- `.github/workflows/update-appcast.yml` - Automation for appcast updates

Appcast template:
```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>WorkspaceManager Updates</title>
    <link>https://cloudcompute.github.io/workspaces/appcast.xml</link>
    <description>Most recent changes with links to updates.</description>
    <language>en</language>
    <item>
      <title>Version 1.0.0</title>
      <sparkle:version>1</sparkle:version>
      <sparkle:shortVersionString>1.0.0</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <pubDate>Mon, 01 Jan 2026 00:00:00 +0000</pubDate>
      <enclosure
        url="https://github.com/cloudcompute/workspaces/releases/download/v1.0.0/WorkspaceManager-1.0.0.dmg"
        sparkle:edSignature="{SIGNATURE}"
        length="{FILE_SIZE}"
        type="application/octet-stream" />
      <description><![CDATA[
        <h2>Initial Release</h2>
        <ul>
          <li>Terminal-based workspace management</li>
          <li>Git integration</li>
          <li>SwiftUI interface</li>
        </ul>
      ]]></description>
    </item>
  </channel>
</rss>
```

**Acceptance criteria:**
- [ ] Appcast accessible at SUFeedURL
- [ ] GitHub Pages configured for docs/ folder
- [ ] XML validates against Sparkle schema

### Phase 6: Release Signing Script

**Files to modify:**
- `scripts/notarize.sh` - Add Sparkle signing step

Add after DMG creation:
```bash
# Sign for Sparkle
SIGNATURE=$(./Sparkle/bin/sign_update "$DMG_PATH" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE")
echo "Sparkle signature: $SIGNATURE"
```

**Files to create:**
- `scripts/update-appcast.sh` - Script to update appcast with new release

**Acceptance criteria:**
- [ ] DMG signed with EdDSA key during release
- [ ] Signature included in appcast entry

## Verification Commands

```bash
# Build with Sparkle
swift build -c release

# Verify Sparkle linked
otool -L .build/release/WorkspaceManager | grep Sparkle

# Test appcast fetch (after deployment)
curl -s https://cloudcompute.github.io/workspaces/appcast.xml | xmllint --format -

# Verify signature
./Sparkle/bin/sign_update --verify "$DMG_PATH" --ed-key-file "$PUBLIC_KEY_FILE"
```

## Rollback Plan

If Sparkle causes issues:
1. Remove Sparkle dependency from Package.swift
2. Remove updater code from WorkspaceManagerApp.swift
3. Remove CheckForUpdatesView.swift
4. Remove Sparkle keys from Info.plist
5. Rebuild and release without auto-update

Users on broken version can manually download from GitHub Releases.

## References

- [Sparkle Documentation](https://sparkle-project.org/documentation/)
- [Sparkle 2 Migration Guide](https://sparkle-project.org/documentation/upgrading/)
- [Sparkle SPM Integration](https://github.com/sparkle-project/Sparkle#swift-package-manager)
- `Package.swift:1-29` - Current package configuration
- `scripts/notarize.sh` - Current release script
