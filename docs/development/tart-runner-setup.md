# Tart UI Runner Setup

Use this runbook to provision the dedicated `[self-hosted, tart-ui]` lane for UI and perf automation without touching the interactive desktop runner.

## Host prerequisites

- Tart installed on the host: `brew install cirruslabs/cli/tart`
- A Tart image with Xcode and the guest agent available locally:
  - preferred: `macos-tahoe-xcode`
- GitHub CLI authenticated against `fairchild/workspaces` with permission to create self-hosted runner registration tokens
- This repository available on the host filesystem so it can be shared into the guest

## 1. Clone and start the guest

```bash
REPO_ROOT=$(pwd)
TART_VM=workspaces-tart-ui
TART_BASE_VM=macos-tahoe-xcode
TART_LOG_DIR="${HOME}/.local/state/workspaces"
TART_LOG_PATH="${TART_LOG_DIR}/tart-ui-vm.launchd.log"
PLIST_PATH="${HOME}/Library/LaunchAgents/com.fairchild.workspaces.tart-ui-vm.plist"

mkdir -p "${TART_LOG_DIR}"
tart clone "${TART_BASE_VM}" "${TART_VM}" 2>/dev/null || true

cat > "${PLIST_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.fairchild.workspaces.tart-ui-vm</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/bin/tart</string>
    <string>run</string>
    <string>--no-graphics</string>
    <string>--net-bridged=en0</string>
    <string>${TART_VM}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>WorkingDirectory</key>
  <string>${HOME}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardOutPath</key>
  <string>${TART_LOG_PATH}</string>
  <key>StandardErrorPath</key>
  <string>${TART_LOG_PATH}</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)" "${PLIST_PATH}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "${PLIST_PATH}"
launchctl kickstart -k "gui/$(id -u)/com.fairchild.workspaces.tart-ui-vm"
```

Wait until the guest responds to `tart exec`:

```bash
until tart exec "${TART_VM}" sw_vers >/dev/null 2>&1; do
  sleep 5
done
```

## 2. Register the guest runner

Generate a one-time registration token on the host:

```bash
RUNNER_REGISTRATION_TOKEN=$(
  gh api -X POST repos/fairchild/workspaces/actions/runners/registration-token \
    --jq .token
)
```

Configure the runner inside the guest using the shared `scripts/runner.sh` helper:

```bash
tart exec "${TART_VM}" bash -lc "
  set -euo pipefail
  cd '/Volumes/My Shared Files/workspaces'
  export RUNNER_DIR=\"\$HOME/.local/share/actions-runner-tart-ui\"
  export RUNNER_NAME=\"tart-ui-\$(hostname -s)\"
  export RUNNER_LABELS='tart-ui'
  export RUNNER_REGISTRATION_TOKEN='${RUNNER_REGISTRATION_TOKEN}'
  ./scripts/runner.sh setup
  ./scripts/runner.sh service-install
  ./scripts/runner.sh service-start
  ./scripts/runner.sh service-status
"
```

The custom label should be `tart-ui` only. GitHub automatically adds the read-only `self-hosted`, `macOS`, and `ARM64` labels.

## 3. Verify the runner is online

```bash
gh api repos/fairchild/workspaces/actions/runners \
  --jq '.runners[] | {name, status, labels: [.labels[].name]}'
```

Confirm there is an online runner whose labels include `tart-ui`.

## 4. Dispatch the smoke workflow

The repo includes a manual smoke workflow at `.github/workflows/tart-ui-smoke.yml`.

Before the workflow lands on `main`, pushes to `codex/**` branches that touch the workflow or `scripts/runner.sh` will also trigger the smoke run so the lane can be validated pre-merge.

```bash
gh workflow run tart-ui-smoke.yml --ref <branch-with-workflow>
gh run watch --exit-status "$(gh run list --workflow tart-ui-smoke.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
```

The run should execute on `[self-hosted, tart-ui]` and print `sw_vers`, `swift --version`, and `xcodebuild -version`.

## Day-two operations

Restart the host-side Tart VM supervisor:

```bash
launchctl kickstart -k "gui/$(id -u)/com.fairchild.workspaces.tart-ui-vm"
```

Unload the host-side Tart VM supervisor:

```bash
launchctl bootout "gui/$(id -u)" "${HOME}/Library/LaunchAgents/com.fairchild.workspaces.tart-ui-vm.plist"
```

Check the guest-side service status:

```bash
tart exec "${TART_VM}" bash -lc "
  cd ~/.local/share/actions-runner-tart-ui
  ./svc.sh status
"
```

Stop the runner cleanly before deleting the VM:

```bash
tart exec "${TART_VM}" bash -lc "
  cd ~/.local/share/actions-runner-tart-ui
  ./svc.sh stop || true
"
tart stop "${TART_VM}" --timeout 30
```

If you need to re-register the guest, remove the old runner first from GitHub and rerun the registration steps above with a fresh registration token.
