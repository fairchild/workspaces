# Builds the terminal environment shared by independent Compose workspaces.
# Tool installation happens here so runtime containers can keep a read-only root.
FROM node:24-bookworm-slim@sha256:2fe369e969550cde8e867afc3fe370b260140cab4a23d467074295b42163d553

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash ca-certificates curl git less openssh-client \
        python3 python3-pip python3-venv tmux \
    && apt-get clean \
    && find /var/lib/apt/lists -mindepth 1 -delete \
    && usermod --login agent --home /home/agent --move-home node \
    && groupmod --new-name agent node \
    && mkdir -p /workspace /home/agent/.local/bin \
    && chown -R 1000:1000 /workspace /home/agent \
    && git config --system --add safe.directory /workspace \
    && printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> /home/agent/.profile

# tmux invokes this only when creating a session. Its child owns the configured
# command, so exit, exec, failure and interruption can all return to a usable shell.
RUN <<'INSTALL_TERMINAL'
cat > /usr/local/bin/workspaces-terminal <<'TERMINAL'
#!/bin/bash
if [[ -n "${SANDBOX_TERMINAL_COMMAND:-}" ]]; then
    trap ':' INT
    /bin/bash -lc "$SANDBOX_TERMINAL_COMMAND"
    result=$?
    trap - INT
    if [[ "$result" -ne 0 ]]; then
        printf '\nTerminal command exited with status %s. Opening a shell.\n' "$result" >&2
    fi
fi
exec /bin/bash -l
TERMINAL
chmod 0755 /usr/local/bin/workspaces-terminal
INSTALL_TERMINAL

ENV HOME=/home/agent \
    NPM_CONFIG_PREFIX=/home/agent/.local \
    TERM=xterm-256color
WORKDIR /workspace
USER 1000:1000
CMD ["sleep", "infinity"]
