# Bootstrap Guide (One-Time Setup)

One-time instructions for setting up `younix` (UGREEN NASync DXP4800 Plus) from scratch:
1. **Part 1:** Installing NixOS onto the **1 TB M.2 NVMe SSD** (leaving the factory **128 GB UGOS Pro SSD** untouched).
2. **Part 2:** Initializing the **LUKS2 + MergerFS + SnapRAID** HDD storage array (starting with 2× 4 TB SATA drives).
3. **Part 3:** Provisioning `/etc/keys/sops.key` for **`sops-nix`** encrypted secrets.

For day-to-day administration and drive replacement procedures, see the [Operations & Recovery Runbook](runbook.md).

---

## Part 1 — Install NixOS on the 1 TB NVMe SSD

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
- **~3.6T / 4T SATA** → data HDDs (left untouched during OS bootstrap)

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

---

## Part 2 — Initialize the HDD Storage Array (LUKS2 + MergerFS + SnapRAID)

Bulk HDD storage uses standalone **LUKS2-encrypted `ext4`** drives unlocked automatically at boot by a keyfile on the 1 TB NVMe (`/etc/keys/hdd.key`), pooled at `/mnt/data` via **MergerFS**, and protected by nightly **SnapRAID** parity sync + weekly scrubs (`modules/storage.nix`).

- **Initial layout (2× 4 TB):** 1 parity drive (`LUKS-PARITY1` → `/mnt/parity1`) + 1 data drive (`LUKS-DATA1` → `/mnt/disk1`), pooled at `/mnt/data` (4 TB usable).
- **Future expansion (`T-009`):** Add `LUKS-DATA2` (`/mnt/disk2`) and `LUKS-DATA3` (`/mnt/disk3`) for 12 TB usable (75% efficiency).

### 1. Generate and back up the HDD encryption keyfile

SSH into `younix` and generate the keyfile (never commit it to Git):

```bash
sudo install -d -m 0700 /etc/keys
sudo dd if=/dev/urandom of=/etc/keys/hdd.key bs=4096 count=1 status=none
sudo chmod 0400 /etc/keys/hdd.key
```

> **Important:** Back up `/etc/keys/hdd.key` immediately (e.g., store the base64 output in your password manager). If the 1 TB NVMe SSD ever fails, you will need this keyfile to unlock your HDDs:
>
> ```bash
> sudo base64 -w 0 /etc/keys/hdd.key; echo
> ```

### 2. Identify the two 4 TB SATA drives

Inspect all disks and verify you **only** touch the two 4 TB SATA HDDs (never the 128 GB UGOS NVMe or 1 TB NixOS NVMe):

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINT
ls -l /dev/disk/by-id/ata-*
```

### 3. Partition, encrypt (LUKS2), and format `PARITY1` & `DATA1`

> **Tip:** If `cryptsetup` is not yet installed before deploying `modules/storage.nix`, run `nix shell nixpkgs#cryptsetup` first (or deploy `modules/storage.nix` on `testing-younix` first—all mounts use `nofail`).

Set `PARITY_DISK` and `DATA_DISK` to the two verified `/dev/disk/by-id/ata-...` whole-disk symlinks (without `-partN`):

```bash
PARITY_DISK=/dev/disk/by-id/ata-<MODEL_SERIAL_PARITY>
DATA_DISK=/dev/disk/by-id/ata-<MODEL_SERIAL_DATA>

# Create a single GPT Linux partition with a stable PARTLABEL on each drive
printf 'label: gpt\ntype=linux, name="LUKS-PARITY1"\n' | sudo sfdisk "$PARITY_DISK"
printf 'label: gpt\ntype=linux, name="LUKS-DATA1"\n' | sudo sfdisk "$DATA_DISK"
sudo udevadm settle

# Verify the PARTLABEL symlinks exist
ls -l /dev/disk/by-partlabel/LUKS-*

# Encrypt both partitions with LUKS2 using the keyfile
sudo cryptsetup luksFormat --type luks2 --batch-mode --key-file /etc/keys/hdd.key /dev/disk/by-partlabel/LUKS-PARITY1
sudo cryptsetup luksFormat --type luks2 --batch-mode --key-file /etc/keys/hdd.key /dev/disk/by-partlabel/LUKS-DATA1

# Open temporarily to format the inner ext4 filesystems
sudo cryptsetup open --key-file /etc/keys/hdd.key /dev/disk/by-partlabel/LUKS-PARITY1 crypt_parity1
sudo cryptsetup open --key-file /etc/keys/hdd.key /dev/disk/by-partlabel/LUKS-DATA1 crypt_data1

# Parity: 0% reserved blocks + fewer inodes (-T largefile4) so snapraid.parity
# always has slightly more space than any same-size data drive
sudo mkfs.ext4 -m 0 -T largefile4 -L PARITY1 /dev/mapper/crypt_parity1

# Data: 1% reserved buffer keeps data usage safely below parity capacity
sudo mkfs.ext4 -m 1 -L DATA1 /dev/mapper/crypt_data1

# Close mappers so systemd-cryptsetup unlocks them cleanly on deploy/boot
sudo cryptsetup close crypt_parity1 crypt_data1
```

### 4. Lock empty mountpoints with `chattr +i`

Marking the empty mountpoint directories immutable guarantees that if a drive ever fails to unlock/mount (`nofail`), nothing can silently write data onto the 1 TB NVMe root:

```bash
sudo mkdir -p /mnt/parity1 /mnt/disk1 /mnt/data
sudo chattr +i /mnt/parity1 /mnt/disk1 /mnt/data
```

### 5. Deploy, verify unlock/mounts, and initialize SnapRAID

Push your changes to `testing-younix` first (safe test activation), then run on `younix`:

```bash
sudo comin fetch

# Trigger unlock + mounts on live test activation (reboot handles this automatically)
sudo systemctl daemon-reload
sudo systemctl start systemd-cryptsetup@crypt_parity1 systemd-cryptsetup@crypt_data1
sudo systemctl start mnt-parity1.mount mnt-disk1.mount mnt-data.mount

# Verify everything is unlocked and mounted
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT
findmnt -R /mnt
df -h /mnt/parity1 /mnt/disk1 /mnt/data
```

Create the top-level bulk-data directories on the MergerFS pool and run the initial SnapRAID sync:

```bash
sudo mkdir -p /mnt/data/{photos,documents,media,backups,share}
sudo snapraid sync
sudo snapraid status

# Verify the automated precheck + sync service works end-to-end
sudo systemctl start snapraid-sync
journalctl -u snapraid-precheck -u snapraid-sync -n 30
```

Once everything checks out, merge `testing-younix` into `main`, run `sudo comin fetch`, and `sudo reboot` once to verify unattended LUKS unlock and mounting on boot.

---

## Part 3 — Provision `sops-nix` Decryption Key (`/etc/keys/sops.key`)

Encrypted secrets in `secrets/secrets.yaml` are decrypted at boot/activation using a dedicated `age` private key stored at `/etc/keys/sops.key` alongside `/etc/keys/hdd.key`.

- **Reinstalling on a replacement NVMe SSD?** Restore your backed-up `/etc/keys/sops.key` from your password manager—see [Keyfile Recovery](runbook.md#4-keyfile-recovery-if-the-1-tb-nvme-is-reinstalled) (no Git changes needed).
- **Bootstrapping brand-new keys from scratch:**
  1. On macOS, install `sops` and `age` (`brew install sops age`) and generate an admin key at `~/Library/Application Support/sops/age/keys.txt` (`age-keygen -o "$HOME/Library/Application Support/sops/age/keys.txt"`). Back it up in your password manager.
  2. On `younix`, generate the host key and back it up in your password manager:
     ```bash
     sudo install -d -m 0700 /etc/keys
     sudo install -m 0600 /dev/null /etc/keys/sops.key
     nix shell nixpkgs#age -c sh -c 'age-keygen | sudo tee /etc/keys/sops.key > /dev/null'
     sudo chmod 0400 /etc/keys/sops.key
     sudo cat /etc/keys/sops.key   # copy into password manager
     ```
  3. Put both public `age1...` keys in `.sops.yaml` and run `sops updatekeys secrets/secrets.yaml` on macOS.
