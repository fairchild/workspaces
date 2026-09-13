# Docker Compose workspaces

Docker Compose workspaces keep each agent's execution in a Linux container while
keeping its working copy visible on the Mac. Each workspace owns a Compose project,
an independent clone, an `agent` service, and a persistent agent home volume.

The [standalone reference](../../examples/compose-agent-sandbox/README.md) uses the
same base template without requiring WorkSpaces. It also demonstrates adding
Postgres as a second service. The app currently uses the base agent template only.
Its [visual feature guide](../../examples/compose-agent-sandbox/index.html) includes
an interactive lifecycle diagram and recordings of the standalone runtime and
production provider test.

## Create and use a workspace

Start a local Docker runtime with Linux containers and the Compose plugin, then
choose **Docker Compose** in the New Workspace sheet. The provider records the
selected Docker context and its local Unix socket endpoint. A context pointed at a
remote daemon is rejected. Later operations reject a changed endpoint instead of
silently operating on another daemon.

Creation resolves the selected repository reference to a commit, copies its Git
objects into a self-contained clone, and checks out that commit inside `agent`.
Uncommitted source edits are not included. The clone has its own `.git` directory
and objects, so the container needs no mount of the original repository. Its remote
is set to the repository's network origin when one is available; a local host path
is not retained as a container remote.

The provider builds its image, starts the project, checks health and write access,
and runs the repository's setup script in the container. It marks the workspace
ready only after setup succeeds. The setup candidates, in precedence order, are
`scripts/setup`, `scripts/setup.sh`, and `setup.sh`.

Opening a ready, running workspace launches an interactive `docker compose exec`
into `agent`, with `/workspace` as the guest working directory. Git, Bash, tmux,
Node.js/npm, and Python tooling are available there. Install and authenticate an
agent inside that workspace as described in the standalone reference.

The Compose option also offers **Default Terminal Command**. An empty value opens
Bash. A configured command runs in a guest login shell when each new terminal
session starts, then leaves an interactive shell available when it exits, fails,
or is interrupted. Required tools must already be installed in the image or guest
setup. Reattaching to an existing session does not run it again. A split creates a
new session and runs its own copy; Stop ends all sessions, so a terminal opened
after Start runs it afresh. The app reconnects already-open terminal panes after
Start, preserving their identities and split layout. Starting the container
alone does not run the command.

The value is saved in the workspace's trusted metadata and passed into its
container environment for creation and restart. It is excluded from the host
terminal launch string. The image's shared `workspaces-terminal` helper performs
the execution inside the guest; the standalone reference uses the same helper.
Older workspace records without a command continue to open Bash. This is a
creation setting limited to 16 KiB of UTF-8 text, with no existing-workspace editor or repo/global fallback.

## Files, changes, and terminal continuity

The Files tab reads the host-visible clone using directory-relative file
descriptors. Enumeration and preview reject symbolic links and special files;
every traversed component uses no-follow opens. Preview size and tree depth are
bounded. Native previews are read-only, and the app's editor actions are disabled
for these workspaces. Edit files in the workspace terminal.

The Changes tab executes Git in `agent`, including status, diff, stage, unstage,
and discard. This includes Review Diff opened from a file preview. Repository
configuration and attributes can invoke programs, so a container error never
falls back to host Git. Unavailable status appears as **Changes Unavailable**,
rather than a clean working tree. File arguments use literal Git pathspecs.

Host-only CLI commands such as `workspaces status`, `open`, `run`, `resume`, and
`ws launch` reject Compose workspaces before reading checkout configuration or
executing Git. The CLI retains provider identity when it resolves an app workspace.
For older CLI records and app-offline use, host-owned Compose receipts also protect
known checkout paths, their subdirectories, and aliases. Use the app's terminal or
an explicit `docker compose exec` command to operate inside the sandbox.

Each Terminal Session attaches to a guest tmux session named
`ws-<terminal-session-uuid>`. Splitting a terminal preserves the Compose launch
command and assigns a new UUID, giving each tile its own shell. Closing the app
detaches its clients while the container and guest processes continue running.
Closing a terminal also detaches its client; stop or recreate the runtime to end
the retained guest processes.

On app restart, the continuity controller matches saved terminal IDs to current
workspace records and regenerates attachment commands from validated provider
metadata. It does not replay the saved shell string. Missing, deleted, archived,
or incomplete workspaces cannot restore a host shell through this path. The
existing continuity format restores split terminals as separate tabs; their guest
session IDs survive, while the split arrangement does not.

## Lifecycle and retained data

| Action | Result |
| --- | --- |
| Start | Bring up the saved project without rebuilding its image. |
| Stop | Run the container's stop hook when available, then stop the project. Retain files, containers, image, and volumes. |
| Rebuild through the provider API | Build the trusted snapshot and recreate the project. Retain the checkout and home volume; running processes end. |
| Delete with files retained | Remove the app record, containers, and project network. Retain the checkout, named volumes, image, and trusted configuration directory. |
| Delete with files removed | Also remove this project's volumes, image, checkout, and trusted configuration directory. |

The app exposes Start, Stop, and Delete through its existing provider actions.
Rebuild is a provider API operation; there is no dedicated Rebuild control yet.
Compose workspaces do not support Archive.

Stop hooks use `scripts/stop` or `scripts/stop.sh`. Before destructive deletion,
the provider also attempts `scripts/archive`, `scripts/archive.sh`, or `archive.sh`
when the completed workspace is running. These scripts execute inside `agent`.
Deletion does not use the host workspace remover, which can execute Git.

Failed creation retains the stopped workspace record, provisional identity,
checkout, and any allocated runtime data for explicit deletion. A failed setup
does not produce a ready marker, so Start and terminal attachment refuse it.
Delete that workspace and create it again after correcting the setup script.

A Docker outage is an unavailable observation. Status reconciliation throws and
leaves the last observed app status intact. It never infers that files were deleted.
Cleanup is restricted to the saved project's identity and uses no global Docker
prune operation.

## Configuration and isolation

The app bundles `compose.yaml`, `Dockerfile`, and `.dockerignore` from the
standalone example. Each workspace receives a private snapshot under
`Application Support/WorkspaceManager/ComposeSandboxes/<project-name>`; synthetic
runs use their isolated run root. The snapshot, metadata receipt, and ready marker
remain outside the mounted clone. The build context excludes repository contents.

`ComposeSandboxMetadata` records the project name, Docker context and endpoint,
host path, configuration directory, terminal service, guest working directory,
template version, template hashes, and optional default terminal command. Operations validate that identity and the
saved snapshot before using explicit Compose file and project arguments. The
container receives neither the configuration snapshot nor the Docker socket.
Repository Compose files and `.env` files are not imported. Supporting custom
stacks in the app requires a separate reviewed configuration flow.

The base template runs UID/GID 1000 with a read-only root filesystem, dropped Linux
capabilities, no privilege escalation, and CPU, memory, process, and temporary
storage limits. Writable storage consists of the dedicated clone, project home
volume, and temporary filesystem. No host home directory, SSH agent, WorkSpaces
automation socket, or host agent credentials are shared. Credentials acquired by
an agent inside its home remain readable by that agent and persist with the volume.

Outbound networking is allowed, including reachable host and LAN services. Project
networks are not an egress policy. Containers share the Docker host's Linux kernel;
use a stronger isolation boundary for hostile code. The standalone reference
describes the resource limits and optional service networking in detail.

## Verification

These checks cover different boundaries; a passing unit suite does not establish
that the native terminal and Docker runtime work together:

```bash
swift test --filter ComposeWorkspace
swift test --filter CLIComposeBoundaryTests
WORKSPACES_COMPOSE_LIVE_TESTS=1 swift test --filter ComposeWorkspaceLiveTests
./examples/compose-agent-sandbox/smoke.sh
./examples/compose-agent-sandbox/smoke.sh --with-postgres --skip-build
```

The app regression suite covers real split creation, metadata-based restoration,
Git routing with unavailable containers, literal filenames, and no-follow file
inspection. Its split mutation removes provider-command propagation and must fail
the terminal identity test. The standalone smoke checks two concurrent projects,
PTY/tmux reattachment, lifecycle persistence, and deletion without affecting a
neighbor. Optional Postgres coverage belongs to the standalone example.

The CLI regression launches the real executable against an isolated operator
inventory and legacy records. It proves that a malicious Git fsmonitor hook works,
then verifies that Compose status and command launches leave its host marker
absent. Offline receipts cover resumed records, subdirectories, and symlink
aliases. Removing the status guard must make this regression fail.

The provider's live test is opt-in because it builds images and creates disposable
containers, volumes, and clones on the selected local Docker runtime. It exercises
the production provider's setup, execution, rebuild, and scoped deletion paths.

For native end-to-end evidence, create a disposable Compose workspace in an
isolated debug app run, inspect files and a Git diff, split its terminal, stop and
start it, and relaunch the app while checking the retained guest tmux IDs and
processes. Capture the rendered window using the
[app evidence lane](evidence.md). Record that evidence separately from unit and
standalone results.
