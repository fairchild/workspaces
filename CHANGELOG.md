# Changelog

## [0.8.0] - 2026-03-24

### Added
- add per-agent health monitoring to ops-report (#199)

### Fixed
- harden evidence validation with truncated errors and structured classification (#198)

### Other
- Gate public agent workflows to trusted actors (#202)

## [0.7.0] - 2026-03-24

### Added
- upgrade diagnostic export to full report bundle (#197)
- web: Phase 3 — event persistence, live dashboard, mobile layout (#193)
- web: Phase 2 — GitHub OAuth, dashboard, webhook activity feed (#188)
- add exportable local diagnostics for startup regressions (#153)
- add lume daemon reliability tooling and docs (#161)
- compact lume-status script and fix smoke VM cleanup (#160)
- instrument workspace-switch focus metrics (#149)
- add @agent mention triggers and extract reusable evidence workflow
- add release quality gate before publishing (#155)
- enforce startup performance budgets in CI (#147)

### Changed
- extract contributor runtime into domain modules (#185)
- move selection persistence off main-actor hot path (#151)
- parallelize provider availability and Lume snapshot refresh (#152)
- track activation-to-ready gap in dashboard

### Fixed
- add web README and set Vercel root directory (#194)
- add workspace creation diagnostics and guard debounced save rollback (#190)
- remove stale snapshot cache from setup flow (#106 follow-up) (#166)
- simplify terminal focus ownership and remove duplicate handoffs (#150)
- address PR #141 review follow-ups (#154)
- support multi-line quoted strings in frontmatter parser (#138)

### Other
- Fix main test suite deadlock and refresh perf baseline (#186)
- spaces.cloudcompute.com agent discovery dashboard (#191)
- Add chat sdk skill (#192)
- Harden contributor evidence contracts (#145)
- Upgrade create-github-app-token to v3 (#144)
- Improve contributor own-PR follow-up flow (#141)
- Reduce redundant snapshot() probes in workspace creation flow
- Retry app review smoke verification (#140)
- Show progress while New Workspace loads (#135)
- Target lume runner for evidence, handle bot assignment (#139)
- Wire R2 evidence URLs into April workflow (#136)
- Add runner VM recovery docs and unlock script (#137)

## [0.6.0] - 2026-03-19

### Added
- switch agent output to YAML frontmatter + add CLI agentic loop mode (#102)
- add agent history context to contributor runs
- drop advance_issue, redirect agents to discussions
- PR reviews lead with verdict and support code suggestions
- give agents their own GitHub App identities
- prioritize follow-up reviews when author pushes after agent comment
- add --message parameter for directed agent tasks
- normalize OpenAI API key env for Codespaces compatibility

### Fixed
- grant issues:write to agent workflows and require timeouts on all subprocess calls (#101)
- handle preamble text before frontmatter in CLI agentic mode
- strengthen frontmatter format instructions for CLI agentic mode
- detect bot login via /app endpoint instead of /user
- map approve_with_followups to --approve and pass GH_APP_SLUG
- prefer engagement before new agent proposals (#113)
- run contributor agents on ubuntu hosted runners (#118)

### Other
- scope macOS CI to build-affecting changes
- Hide activity tab when notifications are disabled (#80)
- align backlog with milestone workflow (#85)
- link lume milestone to backlog (#91)
- clarify signing-host release lane (#86)
- Refactor Ghostty runtime handling and workspace environment options (#92)
- add .agents/MEMORY.md
- Require PR evidence for UI and performance-sensitive work (#95)
- Fix startup slowness from eager runtime probing (#94)
- prioritize discussion participation over solo issue comments
- add weekend agent schedules (every other hour)
- move agent scripts into skill directories
- Harden Lume runtime seams (#103)
- add remote runtime expansion plan to backlog
- gitignore paper PDFs and add papers README with sources
- Make Peter issues agent actionable (#114)
- Fix Peter frontmatter parsing for block-list metadata (#115)
- Add contributor execution flow
- Add agent owner protocol
- Sync issue readiness for contributors
- Add agent:review and agent:mergeable labels with assignment tracking (#120)
- Require PR evidence accounting for agent work
- Enable agents to produce macOS evidence via CI job
- Fix agent CI evidence flow
- Run April on Lume macOS VM with ubuntu fallback (#128)
- Prefer app token for agent PR reviews (#122)
- Restore native GitHub App reviews (#125)
- Run April on Lume macOS VM with ubuntu fallback (#130)
- Add fuzzy evidence matching and CI reconciliation (#126)
- Add R2 evidence store and harden April's macOS execution (#133)
- Fix evidence gate edge cases and simplify April workflow (#132)
- Fix environment status color semantics in NewWorkspaceSheet (#119)
- Close provider setup validation gaps for milestone 5 (#123)
- Add /april command for agent team coordination (#134)
- defer workspace runtime readiness and record release baseline

## [0.5.0] - 2026-03-12

### Added
- generate fun unique workspace names (#79)
- add drive milestone skill (#77)
- runner-status script for CI visibility (#69)
- CI visibility via runner status and menu bar indicator (#73)
- add ops reporting loop (#72)

### Fixed
- harden release workflow and prep (#76)
- sanitize pipe chars and resolve symlink in runner scripts (#74)

### Other
- Fix SwiftBar runner plugin installation (#78)
- Add Lume macOS VM validation and smoke automation (#54)
- Add observer replay fixtures (#75)
- Implement registry-backed remote workspaces and SSH host support (#55)

## [0.4.0] - 2026-03-11

### Added
- add GitHub connect entrypoints in the activity panel
- add conductor setup automation for trusted mise installs
- expand agent automation support for remote runtime and scheduled workflows

### Fixed
- provision packaged apps correctly for the data protection keychain
- dedupe notification activity replays and JWT refresh churn
- stop app focus stealing on self-hosted CI runners
- harden contributor and Peter automation workflows

### Other
- update GitHub Actions runtimes to Node.js 24
- document keychain-signing bootstrap and agent-team token requirements

## [0.3.0] - 2026-03-10

### Added
- refine main window navigation and simplify sidebar chrome
- add notification client with GitHub auth and Activity tab
- add Cloudflare webhook relay worker with Durable Objects
- add repo landing page with web bridge and override support
- add workspace process monitor for agent detection
- add GitHub App auth for gh-discuss skill (#31)
- add gh-discuss skill for multi-agent coordination via GitHub Discussions (#27)

### Fixed
- improve crash safety and reliability
- address repo landing review feedback

### Other
- ignore tmp
- Extract main-window presentation and bootstrap controllers (#29)
- Complete refinement hardening and start maintainability pass (#28)

## [0.2.0] - 2026-03-02

### Added
- Daytona remote sandbox integration — cloud workspaces with SSH (#21)
- add open-in-editor launch guardrails and metrics
- harden tart-gui-automation + context attachments UX (#19)
- add URL sources webview mode and terminal UX refinements

### Fixed
- use fixture home in open-in-editor smoke assertions
- harden webview blocked navigation behavior

### Other
- Streamline web chrome and add wildcard web allowlist domains (#22)
- Refine sidebar session-state UX and add coverage (#20)
- Add open-in-editor launch guardrails and performance metrics (#18)
- Fix swift-format AddLines lint failures
- Fix review findings in workspace safety, git parsing, and focus retries
- Add deterministic Tart WebView memory benchmark and report
- Add reusable Tart GUI automation skill
- Update agent python guidance and launch-dev process check
- Keep web source navigation in-app for related domains
- Add optional live VNC viewer flag for Tart demo
- Add Tart-based webview demo recorder

## [0.1.2] - 2026-02-28

### Other
- Sync Ghostty theme with system appearance
- Fix swift-format lint violations
- Harden preview capture against black screenshots
- Add deterministic fixture preview bootstrap and capture script
- Refine open-control styling and optimize repo path lookups
- Polish open-in-editor UX and harden editor launch flow

## [0.1.1] - 2026-02-24

### Other
- Keep app alive after last window closes
- Preserve inspector state and prune stale pane cache
- Fix repo inspector targeting and GhosttyKit build warnings
- Fix code preview rendering and integrate preview/terminal controls
- Make inspector opt-in and add Cmd+Shift+B toggle
- fix terminal split exit handling and live session indicators

## [0.1.0] - 2026-02-17

### Added
- refresh icon assets and branding guide
- route shortcuts via policy and harden release workflow
- add dev launcher and sandbox-aware shortcut updates
- polish sidebar UI and add deterministic sidebar capture
- add app icon and branding
- ui: show live terminal indicators for repo sessions
- host: preload ~/code repos and persist repo-click terminal sessions
- m1: pin main terminal to host defaults on launch
- cli: add workspace manager daily-driver commands
- add self-hosted runner support
- extract WorkspaceManager from services monorepo

### Changed
- harden host terminal session presentation flow
- ui: direct session focus and add one-click host navigation
- ui: reduce host session render cost and speed repo preload
- host: harden session lifecycle and window scoping
- value-type protocol boundaries, async process execution, repo setup

### Fixed
- keep inspector closed when creating workspace
- recenter and increase app icon frame occupancy
- apply app icon in dev and bundle builds
- make release cleanup compatible with bash 3
- tolerate missing default keychain in release workflow
- release: harden secret setup and align runner behavior
- terminal: switch main view to selected workspace session
- ui: restore host row and strengthen live session visibility
- harden process execution and workspace terminal lifecycle
- address review findings and add workspace progress follow-up (#9)
- repair broken markdown table in isolation-strategies.md

### Other
- Harden Ghostty shortcut pass-through and add smoke verification
- Unify shortcut routing and harden debug launch against stale app
- clarify and refactor build-ghosttykit
- fix terminal split shortcut and document verification loop
- Rename production heading to Next
- Update release workflow to manual
- Add perf CI validation and archive legacy UI scripts
- Streamline UI test scripts and add shared smoke/capture entrypoints
- Add performance instrumentation, benchmarks, and dashboard docs
- Document release and plan refinments
- sidebar: make repositories header clickable for host terminal
- sidebar: make live-session indicators explicit
- Adopt GhosttyKit terminal stack (#10)

All notable changes to this project will be documented in this file.

## [0.1.0] - 2026-02-16

### Added
- Repository-first sidebar hierarchy with nested workspace rows under each repository.
- Collapsible repository rows with compact workspace-count badge indicators.
- Shortcut routing architecture doc: `docs/development/shortcut-routing.md`.

### Changed
- Shortcut handling now follows a Ghostty-first policy by default; app chrome owns only explicit non-overlapping shortcuts (currently `Cmd+B` for sidebar toggle).
- Embedded terminal key-equivalent handling now uses Ghostty binding detection/replay flow instead of one-off per-shortcut interception.
- `launch-dev.sh` now verifies the running executable path to prevent stale-build confusion.
- Product/user-story docs now explicitly define wrapper-vs-terminal shortcut ownership and future routing override direction.

### Fixed
- `Cmd+D` split creation now routes through Ghostty runtime actions into app split state reliably.
- `goto_split` runtime actions are now handled for the current two-pane horizontal split model.
- Release workflow now enforces main-lineage release commits and supports tag-driven releases (`workspaces-v*`).
- Release signing/notarization flow no longer depends on writing signing credentials into repo files during CI.
- Release cleanup now restores prior keychain state safely on self-hosted runners and is compatible with macOS bash 3.

## [0.1.0-alpha.1] - 2026-02-09

### Changed
- Terminal now runs on GhosttyKit (`libghostty`) for faster rendering and better input/focus reliability.
- Workspace terminal behavior remains the same (open per workspace, restart, and focus restore).
- Release/CI flow now builds GhosttyKit automatically before app build/tests.

### Architecture
- Replaced SwiftTerm with a thin Ghostty surface/app-manager integration layer; custom terminal theming is deferred for now.
