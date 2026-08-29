# Assistant resurrect: agents that survive restarts

Research memo, 2026-08-29. Evaluates timvw/tmux-assistant-resurrect (HEAD
`f11ca73`) against the WorkSpaces persistent-restart goal; claims verified
against this repo at `b0c7b0cd`. Staleness test: if #1407 has merged or
#1413/#1390 have moved, re-verify §"What WorkSpaces already has" before
acting on the recommendation.

## Recommendation

**Inspire-only.** Don't run the plugin on the `-L workspaces` server and
don't vendor its code. WorkSpaces already owns almost every ingredient the
plugin provides — durable per-session rows, a recorded tmux name, a
transcript-resumability check, a three-rung restore ladder, typed command
delivery — and the plugin's architecture is wrong for a product that owns
its own session store (§ Direct use). What the plugin does offer is four
specific, hard-won patterns worth borrowing (§ Inspiration), plus a clear
demonstration of the restore-security posture to avoid (§ Security).

The path to "agents persist until deliberately turned off" is finishing the
native machinery, in order:

1. Land #1407 (identity adoption on reattach) — without it, even agents
   that *do* survive go status-dark after every app restart.
2. Persist launch provenance — the agent command text, model, and agent
   kind per session. Today only a boolean (`custom_command_present`)
   survives, so no restore path can know what a session was running.
3. Add a hook-written state-file fallback so the agent session ID survives
   the app being dead (today it arrives only over a Unix socket the app
   must be alive to answer).
4. Graduate `restoreSessionsOnLaunch` from its default-off experiment as
   the reboot/tmux-death story, with the safe restore posture below.

Costs are named at the end; follow-up issues are filed and linked there.

## The question

Michael's intent: WorkSpaces agents persist until deliberately turned off —
across app restarts, tmux-server death, and reboots — whether the agent
runs in a live sandbox or plainly on the laptop with state. The plugin was
flagged as possible inspiration or direct use.

## What the plugin actually is

A TPM plugin riding tmux-resurrect's hooks (`@resurrect-hook-post-save-all`
/ `-post-restore-all`), with tmux-continuum as the timer. Save takes one
`ps -eo pid=,ppid=,args=` snapshot plus two `list-panes -a` passes, BFS-walks
each pane's process tree for assistant binaries (claude, copilot, opencode,
codex, pi, omp, grok), extracts a session ID per tool by tool-native means,
and writes an `assistant-sessions.json` sidecar next to resurrect's own
save data. Restore runs after resurrect has recreated panes and literally
types (`send-keys`) a reconstructed resume command — for Claude,
`command claude <saved flags> --resume '<id>'` — into each pane that maps
back by `(session_name, window_index, pane_index)` and is sitting at a bare
shell with no assistant already in its tree.

The Claude session ID comes from a SessionStart hook the plugin installs
into `~/.claude/settings.json`: the hook writes Claude's whole SessionStart
payload to `~/.local/state/tmux-assistant-resurrect/claude-<pid>.json`, and
save-time code correlates pane → claude PID → that filename. Nothing else —
no cwd, tty, or transcript path — participates in the correlation. Tools
without a hook fall back to argv scraping or cwd+mtime heuristics against
their own state stores (Codex's SQLite/JSONL, Pi's session dir), which the
code itself documents as collision-prone when two instances share a
directory.

Two facts that frame everything below:

- **It is socket-blind.** Every tmux call in the production scripts is bare
  `tmux` — no `-L`, no `-S`, no `TMUX_TMPDIR` handling. The server is
  whatever `$TMUX` the hook inherited. Nothing namespaces the sidecar or
  the state dir by server, so two servers sharing a resurrect dir overwrite
  each other's saves.
- **Restore replays flags verbatim.** `--dangerously-skip-permissions`
  survives capture and is re-typed on restore; the README documents
  `claude --dangerously-skip-permissions --model opus --resume <id>` as
  expected restore output. There is no allowlist on the restore path — the
  hazard-token list exists only in the interactive `just relaunch-add`
  helper and is deliberately never consulted by save or restore.

Quality is better than the README's "entirely vibecoded" disclaimer
suggests: ~5,000 lines of production bash/awk/python against ~8,900 of
test, CI across Linux/macOS/bash-3.2, and comments that cite the concrete
incident behind each guard. But macOS is the second-class platform — no
`/proc` means no env capture and no exact-argv recovery, so every
flattened-argv mitigation degrades to "persist it wrong" or "drop it"
there. Its scar tissue is the most useful thing about it: it is a catalog
of what a restore feature will hit (PID recycling, cwd collisions,
first-save chicken-and-egg, TUIs caching a null OSC response when restored
with no client attached).

## What WorkSpaces already has

The restart story today, stated plainly: **shells come back, agents
don't** — and even agents that survive go status-dark (#1397).

- The tmux server (`-L workspaces`) outlives the app; adoption on relaunch
  is entirely `new-session -A` against the deterministic
  `wm-<dir>-<hash8>` name (`GhosttyTerminalConfig.tmuxLaunchScript`). The
  continuity manifest replays session records under their recorded UUIDs;
  the reattach pass realizes up to 12 provably-alive scopes but
  deliberately excludes any session with a `customCommand` or
  `initialCommand` — re-running an agent is "an explicit act, not restore"
  (`MainWindowOpenSurfaceReattachController.swift:179-194`).
- A restore ladder already exists behind the default-off
  `restoreSessionsOnLaunch` experiment: `reattachTmux` when the recorded
  tmux name is alive → `resumeClaude` when the transcript exists for the
  exact recorded cwd → `freshShell`
  (`TerminalRestorePlanner.decideAction`). The resume command is a bare
  `claude --resume <id>` (`RestoreLaunchCommand.swift:17-19`), typed over
  the automation text bridge because libghostty ignores per-surface launch
  commands after the first surface.
- The agent session ID feeding that ladder comes exclusively from hook
  events (`agent_status_events`, newest row per host session) — delivered
  by `curl --unix-socket` to a listener that must be alive and must have
  the host-session ID registered. #1397 is that registration going stale on
  app restart (three days of silent ingestion loss in the repro); PR #1407
  (open, unmerged) adopts the recorded ID on the reattach rung and makes
  drops visible, and leaves the fresh-mint-onto-live-name hole to #1413.
- Nothing persists how a session was started. SQLite records
  `custom_command_present` as a boolean; the manifest stores
  `customCommand` text but refuses to restore records carrying one;
  `initialCommand` is not persisted anywhere. The desktop app passes no
  permission flags when launching agents — `--dangerously-skip-permissions`
  appears once in the repo, in `scripts/codespaces-claude-worker.sh`, a
  headless cloud-worker plane.
- Env is app-owned and re-minted per launch: the five tile-scoped keys
  (hooks socket, host-session ID, automation socket/handle, command-status
  hook) are injected per session via `-e` plus chained `set-environment`.
  The automation handle lives only in memory; every restart re-mints it.
  There is no env scrubbing — the launch env is the app's own env plus
  additions. (The handoff's "scrubbed-env hygiene" doesn't exist in the
  tree; the actual hygiene property is per-tile *scoping*.)
- The sandbox plane (Lume/Daytona/SSH providers) uses no tmux at all — a
  `customCommand` SSH invocation with a four-variable env, no hooks, no
  automation handle, excluded from manifest restore, reattach, and the
  planner by construction.
- An evidence harness for exactly this question exists:
  `scripts/continuity-evidence.sh` + `scripts/tmux-continuity-probe.sh`
  (quit/reopen with isolated state, before/after captures, survival probe).

## Q1 — Direct use: no

Four reasons, any one sufficient:

1. **Server plumbing doesn't reach it.** The plugin needs TPM + resurrect +
   continuum loaded *inside* the `-L workspaces` server, which means config
   in `~/.tmux.conf` — shared with the user's default server, so the whole
   stack would also start running there, and both servers would write the
   same sidecar and resurrect dir (last save wins, no socket component in
   any path). Isolating it would mean maintaining a parallel tmux config
   the app doesn't own today.
2. **Resurrected agents would be invisible to the app.** Resurrect
   recreates panes as fresh shells; the plugin types resume commands into
   them. Those panes carry none of the tile-scoped env — no
   `WORKSPACES_HOOKS_SOCKET`, no `WORKSPACES_HOST_SESSION_ID`, no
   automation handle — and tmux cannot rewrite a live process's
   environment. Every resurrected agent would run status-dark and
   unaddressable: the #1397 failure class made permanent and universal.
3. **Two restore authorities would collide.** The app's manifest replay,
   `-A` adoption, and (when enabled) its own restore ladder all act on the
   same panes the plugin would be typing into. The plugin's guards
   (bare-shell check, assistant-in-tree walk) reduce but don't eliminate
   the interleavings, and the app's side has no idea the plugin exists —
   its #1233 suppression only knows about surfaces it owns. Debugging a
   double-restore race across two codebases is a poor trade for
   functionality the app is four steps from owning natively.
4. **Install mutates surfaces this project treats as protected.** The
   plugin edits `~/.claude/settings.json` directly (adding SessionStart/
   SessionEnd hooks alongside the app's own forwarders) and requires
   `~/.tmux.conf` changes. Per the dispatch brief, both are
   Michael's-word-only surfaces; a product feature can't depend on them.

None of this is a defect in the plugin — it's built for the tmux-native
user whose terminal *is* the session store. WorkSpaces already has a
session store; grafting a second one underneath it adds a consistency
problem, not persistence.

## Q2 — Inspiration: four patterns worth taking

**1. The state-file rendezvous (the SessionStart trick).** The plugin's
load-bearing insight is that a hook and its eventual reader never share an
environment, so the rendezvous path must be derivable from the one variable
both sides agree on (`$HOME` — their issue #65 was `TMPDIR` diverging
between Claude's hook env and the tmux server). WorkSpaces' forwarder
currently curls a socket; when the app is dead, the event — and with it the
session ID — is simply lost. The borrow: have the app's own SessionStart
forwarder *also* append a small state file (session ID, model, cwd, pid,
host-session ID) under a `$HOME`-fixed app dir, and have launch read it to
heal `agent_status_events` staleness before planning a restore. Take their
reaping discipline too: PID-liveness plus mtime-vs-process-start with
slack, because SessionEnd never fires on SIGKILL/crash.

**2. Launch provenance as data.** The plugin captures `cli_args` and
`model` per pane because without them restore can't reconstruct anything.
WorkSpaces should persist the equivalent (agent command text, model, agent
kind) in `terminal_sessions` and the manifest — not to replay verbatim
(§ Security), but so restore *knows* what a session was and can present an
honest "resume claude (opus) in issue-1374?" instead of a boolean shrug.

**3. Restore guards.** Three of the plugin's checks are directly liftable
into the ladder's resume rung: the pane must be at a bare shell; the
process tree under the pane must contain no assistant already (their
`pane_has_assistant` full-tree BFS — stronger than name-based
suppression); the saved cwd must still exist before anything is typed.
And one lesson for the automation plane rather than restore: a TUI
restored into a pane with no attached client caches tmux's null reply to
its startup OSC queries and never retries (their codex-diff-palette bug).
`ws launch` creates detached sessions running agents — same hazard shape.

**4. The voucher, if flag replay is ever wanted.** Byte-exact, user-owned
allowlist consulted at restore; sidecar text is only a lookup key and the
executed command is rebuilt from the voucher line. If WorkSpaces ever
replays more than `--resume`, this is the shape — with the trust-boundary
fix the plugin lacks (it never checks voucher ownership or mode, and the
voucher lives in the same directory as the data it authorizes; ours should
be app-owned state with ownership checks, or an in-app approval).

## Q3 — Security: the safe restore posture

The plugin re-grants elevation nobody re-approved: a pane that was running
`--dangerously-skip-permissions` resumes with it silently, five minutes of
continuum cadence after anyone starts such a session. Its sidecar is also
an input-injection surface — restore constrains *which binary* runs but
not which flags reach it, so write access to the resurrect dir is argv
control over an agent binary (their own docs frame the guarantee as
"nothing unattended," not "nothing dangerous").

WorkSpaces's current posture is already right, partly by accident of
minimalism: restore types a bare `claude --resume <id>` — conversation
identity comes back, elevation doesn't; anything the agent wants beyond
defaults gets re-asked in-session. Keep that invariant explicit as
provenance lands:

- **Resume restores identity, never authority.** Persisted command text
  informs the restore *offer*; the executed command stays
  allowlist-shaped (binary from a fixed table + `--resume <validated id>`
  + `--model <validated>`). Hazard flags are never replayed from storage —
  if that's ever wanted, it goes through an explicit per-command
  re-approval (voucher pattern, app-owned).
- **Treat the stores as injection surfaces.** Typed delivery means
  anything in the manifest/SQLite becomes keystrokes in a shell. Validate
  shape at read the way the plugin validates its sidecar per-entry
  (bounded, pattern-matched session IDs; reject rather than repair).
- The credential-flag stripping lesson applies at capture time if we ever
  record raw argv: strip by flag name, accept that opaque values can hide
  secrets, and bound the blast radius with file modes.

## Q4 — State that matters beyond the session ID

Worth persisting: the worktree/cwd (already recorded; the transcript
locator deliberately keys off the *exact* cwd Claude's hook reported),
agent kind, model (append `--model` on resume when absent, as the plugin
does — resume alone doesn't pin it), the effective tmux session name and
override (already in both stores), and eventually split layout (#895).

Deliberately *not* worth persisting: the tile-scoped env. The plugin must
capture env because nothing else will recreate it; WorkSpaces re-mints all
five keys per launch, and a restored pane should get *this* launch's
sockets and handle with the *old* conversation. Replaying stale env would
recreate #1397 by hand. The app being the env owner is precisely the
advantage a native restore has over the plugin.

The sandbox case: nothing here applies — provider-backed sessions have no
tmux plane, no hooks, and no restore rung by construction, and their
persistence is the provider's lifecycle (VM/sandbox state), not pane
reconstruction. The laptop-with-state case is the tractable one and the
one this arc should mean. If sandbox-session persistence matters soon, it
is a separate design (provider snapshot/reattach), not an extension of
this.

## Q5 — Scope cut: what each restart case needs

**App restart** (the common case): agents *keep running* — the server
outlives the app and `-A` re-adopts by name. Nothing needs resurrecting;
what breaks is identity and status (#1397). #1407 buys adoption on the
reattach rung plus visible drop counters; #1413 covers the residual
fresh-mint-onto-live-name hole. This case is fixed by landing those, full
stop — no save/restore machinery involved.

**tmux-server death** (rare: crash, manual kill, #1267-style accidents):
agents die with it. The restore ladder's `resumeClaude` rung is exactly
this case and already works when the experiment is on — but it depends on
the hook-fed session ID being fresh, which is the stream #1397 kills. So
ingestion health is a prerequisite, and the state-file fallback (Q2.1)
makes the ladder robust to the app having been dead when the session
last spoke.

**Reboot**: identical to server death from the ladder's point of view.
This is where "agents persist until turned off" gets decided: graduate
`restoreSessionsOnLaunch` (or a successor) to a real feature, fed by
provenance (Q2.2) and the state-file fallback (Q2.1), guarded per Q2.3,
with the reboot-shaped lane added to `continuity-evidence.sh`
(kill-server + relaunch approximates it without a logout).

Claude-only first is the honest cut: the ladder, transcript locator, and
hook stream are all Claude-shaped today, and Claude is the fleet's
workhorse. The plugin's per-tool extraction table is the reference if
codex/pi resume ever matters.

## Costs

Owning restore natively means owning the failure catalog the plugin spent
191 commits accumulating — PID recycling, stale state files, first-save
gaps, client-attach timing — though WorkSpaces dodges the worst of it
(PID-keyed hook correlation and app-owned env replace the cwd+mtime
heuristics that cause most plugin misassignment). Provenance is schema +
manifest churn on well-tested code. Graduating restore-on-launch is a
product decision with UX weight (when to offer, when to auto-resume), not
just a flag flip. And the state-file fallback adds a second source of
truth for agent session identity that must reconcile with
`agent_status_events` rather than race it.

## Follow-ups filed

- #1416 — persist launch provenance (command text, model, agent kind).
- #1417 — SessionStart state-file fallback for app-dead capture.
- #1418 — reboot-recovery lane: graduate `restoreSessionsOnLaunch` +
  evidence lane.

Sequencing: #1407 first (already in review), then #1416, then #1417, then
#1418. Each is independently shippable.
