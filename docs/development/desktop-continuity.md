# Desktop Terminal Continuity

Desktop continuity means reopening Workspaces and landing back in the same local repo or local workspace terminal with the strongest state the host can honestly preserve.

## First-phase contract

For local repo/workspace terminals:

1. Workspaces launches tmux mode into a deterministic tmux session for the terminal launch directory on the `workspaces` socket.
2. Workspaces persists a terminal continuity manifest for the last opened local terminal target.
3. On app restore, the last terminal surface is selected and the manifest's launch directory is preferred if it still exists under the same target root.
4. If the tmux server survived, tmux reattach preserves live process state, panes, cwd, and scrollback.
5. If the tmux server did not survive, Workspaces relaunches from the manifest launch directory or target root. In-flight processes are not recreated.

Remote/provider-backed workspaces are not covered by this first phase.

## Manual probe

Use this loop to record survival across lifecycle boundaries:

```bash
scripts/tmux-continuity-probe.sh start /path/to/workspace app-restart
# Quit/reopen Workspaces, sleep/wake, logout, or reboot.
scripts/tmux-continuity-probe.sh check /path/to/workspace app-restart
scripts/tmux-continuity-probe.sh cleanup /path/to/workspace app-restart
```

Expected result for an app quit/reopen inside the same login session: `check` reports `survived`.

Expected result after reboot may be `missing`; in that case the manifest fallback is the intended recovery behavior.

## Verification

For code changes touching this area:

```bash
./scripts/build-ghosttykit.sh
swift build
swift test
./scripts/launch-dev.sh --no-build --no-activate
ps aux | rg '.build/arm64-apple-macosx/debug/WorkspaceManager'
scripts/tmux-continuity-probe.sh start "$PWD" app-restart
scripts/tmux-continuity-probe.sh check "$PWD" app-restart
scripts/tmux-continuity-probe.sh cleanup "$PWD" app-restart
```

Capture evidence with `./scripts/evidence.sh --pr <number> --name <slug>` before creating or marking a PR ready.
