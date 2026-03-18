# Lume Runner Setup

Use this runbook to provision the `[self-hosted, lume-macos]` runner lane inside a Lume macOS VM for agent workflows that need macOS capabilities (swift build/test, screenshots).

## Host prerequisites

- Lume CLI installed: `~/.local/bin/lume` (v0.2.85+)
- A validated Lume base VM with SSH and auto-login configured
  - Default: `workspaces-validated-base-macos-tahoe-26-2-xcode-26-2`
  - Stored in `~/Library/Application Support/WorkspaceManager/LumeStorage/validated-bases/`
- GitHub CLI authenticated against `fairchild/workspaces`

## 1. Clone the validated base

```bash
LUME_STORAGE="$HOME/Library/Application Support/WorkspaceManager/LumeStorage"
LUME_VM=workspaces-lume-runner

lume clone workspaces-validated-base-macos-tahoe-26-2-xcode-26-2 "$LUME_VM" \
  --source-storage "$LUME_STORAGE/validated-bases" \
  --dest-storage "$LUME_STORAGE/workspace-vms"
```

## 2. Boot the VM

```bash
lume run "$LUME_VM" \
  --storage "$LUME_STORAGE/workspace-vms" \
  --no-display &
```

Wait for SSH (the VM gets a bridged IP via DHCP — this takes 30–60 seconds):

```bash
for i in $(seq 1 12); do
  if lume ssh "$LUME_VM" "sw_vers" \
    --user lume --password lumesetup26 \
    --storage "$LUME_STORAGE/workspace-vms" \
    --timeout 10 2>/dev/null; then
    echo "SSH is up"
    break
  fi
  sleep 10
done
```

**Known issue**: `lume get` may show `ip: -` even when the VM is reachable. Wait the full 60 seconds — bridged IP discovery is slow but SSH works once the guest boots.

## 3. Register the runner

Generate a one-time registration token:

```bash
RUNNER_REGISTRATION_TOKEN=$(
  gh api -X POST repos/fairchild/workspaces/actions/runners/registration-token \
    --jq .token
)
```

Configure and start the runner inside the guest:

```bash
lume ssh "$LUME_VM" \
  --user lume --password lumesetup26 \
  --storage "$LUME_STORAGE/workspace-vms" \
  --timeout 120 \
  "bash -lc '
    set -euo pipefail
    RUNNER_DIR=\$HOME/.local/share/actions-runner-lume
    RUNNER_VERSION=2.332.0
    mkdir -p \$RUNNER_DIR
    curl -sL \"https://github.com/actions/runner/releases/download/v\${RUNNER_VERSION}/actions-runner-osx-arm64-\${RUNNER_VERSION}.tar.gz\" | tar xz -C \$RUNNER_DIR
    cd \$RUNNER_DIR
    ./config.sh \
      --url \"https://github.com/fairchild/workspaces\" \
      --token \"${RUNNER_REGISTRATION_TOKEN}\" \
      --name \"lume-runner\" \
      --labels \"lume-macos\" \
      --unattended \
      --replace
    ./svc.sh install
    ./svc.sh start
    sleep 3
    ./svc.sh status
  '"
```

## 4. Verify the runner is online

```bash
gh api repos/fairchild/workspaces/actions/runners \
  --jq '.runners[] | select(.labels[].name == "lume-macos") | {name, status}'
```

Confirm there is an online runner with `lume-macos` label.

## 5. Harden and install tools

Run this immediately after registration. It sets up passwordless sudo (required for CLT install and service management), disables macOS auto-updates (prevents silent OS upgrades that invalidate Xcode/CLT), and installs tools the agent needs.

```bash
lume ssh "$LUME_VM" \
  --user lume --password lumesetup26 \
  --storage "$LUME_STORAGE/workspace-vms" \
  --timeout 300 \
  "bash -lc '
    set -euo pipefail

    # Passwordless sudo (required — lume ssh has no TTY for password prompts)
    echo \"lumesetup26\" | sudo -S bash -c \"echo \\\"lume ALL=(ALL) NOPASSWD:ALL\\\" > /etc/sudoers.d/lume\"

    # Disable all automatic macOS updates
    sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false
    sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
    sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false

    # Install Homebrew + gh CLI
    NONINTERACTIVE=1 /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"
    eval \"\$(/opt/homebrew/bin/brew shellenv)\"
    brew install gh

    # Install uv (Python package manager for agent scripts)
    curl -LsSf https://astral.sh/uv/install.sh | sh

    # Install Xcode CLT if missing (common after OS auto-update invalidated the base Xcode)
    if ! xcode-select -p &>/dev/null; then
      CLT_LABEL=\"Command Line Tools for Xcode \$(sw_vers -productVersion | cut -d. -f1)-\$(sw_vers -productVersion | cut -d. -f1-2)\"
      echo \"Installing: \$CLT_LABEL\"
      sudo softwareupdate -i \"\$CLT_LABEL\" --verbose
    fi

    echo \"Done. Verifying...\"
    swift --version 2>&1 | head -1
    git --version
    /opt/homebrew/bin/gh --version | head -1
    \$HOME/.local/bin/uv --version
    sudo -n true && echo \"sudo: passwordless\"
  '"
```

## Day-two operations

Check guest-side runner status:

```bash
lume ssh "$LUME_VM" \
  --user lume --password lumesetup26 \
  --storage "$LUME_STORAGE/workspace-vms" \
  --timeout 10 \
  "bash -lc 'cd ~/.local/share/actions-runner-lume && ./svc.sh status'"
```

Restart the runner:

```bash
lume ssh "$LUME_VM" \
  --user lume --password lumesetup26 \
  --storage "$LUME_STORAGE/workspace-vms" \
  --timeout 30 \
  "bash -lc 'cd \$HOME/.local/share/actions-runner-lume && ./svc.sh stop && ./svc.sh start'"
```

Stop the VM:

```bash
lume stop "$LUME_VM" --storage "$LUME_STORAGE/workspace-vms"
```

Re-register after token expiry:

```bash
# Get fresh token, then inside guest:
cd ~/.local/share/actions-runner-lume
./config.sh remove --token <REMOVAL_TOKEN>
# Re-run step 3
```

## Troubleshooting

### `lume get` shows `ip: -` but the VM is running

This is the most common issue. The Lume daemon's bridged-mode IP discovery is slow and sometimes never reports an IP at all. The VM is usually fine — it just takes 30–60 seconds for the guest to get a DHCP lease on `en0`.

**What to do**: Wait. The SSH retry loop in step 2 handles this. If SSH still fails after 2 minutes, check the ARP table:

```bash
arp -a | grep bridge100
```

The VM's MAC will be on `vmenet0` attached to `bridge100`. You can also open VNC to see the guest desktop (the VNC URL is shown by `lume get`).

### `lume ssh` says "no IP address" but you know the VM has one

`lume ssh` depends on `lume get` for IP discovery. If the daemon doesn't report an IP, `lume ssh` refuses to connect. Fall back to direct SSH:

```bash
ssh -o StrictHostKeyChecking=no lume@<IP_FROM_ARP>
```

Password: `lumesetup26`

### Clone boots but SSH is refused on all IPs

The validated base has Remote Login enabled, but if the guest OS auto-updated, SSH may need re-enabling. Connect via VNC and toggle Remote Login in System Settings > General > Sharing.

To prevent this: disable auto-updates immediately after provisioning (see "Post-provision hardening" above).

### `sudo` fails with "a terminal is required to read the password"

`lume ssh` does not allocate a TTY by default. Two workarounds:

1. **Set up passwordless sudo first** via direct SSH with `-t`:
   ```bash
   ssh -t lume@<VM_IP>
   # then: echo 'lumesetup26' | sudo -S bash -c 'echo "lume ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/lume'
   ```

2. **Use expect** for non-interactive sudo:
   ```bash
   /usr/bin/expect <<'EXPECT'
   spawn ssh -t lume@<VM_IP>
   expect "assword"
   send "lumesetup26\r"
   expect "%"
   send "echo 'lumesetup26' | sudo -S <command>\r"
   expect "%"
   send "exit\r"
   expect eof
   EXPECT
   ```

### Xcode CLT prompt appears on GUI login

Even after installing CLT via `softwareupdate`, macOS may still show a "developer tools required" dialog on first GUI login. This is cosmetic — CLT is installed and `swift` works from the terminal. Click "Install" to dismiss, or ignore it.

This happens because the validated base's Xcode.app was invalidated by a macOS auto-update. The CLT we install via SSH is sufficient for `swift build` and `swift test`.

### Runner goes offline after CLT or Homebrew install

Large installs can temporarily interrupt the runner's network connection to GitHub. Restart the runner:

```bash
lume ssh "$LUME_VM" ... "bash -lc 'pkill -f Runner.Listener; cd ~/.local/share/actions-runner-lume && nohup ./run.sh > runner.log 2>&1 &'"
```

### Cloning from a bridged base and booting with NAT doesn't work

The clone inherits `networkMode: "bridged:en0"` from the base config. Editing `config.json` to change to `nat` doesn't reliably work — the guest's network interface was configured for bridged during initial setup and may not negotiate NAT correctly.

**Recommendation**: Keep the same network mode as the base. If you need NAT, create a fresh VM with `lume create` and run `lume setup --unattended` with the NAT config (`tahoe-workspaces-v26.yml`).

### Fresh IPSW install fails partway through

`lume create --ipsw latest` occasionally fails with "RestoreOS device removed before restored completed" (Apple Virtualization Framework error). This is intermittent. Retry — the IPSW is cached locally after the first download.

### Unattended setup fails at "Data & Privacy"

The v26 NAT config has network panes ("How Do You Connect?", "Your Internet Connection") that require the guest to have network connectivity before proceeding. If the NAT network isn't ready when the automation clicks "Continue", the next screen never appears.

**Workaround**: Use the bridged config (`tahoe-workspaces-bridged-v27.yml`) which skips network panes entirely. Or increase the delay before the "Data & Privacy" wait step.

## Runner persistence

The runner is installed as a launchd LaunchAgent (`actions.runner.fairchild-workspaces.lume-runner`). It auto-starts when the `lume` user logs in, which happens automatically via auto-login on boot.

Check service status:

```bash
lume ssh "$LUME_VM" ... "bash -lc 'cd ~/.local/share/actions-runner-lume && ./svc.sh status'"
```

Restart the service:

```bash
lume ssh "$LUME_VM" ... "bash -lc 'cd ~/.local/share/actions-runner-lume && ./svc.sh stop && ./svc.sh start'"
```

## Credentials

| Item | Value |
|------|-------|
| Guest user | `lume` |
| Guest password | `lumesetup26` |
| Runner dir | `~/.local/share/actions-runner-lume` |
| Runner label | `lume-macos` |
| Network | `bridged:en0` |
