---
topic: lume-runtime
priority: 2
description: Post-merge cleanup for Lume runtime decomposition, transport unification, launcher hardening, and stronger VM/error typing.
---

# Lume Runtime Architecture Follow-Ups

## Problem Statement

PR [#54](https://github.com/fairchild/workspaces/pull/54) intentionally shipped the Lume provider, validated-base contract, and end-to-end validation tooling in one slice because the primary risk was correctness and operational proof, not architectural neatness. That was the right tradeoff for getting the feature working and testable.

The follow-up review identified several real maintainability concerns that are now worth addressing once the feature is stable in `main`: the Lume runtime/provider actors are too large, the HTTP transport logic is duplicated, detached CLI launch still relies on a Python shim, and VM/error classification is still more stringly typed than it should be. None of these blocked the current PR after the runtime contract and test evidence were solid, but they will increase maintenance cost and reviewer friction if left unaddressed.

## Deferred Review Items

| Area | Current State | Why Deferred in PR #54 |
|------|---------------|------------------------|
| Runtime/provider decomposition | `LumeRuntimeService.swift` and `LumeWorkspaceProvider.swift` each own multiple responsibilities | The slice needed validated behavior first; splitting during active runtime debugging would have increased risk |
| Shared HTTP client | `sendRequest`, `sendCurlRequest`, and URL construction are duplicated across runtime/provider | Duplicated code was acceptable short-term while transport behavior was still under active investigation |
| Detached launcher | `LumeWorkspaceProvider.runMacOSVMWithCLI` uses `/usr/bin/python3` to detach `lume run` | The Python shim was the fastest path to preserve VM lifetime during debugging; native detachment is preferable long-term |
| Stronger VM/error typing | Status and fallback detection still rely on string matching in a few places | Upstream Lume behavior was still moving during bring-up, so stronger types were postponed until behavior stabilized |

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Decomposition target | Extract `LumeHTTPClient`, `LumeCLIRunner`, and `LumeImageCatalog` from the large actor files | Removes duplicated transport/process code and makes ownership boundaries explicit |
| Launcher replacement | Replace the Python detacher with a native or shell-based detached launch path | Avoids dependency on `/usr/bin/python3` and Xcode CLI tools shims |
| Typing strategy | Introduce shared `LumeVMStatus` and centralize fallback heuristics | Reduces drift and silent bugs from repeated string literals |
| Scope discipline | Keep validated-base contract and evidence scripts unchanged while refactoring internals | Preserves the working operational contract proven in PR #54 |

## Architecture

```text
Current
-------
LumeRuntimeService
  |- install / verify / repair
  |- host profile
  |- image resolution
  |- curl transport
  |- CLI probing
  |- validated-base lookup

LumeWorkspaceProvider
  |- workspace CRUD
  |- clone / run / stop / delete
  |- curl transport
  |- CLI fallbacks
  |- progress/status mapping

Target
------
LumeHTTPClient
LumeCLIRunner
LumeImageCatalog
LumeRuntimeService
  |- install / verify / host profile / base readiness
LumeWorkspaceProvider
  |- workspace lifecycle orchestration only
```

## Implementation Phases

### Phase 1: Shared transport and runner extraction

**Files to modify:**
- `Sources/WorkspaceManagerCore/Services/LumeRuntimeService.swift` - replace inline curl/URL building with injected/shared helpers
- `Sources/WorkspaceManagerCore/Services/LumeWorkspaceProvider.swift` - remove duplicated transport/process helpers
- `Sources/WorkspaceManagerCore/Services/WorkspaceProviders.swift` - keep provider contract stable while internals move

**Files to create:**
- `Sources/WorkspaceManagerCore/Services/LumeHTTPClient.swift` - shared daemon transport, request/response handling, curl fallback if still required
- `Sources/WorkspaceManagerCore/Services/LumeCLIRunner.swift` - centralized `lume` subprocess execution and detached-run support
- `Sources/WorkspaceManagerCore/Services/LumeImageCatalog.swift` - catalog definitions and resolution logic moved out of runtime actor

**Acceptance criteria:**
- [ ] Transport URL construction and curl marker parsing exist in one place only
- [ ] Runtime/provider actors shrink materially and lose duplicated request helpers
- [ ] Existing runtime/provider tests continue to pass without behavior regression

### Phase 2: Native detachment and stronger typing

**Files to modify:**
- `Sources/WorkspaceManagerCore/Services/LumeWorkspaceProvider.swift` - replace Python detacher, consume typed VM status/error helpers
- `Sources/WorkspaceManagerCore/Services/LumeRuntimeService.swift` - consume shared typed VM/error helpers
- `scripts/lume-standalone-*.sh` - only if status/error wording needs synchronization with new typed helpers

**Files to create:**
- `Sources/WorkspaceManagerCore/Services/LumeVMStatus.swift` - normalized VM status enum and parsing helpers
- `Sources/WorkspaceManagerCore/Services/LumeErrorHeuristics.swift` - central fallback/missing-VM classification

**Acceptance criteria:**
- [ ] No runtime/provider code path depends on `/usr/bin/python3` for detachment
- [ ] Raw string comparisons for VM status and error heuristics are reduced to a single normalization layer
- [ ] Tests cover fallback classification and VM status parsing explicitly

### Phase 3: Contract cleanup and docs alignment

**Files to modify:**
- `docs/development/lume-integration.md` - update internal architecture after extraction
- `docs/development/lume-validation.md` - document any launcher/transport changes
- `docs/development/lume-recreate-runbook.md` - keep recreate instructions aligned with actual runtime path
- `AGENTS.md` - keep discovery notes current for future sessions

**Acceptance criteria:**
- [ ] Docs no longer describe duplicated transport internals or Python-based detachment
- [ ] PR reviewers can trace runtime/provider responsibilities to small focused types

## Verification Commands

```bash
swift build
swift test --filter 'LumeRuntimeServiceTests|LumeValidatedBaseServiceTests|WorkspaceProviderTests|HostLumeSmokeAutomationTests|LumeSetupCoordinatorTests|ModelsTests'
./scripts/lume-pr-validation.sh --standalone-run-dir output/lume-standalone/20260311-182619 --poll-seconds 5
```

## Rollback Plan

- Keep refactors internal to the Lume runtime/provider layer.
- If transport or launcher refactors destabilize real-host smoke, revert to the last known-good implementation from PR #54 and re-run:
  - `mise run dev-lume-standalone-validate`
  - `mise run dev-lume-macos-smoke -- --no-build`

## References

- PR review comment that prompted these follow-ups: [issuecomment-4043562916](https://github.com/fairchild/workspaces/pull/54#issuecomment-4043562916)
- PR shipping the validated-base contract and evidence tooling: [#54](https://github.com/fairchild/workspaces/pull/54)
- `Sources/WorkspaceManagerCore/Services/LumeRuntimeService.swift`
- `Sources/WorkspaceManagerCore/Services/LumeWorkspaceProvider.swift`
- `Sources/WorkspaceManagerCore/Services/LumeValidatedBaseService.swift`
- `docs/development/lume-integration.md`
- `docs/development/lume-validation.md`
