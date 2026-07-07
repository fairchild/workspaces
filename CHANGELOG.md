# Changelog

## [0.23.0-beta.2] - 2026-07-06

Tester prerelease. Headline: the Tile Tree + Surface abstraction epic (#627) is complete — the terminal layout is a recursive tile tree end to end, and web sources render through the same surface seam.

### Added
- Tile-tree epic completed (#627): `SurfaceStore` is the live surface owner and single eviction authority (P5, #701); web main content renders through the `Surface` seam with per-source page persistence — flipping away from a web source and back within ~30s no longer reloads (P6, #841); `TileTreeStore` rename + domain glossary (P7/P8, #842). Lingering web pages are LRU-capped at 3 (#849).
- Durable terminal sessions across app restarts, behind an experimental flag: cold-start restore planning, restore banner + execution, session-history read models and browser window (#730, #742, #743, #755, #758, #763, #782); reboot-resume fixes (#786).
- Guarded native text editing: editable buffer for small UTF-8 files with save command and hardened save path (#713, #720, and follow-ups).
- WorkSpaces automation: experimental caller-scoped `input.write` capability (#799); `ws race` fans one prompt across N worktree workspaces (#801).
- Desktop UI smoke now hard-gates web-through-the-seam (Flow 3, #841).
- Attention summary resolver extracted to core; acknowledged Needs You notifications clear (#722 and follow-ups).

### Fixed
- Renderer falls back to a real renderer outside the WorkSpaces app (#788).
- Cap lingering web pages LRU in `SurfaceStore` (#849).

### Web & infrastructure
- web-next sessions-first redesign: Folio design system, durable resumable turns, real harness-backed agent runtime, reasoning traces, session resume (#741, #769–#787, #822, #826–#833).
- Web dashboard: middleware session freshness (#727), narrow-viewport sidebar drawer (#732), component-test lane (#731), Chat SDK bot retirement (#725).
- Agents/infra: repo settings as code with drift gate (#835), author labels on agent PRs (#792), Fable orchestrator v1 (#768), curated repo memory read side (#765), managed-review reruns flag (#738), token-handling hardening (#762, #791), feedback-store dedup + audit (#766), sandbox mise pin bump (#840).

## [0.23.0-beta.1] - 2026-06-30

### Added
- Guarded native text editing phase 1: small UTF-8 files can now open in an in-memory editable buffer, with read-only safety gates for unsupported files (#713).

### Changed
- Refactor preview QA to use a reusable alias (#702).

### Other
- Refresh roadmap to v0.22 and groom backlog labels for milestone #9 (#711).

## [0.22.0] - 2026-06-28

### Added
- WorkSpaces automation API v1 for local scripting and host integration (#684).
- Tile-tree Phase 4 recursive renderer with N-way tiling support (#658).
- Help -> Keyboard Shortcuts cheat sheet (#691).
- In-app feedback capture backed by feedback-store infrastructure (#699).
- Preview deployment QA flow.

### Changed
- Redesign managed review run details.
- Update web security dependencies.

### Fixed
- Ensure terminal sessions exit before workspace retirement (#689).
- Fix Codex worker mise bootstrap.
- Fix diagnostic export main actor crash (#694).
- Fix managed review stuck-starting repair.

### Other
- Harden tile-tree focus, teardown, and Lume terminal launch storage coverage (#692, #695).
- Record the tile-tree reversal and terminal-multiplexing ADR update (#693).

## [0.21.0] - 2026-06-27

### Added
- Insert dropped terminal paths into active sessions (#686).
- Needs-you notification dropdown.

### Fixed
- Ghostty terminal scrolling.
- Xcode Cloud Ghostty Zig selection.

### Other
- Add optional tester prerelease path (#676).
- Enable Ghostty tab renaming.
- Avoid no-op terminal tab title overrides.
- Fix Lume orphan VM storage cleanup.
- Rename Command Palette to Session Switcher.
- Address session switcher review findings and follow-ups.
- Close workspace terminals on archive.

## [0.21.0-beta.1] - 2026-06-25

### Added
- Needs-you notification dropdown.

### Fixed
- Ghostty terminal scrolling.

## [0.20.0] - 2026-06-17

### Added
- hover info card for sidebar workspace rows (#660)

### Changed
- deepen agent update intake routing

### Other
- Centralize terminal launch context policy (#672)
- Surface workspace journal in detail pane (#669)
- Centralize agent chrome projection (#668)

## [0.19.0] - 2026-06-10

### Added
- tile-tree core model + reducer (Phase 0–1)
- tile-tree Phase 2 — protocol Surface seam + SurfaceStore (#633)
- desktop UI smoke for daily-driver flows (create workspace, terminal follows selection)
- tile-tree Phase 3 — TileTreeState is the split-layout source of truth (#645)
- reconcile orphaned workspace resources (#650)
- adopt ProcessRunner.run timeout: at all non-Lume call sites (#648)
- archive workspaces to .archived/ with purge and hidden UI (#661)

### Fixed
- harden tile tree ratio clamping
- harden ProcessRunner against subprocess hang classes (#634) (#640)
- exempt docs-only PRs from the readiness evidence gate
- trust mise config first in setup so new workspaces don't show trust errors (#657)

### Other
- lock close-focus reassignment + single-tile close no-op
- satisfy swift-format strict lint in tile-tree tests
- Fix debug performance benchmark contract
- refresh roadmap — tile-tree reversal, v0.18.0, core-reliability cluster
- tighten AGENTS.md to its startup budget (#626)
- Coordinate workspace deletion cleanup
- Document GitHub issue claim workflow in AGENTS
- bump pinned mise to v2026.6.1 to satisfy verify-mise-security
- Improve managed review timing observability
- Stabilize docs operator search
- Dedup and close prod CD failure issues
- add main window hotspot baselines (#655)
- Speed up managed review turnaround (#656)
- Simplify repo terminal toolbar title (#659)

## [0.18.0] - 2026-06-07

### Added
- terminal color theme switcher (#622)

### Fixed
- paginate release preflight check runs (#619)
- write machine-agnostic Claude hook + status-line commands (#621)

### Other
- refresh roadmap after v0.17.0 (#618)
- fix claude hook install churn (#620)
- [codex] Scope host terminal tabs (#623)
- consolidate schema bootstrap into one tracked-migration seam (#624)

## [Unreleased]

### Fixed
- Write machine-agnostic Claude Code hook and status-line commands: both forwarders extract to a stable, space-free dir (`~/.local/share/workspaces/hook-forwarders/`) and `settings.json` carries a tilde-relative, unquoted path identical on every machine. This keeps the committed dotclaude config matching runtime so `~/.claude` stops going dirty and the auto-deploy no longer silently skips. Opted-in users migrate off the older `Application Support` / `.build` bundle paths on next launch. See `docs/decisions/hook-forwarder-command-shape.md`.

## [0.17.0] - 2026-06-05

### Added
- Use git worktrees for Local workspace creation, avoiding repository-copy failures on Git internals and making new local workspaces faster (#606)
- Add workspace materializer strategy docs and lifecycle behavior for project scripts so setup/archive hooks are part of the local workspace flow (#609)
- Add managed reviewer recovery controls, a projection ledger, architecture documentation, an understanding quiz, and a visual guide for maintainers (#600, #601, #602, #610)
- Add the terminal status sliver and weekly engineering summary generator to improve session visibility and reporting (#578, #583)

### Changed
- Center managed reviewer health on durable ReviewRun state with clearer SLO/operator signals and coalesced run expectations (#599, #603, #604)
- Tighten managed-review trigger classification and evidence-comment handling so ordinary review responses do not create noisy reruns (#580, #605, #608)
- Document the final release update verification path so release closure includes a downloaded DMG and installed-app update check

### Fixed
- Repair managed review projection from completed ReviewRuns before broker repair, keeping GitHub status aligned with the durable run state (#598)
- Trigger the managed-review broker from pending status events and isolate status-event concurrency so completed reviews are projected promptly without duplicate-status interference (#611, #612, #613)
- Cache Playwright browsers in CD to reduce deployment validation friction (#607)

## [0.16.0] - 2026-05-26

### Added
- Add opt-in Claude Code integration for live agent-session signal in the host app: sidebar status, macOS notifications, status-line fields, and conversation-log context. Enable in Settings -> Agents; see `docs/development/claude-code-integration.md` (#443, #451, #452, #454, #455, #466, #473, #477, #513)
- Report Claude command status from prompt markers through a new parser, registry, and hook forwarder (#501, #566)
- Add workspace event/journal read APIs and default-agent command resolution foundations (#498, #500)
- Add GitService diff, staging, discard, and branch APIs for upcoming workspace actions (#499)
- Add Settings UI and documentation for gated experimental features (#475)

### Changed
- Embed matching changelog sections in generated Sparkle appcasts for update release notes (#497)
- Tighten managed-review run projection, operator reporting, broker workflow, deterministic canaries, and workspace-agent identity alignment (#508, #510, #562, #568, #571, #575)
- Clarify release performance gates and evidence expectations

### Fixed
- Stop installing Claude event-forwarder hooks on worktree create/remove events (#561)
- Harden managed-review intent publishing and route reviewer status to run detail pages (#504, #506)
- Fix Claude hook installation when command paths contain spaces (#513)
- Fix evidence environment discovery in worktrees
- Harden public agent identity routing for chat messages and dispatch

## [0.15.1] - 2026-05-19

### Fixed
- broker managed reviewer completions out of band (#489)
- supersede stale managed reviews (#490)
- harden local state persistence and diagnostics (#488)
- show managed reviewer pickup status (#494)
- harden perf readiness diagnostics

### Other
- Restore managed reviewer repository auth (#487)
- Refactor main window orchestration into focused controllers (#486)

## [0.15.0] - 2026-05-16

### Added
- add local SQLite state store foundation

## [0.14.0] - 2026-05-16

### Added
- add runtime diagnostics detail pane

### Fixed
- forward PR review webhooks to web app (#478)
- unblock docs deployment validation (#481)

### Other
- [codex] Publish WorkSpaces docs site (#463)
- Harden managed reviewer ingress tests (#480)

## [0.13.1] - 2026-05-12

### Fixed
- post managed PR review intents (#476)
- avoid packaged Claude hook resource crash (#477)

## [0.13.0] - 2026-05-10

### Added
- claude code hook integration (PR #1, contract layer + Channel 1)
- settings → agents pane for claude hook installer
- claude code OSC fallback channel + backup rotation (PR #3)
- claude code headless runner channel (PR #5)
- Channel 4 transcript replay + cold-start state recovery (PR #4)
- claude code statusline channel (PR #2)
- rerun on meaningful PR updates (#464)
- shape the kickoff as a follow-up on reruns (#468)

### Fixed
- wire AgentSessionRegistry to host sessions and the sidebar
- silently reinstall Claude hooks on launch when opted in
- resolveHostSession routes by agentSessionID first, cwd is SessionStart fallback
- inject agentSessionRegistry into Settings scene via keyed environment
- publish claude settings installer to settings scene
- write claude hooks using matcher groups
- prevent setup prerender auth secret failure (#462)
- command-hook forwarder for /event (Unsupported protocol http+unix:) (#466)
- make agent label migration idempotent (#470)

### Other
- swift-format pass on claude integration sources
- add TestClock and waitUntil helpers; fix CI race + sendable warning
- multi-session resolveHostSession scenarios for duplicate tabs
- make release asset validation reliable
- channel1 perf + risk tests, drivers, contract entries
- claude code integration reference
- add claude integration smoke harness
- harden mise setup
- configure Matt Pocock skills
- Refine Ghostty terminal action routing (#461)
- Enable Command+, and align shortcut catalog (#460)
- fix xcode cloud ghostty gettext setup (#459)
- speed up conductor workspace setup (#465)
- simplify agent lifecycle labels (#467)
- harden agent label migration (#469)
- verify mise security changes (#458)
- Fix Settings menu opening (#474)
- Simplify Claude integration architecture (#473)

## [0.12.0] - 2026-05-06

### Added
- use team memory for personas
- add become persona skill

### Changed
- sidebar: extract workspace presentation controller (#431)

### Fixed
- sync ghostty layer backing scale
- persist main window surface across relaunch
- gate update checks behind disclosure

### Other
- harden agent compute and release paths
- migrate notarize to App Store Connect API-key auth (#398)
- Add desktop terminal continuity manifest (#408)
- Fix CD authz Playwright validation (#439)
- rename public app bundle to WorkSpaces (#437)
- add PR reviewer evidence judgement
- add PR reviewer label intelligence

## [0.11.2] - 2026-05-03

### Other
- web: make PR reviewer kickoff reliable (#421)
- repair first-run hook setup
- reconcile current P0 maintainability state
- add root mise task catalog
- align roadmap web runtime facts (#428)
- extract expansion state controller
- security: harden release and terminal compute
- document release hardening mechanics
- refresh improve codebase command flow
- web: target Vercel PR previews
- allow web preview PR comments
- web: teach PR reviewer narrative labels
- clarify release workflow publication

## [0.11.1] - 2026-05-03

### Changed
- centralize Ghostty callback userdata resolution
- desktop: isolate Ghostty runtime config callbacks (#387)

### Fixed
- release: skip perf parity when runner has no foreground GUI session (#389)
- release: harden codesign against errSecInternalComponent (#388)
- release: sign Sparkle nested helper bundles for Developer ID builds

### Other
- add notarization preflight step before heavy build work (#399)
- scope workspace sync by owner
- resolve production dependency audit
- fail closed without ttyd token secret
- keep terminal clone tokens out of URLs
- Add privacy-first Sparkle updates (#413)
- scope agent sessions to users
- verify repo selections server-side
- make setup pnpm install noninteractive
- add PR review narrative context
- remove legacy Workspaces display fallbacks
- Add app-owned terminal tabs and shortcuts (#401)
- fix local login setup flow (#400)
- rename displayed app brand to WorkSpaces
- remove PR reviewer attribution line
- add performance PR evidence profile (#391)
- add PR reviewer decision banner (#390)

## [0.11.0] - 2026-05-02

### Added
- web: post PR reviews via GitHub API (#363)
- cd: preview→validate→promote pipeline with bootstrap orchestrator (#344)
- web: automated PR review via Managed Agents (#345)
- web: qa-web skill + subagent with change-aware exploration and report presentation (#343)
- web: E2E harness for managed-agents + dev-bypass token fix
- web: Anthropic Managed Agents provider + unified terminal abstraction (#332)
- web: install pi, skills, mise, uv in Vercel sandbox base snapshot (#329)
- web: add Managed Agents as opt-in compute provider (#325)
- web: Spaces welcome banner in terminal (v4-welcome) (#321)

### Changed
- terminal: extract Ghostty threading, userdata, clipboard, and scale seams (#371)
- desktop: reduce render-cycle work and harden reliability (#341)
- web: wrap remaining runCommand calls in assertRunCommand (#320)

### Fixed
- desktop: gate runtime NSApp.activate via AppActivationPolicy (shared-desktop Phase 1) (#374)
- web: use ./tmp instead of /tmp for review temp files
- web: use file + jq for PR review body to preserve markdown
- web: attribute PR reviews to Claude + fix token mount path (#367)
- cd: run vercel CLI from repo root (project has rootDirectory=web) (#359)
- cd: bypass Vercel Deployment Protection for preview validators (#354)
- cd: strip ANSI escapes from playwright findings
- cd: checkout repo in fail-notify jobs
- cd: resolve fail-notify module via absolute file URL
- cd: deploy prebuilt artifact with --prod --skip-domain
- cd: add VERCEL_PROJECT_ID to deploy + promote env blocks (#351)
- cd: target Node 24 + Vercel CLI 51 to match project settings (#350)
- cd: point pnpm/action-setup at web/package.json (#349)
- web: stable sub-tab order (sort by created_at, not last_activity_at) (#333)
- web: ensure tmux socket dir exists before ttyd launch (#331)
- web: pass GitHub token to managed-agents provider (#330)
- web: strip .git suffix from repo name in welcome banner (v4-welcome-c) (#323)
- web: welcome banner via /etc/profile.d (v4-welcome-b) (#322)

### Other
- add landing login link (#384)
- Update GhosttyKit to latest stable (#380)
- Add GitHub App authentication for PR reviewer (#370)
- refactor+fix(web): simplify shared patterns; close read-API authz gaps (#342)
- [codex] Harden Workspaces performance system (#338)
- add PostHog telemetry to web (#336)
- Optimize Workspaces UI latency and expand perf diagnostics (#304)

## [0.10.0] - 2026-04-09

### Added
- standalone terminal sessions — no agent chat required (#295)
- terminal per agent with sub-tabs in Terminal and Chat (#298)
- run tmux inside sandbox for real Resume continuity (#311)

### Fixed
- make terminal tab actually work in production (#292)
- check sandbox.status in resolveSandboxState (#293)
- implement ttyd WebSocket protocol in terminal panel (#297)
- terminal resize bug + multi-agent UX polish (#299)
- terminal security + correctness fixes from reflection (#302)
- unblock terminal start button (47s INP block) (#303)
- close ttyd auth gap for agent sandboxes + small polish (#305)
- claude CLI auth in sandboxes + runner extraction + backlog reconcile (#306)
- claude apiKeyHelper as a real shell script (not echo \$VAR) (#307)
- source env.sh in agent runner — Sandbox.create env doesn't propagate (#309)
- webhook_events composite index + getEventStats cache + poll bump (#314)
- install tmux into /usr/local/bin so it survives Vercel snapshot (#316)
- v3-tmux-b — bundle tmux shared libs + install manifest probe (#317)
- assert runCommand exitCode in base snapshot build (v3-tmux-c) (#318)
- install tmux as a static binary (v3-tmux-d) (#319)

### Other
- Add self-hosted runner management skill (#296)
- debug(web): add diagnostic probe to agent runner script (#308)
- claude CLI auth section + terminal arc retrospective (#310)
- Revert "feat(web): run tmux inside sandbox for real Resume continuity (#311)" (#312)
- debug(web): /api/debug-db endpoint to diagnose dashboard 500s (#313)
- Reapply "feat(web): run tmux inside sandbox for real Resume continuity (#311)" (#312) (#315)

## [0.9.0] - 2026-04-06

### Added
- cap agent WIP and shift toward closure-first behavior (#207)
- pre-fetch PR diffs into agent review context (#201)
- agent discovery dashboard Phase 1 (#206)
- collapsible dashboard sections with sticky state (#216)
- collapsible dashboard sections with sticky state (#217)
- bookmarkable URL routing for dashboard repo views (#222)
- clickable event details with GitHub source links (#223)
- add prek pre-commit hooks for swift-format and biome lint
- add Carl Community agent for daily project commentary (#187)
- workspace state sync endpoint (#179) (#245)
- integrate chat platform — AI streaming, Slack, dispatch, status cards, chat UI (#246)
- evidence tooling for local and CI use (#254)
- @agent chat with compute backend abstraction (#257)
- durable-workflows skill — PGlite + DBOS crash-resilient workflows (#247)
- collapse consecutive events in chat timeline (#271)
- autofocus chat input when switching to Chat tab
- collapsible panels + keyboard shortcuts (#275)
- persistent sandbox via snapshot API for conversation continuity (#277)
- claude --resume for full conversation memory (#278)
- session-manager tests + threadId continuity fix (#285)
- mock provider + E2E agent chat tests (#286)
- default agent for chat messages (#287)
- terminal tab with ghostty-web + TerminalShare proxy (#288)
- multi-provider terminal — Vercel ttyd + Cloudflare sandbox (#290)

### Fixed
- gate inline PR diffs to trusted sources (#210)
- surface API errors on setup page (#213)
- debug webhook signature failures (#220)
- surface agent API errors and webhook debug logging (#221)
- validate Lume unattended inputs before temp file creation
- harden Codespaces Claude worker launch flow
- setup script installs dependencies from lockfiles
- ensure data directory exists for local SQLite fallback
- sort imports for biome linting
- biome lint and format compliance
- show tab bar on desktop for Dashboard/Chat switching (#248)
- show tab bar on desktop for Dashboard/Chat switching (#249)
- refresh expired GitHub OAuth tokens (#250)
- quality fixes for chat platform merge (#251)
- make chat tab bar sticky during scroll (#253)
- wire mention kill switch and harden evidence store (#256)
- exclude e2e from vitest/biome, add evidence hook to settings (#258)
- gate scheduled agent runs on AGENT_SCHEDULED_RUNS_ENABLED (#260)
- unified AGENT_AUTOMATIONS_ENABLED kill switch for all agent workflows (#261)
- harden agent runtime — resource leaks, auth config, error handling (#264)
- update sandbox E2E test for ALLOWED_AGENT_LOGINS rename (#268)
- hooks order and biome lint in collapsed events (#271)
- symlink .env from main worktree in scripts/setup (#276)
- revert stream-json, keep plain text streaming (#283)
- disable --session-id/--resume in runner until CLI version verified (#284)

### Other
- Add Codespaces Claude worker runtime substrate
- Add Codespaces Claude launcher
- Add Codespaces Claude worker workflow docs
- agents: harden prompt trust boundaries (#209)
- pin actions and remove committed Lume guest credentials (#208)
- add mention automation kill switch (#211)
- agents: isolate contributor execution from secrets (#212)
- Install Vercel Web Analytics (#218)
- security: default Lume to NAT and disable public mentions
- security: add approval-gated agent triage
- review PR files from pull refs
- update roadmap learnings for web dev reliability
- broaden PR evidence requirements to cover all change types (#242)
- broaden evidence rules in AGENTS.md for all PR types (#243)
- security: pin remaining floating action, add explicit permissions, harden tests (#239)
- session wrapup — chat platform consolidation learnings
- add behavior tests for GitHub token refresh (#252)
- expand test coverage with unit tests and Playwright E2E (#255)
- add chat & agent dispatch design documents
- add unit tests and E2E fast tests to Web CI (#259)
- session wrapup — security review and agent kill switch
- session wrapup — agent chat runtime design and implementation
- session wrapup — QA, test coverage, agent runtime hardening
- trigger redeploy with sandbox env vars
- add evidence guide for PR screenshots (#267)
- add Playwright auth fixture with DEV_BYPASS_AUTH (#262)
- validate agent chat sandbox pipeline E2E (#265)
- sandbox testing session wrapup (#269)
- bot command tests + E2E data seeding + auth fixture (#270)
- session wrapup — chat timeline collapsed events
- comprehensive chat E2E tests and video demo recordings (#273)
- fix INP on compose bar and reduce re-renders (#280)
- move persistent sandbox backlog item to done (#281)
- snapshot session lifecycle + stream-json parser (#282)
- session wrapup for web perf PR #280
- [codex] Add Workspaces optimization skill and diagnostics (#291)

## [0.8.1] - 2026-03-24

### Fixed
- skip CI preflight gate for changelog-only release commits

### Other
- v0.8.1

## [0.8.1] - 2026-03-24

### Fixed
- skip CI preflight gate for changelog-only release commits

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
