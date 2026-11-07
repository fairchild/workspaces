# web-next renders terminals on Ghostty's release libghostty-vt wasm

**Date**: 2026-11-07
**Status**: accepted
**Decided by**: spike for [#1846](https://github.com/fairchild/workspaces/issues/1846), merged by the repo owner
**Issue**: [#1846](https://github.com/fairchild/workspaces/issues/1846) — milestone G1

## Context

web-next's drawer uses `ghostty-web` 0.4.0: Ghostty `5714ed07` (December 2025) plus a private wasm patch. Upstream has not released since (0.5.0-rc.0 waits in PR #182), and no maintainer has announced moving to libghostty-vt 1.0; the only upgrade attempt is a community WIP on 1.3 (#162). 0.4.0 carries an open memory-corruption bug (#210) and the unpatched paste [CVE-2026-26982](https://github.com/ghostty-org/ghostty/security/advisories/GHSA-4jxv-xgrp-5m3r) (#193).

Fed the same bytes at `/dev/terminal-vt`, the release wasm matched the fixture, parsed 128 KB frames at a fifth of ghostty-web's p95 for the same paint cost, and differed on 9 of 32 input cases: eight are ghostty-web bugs, one a macOS Option policy. It costs bytes and an owned front end.

## Decision

We will render web-next terminals on Ghostty's signed `ghostty-vt-<version>-small.wasm`, pinned by version and SHA-256 and served same-origin. A canvas front end in the repo paints render-state snapshots on a fixed cell grid, following `ios/Packages/TerminalScreen`.

## Consequences

- Input follows Ghostty's encoders: kitty keyboard flags, Shift+Enter as `CSI 27;2;13~`, sanitized paste, device replies through `WRITE_PTY`.
- A 1.x pin bump is a checksum change, and web and mobile share one snapshot model.
- **Cost:** about 112 KB more gzip per lazy load (292 KB against 180 KB).
- **Cost:** we own what ghostty-web mostly provides: selection across scrollback (the library's gesture API), mouse-tracking and focus encoding, OSC 8 links, cursor blink, inline IME preedit, an accessibility mirror. #1847 builds them; #1848 cuts the drawer over.
- `web/` (maintenance mode) stays on ghostty-web.

## Alternatives considered

- **Stay on ghostty-web 0.4.0.** It has shipped input bugs, the unpatched paste CVE, and no path to the 1.0 ABI.
- **Fork ghostty-web onto 1.0.** That means maintaining someone else's renderer plus a re-applied wasm patch. The 1.0 API already exposes what the patch added.
- **The `fast` build.** Its frame cost matched `small` within run-to-run noise, at 67 KB more gzip.

## Evidence

> OVER CAP: kept because the exit test of #1846 requires the comparison table and spike screenshots.

The data comes from headless Chromium 149 against `next build` output: `node web-next/scripts/terminal-vt-spike.mjs --ws … --mb 2.4` with a local ttyd. Stress runs streamed 3.0 MB of synthetic agent output in 16 KB or 128 KB per frame, three runs each; the figures are medians. Both panes get the same `Uint8Array`, and render time counts only frames that follow a write (185 or 24 per run on each pane). The grids were 74×24 (ghostty-web) and 77×24 (vt). Sizes are `gzip -9` and `brotli -q 11` of the built chunk and the wasm files. Wasm digests: fast `7b428fee…`, small `dad8e14c…`. Both verified with minisign against Ghostty's published key.

| | ghostty-web 0.4.0 | libghostty-vt 1.0.0 + spike canvas |
|---|---|---|
| Fixture fidelity (`agent-turn.vt`) | Same text; colors, attributes and wide cells all correct; box sides break into dashes | Same text and attributes; box borders join |
| Keys (26 synthetic cases) | Shift+Tab → `\t`; Shift+Enter → `\r`; kitty flags ignored; macOS Option+B dropped | `ESC[Z`; `CSI 27;2;13~`; `CSI 99;5u`; `ESC ∫` (option-as-alt left for #1847) |
| IME (CDP composition) | Commits 日本; no inline preedit | Commits 日本; no inline preedit |
| Paste `ls␛[201~id⏎`, mode 2004 | Passes the bytes through, so the paste escapes the bracket | `␛[200~ls [201~id⏎␛[201~` |
| Selection and copy | Drag, double and triple click, across scrollback | Drag and double click within the viewport; live ttyd copy returned `select-me-please` |
| Scrollback and resize | Yes; FitAddon | Yes; `stty size` read `24 52` after a resize |
| Device replies | Answers CPR; no reply to DA1, which shells such as fish wait on (upstream #101 landed after 0.4.0) | DA1 `ESC[?62;22c`, CPR `ESC[1;1R` |
| Gzip / brotli | 180 / 146 KB, one chunk with the wasm inlined as a `data:` URI (upstream #188, which `connect-src 'self'` blocks) | wasm 292 / 228 KB (small) or 359 / 270 KB (fast), plus a 12 KB page chunk |
| 16 KB/frame: write p95, render p95 | 0.6 ms, 2.9 ms | 0.2 ms, 2.4 ms (small) |
| 128 KB/frame: write p95, render p95 | 7.9 ms, 2.6 ms | 1.4 ms, 3.0 ms (small; every row is dirty, so the snapshot rebuilds the full grid) |
| Frame interval p95, both loads | 17–19 ms (60 fps) | 17–18 ms (60 fps) |

Screenshots from the same run:

| | ghostty-web 0.4.0 | libghostty-vt 1.0.0 |
|---|---|---|
| Fixture `agent-turn.vt` | ![ghostty-web fixture](https://evidence.cloudcompute.com/workspaces/pr-1853/uOw7TV8MzRBV1ZDel1VrUA/20261107-174655-terminal-vt-fixture-ghostty-web.png) | ![libghostty-vt fixture](https://evidence.cloudcompute.com/workspaces/pr-1853/N2lrzaFlz6g7ga_p4qsVDA/20261107-174656-terminal-vt-fixture-ghostty-vt.png) |
| Live ttyd shell | ![ghostty-web ttyd](https://evidence.cloudcompute.com/workspaces/pr-1853/1WEWVHeE6JOAw_pDruVQyA/20261107-174658-terminal-vt-ttyd-live-ghostty-web.png) | ![libghostty-vt ttyd](https://evidence.cloudcompute.com/workspaces/pr-1853/db6lOwpIkiA3zlICZ1OzYg/20261107-174659-terminal-vt-ttyd-live-ghostty-vt.png) |
| Scrollback | ![ghostty-web scrollback](https://evidence.cloudcompute.com/workspaces/pr-1853/7gB8bvGq09KbBPhCIdXUCw/20261107-174659-terminal-vt-ttyd-scrollback-ghostty-web.png) | ![libghostty-vt scrollback](https://evidence.cloudcompute.com/workspaces/pr-1853/jYxpbIqNmXNpoEEUv4Sgzw/20261107-174700-terminal-vt-ttyd-scrollback-ghostty-vt.png) |
| IME commit (mock PTY) | ![ghostty-web IME](https://evidence.cloudcompute.com/workspaces/pr-1853/thGfsoNJul4GfyrqR5xGiQ/20261107-174657-terminal-vt-ime-mock-ghostty-web.png) | ![libghostty-vt IME](https://evidence.cloudcompute.com/workspaces/pr-1853/mZwpBsnb3mEU6eZFA4oBeA/20261107-174658-terminal-vt-ime-mock-ghostty-vt.png) |
| Stress stream tail | ![ghostty-web stress](https://evidence.cloudcompute.com/workspaces/pr-1853/lPf4uPOouc9tZ5kWYvcxeQ/20261107-174701-terminal-vt-stress-tail-ghostty-web.png) | ![libghostty-vt stress](https://evidence.cloudcompute.com/workspaces/pr-1853/b3QhrbDSPSU0wXeWlcr-ig/20261107-174702-terminal-vt-stress-tail-ghostty-vt.png) |
| Selection, then resize | — | ![libghostty-vt selection](https://evidence.cloudcompute.com/workspaces/pr-1853/i8b5SbrpkpuFiHz3nJe07g/20261107-174700-terminal-vt-ttyd-selection-ghostty-vt.png) ![libghostty-vt resize](https://evidence.cloudcompute.com/workspaces/pr-1853/dHiK4Ps8Dv5_VMZ3BUnU4A/20261107-174701-terminal-vt-ttyd-resize-ghostty-vt.png) |

Input matrix, 32 cases, differences highlighted: [input-matrix.png](https://evidence.cloudcompute.com/workspaces/pr-1853/BxRiknI1e6zixPaZtmusww/20261107-174657-terminal-vt-input-matrix.png)
