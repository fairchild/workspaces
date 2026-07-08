# CODEX Report

## Hardening pass

Issue: #981 web-next host compute provider.

### Directed-review findings

- Settings escape the allowlist: fixed. Host turns now launch Claude with `--safe-mode`, `--strict-mcp-config`, matching `--tools`, and `--allowedTools`. `--safe-mode` is the installed CLI's supported configless path for v1 because it disables user/project customizations including hooks, MCP servers, agents, plugins, skills, and CLAUDE.md discovery while preserving auth, model selection, built-in tools, and permissions. `--strict-mcp-config` is included as defense in depth. Config parity remains issue #985.
- Stale resume wedges the session: fixed. A failed `--resume` attempt that exits before assistant content is discarded and retried once fresh with `request.priorContext` in the prompt. If that fresh retry fails, the terminal `done` includes `metadata.resume: null` so `persistResume` clears the stored handle.
- Unbounded hang: fixed. `WEB_NEXT_HOST_TURN_TIMEOUT_MS` bounds the turn wall clock, defaulting to `900000`. Timeout emits a structured `host_turn_timeout` error and an aborted `done`. The stdout-closed to process-exit wait is bounded to 10 seconds, then the existing SIGTERM to SIGKILL path runs.
- Descendants survive the kill: fixed. Claude is spawned detached in its own process group; abort, timeout, and kill escalation signal `-pid` first and fall back to the direct child if the group signal fails. Normal exit does not signal.
- Unbounded buffers: fixed for retained stderr and stdout lines. Stderr keeps only the last 8 KiB and annotates truncation in the emitted error. Stdout stream-json lines are split with a bounded custom splitter; lines over 1 MiB are dropped and reported as structured errors.
- Web egress: fixed. `WebFetch` and `WebSearch` are removed from `HOST_ALLOWED_TOOLS`; v1 stays read-only filesystem inspection. Issue #985 can revisit broader config/tool parity.
- Clone race: fixed. Workspace setup is guarded by a per-session in-process mutex so concurrent first turns share the same clone operation.

### Claude CLI help excerpts

Verified with `claude -p --help` from `web-next/` on 2026-07-08.

```text
--safe-mode
  Start with all customizations (CLAUDE.md, skills, plugins, hooks, MCP
  servers, custom commands and agents, output styles, workflows, custom themes,
  keybindings, and more) disabled ... Auth, model selection, built-in tools,
  and permissions work normally. Sets CLAUDE_CODE_SAFE_MODE=1.

--strict-mcp-config
  Only use MCP servers from --mcp-config, ignoring all other MCP configurations

--tools <tools...>
  Specify the list of available tools from the built-in set. Use "" to disable
  all tools, "default" to use all tools, or specify tool names.

--allowedTools, --allowed-tools <tools...>
  Comma or space-separated list of tool names to allow.
```

The installed help documents `--setting-sources <sources>` as `user, project, local`; it does not advertise an empty or `none` value, so this pass uses `--safe-mode` instead of relying on an undocumented setting-source sentinel.

### Verification

- `pnpm exec vitest run src/lib/agent-runtime/host-provider.test.ts`: passed.
- `pnpm run clean build`: passed; removed `.next`.
- `pnpm test`: passed, 43 files / 484 tests.
- `pnpm typecheck`: passed.
- `pnpm lint`: passed.
- `pnpm build`: passed. Existing warnings remained for `jose` using `CompressionStream`/`DecompressionStream` in the Edge Runtime import trace through `better-auth`.
- `E2E_PORT=3181 pnpm test:e2e`: passed, 43 tests.

### Mutation checks

- Settings isolation: temporarily removed `--safe-mode`; `pnpm exec vitest run src/lib/agent-runtime/host-provider.test.ts -t "always includes read-only tool restriction flags"` failed with `expected ... to include "--safe-mode"`. Restored.
- Resume clearing: temporarily changed the failure metadata helper to omit `resume: null`; `pnpm exec vitest run src/lib/agent-runtime/host-provider.test.ts -t "falls back once from a stale resume"` failed because the terminal `done.metadata` was missing `resume: null`. Restored.

### Residual risks

- The workspace setup mutex is intentionally in-process only. Cross-process/session-worker serialization is still outside this v1 host provider pass.
