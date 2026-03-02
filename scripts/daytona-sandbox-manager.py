#!/usr/bin/env python3
"""Daytona sandbox manager — CLI for WorkspaceManager Swift app.

Usage:
    daytona-sandbox-manager.py create --name <name> [--clone-url <url>]
    daytona-sandbox-manager.py ssh-command --sandbox-id <id>
    daytona-sandbox-manager.py delete --sandbox-id <id>
    daytona-sandbox-manager.py list

All output is JSON to stdout for easy parsing from Swift.
"""

import argparse
import json
import os
import sys
from pathlib import Path


def load_api_key() -> str:
    env_path = Path.home() / ".env"
    if env_path.exists():
        for line in env_path.read_text().splitlines():
            if "=" in line and not line.startswith("#"):
                key, _, value = line.partition("=")
                os.environ.setdefault(key.strip(), value.strip())

    api_key = os.environ.get("DAYTONA_API_KEY")
    if not api_key:
        print(json.dumps({"error": "DAYTONA_API_KEY not found"}), file=sys.stderr)
        sys.exit(1)
    return api_key


def get_client():
    from daytona import Daytona, DaytonaConfig

    return Daytona(DaytonaConfig(api_key=load_api_key()))


def cmd_create(args):
    daytona = get_client()
    sandbox = daytona.create()

    ssh = sandbox.create_ssh_access(expires_in_minutes=480)

    if args.clone_url:
        sandbox.git.clone(args.clone_url, f"/home/daytona/{args.name}")

    print(
        json.dumps(
            {
                "sandbox_id": sandbox.id,
                "ssh_command": ssh.ssh_command,
                "ssh_token": ssh.token,
                "expires_at": ssh.expires_at.isoformat(),
                "home_dir": sandbox.get_user_home_dir(),
                "work_dir": sandbox.get_work_dir(),
                "state": str(sandbox.state),
            }
        )
    )


def cmd_ssh_command(args):
    daytona = get_client()
    sandbox = daytona.get(args.sandbox_id)
    ssh = sandbox.create_ssh_access(expires_in_minutes=480)
    print(
        json.dumps(
            {
                "sandbox_id": sandbox.id,
                "ssh_command": ssh.ssh_command,
                "ssh_token": ssh.token,
                "expires_at": ssh.expires_at.isoformat(),
                "state": str(sandbox.state),
            }
        )
    )


def cmd_delete(args):
    daytona = get_client()
    sandbox = daytona.get(args.sandbox_id)
    sandbox.delete()
    print(json.dumps({"deleted": True, "sandbox_id": args.sandbox_id}))


def cmd_list(_args):
    daytona = get_client()
    sandboxes = daytona.list()
    result = []
    for sb in sandboxes:
        result.append(
            {
                "sandbox_id": sb.id,
                "state": str(sb.state),
            }
        )
    print(json.dumps(result))


def main():
    parser = argparse.ArgumentParser(description="Daytona sandbox manager")
    sub = parser.add_subparsers(dest="command", required=True)

    create_p = sub.add_parser("create")
    create_p.add_argument("--name", required=True)
    create_p.add_argument("--clone-url")

    ssh_p = sub.add_parser("ssh-command")
    ssh_p.add_argument("--sandbox-id", required=True)

    del_p = sub.add_parser("delete")
    del_p.add_argument("--sandbox-id", required=True)

    sub.add_parser("list")

    args = parser.parse_args()

    try:
        {"create": cmd_create, "ssh-command": cmd_ssh_command, "delete": cmd_delete, "list": cmd_list}[
            args.command
        ](args)
    except Exception as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
