# Codespaces Claude Worker

This repo now includes a manual GitHub Actions entrypoint that:

1. creates a fresh GitHub Codespace for this repository
2. uploads a prompt file into the Codespace
3. runs Claude Code headlessly inside the Codespace
4. leaves the Codespace available for inspection on failure, or stops it on success unless told otherwise

## What It Is For

This repository is a macOS app, while GitHub Codespaces runs Linux containers. That means this workflow is best suited for:

- repo exploration
- documentation edits
- issue triage
- PR review follow-ups
- scripted source changes that do not depend on macOS-only toolchains

It is not a substitute for the repo's normal macOS build, test, signing, or UI verification flows.

## Required Secrets

Repository Actions secret:

- `CODESPACES_WORKER_GITHUB_TOKEN`
  - must be a user-scoped token that can create Codespaces for this repository
  - a GitHub App user access token is preferred
  - a fine-grained PAT also works if you choose the simpler credential path

Account-specific GitHub Codespaces secret:

- `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN`
  - the Codespace-side runner checks for one of these before launching Claude
  - use Codespaces secrets for this, not Actions secrets, so the credential is available inside the created Codespace

## Workflow Inputs

The manual workflow is [.github/workflows/codespaces-claude-worker.yml](../../.github/workflows/codespaces-claude-worker.yml).

- `ref`: branch, tag, or SHA to open
- `prompt`: inline request text
- `prompt_path`: optional repo-relative file appended to the inline prompt
- `machine`: optional Codespaces machine type
- `keep_running`: keep the Codespace alive after a successful run
- `max_turns`: Claude turn cap
- `idle_timeout_minutes`: Codespace idle timeout
- `retention_minutes`: Codespace retention window

Use `prompt` for short requests. Use `prompt_path` when you want a longer task brief kept in the repository.

## Runtime Layout

Tracked control-plane files:

- [.devcontainer/devcontainer.json](../../.devcontainer/devcontainer.json)
- [scripts/codespaces-claude-launch.py](../../scripts/codespaces-claude-launch.py)
- [scripts/codespaces-claude-worker.sh](../../scripts/codespaces-claude-worker.sh)

Ephemeral run artifacts inside the Codespace:

- `.context/codespaces-claude-worker/<run-id>/request.md`
- `.context/codespaces-claude-worker/<run-id>/response.json`
- `.context/codespaces-claude-worker/<run-id>/stderr.log`
- `.context/codespaces-claude-worker/<run-id>/status.json`
- `.context/codespaces-claude-worker/<run-id>/metadata.json`

## Inspecting Or Taking Over

After a run, you can connect in any of these ways:

- open the Codespace in the GitHub web UI
- attach with VS Code
- use `gh codespace ssh -c <codespace-name>`

The devcontainer includes the `sshd` feature so OpenSSH-style attach is available if you generate an SSH config with `gh codespace ssh --config`.

Inside the Codespace, Claude artifacts live under `.context/codespaces-claude-worker/<run-id>/`. If you want to continue the same repo-local Claude state manually, attach to the Codespace and run Claude again from the repo root.

## Local Validation

Quick local checks for the control-plane scripts:

```bash
uv run --script ./scripts/test_codespaces_claude_launch.py
uv run --script ./scripts/codespaces-claude-launch.py --help
bash -n ./scripts/codespaces-claude-worker.sh
```
