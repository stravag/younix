# younix

GitOps-managed NixOS configuration for a **UGREEN NASync DXP4800 Plus**.

## Guides

- **[Bootstrap Guide](docs/bootstrap.md)** — One-time setup from scratch: installing NixOS onto the 1 TB NVMe SSD (leaving the factory 128 GB UGOS SSD untouched) and initializing the LUKS2 + MergerFS + SnapRAID HDD array.
- **[Operations & Recovery Runbook](docs/runbook.md)** — Day-to-day GitOps workflow, storage administration, LUKS keyfile recovery, and step-by-step drive failure & replacement procedures.
- **[Roadmap & Tasklist](TASKS.md)** — Implementation roadmap and task tracking.

## Layout

- `flake.nix` — Flake inputs (`nixpkgs`, `comin`, `sops-nix`) and host definitions.
- `.sops.yaml` — `sops` encryption rules & public `age` recipients (macOS admin + `younix`).
- `hosts/younix/configuration.nix` — Host-specific system configuration.
- `hosts/younix/hardware-configuration.nix` — Hardware & root filesystem definitions generated on the NAS.
- `modules/gitops.nix` — Pull-based GitOps deployment with `comin` (polls `main` every 1 hour; supports `testing-younix`).
- `modules/secrets.nix` — Encrypted declarative secrets via `sops-nix` (decrypted via `/etc/keys/sops.key` into `/run/secrets/`).
- `modules/thermals.nix` — Out-of-tree `it87` driver (`IT8613E`), `drivetemp`, `thermald`, and standby-safe quiet `younix-fancontrol` daemon.
- `modules/leds.nix` — Out-of-tree `led-ugreen` kernel module and `younix-leds` front-panel LED controller.
- `modules/graphics.nix` — Intel Alder Lake QuickSync hardware acceleration (`intel-media-driver` VA-API, `vpl-gpu-rt` oneVPL, `intel-compute-runtime` OpenCL) and GPU diagnostics (`vainfo`, `intel_gpu_top`, `clinfo`).
- `modules/storage.nix` — LUKS2-encrypted `ext4` HDDs (`/etc/crypttab`), MergerFS pool at `/mnt/data`, scheduled SnapRAID sync/scrub, `smartd` health monitoring, and `hd-idle` 30-min HDD spindown.
- `modules/samba.nix` — macOS-friendly SMB3 file sharing (`vfs_fruit`, Avahi Bonjour + WSDD discovery, declarative password via `sops-nix`).
- `modules/remote-access.nix` — Zero-port-forward Tailscale remote access with strict per-port `tailscale0` firewall isolation.
- `modules/proxy.nix` — Caddy HTTPS reverse proxy with automatic wildcard DNS-01 TLS via deSEC (domain & token encrypted in `sops-nix`, port 443 restricted to `tailscale0`).
- `modules/services/jellyfin.nix` — Native Jellyfin media server with Intel QuickSync (QSV) hardware transcoding, NVMe metadata/cache (`/var/lib/jellyfin`, `/var/cache/jellyfin`), `/mnt/data/media` library access, and Caddy HTTPS route (`jellyfin.<domain>`).
- `secrets/secrets.yaml` — `age`-encrypted secrets file managed via `sops`.
- `docs/bootstrap.md` — One-time OS, storage, and keyfile bootstrap instructions.
- `docs/runbook.md` — Day-to-day operations, secrets management, and drive/keyfile recovery runbook.
- `TASKS.md` — Single-source project roadmap.

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
df -h /mnt/parity1 /mnt/disk1 /mnt/data
sudo snapraid status

# Remote access status (Tailscale)
tailscale status
tailscale ip -4
```

For risky changes, push to the `testing-younix` branch first (`comin` activates temporarily via `test`, so a reboot reverts to `main`). See the [Operations & Recovery Runbook](docs/runbook.md) for full details.
