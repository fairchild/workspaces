#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Compact lume VM status — cuts the noise from `lume ls`."""

import argparse
import json
import os
import re
import subprocess
import sys

LUME_BIN = os.environ.get("LUME_BIN", "lume")

# ── ANSI helpers ──

USE_COLOR = sys.stdout.isatty()

GREEN = "\033[32m" if USE_COLOR else ""
YELLOW = "\033[33m" if USE_COLOR else ""
RED = "\033[31m" if USE_COLOR else ""
GRAY = "\033[90m" if USE_COLOR else ""
BOLD = "\033[1m" if USE_COLOR else ""
RESET = "\033[0m" if USE_COLOR else ""

STATUS_ICONS: dict[str, str] = {
    "running": f"{GREEN}●{RESET}",
    "stopped": f"{GRAY}○{RESET}",
    "suspended": f"{YELLOW}◐{RESET}",
    "provisioning": f"{YELLOW}◌{RESET}",
    "stale": f"{RED}✖{RESET}",
}


def icon_for(status: str) -> str:
    if "stale" in status:
        return STATUS_ICONS["stale"]
    for key, icon in STATUS_ICONS.items():
        if key in status:
            return icon
    return f"{GRAY}?{RESET}"


def strip_ansi(text: str) -> str:
    return re.sub(r"\033\[[0-9;]*m", "", text)


# ── Formatters ──


def fmt_disk(disk: dict) -> str:
    alloc = disk["allocated"]
    total = disk["total"]
    if alloc == 0:
        return "0B"
    return f"{alloc / (1024**3):.1f}/{total / (1024**3):.0f}G"


def fmt_mem(bytes_: int) -> str:
    return f"{bytes_ / (1024**3):.0f}G"


def fmt_vnc(url: str | None) -> str:
    if not url:
        return "-"
    m = re.search(r":(\d+)$", url)
    return f":{m.group(1)}" if m else url


# ── Status sorting ──

STATUS_ORDER = {"running": 0, "suspended": 1, "stopped": 2}


def sort_key(vm: dict) -> tuple:
    s = vm["status"].split()[0]
    rank = STATUS_ORDER.get(s, 9 if "stale" in vm["status"] else 3)
    return (rank, vm["name"])


# ── Table rendering ──


def print_table(headers: list[str], rows: list[list[str]]) -> None:
    widths = [0] * len(headers)
    for row in [headers, *rows]:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(strip_ansi(cell)))

    header_line = "  ".join(f"{BOLD}{h:<{widths[i]}}{RESET}" for i, h in enumerate(headers))
    print(header_line)

    for row in rows:
        cells = []
        for i, cell in enumerate(row):
            padding = widths[i] - len(strip_ansi(cell))
            cells.append(cell + " " * padding)
        print("  ".join(cells))


# ── Data fetching ──


def fetch_vms() -> list[dict]:
    result = subprocess.run(
        [LUME_BIN, "ls", "-f", "json"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"lume ls failed: {result.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    return json.loads(result.stdout)


def is_stale(vm: dict) -> bool:
    return "stale" in vm["status"] or (
        "provisioning" in vm["status"] and vm["diskSize"]["allocated"] == 0
    )


# ── Commands ──


def cmd_json(vms: list[dict]) -> None:
    print(json.dumps(vms, indent=2))


def cmd_quiet(vms: list[dict]) -> None:
    for vm in sorted(vms, key=sort_key):
        print(f"  {icon_for(vm['status'])} {vm['name']:40s} {vm['status']}")


def cmd_prune(vms: list[dict], *, yes: bool = False) -> None:
    stale = [vm for vm in vms if is_stale(vm)]
    if not stale:
        print("No stale VMs to prune.")
        return

    print(f"Found {len(stale)} stale VM(s):")
    for vm in stale:
        print(f"  - {vm['name']}")

    if not yes:
        confirm = input("\nDelete all? [y/N] ")
        if confirm.strip().lower() != "y":
            print("Aborted.")
            return

    for vm in stale:
        name = vm["name"]
        print(f"Deleting {name}...")
        r = subprocess.run(
            [LUME_BIN, "delete", name, "--force"],
            capture_output=True, text=True,
        )
        if r.returncode != 0:
            print(f"  Failed: {r.stderr.strip()}")
    print("Done.")


def cmd_list(vms: list[dict], *, show_all: bool = False, stale_only: bool = False) -> None:
    if stale_only:
        vms = [vm for vm in vms if is_stale(vm)]
        if not vms:
            print("No stale VMs.")
            return

    vms.sort(key=sort_key)

    headers = ["", "NAME", "OS", "STATUS", "DISK", "NET", "IP", "SSH", "VNC"]
    if show_all:
        headers += ["CPU", "MEM", "DISPLAY", "SHARES"]

    rows: list[list[str]] = []
    for vm in vms:
        row = [
            icon_for(vm["status"]),
            vm["name"],
            vm["os"],
            vm["status"],
            fmt_disk(vm["diskSize"]),
            vm["networkMode"],
            vm["ipAddress"] or "-",
            "yes" if vm.get("sshAvailable") else "-",
            fmt_vnc(vm.get("vncUrl")),
        ]
        if show_all:
            row += [
                str(vm["cpuCount"]),
                fmt_mem(vm["memorySize"]),
                vm["display"],
                ",".join(vm["sharedDirectories"]) if vm.get("sharedDirectories") else "-",
            ]
        rows.append(row)

    print_table(headers, rows)
    print(f"\n{GRAY}{len(vms)} VM(s){RESET}")


# ── CLI ──


def main() -> None:
    parser = argparse.ArgumentParser(description="Compact lume VM status")
    parser.add_argument("-a", "--all", action="store_true", help="show all columns")
    parser.add_argument("-j", "--json", action="store_true", help="raw JSON output")
    parser.add_argument("-s", "--stale", action="store_true", help="show only stale/stuck VMs")
    parser.add_argument("-p", "--prune", action="store_true", help="delete stale VMs (with confirmation)")
    parser.add_argument("-y", "--yes", action="store_true", help="skip confirmation (for --prune)")
    parser.add_argument("-q", "--quiet", action="store_true", help="just names and status")
    args = parser.parse_args()

    vms = fetch_vms()
    if not vms:
        print("No VMs.")
        return

    if args.json:
        cmd_json(vms)
    elif args.prune:
        cmd_prune(vms, yes=args.yes)
    elif args.quiet:
        cmd_quiet(vms)
    else:
        cmd_list(vms, show_all=args.all, stale_only=args.stale)


if __name__ == "__main__":
    main()
