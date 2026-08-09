# Code Map

Pointers from a task or symbol to the file that answers it — moved out of `AGENTS.md` to keep that file under its token budget (see `AGENTS.md` § "Startup Instruction Budget"). Read `AGENTS.md` first for policy; come here once you know *what* you need but not *where*.

## Doc Navigation

| Task | Primary Doc | Skip |
|------|-------------|------|
| Surface-specific agent context (auto-loaded per directory) | Sources/AGENTS.md, Tests/AGENTS.md, web/AGENTS.md, web-next/AGENTS.md, backlog/AGENTS.md | - |
| High-signal lessons ledger (full history + rationale) | docs/agents/lessons.md | - |
| Understand the app | README.md | backlog/ |
| Architectural decisions | ARCHITECTURE.md | backlog/ |
| Implement a component | docs/original_spec.md (find relevant section) | Read whole file |
| libghostty internals + dev verification runbook | docs/development/libghostty-integration.md | - |
| Notifications / webhooks | docs/development/notifications.md | - |
| Debug an issue | docs/development/troubleshooting.md | - |
| Add Settings-gated experimental UI | docs/development/experimental-features.md | - |
| Terminal keyboard focus | docs/development/solution-terminal-keyboard.md | - |
| Evidence guide | docs/development/evidence.md | - |
| UI fixture mode + release screenshots | docs/development/ui-fixture-mode.md | - |
| Local SQLite state schema | docs/schema.sql | - |
| Local state store plan | docs/development/local-state-store-plan.md | - |
| Lume integration / daemon reliability | docs/development/lume-integration.md | - |
| Lume validation lanes | docs/development/lume-validation.md | - |
| Lume runner setup | docs/development/lume-runner-setup.md | - |
| Xcode Cloud harness + debugging (real logs, VM quirks) | docs/development/xcode-cloud.md | - |
| web-next local dev (active app; plain pnpm, no mise) | web-next/CONTRIBUTING.md | - |
| web-next architecture (browser doc) | web-next/docs/architecture.html | - |
| web-next ↔ macOS embedding contract | web-next/docs/decisions/embedded-native-contract.md | - |
| web/ local dev (maintenance mode; mise tasks, auth bypass) | web/docs/local-dev.md | - |
| web/ architecture | web/docs/architecture.md | - |
| Agent Factory current state (lanes, switches, ops-data, dashboard) | docs/development/factory-current-state.md | - |
| Agent Factory design record (why the pipeline looks like this) + glossary | docs/development/agent-factory-v2-plan.md, docs/agents/CONTEXT.md | docs/development/agent-team.md (superseded architecture) |
| Agent Factory system overview + trust model (browser doc) | docs/development/agent-factory-v2-overview.html | - |
| Roadmap/planning | backlog/ROADMAP.md | - |
| Deferred work items | backlog/*.md | - |
| Prototypes | prototypes/README.md | - |

## Code Navigation

| What | Where |
|------|-------|
| Data models | Sources/WorkspaceManagerCore/Models/Models.swift |
| Git operations | Sources/WorkspaceManagerCore/Services/GitService.swift |
| Workspace lifecycle | Sources/WorkspaceManagerCore/Services/WorkspaceService.swift |
| Local state history | Sources/WorkspaceManagerCore/Services/LocalStateStore.swift |
| Service protocols | Sources/WorkspaceManagerCore/Services/Protocols.swift |
| Backend abstraction | Sources/WorkspaceManagerCore/Services/LocalBackend.swift |
| Lume runtime setup | Sources/WorkspaceManagerCore/Services/LumeRuntimeService.swift |
| Lume workspace orchestration | Sources/WorkspaceManagerCore/Services/LumeWorkspaceProvider.swift |
| Lume daemon transport | Sources/WorkspaceManagerCore/Services/LumeHTTPClient.swift |
| Lume CLI runner | Sources/WorkspaceManagerCore/Services/LumeCLIRunner.swift |
| Lume image catalog | Sources/WorkspaceManagerCore/Services/LumeImageCatalog.swift |
| Lume VM status normalization | Sources/WorkspaceManagerCore/Services/LumeVMStatus.swift |
| Lume error heuristics | Sources/WorkspaceManagerCore/Services/LumeErrorHeuristics.swift |
| Main layout | Sources/WorkspaceManager/Views/MainWindow/ContentView.swift |
| Terminal wrapper | Sources/WorkspaceManager/Views/Components/TerminalView.swift |
| Sidebar (repos/workspaces) | Sources/WorkspaceManager/Views/MainWindow/SidebarView.swift |
| Right pane (files/changes) | Sources/WorkspaceManager/Views/MainWindow/RightPaneView.swift |
| Notification constants | Sources/WorkspaceManagerCore/Services/NotificationConstants.swift |
| Notification coordinator | Sources/WorkspaceManager/Views/MainWindow/NotificationCoordinator.swift |
| WebSocket event stream | Sources/WorkspaceManagerCore/Services/EventStreamService.swift |
| GitHub Device Flow auth | Sources/WorkspaceManagerCore/Services/GitHubDeviceAuth.swift |
| JWT session exchange | Sources/WorkspaceManagerCore/Services/NotificationSessionService.swift |
| Keychain storage | Sources/WorkspaceManagerCore/Services/KeychainHelper.swift |
| Webhook event model | Sources/WorkspaceManagerCore/Models/WebhookEvent.swift |
| Cloudflare Worker (webhooks) | infra/cloudflare-webhook-relay/ |
| Cloudflare Worker (evidence) | infra/cloudflare-evidence-store/ |
| Evidence upload script | scripts/upload-evidence.py |
| Tests | Tests/WorkspaceManagerTests/ |
| web-next app routes | web-next/src/app/ |
| web-next Folio conversation UI package | web-next/packages/folio/ |
| web-next embedding (native side: spawn, healthz, token handoff) | Sources/WorkspaceManagerCore/Services/WebNextServerService.swift, Sources/WorkspaceManager/Web/EmbeddedWebNextDetailView.swift |
| web/ dashboard (maintenance mode) | web/src/app/dashboard/ |
| web/ agent runtime | web/src/lib/agent-runtime/ |
| web/ compute providers | web/src/lib/agent-runtime/vercel-sandbox.ts, provider-registry.ts |
| web/ terminal panel | web/src/app/dashboard/components/terminal-panel.tsx |
| web/ terminal API | web/src/app/api/terminal/ |
| web/ API auth helpers | web/src/lib/api-auth.ts |
