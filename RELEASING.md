# Releasing WorkspaceManager

This document describes the complete process for creating a new release of WorkspaceManager.

## Overview

WorkspaceManager is distributed as a notarized DMG file via GitHub Releases. The release process involves:

1. **Versioning** - Update version numbers in Info.plist
2. **Building** - Create release binary with SPM
3. **Bundling** - Package into a proper .app bundle
4. **Signing** - Sign with Developer ID certificate
5. **Notarizing** - Submit to Apple for notarization
6. **Packaging** - Create DMG with stapled notarization ticket
7. **Releasing** - Upload to GitHub Releases

## Prerequisites

### Apple Developer Program

You need an Apple Developer Program membership ($99/year) for:
- Developer ID Application certificate (for code signing)
- Notarization (for Gatekeeper approval)

### Local Development Setup

1. **Install Developer ID Certificate**

   Export your Developer ID Application certificate from the Apple Developer portal and import it into Keychain Access:

   ```bash
   # The certificate should appear when you run:
   security find-identity -v -p codesigning
   ```

2. **Create App-Specific Password**

   For notarization, create an app-specific password at [appleid.apple.com](https://appleid.apple.com) under Security > App-Specific Passwords.

3. **Configure Signing Credentials**

   ```bash
   cp scripts/signing-config.sh.template scripts/signing-config.sh
   # Edit signing-config.sh with your credentials
   ```

### GitHub Actions Setup (for CI/CD)

Add these **secrets** to your GitHub repository (Settings > Secrets and variables > Actions > Secrets):

| Secret | Description |
|--------|-------------|
| `APPLE_DEVELOPER_ID_CERT_BASE64` | Base64-encoded .p12 certificate |
| `APPLE_DEVELOPER_ID_CERT_PASSWORD` | Password for the .p12 file |
| `APPLE_APP_PASSWORD` | App-specific password |

Add these **variables** to your GitHub repository (Settings > Secrets and variables > Actions > Variables):

| Variable | Description |
|--------|-------------|
| `APPLE_ID` | Your Apple ID email |
| `APPLE_TEAM_ID` | 10-character Team ID |

To export and encode your certificate:

```bash
# Export from Keychain Access as .p12, then:
base64 -i Developer_ID_Application.p12 | pbcopy
# Paste as APPLE_DEVELOPER_ID_CERT_BASE64 secret
```

---

## Release Methods

### Method 1: Manual Release via GitHub Actions (Recommended)

The recommended method for production releases.

1. **Update Version**

   Edit `Sources/WorkspaceManager/Resources/Info.plist`:
   ```xml
   <key>CFBundleShortVersionString</key>
   <string>0.2.0</string>  <!-- New version -->
   ```

2. **Merge Version Changes to `main`**

   ```bash
   git add .
   git commit -m "chore: bump version to 0.2.0"
   git push origin <your-branch>
   # Open PR and merge after CI is green
   ```

3. **Run Release Workflow Manually**

   - Workflow: `.github/workflows/release.yml`
   - Trigger: `workflow_dispatch` only (manual run)
   - In GitHub: Actions > `Release` > `Run workflow`
   - Branch to release from: `main`
   - Actions performed:
     - Build GhosttyKit
     - Import signing certificate from secrets
     - Build signed `.app`
     - Notarize and staple `.dmg`
     - Publish a GitHub release with artifacts

4. **Release Tag and Assets**

   - Tag format: `workspaces-v<version>-main.<run_number>`
   - Assets:
     - `WorkspaceManager-<version>.dmg`
     - `WorkspaceManager-latest.dmg`

### Method 2: Manual Local Release

For testing or when CI isn't available.

1. **Update Version**

   ```bash
   # Edit Info.plist manually or use PlistBuddy:
   /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.2.0" \
       Sources/WorkspaceManager/Resources/Info.plist
   /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(($(date +%s)/86400))" \
       Sources/WorkspaceManager/Resources/Info.plist
   ```

2. **Build and Sign**

   ```bash
   ./scripts/build-release.sh
   ```

3. **Notarize and Create DMG**

   ```bash
   ./scripts/notarize.sh
   ```

4. **Upload to GitHub**

   ```bash
   # Create release with GitHub CLI
   gh release create workspaces-v0.2.0 \
       --title "Workspaces v0.2.0" \
       --notes "Release notes here" \
       build/WorkspaceManager-0.2.0.dmg
   ```

---

## Version Numbering

We follow [Semantic Versioning](https://semver.org/):

- **MAJOR** (1.0.0): Breaking changes
- **MINOR** (0.1.0): New features, backwards compatible
- **PATCH** (0.0.1): Bug fixes, backwards compatible

Pre-release versions:
- `0.1.0-beta.1` - Beta releases
- `0.1.0-alpha.1` - Alpha releases

Build numbers (CFBundleVersion) are auto-incremented by CI or can be set manually.

---

## Verification Checklist

After creating a release, verify:

### Code Signature
```bash
codesign -dv --verbose=4 build/WorkspaceManager.app
# Should show "Developer ID Application: Your Name (TEAM_ID)"
```

### Gatekeeper
```bash
spctl --assess --type execute --verbose build/WorkspaceManager.app
# Should say "accepted"
```

### Notarization
```bash
xcrun stapler validate build/WorkspaceManager-0.2.0.dmg
# Should say "The validate action worked!"
```

### Clean Mac Test

Download the DMG from GitHub Releases onto a Mac that has never seen the app:
1. Mount the DMG
2. Drag to Applications
3. Double-click to launch (no Gatekeeper warning should appear)

---

## Troubleshooting

### Notarization Fails

View the notarization log:
```bash
xcrun notarytool log <submission-id> \
    --apple-id your@email.com \
    --password xxxx-xxxx-xxxx-xxxx \
    --team-id XXXXXXXXXX
```

Common issues:
- **Unsigned code**: All binaries and frameworks must be signed
- **Hardened runtime missing**: Use `--options runtime` when signing
- **Invalid entitlements**: Check entitlements file syntax

### "App is damaged" Error

The notarization ticket wasn't stapled. Run:
```bash
xcrun stapler staple path/to/your.dmg
```

### Certificate Not Found

Ensure the certificate is in your login keychain and unlocked:
```bash
security unlock-keychain ~/Library/Keychains/login.keychain-db
security find-identity -v -p codesigning
```

---

## Scripts Reference

| Script | Purpose |
|--------|---------|
| `scripts/build-release.sh` | Build app bundle from SPM |
| `scripts/notarize.sh` | Create DMG and notarize |
| `scripts/signing-config.sh` | Your signing credentials (not in git) |

---

## Release Announcement Template

When announcing a release:

```markdown
## Workspaces v0.2.0

### What's New
- Feature 1
- Feature 2
- Bug fix 1

### Download
[WorkspaceManager-0.2.0.dmg](link)

### Requirements
- macOS 14.0 (Sonoma) or later
- Apple Silicon or Intel Mac

### Installation
1. Download the DMG
2. Drag Workspaces to Applications
3. Launch from Applications folder
```
