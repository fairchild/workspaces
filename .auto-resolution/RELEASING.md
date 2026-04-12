# Releasing WorkspaceManager

This document describes the complete process for creating a new release of WorkspaceManager.

## Overview

WorkspaceManager is distributed as a notarized DMG file via GitHub Releases. The release process involves:

1. **Versioning** - Prepare version, changelog, commit, and tag through `scripts/prepare-release.sh`
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
- Developer ID provisioning profile with keychain sharing for `com.cloudcompute.workspaces`
- Notarization (for Gatekeeper approval)

### Local Development Setup

#### Step 1: Create a Developer ID Application Certificate

You need a **Developer ID Application** certificate — this is the specific certificate type Apple requires for distributing macOS apps outside the App Store. Other certificate types (Mac App Distribution, Apple Development) won't work for notarization.

**Option A: Via Xcode (easiest)**

1. Open Xcode > Settings > Accounts
2. Select your Apple ID, then your team
3. Click "Manage Certificates..."
4. Click **+** and choose "Developer ID Application"
5. Xcode creates the private key, submits the CSR, and installs the certificate automatically

**Option B: Via Apple Developer Portal (manual)**

1. Open Keychain Access > Certificate Assistant > Request a Certificate From a Certificate Authority
2. Enter your email, leave CA Email blank, select "Saved to disk"
3. Save the `.certSigningRequest` file
4. Go to [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates)
5. Click **+**, select "Developer ID Application", click Continue
6. Upload your `.certSigningRequest` file
7. Download the generated `.cer` file
8. Double-click the `.cer` to install it into Keychain Access

**Verify it worked:**

```bash
security find-identity -v -p codesigning
# Look for: "Developer ID Application: Your Name (TEAM_ID)"
```

If nothing shows up, check that both the certificate *and* its private key are in your login keychain (Keychain Access > login > My Certificates).

#### Step 2: Find Your Team ID

Your 10-character Team ID is at [developer.apple.com/account](https://developer.apple.com/account) under Membership Details. It's also shown in the parentheses of your signing identity from Step 1.

#### Step 3: Create a Developer ID Provisioning Profile

The data protection keychain requires more than a Developer ID certificate. The
packaged app also needs a macOS provisioning profile that authorizes:

- the `com.cloudcompute.workspaces` App ID
- keychain sharing for that App ID

Create a macOS Developer ID provisioning profile in the Apple Developer portal
for `com.cloudcompute.workspaces`, enable Keychain Sharing, download the
`.provisionprofile`, and store it somewhere local, for example:

```bash
mkdir -p ~/.config/apple
mv ~/Downloads/WorkspaceManager.provisionprofile ~/.config/apple/workspaces.provisionprofile
```

#### Step 4: Create an App-Specific Password

Notarization requires an app-specific password (your regular Apple ID password won't work).

1. Go to [account.apple.com](https://account.apple.com) > Sign-In and Security > App-Specific Passwords
2. Click "Generate an app-specific password"
3. Name it something like "workspaces-notarytool"
4. Copy the generated `xxxx-xxxx-xxxx-xxxx` password

You can optionally store this in Keychain instead of a file:

```bash
xcrun notarytool store-credentials "workspaces-notarize" \
    --apple-id your@email.com \
    --team-id XXXXXXXXXX \
    --password xxxx-xxxx-xxxx-xxxx
```

#### Step 5: Configure Local Signing

```bash
cp scripts/signing-config.sh.template scripts/signing-config.sh
```

Edit `scripts/signing-config.sh` with your credentials. The template has inline comments explaining each field. This file is gitignored — never commit it.

Set both:

- `SIGNING_IDENTITY` to your Developer ID Application certificate
- `PROVISIONING_PROFILE_PATH` to the downloaded `.provisionprofile`

Use `scripts/signing-config.sh` for local signing/notarization only. For GitHub Actions release setup, use `./scripts/setup-release-secrets.sh`.

If the Apple Developer portal is unclear about macOS provisioning profiles, use
Xcode to bootstrap the profile:

1. Create a temporary macOS app target on team `LKVN4J3C6C`
2. Set the bundle identifier to `com.cloudcompute.workspaces`
3. In `Signing & Capabilities`, add `Keychain Sharing`
4. Build/archive once so Xcode generates the macOS profile
5. Copy the resulting profile from `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`
   to `~/.config/apple/workspaces.provisionprofile`

The generated profile should be an `OSX` profile for
`com.cloudcompute.workspaces`, for example `Mac Team Direct Provisioning Profile:
com.cloudcompute.workspaces`.

#### Step 6: Verify the Full Pipeline

Run a local unsigned build first to confirm the toolchain works:

```bash
./scripts/build-release.sh --no-sign
open build/WorkspaceManager.app
```

Then test signing:

```bash
./scripts/build-release.sh
./scripts/verify-app-keychain-signing.sh build/WorkspaceManager.app
./scripts/verify-release-bundle.sh build/WorkspaceManager.app
# Should confirm the embedded provisioning profile, keychain access group,
# and Developer ID signing across nested code objects
```

### GitHub Actions Setup (for CI/CD)

Preferred setup path:

```bash
./scripts/setup-release-secrets.sh \
    --p12-path ~/.config/apple/Developer_ID_Application_<TEAM_ID>.p12 \
    --profile-path ~/.config/apple/workspaces.provisionprofile
```

Notes:
- The script is idempotent by default and only fills missing secrets/variables.
- Add `--force` to overwrite existing values.
- Add `--non-interactive` for CI-friendly usage.
- Add `--run-release --watch` to dispatch the release workflow from `main` immediately after setup and stream the result.

If you prefer to configure GitHub manually, add these **secrets** to your GitHub repository (Settings > Secrets and variables > Actions > Secrets):

| Secret | Description |
|--------|-------------|
| `APPLE_DEVELOPER_ID_CERT_BASE64` | Base64-encoded .p12 certificate |
| `APPLE_DEVELOPER_ID_CERT_PASSWORD` | Password for the .p12 file |
| `APPLE_DEVELOPER_ID_PROVISIONING_PROFILE_BASE64` | Base64-encoded Developer ID provisioning profile with keychain sharing |
| `APPLE_APP_PASSWORD` | App-specific password |

Add these **variables** to your GitHub repository (Settings > Secrets and variables > Actions > Variables):

| Variable | Description |
|--------|-------------|
| `APPLE_ID` | Your Apple ID email |
| `APPLE_TEAM_ID` | 10-character Team ID |

To export your certificate for CI or for `setup-release-secrets.sh`:

1. Open Keychain Access > login > My Certificates
2. Right-click your "Developer ID Application" certificate > Export Items...
3. Choose .p12 format, set a strong password (this becomes `APPLE_DEVELOPER_ID_CERT_PASSWORD`)
4. Base64-encode and copy to clipboard:

```bash
base64 -i Developer_ID_Application.p12 | pbcopy
# Paste as APPLE_DEVELOPER_ID_CERT_BASE64 secret
```

To export the provisioning profile for CI:

```bash
base64 -i ~/.config/apple/workspaces.provisionprofile | pbcopy
# Paste as APPLE_DEVELOPER_ID_PROVISIONING_PROFILE_BASE64 secret
```

---

## Release Methods

### Method 1: Manual Release via GitHub Actions (Recommended)

The recommended method for production releases.

1. **Prepare And Push The Release From `main`**

   Run the helper on a clean local `main` checkout:
   ```bash
   git checkout main
   ./scripts/prepare-release.sh --version 0.3.1
   ```

   The helper:
   - fetches `origin/main` and fast-forwards local `main` before mutating
   - updates `Info.plist` version/build metadata
   - prepends a changelog entry from commits since the latest `v*` tag
   - creates commit `release: v0.3.1`
   - creates lightweight tag `v0.3.1`
   - pushes `main` first, then pushes the tag

   Preview the computed release without mutating:
   ```bash
   ./scripts/prepare-release.sh --version 0.3.1 --dry-run
   ```

2. **Release Workflow Trigger**

   Pushing `v0.3.1` triggers `.github/workflows/release.yml` automatically.

3. **Optional Manual Rerun (from `main` or an existing release tag)**

   - Workflow: `.github/workflows/release.yml`
   - Trigger: `workflow_dispatch`
   - In GitHub: Actions > `Release` > `Run workflow`
   - Ref: `main` or an existing release tag (`v*`, `workspaces-v*`)
   - Runner lane: `[self-hosted, signing-host]`
     - At least one online runner must advertise the `signing-host` label before dispatch.
     - The release lane can be an existing signing-capable host; it does not need to be a separate machine, but it must be intentionally designated for release duties.
     - See [docs/development/signing-runner-setup.md](./docs/development/signing-runner-setup.md) for label assignment and verification commands.
   - Guardrails:
     - Manual releases fail if started from a non-`main` branch.
     - Release commit must be reachable from `origin/main`.
     - Tag-driven releases fail fast if app version metadata does not match the requested release tag.
     - Temporary signing keychain is cleaned up and prior keychain defaults are restored on the shared `signing-host` runner.
   - Actions performed:
     - Build GhosttyKit
     - Import signing certificate from secrets
     - Decode provisioning profile from secrets
     - Build signed `.app`
     - Verify nested bundle signing before notarization
     - Notarize and staple `.dmg`
     - Publish or refresh a GitHub release with artifacts via `gh`

4. **Release Tag and Assets**

   - `./scripts/prepare-release.sh --version <X.Y.Z>`:
     - creates and pushes `v<X.Y.Z>`
     - tag push triggers the release workflow automatically
   - Manual workflow-dispatch run from `main`:
     - If `v<version>` already exists, release assets are published to that tag
     - Otherwise tag format is `workspaces-v<version>-main.<run_number>`
   - Tag-push run: supports both `v<version>` and `workspaces-v*`
   - Rerunning the workflow for an existing tag replaces assets in place and refreshes generated release notes; no GitHub release cleanup is required.
   - Assets:
      - `WorkspaceManager-<version>.dmg`
      - `WorkspaceManager-latest.dmg`

### Method 1B: Tag-Driven Release (Main Commit Only)

If you prefer to cut the tag yourself first, you can push a release tag from a `main` commit:

```bash
git checkout main
git pull --ff-only origin main
./scripts/release-version.sh assert-tag-match v0.3.1
git tag v0.3.1
git push origin v0.3.1
```

- The `Release` workflow triggers on both `v*` and `workspaces-v*` tags.
- Guardrail still applies: the tagged commit must be on `origin/main` history.
- The pushed tag is used as the release tag directly.

### Method 2: Manual Local Release

For testing or when CI isn't available.

1. **Prepare Release Metadata**

   ```bash
   git checkout main
   ./scripts/prepare-release.sh --version 0.3.1 --no-push
   ```

2. **Build and Sign**

   ```bash
   ./scripts/build-release.sh
   ```

3. **Notarize and Create DMG**

   ```bash
   ./scripts/notarize.sh
   ```

   For local production-equivalent validation where Gatekeeper offline behavior is not required, use:

   ```bash
   ./scripts/notarize.sh --no-staple
   # or via mask:
   mask release near-prod
   ```

4. **Upload to GitHub**

   ```bash
   # Create release with GitHub CLI
   gh release create v0.3.1 \
       --title "Workspaces v0.3.1" \
       --notes "Release notes here" \
       build/WorkspaceManager-0.3.1.dmg
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
./scripts/verify-app-keychain-signing.sh build/WorkspaceManager.app
./scripts/verify-release-bundle.sh build/WorkspaceManager.app
# Should confirm the embedded provisioning profile, keychain access group,
# and Developer ID signing across nested code objects
```

### Gatekeeper
```bash
spctl --assess --type execute --verbose build/WorkspaceManager.app
# Should say "accepted"
```

### Notarization
```bash
xcrun stapler validate build/WorkspaceManager-0.3.1.dmg
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

When `scripts/notarize.sh` fails, it also saves Apple's JSON response to:

```bash
build/notarytool-log.json
```

Common issues:
- **Unsigned code**: All binaries and frameworks must be signed
- **Hardened runtime missing**: Use `--options runtime` when signing
- **Invalid entitlements**: Check entitlements file syntax and provisioning profile authorization
- **Missing provisioning profile**: Signed packaged builds need `PROVISIONING_PROFILE_PATH` locally and `APPLE_DEVELOPER_ID_PROVISIONING_PROFILE_BASE64` in CI
- **Secrets/variables drift**: Re-run `./scripts/setup-release-secrets.sh`; it is safe to run repeatedly and `--force` will refresh existing values

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
| `scripts/verify-app-keychain-signing.sh` | Verify embedded provisioning profile and signed keychain entitlements |
| `scripts/verify-release-bundle.sh` | Verify Developer ID signing across bundled code objects before notarization |
| `scripts/prepare-release.sh` | Update release metadata, create the release commit, and tag/push the release |
| `scripts/notarize.sh` | Create DMG and notarize |
| `scripts/setup-release-secrets.sh` | Configure GitHub Actions release secrets/variables from a verified `.p12` and provisioning profile |
| `scripts/signing-config.sh` | Your signing credentials (not in git) |

---

## Release Announcement Template

When announcing a release:

```markdown
## Workspaces v0.3.1

### What's New
- Feature 1
- Feature 2
- Bug fix 1

### Download
[WorkspaceManager-0.3.1.dmg](link)

### Requirements
- macOS 14.0 (Sonoma) or later
- Apple Silicon or Intel Mac

### Installation
1. Download the DMG
2. Drag Workspaces to Applications
3. Launch from Applications folder
```
