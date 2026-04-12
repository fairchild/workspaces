# Self-Hosted Runner Incidents

This document records infrastructure failure modes for the repo's self-hosted lanes.

## Classification Rule

When a runner shows `online`, accepts work, then flips `offline` or stops reporting while the job is still queued or running, classify that as an infrastructure incident first, not a product regression.

Reason:

- the app perf signal is invalid if the execution lane cannot stay connected
- a flaky lane can create false negatives that look like code regressions
- product performance and runner health must be reviewed independently

## Current Incident Signature

Signature:

- runner becomes eligible for a job
- GitHub shows the lane as `offline`, `lost communication`, or leaves the job queued
- the local runner process may still be alive

Interpretation:

- lane-health failure
- not evidence that the checked code regressed

## Required Response

1. Capture runner state with the self-hosted-runner tooling.
2. Attach the lane-health artifact or local runner evidence.
3. Mark the perf result as skipped or infra-blocked.
4. Do not treat the skipped perf lane as proof of a product regression.

## Related Files

- `.github/workflows/perf-validation.yml`
- `.agents/skills/self-hosted-runners/SKILL.md`
- `scripts/runner.sh`
