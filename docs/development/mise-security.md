# mise Security

This repo uses `mise` as a task runner and to install the pinned Zig toolchain.
Treat `.mise.toml` as executable repo policy: tasks can run shell, and trusted
configs can affect every later command in a checkout.

## Enforced Repo Controls

- Only the root `.mise.toml` and `web/.mise.toml` are allowed by
  `./scripts/setup`.
- `./scripts/setup` rejects mise configs that contain `[env]`, `[hooks]`,
  `trusted_config_paths`, `yes = true`, `ci = true`, `_.source`, or `_.file`.
- Root tool installs run in locked mode against the checked-in `mise.lock`.
- GhosttyKit invokes Zig through `mise exec --locked`.
- The hosted agent sandbox installs a pinned mise release and verifies its
  SHA-256 before making it executable.

## Operator Rules

- Keep secrets out of global and project mise config. Use `.env`, the macOS
  keychain, GitHub secrets, or the repo-specific secret setup scripts instead.
- Do not add `trusted_config_paths`, `yes = true`, or `ci = true` to global or
  project mise config.
- Trust specific files after review: `mise trust .mise.toml` and, for web work,
  `mise trust web/.mise.toml`.
- Prefer core or signed/provenance-aware backends. Do not add asdf-backed tools
  unless there is no maintained alternative and the review calls out the
  tradeoff.
- When changing `[tools]`, update `mise.lock` for `macos-arm64` and `linux-x64`.
- Keep host installs and the hosted-agent sandbox on the latest stable mise
  release. Confirm GitHub reports `draft=false` and `prerelease=false`, then
  update the sandbox `MISE_VERSION` and checksum together.

## Verification

```bash
./scripts/verify-mise-security.sh
```

The `Mise Security` workflow runs this verifier whenever mise configs,
`mise.lock`, the setup/build scripts, the sandbox mise installer, or this doc
change.

## Sandboxed Agent Runs

When Codex or another sandbox blocks writes to user-level mise state or cache
directories, run mise through:

```bash
./scripts/mise-sandbox -C web run web:check
```

The wrapper redirects only `XDG_STATE_HOME` and `MISE_CACHE_DIR` to temp
directories, ignores user-level mise config, preserves explicit trust for the
reviewed root and web mise configs, enables paranoid mode, and then execs `mise`
normally. It does not redirect `MISE_DATA_DIR`, suppress stderr, or weaken task
failure behavior.
