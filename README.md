# younix

GitOps-managed NixOS configuration for a **UGREEN NASync DXP4800 Plus**.

## Guides

- **[Bootstrap Guide](docs/bootstrap.md)** — One-time setup from scratch: installing NixOS onto the 1 TB NVMe SSD (leaving the factory 128 GB UGOS SSD untouched) and initializing the LUKS2 + MergerFS + SnapRAID HDD array.
- **[Operations & Recovery Runbook](docs/runbook.md)** — Day-to-day GitOps workflow, storage administration, LUKS keyfile recovery, and step-by-step drive failure & replacement procedures.
- **[Roadmap & Tasklist](TASKS.md)** — Implementation roadmap and task tracking.

## Layout

- `flake.nix` — Flake inputs (`nixpkgs`, `nixpkgs-unstable`, `comin`, `sops-nix`) and host definitions.
- `.github/workflows/check.yml` — GitHub Actions CI running `nix flake check` on pushes/PRs (ignoring docs-only changes) and full `younix` NixOS toplevel builds on PRs and manual runs.
- `.github/dependabot.yml` — Weekly grouped Dependabot PRs for `flake.lock` inputs (`nix`) and `github-actions`.
- `.sops.yaml` — `sops` encryption rules & public `age` recipients (macOS admin + `younix`).
- `hosts/younix/configuration.nix` — Host-specific system configuration.
- `hosts/younix/hardware-configuration.nix` — Hardware & root filesystem definitions generated on the NAS.
- `modules/gitops.nix` — Pull-based GitOps deployment with `comin` (polls `main` every 60s; supports `testing-younix`).
- `modules/secrets.nix` — Encrypted declarative secrets via `sops-nix` (decrypted via `/etc/keys/sops.key` into `/run/secrets/`).
- `modules/thermals.nix` — Out-of-tree `it87` driver (`IT8613E`), one-shot `udev` hardware Smart Fan tuning (zero fan daemon), `thermald`, and `powersave` CPU governor.
- `modules/power.nix` — Idle power tuning: PCIe ASPM (`powersave` policy, ready for BIOS Native ASPM), PCI/USB runtime PM, Intel HWP `balance_power` EPP, and `ethtool`.
- `modules/leds.nix` — Out-of-tree `led-ugreen` kernel module and `younix-leds` front-panel LED controller (active white + I/O blink, dim blue on HDD standby via `hdparm -C`, red on SMART/offline fault, amber power LED on unmounted/degraded array).
- `modules/graphics.nix` — Intel Alder Lake QuickSync hardware acceleration (`intel-media-driver` VA-API, `vpl-gpu-rt` oneVPL, `intel-compute-runtime` OpenCL) and GPU diagnostics (`vainfo`, `intel_gpu_top`, `clinfo`).
- `modules/storage.nix` — LUKS2-encrypted `ext4` HDDs (`/etc/crypttab`), MergerFS pool at `/mnt/data`, scheduled SnapRAID sync/scrub, `smartd` health monitoring, and `hd-idle` 30-min HDD spindown.
- `modules/backups.nix` — Nightly consistent `zstd` PostgreSQL dumps (`03:00` to NVMe + mirrored to `/mnt/data/backups/postgres`), online SQLite snapshots for Jellyfin, and encrypted Backblaze B2 (EU Central) offsite `restic` backups (`03:15`, `restic-offsite`, credentials via `sops-nix`).
- `modules/alerts.nix` — Push failure alerts via `ntfy.sh` (`younix-notify` CLI, reusable `younix-notify@.service` `OnFailure=` unit for SnapRAID/PostgreSQL/restic/comin/smartd, `smartd` S.M.A.R.T. warning exec hook, and `comin` build/deployment failure hooks; topic URL & optional token via `sops-nix`).
- `modules/samba.nix` — macOS-friendly SMB3 file sharing (`vfs_fruit`, Avahi Bonjour + WSDD discovery, declarative password via `sops-nix`).
- `modules/remote-access.nix` — Zero-port-forward Tailscale remote access with strict per-port `tailscale0` firewall isolation.
- `modules/proxy.nix` — Caddy HTTPS reverse proxy with automatic wildcard DNS-01 TLS via deSEC (domain & token encrypted in `sops-nix`, port 443 served on LAN + `tailscale0` with split-horizon DNS).
- `modules/services/jellyfin.nix` — Native Jellyfin media server with Intel QuickSync (QSV) hardware transcoding, NVMe metadata/cache (`/var/lib/jellyfin`, `/var/cache/jellyfin`), `/mnt/data/media` library access, and Caddy HTTPS route (`jellyfin.<domain>`).
- `modules/services/immich.nix` — Native Immich photo & video server with Intel QuickSync (QSV) transcoding, hybrid HDD/NVMe storage (`/mnt/data/photos` read-only External Library + `/mnt/data/immich` uploads on HDD + `/var/lib/immich/{thumbs,encoded-video}`, PostgreSQL, Redis, and ML on NVMe), and Caddy HTTPS route (`photos.<domain>`).
- `modules/services/beszel.nix` — Lightweight Beszel Hub + Agent dashboard for system metrics (CPU, RAM/zram, temps, NVMe + `/mnt/data` usage, Intel QuickSync GPU via `intel_gpu_top`), standby-safe S.M.A.R.T. drive health (`smartctl -n standby`), systemd service status & per-service `journald` logs, and passwordless LAN + Tailscale Caddy HTTPS route (`status.<domain>`).
- `modules/services/filebrowser.nix` — Lightweight FileBrowser Quantum v2 web file manager (from `nixpkgs-unstable`) exposing `/mnt/data/{share,media,photos}` with Samba-compatible group permissions (`UMask = 0007`), NVMe DB/cache (`/var/lib/filebrowser-quantum`, `/var/cache/filebrowser-quantum`), standby-safe unindexed sources (never wakes sleeping HDDs), and passwordless LAN + Tailscale Caddy HTTPS route (`files.<domain>`, ready for Pocket-ID OIDC).
- `secrets/secrets.yaml` — `age`-encrypted secrets file managed via `sops`.
- `docs/bootstrap.md` — One-time OS, storage, and keyfile bootstrap instructions.
- `docs/runbook.md` — Day-to-day operations, secrets management, and drive/keyfile recovery runbook.
- `TASKS.md` — Single-source project roadmap.
- `AGENTS.md` — Guidelines and boundaries for AI coding agents working on this repo.

## Quick Reference

```bash
# Connect from macOS
ssh ranil@younix.local

# Edit encrypted secrets (from macOS)
sops secrets/secrets.yaml

# Check or trigger GitOps deployment immediately
comin status
sudo comin fetch

# Quick storage check
findmnt -R /mnt
df -h /mnt/parity1 /mnt/disk1 /mnt/disk2 /mnt/disk3 /mnt/data
sudo snapraid status

# Remote access status (Tailscale)
tailscale status
tailscale ip -4

# Backups (PostgreSQL dumps & offsite restic)
systemctl list-timers 'postgresqlBackup*' 'restic-backups-*'
sudo restic-offsite snapshots
```

For risky changes, push to the `testing-younix` branch first (`comin` activates temporarily via `test`, so a reboot reverts to `main`). See the [Operations & Recovery Runbook](docs/runbook.md) for full details.
