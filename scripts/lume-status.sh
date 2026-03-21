#!/usr/bin/env bash
# Compact lume VM status — cuts the noise from `lume ls`
set -euo pipefail

LUME_BIN="${LUME_BIN:-lume}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -a, --all       Show all columns (cpu, memory, display, shared_dirs)
  -j, --json      Raw JSON output
  -s, --stale     Show only stale/stuck VMs (for cleanup)
  -p, --prune     Delete stale/stuck VMs (prompts for confirmation)
  -q, --quiet     Just names and status, nothing else
  -h, --help      This message
EOF
}

show_all=false
json_mode=false
stale_only=false
prune_mode=false
quiet_mode=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--all)    show_all=true; shift ;;
    -j|--json)   json_mode=true; shift ;;
    -s|--stale)  stale_only=true; shift ;;
    -p|--prune)  prune_mode=true; shift ;;
    -q|--quiet)  quiet_mode=true; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

raw=$("$LUME_BIN" ls -f json 2>/dev/null)
count=$(echo "$raw" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")

if [[ "$count" -eq 0 ]]; then
  echo "No VMs."
  exit 0
fi

if [[ "$json_mode" == true ]]; then
  echo "$raw" | python3 -m json.tool
  exit 0
fi

if [[ "$prune_mode" == true ]]; then
  stale_names=$(echo "$raw" | python3 -c "
import json, sys
vms = json.load(sys.stdin)
stale = [v['name'] for v in vms if 'stale' in v['status'] or ('provisioning' in v['status'] and v['diskSize']['allocated'] == 0)]
for n in stale:
    print(n)
")
  if [[ -z "$stale_names" ]]; then
    echo "No stale VMs to prune."
    exit 0
  fi
  stale_count=$(echo "$stale_names" | wc -l | tr -d ' ')
  echo "Found $stale_count stale VM(s):"
  echo "$stale_names" | while read -r name; do echo "  - $name"; done
  printf "\nDelete all? [y/N] "
  read -r confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo "$stale_names" | while read -r name; do
      echo "Deleting $name..."
      "$LUME_BIN" delete "$name" --force 2>/dev/null || echo "  Failed to delete $name"
    done
    echo "Done."
  else
    echo "Aborted."
  fi
  exit 0
fi

# Python does the formatting — keeps the bash simple
echo "$raw" | python3 -c "
import json, sys

vms = json.load(sys.stdin)
show_all = $( [[ $show_all == true ]] && echo True || echo False )
stale_only = $( [[ $stale_only == true ]] && echo True || echo False )
quiet_mode = $( [[ $quiet_mode == true ]] && echo True || echo False )

# Status styling
STATUS_ICON = {
    'running':    '\033[32m●\033[0m',  # green
    'stopped':    '\033[90m○\033[0m',  # gray
    'suspended':  '\033[33m◐\033[0m',  # yellow
}

def status_icon(s):
    if 'stale' in s:
        return '\033[31m✖\033[0m'  # red
    if 'provisioning' in s:
        return '\033[33m◌\033[0m'  # yellow
    return STATUS_ICON.get(s, '\033[90m?\033[0m')

def fmt_disk(d):
    alloc = d['allocated']
    total = d['total']
    if alloc == 0:
        return '0B'
    gb = alloc / (1024**3)
    tot = total / (1024**3)
    return f'{gb:.1f}/{tot:.0f}G'

def fmt_mem(b):
    return f'{b / (1024**3):.0f}G'

# Filter
if stale_only:
    vms = [v for v in vms if 'stale' in v['status'] or 'provisioning' in v['status']]
    if not vms:
        print('No stale VMs.')
        sys.exit(0)

# Sort: running first, then by name
order = {'running': 0, 'suspended': 1, 'stopped': 2}
vms.sort(key=lambda v: (order.get(v['status'].split()[0], 3 if 'stale' not in v['status'] else 9), v['name']))

if quiet_mode:
    for v in vms:
        icon = status_icon(v['status'])
        print(f\"  {icon} {v['name']:40s} {v['status']}\")
    sys.exit(0)

# Build rows
rows = []
for v in vms:
    icon = status_icon(v['status'])
    name = v['name']
    os_ = v['os']
    status = v['status']
    disk = fmt_disk(v['diskSize'])
    net = v['networkMode']
    ip = v['ipAddress'] or '-'
    ssh = 'yes' if v.get('sshAvailable') else '-'
    storage = v.get('locationName', '-')

    # VNC: just show port, not the full URL
    vnc_raw = v.get('vncUrl') or ''
    if vnc_raw:
        # extract port from vnc://:pass@host:port
        import re
        m = re.search(r':(\d+)\$', vnc_raw)
        vnc = f':{m.group(1)}' if m else vnc_raw
    else:
        vnc = '-'

    row = [icon, name, os_, status, disk, net, ip, ssh, vnc]
    if show_all:
        row.extend([str(v['cpuCount']), fmt_mem(v['memorySize']), v['display']])
        row.append(','.join(v['sharedDirectories']) if v.get('sharedDirectories') else '-')
    rows.append(row)

# Headers
headers = ['', 'NAME', 'OS', 'STATUS', 'DISK', 'NET', 'IP', 'SSH', 'VNC']
if show_all:
    headers.extend(['CPU', 'MEM', 'DISPLAY', 'SHARES'])

# Column widths
widths = [0] * len(headers)
for r in [headers] + rows:
    for i, c in enumerate(r):
        # strip ANSI for width calc
        import re
        plain = re.sub(r'\033\[[0-9;]*m', '', str(c))
        widths[i] = max(widths[i], len(plain))

# Print
hdr = '  '.join(f'\033[1m{h:<{widths[i]}}\033[0m' for i, h in enumerate(headers))
print(hdr)
for r in rows:
    cols = []
    for i, c in enumerate(r):
        import re
        plain = re.sub(r'\033\[[0-9;]*m', '', str(c))
        pad = widths[i] - len(plain)
        cols.append(str(c) + ' ' * pad)
    print('  '.join(cols))

print(f\"\n\033[90m{len(vms)} VM(s)\033[0m\")
"
