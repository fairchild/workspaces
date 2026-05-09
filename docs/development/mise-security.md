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
uv run --script scripts/test_security_hardening.py
MISE_TRUSTED_CONFIG_PATHS="$PWD" mise lock --dry-run --platform macos-arm64,linux-x64 zig
MISE_IGNORED_CONFIG_PATHS="$HOME/.config/mise" MISE_TRUSTED_CONFIG_PATHS="$PWD" mise exec --locked zig@0.15.2 -- zig version
curl -fsSL https://api.github.com/repos/jdx/mise/releases/latest | jq -r '.tag_name, "draft=\(.draft)", "prerelease=\(.prerelease)"'
```
