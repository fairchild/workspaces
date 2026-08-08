# Perf contract: channel4_replay_10k_records removed

**Date**: 2026-08-07
**Status**: accepted
**Issue**: #1238

## Decision

The performance contract (`config/performance/contract.json`) no longer declares
the `channel4_replay_10k_records` scenario or its two metrics
(`channel4_replay_completion_seconds`, `channel4_replay_rss_delta_mb`).

## Why

The contract row described a cold-start replay of a 10,000-record transcript
JSONL through `TranscriptColdStartRecovery` + `AgentSessionRegistry.ingestBatch`
with budgets (≤ 25 s completion, ≤ 50 MB RSS delta), but no harness for it
exists anywhere in the repo — verified 2026-08-07 during the perf-system audit.
Every other contract row is runnable through `perf-runner.sh`; a row that
cannot be run reads as coverage that does not exist, which is precisely the
failure mode #1238 closes (a skipped or unrunnable measurement must not present
as a passing one).

The audit chose removal over implementation because three other harnesses were
simultaneously rotted or never wired; adding a fifth build-from-scratch harness
to that repair wave would have traded four fixed alarm wires for five untested
ones. The perf-audit hard constraints the row pointed at
(`perf-audit-pr443-final.md`) remain documented there.

## Reopening

If transcript-replay coverage is wanted, file it as a feature issue: implement
the replay harness (a `swift test` perf scenario emitting
`WORKSPACES_PERF_OUT` JSON, wrapped by a `perf-runner.sh` arm like the
channel1/channel2 scenarios), and only then restore the contract row alongside
the harness in the same PR.
