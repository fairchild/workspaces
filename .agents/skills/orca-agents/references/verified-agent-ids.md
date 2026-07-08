# Orca's known `--agent <id>` registry

No public docs enumerate valid `--agent` values for `orca worktree create`
or `orca terminal create --command`; the CLI's error on a bad id
(`invalid_argument: Unknown TUI agent "<id>"`) doesn't list alternatives
either. This table was extracted directly from Orca.app's bundled config
(ground truth, not inferred) on 2026-07-08:

```bash
cat "/Applications/Orca.app/Contents/Resources/app.asar.unpacked/out/shared/tui-agent-config.js"
```

Re-run that if a command with `--agent` fails unexpectedly after an Orca
update — this list can drift.

| id | launch cmd | prompt injection |
|----|-----------|-------------------|
| `claude` | `claude` | argv `--prefill` |
| `claude-agent-teams` | `orca claude-teams` | stdin-after-start |
| `openclaude` | `openclaude` | argv `--prefill` |
| `codex` | `codex` | argv |
| `autohand` | `autohand` | stdin-after-start |
| `ante` | `ante` | stdin-after-start |
| `opencode` | `opencode` | flag-prompt |
| `mimo-code` | `mimo` | flag-prompt |
| `pi` | `pi` | argv (env `ORCA_PI_PREFILL` overlay) |
| `omp` | `omp` | argv (env `ORCA_OMP_PREFILL`) |
| `gemini` | `gemini` | flag-prompt-interactive |
| `antigravity` | `agy` | flag-prompt-interactive |
| `aider` | `aider` | stdin-after-start |
| `goose` | `goose` | stdin-after-start |
| `amp` | `amp` | stdin-after-start |
| `kilo` | `kilo` | stdin-after-start |
| `kiro` | `kiro-cli chat --tui` | stdin-after-start |
| `crush` | `crush` | stdin-after-start |
| `aug` | `auggie` | stdin-after-start |
| `cline` | `cline` | stdin-after-start |
| `codebuff` | `codebuff` | stdin-after-start |
| `command-code` | `command-code --trust` | argv |
| `continue` | `cn` | stdin-after-start |
| `cursor` | `cursor-agent` | argv |
| `droid` | `droid` | argv |
| `kimi` | `kimi` | stdin-after-start |
| `mistral-vibe` | `vibe` | stdin-after-start |
| `qwen-code` | `qwen` | stdin-after-start |
| `rovo` | `rovo` | stdin-after-start |
| `hermes` | `hermes --tui` | stdin-after-start |
| `openclaw` | `openclaw` | stdin-after-start |
| `copilot` | `copilot` | flag-interactive |
| `grok` | `grok` | stdin-after-start |
| `devin` | `devin` | stdin-after-start |

Only `codex` and `claude` are confirmed installed and used in this
environment. The rest are Orca's supported registry, not necessarily on this
machine's `PATH` — passing one of them will fail at agent-launch time even
though the worktree itself was created successfully, so check `terminal read`
after `--agent` with an unfamiliar id.
