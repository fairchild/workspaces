# Self-Hosted Runner Policy

Use this policy to decide which runners are allowed to stay online by default.

## Default steady state

- The preferred default runner is the `lume-macos` guest runner (`lume-runner`) inside the dedicated Lume VM.
- Host-local runners on the interactive desktop stay stopped by default.
- `signing-host` and `tart-ui` on the local host are opt-in lanes, not ambient background services.

## When host-local runners are allowed

Start host-local runners only for short-lived, explicit tasks such as:

- recovering a blocked `lume-macos` CI queue
- performing release signing or notarization on an approved host
- running `tart-ui` automation on the current machine by explicit choice

If a host-local runner is started for one of those cases, treat it as temporary capacity.

## Shutdown rule

- Stop host-local runners as soon as the targeted jobs finish.
- Do not leave fallback host runners running in the background "just in case".

Examples:

```bash
RUNNER_DIR="$HOME/.local/share/actions-runner-workspaces-lume-host-5" \
  ./scripts/runner.sh service-stop
```

```bash
RUNNER_DIR="$HOME/.local/share/actions-runner-workspaces" \
  ./scripts/runner.sh service-stop
```

## Registration hygiene

- Prefer a fresh runner name and directory for temporary host fallback capacity.
- Do not keep reusing stale local host runner directories that have shown `offline while busy`, session conflicts, or partial self-update behavior.
- Once the temporary runner is no longer needed, stop it and leave it out of the normal background set.

## Security posture

- A running host-local runner increases local exposure on the interactive machine.
- The repo default should therefore be "Lume guest by default, host-local by explicit opt-in".
