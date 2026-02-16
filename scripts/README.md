# Scripts Guide

This directory contains build/release helpers plus UI test utilities.

## Primary UI Test Entry Points

Use these two scripts for day-to-day UI verification:

1. `./scripts/ui-smoke.sh`
- Fast interaction smoke test.
- Validates launch, focus, typing, and Enter behavior.
- Writes artifacts to `/tmp/workspaces-ui-smoke-<timestamp>/`.

2. `./scripts/ui-capture.sh`
- Screenshot-focused flow capture.
- Same core interaction path plus screenshot artifacts.
- Writes artifacts to `/tmp/workspaces-ui-capture-<timestamp>/`.

Both scripts:
- fail fast on missing permissions
- print artifact directory path at the end
- use explicit app target launch (`swift run WorkspaceManager`)

## Legacy UI Scripts

Other `*test*.sh` files are older exploratory scripts kept for reference and targeted debugging.
Prefer `ui-smoke.sh` and `ui-capture.sh` unless you specifically need one of the legacy flows.
