# Releasing WorkspaceManager

This document describes the complete process for creating a new release of WorkspaceManager,
including optional tester prereleases before a stable release is published.

## Overview

WorkspaceManager is distributed as a notarized DMG file via GitHub Releases. The release process involves:

1. **Versioning** - Land a release metadata PR, then tag stable releases or dispatch tester prereleases
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

#### Step 4: Create an App Store Connect API Key

Notarization uses App Store Connect API-key authentication rather than an
Apple ID app-specific password.

1. Go to App Store Connect > Users and Access > Integrations > App Store Connect API
2. Create an API key with notarization access
3. Download the `.p8` private key once and store it outside the repository, for example:

```bash
mkdir -p ~/.config/apple
mv ~/Downloads/AuthKey_XXXXXXXXXX.p8 ~/.config/apple/
chmod 600 ~/.config/apple/AuthKey_XXXXXXXXXX.p8
```

Record the key ID and issuer ID shown in App Store Connect. The key ID is also
embedded in the downloaded filename.

#### Step 5: Configure Local Signing

```bash
cp scripts/signing-config.sh.template scripts/signing-config.sh
```

Edit `scripts/signing-config.sh` with your credentials. The template has inline comments explaining each field. This file is gitignored — never commit it.

Set both:

- `SIGNING_IDENTITY` to your Developer ID Application certificate
- `PROVISIONING_PROFILE_PATH` to the downloaded `.provisionprofile`
- `APPLE_API_KEY_PATH`, `APPLE_API_KEY_ID`, and `APPLE_API_ISSUER_ID` for notarization

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
./scripts/verify-installed-perf.sh build/WorkSpaces.app /tmp/workspaces-installed-perf-verify-<date>
```

Then test signing:

```bash
./scripts/build-release.sh
./scripts/verify-app-keychain-signing.sh build/WorkSpaces.app
./scripts/verify-release-bundle.sh build/WorkSpaces.app
./scripts/verify-installed-perf.sh build/WorkSpaces.app build/release-installed-perf
# Should confirm the embedded provisioning profile, keychain access group,
# Developer ID signing across nested code objects, bundled Ghostty resources,
# and installed-app terminal readiness metrics
```

### GitHub Actions Setup (for CI/CD)

Before adding release secrets, create a GitHub Actions environment named
`release` in repository settings and require reviewer approval for deployments
to that environment. The release workflow references this environment before it
imports signing material, so environment protection is the approval gate for
Developer ID, notarization, and Sparkle release secrets.

The workflow is split into three jobs:

- `build-sign-notarize-release` runs on `[self-hosted, signing-host]` with
  read-only repository permissions. It imports the Developer ID certificate into
  a temporary keychain, builds and signs the app, notarizes the DMG, generates
  the Sparkle appcast, uploads release assets as workflow artifacts, then
  deletes the temporary keychain.
- `publish-github-release` runs on `ubuntu-latest` with `contents: write`. It
  downloads the signed artifacts and creates or updates the GitHub Release.
- `validate-published-release-assets` runs on GitHub-hosted macOS with
  read-only repository permissions after publication. It downloads the public
  release assets, validates the Sparkle appcast, confirms the latest DMG
  matches the versioned DMG, and runs macOS DMG notarization/Gatekeeper checks
  against the published asset.

Keep signing/notarization credentials scoped to the steps that need them. Do not
write generated keychain passwords or Apple notarization credentials to
`$GITHUB_ENV`; generated keychain passwords should be masked immediately with
`::add-mask::` before they can appear in logs.

Preferred setup path:

```bash
./scripts/setup-release-secrets.sh \
    --p12-path ~/.config/apple/Developer_ID_Application_<TEAM_ID>.p12 \
    --profile-path ~/.config/apple/workspaces.provisionprofile \
    --api-key-path ~/.config/apple/AuthKey_<KEY_ID>.p8 \
    --api-key-id <KEY_ID> \
    --api-issuer-id <ISSUER_ID>
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
| `APPLE_API_KEY_BASE64` | Base64-encoded App Store Connect API `.p8` key |
| `APPLE_API_KEY_ID` | App Store Connect API key ID |
| `APPLE_API_ISSUER_ID` | App Store Connect issuer ID |

Add these **variables** to your GitHub repository (Settings > Secrets and variables > Actions > Variables):

| Variable | Description |
|--------|-------------|
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

To export the App Store Connect API key for CI:

```bash
base64 -i ~/.config/apple/AuthKey_<KEY_ID>.p8 | pbcopy
# Paste as APPLE_API_KEY_BASE64 secret
```

---

## Release Methods

There are two normal lanes:

- **Tester prerelease:** metadata PR, merge to `main`, then manually dispatch
  `Release` from `main`. This creates a non-latest GitHub prerelease.
- **Stable release:** metadata PR, merge to `main`, then push `v<X.Y.Z>`. This
  creates or refreshes the latest stable GitHub Release and Sparkle appcast.

Both lanes use the same protected signing, notarization, appcast, manifest,
artifact upload, and published-asset validation workflow.

### Method 1: Stable Release

Use this after tester signoff or when you are ready to publish directly to all
users.

1. **Open a stable release metadata PR**

   Start from current `origin/main`:

   ```bash
   git fetch origin main --tags
   git checkout -b release/v0.21.0 origin/main
   ./scripts/prepare-release.sh --version 0.21.0 --metadata-only
   ```

   The helper updates `Info.plist` version/build metadata and prepends a
   `CHANGELOG.md` section computed from commits since the latest stable `v*`
   tag. It does not commit, tag, push, or publish.

   Preview without mutating:

   ```bash
   ./scripts/prepare-release.sh --version 0.21.0 --metadata-only --dry-run
   ```

   Review the generated changelog notes, commit the metadata changes, open a
   PR, attach evidence, and merge it to `main`.

2. **Tag the merged `main` commit**

   ```bash
   git fetch origin main --tags
   git checkout main
   git pull --ff-only origin main
   ./scripts/release-version.sh assert-tag-match v0.21.0
   git tag v0.21.0
   git push origin v0.21.0
   ```

   Pushing `v0.21.0` triggers `.github/workflows/release.yml`.

3. **Approve and watch the protected release workflow**

   - Workflow: `.github/workflows/release.yml`
   - Trigger: `push` tag `v*`
   - Runner lane: `[self-hosted, signing-host]`
   - Protected environment: `release`

   Guardrails:
   - The tagged commit must be reachable from `origin/main`.
   - Tag-driven releases fail fast if app version metadata does not match the
     requested release tag.
   - Release preflight waits for in-flight `build-and-test` checks on the exact
     source commit before signing starts.
   - Temporary signing keychain is cleaned up and prior keychain defaults are
     restored on the shared `signing-host` runner.

4. **Final download and update check**

   After the release workflow passes and published-asset validation is green,
   finish the release with an operator/user-visible update-path check:

   ```bash
   gh release download v0.21.0 \
       --repo fairchild/workspaces \
       --pattern "WorkSpaces-0.21.0.dmg" \
       --dir /tmp/workspaces-release-v0.21.0 \
       --clobber
   ```

   Confirm the versioned DMG downloads from the published GitHub Release; do not
   stop at seeing the asset listed in the browser. Ask the user to open the
   installed app and choose `WorkSpaces > Check for Updates...`; Sparkle should
   offer the new stable version with matching release notes. Record that
   confirmation in the release handoff/status update.

### Method 1A: Optional Tester Prerelease

Use this when several changes have landed on `main` and you want testers to
exercise the signed, notarized app before publishing a new stable release.

1. **Open a prerelease metadata PR**

   Start from current `origin/main` and choose a SemVer prerelease version:

   ```bash
   git fetch origin main --tags
   git checkout -b release/0.21.0-beta.1 origin/main
   ./scripts/prepare-prerelease.sh --version 0.21.0-beta.1
   ```

   The helper requires a prerelease suffix such as `-alpha.1`, `-beta.1`, or
   `-rc.1`. It updates `Info.plist`, bumps `CFBundleVersion`, and prepends a
   matching changelog section. It does not commit, tag, push, or publish.

   Preview without mutating:

   ```bash
   ./scripts/prepare-prerelease.sh --version 0.21.0-beta.1 --dry-run
   ```

   Review the generated changelog notes, commit the metadata changes, open a
   PR, attach evidence, and merge it to `main`.

2. **Dispatch the Release workflow from `main`**

   In GitHub: Actions > `Release` > `Run workflow` > Ref: `main`.

   Manual dispatch from `main` always publishes a tester prerelease named
   `workspaces-v<version>-main.<run_number>` with `--prerelease` and
   `--latest=false`. It does not replace the latest stable release and does not
   change the stable Sparkle feed.

3. **Hand the prerelease to testers**

   Send testers the GitHub prerelease URL or the versioned DMG asset from that
   prerelease. `WorkSpaces > Check for Updates...` uses
   `releases/latest/download/appcast.xml`, so normal update checks
   intentionally continue to see only the latest stable release.

4. **Publish stable after tester signoff**

   Merge any fixes, set the final stable version if the prerelease used
   `-alpha`, `-beta`, or `-rc`, and use Method 1 to create a fresh `v<X.Y.Z>`
   stable tag. Do not promote the `workspaces-v...` tester tag.

### Manual Reruns

- Dispatch `Release` from `main` to create another tester prerelease for the
  current app version.
- Dispatch `Release` from an existing `v*` or `workspaces-v*` tag to rebuild and
  refresh assets for that exact tag.
- Tag shape controls release classification: `v<X.Y.Z>` is stable/latest;
  SemVer prerelease tags and all `workspaces-v*` tags are GitHub prereleases.

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

4. **Exceptional Manual Upload**

   The normal publication path is still the protected GitHub Actions release
   workflow. Use direct `gh release create` only when intentionally bypassing
   automation, such as an incident recovery where signed/notarized artifacts
   already exist and the workflow cannot publish them.

   ```bash
   # Exceptional recovery only: publish already-built release assets directly.
   gh release create v0.3.1 \
       --title "WorkSpaces v0.3.1" \
       --notes "Release notes here" \
       build/WorkSpaces-0.3.1.dmg
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
./scripts/verify-app-keychain-signing.sh build/WorkSpaces.app
./scripts/verify-release-bundle.sh build/WorkSpaces.app
# Should confirm the embedded provisioning profile, keychain access group,
# and Developer ID signing across nested code objects
```

### Gatekeeper
```bash
spctl --assess --type execute --verbose build/WorkSpaces.app
# Should say "accepted"
```

### Notarization
```bash
xcrun stapler validate build/WorkSpaces-0.3.1.dmg
# Should say "The validate action worked!"
```

### Installed Performance
```bash
./scripts/verify-installed-perf.sh build/WorkSpaces.app build/release-installed-perf
# Should report launch_to_first_prompt, terminal_first_output, and first_prompt_ready
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
    --key "$APPLE_API_KEY_PATH" \
    --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER_ID"
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
| `scripts/verify-installed-perf.sh` | Verify packaged Ghostty resources and installed-app terminal readiness metrics |
| `scripts/prepare-release.sh` | Prepare stable release metadata; legacy direct commit/tag/push mode remains for exceptional local use |
| `scripts/prepare-prerelease.sh` | Prepare tester-prerelease version/build metadata and changelog notes for a PR |
| `scripts/notarize.sh` | Create DMG and notarize |
| `scripts/setup-release-secrets.sh` | Configure GitHub Actions release secrets/variables from a verified `.p12` and provisioning profile |
| `scripts/signing-config.sh` | Your signing credentials (not in git) |

---

## Release Announcement Template

When announcing a release:

```markdown
## WorkSpaces v0.3.1

### What's New
- Feature 1
- Feature 2
- Bug fix 1

### Download
[WorkSpaces-0.3.1.dmg](link)

### Requirements
- macOS 14.0 (Sonoma) or later
- Apple Silicon or Intel Mac

### Installation
1. Download the DMG
2. Drag WorkSpaces to Applications
3. Launch from Applications folder
```
