# Lume Recreate-From-Scratch Runbook

This is the practical runbook for recreating the current known-good Lume macOS VM flow on this Mac from scratch.

Use this when you need to:

- rebuild confidence in the Lume runtime without involving the Swift app
- recreate the validated base VM from zero
- prove the fast clone path still works
- diagnose whether a failure belongs to Lume runtime behavior, guest setup, or Workspaces integration

For the high-level contract, see [lume-integration.md](./lume-integration.md). For the broader validation modes, see [lume-validation.md](./lume-validation.md).

## Use This Order

If you are starting a fresh investigation, use this sequence:

1. verify the official installed Lume runtime and entitlements
2. start the dedicated official daemon on port `7778`
3. run the standalone validator once
4. if the validator is red but you need to prove the runtime manually, use the bridged-network manual recovery path in this document
5. only after the standalone path is understood should you return to the Swift app smoke

This keeps three different problems separate:

- Lume install / entitlement problems
- guest networking / SSH problems
- Workspaces integration problems

## Current Known-Good Outcome

The currently proven path is:

1. Prepare or recover the Tahoe base VM in Workspaces-managed storage.
2. Run the base through the official signed Lume daemon.
3. Use a bridged network override at runtime.
4. Enable `Remote Login` in the guest through System Settings.
5. Verify direct SSH to the base.
6. Clone the base, boot the clone, and verify direct SSH plus shared-directory visibility.

Important:

- The guest is usable on this path.
- Lume daemon `GET /lume/vms/:name` may still report `ipAddress: null` and `sshAvailable: null` for bridged clones even when the guest is healthy.
- Treat bridged-mode guest SSH as the source of truth when reproducing this specific path.

Current green commands:

- `mise run dev-lume-standalone-validate`
- `mise run dev-lume-macos-smoke -- --no-build`

## How It Works

```text
official signed Lume daemon
-> boot base VM from Workspaces storage
-> bridged network override at runtime
-> guest gets LAN IP
-> enable Remote Login in guest
-> verify direct SSH
-> clone base
-> verify clone SSH + shared-dir
```

Why this matters:

- NAT on this host repeatedly produced only link-local `169.254.x.x` guest addresses.
- The official signed Lume binary is still the correct runtime surface, but NAT alone was not enough.
- Bridged networking was the first path that yielded stable guest IPs and successful SSH.

## Clean-Slate Reset

Use this when you need to recreate the working path from zero without deleting evidence outright.

Move the existing base and manifest aside instead of removing them:

```bash
STAMP="$(date +%Y%m%d-%H%M%S)"
QUARANTINE="$HOME/Library/Application Support/WorkspaceManager/LumeQuarantine/$STAMP"
mkdir -p "$QUARANTINE"

mv \
  "$HOME/Library/Application Support/WorkspaceManager/LumeValidatedBases/workspaces-validated-base-macos-tahoe-26-2-xcode-26-2.json" \
  "$QUARANTINE/" 2>/dev/null || true

mv \
  "$HOME/Library/Application Support/WorkspaceManager/LumeStorage/validated-bases/workspaces-validated-base-macos-tahoe-26-2-xcode-26-2" \
  "$QUARANTINE/" 2>/dev/null || true
```

Then clear any old standalone smoke clones the same way if they are still present:

```bash
find \
  "$HOME/Library/Application Support/WorkspaceManager/LumeStorage/standalone-smoke" \
  -maxdepth 1 \
  -name 'workspaces-validated-clone-smoke-*' \
  -exec mv {} "$QUARANTINE/" \; 2>/dev/null || true
```

If a dedicated investigation daemon is still running, stop it before recreating:

```bash
tmux kill-session -t codex-lume-daemon-official 2>/dev/null || true
```

## Storage And Names

Workspaces-managed Lume storage:

- validated bases:
  - `~/Library/Application Support/WorkspaceManager/LumeStorage/validated-bases`
- standalone smoke clones:
  - `~/Library/Application Support/WorkspaceManager/LumeStorage/standalone-smoke`
- app-created workspace VMs:
  - `~/Library/Application Support/WorkspaceManager/LumeStorage/workspace-vms`

Canonical base VM name on this host:

- `workspaces-validated-base-macos-tahoe-26-2-xcode-26-2`

## Prerequisites

- Apple Silicon Mac
- official Lume install under:
  - `~/.local/bin/lume`
  - `~/.local/share/lume/lume.app/Contents/MacOS/lume`
- isolated Workspaces Lume storage exists
- Screen Recording / Accessibility if you need live VNC automation

## Fast Decision Tree

```text
Need a clean proof from zero?
-> run standalone validator

Standalone validator passes?
-> use the validated base and continue to clone smoke or app smoke

Standalone validator fails, but guest is expected to be mostly installed?
-> switch to the manual bridged run path in this doc

Manual bridged path fails before guest login?
-> debug Lume runtime / unattended setup

Manual bridged path succeeds but app smoke fails?
-> debug Workspaces integration, not Lume
```

## Step 1: Verify The Official Runtime

Do not start from a raw SwiftPM build when recreating the working path.

Check the installed runtime:

```bash
~/.local/bin/lume --version
codesign -d --entitlements :- ~/.local/share/lume/lume.app/Contents/MacOS/lume 2>/dev/null
```

You want to see both:

- `com.apple.security.virtualization`
- `com.apple.vm.networking`

Why:

- the raw directly runnable upstream build on this Mac repeatedly behaved differently
- the official installed app binary is the runtime that successfully produced bridged, SSH-reachable guests

## Step 2: Start A Dedicated Official Daemon

Use a separate port so this investigation does not interfere with the normal Workspaces daemon:

```bash
tmux new-session -d -s codex-lume-daemon-official \
  "cd /Users/fairchild/.codex/worktrees/55bd/workspaces && \
   ~/.local/bin/lume serve --port 7778 2>&1 | tee '.dev-data/logs/codex-lume-daemon-official.log'"
```

Verify:

```bash
lsof -nP -iTCP:7778 -sTCP:LISTEN
```

## Step 3: Get The Base Into A Login-Capable State

If you are starting from zero, first run the standalone validator:

```bash
mise run dev-lume-standalone-validate
```

If the validator stalls during Tahoe setup, the useful artifacts are:

- `output/lume-standalone/<timestamp>/summary.md`
- `output/lume-standalone/<timestamp>/status.json`
- `output/lume-standalone/<timestamp>/unattended-debug/`

Current useful helper profile for post-setup guest recovery:

- `config/lume/unattended/tahoe-workspaces-v18-official-run-bootstrap-ssh.yml`

Current full-flow Tahoe override used by standalone rebuilds:

- `config/lume/unattended/tahoe-workspaces-v23.yml`

That profile is a resume helper, not the full stock-install preset. It assumes the guest can already reach the login screen and Terminal.

If the standalone validator is already green, skip ahead to [Step 4](#step-4-run-the-base-with-bridged-networking). You do not need to recreate the base again just to repro the known-good path.

## Step 4: Run The Base With Bridged Networking

Stop any existing run first:

```bash
curl -sS -X POST \
  'http://127.0.0.1:7778/lume/vms/workspaces-validated-base-macos-tahoe-26-2-xcode-26-2/stop' \
  -H 'Content-Type: application/json' \
  --data '{"storage":"/Users/fairchild/Library/Application Support/WorkspaceManager/LumeStorage/validated-bases"}'
```

Then run with an explicit bridged override:

```bash
curl -sS --json '{
  "storage":"/Users/fairchild/Library/Application Support/WorkspaceManager/LumeStorage/validated-bases",
  "noDisplay":true,
  "network":"bridged:en0"
}' \
  'http://127.0.0.1:7778/lume/vms/workspaces-validated-base-macos-tahoe-26-2-xcode-26-2/run'
```

Notes:

- `en0` is the known-good interface on this host.
- Lume may still report `"networkMode":"nat"` in `GET /lume/vms/:name`; that reflects persisted config more than effective runtime override.
- If the daemon returns `ipAddress: null` here, keep going. That is not enough to call the guest unhealthy on this bridged path.

## Step 5: Log In Over VNC And Enable Remote Login

Poll until the daemon returns a VNC URL:

```bash
curl -sS \
  'http://127.0.0.1:7778/lume/vms/workspaces-validated-base-macos-tahoe-26-2-xcode-26-2?storage=%2FUsers%2Ffairchild%2FLibrary%2FApplication%20Support%2FWorkspaceManager%2FLumeStorage%2Fvalidated-bases'
```

Once you have a `vncUrl`, use `vncdo` or a VNC client to:

1. log in as `lume`
2. open `System Settings`
3. search for `remote login`
4. open `Sharing`
5. toggle `Remote Login` on
6. if prompted, confirm the dialog
7. optionally open Terminal and run `ipconfig getifaddr en0`

Expected result:

- `Remote Login: On` is visible in the dialog or Sharing pane
- `ipconfig getifaddr en0` prints a LAN IP, not `169.254.x.x`
- if `ipconfig getifaddr en0` is blank, do not keep debugging the app; the guest itself is not network-ready yet

Observed credentials during manual recovery:

- VNC / guest login user: `lume`
- guest password: `lume`

Evidence for the working GUI path:

- `/Users/fairchild/.codex/worktrees/55bd/workspaces/output/lume-standalone/20260311-101900-open-system-settings/03-opened.png`
- `/Users/fairchild/.codex/worktrees/55bd/workspaces/output/lume-standalone/20260311-103000-settings-search-click2/03-typed.png`
- `/Users/fairchild/.codex/worktrees/55bd/workspaces/output/lume-standalone/20260311-103400-settings-remote-login-click/02-after-click.png`
- `/Users/fairchild/.codex/worktrees/55bd/workspaces/output/lume-standalone/20260311-104000-remote-login-toggle/00-start.png`
- `/Users/fairchild/.codex/worktrees/55bd/workspaces/output/lume-standalone/20260311-104000-remote-login-toggle/01-after-toggle.png`

## Step 6: Verify The Base Over SSH

Known-good command:

```bash
~/.local/bin/lume ssh workspaces-validated-base-macos-tahoe-26-2-xcode-26-2 \
  'echo BASE_OK && whoami && hostname && ipconfig getifaddr en0' \
  --user lume \
  --password lume \
  --storage '/Users/fairchild/Library/Application Support/WorkspaceManager/LumeStorage/validated-bases'
```

Expected:

- `BASE_OK`
- `lume`
- guest hostname
- bridged guest IP

## Step 7: Verify The Fast Clone Path

Create a disposable clone and a temp shared directory:

```bash
CLONE="workspaces-validated-clone-smoke-$(date +%Y%m%d-%H%M%S)"
SHARE="/tmp/workspaces-lume-shared-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$SHARE"
printf 'clone-shared-ok\n' > "$SHARE/marker.txt"
```

Clone the base:

```bash
curl -sS --json "{
  \"name\":\"workspaces-validated-base-macos-tahoe-26-2-xcode-26-2\",
  \"newName\":\"$CLONE\",
  \"sourceLocation\":\"/Users/fairchild/Library/Application Support/WorkspaceManager/LumeStorage/validated-bases\",
  \"destLocation\":\"/Users/fairchild/Library/Application Support/WorkspaceManager/LumeStorage/validated-bases\"
}" \
  'http://127.0.0.1:7778/lume/vms/clone'
```

Run the clone:

```bash
curl -sS --json "{
  \"storage\":\"/Users/fairchild/Library/Application Support/WorkspaceManager/LumeStorage/validated-bases\",
  \"noDisplay\":true,
  \"network\":\"bridged:en0\",
  \"sharedDirectories\":[
    {\"hostPath\":\"$SHARE\",\"readOnly\":false}
  ]
}" \
  "http://127.0.0.1:7778/lume/vms/$CLONE/run"
```

Then:

1. log in over VNC if needed
2. run `ipconfig getifaddr en0` in guest Terminal
3. SSH directly to that bridged IP if daemon-side `ipAddress` is still null

Known-good direct SSH proof:

```bash
python3 - <<'PY'
import paramiko

host = "REPLACE_WITH_CLONE_IP"
user = "lume"
password = "lume"
cmd = 'echo CLONE_OK && whoami && hostname && ipconfig getifaddr en0 && ls "/Volumes/My Shared Files" && cat "/Volumes/My Shared Files/marker.txt"'

client = paramiko.SSHClient()
client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
client.connect(hostname=host, username=user, password=password, timeout=20)
stdin, stdout, stderr = client.exec_command(cmd, timeout=30)
print(stdout.read().decode())
print(stderr.read().decode())
client.close()
PY
```

Expected:

- `CLONE_OK`
- `lume`
- clone guest hostname
- bridged guest IP
- `marker.txt`
- `clone-shared-ok`

## Cleanup

Stop and delete the clone:

```bash
curl -sS -X POST \
  "http://127.0.0.1:7778/lume/vms/$CLONE/stop" \
  -H 'Content-Type: application/json' \
  --data '{"storage":"/Users/fairchild/Library/Application Support/WorkspaceManager/LumeStorage/validated-bases"}'

curl -sS -X DELETE \
  "http://127.0.0.1:7778/lume/vms/$CLONE?storage=%2FUsers%2Ffairchild%2FLibrary%2FApplication%20Support%2FWorkspaceManager%2FLumeStorage%2Fvalidated-bases"
```

Then remove the temp shared directory manually.

## Evidence To Capture

When recreating from scratch, capture these before changing anything else:

- standalone artifact bundle:
  - `output/lume-standalone/<timestamp>/summary.md`
  - `output/lume-standalone/<timestamp>/status.json`
- daemon log for the dedicated investigation daemon:
  - `.dev-data/logs/codex-lume-daemon-official.log`
- guest-side VNC screenshots if you used manual recovery
- base SSH output
- clone SSH output

This is the minimum set that lets a future session tell whether the failure was:

- install / entitlement
- unattended setup
- networking
- daemon state reporting
- or Workspaces integration

## Troubleshooting

### Symptom: raw upstream `lume` behaves differently from the installed binary

Cause:

- local source-build signing and entitlements are different enough on this Mac to change runtime behavior

What to do:

- use the official installed app binary for runtime recreation
- use a separate official daemon on port `7778`

### Symptom: `ipconfig getifaddr en0` prints `169.254.x.x`

Cause:

- guest is only getting a link-local address
- NAT is not producing a usable DHCP lease on this host for this flow

What to do:

- stop the VM
- rerun it with `network: "bridged:en0"`
- recheck guest IP from inside Terminal

### Symptom: `systemsetup -setremotelogin on` fails

Observed behavior on Tahoe:

- it requires Full Disk Access privileges

What to do:

- do not use `systemsetup`
- use the GUI `System Settings -> Sharing -> Remote Login` path instead

### Symptom: `launchctl load -w /System/Library/LaunchDaemons/ssh.plist` or `launchctl bootstrap` fails

Observed behavior on Tahoe:

- `Bootstrap failed: 5: Input/output error`

What to do:

- treat that as a guest-policy / permissions failure on this host
- switch to the GUI `Remote Login` path instead

### Symptom: daemon says `ipAddress: null` and `sshAvailable: null`, but the guest looks fine

Cause:

- bridged-mode detection is currently incomplete or stale in daemon status reporting

What to do:

- treat guest-side `ipconfig getifaddr en0` as authoritative
- verify with direct SSH to the bridged guest IP
- do not treat `null` daemon IP as immediate proof of guest failure on this path

### Symptom: daemon `GET /lume/vms/:name` fails for a VM in Workspaces-managed storage

Cause:

- daemon-side lookup against custom storage can fail on this host even when the VM is healthy

What to do:

- use CLI fallback:

```bash
~/.local/bin/lume get workspaces-validated-base-macos-tahoe-26-2-xcode-26-2 \
  --storage '/Users/fairchild/Library/Application Support/WorkspaceManager/LumeStorage/validated-bases' \
  -f json
```

- trust CLI `get`, guest-side IP checks, and direct SSH over daemon 400 responses on this path

### Symptom: you need to prove the clone path, not just the base

What to do:

- create a disposable clone from the validated base
- run it with:
  - `network: "bridged:en0"`
  - a temp shared directory
- prove all of these:
  - guest gets a LAN IP
  - direct SSH works
  - `/Volumes/My Shared Files` is mounted
  - the marker file is readable in the guest

### Symptom: host smoke fails because the active-VM limit has been reached

Cause:

- stale `workspaces-lume-smoke-*` clones are still running in validated-base storage

What to do:

- stop and delete the stale smoke VMs before rerunning
- the current host smoke script now performs this cleanup automatically, but manual recovery should do it explicitly if you are bypassing the script

### Symptom: standalone validator is red, but the manual bridged path works

Cause:

- the validator still relies too heavily on daemon-side IP / SSH status
- or the validator has not yet reproduced the bridged workaround path cleanly

What to do:

- record the manual proof as the runtime source of truth
- treat the problem as a validator gap, not a proof that the guest is unusable
- use this runbook to capture exact base SSH and clone SSH evidence

### Symptom: the LaunchAgent is missing, but `lume` commands still work and the daemon is reachable

Cause:

- local upstream testing or installer cleanup can unload the normal LaunchAgent without actually breaking the current daemon

What to do:

- do not treat that as fatal by itself
- if the binary exists and the daemon is reachable, continue validation
- restore the LaunchAgent later as cleanup, not as the first debugging step

### Symptom: official daemon on `7778` is not running after local upstream testing

Cause:

- `install-local.sh --no-background-service` may unload the normal LaunchAgent while cleaning up a local test install

What to do:

- restart the dedicated investigation daemon manually:

```bash
tmux new-session -d -s codex-lume-daemon-official \
  "cd /Users/fairchild/.codex/worktrees/55bd/workspaces && \
   ~/.local/bin/lume serve --port 7778 2>&1 | tee '.dev-data/logs/codex-lume-daemon-official.log'"
```

- if you are finished with upstream testing, restore the normal daemon / LaunchAgent before returning to app validation

### Symptom: `GET /lume/vms/:name` shows `"networkMode":"nat"` during a working bridged run

Cause:

- the response appears to reflect saved VM config more than the effective runtime override

What to do:

- trust the effective signals instead:
  - guest-side `ipconfig getifaddr en0`
  - successful SSH
  - visible shared-directory mount in the clone

### Symptom: clone looks stuck at the login screen after password entry

Observed behavior:

- clone may sit on an intermediate post-password screen before restoring the desktop

What to do:

- wait longer before concluding failure
- then recapture the screen
- once Terminal is visible, run a simple focus sentinel like:
  - `echo clonecheck`

### Symptom: VNC automation appears to do nothing

Cause:

- Terminal content area is not focused

What to do:

- click inside the Terminal pane before typing
- send a sentinel command such as:
  - `echo sentinel`
- only then send the real guest-side commands

## What Still Needs To Be Fixed In Code

- The standalone validator and the Swift integration still trust daemon-side `ipAddress` and `sshAvailable` too much.
- The working path is now known, but it is not yet captured cleanly in one automated harness.
- The next implementation step should:
  - add bridged-mode runtime fallback to the standalone validator
  - add bridged-mode guest IP discovery when daemon `ipAddress` is null
  - teach clone validation to use direct SSH by discovered guest IP when the guest is clearly healthy
