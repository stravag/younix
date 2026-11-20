# younix

GitOps-managed NixOS configuration for a UGREEN NASync DXP4800 Plus.

## Layout

- `flake.nix` — Flake inputs (`nixpkgs`, `comin`) and host definitions.
- `hosts/younix/configuration.nix` — Host-specific system configuration.
- `hosts/younix/hardware-configuration.nix` — Hardware & filesystem definitions generated on the NAS.
- `modules/gitops.nix` — Pull-based GitOps deployment with `comin`.

## Day-to-day workflow

1. Edit the Nix files locally, commit, and `git push` to `main`.
2. Within ~60 seconds, `comin` on `younix` pulls the new commit, builds the system, and switches to it.
3. For risky changes (networking, SSH, bootloader), push to branch `testing-younix` instead—`comin` activates it temporarily (`test`), so a reboot reverts to `main`.

## Useful commands on the NAS

```bash
# Connect from macOS
ssh ranil@younix.local

# Check GitOps status
comin status

# Watch deployment logs
journalctl -u comin -f

# Trigger an immediate fetch/deploy without waiting for the poll interval
sudo comin fetch
```
