# Changelog

## [0.24.0] - 2026-08-09

No new user-facing capability in this release. The work went into consolidation —
40 fixes, and 13 refactors that mostly decompose `ContentView` into focused units
(#1160) — plus infrastructure behind the agent factory, roughly a third of the
commits on its own. What features did land serve testing and operation rather than
the product: typed wait and focus primitives, per-scenario UI-state goldens, and a
synthetic-run isolation boundary.

### Added
- validate active compute provider (#1043)
- add Folio conversation ports (#1057)
- monitor telemetry workflow with ops-data write path (#1067)
- digest writer — one marked discussion, gates by age (#1071)
- digest as pinned issue — retire the discussion-token dependency (#1076)
- reconciliation janitor — the monitor repairs state daily (#1078)
- dispatch ready issues to April (#1096)
- route agent PRs to counterpart review (#1097)
- owner-comment responder — reply-only v1 (#1095)
- integrate implementation evidence (#1101)
- add safety rails and dispatch observability (#1099)
- first-class ci and diff evidence kinds with a CI verifier lane (#1136)
- review-time live CI verification and diff evidence completion (#1137)
- per-run cost telemetry rows and stream-json transcript artifacts (#1145)
- local factory dashboard over cached GitHub + ops-data history (#1146)
- close rolling CD-failure issues on green validation (#1165)
- level-triggered sweep for the standing ready queue (#1172)
- seed continuity data so fixture mode can stage the restore banner (#1205)
- ship workspaces-factory[bot] worker-identity machinery (#1203)
- require one approving review on main-merge (#1206) (#1213)
- archive-with-teardown + typed retryable error semantics (#1256)
- release-gate the dev smoke/fixture harness behind a SmokeScenarioDriver seam (#1255)
- WORKSPACES_SYNTHETIC_ROOT synthetic-run boundary (#1245)
- reconnect the perf alarm wire and close contract coverage gaps (#1249)
- typed wait + focus primitives (POST /v1/wait, GET /v1/focus) (#1265)
- GET /v1/ui-state + per-scenario UI-state goldens + tokenless evidence capture (#1259)
- group operator verbs under 'automation' and bridge the two-plane state split (#1253)
- add Mara Fielding product-manager persona + /pm triage workflow (#1270)
- token-authenticated agent API on the feedback store (#1273)

### Fixed
- finish hero-flow follow-ups (#1041)
- prevent stale harness server reuse (#1042)
- guard repair sweep against polluted zig cache (#1049)
- Discussion has no state field — use closed boolean (#1073)
- show repo/branch once — hide the duplicate centered window title (#1086)
- claim survives App-token agent-assignment restriction (#1104)
- seed Claude project trust for contributor workspaces (#1105)
- echo stdout when a checked command fails (#1106)
- restore OAuth auth — drop --bare, gate isolation on project trust (#1107)
- preserve scratch symlinks; guard .claude/ paths (#1108)
- dismiss stale reviews on push — M3 review-lane TOCTOU backstop (#1102)
- pre-approve exposed tools so headless edits land (#1112)
- seed Mergeability section in contributor PR bodies (#1130)
- responder-lane coexistence + code-span-safe mention detection (#1129)
- terminal label hygiene + admission-stage comment voice (#1131)
- scope contributor write grant and adopt stream-json telemetry (#1134)
- pin and restrict planner lane model invocation (#1133)
- sanitize planner-lane model subprocess env (#1144)
- security-hardening test asserts claude.yml stays deleted (#1175)
- absorb loaded-runner spawn overhead in timing-sensitive suites (#1176)
- enable evidence-verify lane and guard FACTORY_*_ENABLED vars (#1185)
- restore CI gate on WebNextServerServiceTests pending load-adaptive rework (#1197)
- count successful reviews, not raw attempts, toward daily cap (#1202)
- guard evidence-verify writes against body drift, not just SHA drift (#1207)
- retry-once reviewer runtime crashes, harden output-parse salvage (#1179) (#1209)
- deliver the model task via stdin, not argv (#1212)
- drop embedded PEP 723 header from factory identity test fixture (#1250)
- operator scope integrity — App Intents gate, registry eviction, tile.close outcome (#1242)
- abandoned click-to-focus measurements no longer pollute the perf baseline (#1248)
- skip the surface_focused dead wait when activation is suppressed (#1243)
- clean created worktrees on every desktop-ui-smoke outcome (#1247)
- distinct tmux sessions per split pane, restore by probed name (#1246)
- ordered, diffed continuity writes; ended rows never resurrect (#1254)
- socket read/write deadlines, connection cap, disconnect handling, audit rotation (#1241)
- guard launch-dev.sh --fixture with WORKSPACES_SYNTHETIC_ROOT (#1275)
- thread each tile's automation handle through tmux per-session env (#1260)
- read UserDefaults from a scratch suite on isolated launches (#1258)
- adopt ProcessRunner timeouts + CI tripwire for un-timed subprocess calls (#1244)
- close makeHangingGitStub in WorkspaceOrphanReconcilerTests (#1285)
- unbreak main CI — test-target compile break and a frozen docs date (#1284)

### Other
- encode W6 retrospective (#1048)
- web-next: establish the Folio package boundary (#1056)
- package Folio styles (#1058)
- web-next: consume Folio through its public conversation port (#1059)
- web-next: produce a versioned installable Folio artifact (#1060)
- encode agent factory v2 plan, ADRs, and glossary (#1061)
- pin codex dispatch to gpt-5.6 (#1068)
- correct codex model pin to gpt-5.6-sol (#1069)
- retire v1 agent automation (cleanup wave) (#1070)
- fail fast when Vercel protection-bypass is not honored (#1072)
- visual changes require visual evidence (#1087)
- browser-readable system overview and trust model (#1100)
- link Agent Factory v2 overview page from README (#1113)
- Reject . and .. path-traversal segments in isValidRepoFullName (#1114)
- Fix session-cookie tamper test to flip full-payload-bit char (#1115)
- fixture sweep, persona prune, ops lessons docs (#1132)
- web-next: prove Folio external consumer
- In response to codex (gpt-5.6-sol, xhigh) harden Folio proof
- In response to Claude Fable (claude-fable-5, xhigh) harden Folio release flow
- add Agent Factory v2 arc post (#1143)
- delete dormant claude.yml workflow (#1166)
- run all scripts/tests/*.py via a directory loop, not hand enumeration (#1169)
- deletion wave — dead scripts, root-file cruft, force-added output PNG (#1168)
- retire the managed PR reviewer (#1167)
- mechanical cleanup — dead types, Lume DTO dedup, schema header, build nits (#1170)
- hygiene pass — web-ci path filter, timeouts, concurrency groups, LEDGER/specs (#1171)
- zombie sweep + current-state doc (#1174)
- migrate 146 NSLog call sites to os.Logger (#1173)
- AGENTS.md truth pass — kill Discussions routing, two-web-apps charter, token budget (#1182)
- extract workspace-orphan reconciliation from ContentView (#1160 slice 1) (#1186)
- unify os.Logger categories within bracket-tag families (#1184)
- markdown link-check gate + repair broken internal refs (#1187)
- extract background maintenance passes from ContentView (#1160 slice 2) (#1188)
- StrictConcurrency warnings + swift-format safety rules; triage 3 env-sensitive test failures (#1189)
- extract code-preview dirty-navigation guard from ContentView (#1160 slice 3) (#1190)
- extract session-switcher projections from ContentView (#1160 slice 5) (#1193)
- extract session-restore banner flow from ContentView (#1160 slice 4) (#1191)
- extract main-window lifecycle sequences from ContentView (#1160 slice 6a) (#1194)
- move the four non-ContentView view types out of ContentView.swift (#1160 slice 6c) (#1198)
- extract alert and sheet presentation bindings from ContentView (#1160 slice 6b) (#1196)
- reconcile triage-labels.md and mergeability-standard.md after label removal (#1201)
- encode binding-mutation-check testing lesson in AGENTS.md (#1200)
- make WebNextServerServiceTests spawn-adaptive and un-gate it in CI (#1204)
- commit the workspaces-factory App logo as config-as-code (#1211)
- workspaces-factory App created + installed — worker-identity rollout proof (#1210)
- advisory PoC — desktop-ui-smoke on hosted macos-15 (#1264)
- consolidate api/desktop smoke setup+teardown into scripts/lib/api-smoke-common.sh (#1274)
- seed the initial host session before the first layout pass (#1276)
- direction-only ROADMAP rewrite (proposal for #1158) (#1214)
- extract ContentView selection + landing clusters, gate fixture parsers (#1261)
- retire tart-ui perf cron — perf goes laptop-opt-in, smoke stays on hosted runner (#1280)
- restructure AGENTS.md — root invariants + routing table, nested surface context, lessons ledger (#1282)
- pin the preferences axis, label every launch sample, and characterise the #1276 residual (#1286)
- record why launchd-launched GUI apps miss shell env (#1283)

## [0.23.0] - 2026-07-10

### Added
- tile-tree P5 — SurfaceStore is live owner + single eviction authority (#701)
- responsive layout — sidebar drawer + reachable activity feed on narrow viewports (#732)
- PR_REVIEWER_RERUNS_ENABLED rollout flag + structured skip-reason logs (#738)
- scheduled contributors read curated repo memory (Phase 2 read side) (#765)
- Fable orchestrator v1 — one daily recommendation (#768)
- reasoning traces + adversarial mock (#784, #785) (#787)
- auth-gated AI Gateway diagnostic probe (#797)
- real harness-backed agent runtime + sandbox template prewarm (#750) (#822)
- real message-driven turns + durable session resume, and unbreak the runtime inside Next.js (#826, #750) (#831)
- experimental caller-scoped `input.write` capability (#799)
- `ws race` — fan one prompt across N worktree workspaces (#801)
- GitHub repo settings as code (rulesets + drift gate) (#835)
- tile-tree P6 — web main content through the Surface seam (#841)
- Vercel env vars as config-as-code (spaces-web + web-next) (#847)
- weekly mise-pin-refresh owns staleness; PR lane demotes it to a warning (#852)
- milestone legibility — lane/order title prefixes + drift gate (#858)
- real foreground-process names for plain terminal tabs (tmux mode) (#666) (#893)
- restore-aware retention + integrity probe (#789) (#886)
- native diff review surface (slice 1 of #704 Phase 3) (#894)
- browser.read web-surface listing (#679 slice 1) (#898)
- per-session model selection — pick, persist, route, display (#903)
- GitHub-backed repo picker with validation + default branch (#902)
- session titles — auto from first turn, inline editable (#908)
- terminal drawer — a real shell into the session's sandbox (#752) (#912)
- bounded web-surface snapshot route (#679) (#926)
- validation stages — per-model gateway sweep (#816) + deployed-safe e2e vs deployed envs (#817) (#927)
- surface streaming turn failures — inline error + retry (#929)
- latest-activity snippets on session cards (#680 slice 3) (#930)
- lifecycle controls + first-class error surfaces + mobile 375px (#935)
- validation W3 — real agentic turn probe (#818), reporting + scheduled lane (#819), authed flows close-out (#814) (#937)
- operator scope end-to-end — opt-in launch, minted credential, window.read, CLI window list (#916) (#941)
- window.snapshot — WindowSnapshotService + route + CLI, terminal surface included (#917) (#942)
- one-command app evidence lane — launch fixture, snapshot, upload (#918) (#943)
- workspace.read — operator read route + CLI (#919) (#946)
- gesture-verb layer + workspace.select through the real selection binding (#920) (#947)
- add workspace create gesture verb (#952)
- diff-review stage/unstage/discard + dirty-nav veto (#704) (#924)
- turn-completion webhook notifications (#971) (#974)
- quiet sign-out from sessions header (#871) (#978)
- checkpoint sandbox turns after completion (#968) (#980)
- tile-orchestration — coordinate codex workers in WorkSpaces tiles (#996)
- replay conversation context on fresh fallback turns (#997)
- add workspace.create options (#989) (#1005)
- bounded surface read for created workspaces (#990) (#1006)
- workspace.archive verb + health server metadata (#991, #992) (#1007)
- tile-orchestration — usage-quota check before fanning out (#1009)
- host compute provider — turns via the local claude binary (#981) (#1012)
- session list search, filters, and keyboard resume (#986) (#1002)
- approval protocol — request/resolve chunks, broker, endpoint, card (#982) (#1016)
- local single-user serving mode — loopback + minted token (#983) (#1017)
- harness config parity — allowlisted content injection + receipt (#985) (#1019)
- mid-turn steering — durable message queue (#984) (#1018)
- open a draft PR from a session (#820) (#1021)
- WebNextServerService — supervise local-mode web-next (#987 N1) (#1029)
- session-create deep-link, healthz, sign-in redirect (#987 W1) (#1030)
- embedded web-next surface + shortcut + New Web Session (#987 N2) (#1031)

### Fixed
- validate session freshness in middleware, not just cookie presence (#727)
- update model to Sonnet 5 and fail fast on missing API key (#760)
- fall back to a real renderer outside the WorkSpaces app (#788)
- dedup guard + audit trail on admin publish (#766)
- use existing CLAUDE_CODE_OAUTH_TOKEN; drop temperature (Sonnet 5) (#791)
- stop persisting App token on disk, pin Claude Code CLI (#762)
- durable resume — DB-authoritative turn liveness across instances (#830)
- turn-runtime robustness — concurrency guard, atomic close, structured errors (#832)
- bound managed-agents transcript SSE lifecycle (#833)
- cap lingering web pages LRU in SurfaceStore (#849)
- web-detail eviction authority — selection state, not view lifecycle (#853)
- resolve Homebrew zig via brew --prefix, not a hardcoded path (#854)
- accept BETTER_AUTH_SECRET for terminal signing in prod agent config (#857)
- exclude archived workspaces from repo count badge (#865)
- fold the mise pin into the base-snapshot cache key (#868)
- geometric directional tile focus at depth ≥ 2 (closes #690) (#867)
- unarchive legacy workspaces in place (#663) (#863)
- clarify orphan-cleanup failure when workspaces storage is missing (#884)
- structured timeout outcomes in managed-review health scripts (#885)
- banner frequency guard + working resume delivery (#783) (#888)
- force NODE_ENV=production on next build/e2e:server (#780) (#900)
- bootstrap native Homebrew when Xcode Cloud's zig is wrong-arch (#907)
- give a landed edit one home — its Edit ledger row (#790) (#909)
- cross-compile the GhosttyKit slice when Xcode Cloud's zig is wrong-arch (#925)
- API routes answer 401 JSON at the edge; reconcile design.md fonts (#931)
- folio as default validation target + gateway probe headroom for reasoning models (#949)
- capped retry with backoff on transient 429/5xx (#956)
- trim GhosttyKit's repair sweep to a thin, host-arch-only archive (#962)
- thread the session repo into the compute provider (#967) (#975)
- harden auth bypass and session ownership (#977)
- adaptive sandbox idle-stop with settled-turn guard (#1001)
- mobile status-line gutter + 44px touch targets (#809) (#1010)
- link per-app env files into worktrees, not just root (#1013)
- naturally follow active turns (#1034)
- size embedded web-next readiness for cold first-run build (#1035)
- parse multi-line .env values so the GitHub App key loads (#1036)

### Other
- refresh roadmap to v0.22 + groom backlog (milestone #9, idea/stale labels) (#711)
- Refactor preview QA to reusable alias (#702)
- Add guarded native text editing phase 1 (#713)
- Clear acknowledged Needs You notifications
- Add save command for native editor
- Polish managed review run detail
- cover managed review run detail
- correct roadmap — chat/discovery web work shipped, not stale
- Harden native editor save path (#720)
- Extract attention summary resolver to core (#722)
- plan: web next-cycle execution plan grounded against live code (#723)
- refresh LEDGER verified dates for authz suite run (#726)
- retire disabled Chat SDK bot path, keep dashboard Chat tab (#725)
- add DOM component-test lane for dashboard regressions (#731)
- freshness sweep + encode 2026-07-02 cycle learnings (#735)
- Add continuity read models to LocalStateStore (durable sessions slice 1) (#730)
- archive completed web next-cycle plan to done/ (#736)
- encode 2026-07-02 session retrospective at the right surfaces (#739)
- add retro skill; wire it to arc-close moments (#740)
- Add TerminalRestorePlanner for cold-start restore (durable sessions slice 2) (#742)
- Add production restore probes for TerminalRestorePlanner (durable sessions slice 3a) (#743)
- Wire cold-start restore planning behind an experimental flag (durable sessions slice 3b) (#755)
- Web experience redesign: sessions-first greenfield plan + Phase 0 spike (#741)
- web-next: CI + evidence + performance harness (#761)
- Add restore banner + execution (durable sessions slice 3c) (#758)
- Add session-history read/view-model layer (durable sessions slice 4a) (#763)
- web-next: Folio design system as React components (#769)
- web-next: session_events + sessions schema + UIMessage projection (#770)
- web-next: auth + sessions home + new-session flow (#771)
- web-next: mock provider streams into the live Folio transcript (#772)
- web-next: durable, resumable turns (detached ingest + tail route) (#773)
- Fix 1-in-16 flake in session-cookie tamper test (#774) (#775)
- correct agent fleet state — automations are live, not gated off (#764)
- Add session history browser window (durable sessions slice 4b) (#782)
- Fix reboot-resume: login-shell resume launch + previous-run scoping (#783) (#786)
- adopt @ai-sdk/harness as session runtime (ADR + plan revision) (#777)
- orient agents to the live Issues+labels bus (#767)
- add canonical design doc; archive the pre-Folio design era (#781)
- web-next: turn structure — soft turn frame + drop tool-ledger rule (#779)
- require an author:<agent> label on agent-authored PRs (#792)
- repair the e2e lane after #787 — sessions spec + a latent auth flake (#793)
- tolerant field matching + sticky feedback comment (#794)
- CONTRIBUTING.md — local dev setup + real-runtime credentials (#796)
- architecture.html — the stack, a turn's anatomy, credential placement (#803)
- web-next: roadmap to usable + validation harness (reachability & posture vs local/prod) (#827)
- bump sandbox mise pin to v2026.7.0 (#840)
- instrument ci_post_clone.sh so failures name their step (#795)
- record Orca race track — Phase 0+1a shipped, follow-ups filed (#839)
- record reviewer pause + required-check removal (#834)
- tile-tree P7 rename sweep (TileTreeStore) + P8 CONTEXT.md glossary (#842)
- PEM is a sensitive env var now; vercel env pull can't verify it (#846)
- bump sandbox mise pin to v2026.7.1; SHA-pin checkout in repo-settings-drift (#850)
- prepare 0.23.0-beta.2 tester prerelease (#851)
- groom milestones into two sequenced lanes; close phantom P0 (#848)
- encode the codex review loop as a project skill (#859)
- trim codex-review-loop to behavior drivers (#860)
- promote [D3] desktop breadth milestone; record backlog triage (#861)
- mise pin refresh runs as a Claude routine, not a GH workflow (#866)
- gitignore .agents/inbox/ (local coordination messages) (#870)
- diag(ghostty): add toggleable GhosttyKit architecture diagnostics (#869)
- dedup bootstrap controller + error-presentation seam (PR 1/2) (#875)
- extract the session-retirement close state machine (#710 slice 1) (#877)
- coalesce agent-event status aggregation (#637) (#876)
- migrate error call sites onto the presenter seam (PR 2/2) (#879)
- extend the archive/unarchive lifecycle regression net (#881)
- correct stale "web-next has no perf budget" — floor shipped in #761 (#883)
- Route standard app menu shortcuts to AppKit (#862)
- record D1 (#9) close-out; durable sessions (#10) now the active desktop milestone (#890)
- pin milestone-legibility actions to SHAs (#891)
- promote session-card read model to Core, delete dead switcher layer (#680 slice 1) (#896)
- unify sidebar attention onto the shared severity ladder (#680 slice 2) (#897)
- D2 (#10) closed; D3 (#15) active and substantially shipped (#899)
- baseline-relative regression guard + deployed-target measurement (#887)
- arg-based clean script replaces ad-hoc rm -rf (#904)
- label-gated opt-in Vercel preview; disable Git auto-deploy (#905)
- web-next validation identity (#814) (#906)
- encode the no-ad-hoc-rm-rf cleanup convention at repo surfaces (#911)
- automation operator scope + two-arc strategy (#913)
- fetch Xcode Cloud build logs via the App Store Connect API (#928)
- record #915 capture-spike outcome in facts-before-mechanism (#933)
- debugging runbook — real log access, SHA-pinned watching, VM quirks (#940)
- [A1] closed — flip A-lane stack to [A2], add retro learnings (#945)
- web-next: keyboard-reachable reveals + AA contrast + multiline compose (#805, #806, #807) (#948)
- document the D-lane feature additions (#679, #680, #894) (#951)
- web-next e2e: deterministic DB bootstrap + isolated, event-driven session specs (#901, #932) (#950)
- W-arc closeout — folio ship recorded, roadmaps synced, codex-execution skill (#953)
- Add App Intents for workspace verbs (#954)
- Add API desktop smoke parity lane (#955)
- W-arc reflection — what we set out to do, surprises, advice, loose ends (#957)
- [A2] closeout — A-lane complete, retro learnings, delegation preflight (#960)
- automation two-arc program retrospective (#964)
- host-compute daily-driver decision — build, host-first (#972) (#988)
- W5 closeout pair — subscription-billing decision (#972) + automation-dogfood report (#979)
- add orca-agents skill for opt-in Orca fan-out (#993)
- close out the D-lane (milestones #9, #10, #15) (#961)
- D-lane closeout retrospective (D1 #9, D2 #10, D3 #15) (#966)
- harden tile env injection diagnostics (#973) (#1000)
- roadmap — W5 closed 8/8, W6 next (#1003)
- tile-orchestration usage guidance, gotchas, concurrency findings (#1008)
- remove accidentally committed worker report (#1011)
- encode W6 review-loop learnings — directed reviews, attack patterns (#1020)
- W6 retro — host compute daily driver, review-loop data (#972 arc) (#1022)
- filmed hero-flow demo spec — real turn to draft PR (#1025)
- docs diffs don't trigger the build/perf gate (#1023)
- embedded-native contract for #987 — spawn, readiness, token handoff, deep-links (#1028)

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

### Added
- Native diff review: open a changed file's diff in-app (add/remove/context coloring, old|new gutters) from the Changes tab or the code editor (#704).
- Session cards show live activity: a status-derived snippet on session switcher rows (running tool + detail, "waiting for permission," or the error), and the sidebar hover card surfaces the last assistant message from a Claude Code session's transcript (#680).
- Automation API: read-only `browser.read` capability exposes embedded web surfaces to local scripting — `GET /v1/web-surfaces` lists them (live URL/title only when a view is open) and `GET /v1/web-surfaces/{id}/snapshot` returns a bounded PNG of a live surface (#679).

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
