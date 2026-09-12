# Compose agent sandbox

Run an agent in a Linux terminal with its own working copy, home directory and
optional database. Each workspace is an ordinary Docker Compose project. This
example works without WorkSpaces, and WorkSpaces uses the same base template.

The host keeps the checkout visible to editors. Commands, Git, setup scripts and
agent tools run inside `agent`. That boundary matters because Git configuration
and repository scripts can execute programs. A Git worktree points outside its
directory, so use a self-contained clone with its own `.git` directory and objects.

## Start a workspace

You need Git and a running local Docker Engine with Docker Compose 2.24 or newer.
On macOS, Docker Desktop and OrbStack supply the Linux runtime. The container runs
as UID/GID 1000. On Linux, give that user write access to the dedicated clone using
ownership or an ACL. Do not change permissions on your original repository.
The image trusts the specific Git directory `/workspace`, since Docker Desktop
can preserve macOS ownership on an otherwise writable bind. It does not disable
Git's ownership checks for other paths.

Keep the trusted Compose files outside anything mounted into the agent. Review
the Dockerfile and Compose configuration before running these commands from this
directory. Set `repository_url` to the repository you want to work on.

```bash
repository_url=https://github.com/your-account/your-repository.git
sandbox_root="$HOME/compose-workspaces"
mkdir -p "$sandbox_root/templates/v1" "$sandbox_root/checkouts"
cp compose.yaml compose.postgres.yaml Dockerfile .dockerignore "$sandbox_root/templates/v1/"
git clone "$repository_url" "$sandbox_root/checkouts/demo"

export WORKSPACE_DIR="$sandbox_root/checkouts/demo"
export COMPOSE_PROJECT_NAME=ws-demo
export DOCKER_CONTEXT="$(docker context show)"
cd "$sandbox_root/templates/v1"
docker compose --env-file /dev/null -f compose.yaml build agent
docker compose --env-file /dev/null -f compose.yaml up -d --wait --wait-timeout 60
docker compose --env-file /dev/null -f compose.yaml exec agent /bin/bash -l
```

The explicit file and empty environment file prevent the checkout's Compose or
`.env` files from changing what Docker starts. `WORKSPACE_DIR` must name an existing
clone. An unset variable or missing directory fails instead of creating a host
directory. The image build context includes only the Dockerfile and `.dockerignore`.

Use a unique, stable project name for each workspace. Start another clone with
`COMPOSE_PROJECT_NAME=ws-demo-2` and a different `WORKSPACE_DIR`. Do not add fixed
container names or shared external networks/volumes, which would defeat project
separation. `SANDBOX_IMAGE` optionally changes the shared image tag, whose default
is `workspaces-compose-agent:v1`. Pin `DOCKER_CONTEXT` for the workspace's lifetime.

## Use a terminal and install an agent

The image contains Bash, Git, tmux, curl, Node.js/npm, Python, pip and venv.
Install additional system packages by editing the trusted Dockerfile and rebuilding.
User-installed tools belong in the persistent home volume. npm's global prefix is
`/home/agent/.local`; Python tools can use a virtual environment under the home.

For example, install Codex inside the container, inspect its version, then sign in
through its device flow. This creates a separate login in this workspace. These
commands never read your host credentials.

```bash
docker compose --env-file /dev/null -f compose.yaml exec agent /bin/bash -l
# Inside the container:
npm install --global @openai/codex
codex --version
codex login --device-auth
codex
```

Device login must be enabled for your account or organization. See the official
[Codex CLI](https://learn.chatgpt.com/docs/codex/cli) and
[headless authentication](https://learn.chatgpt.com/docs/auth#login-on-headless-devices)
documentation. The base image does not pick an agent vendor or include credentials.
If an agent stores credentials in its home, those credentials persist in this
workspace's home volume and are readable by that agent.

Use a stable tmux name for each terminal tile to keep its shell running when a
terminal closes. `Control-B`, then `D` detaches. Repeating the command reattaches.
Choose another name for a second terminal.

```bash
docker compose --env-file /dev/null -f compose.yaml exec agent \
  tmux new-session -A -s terminal-1 -c /workspace /bin/bash -l
```

Automated commands use `exec -T`, which disables the interactive TTY. For example,
run setup or inspect changes without executing repository code on the host:

```bash
docker compose --env-file /dev/null -f compose.yaml exec -T agent bash -lc 'npm ci && npm test'
docker compose --env-file /dev/null -f compose.yaml exec -T agent git diff --stat
```

## Add a database

The optional override adds Postgres on a project-specific internal network, with
no published host port. The agent receives `DATABASE_URL` and can reach
`postgres:5432`. The documented `sandbox` password is disposable development data.

```bash
docker compose --env-file /dev/null -f compose.yaml -f compose.postgres.yaml up -d --wait
docker compose --env-file /dev/null -f compose.yaml -f compose.postgres.yaml \
  exec postgres psql -U sandbox -d sandbox
```

Keep both `-f` arguments on later lifecycle commands for a workspace using this
override. Its database data lives in that project's `postgres-data` volume.

For a web preview, add a reviewed override with an agent port mapping such as
`127.0.0.1::3000`, start your server on `0.0.0.0:3000` inside the agent, then use
`docker compose port agent 3000` to discover the assigned loopback port. The base
template publishes no ports. Publishing a preview makes it accessible to local
host processes; it does not authenticate the application.

## Stop, rebuild and remove

Use the same project name, Docker context, file arguments and workspace path each
time. Closing a terminal leaves the service running. Stopping or recreating a
container ends its processes, including tmux shells. Saved files and agent
transcripts survive in the checkout and home volume.

| Command after `docker compose --env-file /dev/null -f compose.yaml` | Result |
| --- | --- |
| `stop` | Stop processes; retain containers, files and volumes. |
| `start --wait` | Start the retained containers. |
| `build agent`, then `up -d --force-recreate --wait` | Rebuild from trusted configuration; retain files and volumes. |
| `down` | Remove containers and networks; retain files and named volumes. |
| `down --volumes` | Also delete this project's home and database data. The host clone remains. |

Only delete the checkout after saving work you intend to keep. No command in this
example prunes Docker globally. If Docker is unavailable, state is unknown until
the daemon returns; it does not mean your workspace was deleted.

## What the sandbox contains

The agent has a read-only root filesystem, no Linux capabilities, no privilege
escalation, a 2 CPU/4 GiB/512 PID budget and a 512 MiB temporary directory. Its only
host bind is the dedicated checkout. Its home is a named volume. It receives no
host home, Docker socket, SSH agent, WorkSpaces automation socket or credentials.
The optional database is a separate service with its own smaller resource budget.

Outbound networking is allowed. This includes reachable host and LAN services;
Compose project networks are not an egress allowlist. For restricted egress, add
an enforced network policy or proxy. Proxy environment variables alone cannot
enforce the boundary. Local host software with Docker access can inspect or modify
these containers and volumes. Containers share the Docker host's Linux kernel,
so hostile-code isolation needs a stronger boundary such as a dedicated VM.

Treat the effective Compose configuration as trusted executable input. An agent
that can edit it could ask Docker for host mounts at the next start. Keep your
reviewed snapshot and Dockerfile outside the mounted clone, and explicitly review
updates. See Docker's [Compose trust model](https://docs.docker.com/compose/trust-model/)
and [service controls](https://docs.docker.com/reference/compose-file/services/).

The Node and Postgres base images use multi-platform digests resolved on
2026-09-12. Debian packages are installed from the current signed package indexes
at build time; the whole build is not byte-for-byte reproducible. Update the base
digest and rebuild regularly to pick up security fixes, then run the smoke test.

## Verify the example

```bash
./smoke.sh
./smoke.sh --with-postgres --skip-build
```

This is new coverage for the standalone runtime, separate from the app's provider
unit tests. It runs against your selected Docker context with disposable clones
outside the source repository. It checks concurrent projects, Git commits, runtime
restrictions, separate files and volumes, real PTY/tmux reattachment, stop/start,
recreation, retained state after `down`, and deleting one project while its neighbor
keeps working. The Postgres mode also verifies database connectivity and data
persistence. A separate disposable container checks Git with a UID501-owned
workspace, then disables system Git configuration to reproduce the ownership
failure. It also checks that unrelated paths remain untrusted. The test changes
`create_host_path` in a disposable copy to prove the missing-directory check
detects that regression.

Cleanup deletes only the generated `ws-smoke-*` projects and their volumes. It
retains the temporary fixture directory and logs, prints their path, and fails if
cleanup fails. It never uses your current checkout as writable sandbox data and
does not copy any host credentials. The smoke test proves the execution environment;
it does not sign in to an agent provider or spend model credits.
