# tile-orchestration — maintenance notes

This skill documents the W5-era surface (2026-07-08), including its
workarounds. Several are load-bearing only until tracked machinery lands.
**When any issue below closes, update SKILL.md in the same PR** — each row
names exactly what changes. Provenance for all of it:
`docs/retros/2026-07-08-automation-dogfood-w5.md`.

| Issue | What lands | Skill change when it does |
|---|---|---|
| #973 | Tiles receive `WORKSPACES_AUTOMATION_SOCKET`/`_HANDLE` again | Bootstrap hook gates on the handle env instead of cwd; workers can self-report via `workspaces automation context`; `input.write` becomes usable inside tiles |
| #989 | `workspace.create` options: `select:false`, `fromRef`, `startCommand` | Delete the "flips the owner's selection" warning (pass `select:false`); delete Preflight step 3 (pass `fromRef:"origin/main"`); **retire the rc-hook bootstrap entirely** (`startCommand` seeds the tile at creation — the inbox/tile-start dance and `references/bootstrap-hook.zsh` reduce to the re-tasking path only, or go away with #838) |
| #990 | Bounded text read-back of own-created tiles | Replace the `tee`-to-`worker.log` monitoring contract with `surface/read`; the finished-marker watcher can poll the API instead of a file |
| #991 | `workspace.archive` verb | Replace the Teardown section's "tell the owner" with an archive call at lane close |
| #992 | Health reports pid/launchedAt/experiments/protocolVersion | Simplify Preflight step 1 (no `ps` cross-check; version skew self-diagnoses) |
| #995 | Reference documents windowID string type + snapshot `data` key | Drop the inline warnings in the Monitor section (the reference becomes sufficient) |
| #889 | libghostty per-surface command/initial_input fix | Prerequisite for #989's `startCommand`; no direct skill text, but unblocks the row above |
| #838 | Child-handle authority model (cross-tile write to created surfaces) | If built, interactive worker steering (mid-run input) becomes possible; add a "steer a worker" section |

Also worth folding in when they happen:

- **A coordinator-durability pattern** — two session interruptions in W5
  killed background CI watchers; the durable-signals sweep (worker logs,
  `gh pr list`) is documented in Monitor, but a checkpoint file the
  coordinator maintains would make resumes mechanical.
- **Evidence-walk reliability (#976)** — web-next side; until fixed, the
  skill's gate step inherits the targeted-Playwright fallback for UI
  evidence in fresh worktrees.
- **Worker model/effort table** — W5 used xhigh for provider-seam work,
  high for design-lite features, medium for small UI; if the next arc
  confirms the mapping, promote it from judgment to guidance in SKILL.md.
