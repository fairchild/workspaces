# WorkSpaces

**Terminal-first workspace manager for AI coding sessions on macOS.**

WorkSpaces gives you a native app that wraps a terminal with some niceties for spinning up isolated workspaces. Designed to optimize terminal-based coding agent workflows.

![WorkSpaces main window][screenshot-main]

[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

## Philosophy

- **Any terminal agent**: Embedded terminal with workspace management around it. Anything that runs in a shell works — Claude Code, Aider, Codex CLI, or a plain `bash` session.
- **Fork-friendly**: No backwards-compatibility baggage. Take what works, change what doesn't.
- **Opinionated defaults**: Three-column layout, terminal-first workflow, lifecycle hooks. Customizable by editing the source directly.

## Download

**[Download Latest Release](https://github.com/fairchild/workspaces/releases/latest)** (macOS 14.0+)

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon or Intel Mac

## Installation

### From DMG (Recommended)

1. Download the latest `.dmg` from [Releases](https://github.com/fairchild/workspaces/releases)
2. Open the DMG and drag **WorkSpaces** to Applications
3. Launch from Applications (first time: right-click > Open)

## Features

- Three-column layout: sidebar, terminal, and detail pane
- Restores the last active repo overview, workspace terminal, or web view on launch
- Repository overview with workspace and web-view creation
- Nested repo-scoped web views and workspaces in a single calm source list
- Repository sorting with stable `Alphabetical` and `Last Accessed` modes
- Persistent terminal sessions for repo and workspace rows
- Integrated GhosttyKit terminal surface
- Two-pane split controls driven by Ghostty actions (`Cmd+D`, focus, resize, equalize)
- Embedded web views with global, repo-owned, and workspace-owned scope
- File browser and git status view
- `cmd+o` to open repo in editor, defaulting to zed
- Lifecycle hooks (`scripts/setup`, `scripts/stop`, `scripts/archive`; legacy `setup.sh` / `archive.sh`)

## Usage

1. Launch app and resume your last repo overview, workspace terminal, or web view
2. Add repositories manually if needed
3. Click a repo row to open its overview, or expand it to jump into web views and workspaces
4. Create workspaces or add web views from repo actions
5. Click a workspace row to open its terminal context
6. Use the right pane for files and git changes

### CLI (source builds)

```bash
swift run workspaces
swift run workspaces .
swift run workspaces repo add ~/code/my-repo
swift run workspaces ws new my-repo feature-auth
swift run workspaces open my-repo/feature-auth --cmd "claude"
swift run workspaces ws race my-repo "add a health endpoint" --n 3 --cmd "claude"
```

`ws race` fans one prompt across N fresh worktree workspaces (`race-<slug>-1..N`)
and runs the agent headlessly in each (`<cmd> -p '<prompt>'`, output in the
workspace's `.race-agent.log`). Use `workspaces open <repo>/<name>` to attach to
any of them interactively.

## Configuration

Open Settings (`Cmd+,`) to configure workspace root location.

## Fork & Customize

WorkSpaces is designed to be forked. There's no plugin system or extension API — instead, the codebase itself is the API. Common customizations:

- **Change the layout**: Edit `ContentView.swift` to rearrange panes
- **Add lifecycle hooks**: Drop project lifecycle scripts into `scripts/` (`setup`, `stop`, `archive`) or use legacy root hooks (`setup.sh`, `archive.sh`)
- **Customize repo overview and sidebar behavior**: Start with `RepoLandingView.swift`, `SidebarView.swift`, and `SidebarRows.swift`
- **Swap the terminal**: The `TerminalView` wrapper abstracts the terminal backend
- **Adjust keyboard shortcuts**: See `ShortcutRoutingPolicy.swift`

If you build something interesting on top of this, open an issue.

## Roadmap

[backlog/ROADMAP.md](./backlog/ROADMAP.md) and the other files in [backlog/](./backlog/) sketch a loose direction. It evolves as the project gets used and developed — nothing there is a promise.

## Developer Setup and Contributing

Bootstrap a fresh checkout with:

```bash
./scripts/setup
```

After bootstrap, use the root `mise` catalog for day-to-day work:

```bash
mise run build-ghosttykit
mise run build
mise run test
mise run check
mise run dev-launch
mise run dev-smoke
mise run evidence -- --pr <number> --name <slug>
```

Lume validation entry points are also available from the root catalog:

```bash
mise run dev-lume-ensure
mise run dev-lume-preflight
mise run dev-lume-standalone-validate
mise run dev-lume-macos-smoke
```

Run `mise tasks` for the full top-level catalog. Web dashboard tasks stay in `web/.mise.toml`; run them with `mise -C web run <task>`.

The bootstrap path validates and trusts only the reviewed root/web mise configs,
then installs locked tool versions. Keep secrets and broad trust settings out of
mise config; see [mise security](./docs/development/mise-security.md).

For contribution guidelines and project structure, see:

- [CONTRIBUTING.md](./CONTRIBUTING.md)

For release/signing/notarization details, see:

- [RELEASING.md](./RELEASING.md)

For performance testing and benchmarking workflows, see:

- [docs/performance-testing.md](./docs/performance-testing.md)
- [docs/performance/dashboard.md](./docs/performance/dashboard.md)

For introducing Settings-gated UI experiments, see:

- [docs/development/experimental-features.md](./docs/development/experimental-features.md)

For local app-shell automation from WorkSpaces terminal tiles, see:

- [docs/automation-api.md](./docs/automation-api.md)
- [docs/development/automation-api.md](./docs/development/automation-api.md)

For VM and provider-backed workspace architecture, see:

- [docs/vm-provider-architecture.md](./docs/vm-provider-architecture.md)
- [docs/development/lume-integration.md](./docs/development/lume-integration.md)
- [docs/development/lume-validation.md](./docs/development/lume-validation.md)
- [docs/development/lume-recreate-runbook.md](./docs/development/lume-recreate-runbook.md)
- [docs/development/evidence.md](./docs/development/evidence.md)

The Lume validation flow uses isolated WorkSpaces-managed VM storage and a standalone validated-base manifest before the app will reuse a macOS base VM.

For the Agent Factory (autonomous pipeline) system overview and trust model, browser-openable directly, see:

- [docs/development/agent-factory-v2-overview.html](./docs/development/agent-factory-v2-overview.html)

For UI smoke/capture script entry points, see:

- [scripts/README.md](./scripts/README.md)

## License

[Apache-2.0](LICENSE) — Copyright 2026 Michael Fairchild

[screenshot-main]: docs/assets/screenshot-main.jpg
