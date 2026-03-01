# Tart GUI Automation Setup Reference

## 1) Host prerequisites

1. Install Tart on host:
   - `brew install cirruslabs/cli/tart`
2. Install media + automation helpers:
   - `brew install ffmpeg`
   - `brew install uv`
3. Verify networking interface for bridged mode:
   - `tart run --help` and use `--net-bridged=<interface>` (usually `en0`)

## 2) Base VM preparation

1. Pull or clone a base VM image (example):
   - `tart pull ghcr.io/cirruslabs/macos-sequoia-base:latest`
2. Boot base VM once and snapshot after provisioning.
3. Reuse the same base VM for repeatable automation.

## 3) Guest configuration (required)

1. Enable Remote Login (SSH) in guest System Settings.
2. Install guest tools:
   - `brew install cliclick`
   - Ensure `swift` is available if target app needs local build/run.
3. Grant Accessibility permission for the click driver binary used in guest
   (`cliclick` path inside guest).
4. Keep guest credentials stable for automation (for example `admin/admin` in
   isolated dev VMs).

## 4) Shared-folder and target setup

1. Run Tart with a shared directory:
   - `--dir <share-name>:<host-path>`
2. Confirm guest mount path:
   - `/Volumes/My Shared Files/<share-name>`
3. Update target automation commands for your app:
   - launch command
   - click coordinates or semantic selectors
   - expected completion signal (log line, DOM marker, visible text)

## 5) Headless-first execution policy

1. Default to headless runs:
   - do not open VNC viewer unless explicitly requested.
2. Use VNC only for live debugging / manual observation.
3. Capture evidence with frame grabs and encoded MP4 instead of keeping an
   interactive viewer open.

## 6) Cleanup order (important)

When VNC was opened, use this order:

1. Close VNC client session first (for macOS built-in viewer: quit Screen Sharing).
2. Stop VM (`tart stop <run-vm>`).
3. Delete ephemeral VM clone (`tart delete <run-vm>`) unless intentionally kept.

This prevents stale viewer sessions and reduces host resource leakage.

## 7) Reliability checklist

- Recreate ephemeral run VM from a known base for each run.
- Write a run-scoped `session.json` with VM name, VNC URL, log path, and SSH host.
- Retry VNC captures (`3-5` attempts).
- Use deterministic waits tied to observable state (logs/UI markers), not long fixed sleeps.
- Keep one active GUI workload per VM.
