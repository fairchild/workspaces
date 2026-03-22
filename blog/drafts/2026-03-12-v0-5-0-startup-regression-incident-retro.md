# Draft: Incident Retro for the v0.5.0 Startup Regression

Date: 2026-03-12

Status: Published. Validated on 2026-03-21 with all follow-up work complete.

## Summary

Workspaces `v0.5.0` shipped with a major startup performance regression. The app did too much work on launch, and the installed release felt dramatically slow on another system.

The current external impact is low because there is only one active user right now. That does not reduce the seriousness of the engineering failure. If this project is going to be an exemplar of high-quality software engineering, then we need to practice that standard before the stakes are higher, not after.

## Impact

- A full release regressed first-run and startup experience in a way that was immediately noticeable.
- The regression damaged confidence in the release even though the product scope and user count are still small.
- Investigation took longer than it should have because the installed app did not yet expose enough local diagnostic signal for the new slow path.

## What Changed

`v0.5.0` introduced new startup-time environment probing intended to improve workspace creation flows. In practice, the main window launch path began doing three categories of work too early:

- refreshing workspace provider availability
- taking a Lume runtime snapshot
- syncing non-local workspace statuses

The Lume runtime snapshot path could also do additional expensive work:

- probe local daemon endpoints
- run host commands such as `sw_vers`, `xcodebuild -version`, and `xcode-select -p`
- inspect base VM state

Each of those checks is reasonable when the user asks for VM or remote-workspace functionality. They were not reasonable as unconditional work on the initial launch path.

## Why We Missed It

We missed this for a few reasons.

First, we allowed optional capability discovery to sit on the critical path for initial UI readiness. That was a design mistake. The app should prioritize first paint and only enrich the environment model when the user enters a flow that actually needs that information.

Second, our existing performance instrumentation did not cover the new launch-time work. We had signposts for other flows, but not for provider refresh, Lume snapshot collection, daemon reachability checks, host profile detection, or remote status sync. That made it harder to identify the culprit quickly from an installed build.

Third, our release validation was too development-centric. We did not have a thorough release quality check for a full release and changelog publication. We also did not have a hard requirement to validate startup behavior in an installed release on another machine before publishing.

## Detection And Investigation

The regression was detected after installing the released app and observing that it was much slower than expected at startup.

A review of the `v0.5.0` changes showed that milestone work to avoid blocking startup on notification auth restore was useful, but it did not address the more expensive runtime probing path. Static review of the shipped launch flow pointed to eager Lume/provider/status checks as the highest-confidence cause of the slowdown.

We chose not to add telemetry. Instead, the right response is better local diagnostics, clearer startup budgets, and release validation that reflects real installed usage.

This incident also exposed a process gap: we treated release creation and changelog publication as the end of the work instead of the final step after a higher-confidence quality pass. For full releases, that is backwards. Publication should come after an extra round of targeted validation, not before it.

## Immediate Fix

The first corrective patch does three things:

- removes eager provider and Lume runtime refresh from the initial app launch path
- defers non-local workspace status sync so it does not compete with first-window readiness
- adds local-only performance logs around provider refresh, runtime snapshot collection, daemon reachability, host-profile detection, host commands, and workspace status sync

This is the right short-term correction because it both reduces startup work and improves our ability to diagnose future regressions without collecting telemetry.

## What We Are Changing

These are the engineering standards this incident reinforces:

1. No remote, daemon, or host-tool probing belongs on the first-window path unless it is strictly required to render the initial UI.
2. Any new startup-path work must ship with explicit timing instrumentation.
3. Release validation must cover installed builds, not only local development builds.
4. Local diagnostics must be good enough that we can understand a slow installed build without adding telemetry.
5. Full releases and changelog publication need a deliberate release-quality gate with a little extra testing before publication.
6. Low current stakes are not a reason to cut corners. They are an opportunity to build the habits we want when the stakes are high.

## Follow-Up Work — Status

All follow-up items from this incident have been completed:

- ✅ Local diagnostics export added to the app (PR #153, issue #97)
- ✅ Release quality gate added — CI must pass before signing/publishing (PR #155, issue #98)
- ✅ Startup performance budgets defined and enforced in CI (PR #147, issue #96)
- ✅ Terminal focus ownership simplified, duplicate handoffs removed (PR #150)
- ✅ Selection hot-path moved off main actor (PR #151)
- ✅ Workspace transitions made responsive during remote state hydration (PR #152)
- ✅ Terminal readiness critical path instrumented with workspace-switch metrics (PR #149)

## Validation Results — 2026-03-21

Post-fix baseline on main (5 runs, `no-activate` mode, debug build):

| Metric | Median | Budget | Status |
|---|---:|---:|---|
| `repo_hydration` | 2.72 ms | 25 ms | ✅ pass |
| `launch_to_first_prompt` | 3,399 ms | 250 ms | ❌ over budget |
| `repo_click_to_focus` | 2,604 ms | 250 ms | ❌ over budget |

The original regression (eager Lume/provider probing at startup) is fully resolved — `repo_hydration` is now 2.72ms vs the 250ms+ it caused previously.

The remaining budget violations are dominated by **GhosttyKit terminal initialization and focus acquisition**, not by the startup probing that caused this incident. Terminal surface readiness (~2-3s) is a separate performance domain that predates this regression and requires different optimization work (terminal prewarming, focus coordination improvements).

This incident is closed. Terminal startup performance is tracked as ongoing optimization work, not as part of this regression.

## Closing Reflection

This was a low-impact incident in business terms and a meaningful incident in engineering terms.

That distinction matters. The right lesson is not that we can afford mistakes because the audience is small. The right lesson is that we have room to strengthen our systems now, while the cost of learning is still low. That is how a project becomes a trustworthy reference for software engineering practice instead of a project that talks about quality without consistently demonstrating it.
