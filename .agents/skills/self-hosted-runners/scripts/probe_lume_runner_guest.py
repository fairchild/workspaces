#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///

from __future__ import annotations

import argparse
import ipaddress
import json
import re
import subprocess
import sys
from typing import Any


def run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, capture_output=True, text=True, check=False)


def lume_get(vm_name: str, storage: str) -> str:
    result = run(["lume", "get", vm_name, "--storage", storage])
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "lume get failed")
    return result.stdout


def extract_ip(text: str) -> str | None:
    candidates = re.findall(r"\b(\d{1,3}(?:\.\d{1,3}){3})\b", text)
    for candidate in candidates:
        try:
            ip = ipaddress.ip_address(candidate)
        except ValueError:
            continue
        if ip.is_loopback:
            continue
        return candidate
    return None


def ssh(ip: str, command: str, user: str) -> subprocess.CompletedProcess[str]:
    return run(
        [
            "ssh",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/tmp/lume-known-hosts",
            "-o",
            "ConnectTimeout=10",
            f"{user}@{ip}",
            command,
        ]
    )


def summarize_guest(ip: str, user: str) -> dict[str, Any]:
    summary: dict[str, Any] = {"ip": ip, "ssh_user": user}

    sw_vers = ssh(ip, "sw_vers", user)
    summary["ssh_ok"] = sw_vers.returncode == 0
    summary["sw_vers"] = sw_vers.stdout.strip()
    if not summary["ssh_ok"]:
        summary["ssh_error"] = sw_vers.stderr.strip()
        return summary

    xcode_select = ssh(ip, "xcode-select -p", user)
    xcodebuild = ssh(ip, "xcodebuild -version", user)
    xcode_apps = ssh(ip, "bash -lc 'find /Applications /Users/lume/Applications -maxdepth 2 -name \"Xcode*.app\" 2>/dev/null'", user)
    svc_status = ssh(ip, "bash -lc 'cd ~/.local/share/actions-runner-lume && ./svc.sh status'", user)
    runner_log = ssh(
        ip,
        "bash -lc 'tail -80 ~/Library/Logs/actions.runner.fairchild-workspaces.lume-runner/stdout.log 2>/dev/null'",
        user,
    )

    summary["xcode_select"] = xcode_select.stdout.strip() or xcode_select.stderr.strip()
    summary["xcodebuild"] = xcodebuild.stdout.strip() or xcodebuild.stderr.strip()
    summary["xcode_apps"] = [line for line in xcode_apps.stdout.splitlines() if line.strip()]
    summary["svc_status"] = svc_status.stdout.strip() or svc_status.stderr.strip()
    summary["runner_log_tail"] = runner_log.stdout.strip()

    signatures: list[str] = []
    haystack = "\n".join([summary["xcodebuild"], summary["svc_status"], summary["runner_log_tail"]])
    if "registration has been deleted" in haystack:
        signatures.append("registration_deleted")
    if "A session for this runner already exists" in haystack:
        signatures.append("session_conflict")
    if "xcodebuild requires Xcode" in haystack or (
        summary["xcode_select"] == "/Library/Developer/CommandLineTools" and not summary["xcode_apps"]
    ):
        signatures.append("missing_xcode")
    if "Started:" in summary["svc_status"] and "- 0" in summary["svc_status"]:
        signatures.append("service_not_running")
    summary["signatures"] = signatures
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description="Probe the Lume macOS runner guest over SSH.")
    parser.add_argument("--vm-name", default="workspaces-lume-runner")
    parser.add_argument("--storage", default="workspaces", help="Value passed to `lume get --storage`.")
    parser.add_argument("--ssh-user", default="lume")
    parser.add_argument("--ip", help="Optional direct guest IP. Use this when `lume get` does not report one.")
    parser.add_argument("--json", action="store_true", help="Emit JSON instead of text.")
    args = parser.parse_args()

    vm_text = lume_get(args.vm_name, args.storage)
    ip = args.ip or extract_ip(vm_text)

    output: dict[str, Any] = {
        "vm_name": args.vm_name,
        "storage": args.storage,
        "lume_get": vm_text.strip(),
        "ip": ip,
    }
    if ip:
        output["guest"] = summarize_guest(ip, args.ssh_user)

    if args.json:
        json.dump(output, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0

    print(f"VM: {args.vm_name}")
    print(f"Storage: {args.storage}")
    print(output["lume_get"])
    print()
    if not ip:
        print("No IP found in `lume get` output.")
        print("Retry with --ip <guest-ip> if direct SSH is known to work.")
        return 0

    guest = output["guest"]
    print(f"SSH IP: {ip}")
    print(f"SSH OK: {guest['ssh_ok']}")
    print()
    if not guest["ssh_ok"]:
        print(guest.get("ssh_error", "SSH failed"))
        return 0

    print("Guest OS:")
    print(guest["sw_vers"] or "(empty)")
    print()
    print("Xcode select:")
    print(guest["xcode_select"] or "(empty)")
    print()
    print("Xcode build:")
    print(guest["xcodebuild"] or "(empty)")
    print()
    print("Xcode apps:")
    if guest["xcode_apps"]:
        for item in guest["xcode_apps"]:
            print(f"- {item}")
    else:
        print("- none found")
    print()
    print("Runner service status:")
    print(guest["svc_status"] or "(empty)")
    print()
    print("Signatures:")
    if guest["signatures"]:
        for item in guest["signatures"]:
            print(f"- {item}")
    else:
        print("- none")
    print()
    print("Recent guest runner log:")
    print(guest["runner_log_tail"] or "(empty)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
