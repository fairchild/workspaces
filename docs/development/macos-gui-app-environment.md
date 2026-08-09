# macOS GUI App Environment

An app started from the Dock, Finder, or `open` inherits launchd's environment, not your shell's. Exports in `~/.zshrc`, `~/.zprofile`, or a `.env` file are invisible to it. This matters whenever a GUI app is configured through environment variables — this repo's own app is one, and so are the agent harnesses we run inside.

## Confirming which environment an app actually got

A parent PID of 1 means launchd started it, so the shell was never in the picture:

```bash
ps -axo pid,ppid,command | rg 'MacOS/YourApp'
ps eww -p <pid> | tr ' ' '\n' | rg '^PATH='
```

`PATH=/usr/bin:/bin:/usr/sbin:/sbin` with roughly a dozen variables total is the launchd default and the clearest tell. A shell-derived environment carries your full `PATH` (mise shims, Homebrew) and far more entries.

## Why the dev scripts see env vars and the installed app doesn't

`scripts/launch-dev.sh:623` launches through `nohup env "${ENV_VARS[@]}" "$DEBUG_BINARY"` — the binary is a direct child of your shell, so `WORKSPACES_NO_ACTIVATE_ON_LAUNCH`, `GHOSTTY_RESOURCES_DIR`, `WORKSPACES_DATA_DIR` and the rest all arrive. The copy in `/Applications` started from the Dock gets none of them.

So when an env var "isn't taking effect," first establish which of the two processes you are looking at — that check is already step 3 of `Sources/AGENTS.md` § "Dev Verification Practice", and it resolves this class of confusion more often than any code change.

## Getting a variable to a Dock-launched app

`launchctl setenv` writes into the GUI session environment that launchd hands to apps:

```bash
launchctl setenv MY_VAR value
```

Processes read their environment at exec, so the app must be fully quit (⌘Q, not just closing its window) and relaunched. The value survives until logout. For persistence across reboots, a LaunchAgent in `~/Library/LaunchAgents` with `RunAtLoad` can re-run a small script that calls `launchctl setenv` at login; `scripts/lume-ensure-daemon.sh` is the in-repo example of managing an agent's lifecycle with `launchctl bootstrap`.

For a secret, holding it in Keychain and bridging it at login keeps it out of a plaintext plist:

```bash
security add-generic-password -a "$(id -un)" -s my-service -w
security find-generic-password -a "$(id -un)" -s my-service -w
```

A login-time agent should tolerate the login Keychain still being locked for the first moment it runs — a short retry loop around the `security` read is enough.

The tradeoff worth stating plainly: anything set with `launchctl setenv` is readable by every process in the GUI session via `launchctl getenv`. On a single-user machine that is usually acceptable, but it is session-wide exposure, not isolation, and Keychain-at-rest does not change that once the value has been bridged.

## A CLI launcher usually doesn't close the gap

Many apps ship a CLI that "launches the app," which looks like it should carry your exported variables. Most of them shell out to `/usr/bin/open` on the bundle, which hands the launch to LaunchServices — the app starts fresh from launchd, and any environment the CLI passed reaches only the short-lived `open` helper. Read the launcher before assuming it helps.

## Worked example: Orca's Gitea integration

Orca configures its Gitea integration through `ORCA_GITEA_TOKEN` and `ORCA_GITEA_API_BASE_URL`, read straight from its own process environment:

```js
function envValue(name) {
  const value = process.env[name]?.trim() ?? "";
  return value.length > 0 ? value : null;
}
```

There is no dotenv loader and no Keychain lookup, so a `.env` file will not reach it no matter which directory it sits in — the settings card's own "restart Orca if environment variables changed" is the tell for a process-env read. Orca's `orca open` is the `/usr/bin/open` case described above. The working setup is the Keychain-plus-LaunchAgent bridge, followed by a full quit and relaunch.

Two details specific to that variable pair, both worth knowing before debugging a value that looks wrong:

- The base URL is normalized — Orca appends `/api/v1` when it is absent, so the web root and the explicit API base both work. A schemeless value (a bare hostname) does not: it reaches `new URL()` and throws.
- The base URL is only needed when Orca cannot derive the API origin from the git remote. SSH remotes on a non-default port are the common case where derivation cannot work, since the SSH port says nothing about where the HTTP API listens.

Restarting Orca ends any agent session running in its terminal panes, which is worth sequencing around rather than discovering.
