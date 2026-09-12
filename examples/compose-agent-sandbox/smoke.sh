#!/usr/bin/env bash
# Exercises the sandbox contract against a real Docker daemon using two disposable
# clones. Cleanup removes only this run's projects and volumes; fixtures stay in /tmp.
# Container shell expressions and SQL quoting must reach the container unchanged.
# shellcheck disable=SC2016
set -euo pipefail

with_postgres=false
skip_build=false
for argument in "$@"; do
  case "$argument" in
    --with-postgres) with_postgres=true ;;
    --skip-build) skip_build=true ;;
    *) printf 'Usage: %s [--with-postgres] [--skip-build]\n' "$0" >&2; exit 2 ;;
  esac
done

reference_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
test_root=$(mktemp -d /tmp/workspaces-compose-smoke.XXXXXXXX)
test_root=$(cd "$test_root" && pwd -P)
run_id="ws-smoke-$(basename "$test_root" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
docker_context=${DOCKER_CONTEXT:-$(docker context show)}
sandbox_image=${SANDBOX_IMAGE:-workspaces-compose-agent:v1}
trusted_dir="$test_root/trusted"
mkdir "$trusted_dir"
cp "$reference_dir/compose.yaml" "$reference_dir/compose.postgres.yaml" \
  "$reference_dir/Dockerfile" "$reference_dir/.dockerignore" "$trusted_dir/"

compose() {
  local slot=$1
  shift
  local files=(-f "$trusted_dir/compose.yaml")
  if "$with_postgres" && [[ "$slot" == a || "$slot" == b ]]; then
    files+=(-f "$trusted_dir/compose.postgres.yaml")
  fi
  WORKSPACE_DIR="$test_root/$slot" SANDBOX_IMAGE="$sandbox_image" \
    docker --context "$docker_context" compose --env-file /dev/null \
    --project-name "$run_id-$slot" "${files[@]}" "$@"
}

cleanup() {
  local result=$?
  trap - EXIT
  for slot in a b missing mutation; do
    if ! compose "$slot" down --volumes --remove-orphans --timeout 5 >> "$test_root/cleanup.log" 2>&1; then
      printf 'Cleanup failed for %s; inspect %s/cleanup.log\n' "$run_id-$slot" "$test_root" >&2
      result=1
    fi
  done
  printf 'Disposable fixture files and logs: %s\n' "$test_root"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

docker --context "$docker_context" info --format '{{.ServerVersion}}' > "$test_root/docker-version.txt"
docker --context "$docker_context" compose version
printf 'Docker context: %s; projects: %s-a and %s-b\n' "$docker_context" "$run_id" "$run_id"

# Never mount this source repository. Fixtures have independent Git object stores.
git init -q "$test_root/seed"
printf 'sandbox fixture\n' > "$test_root/seed/README.md"
git -C "$test_root/seed" add README.md
git -C "$test_root/seed" -c user.name='Sandbox smoke' -c user.email=smoke@example.invalid commit -qm fixture
for slot in a b; do
  git clone -q --no-local "$test_root/seed" "$test_root/$slot"
  git -C "$test_root/$slot" remote set-url origin https://example.invalid/sandbox.git
  # Test-owned content only. This also runs on Linux hosts whose UID is not 1000.
  chmod -R a+rwX "$test_root/$slot"
done

if env -u WORKSPACE_DIR docker --context "$docker_context" compose --env-file /dev/null \
  -p "$run_id-missing" -f "$trusted_dir/compose.yaml" config > "$test_root/unset.log" 2>&1; then
  fail 'unset WORKSPACE_DIR was accepted'
fi
pass 'missing workspace variable fails closed'

if ! "$skip_build"; then compose a build agent; fi

# Docker Desktop can preserve macOS UID 501 on a writable bind. Reproduce that
# ownership mismatch independently of the active runtime's host-file translation.
docker --context "$docker_context" run --rm --user 1000:1000 --read-only \
  --cap-drop ALL --security-opt no-new-privileges --cpus 2 --memory 4g --pids-limit 512 \
  --tmpfs /workspace:rw,exec,nosuid,nodev,uid=501,gid=20,mode=0777 --tmpfs /tmp \
  "$sandbox_image" bash -lc '
    set -eu
    git init -q -b smoke /workspace
    test -w /workspace
    git status --porcelain
    if GIT_CONFIG_NOSYSTEM=1 git status --porcelain 2>/tmp/ownership-mutation.log; then
      echo "Removing system Git configuration should reject the different owner" >&2
      exit 1
    fi
    git init -q -b smoke /tmp
    if git -C /tmp status --porcelain 2>/tmp/untrusted-owner.log; then
      echo "The safe-directory exception must not cover other paths" >&2
      exit 1
    fi
  '
pass 'Git accepts writable UID501 workspace, rejects other paths, and detects removal of the scoped exception'

if compose missing create agent > "$test_root/missing.log" 2>&1; then
  fail 'nonexistent bind source was accepted'
fi
[[ ! -e "$test_root/missing" ]] || fail 'Docker created a missing bind source'
pass 'nonexistent bind source is rejected without creating a directory'

# Mutation proof: removing the guard must let Docker create the unwanted directory.
sed 's/create_host_path: false/create_host_path: true/' "$trusted_dir/compose.yaml" > "$trusted_dir/mutated.yaml"
WORKSPACE_DIR="$test_root/mutation" SANDBOX_IMAGE="$sandbox_image" \
  docker --context "$docker_context" compose --env-file /dev/null -p "$run_id-mutation" \
  -f "$trusted_dir/mutated.yaml" up -d --no-build agent > "$test_root/mutation.log" 2>&1
[[ -d "$test_root/mutation" ]] || fail 'missing-path mutation did not exercise the guard'
pass 'mutation removing create_host_path guard reproduces unwanted directory creation'

compose a up -d --wait --wait-timeout 90 > "$test_root/up-a.log" 2>&1 &
pid_a=$!
compose b up -d --wait --wait-timeout 90 > "$test_root/up-b.log" 2>&1 &
pid_b=$!
result_a=0
result_b=0
wait "$pid_a" || result_a=$?
wait "$pid_b" || result_b=$?
if [[ "$result_a" != 0 || "$result_b" != 0 ]]; then
  cat "$test_root/up-a.log" "$test_root/up-b.log" >&2
  fail 'both projects must become healthy'
fi
pass 'two projects run concurrently'

for slot in a b; do
  compose "$slot" exec -T agent bash -lc '
    set -eu
    test "$(id -u)" = 1000
    test "$HOME" = /home/agent
    test "$(pwd)" = /workspace
    test -d .git
    test ! -e .git/objects/info/alternates
    git status --porcelain
    git -c user.name=Agent -c user.email=agent@example.invalid commit --allow-empty -qm sandbox
    test -z "${SSH_AUTH_SOCK:-}"
    test -z "${OPENAI_API_KEY:-}"
    test ! -e /var/run/docker.sock
    test ! -e /run/host-services/ssh-auth.sock
    test ! -e /workspace/../trusted
    touch "$HOME/home-marker" /workspace/workspace-marker /tmp/temporary-marker
    if touch /etc/sandbox-write-test 2>/dev/null; then exit 1; fi
    node --version
    npm --version
    python3 -m venv "$HOME/venv"
    "$HOME/venv/bin/python" --version
  '
  container_id=$(compose "$slot" ps -q agent)
  docker --context "$docker_context" inspect "$container_id" |
    compose "$slot" exec -T agent python3 -c '
import json, sys
c = json.load(sys.stdin)[0]
h = c["HostConfig"]
assert c["Config"]["User"] == "1000:1000"
assert h["ReadonlyRootfs"] and not h["Privileged"]
assert "ALL" in h["CapDrop"] and not h["CapAdd"]
assert "no-new-privileges:true" in h["SecurityOpt"]
assert h["NanoCpus"] == 2_000_000_000
assert h["Memory"] == 4 * 1024**3 and h["PidsLimit"] == 512
assert not h["PortBindings"]
binds = [m for m in c["Mounts"] if m["Type"] == "bind"]
assert len(binds) == 1 and binds[0]["Destination"] == "/workspace"
assert all(m["Destination"] in ("/workspace", "/home/agent", "/tmp") for m in c["Mounts"])
'
done
pass 'Git, Node, Python, non-root execution, mount restrictions and resource limits'

compose a exec -T agent bash -lc 'echo only-a > /workspace/only-a; echo only-a > "$HOME/only-a"'
compose b exec -T agent bash -lc 'test ! -e /workspace/only-a; test ! -e "$HOME/only-a"'
pass 'working copies and home volumes are separate'

# A real PTY attaches twice to the same guest tmux session and detaches each time.
compose a exec -T agent python3 - <<'PY'
import os, pty, select, subprocess, time
subprocess.run(["tmux", "new-session", "-d", "-s", "smoke", "bash"], check=True)
original = subprocess.check_output(["tmux", "display-message", "-p", "-t", "smoke", "#{pane_pid}"])
for attempt in range(2):
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp("tmux", ["tmux", "attach-session", "-t", "smoke"])
    deadline = time.monotonic() + 10
    attached = False
    while time.monotonic() < deadline:
        if select.select([fd], [], [], 0.1)[0]:
            os.read(fd, 65536)
        if subprocess.check_output(["tmux", "list-clients", "-t", "smoke"]).strip():
            attached = True
            break
    assert attached, "tmux did not attach to the PTY"
    os.write(fd, b"\x02d")
    while time.monotonic() < deadline:
        done, status = os.waitpid(pid, os.WNOHANG)
        if done:
            assert os.waitstatus_to_exitcode(status) == 0
            break
        time.sleep(0.1)
    else:
        os.kill(pid, 9)
        raise AssertionError("tmux did not detach")
    os.close(fd)
    assert original == subprocess.check_output(["tmux", "display-message", "-p", "-t", "smoke", "#{pane_pid}"])
subprocess.run(["tmux", "kill-session", "-t", "smoke"], check=True)
PY
pass 'real PTY detach and reattach preserve the tmux shell process'

if "$with_postgres"; then
  compose a exec -T postgres psql -U sandbox -d sandbox -v ON_ERROR_STOP=1 \
    -c 'CREATE TABLE smoke (value text); INSERT INTO smoke VALUES ($$persisted$$);'
  compose a exec -T agent python3 -c 'import socket; socket.create_connection(("postgres", 5432), timeout=5).close()'
  database_id=$(compose a ps -q postgres)
  docker --context "$docker_context" inspect "$database_id" |
    compose a exec -T agent python3 -c '
import json, sys
c = json.load(sys.stdin)[0]
assert not c["HostConfig"]["PortBindings"], "database has a host port binding"
assert not any(c["NetworkSettings"]["Ports"].values()), "database has a published port"
assert len(c["NetworkSettings"]["Networks"]) == 1
'
  docker --context "$docker_context" network inspect "$run_id-a"_database |
    compose a exec -T agent python3 -c 'import json, sys; assert json.load(sys.stdin)[0]["Internal"]'
  compose b exec -T postgres psql -U sandbox -d sandbox -Atc \
    "SELECT count(*) FROM pg_tables WHERE tablename='smoke'" | grep -qx 0
  pass 'database is private, reachable from the agent and separate per project'
fi

compose a stop > "$test_root/stop.log" 2>&1
compose a start --wait --wait-timeout 90 > "$test_root/start.log" 2>&1
compose a exec -T agent bash -lc 'test -e "$HOME/home-marker"; test -e /workspace/workspace-marker; test ! -e /tmp/temporary-marker'
pass 'stop and start preserve files while temporary runtime data is cleared'

compose a up -d --force-recreate --wait --wait-timeout 90 > "$test_root/recreate.log" 2>&1
compose a exec -T agent bash -lc 'test -e "$HOME/home-marker"; test -e /workspace/workspace-marker'
if "$with_postgres"; then
  compose a exec -T postgres psql -U sandbox -d sandbox -Atc 'SELECT value FROM smoke' | grep -qx persisted
fi
pass 'container recreation preserves workspace, home and optional database data'

compose a down > "$test_root/down.log" 2>&1
compose a up -d --wait --wait-timeout 90 > "$test_root/restore.log" 2>&1
compose a exec -T agent bash -lc 'test -e "$HOME/home-marker"; test -e /workspace/workspace-marker'
pass 'down without volumes retains saved state'

compose a down --volumes > "$test_root/delete-a.log" 2>&1
compose b exec -T agent bash -lc 'test -e "$HOME/home-marker"; test -e /workspace/workspace-marker; git status --porcelain'
pass 'deleting one project leaves its neighbor working'
printf 'PASS Compose sandbox end-to-end (%s)\n' "$run_id"
