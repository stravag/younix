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
- `modules/thermals.nix` — Out-of-tree `it87` driver (`IT8613E`), `drivetemp`, `thermald`, and quiet `younix-fancontrol` daemon.
- `modules/leds.nix` — Out-of-tree `led-ugreen` kernel module and `younix-leds` front-panel LED controller.
- `modules/storage.nix` — LUKS2-encrypted `ext4` HDDs (`/etc/crypttab`), MergerFS pool at `/mnt/data`, and scheduled SnapRAID parity sync (with precheck guard) & weekly scrub.
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
```

For risky changes, push to the `testing-younix` branch first (`comin` activates temporarily via `test`, so a reboot reverts to `main`). See the [Operations & Recovery Runbook](docs/runbook.md) for full details.
