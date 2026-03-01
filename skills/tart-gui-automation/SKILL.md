---
name: tart-gui-automation
description: Run deterministic GUI workflows in isolated Tart macOS VMs for projects where local desktop automation is unreliable. Use when Codex needs to start ephemeral VMs, automate app UI interactions over SSH, capture screenshots/video headlessly by default, optionally open VNC for live observation, and cleanly tear down VM and VNC sessions.
---

# Tart GUI Automation

Use the harness script for VM lifecycle and capture primitives:
- `scripts/tart_vm_harness.py`

Load setup details only when needed:
- `references/setup-and-target.md`

## Workflow

1. Start an ephemeral run VM (headless by default).
2. Discover the guest SSH host bound to the shared directory.
3. Run app-specific launch/click/assert commands over SSH.
4. Capture VNC frames and encode video artifacts.
5. Teardown in safe order: close VNC client first, then stop/delete VM.

## Commands

Run from the skill directory or call script by absolute path.

1. Start VM session (headless default):
```bash
uv run --script scripts/tart_vm_harness.py start \
  --base-vm sequoia-base \
  --share-name workspaces \
  --share-path /absolute/path/to/project
```

2. Start VM session with live VNC view:
```bash
uv run --script scripts/tart_vm_harness.py start \
  --base-vm sequoia-base \
  --share-name workspaces \
  --share-path /absolute/path/to/project \
  --open-vnc
```

3. Discover SSH host and persist it in `session.json`:
```bash
uv run --script scripts/tart_vm_harness.py discover-ssh \
  --session-file /path/to/session.json \
  --ssh-user admin \
  --ssh-password admin
```

4. Capture one frame:
```bash
uv run --script scripts/tart_vm_harness.py capture \
  --session-file /path/to/session.json \
  --output /path/to/frame-0001.png
```

5. Teardown (default closes Screen Sharing, stops VM, deletes VM):
```bash
uv run --script scripts/tart_vm_harness.py teardown \
  --session-file /path/to/session.json
```

## App-Specific Layer

Keep app behavior outside this skill and script it per project:
- launch command inside guest
- deterministic interactions (clicks, keys, or app-specific scripts)
- completion signal (log marker, text marker, or stable frame)
- artifact naming and output paths

## Guardrails

- Default to headless runs (`--no-open-vnc`).
- Use `--open-vnc` only for debugging or live walkthroughs.
- Always teardown ephemeral VMs after run unless explicitly preserving them.
- If VNC was opened, close VNC client before VM shutdown.
- Prefer one run VM per flow to avoid cross-run state leakage.
