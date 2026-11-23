# younix — Roadmap & Agent Tasklist

Single-source tasklist for building out `younix` (UGREEN NASync DXP4800 Plus running GitOps-managed NixOS).

## For Agents: How to Use This File

- **Never execute commands directly on `younix`**: Do not SSH into `younix` or execute remote commands against the NAS (see `AGENTS.md`). Always give the user the exact deployment and verification commands to run on `younix` themselves.
- **Public repository**: `github:stravag/younix` is public. **Never** commit plaintext passwords, API keys, auth keys, or private keys.
- **Module conventions**: Put each feature in its own `modules/<feature>.nix` file and register it in `flake.nix`. Keep host-specific settings in `hosts/younix/configuration.nix`.
- **Safe rollouts**: For risky changes (storage mounts, networking, firewall, SSH, bootloader), test on the `testing-younix` branch first (`comin` activates temporarily via `test`, so a reboot reverts to `main`).
- **Task statuses**:
  - `done` — Completed and deployed.
  - `ready` — Unblocked and has enough context for an agent to implement.
  - `needs-decision` — Requires a user choice (see the **Open Decisions** note in the task) before implementation.
  - `blocked` — Waiting on one or more `Depends on` tasks.
  - `in-progress` — Currently being worked on.
- **When finishing a task**:
  1. Run the task's verification steps (and `nix flake check` if available).
  2. Update the task's `Status` to `done`, check its boxes, and link the added module(s).
  3. Unblock downstream tasks whose dependencies are now all `done` (move them to `ready` or `needs-decision`).
  4. Keep `README.md` updated with any new modules or operational commands.

## Target Architecture

- **Hardware**: UGREEN NASync DXP4800 Plus (Intel Pentium Gold 8505 w/ QuickSync iGPU, 1 TB NVMe for NixOS + fast app data, 128 GB factory UGOS Pro untouched, 4x SATA bays starting with 2x 4 TB HDDs → expanding to 4x 4 TB after migrating from the old NAS).
- **Storage layout**:
  - **1 TB NVMe**: NixOS root, PostgreSQL/Redis databases, Immich thumbnails/cache, Paperless index/data.
  - **HDD array**: Bulk data split into separate subvolumes/datasets (`photos`, `documents`, `media`, `backups`, `share`) so irreplaceable data (`photos`, `documents`, DB dumps) can be snapshotted and backed up offsite without paying to back up large `media` files.
- **Remote access**: Tailscale (zero router port-forwarding) + Caddy reverse proxy for clean HTTPS URLs.
- **Services**: Native NixOS modules (`services.jellyfin`, `services.immich`, `services.paperless`) instead of ad-hoc containers for cleaner upgrades and QuickSync access.

---

## Phase 1 — Foundation (Secrets & Storage)

### T-009 — Expand HDD array with 2nd pair of 4 TB drives (post-migration)
- **Status**: `ready`
- **Depends on**: `T-007`
- **Goal**: After migrating data from the old NAS, install the remaining 2x 4 TB drives and grow the MergerFS + SnapRAID pool to 12 TB usable (1 parity + 3 data).
- **Scope**:
  - Document the exact expansion procedure in `docs/runbook.md` (partition `LUKS-DATA2`/`LUKS-DATA3`, LUKS2 format with `/etc/keys/hdd.key`, `mkfs.ext4 -m 1 -L DATA2/DATA3`, `chattr +i` mountpoints, append `d2`/`d3` to `dataDisks` in `modules/storage.nix`, run `snapraid sync`, optionally `mergerfs.balance`).
  - Update `dataDisks` in `modules/storage.nix` when the drives are installed.
- **Manual steps**:
  - Copy data from old NAS to `younix`, physically install bays 3 & 4, and run the expansion.
- **Verification**:
  - Confirm bays 1–4 LEDs are all active white (`younix-leds`), `df -h /mnt/data` shows ~11 TB / 12 TB usable space, and `snapraid status` + scrub pass with 0 errors.

---

## Phase 3 — Self-Hosted Services

### T-015 — Immich photo & video management
- **Status**: `ready`
- **Depends on**: `T-006`, `T-007`, `T-012`, `T-013`
- **Goal**: Deploy Immich natively with originals on the HDD array and database/thumbnails on the NVMe for fast browsing.
- **Scope**:
  - Create `modules/services/immich.nix` enabling `services.immich`.
  - Configure `mediaLocation` on the HDD array (`/mnt/data/photos`), while keeping PostgreSQL and (optionally) `thumbs`/`encoded-video` fast storage on the NVMe.
  - Grant `immich` access to `/dev/dri` (`video`, `render`) for hardware video transcoding.
  - Add reverse proxy route in `modules/proxy.nix` (with large upload body limits for mobile video backups).
- **Verification**:
  - Upload photos/videos via web UI and Immich mobile app (both LAN and over Tailscale); verify thumbnails generate and originals land on `/mnt/data/photos`.

### T-016 — Paperless-ngx document management
- **Status**: `ready`
- **Depends on**: `T-006`, `T-007`, `T-011`, `T-012`
- **Goal**: Deploy Paperless-ngx natively with OCR, HDD document storage, and a Samba-accessible `consume` inbox folder.
- **Scope**:
  - Create `modules/services/paperless.nix` enabling `services.paperless` with `mediaDir` on `/mnt/data/documents`, `consumptionDir` wired to the Samba inbox share, and admin password via `sops-nix`.
  - Configure OCR languages (e.g. `eng+deu` — confirm preferred languages).
  - Enable `database.createLocally = true` (PostgreSQL on NVMe).
  - Add reverse proxy route in `modules/proxy.nix`.
- **Verification**:
  - Drop a test PDF into the Samba inbox from macOS; confirm Paperless ingests, OCRs, indexes, and stores it under `/mnt/data/documents`.

---

## Phase 4 — Backups, Observability & CI

### T-017 — Local database dumps & versioned snapshots
- **Status**: `ready`
- **Depends on**: `T-007`
- **Goal**: Protect against accidental deletion or bad app updates with automated consistent DB dumps (scheduled ahead of nightly `snapraid sync`) and optional local versioned backups.
- **Scope**:
  - Configure `services.postgresqlBackup` (dumping Immich & Paperless databases nightly—e.g., `03:00`, before the `04:00` SnapRAID sync—to `/mnt/data/backups/postgres`).
  - Optionally configure a local versioned backup (e.g., local `restic` repo or `rsync --link-dest`) for `photos` and `documents` if fast local point-in-time recovery beyond SnapRAID + offsite `restic` (`T-018`) is desired.
- **Verification**:
  - Run backup timers manually; verify SQL dumps exist under `/mnt/data/backups/postgres` and are non-empty.

### T-018 — Automated offsite backups (`restic`)
- **Status**: `needs-decision`
- **Depends on**: `T-006`, `T-007`, `T-017`
- **Open decision**: Choose an offsite storage target (e.g., Hetzner Storage Box, Backblaze B2, Cloudflare R2, or a remote friend/family machine).
- **Scope**:
  - Create `modules/backups.nix` using `services.restic.backups` with repository password & credentials stored via `sops-nix`.
  - Back up irreplaceable data (`/mnt/data/photos`, `/mnt/data/documents`, `/mnt/data/backups/postgres`, `/var/lib/paperless`, `/var/lib/jellyfin/data`, `/var/lib/jellyfin/config`), explicitly excluding bulk `/mnt/data/media`.
  - Configure retention (`pruneOpts`) and periodic `checkOpts` to verify backup integrity.
- **Verification**:
  - Trigger a backup run, inspect `restic snapshots`, and perform a test restore of one file to `/tmp`.

### T-019 — System health & failure notifications
- **Status**: `needs-decision`
- **Depends on**: `T-006`
- **Open decision**: Choose notification channel (e.g., `ntfy.sh`, Pushover, Telegram bot, Discord webhook, or SMTP email).
- **Scope**:
  - Create `modules/alerts.nix` with a reusable systemd `OnFailure=` notification unit.
  - Wire alerts to: `smartd` warnings, scrub failures, `restic` backup failures, and `comin` deployment failures.
- **Verification**:
  - Trigger a test notification and confirm delivery on phone/Mac.

### T-020 — GitHub Actions CI for NixOS config validation
- **Status**: `ready`
- **Depends on**: none
- **Goal**: Catch Nix syntax/evaluation/build errors in CI before `comin` pulls broken commits.
- **Scope**:
  - Add `.github/workflows/check.yml` running `nix flake check` and `nix build .#nixosConfigurations.younix.config.system.build.toplevel --no-link` on pushes and PRs.
- **Verification**:
  - Push workflow and verify green run in GitHub Actions.

---

## Completed

### T-001 — Bootstrap instructions & key commands in README
- **Status**: `done`
- **Artifacts**: `README.md`
- **Summary**: Documented USB creation, BIOS watchdog disable, 1 TB NVMe partitioning (preserving factory 128 GB UGOS SSD), `nixos-install` from GitHub flake, and daily `comin` commands.

### T-002 — Pull-based GitOps with `comin`
- **Status**: `done`
- **Artifacts**: `modules/gitops.nix`
- **Summary**: Enabled `services.comin` polling `https://github.com/stravag/younix.git` (`main` branch, with `testing-younix` support for safe test deployments).

### T-003 — Thermal & fan control
- **Status**: `done`
- **Artifacts**: `modules/thermals.nix`
- **Summary**: Built out-of-tree `it87` driver (IT8613E) for read-only `sensors` visibility, enabled `thermald` and `powersave` governor, and left fan speed control to the motherboard's native BIOS Smart Fan controller (removed the custom `younix-fancontrol` daemon and `drivetemp` polling).

### T-004 — UGREEN front-panel LED controller
- **Status**: `done`
- **Artifacts**: `modules/leds.nix`
- **Summary**: Built out-of-tree `led-ugreen` kernel module (I2C @ `0x3a`) and `younix-leds` daemon controlling power, LAN (`netdev`), and bay 1–4 disk LEDs (activity blinking + standby-safe SMART fault indicator).

### T-005 — Sync `README.md` with current repo state
- **Status**: `done`
- **Artifacts**: `README.md`, `docs/bootstrap.md`, `docs/runbook.md`
- **Summary**: Updated layout with `thermals.nix`, `leds.nix`, `storage.nix`, and `TASKS.md`, corrected `comin` polling interval to 1 hour, and split documentation into a concise `README.md`, one-time `docs/bootstrap.md`, and day-to-day/recovery `docs/runbook.md`.

### T-006 — Secrets management with `sops-nix`
- **Status**: `done`
- **Artifacts**: `.sops.yaml`, `flake.nix`, `flake.lock`, `modules/secrets.nix`, `secrets/secrets.yaml`, `docs/bootstrap.md`, `docs/runbook.md`, `README.md`
- **Summary**: Enabled `sops-nix` using a dedicated host `age` key at `/etc/keys/sops.key` (backed up alongside `/etc/keys/hdd.key`) plus a macOS admin `age` key (`~/Library/Application Support/sops/age/keys.txt`). Verified end-to-end encryption on macOS and tmpfs decryption to `/run/secrets/test_secret` on `younix`.

### T-007 — HDD storage array setup (initial 2x 4 TB, single-disk expandable)
- **Status**: `done`
- **Artifacts**: `modules/storage.nix`, `flake.nix`, `docs/bootstrap.md`, `docs/runbook.md`
- **Summary**: Deployed **LUKS2 + MergerFS + SnapRAID** (`LUKS-PARITY1`/`PARITY1` at `/mnt/parity1` + `LUKS-DATA1`/`DATA1` at `/mnt/disk1`, unattended Stage 2 unlock via `/etc/crypttab` + `/etc/keys/hdd.key`, MergerFS pool at `/mnt/data`, nightly `snapraid sync` with mount + >100-deletion `snapraid-precheck` guard, and weekly `snapraid scrub`). Verified across reboot.

### T-008 — Disk health monitoring (`smartd`) & HDD power/acoustics
- **Status**: `done`
- **Artifacts**: `modules/storage.nix`, `modules/thermals.nix`, `docs/runbook.md`, `README.md`
- **Summary**: Enabled `services.smartd` (`DEVICESCAN` covering both SATA HDDs and NVMe SSDs, `-n standby,q`, weekly Short self-tests Sat `04:xx`, monthly Long self-tests 1st `04:xx` aligned with the `04:00` SnapRAID window), deployed `hd-idle` (`1800s` ATA spindown scoped dynamically to `allDisks` via `PARTLABEL`), and hardened `younix-fancontrol` (`hdparm -C` standby check + 30 s HDD poll interval + per-sensor `OSError` handling) so `drivetemp` never wakes sleeping HDDs. Verified all 4 services (`smartd`, `hd-idle`, `younix-fancontrol`, `younix-leds`) and confirmed `/dev/sda` remains in standby across poll cycles with zero log errors.

### T-011 — Local file sharing via Samba (macOS-friendly)
- **Status**: `done`
- **Artifacts**: `modules/samba.nix`, `modules/secrets.nix`, `hosts/younix/configuration.nix`, `flake.nix`, `secrets/secrets.yaml`, `docs/runbook.md`, `README.md`
- **Summary**: Enabled authenticated SMB3-only `services.samba` (macOS `vfs_fruit` + `streams_xattr`, `dos filetimes = yes`, `nmbd` disabled), `services.samba-wsdd`, and Avahi `_smb._tcp` Bonjour discovery. Configured declarative `sambaUsers` & `sharedFolders` (`media`, `photos`, group-scoped `2770`/`0660`, ready for multi-user family access and per-user `personalShare` folders) with per-user `sops-nix` password sync (`samba_passwords/<user>` via `younix-samba-passwd.service`) and mount-safe directory provisioning (`younix-samba-dirs.service`). Verified live services and macOS Finder read/write access.

### T-010 — Remote access via Tailscale (zero port-forwarding)
- **Status**: `done`
- **Artifacts**: `modules/remote-access.nix`, `flake.nix`, `docs/runbook.md`, `README.md`
- **Summary**: Enabled `services.tailscale` (`openFirewall = true` for local WireGuard NAT traversal with zero router port-forwarding, `useRoutingFeatures = "none"`, `checkReversePath = "loose"`). Enrolled interactively with `--ssh=false --accept-routes=false --accept-dns=false` (no auth keys in git) and enforced strict per-port `tailscale0` firewall isolation via `younix-tailscale-in` (`iptables`/`ip6tables`), allowing only explicitly allowlisted `tailscale0` ports (`22` + `443`) + ping while keeping Samba/WSDD/Avahi LAN-only.

### T-012 — Reverse proxy & HTTPS with Caddy
- **Status**: `done`
- **Artifacts**: `modules/proxy.nix`, `flake.nix`, `secrets/secrets.yaml`, `docs/runbook.md`, `README.md`
- **Summary**: Deployed `services.caddy` built with `github.com/caddy-dns/desec@v1.1.0` and wildcard DNS-01 TLS (`propagation_delay 60s`, `propagation_timeout 5m`, `resolvers 1.1.1.1 9.9.9.9`) using a dedicated delegated subdomain (`NS` → deSEC) pointing to `younix`'s private Tailscale IP. Both domain and deSEC API token are encrypted in `secrets/secrets.yaml` via `sops.templates."caddy.env"`. Added declarative `younix.proxy.routes`, security headers, built-in `health` endpoint, `abort` for unknown subdomains, and `tailscale0`-only TCP `443` access. Verified valid Let's Encrypt wildcard HTTPS over Tailscale and LAN port `443` isolation.

### T-013 — Intel QuickSync hardware acceleration
- **Status**: `done`
- **Artifacts**: `modules/graphics.nix`, `hosts/younix/configuration.nix`, `flake.nix`, `docs/runbook.md`, `README.md`
- **Summary**: Enabled Intel Alder Lake iGPU (`/dev/dri/renderD128`, PCI `8086:46b3`) hardware acceleration via `hardware.graphics` with `intel-media-driver` (VA-API `iHD`), `vpl-gpu-rt` (oneVPL / QuickSync), `intel-compute-runtime` (OpenCL / Level Zero for HDR tone-mapping), `hardware.enableRedistributableFirmware = true`, `LIBVA_DRIVER_NAME = "iHD"`, and diagnostic tools (`libva-utils`, `intel-gpu-tools`, `clinfo`). Added `video` and `render` groups to `ranil`. Verified live on `younix`: `vainfo` reports Intel `iHD` driver 26.1.6 with H.264/HEVC/VP9/AV1 decode and H.264/HEVC/VP9 encode (`EncSlice`/`EncSliceLP`), `clinfo --list` exposes `Intel(R) OpenCL Graphics`, and `dmesg` confirms `i915` DMC, GuC submission/SLPC/RC, and HuC authentication active out of the box.

### T-014 — Jellyfin media server
- **Status**: `done`
- **Artifacts**: `modules/services/jellyfin.nix`, `flake.nix`, `docs/runbook.md`, `README.md`
- **Summary**: Deployed native `services.jellyfin` with declarative Intel Alder Lake QuickSync (QSV) hardware transcoding (`hardwareAcceleration.type = "qsv"`, `/dev/dri/renderD128`, `forceEncodingConfig = true`, low-power H.264/HEVC encoding, OpenCL HDR tone-mapping, transcode throttling, and Alder Lake decode/encode codecs). Kept DB/metadata/caches on the 1 TB NVMe (`/var/lib/jellyfin`, `/var/cache/jellyfin`), granted `jellyfin` `video`, `render`, and `media` group memberships with boot ordering after `mnt-data.mount` and `younix-samba-dirs.service`, kept port `8096` closed in the firewall, and exposed HTTPS via Caddy (`younix.proxy.routes.jellyfin` over `tailscale0`). Verified live playback, library access, and active Intel GPU transcoding in `intel_gpu_top`.
