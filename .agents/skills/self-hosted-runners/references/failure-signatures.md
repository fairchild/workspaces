# Failure Signatures

## Registration deleted

Symptoms:

- guest or host runner logs contain `Failed to create a session. The runner registration has been deleted`
- GitHub no longer lists the runner, or lists it only after re-registration

Action:

- re-register the runner with a fresh GitHub Actions registration token

## Session conflict

Symptoms:

- direct `./run.sh` prints `A session for this runner already exists`
- a fresh listener cannot come up cleanly with the same runner name

Action:

- confirm whether another local runner process is still alive
- if needed, stop the existing process or register a fresh runner name

## VM runner not build-ready

Symptoms:

- `xcode-select -p` points to `/Library/Developer/CommandLineTools`
- `xcodebuild -version` fails
- no `Xcode.app` exists on the guest
- CI fails immediately in build bootstrap steps such as `Build GhosttyKit`

Action:

- do not schedule macOS CI onto that guest
- repair or replace the VM, or use a host fallback lane

## Online then offline while busy

Symptoms:

- GitHub shows the runner `online`
- the runner may create a session and appear `busy`
- then GitHub flips it to `offline` while the local process still exists
- queued jobs remain unclaimed or stalled

Action:

- classify as a host-side communication failure first
- stop retrying on the same host if the job is urgent
- capture local runner diagnostics and move the lane elsewhere

## Guest service installed but stopped

Symptoms:

- `./svc.sh status` shows the service installed but not started
- `launchctl print` shows `state = not running`

Action:

- start the service
- if it stops immediately, inspect the guest runner logs for stale registration or session conflict
