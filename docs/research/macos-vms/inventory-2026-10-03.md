# macOS VM inventory and refresh, 2026-10-03

Scope: what tart and lume are on this Mac, what each one holds on disk, what
each upstream has shipped since our installed versions, and which tool to keep.
The note is in time order: the inventory first, then the boot tests, then the
lume upgrade. Where a later section changed what an earlier line says, the
earlier line is marked **superseded** and points to the section that replaced
it. Facts are marked as observed, as upstream claims, or as unverified. Lines
re-read on 2026-10-12 say so.

## Installed state (observed 18:08-18:12 UTC, before the boot tests and the upgrade)

| Item | Where | Version or size |
|---|---|---|
| tart CLI | `/opt/homebrew/bin/tart`, brew keg `cirruslabs/cli/tart` | 2.32.1 (72 MB keg) |
| tart VM `workspaces-tart-ui` | `~/.tart/vms/workspaces-tart-ui` | 120 GB sparse, 85 GB allocated, 4 CPU, 8 GB RAM. macOS version: **superseded**, the boot test read 26.2 (25C56) |
| tart cache | `~/.tart/cache` | empty |
| lume CLI | `~/.local/bin/lume` → `~/.local/share/lume/lume.app` | 0.3.3 (16 MB). **Superseded**: 0.6.0 since the lume upgrade below |
| lume daemon | `lume serve --port 7777`, running from the 0.3.3 app | zero VMs reported (`GET /lume/vms` → `[]`). **Superseded**: that process was stopped and a 0.6.0 daemon started in the lume upgrade below |
| lume home storage | `~/.lume` | 16 empty UUID directories, 0 bytes; no VMs |
| lume app storage, validated base | `~/Library/Application Support/WorkspaceManager/LumeStorage/validated-bases/workspaces-validated-base-macos-tahoe-26-2-xcode-26-2` | macOS Tahoe 26.2, 4 CPU, 8 GB RAM, 50 GB logical, 24.7 GiB allocated (26.5 GB; the same 26,493,968,384 bytes the upgrade section reads), stopped, network `bridged:en0` in its VM config |
| lume app storage, 26.3.1 base | `LumeValidatedBases/…tahoe-26-3-1…json` | state `invalid` (stock prepare failed); no disk |

Free space on the Data volume was 111 GiB (`df`, 94% used), against an earlier
estimate of about 54 GB. Re-check before any download.

## Upstream (observed in release metadata and notes)

- tart: installed 2.32.1, latest 2.40.1 (2026-09-30). Source moved from
  cirruslabs to openai (2.33.0). License is FSL-1.1-ALv2 (Functional Source
  License; internal use is permitted, and a "Competing Use" is excluded; each
  release converts to Apache-2.0 after two years).
- lume: installed 0.3.3 (**superseded**: 0.6.0 is installed now), latest 0.6.0
  (2026-10-01). 0.4.0 added telemetry schema v3 and extra data disks. 0.5.0
  added a native display, live attach, and detached runs. 0.6.0 added GPU
  passthrough, a no-VNC option, and forced stop. Lume is in the trycua/cua
  monorepo.

## Refresh status (as of 18:12 UTC)

- tart: the brew route is blocked. The cirruslabs/cli tap is stale (its formula
  is 2.32.1 and it fails on brew 7 with `depends_on macos:` disabled). Its
  source is untrusted. Upstream now ships through `openai/tools` (tart 2.40.1 plus
  softnet 0.24.0). The 2.40.1 release
  (<https://github.com/openai/tart/releases/tag/2.40.1>) was downloaded with
  `gh release download 2.40.1 -R openai/tart -p tart.tar.gz -p tart_2.40.1_checksums.txt`
  and extracted only in the session scratchpad, not installed. `shasum -a 256 -c
  tart_2.40.1_checksums.txt` printed `tart.tar.gz: OK`; the release lists that
  asset's digest as
  `sha256:363e2701154a8155cbc1bb6d845430c9b42697d2a186bc49574471ca2877db46`.
  `codesign` names Cirrus Labs team 9M2P8L4D89 and `spctl` reports it
  notarized. Its `tart list` and `tart get workspaces-tart-ui` read the existing
  VM. Brew was not changed.
- lume: 0.6.0 was staged side by side at `~/.local/share/lume-0.6.0/lume.app`,
  from `lume-0.6.0-darwin-arm64.tar.gz` in
  <https://github.com/trycua/cua/releases/tag/lume-v0.6.0>. Its local
  `shasum -a 256` was
  `4d25c7c36ebd3fdf0e2f97f9e7a2c4ff2d0538ba9eb2d536f6dbb542d9d504a7`. On
  2026-10-03 that value was not compared to the release; on 2026-10-12 the
  release's listed digest for the asset was read and matches it. `codesign`
  names Cua AI team YCK386LBJ7, `spctl` reports it notarized, and it runs
  `--version` → 0.6.0 and reads the app's validated base. **Superseded**: the
  swap this section described as pending was done in the lume upgrade below.

## Image sizes (not pulled; compressed, from registry manifests read 2026-10-03)

The tart sizes are for the mutable `latest` tag at the time of the read. The
manifest digests were not recorded, so a later read of the same tag can return
a different image and size.

- `ghcr.io/cirruslabs/macos-tahoe-base:latest`: 27.0 GB, 96 layers.
- `ghcr.io/cirruslabs/macos-tahoe-xcode:latest`: 62.1 GB, 263 layers.
- lume `trycua/macos-tahoe-xcode:26.2`: the registry denied the manifest read
  anonymously; size unavailable. The app already has a 26.2 validated base locally.

## Boot test

Both boots waited on a load gate set for this session, not a repo preflight
(`scripts/lume-host-preflight.sh` checks disk, not swap or load). It sampled
every 30 s with a 25-minute cap and opened when swap use fell under 92% of the
swap total; the lume gate also required the 15-minute load average under 40.
Swap was near its ceiling all session, so the gate opened at 91%.

tart (`workspaces-tart-ui`), done 18:14:12 to 18:14:56 UTC (about 44 s running):

- Gate opened at 18:14:05 (swap 91%, load15 7.90); a re-read at 18:14:08 showed
  swap 91.9%, load15 7.87.
- Memory set for the run with `tart set workspaces-tart-ui --memory 4096` and
  restored with `tart set workspaces-tart-ui --memory 8192` after shutdown.
- Booted headless with `taskpolicy -b nice -n 20 tart run workspaces-tart-ui --no-graphics`.
  `tart ip workspaces-tart-ui --wait 120` returned an address on tart's NAT
  network.
- Guest reports macOS 26.2 (build 25C56), via `tart exec workspaces-tart-ui sw_vers`.
  So `tart exec` works (the guest agent is present). SSH (22) and VNC (5900) were
  closed. Enabling either needs in-guest setup, which was not done.
- Swap rose to about 94% during the run. Shut down with
  `tart stop workspaces-tart-ui --timeout 30`, exit 0.

lume (clone `lume-boot-test-26-2` of the 26.2 validated base), done 18:19:47 to 18:20:18 UTC,
with the 0.6.0 binary from `~/.local/share/lume-0.6.0` (the installed CLI was
still 0.3.3):

- Gate opened at 18:19:36 (swap 91%, load15 7.60). The base was cloned, never booted.
- Cloned with `lume clone workspaces-validated-base-macos-tahoe-26-2-xcode-26-2 lume-boot-test-26-2 --source-storage "$HOME/Library/Application Support/WorkspaceManager/LumeStorage/validated-bases"`.
  No destination storage was given, so the clone went to lume's default (home)
  storage.
- Clone set to 4 GB (`lume set lume-boot-test-26-2 --memory 4GB`), run with
  `taskpolicy -b nice -n 20 lume run lume-boot-test-26-2 --detach --display none --vnc disabled`.
  No `--network` flag was passed, so the clone ran with the bridged network it
  inherited from the base.
- It got a LAN address, port 22 was open, and `lume ssh` returned EOF. No
  credentials were tried, so the guest OS version is unverified.
- Stopped with `lume stop lume-boot-test-26-2`; status read stopped. The clone
  was deleted with `lume delete lume-boot-test-26-2` on the operator's go-ahead.
  The base was read afterward: still stopped, still 8 GB.

This boot says nothing about the way the app runs clones. The app boots macOS
clones with `--network nat` (`LumeWorkspaceProvider.defaultMacOSRunNetworkMode`),
and `docs/development/lume-runner-setup.md` warns that a base prepared with
bridged networking may not negotiate NAT. Whether this base boots under NAT is
unverified.

## Lume upgrade (applied 18:58:56 to 18:59:30 UTC)

- 0.3.3 copied with `cp -Rp lume.app lume-0.3.3.app.bak` in `~/.local/share/lume`,
  and the original moved aside to `lume-0.3.3.app.replaced` in the swap. On
  2026-10-12, `diff -rq` of the two directories printed nothing (exit 0), so they
  are identical and either one can go.
- Stopped the 0.3.3 daemon by pid after `ps -p` confirmed it was
  `lume serve --port 7777`. Copied 0.6.0 in as `lume.app`;
  `codesign --verify --deep --strict lume.app` passed. `lume --version` reads 0.6.0.
- Started the daemon with `scripts/lume-ensure-daemon.sh`.
  `GET /lume/host/status` returned `{"status":"healthy","max_vms":2,"vm_count":0,"available_slots":2}`.
  `max_vms: 2` is the daemon's own report and was not exercised here.
  `docs/development/lume-validation.md` describes the limit as active (running)
  VMs; the app reads this endpoint only to check the daemon is reachable.
- Base check, read-only and not booted. It covers some of what the app checks,
  not all of it:
  - manifest `state: ready`, `validatedAt 2026-03-15T11:01:23Z`, `schemaVersion: 1`
    (the app expects 1);
  - `disk.img` and `config.json` present, 26.5 GB allocated;
  - `lume get … --storage <validated-bases>` reports it stopped, and
    `lume ls --storage <validated-bases>` lists it.

  Not checked: the manifest's `hostProfileKey` against the profile the app
  expects, which `LumeValidatedBaseService.validationReason` also requires, and
  the bridged-versus-NAT question above. So this check cannot say the app will
  accept and boot the base. `scripts/lume-standalone-verify-base.sh` boots the
  base, so it was not run.
- Telemetry: at 18:59:23, `telemetryEnabled: true` → `false` in
  `~/.config/lume/config.yaml` (backup `config.yaml.bak-telemetry`), and
  `lume config get` then read "Telemetry enabled: false". That is a read of the
  file. The daemon had been started 20 s earlier and was not restarted, so
  whether it honored the change that day is unverified. On 2026-10-12 the key
  still reads `false`, and the running daemon was started 2026-10-09, after the
  edit. Whether lume sends no telemetry with the key off was not checked
  here.
