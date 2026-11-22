# Agent Guidelines for `younix`

- **Never execute commands directly on `younix`**: Do not run `ssh`, `scp`, `rsync`, or any other remote command targeting `younix` (e.g., `younix.local` or its Tailscale IP/hostname). Instead, provide the exact commands for the user to run on `younix` themselves (e.g., `sudo comin fetch`, `comin status`, verification commands) and ask them to share the output if needed.
- **Public repository**: `github:stravag/younix` is public. **Never** commit plaintext passwords, API keys, auth keys, personal domains, or private keys — use `sops-nix` (`secrets/secrets.yaml`).
- **Module conventions**: Put each feature in its own `modules/<feature>.nix` (or `modules/services/<service>.nix`) file and register it in `flake.nix`. Keep host-specific settings in `hosts/younix/configuration.nix`.
- **Safe rollouts**: For risky changes (storage mounts, networking, firewall, SSH, bootloader), test on the `testing-younix` branch first (`comin` activates temporarily via `test`, so a reboot reverts to `main`).
- **Task tracking**: Follow `TASKS.md` for task statuses, verification checklists, and documentation updates (`README.md`, `docs/runbook.md`).
