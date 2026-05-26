---
status: done
issue: 555
completed: 2026-05-25
resolution: promoted-to-github-issue
category: plan
pr: null
branch: null
score: null
retro_summary: null
---

# Remote Runtime Expansion Plan (SSH, Kubernetes Pods, Docker Compose)

## Context

We currently support local workspaces and a Daytona-based remote VM backend. This document proposes a path to support:

1. Any SSH-accessible host
2. Kubernetes pod runtimes
3. Docker Compose-enabled workflows

It also includes a concrete triage rubric to review related PRs and decide merge/close/follow-up actions.

## Constraint Noted During This Session

The local clone has no configured Git remote and no GitHub CLI available, so direct PR metadata review was not possible from this environment. Use the triage framework below against the open PRs.

## PR Review Triage Framework (Use on each related PR)

Score each PR 0-2 in each category (max 10):

- **Architecture fit**: aligns with protocol-driven backend DI and actor service patterns
- **Data model safety**: migration-safe persistence changes, backward-compatible workspace metadata
- **UX consistency**: creation/selection/lifecycle behavior matches existing sidebar + terminal model
- **Operational reliability**: reconnect behavior, stale-session handling, actionable error messages
- **Test evidence**: Swift Testing coverage and negative-path validation

Suggested actions by total score:

- **9-10**: merge with minor follow-ups
- **7-8**: merge behind feature flag or with required TODO issues
- **5-6**: request changes; split into smaller PRs
- **0-4**: close and replace with scoped implementation plan

## Architecture Recommendation

### 1) Move from provider-specific protocol to capability-based runtime protocol

Current remote protocol is lifecycle-heavy and Daytona-shaped. Introduce a core runtime contract plus optional capability surfaces.

Recommended split:

- `RuntimeBackendProtocol` (core)
  - `identifier`
  - `isAvailable()`
  - `openSession(workspace:) -> RuntimeSessionDescriptor`
  - `healthCheck(workspace:)`
- `RuntimeLifecycleCapable`
  - `createRuntime(...)`
  - `startRuntime(...)`
  - `stopRuntime(...)`
  - `deleteRuntime(...)`
- `RuntimeListCapable`
  - `listRuntimes()`
- `ComposeCapable`
  - `validateCompose(...)`
  - `composeUp(...)`
  - `composeDown(...)`

Add `RuntimeCapabilities` to drive UI affordances instead of hard-coding Daytona assumptions.

### 2) Extend workspace metadata model

Current `backendIdentifier + remoteId` is insufficient for SSH and Kubernetes details.

Add persisted metadata payload (`remoteMetadataRaw` JSON string) with typed wrappers:

- `SSHMetadata`: host, user, port, auth mode, workDir, optional tmux session
- `KubernetesMetadata`: context, namespace, pod/deployment selector, container, workDir
- `ComposeMetadata`: files, project name, service, startup policy

Backward compatibility:

- Existing Daytona entries continue using `remoteId`
- Add migration path where missing metadata defaults to existing behavior

### 3) Keep terminal session model as integration point

Retain `HostTerminalSession.customCommand` as the transport boundary.

- SSH backend emits ssh command
- Kubernetes backend emits kubectl exec command
- Compose orchestration runs pre-attach/post-attach commands where configured

## Runtime Options Analysis

## SSH Runtime (Highest ROI)

### Why first

- Broadest compatibility (any host with SSH)
- Lowest implementation risk
- Directly satisfies "any ssh accessible box"

### MVP

- New `SSHRemoteBackend`
- Connection profile form in New Workspace flow
- Session creation with `ssh` command
- Optional clone/bootstrap command

### Hardening

- Optional `tmux new -A -s <workspace>` attach mode
- SSH preflight checks (binary, host reachability, key auth guidance)
- Better host key UX (`StrictHostKeyChecking=accept-new` configurable)

## Kubernetes Pod Runtime

### Two phased modes

1. **Attach-only mode (MVP)**
   - User points to existing context/namespace/pod/container
   - App opens terminal via `kubectl exec -it`

2. **Provisioned mode**
   - App creates pod + PVC from template
   - Supports image presets and resource profiles

### Risks

- Kubernetes auth/context complexity
- Pod churn and reconnect races
- Namespace permissions vary by org

### Mitigations

- Strict preflight diagnostics page
- Explicit status model (Pending/Running/Terminating/NotFound)
- Reconnect strategy on pod replacement

## Docker Compose Enablement

### Recommendation

Treat Compose as a runtime capability, not a separate backend type.

### Preferred first path

- Enable on SSH backend where Docker engine is available
- Support remote command execution:
  - `docker compose config`
  - `docker compose up -d`
  - `docker compose ps`
  - `docker compose down`

### Optional later paths

- Compose-to-Kubernetes conversion workflows (`kompose`) as export utility
- Native kube manifests for production-like stacks

### Risks

- Plugin/version drift across hosts
- `docker compose` vs `docker-compose` binary differences
- Long-running startup logs and failure surfacing

### Mitigations

- Capability probe at workspace creation
- Persist explicit compose executable choice
- Capture and render startup errors in sidebar status

## Proposed Delivery Sequence

1. **Foundation refactor**
   - capability-based runtime protocols
   - metadata model extension
2. **SSH backend MVP**
   - connect + session persistence + retries
3. **Compose capability on SSH**
   - validation + up/down hooks
4. **Kubernetes attach backend**
   - existing pod attach + preflight
5. **Kubernetes provisioned runtime**
   - pod templates + PVC + lifecycle controls
6. **Polish**
   - telemetry, docs, and migration cleanup

## PR Action Recommendations Template

For each existing PR, apply one of these actions:

- **Merge now** if it only adds isolated backend implementation with tests and no protocol/model breakage.
- **Merge after split** if it mixes protocol refactor + backend + UI in one large diff.
- **Request changes** if it introduces backend-specific logic in SwiftUI views.
- **Close and replace** if it hard-codes Kubernetes/SSH semantics into Daytona-oriented interfaces.

## Acceptance Criteria for "Remote Expansion" Epic

- User can create and open workspaces on an arbitrary SSH host.
- User can attach to a Kubernetes pod runtime from selected context/namespace.
- Compose workflows can be enabled per-workspace and run with explicit lifecycle hooks.
- Existing local and Daytona workspaces remain functional without migration regressions.
- Swift Testing coverage includes protocol behavior, metadata decoding, and failure/retry paths.

