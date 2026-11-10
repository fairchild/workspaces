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

## Evidence matrix

| Lifecycle boundary | Evidence status | Merge expectation |
| --- | --- | --- |
| App terminate/relaunch | Automated by `scripts/continuity-evidence.sh` | Required for PRs that touch desktop terminal continuity |
| Sleep/wake | Manual with `scripts/tmux-continuity-probe.sh start/check` | Useful evidence, not a merge gate for the current slice |
| Logout/reboot | Deferred and explicitly unproven | Not required without a scheduled host validation window |

The automated lane intentionally uses local repo/workspace terminals only. Remote/provider-backed workspace continuity remains provider-specific and out of scope for this slice.

## Automated app relaunch evidence

Use the continuity evidence harness when a PR changes restore behavior, terminal continuity manifests, or the tmux continuity contract:

```bash
./scripts/continuity-evidence.sh --target "$HOME/code/workspaces" --no-build --trust-mise
```

The harness:

1. launches with `WORKSPACES_TERMINAL_MULTIPLEXING_MODE=tmux_per_session`;
2. launches the debug app with isolated SwiftData under `output/continuity-evidence/<timestamp>/data`;
3. opens the requested local repo terminal using the existing startup auto-selection path;
4. captures `before-close.png` by exact window id;
5. terminates the exact app PID with `NSRunningApplication.terminate()`;
6. writes a close proof as text;
7. relaunches without auto-selection and captures `after-reopen.png`;
8. checks tmux survival with `scripts/tmux-continuity-probe.sh`;
9. writes `summary.json` with PIDs, window ids, tmux session, artifact paths, and restore timing.

If multiple debug WorkSpaces windows are visible, use `scripts/capture-window.sh --pid <pid>` for manual follow-up captures. The harness already uses exact-window capture first and PID-filtered capture as its fallback.

## Isolated socket and the holder-death drill

The default run checks `has-session` on the desktop's live `-L workspaces` socket and quits the installed app (launch-dev without `--coexist`). Anything that kills a tmux server runs on an isolated socket instead:

```bash
./scripts/continuity-evidence.sh --socket-label wsdrill-$RANDOM --kill-holder
./scripts/continuity-evidence.sh --socket-label wsdrill-$RANDOM --drill [--pass tmux-on-app]
```

`--socket-label` refuses `workspaces`, the app's quarantine label, any label `TmuxSessionProbe.isSafeSocketLabel` rejects, and any label whose server is already running, so a run only ever kills a server it started. The app runs beside the installed one (`--coexist --no-activate`) with `HOME` and `CFFIXED_USER_HOME` (the app's home, its `~/code` repo import and `~/.claude`), `XDG_CONFIG_HOME` (Launch Records and locks), a scratch preferences suite (`WORKSPACES_PREFERENCES_SUITE`), a synthetic workspaces root and its own hooks socket, all inside the run directory. The scratch repo it opens lives there too.

`--kill-holder` terminates the app by pid, kills the isolated server by the pid `tmux -L <label> display -p '#{pid}'` reports (after checking that pid's argv names the label), relaunches, and records what restore did. `--kill-order server-first` kills the server while the app still runs.

`--drill` (`scripts/lib/continuity-drill.sh`) runs that kill across six passes: tmux and Ghostty-splits mode, the restore flag on and off, and both kill orders for tmux. Each pass has its own socket `<label>-pN`. Its tiles are a `ws launch` agent, a hand-typed `claude`, and two splits of that tile, one with its agent mid-turn. Both splits come from the primary tile, because Automation API V1 refuses a split from a secondary one. The agents are `scripts/lib/stub-agent.sh` on `PATH` as `claude`. It writes a transcript, fires the configured hooks through the real `event-forwarder.sh`, and holds its argv until killed, without spending tokens. Tile shells run `scripts/lib/drill-shell.zsh` as their `.zshrc`, which types each queued command and records what the command line holds, where a restore's prefill lands. It re-pins `HOME` to the isolated home, because a tmux server the app starts from a surface runs under `/usr/bin/login`, which resets `HOME` to the account's.

After relaunch the drill waits for the `[Restore]` outcome in the app's os_log, then clicks the repo and workspace rows, because a restored tile starts its shell only once rendered. `restore-log.txt` holds the relaunched pid's `[Restore]`, `[Reattach]`, `[SurfaceStore]` and `HostSession` lines. `summary.json` has one row per tile and pass: the rung taken (`reattach`, `resume`, `fresh`, `restored_unrendered` or `none`), the prefill text, the successor session (a new active after-relaunch `terminal_sessions` row with the tile's session key and tmux name), `resume_via` (a session the os_log says restore created, or the tile's own host session reused, which is how a `ws launch` record's prefill arrives with the restore flag off), and which identity source named the conversation (`hook_events` in `agent_status_events`, or the `ws launch` record). A cmd+t tab and a mixed window are recorded as `not_drivable`, because no automation verb opens a tab and the terminal mode is process-wide.

## Verification

For code changes touching this area:

```bash
./scripts/build-ghosttykit.sh
swift build
swift test
./scripts/continuity-evidence.sh --target "$HOME/code/workspaces" --no-build --trust-mise
./scripts/launch-dev.sh --no-build --no-activate
ps aux | rg '\.build/.*/WorkspaceManager'
scripts/tmux-continuity-probe.sh start "$PWD" app-restart
scripts/tmux-continuity-probe.sh check "$PWD" app-restart
scripts/tmux-continuity-probe.sh cleanup "$PWD" app-restart
```

Capture evidence with `./scripts/evidence.sh --pr <number> --name <slug>` before creating or marking a PR ready.
