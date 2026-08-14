# Recovery Order

Use this order when a self-hosted lane is stuck.

## 1. Confirm what is actually blocked

Run:

```bash
uv run --script .agents/skills/self-hosted-runners/scripts/summarize_runner_state.py
```

Questions to answer first:

- Which queued or failed run matters right now?
- Which labels does that job require?
- Which runners advertise those labels right now?

## 2. Confirm the job targets a lane that still exists

No lane does. Every workflow runs hosted, so any job waiting on a self-hosted
label is a workflow bug — fix the workflow rather than standing hardware back up.
`lume-macos`, `tart-ui`, and `signing-host` are all retired, no runner is
registered, and `.github/actionlint.yaml` allows no self-hosted label, so a job
that somehow reaches one waits forever on hardware that does not exist.

For a fuller local picture than `summarize_runner_state.py` gives:

```bash
./scripts/runners.py
```

It reconciles local runner config, launchd, and GitHub registration, and reports
`dead` when launchd has permanently given up on a runner.

## 3. Re-register stale runners instead of poking blindly

If the logs say the registration was deleted, do not just restart the listener. Re-register it with a fresh token.

GitHub deletes registrations for runners that have not connected recently, so an
idle lane can die on its own and stay dead — launchd logs `no retry needed` and
never restarts it.

## 4. Verify build readiness before rerunning CI

If `signing-host` is being re-provisioned, verify on the new host:

- the runner service can start
- `xcodebuild -version` works
- `xcode-select -p` points at a real Xcode app

If those fail, do not point a release at that host.

## 5. Use a fresh host runner rather than salvaging a strange one

Prefer a fresh directory and name over reusing a strange local runner state.

## 6. Treat "online then offline while busy" as a separate class of failure

If a runner:

- creates a session
- shows `online`
- then flips `offline` while the local process is still alive

that is not a normal queueing problem. It suggests host-side communication loss or host policy software interference.

At that point:

- stop repeating the same rerun on that host
- move the lane to another machine if the workflow is time-sensitive
- capture the local diagnostic tail and GitHub run state for later analysis
