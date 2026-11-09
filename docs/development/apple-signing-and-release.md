# Apple Signing, Notarization, and How WorkSpaces Ships

This page explains why a macOS release needs the credentials it does and how the
WorkSpaces release pipeline uses each one. [`RELEASING.md`](../../RELEASING.md)
holds the commands; this page holds the model those commands assume.

## The three questions every release answers

A downloaded Mac app is checked by **Gatekeeper** the first time it opens.
Gatekeeper asks two things: who built this, and has Apple looked at it? A
release answers the first with a **code signature** made by a Developer ID
certificate, and the second with a **notarization ticket** issued by Apple.
WorkSpaces also updates itself through **Sparkle**, which asks a third question
on every update: did the same publisher sign this update? Sparkle answers that
with its own key, unrelated to Apple's.

![Three lanes, one per question. Lane 1: the Developer ID certificate feeds codesign, which seals the app, which Gatekeeper checks. Lane 2: the App Store Connect key feeds notarytool and stapler, which produce a notarized DMG, which Gatekeeper checks. Lane 3: the Sparkle private key feeds sign_update, which signs appcast.xml, which the installed app verifies.](../assets/signing/trust-chains.svg)

Every credential on this page sits in the left column of one of those lanes.
The colors carry through the rest of the page: blue for Apple identity, amber
for notarization, green for Sparkle.

### Words this page uses

| Term | Meaning |
|---|---|
| Developer ID Application certificate | Apple's certificate for signing Mac apps distributed outside the App Store |
| `.p12` | One file holding a certificate and its private key, encrypted with an export password |
| Hardened runtime | A signing option that blocks code injection and similar tricks; notarization requires it |
| Entitlement | A capability the signature claims, such as JIT or a shared keychain group |
| Provisioning profile | Apple's signed grant of restricted entitlements to one app ID |
| Notarization | Apple's automated scan of a signed build, which issues a ticket when it passes |
| Stapling | Attaching the ticket to the file so Gatekeeper can check it offline |
| Appcast | Sparkle's update feed, `appcast.xml`, carrying a signature for each release |
| Environment | A GitHub scope for secrets and approval rules, entered only by jobs that name it |

## Part 1 · Apple's model

### Identity: the Developer ID certificate

An Apple Developer Program membership gives a team the right to create a
[**Developer ID Application**](https://developer.apple.com/developer-id/)
certificate ([how to create one](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)).
That certificate type is the one Apple accepts for apps distributed outside the
App Store; Apple Development and Mac App Distribution certificates do not
notarize.

A certificate is a public half that Apple signed and a private key that only
its owner holds. The private key is created on the Mac that requested the
certificate and normally never leaves that Mac's Keychain. To sign anywhere
else, such as a CI runner, the pair is exported together as a **`.p12`** file,
encrypted with an export password.

> **Two secrets, not one.** The `.p12` cannot be opened without its export password, so CI needs both, and losing the password means exporting a new `.p12` from the Mac that holds the private key.

Developer ID certificates are valid for five years. Because each signature
carries a secure timestamp, apps signed before expiry keep opening afterwards;
only new signing needs a renewed certificate. Apple's
[Developer ID page](https://developer.apple.com/developer-id/) and
[certificates overview](https://developer.apple.com/help/account/certificates/certificates-overview)
describe expiry and revocation.

### The code signature

`codesign` seals each executable in the bundle, innermost first (embedded
frameworks such as Sparkle, then the app), so any later change to a signed file
breaks the seal. Apple's
[Code Signing Guide](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Introduction/Introduction.html)
is archived but still the clearest account of what a signature covers. Two
options matter for distribution:

- `--options runtime` enables the
  [**hardened runtime**](https://developer.apple.com/documentation/security/hardened-runtime),
  which notarization requires. Exceptions the app genuinely needs, such as JIT for the terminal
  renderer, are declared as entitlements rather than by turning protection off.
- `--timestamp` asks Apple's timestamp server to countersign, which is what
  keeps the signature valid past certificate expiry.

### Entitlements and the provisioning profile

[**Entitlements**](https://developer.apple.com/documentation/bundleresources/entitlements)
are capabilities the signature claims for the app. Most are self-declared in
[`WorkspaceManager.entitlements`](../../WorkspaceManager.entitlements). A few are
restricted: Apple must grant them for a specific app ID, and the grant travels
as a **provisioning profile** embedded in the bundle
([TN3125: Inside Code Signing: Provisioning Profiles](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)).

WorkSpaces needs one restricted entitlement,
[`keychain-access-groups`](https://developer.apple.com/documentation/bundleresources/entitlements/keychain-access-groups),
because it keeps credentials in the data protection keychain
([TN3137: On Mac keychain APIs and implementations](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)
explains the two Mac keychains). The Developer ID
provisioning profile for `com.cloudcompute.workspaces` carries that grant. An
unsigned or ad-hoc local build has no profile, so it falls back to the legacy
login keychain at runtime. Before signing, `scripts/build-release.sh` checks
that the profile names this bundle ID, this team, and the app's keychain group,
then writes exactly that group into the signing entitlements, so the signature
never claims a group the profile does not grant.

### Notarization

[**Notarization**](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
is an automated Apple service. The pipeline uploads the signed DMG with
`xcrun notarytool`
([Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
covers the command line); Apple scans it for malware and for signing
mistakes (missing hardened runtime, unsigned nested code, no timestamp) and, if
it passes, issues a **ticket** for that exact file. `xcrun stapler staple`
attaches the ticket to the DMG so Gatekeeper can verify it without a network
connection.

`notarytool` authenticates with an
[**App Store Connect API key**](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api),
not an Apple ID password. A key is three values that must belong together:

| Value | What it is | Where it appears |
|---|---|---|
| Private key | The `AuthKey_<KEY_ID>.p8` file, downloadable once | The owner's Mac |
| Key ID | Ten characters naming the key | The `.p8` filename and the App Store Connect key list |
| Issuer ID | A UUID naming the team's API account | Above the key list in App Store Connect |

A team can have many keys, each with its own access level, and other tools
(Fastlane, Xcode Cloud) often have keys of their own.

> **The `.p8` file and the key ID must name the same key.** A mismatched pair fails notarization with an authentication error, not a signing error. The key ID is in the file's name.

When Apple rejects a submission for a signing reason rather than an
authentication one, its log names the file and the rule;
[Resolving common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)
maps each rule to its fix.

### Gatekeeper

On first launch
[Gatekeeper](https://support.apple.com/guide/security/gatekeeper-and-runtime-protection-sec5599b66df/web)
checks the signature against Apple's certificate chain, then looks for a
notarization ticket, stapled or fetched from Apple.
`spctl --assess` runs the same check from a terminal, and the pipeline runs it
on every candidate.

## Part 2 · Sparkle, a separate trust chain

Sparkle checks updates with an
[**EdDSA key pair**](https://sparkle-project.org/documentation/#3-segue-for-security-concerns)
that has nothing to do with Apple:

1. The public key ships inside every copy of the app as `SUPublicEDKey` in
   `Info.plist`.
2. The private key signs each release DMG. The signature goes into
   `appcast.xml`, the feed at `SUFeedURL` that installed apps poll
   ([Publishing an update](https://sparkle-project.org/documentation/publishing/)).
3. An installed app refuses any update whose signature does not verify against
   the public key it already has.

> **Never replace the Sparkle key casually.** Rule 3 means a new key pair, or a lost one, leaves every existing install rejecting every future update until users reinstall by hand. Guard it like the Developer ID private key, not like a token.

Sparkle's `generate_keys` tool keeps the private key in the login Keychain
under a service of `https://sparkle-project.org` and an account name. This
project's key is stored under the account `com.cloudcompute.workspaces`, not
the tool's default, so every lookup needs
`generate_keys --account com.cloudcompute.workspaces`. Without the flag the tool
reports that no key exists. Before uploading the key anywhere, compare
`generate_keys --account com.cloudcompute.workspaces -p` with `SUPublicEDKey`.

## Part 3 · Our pipeline

### Where each credential lives

The owner keeps the originals. GitHub holds copies that only the build job can
read.

![The owner's Mac holds the originals in ~/.config/apple, a password manager, App Store Connect and the login Keychain. They are uploaded once to seven secrets in the release-candidate GitHub environment, which only the build job on main can read. The build job creates a temporary keychain, signs, notarizes, signs the appcast, and deletes the keychain.](../assets/signing/credential-flow.svg)

| Credential | Owner's copy | GitHub secret in `release-candidate` | Used for |
|---|---|---|---|
| Developer ID certificate and private key | `Developer_ID_Application_<TEAM_ID>.p12` | `APPLE_DEVELOPER_ID_CERT_BASE64` | Code signing |
| `.p12` export password | Password manager | `APPLE_DEVELOPER_ID_CERT_PASSWORD` | Opening the `.p12` on the runner |
| Developer ID provisioning profile | `workspaces.provisionprofile` | `APPLE_DEVELOPER_ID_PROVISIONING_PROFILE_BASE64` | Keychain-sharing entitlement |
| App Store Connect private key | `AuthKey_<KEY_ID>.p8` | `APPLE_API_KEY_BASE64` | Notarization |
| App Store Connect key ID | The `.p8` filename | `APPLE_API_KEY_ID` | Notarization |
| App Store Connect issuer ID | App Store Connect, Integrations page | `APPLE_API_ISSUER_ID` | Notarization |
| Sparkle EdDSA private key | Login Keychain, account `com.cloudcompute.workspaces` | `SPARKLE_PRIVATE_KEY` | Signing the appcast |

The owner's files conventionally live in `~/.config/apple/`.
[`scripts/setup-release-secrets.sh`](../../scripts/setup-release-secrets.sh)
uploads them, verifying the `.p12` first.

> **GitHub secrets are write-only.** Nothing, including the API, can read a value back. A secret that is wrong or lost is replaced by uploading it again from the owner's copy.

GitHub's [Using secrets in GitHub Actions](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets)
covers how secrets are stored and masked in logs.

### How a release runs

`scripts/release.py` opens a metadata PR that changes only `CHANGELOG.md` and
`Info.plist`. Once it merges and CI passes on that exact commit,
`.github/workflows/release.yml` runs five jobs in order. It starts from a
[`workflow_run`](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_run)
event when CI completes, or from `workflow_dispatch` when the owner starts it.

![Five jobs left to right: Qualify, Build sign notarize, Validate candidate, Publish, Validate published. A dashed amber zone marks the build job as the only one in release-candidate, holding seven signing secrets. A dashed blue zone marks Publish as release-publication, where the owner approves and no secrets exist. A bracket under the first three jobs reads: before approval, build, sign and test the exact bytes that would ship. A bracket under the last two reads: after approval, publish those bytes, then check what users get.](../assets/signing/release-pipeline.svg)

| Job | Holds secrets | What it does |
|---|---|---|
| `qualify` | None | Checks the source: CI passed on this commit, every PR since the last release was independently approved, main has not moved past the metadata commit, and the environments are configured as below. |
| `build-sign-notarize-release` | All seven | Imports the `.p12` into a throwaway keychain, builds and signs the app with the embedded profile, notarizes and staples the DMG, signs the appcast with the Sparkle key, seals the candidate's hashes, uploads it as an immutable artifact, then deletes the keychain. |
| `validate-candidate` | None | Downloads the sealed artifact and checks the installer it actually contains. Its summary links the candidate download. |
| `publish-github-release` | None | Waits for the owner's approval, then publishes the same bytes it validated. Nothing is rebuilt after approval. |
| `validate-published-release-assets` | None | Downloads the public release and the live appcast and checks them against the approved candidate. |

Signing happens before the approval on purpose. The owner approves a finished,
tested installer and can download it first, rather than approving permission to
start building one.

### Why three environments

A GitHub
[**environment**](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments)
scopes secrets and approval rules (required reviewers, branch policies) to the
jobs that declare it. Repository-wide secrets would be readable by any workflow on any
branch; environment secrets are readable only by a job that names the
environment and passes its branch policy.

| Environment | Secrets | Branch policy | Approval |
|---|---|---|---|
| `release-candidate` | All seven signing secrets | `main` only | None |
| `release-publication` | None | `main` only | Owner |
| `release` (legacy) | The older copies | — | Owner, permanently |

- `release-candidate` signs without asking because the job that reads its
  secrets cannot publish anything.
- `release-publication` asks because it is the step that changes what users
  download, and it holds no signing material.
- `release` is the environment the pre-September 2026 workflow used. It keeps
  its approval so that rerunning an old workflow run cannot publish around the
  new gate.

`scripts/release-environments.py check` verifies this shape during `qualify`,
and `apply` creates it. `apply` lifts the approval on `release-candidate` only
once every signing secret is present.

### The review proof and the maintainer allowlist

`qualify` refuses a release unless every PR merged since the previous stable
release has an independent approving review on its final commit. A PR merged
without one can be vouched for by the owner at dispatch time:

```bash
gh workflow run release.yml --ref main -f channel=stable -f maintainer_reviewed_prs=101,102
```

The numbers are recorded in the release manifest as owner-signed rather than
reviewed. The automatic release path takes no inputs, so an unattended release
still needs a real approval on every PR.

## Part 4 · Operating it

### Rotating or replacing a credential

| Credential | When | How |
|---|---|---|
| Developer ID certificate | Before it expires, or if the private key leaks | Create a new certificate, export a new `.p12`, run `setup-release-secrets.sh --force`. Revoke the old one only for a leak, since revocation can affect already-shipped builds. |
| `.p12` password | With the `.p12` | Same command. |
| Provisioning profile | When it expires or the app ID's capabilities change | Regenerate in the Apple Developer portal, then the same command. |
| App Store Connect key | If the `.p8` leaks, or to narrow access | Create a new key, re-upload all three API values together, then revoke the old one. `xcode-cloud-logs` holds its own copies of the same three names; update them too if it uses the same key. |
| Sparkle key | Only if it is compromised | Plan a migration first. Existing installs only trust the current public key. |

### Pitfalls seen in practice

| Symptom | Cause | Fix |
|---|---|---|
| `qualify` fails with "Candidate signing still requires approval" | The September 2026 move to `release-candidate` needed its secrets loaded, and that step never ran until November 2026 | Load the secrets, run `release-environments.py apply`, then `check --settings` |
| Notarization fails to authenticate | The `.p8` file and the key ID came from different keys | Upload the `.p8` whose filename contains the key ID you entered |
| `generate_keys` reports no Sparkle key | The key is stored under the project's account name | Pass `--account com.cloudcompute.workspaces` |
| `qualify` fails with "Main advanced beyond the reviewed release notes" | A merge landed between the metadata commit and the dispatch | Prepare a new metadata commit, and hold merges to `main` until the dispatch qualifies |
| The automatic run fails with "PR #N lacks an independent approving review" | A merged PR has no approval on its final commit, and the automatic path cannot carry an allowlist | Dispatch with `maintainer_reviewed_prs` naming the PRs you vouch for |

## Further reading

In this repo:

- [`RELEASING.md`](../../RELEASING.md): commands, recovery, and verification
- [Release approval retrospective](../retros/2026-09-07-release-approval-contract.md):
  why signing moved ahead of the approval

Apple:

- [Developer ID](https://developer.apple.com/developer-id/) and
  [Create Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution),
  [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow),
  [Resolving common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)
- [Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime),
  [Entitlements](https://developer.apple.com/documentation/bundleresources/entitlements),
  [TN3125: Provisioning Profiles](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
- [Creating API keys for App Store Connect API](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api)
- [Gatekeeper and runtime protection](https://support.apple.com/guide/security/gatekeeper-and-runtime-protection-sec5599b66df/web)
  (Apple Platform Security)

Sparkle and GitHub:

- Sparkle: [Documentation](https://sparkle-project.org/documentation/) and
  [Publishing an update](https://sparkle-project.org/documentation/publishing/)
- GitHub: [Managing environments for deployment](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments)
  and [Using secrets in GitHub Actions](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets)
