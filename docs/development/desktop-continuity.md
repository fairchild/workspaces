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

The isolated runs need `jq` (shipped at `/usr/bin/jq` since macOS 15) and, for `--drill`, `sqlite3`.

`--socket-label` refuses `workspaces`, the app's quarantine label, any label `TmuxSessionProbe.isSafeSocketLabel` rejects, and any label whose server is already running. It also refuses to launch while a debug build of this checkout is running, because `launch-dev.sh --coexist` stops every instance of that binary. The harness checks before each launch and also passes `launch-dev.sh --refuse-running-debug`, which makes the coexist scan fail instead of stopping an instance that appeared in between. Without that flag, `--coexist` behaves as before. The app runs beside the installed one (`--coexist --no-activate`). These live inside the run directory: `HOME` and `CFFIXED_USER_HOME` (the app's home, its `~/code` repo import and `~/.claude`), `XDG_CONFIG_HOME` (Launch Records and locks), the synthetic workspaces root and the scratch repo. Two things live outside it. The hooks socket sits in a `wsdrill.*` directory under `$TMPDIR`. The scratch preferences suite (`WORKSPACES_PREFERENCES_SUITE`, `com.cloudcompute.workspaces.drill.<label>`) lands in the real `~/Library/Preferences`, because cfprefsd ignores `CFFIXED_USER_HOME`. Cleanup removes the socket directory, deletes each suite's keys and then its plist, touching only names under the drill prefix.

`--kill-holder` terminates the app and kills the isolated server, relaunches, and records what restore did. `--kill-order server-first` kills the server while the app still runs. Every signal goes to a recorded identity, checked again just before it is sent. An app pid must still run this checkout's debug binary and have started after its launch began. `launch-dev.sh --pid-file` writes the pid as soon as the app is backgrounded, so cleanup also reaches an app whose launch was interrupted. A tmux server pid is recorded during its own pass, from `tmux -L <label> display -p '#{pid}'`. Its command and start time come from one `ps` read, and a pid with no readable start time is never recorded. It is signalled only while its argv still names the label and its start time is present and unchanged, and that check runs before the `KILL` fallback too. Final cleanup signals only those recorded servers and never looks a label up again.

`--drill` (`scripts/lib/continuity-drill.sh`) runs that kill across six passes: tmux and Ghostty-splits mode, the restore flag on and off, and both kill orders for tmux. Each pass has its own socket `<label>-pN`. Its tiles are a `ws launch` agent, a hand-typed `claude`, and two splits of that tile, one with its agent mid-turn. Both splits come from the primary tile, because Automation API V1 refuses a split from a secondary one. The agents are `scripts/lib/stub-agent.sh` on `PATH` as `claude`. It writes a transcript, fires the configured hooks through the real `event-forwarder.sh`, and holds its argv until killed, without spending tokens. Tile shells run `scripts/lib/drill-shell.zsh` as their `.zshrc`, which types each queued command and records what the command line holds, where a restore's prefill lands. It re-pins `HOME` to the isolated home, because a tmux server the app starts from a surface runs under `/usr/bin/login`, which resets `HOME` to the account's.

Just before the kill, the drill freezes the tile setup. It renames every queued command no shell has claimed to `*.withdrawn`, so a shell opened after relaunch starts no new agent, and lists them in `autorun-withdrawn.txt`. It copies the ledger's startup records to `stub-starts-before.jsonl`. Tiles are identified only from that copy, so an agent first started after the kill can never stand in for one that never started; that tile is `not_started`.

A restore-on pass launches with `WORKSPACES_RESTORE_SESSIONS_ON_LAUNCH=1` and `WORKSPACES_RESTORE_AUTORUN=1`. A restore-off pass sets both to `0`, which the app reads as off, so values exported in the caller's shell do not leak into it.

After relaunch, a restore-on pass polls the app's os_log for up to 40 seconds for a `[Restore]` outcome, and logs and carries on when none appears. A restore-off pass sleeps 8 seconds instead. Either way the drill then clicks the repo and workspace rows, because a restored tile starts its shell only once rendered. `restore-log.txt` holds the relaunched pid's `[Restore]`, `[Reattach]`, `[SurfaceStore]` and `HostSession` lines.

`summary.json` has one row per tile and pass, plus one global `mixed_window` row (`pass: "all"`). A row holds:

- the rung taken: `reattach`, `resume`, `fresh`, `restored_unrendered`, `ambiguous` or `none`, with `ambiguity` naming the evidence when it is `ambiguous`;
- the prefill text;
- the successor sessions;
- `resume_via`;
- which identity source named the conversation: `hook_events` in `agent_status_events`, or the `ws launch` record.

A successor is an unended after-relaunch `terminal_sessions` row that the os_log says restore created. A row that kept its before-relaunch host session id (reattach keeps it) is that before-row's successor. Each newly minted row is matched one-to-one to one of the remaining before-rows by session key and tmux name. When several of them share both, the match narrows to the before-row with the same `is_active` value. A tie, or a before-row claimed twice, makes the tile `ambiguous`. A tile's claimed sessions are its successors plus its own host sessions reused after relaunch. Prefills count only in those. A resume that lands only in another tile's session, or another conversation's resume in a claimed shell, is `ambiguous`.

Holders come from the stub agent's ledger, not from the process table at large. Each `start` event records the stub's pid, and a pid counts only while its process start time falls within 120 seconds before that event. `processes-before.txt` and `processes-after.txt` hold one JSON line per counted holder: pid, start time, the ledger's `source` and the conversation id, and no argv. `reattach` means a holder from before the kill is still alive with its original start time. A new ledger start with `source: "resume"` for the conversation is a resume (`resume_via: new_resume_process`). `resume_via` also says whether a prefill landed in a restored session or in the tile's reused host session. The reused host session is how a `ws launch` record's prefill arrives with the restore flag off.

The `cmd_t_tab` row (one per pass) and the global `mixed_window` row are `not_drivable`, because no automation verb opens a tab and the terminal mode is process-wide.

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
