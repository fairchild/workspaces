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
TART_LOG_PATH="${TART_LOG_DIR}/tart-ui-runner.log"

mkdir -p "${TART_LOG_DIR}"
tart clone "${TART_BASE_VM}" "${TART_VM}" 2>/dev/null || true

nohup tart run --no-graphics \
  --dir="workspaces:${REPO_ROOT}" \
  "${TART_VM}" > "${TART_LOG_PATH}" 2>&1 &
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

```bash
gh workflow run tart-ui-smoke.yml --ref <branch-with-workflow>
gh run watch --exit-status "$(gh run list --workflow tart-ui-smoke.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
```

The run should execute on `[self-hosted, tart-ui]` and print `sw_vers`, `swift --version`, and `xcodebuild -version`.

## Day-two operations

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
