# web-next/ - Active Web App

`CLAUDE.md` here is a symlink to this file — read one, not both.

Sessions-first UI, deployed at `folio.cloudcompute.com`, also embedded locally in the macOS app over loopback HTTP (`docs/decisions/embedded-native-contract.md`). New web work happens here. Stack + local dev: `CONTRIBUTING.md` — no mise integration, plain `pnpm`.

## Cleaning

Never delete build/test state with ad-hoc `rm -rf` — use `pnpm run clean [build|data|artifacts|deps|all] [--dry-run]` (allowlisted; see `CONTRIBUTING.md` § "Cleaning up").

## Agent-Path Lessons

- **Vercel `Sandbox.create({env: {...}})` does NOT propagate to `sandbox.runCommand()`.** Write env vars to an `env.sh` and `source` it at the top of the script. See `docs/development/agent-chat-sandbox.md` § "Claude CLI Authentication".
- **"Tests green" ≠ "works in production" for agent paths.** For changes touching `createSandbox`, `restoreSnapshot`, `createTerminalSandbox`, or `streamOutput`, send a real chat message in production and read the agent stream before declaring victory.
