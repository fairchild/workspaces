# macOS VM inventory and refresh, 2026-10-03

Scope: what tart and lume are on this Mac, what each one holds on disk, what
each upstream has shipped since our installed versions, and which tool to keep.
Status of the boot test is at the end. Facts are marked as observed or as
upstream claims.

## Installed state (observed)

| Item | Where | Version or size |
|---|---|---|
| tart CLI | `/opt/homebrew/bin/tart`, brew keg `cirruslabs/cli/tart` | 2.32.1 (72 MB keg) |
| tart VM `workspaces-tart-ui` | `~/.tart/vms/workspaces-tart-ui` | 120 GB sparse, 85 GB allocated, 4 CPU, 8 GB RAM, macOS version not recorded (needs boot) |
| tart cache | `~/.tart/cache` | empty |
| lume CLI | `~/.local/bin/lume` → `~/.local/share/lume/lume.app` | 0.3.3 (16 MB) |
| lume daemon | `lume serve --port 7777`, pid 803, running from the 0.3.3 app | zero VMs reported (`GET /lume/vms` → `[]`) |
| lume home storage | `~/.lume` | 16 empty UUID directories, 0 bytes; no VMs |
| lume app storage, validated base | `~/Library/Application Support/WorkspaceManager/LumeStorage/validated-bases/workspaces-validated-base-macos-tahoe-26-2-xcode-26-2` | macOS Tahoe 26.2, 4 CPU, 8 GB RAM, 50 GB logical, 24.7 GB allocated, stopped, bridged:en0 |
| lume app storage, 26.3.1 base | `LumeValidatedBases/…tahoe-26-3-1…json` | state `invalid` (stock prepare failed); no disk |

Free space on the Data volume is 111 GiB (`df`, 94% used). The brief said
about 54 GB. Re-check before any download.

## Upstream (observed in release metadata and notes)

- tart: installed 2.32.1, latest 2.40.1 (2026-09-30). Source moved from
  cirruslabs to openai (2.33.0). License is FSL-1.1-ALv2 (Functional Source
  License; internal use is permitted, and a "Competing Use" is excluded; each
  release converts to Apache-2.0 after two years).
- lume: installed 0.3.3, latest 0.6.0 (2026-10-01). 0.4.0 added telemetry
  schema v3 and extra data disks. 0.5.0 added a native display, live attach,
  and detached runs. 0.6.0 added GPU passthrough, a no-VNC option, and forced
  stop. Lume is in the trycua/cua monorepo.

## Refresh status

- tart: the brew route is blocked. The cirruslabs/cli tap is stale (its formula
  is 2.32.1 and it fails on brew 7 with `depends_on macos:` disabled). Its
  source is untrusted. Upstream now ships through `openai/tools` (tart 2.40.1 plus
  softnet 0.24.0). The 2.40.1 tarball is extracted only in the
  session scratchpad, not installed (sha256 matches the release checksum, signed by
  Cirrus Labs team 9M2P8L4D89, notarized). Its `tart list` and `tart get` read
  the existing VM. Brew was not changed.
- lume: 0.6.0 is staged side by side at `~/.local/share/lume-0.6.0/lume.app`
  (sha256 matches the release, signed by Cua AI team YCK386LBJ7, notarized, runs
  `--version` → 0.6.0, reads the app's validated base). The live shim and the
  0.3.3 daemon were not touched. Swapping requires killing pid 803 and letting the
  app restart its daemon.

## Image sizes (not pulled; compressed, from registry manifests)

- `ghcr.io/cirruslabs/macos-tahoe-base:latest`: 27.0 GB, 96 layers.
- `ghcr.io/cirruslabs/macos-tahoe-xcode:latest`: 62.1 GB, 263 layers.
- lume `trycua/macos-tahoe-xcode:26.2`: the registry denied the manifest read
  anonymously; size unavailable. The app already has a 26.2 validated base locally.

## Boot test

tart (`workspaces-tart-ui`), done 18:14:12 to 18:14:56 UTC (about 44 s running):

- Gate passed at 18:14:08: swap 91.9%, load15 7.87. Memory was set to 4 GB for
  the run and restored to 8 GB after shutdown.
- Booted headless with `taskpolicy -b nice -n 20 tart run --no-graphics`. `tart ip`
  returned 192.168.64.3.
- Guest reports macOS 26.2 (build 25C56), via `tart exec sw_vers`. So `tart exec`
  works (the guest agent is present). SSH (22) and VNC (5900) were closed. Enabling
  either needs in-guest setup, which was not done.
- Swap rose to about 94% during the run. Shut down with `tart stop --timeout 30`,
  exit 0.

lume (clone `lume-boot-test-26-2` of the 26.2 validated base), done 18:19:47 to 18:20:18 UTC:

- Gate opened at 18:19:36 (swap 91%, load15 7.60). The base was cloned, never booted.
- Clone set to 4 GB (`lume set --memory 4GB`), run detached with `--display none --vnc disabled`.
- Reached at 192.168.8.111. Port 22 open. `lume ssh` returned EOF, and no credentials were tried, so the guest OS version is unverified.
- Stopped via `lume stop`, status stopped. Clone deleted (steward go); base checked afterward, still stopped with its 8 GB setting.
