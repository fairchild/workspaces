# Lume Validation Runbook

This is the canonical runbook for validating the Lume-backed workspace flow.

Use it for two different jobs:

- capture deterministic PR evidence for the first-use setup flow
- validate Lume itself on Apple Silicon with no Swift app involvement
- manually validate a real host-backed Lume workspace after the standalone gate passes

If you only need repeatable UI evidence, use the fixture flow first. If you need to validate the actual runtime integration, run the standalone Lume gate first, then the app-backed real-host flow.

Current-state integration details live in [lume-integration.md](./lume-integration.md).

If you need the exact from-scratch recreation path and the current troubleshooting playbook, start with [lume-recreate-runbook.md](./lume-recreate-runbook.md).

## Known-Good Evidence

These are the current green bundles on this Mac:

- standalone validator pass:
  - `output/lume-standalone/20260311-182619`
- app-backed host smoke pass:
  - `output/lume-host-smoke/20260311-182805`
- aggregate PR validation pass:
  - `output/lume-pr-validation/20260311-182717`

## Validation Modes

### 1. Fixture UI E2E

Purpose:

- validate the app's Lume UX end to end
- generate stable screenshots for review or a PR
- avoid depending on a real local Lume install or a reachable golden image registry

What it covers:

- environment picker shows `macOS VM`
- `Setup required` state
- one-click Lume setup confirmation sheet
- setup progress sheet
- automatic resume into a created Lume workspace

What it does not cover:

- real Lume installation
- real daemon communication
- real macOS VM boot
- real VNC desktop launch

### 2. Real Host Validation

Purpose:

- validate the actual Lume install, daemon, image resolution, VM pull, VM run, SSH attach, and desktop open behavior

What it covers:

- first-use install flow against the official Lume installer
- LaunchAgent and daemon verification
- host-profile image matching
- real macOS VM creation and startup
- `lume ssh` terminal attach
- external VNC desktop open

What it depends on:

- Apple Silicon host
- reachable Lume installer
- reachable default golden image for the current host profile

### 3. Standalone Lume Validation

Purpose:

- prove Lume can prepare, boot, SSH into, and clone a macOS base VM on its own
- keep Lume defects separate from Workspaces defects
- own one trusted validated base per host profile

What it covers:

- Lume CLI create, run, stop, clone, and SSH
- daemon health and state consistency
- base boot-to-SSH verification
- clone boot-to-SSH verification
- shared-dir visibility in the clone at `/Volumes/My Shared Files`
- Workspaces-owned unattended overrides for stock base preparation

Contract:

- Workspaces-managed validated bases live in:
  - `~/Library/Application Support/WorkspaceManager/LumeStorage/validated-bases`
- standalone clone smoke VMs live in:
  - `~/Library/Application Support/WorkspaceManager/LumeStorage/standalone-smoke`
- workspace VMs created by the app live in:
  - `~/Library/Application Support/WorkspaceManager/LumeStorage/workspace-vms`
- a base is trusted only when the standalone validator has written:
  - `~/Library/Application Support/WorkspaceManager/LumeValidatedBases/<vmName>.json`
  - with `state = "ready"` for the current `hostProfileKey`
- stock Tahoe base preparation now relies on the versioned Workspaces profiles under:
  - `config/lume/unattended/`
- the current default NAT Tahoe override is:
  - `config/lume/unattended/tahoe-workspaces-v26.yml`
- the bridged Tahoe diagnostics override is:
  - `config/lume/unattended/tahoe-workspaces-bridged-v27.yml`
- the current recreate-from-scratch recovery helper is:
  - `config/lume/unattended/tahoe-workspaces-v18-official-run-bootstrap-ssh.yml`
- stock base preparation uses `LUME_STANDALONE_PREPARE_NETWORK` and defaults it to the same value as `LUME_STANDALONE_RUN_NETWORK` (`nat` unless overridden)

Upstream Lume local-build note:

- for upstream Lume changes, do not use raw `libs/lume/.build/debug/lume` as the standalone-validator target
- use `libs/lume/scripts/install-local.sh` into an isolated install dir and point `LUME_BIN` at the installed binary
- the raw SwiftPM build has behaved inconsistently on this Mac, for example passing `lume ipsw` but getting killed during `lume ls -f json`
- `install-local.sh --no-background-service` removes the current `com.trycua.lume_daemon` LaunchAgent during cleanup, so restore the daemon manually before normal Workspaces validation

## Quick Decision Guide

Use this rule:

- changing UI, setup wording, progress states, or action resumption: run the fixture flow
- changing runtime detection, installation, daemon verification, image resolution, VM lifecycle, or desktop launch: run fixture plus standalone Lume validation, then real-host validation

## Swift App Runtime Surfaces

When the real app path is under test, these are the active seams:

| Type | Responsibility |
| --- | --- |
| `LumeRuntimeService` | install/repair flow, daemon health, base inspection |
| `LumeWorkspaceProvider` | workspace VM lifecycle and launch orchestration |
| `LumeHTTPClient` | shared daemon transport and endpoint building |
| `LumeCLIRunner` | shared `lume` CLI execution and detached macOS `run` launch |
| `LumeImageCatalog` | host-profile image resolution |
| `LumeVMStatus` / `LumeErrorHeuristics` | normalized status and retry/missing-VM classification |

## Fixture UI E2E

### Prerequisites

- WorkspaceManager builds locally
- Screen Recording is granted
- Accessibility is granted
- Automation access to `System Events` is granted

### Commands

```bash
./scripts/build-ghosttykit.sh
swift build
./scripts/lume-e2e-capture.sh
```

### What the script does

`./scripts/lume-e2e-capture.sh` launches the app in a dedicated Lume fixture mode and captures the WorkspaceManager window by CoreGraphics window id. That avoids the shared-desktop contamination problems that happen with raw screen-region screenshots.

The script sets:

- `WORKSPACES_UI_FIXTURE=1`
- `WORKSPACES_UI_FIXTURE_LUME_E2E=1`
- `WORKSPACES_UI_FIXTURE_LUME_STEP_DELAY_MS=700`
- `WORKSPACES_DISABLE_AUTO_IMPORT=1`

It also generates a unique workspace name per run so repeated runs do not fail due to an existing fixture workspace name.

### Expected artifacts

The script writes:

- latest symlink: `output/lume-e2e/latest`
- timestamped run: `output/lume-e2e/<timestamp>`

Each run contains:

- `01-new-workspace-sheet.png`
- `02-macos-vm-selected.png`
- `03-lume-setup-confirmation.png`
- `04-lume-setup-progress.png`
- `05-workspace-created.png`
- `EVIDENCE.md`
- `run.log`
- `app-output-initial.log`
- `app-output-final.log`

### PR Evidence Checklist

Confirm all of these before using the artifacts:

- `macOS VM` is visible in the sheet
- the host-matched label is shown, for example `macOS Tahoe 26.2 + Xcode 26.2`
- the confirmation sheet says Workspaces will install Lume and continue automatically
- the progress sheet shows a real setup step, not an empty spinner
- the final screenshot shows the created Lume workspace selected in the sidebar

## Real Host Validation

### Standalone gate

Run this first:

```bash
./scripts/lume-standalone-validate.sh
```

Or with `mise`:

```bash
mise run dev-lume-standalone-validate
```

If you are validating an upstream Lume patch locally, use:

```bash
INSTALL_DIR="/tmp/lume-upstream-test/bin" \
  TERM=xterm-256color \
  /path/to/cua/libs/lume/scripts/install-local.sh --no-background-service

tmux new-session -d -s codex-lume-daemon \
  "/tmp/lume-upstream-test/bin/lume serve --port 7777"

LUME_BIN="/tmp/lume-upstream-test/bin/lume" \
  ./scripts/lume-standalone-validate.sh
```

That path is closer to the locally installed entitlement/signing behavior than running the SwiftPM output in place.

This path writes:

- `output/lume-standalone/latest`
- `output/lume-standalone/<timestamp>`

and captures:

- `summary.md`
- `status.json`
- `base-get-before.json`
- `base-get-running.json`
- `clone-get-running.json`
- `ssh-probe-base.txt`
- `ssh-probe-clone.txt`
- `daemon.log`
- `daemon.error.log`
- `unattended-debug/` when the base was prepared from stock macOS

`status.json` reports the run outcome for the artifact bundle. The manifest under `~/Library/Application Support/WorkspaceManager/LumeValidatedBases/` is the runtime contract the app trusts.

If stock base preparation fails, inspect `unattended-debug/` before debugging the Swift app path. That directory contains Lume's VNC/OCR debug artifacts for the exact unattended run.

Do not treat a Workspaces macOS VM smoke failure as meaningful until this standalone gate passes on the same Mac.

Current known-good runtime note:

- Workspaces now targets NAT-backed validated bases by default
- if you are trying to recreate or debug the older bridged host-reachability path, use [lume-recreate-runbook.md](./lume-recreate-runbook.md)

### Known-good manual recovery path

The default manual proof path is:

1. run the official installed Lume daemon on port `7778`
2. boot the validated base from Workspaces-managed storage
3. prefer `network: "nat"` unless you are debugging host-network reachability
4. log in over VNC if needed
5. enable `Remote Login` in `System Settings -> Sharing`
6. verify the base with direct SSH
7. clone the base and verify clone SSH plus `/Volumes/My Shared Files`

Important:

- use bridged overrides only for diagnostics or when you specifically need host-network reachability
- daemon `ipAddress` and `sshAvailable` were historically unreliable on the bridged path
- if you need the exact bridged-diagnostics commands, use [lume-recreate-runbook.md](./lume-recreate-runbook.md)

### Automated real-host smoke

Use the new host-backed automation path when you want a reproducible real-Lume run without driving the UI manually:

```bash
./scripts/lume-host-preflight.sh
./scripts/lume-host-macos-smoke.sh
```

Or with `mise`:

```bash
mise run dev-lume-preflight
mise run dev-lume-macos-smoke
```

The smoke path:

- runs the standalone Lume validation gate first
- reuses the current validated-base manifest when it is already `ready`
- launches the debug app only
- uses a dedicated isolated data dir
- imports a disposable git repo into the app
- triggers the real `macOS VM` creation path
- auto-confirms Lume setup or repair if needed
- waits for `workspace_active`
- runs a host-side `lume ssh <vmName>` probe
- cleans up the disposable repo, workspace copy, and VM on success
- preserves all artifacts on failure

Artifacts are written to:

- `output/lume-host-smoke/latest`
- `output/lume-host-smoke/<timestamp>`

Each run includes:

- `events.jsonl`
- `launch.log`
- `detached-launch.log`
- `01-launch.png`
- `02-final.png`
- `lume_daemon.log`
- `lume_daemon.error.log`
- `ssh-probe.txt`
- `summary.md`

`detached-launch.log` is copied from the exact `lume run` invocation used to boot the VM.

Current passing host-smoke bundle:

- `output/lume-host-smoke/20260311-193844`

### Aggregate PR validation

Use the aggregate validator when you want one top-level bundle for the whole PR story:

```bash
./scripts/lume-pr-validation.sh \
  --standalone-run-dir output/lume-standalone/20260311-182619 \
  --poll-seconds 5
```

Current passing aggregate bundle:

- `output/lume-pr-validation/20260311-194047`

### Preparing PR evidence

Once a host-smoke bundle has passed, use the prep helper to package the exact
files you need for the PR discussion:

```bash
./scripts/lume-pr-evidence-prep.sh --pr 123
```

Or target a specific host-smoke run explicitly:

```bash
./scripts/lume-pr-evidence-prep.sh \
  --pr 123 \
  --host-smoke-dir output/lume-host-smoke/20260317-200226
```

The script verifies the bundle is complete, then writes:

- `pr-<number>-evidence-comment.md` — ready-to-paste PR comment text
- `pr-<number>-evidence.zip` — screenshots plus the supporting logs
- `pr-<number>-evidence-README.md` — semi-manual upload steps

Semi-manual upload flow:

1. Open the PR in GitHub.
2. Paste the generated comment into a new PR comment.
3. Drag `01-launch.png`, `02-final.png`, and the generated zip into that comment.
4. Copy the resulting attachment URLs into the PR body's `Evidence links:` section.
5. Clear `Blocked on evidence` once the PR itself contains the uploaded files.

Automation launch note:

- `lume-host-preflight.sh` and `lume-host-macos-smoke.sh` now foreground the app by default for deterministic event capture
- use `./scripts/lume-host-preflight.sh --no-activate` only when you intentionally need shared-desktop-safe behavior and accept that the visible-window check may be less reliable

### Host prerequisites

- Apple Silicon Mac
- `xcodebuild -version` returns the host Xcode version
- `sw_vers -productVersion` returns the host macOS version
- the default macOS golden image exists for the same macOS family

### Current host-profile rule

The app resolves a default macOS image from the detected host profile:

- same macOS family first
- exact Xcode match when available
- nearest Xcode match within the same family otherwise

If no image exists for the same macOS family, macOS VM creation should fail clearly and the user should be directed to `Linux VM` instead.

### Manual flow

1. Build and launch the debug app:

```bash
./scripts/build-ghosttykit.sh
swift build
./scripts/launch-dev.sh --no-build --no-activate
```

2. In the app, open `New Workspace`.
3. Choose `macOS VM`.
4. Verify the sheet shows the host-matched default image.
5. Click `Create`.
6. If setup is required, confirm `Install Lume and Continue`.
7. Wait for the setup progress sheet to finish and for the action to resume automatically.
8. Verify the workspace transitions from `provisioning` to `active`.
9. Open terminal for the workspace and confirm it attaches with `lume ssh`.
10. Use `Open Desktop` and confirm the external VNC client opens.

### What to verify in-app

- Settings shows a `VM Runtime` section
- runtime status becomes `Ready`
- host profile is visible
- the resolved default image is visible
- `Verify`, `Repair`, and `Reinstall` actions are available

### Useful checks

```bash
ps aux | rg '.build/arm64-apple-macosx/debug/WorkspaceManager'
ls -la output/lume-e2e/latest
```

If the Lume daemon is installed, these are also useful:

```bash
~/.local/bin/lume version
launchctl list | rg lume
```

## Troubleshooting

### Fixture screenshots captured the wrong app or desktop content

Use `./scripts/lume-e2e-capture.sh`. It captures by CoreGraphics window id and is the supported path for PR evidence.

Do not rely on ad hoc `screencapture -R ...` region captures for this flow.

For the lighter `dev-smoke` startup check, the current behavior is:

- try window-only capture first
- fall back to a full-screen screenshot if CoreGraphics window capture flakes on this host

That fallback is acceptable for startup evidence and does not invalidate the Lume runtime results.

### `macOS VM` does not appear ready

Check:

- Apple Silicon host
- runtime status in Settings
- `Setup required` vs `Repair required`
- host-profile image resolution

### Real-host validation blocks before VM creation

Typical causes:

- `lume` is not installed yet
- LaunchAgent is missing or not loaded
- daemon is not reachable on `localhost:7777`
- the host-matched golden image is not published or not reachable

If what you actually need is to recreate the currently working base+clone path, do not start here. Use [lume-recreate-runbook.md](./lume-recreate-runbook.md) and the dedicated daemon on port `7778`.

### `GET /lume/vms/:name` fails for a VM in custom storage, but CLI `lume get --storage ...` works

Current known behavior on this host:

- daemon-side lookup against Workspaces-managed custom storage can return HTTP 400 even when the VM is healthy
- CLI `lume get --storage ... -f json` is the trusted fallback

Workspaces now falls back to the CLI path in both the runtime service and the provider.

### Daemon says the guest has no IP, but manual SSH works

Current known behavior on this host:

- some bridged runs, especially disposable clone proof runs, have shown `ipAddress: null` and `sshAvailable: null` from the daemon
- the guest can still be healthy and reachable by direct SSH

Treat this as a daemon-detection gap unless both of these fail:

- guest-side `ipconfig getifaddr en0`
- direct SSH to the bridged guest IP

### Host smoke fails with "maximum supported number of active virtual machines has been reached"

Cause:

- stale `workspaces-lume-smoke-*` VMs are still running in validated-base storage

What to do:

- stop/delete those stale smoke VMs
- rerun the host smoke

The current host smoke script now performs that cleanup automatically before each run.

### LaunchAgent is missing, but the daemon is reachable and `lume` commands work

Current rule:

- do not treat that as a hard runtime failure by itself
- if the binary exists and the daemon is reachable, the runtime is usable

Workspaces now reports this as a warning condition instead of blocking the Lume flow.

### Need logs

For fixture runs:

- `output/lume-e2e/<timestamp>/run.log`
- `output/lume-e2e/<timestamp>/app-output-final.log`

For real-host runtime troubleshooting, the app surfaces:

- `/tmp/lume_daemon.log`
- `/tmp/lume_daemon.error.log`

## Files To Remember

- script: `scripts/lume-e2e-capture.sh`
- script: `scripts/lume-host-preflight.sh`
- script: `scripts/lume-host-macos-smoke.sh`
- architecture overview: `docs/vm-provider-architecture.md`
- exact from-scratch workaround: `docs/development/lume-recreate-runbook.md`
- Daytona background: `docs/daytona-vm.md`
- terminal verification runbook: `docs/development/libghostty-integration.md`
