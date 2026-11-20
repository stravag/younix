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
comin fetch
```

---

## Bootstrapping the NAS from scratch

This installs NixOS onto the user-installed **1 TB M.2 NVMe SSD** while leaving the factory **128 GB internal UGOS Pro SSD** (and any HDDs) untouched.

### 1. Create a bootable NixOS USB drive (on macOS)

1. Download the **NixOS Minimal ISO (`x86_64-linux`)** from https://nixos.org/download/.
2. Flash it to a USB drive using either:
   - **GUI (easiest):** [BalenaEtcher](https://etcher.balena.io/) — select the ISO, pick the USB drive, and click Flash.
   - **CLI (macOS Terminal):**
     ```bash
     # Identify the USB drive (e.g. /dev/disk4 — double-check it is NOT your Mac's internal disk!)
     diskutil list external

     # Unmount the USB drive (replace X with your USB disk number)
     diskutil unmountDisk /dev/diskX

     # Write the ISO to the raw disk device (rdiskX is much faster than diskX)
     sudo dd if=~/Downloads/nixos-minimal-*.iso of=/dev/rdiskX bs=4m status=progress

     # Safely eject
     diskutil eject /dev/diskX
     ```

### 2. Disable the BIOS watchdog & boot from USB

1. Connect an **HDMI monitor**, **USB keyboard**, **Ethernet cable**, and the **NixOS USB drive** to the DXP4800 Plus.
2. Power on the NAS and repeatedly tap **`Ctrl + F2`** to enter BIOS.
3. **Disable the hardware watchdog** (under **Advanced → Watchdog Settings / Watchdog Control → Disabled**).
   > **Important:** If left enabled, the motherboard will hard-reboot the NAS every ~3 minutes when UGOS is not running.
4. Press **`F10`** to save and exit.
5. On reboot, repeatedly tap **`Ctrl + F12`** to open the boot menu and choose the **UEFI** entry for your NixOS USB drive.

### 3. Switch to SSH from your Mac

Once the NixOS live installer reaches the `nixos@nixos` prompt, run on the NAS keyboard:

```bash
passwd       # set a temporary password for the live `nixos` user
ip -br a     # note the NAS LAN IP address (e.g. 192.168.x.x)
```

Then connect from your Mac terminal for the rest of the install:

```bash
ssh nixos@<NAS-IP>
sudo -i
```

### 4. Partition and mount the 1 TB SSD

First, inspect all attached drives so you are **100% sure you only touch the 1 TB SSD**:

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE
```

- **~119G / 128G NVMe** → factory UGOS Pro drive (**do not touch**)
- **~931G / 1T NVMe** → target NixOS boot drive
- **~3.6T / 4T SATA** → data HDDs (left untouched during bootstrap)

Set `DISK` to the 1 TB NVMe device (e.g., `/dev/nvme1n1`), then partition, format, and mount it:

```bash
DISK=/dev/nvmeXn1   # <-- replace with your verified 1 TB NVMe device!

# Create GPT partition table: 512 MiB EFI System Partition + ext4 root
parted -s "$DISK" -- mklabel gpt
parted -s "$DISK" -- mkpart ESP fat32 1MiB 513MiB
parted -s "$DISK" -- set 1 esp on
parted -s "$DISK" -- mkpart root ext4 513MiB 100%

# Format partitions (NVMe partitions use p1/p2)
mkfs.fat -F 32 -n NIXOS-BOOT "${DISK}p1"
mkfs.ext4 -L NIXOS-ROOT "${DISK}p2"

# Mount root and EFI partitions
mount /dev/disk/by-label/NIXOS-ROOT /mnt
mkdir -p /mnt/boot
mount -o umask=077 /dev/disk/by-label/NIXOS-BOOT /mnt/boot
```

### 5. Generate & commit `hardware-configuration.nix`

On the NAS (`root` shell), generate the hardware config for the mounted system:

```bash
nixos-generate-config --root /mnt
```

In a terminal **on your Mac** (inside this repo), copy the generated file into the repo, commit, and push:

```bash
scp nixos@<NAS-IP>:/mnt/etc/nixos/hardware-configuration.nix hosts/younix/hardware-configuration.nix
git add hosts/younix/hardware-configuration.nix
git commit -m "Add generated hardware-configuration.nix for younix"
git push
```

### 6. Install NixOS from the GitHub flake

Back in the NAS `root` shell:

```bash
nixos-install --flake github:stravag/younix#younix
```

- When prompted at the end, set a local `root` password (kept off Git; only used as an emergency HDMI console fallback since root SSH is disabled).
- Unplug the USB drive and reboot:

```bash
reboot
```

### 7. Verify first boot & GitOps

- If the NAS boots back into UGOS instead of NixOS, press **`Ctrl + F2`** on startup and move **Linux Boot Manager** (your 1 TB SSD) ahead of the internal 128 GB SSD in the UEFI boot priority. (You can always boot UGOS again later via `Ctrl + F12`.)
- From your Mac, verify SSH and `comin`:

```bash
ssh ranil@younix.local
comin status
```

From this point on, any commit pushed to `main` on GitHub will be pulled and applied automatically by `comin`.
