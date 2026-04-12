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

## 2. Prefer the native lane first

For `lume-macos`, try the Lume guest first:

```bash
uv run --script .agents/skills/self-hosted-runners/scripts/probe_lume_runner_guest.py
```

If the guest is healthy, keep the lane on the VM.

## 3. Re-register stale runners instead of poking blindly

If the logs say the registration was deleted, do not just restart the listener. Re-register it with a fresh token.

## 4. Verify build readiness before rerunning CI

For `lume-macos`, verify:

- SSH works
- the runner service can start
- `xcodebuild -version` works
- `xcode-select -p` points at a real Xcode app

If those fail, do not rerun the workflow on that guest.

## 5. Use a host fallback only when the native lane is not viable

If the Lume guest is not build-ready, register a fresh host fallback runner with a fresh name and the `lume-macos` label.

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
