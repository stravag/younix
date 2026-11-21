# Operations & Recovery Runbook

Day-to-day administration, storage maintenance, and failure recovery procedures for `younix`.
For initial one-time OS and disk setup, see the [Bootstrap Guide](bootstrap.md).

---

## 1. Day-to-Day GitOps Workflow (`comin`)

1. Edit Nix files locally on your Mac, commit, and `git push` to `main`.
2. `comin` on `younix` polls `origin/main` every **1 hour** (`3600s` in `modules/gitops.nix`), builds the new system, and switches to it automatically.
3. For risky changes (storage, networking, firewall, SSH, bootloader), push to branch **`testing-younix`** instead—`comin` activates it temporarily (`test` mode), so a reboot automatically reverts to `main`.

```bash
# Connect from macOS
ssh ranil@younix.local

# Check GitOps deployment status
comin status

# Trigger an immediate fetch & deploy without waiting for the 1h poll
sudo comin fetch

# Follow deployment logs
journalctl -u comin -f
```

---

## 2. Storage Operations (LUKS2 + MergerFS + SnapRAID)

### Health & Status Cheatsheet

```bash
# Inspect LUKS mappers, filesystems, and mounts
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT
findmnt -R /mnt
df -h /mnt/parity1 /mnt/disk1 /mnt/data

# Inspect SnapRAID parity status & pending changes
sudo snapraid status
sudo snapraid diff

# Check scheduled nightly sync (04:00) and weekly scrub (Sun 05:30) logs
journalctl -u snapraid-precheck -u snapraid-sync -u snapraid-scrub -n 50
systemctl list-timers 'snapraid*'
```

### When Automated Sync Aborts (`snapraid-precheck` Delete Threshold)

`snapraid-precheck.service` automatically aborts nightly `snapraid sync` if **more than 100 files** were deleted since the last sync, protecting your parity against accidental `rm -rf` or app bugs.

1. Inspect what changed:
   ```bash
   sudo snapraid diff
   ```
2. **If the deletions were accidental:** Jump to [Scenario 3: Recovering Accidentally Deleted Files](#scenario-3--recovering-accidentally-deleted-files-before-nightly-sync).
3. **If the deletions were intentional** (e.g., cleaning up old media): Run a manual sync once to commit them to parity:
   ```bash
   sudo snapraid sync
   ```
   Automated nightly syncs will resume normally afterward.

---

## 3. LUKS Keyfile Recovery (If the 1 TB NVMe Is Reinstalled)

The HDDs are encrypted with `/etc/keys/hdd.key` (backed up as base64 in your password manager during [bootstrap](bootstrap.md#1-generate-and-back-up-the-hdd-encryption-keyfile)). If you ever reinstall NixOS on a replacement NVMe SSD, restore the keyfile **before** unlocking/mounting the HDDs:

```bash
sudo install -d -m 0700 /etc/keys
echo '<BASE64_KEY_FROM_PASSWORD_MANAGER>' | base64 -d | sudo tee /etc/keys/hdd.key > /dev/null
sudo chmod 0400 /etc/keys/hdd.key

# Verify size is exactly 4096 bytes, then unlock & mount
sudo ls -l /etc/keys/hdd.key
sudo systemctl start systemd-cryptsetup@crypt_parity1 systemd-cryptsetup@crypt_data1
sudo systemctl start mnt-parity1.mount mnt-disk1.mount mnt-data.mount
```

---

## 4. Drive Failure & Recovery Runbook

### Step 0 — Identify the Failed Drive

```bash
# Check front-panel LEDs (a red bay LED = offline or SMART failure on that bay)
journalctl -u younix-leds -n 30

# Inspect attached disks, mappers, and mount points
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,LABEL,MOUNTPOINT
ls -l /dev/disk/by-partlabel/

# Check SMART health on SATA drives
for d in /dev/sd?; do echo "=== $d ==="; sudo smartctl -H "$d"; done

# Check kernel I/O errors
dmesg -T | grep -iE 'ata|sd[a-z]|ext4|i/o error' | tail -n 40
```

> **Before touching anything:** Pause the nightly SnapRAID sync timer during active recovery so parity is never overwritten while a drive is missing or empty:
> ```bash
> sudo systemctl stop snapraid-sync.timer
> ```

---

### Scenario 1 — Replacing a Failed Data Drive (`d1`, `d2`, or `d3`)

Because `modules/storage.nix` uses `PARTLABEL` (`LUKS-DATA1`, `LUKS-DATA2`, `LUKS-DATA3`), **no Git changes are needed** when replacing a failed drive with one of equal or larger size *(note: any data drive must remain ≤ the parity drive size)*.

In the commands below, adjust `N` (`1`, `2`, or `3`) to match the failed data drive (`d1` → `1`, `d2` → `2`, `d3` → `3`).

1. **Power down and physically replace the failed drive:**
   ```bash
   sudo poweroff
   ```
   Swap the dead drive in its bay and power `younix` back on.

2. **Pause automated sync and identify the new replacement drive:**
   ```bash
   sudo systemctl stop snapraid-sync.timer
   lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINT
   ls -l /dev/disk/by-id/ata-*
   ```

3. **Partition, encrypt (LUKS2), and format the replacement drive with the same labels:**
   ```bash
   N=1  # <-- 1 for d1/DATA1, 2 for d2/DATA2, 3 for d3/DATA3
   NEW_DISK=/dev/disk/by-id/ata-<MODEL_SERIAL_NEW_DRIVE>

   printf "label: gpt\ntype=linux, name=\"LUKS-DATA${N}\"\n" | sudo sfdisk "$NEW_DISK"
   sudo udevadm settle

   sudo cryptsetup luksFormat --type luks2 --batch-mode --key-file /etc/keys/hdd.key "/dev/disk/by-partlabel/LUKS-DATA${N}"
   sudo cryptsetup open --key-file /etc/keys/hdd.key "/dev/disk/by-partlabel/LUKS-DATA${N}" "crypt_data${N}"
   sudo mkfs.ext4 -m 1 -L "DATA${N}" "/dev/mapper/crypt_data${N}"
   sudo cryptsetup close "crypt_data${N}"
   ```

4. **Unlock and mount the empty replacement drive:**
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl start "systemd-cryptsetup@crypt_data${N}"
   sudo systemctl start "mnt-disk${N}.mount"
   findmnt "/mnt/disk${N}"
   ```

5. **Rebuild all files on `dN` from SnapRAID parity:**
   ```bash
   # Preview/recover everything belonging to dN and save a recovery log
   sudo snapraid -d "d${N}" -l /tmp/snapraid-fix.log fix
   ```
   *(Depending on how full the 4 TB drive was, this can take several hours—run it inside `tmux` so an SSH disconnect won't interrupt it.)*

6. **Verify recovered data, refresh MergerFS, and re-enable nightly sync:**
   ```bash
   # Verify checksums of every recovered file on dN
   sudo snapraid -d "d${N}" -a check

   # Update SnapRAID content files with the new drive's filesystem UUID
   sudo snapraid sync
   sudo snapraid status

   # Remount MergerFS so /mnt/data picks up the restored drive cleanly
   sudo systemctl restart mnt-data.mount

   # Re-enable nightly sync timer
   sudo systemctl start snapraid-sync.timer
   ```

---

### Scenario 2 — Replacing a Failed Parity Drive (`PARITY1`)

A parity drive failure loses **zero user data**—your files remain intact on the data drives, you just have no parity redundancy until the replacement is synced.

> **Important:** The replacement parity drive must be **at least as large as your largest data drive**.

1. **Power down and physically replace the parity drive:**
   ```bash
   sudo poweroff
   ```
   Swap the dead drive and power `younix` back on.

2. **Pause automated sync and identify the new drive:**
   ```bash
   sudo systemctl stop snapraid-sync.timer
   lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINT
   ls -l /dev/disk/by-id/ata-*
   ```

3. **Partition, encrypt (LUKS2), and format as `PARITY1`:**
   ```bash
   NEW_PARITY=/dev/disk/by-id/ata-<MODEL_SERIAL_NEW_PARITY>

   printf 'label: gpt\ntype=linux, name="LUKS-PARITY1"\n' | sudo sfdisk "$NEW_PARITY"
   sudo udevadm settle

   sudo cryptsetup luksFormat --type luks2 --batch-mode --key-file /etc/keys/hdd.key /dev/disk/by-partlabel/LUKS-PARITY1
   sudo cryptsetup open --key-file /etc/keys/hdd.key /dev/disk/by-partlabel/LUKS-PARITY1 crypt_parity1
   sudo mkfs.ext4 -m 0 -T largefile4 -L PARITY1 /dev/mapper/crypt_parity1
   sudo cryptsetup close crypt_parity1
   ```

4. **Unlock, mount, and rebuild parity (run inside `tmux`):**
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl start systemd-cryptsetup@crypt_parity1
   sudo systemctl start mnt-parity1.mount
   findmnt /mnt/parity1

   # Rebuild parity from scratch across all data drives
   sudo snapraid --force-full sync
   sudo snapraid status

   # Re-enable nightly sync timer
   sudo systemctl start snapraid-sync.timer
   ```

---

### Scenario 3 — Recovering Accidentally Deleted Files (Before Nightly Sync)

As long as `snapraid sync` has **not** run since the deletion:

```bash
# Inspect deleted/missing files
sudo snapraid diff

# Restore ALL deleted/missing files across the array:
sudo snapraid fix -m

# Or restore only a specific folder or file (path relative to disk root):
sudo snapraid -f /photos/2026/ fix
```

*(If nightly `snapraid sync` already committed the deletion, restore the file from your offsite `restic` backup in `T-018`.)*

---

### Scenario 4 — Repairing Silent Bit-Rot Detected by `snapraid scrub`

If `sudo snapraid status` or `journalctl -u snapraid-scrub` reports bad/corrupted blocks:

```bash
# Inspect status and affected files
sudo snapraid status

# Repair only the damaged blocks/files from parity
sudo snapraid -e fix

# Re-scrub the previously bad blocks to confirm they are clean
sudo snapraid -p bad scrub
sudo snapraid status
```

If the same drive repeatedly develops bad blocks, check `sudo smartctl -a /dev/sdX`—it is likely beginning to fail and should be proactively replaced using [Scenario 1](#scenario-1--replacing-a-failed-data-drive-d1-d2-or-d3) or [Scenario 2](#scenario-2--replacing-a-failed-parity-drive-parity1).
