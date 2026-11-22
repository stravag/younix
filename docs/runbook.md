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

# Check disk health (smartd) & HDD spindown state (hd-idle) without waking sleeping drives
systemctl status smartd hd-idle
journalctl -u smartd -u hd-idle -n 30
sudo hdparm -C /dev/sd?
for d in /dev/sd?; do echo "=== $d ==="; sudo smartctl -n standby -H -l selftest "$d"; done
```

### Disk Health (`smartd`) & HDD Spindown (`hd-idle`)

- **`smartd`** monitors all SATA HDDs and NVMe SSDs (`DEVICESCAN`), runs weekly **Short** self-tests (Saturday `04:xx`) and monthly **Long** self-tests (1st of the month `04:xx`, aligned with the `04:00` SnapRAID sync window while HDDs are awake), and uses `-n standby,q` so routine 30-minute polls never spin up sleeping drives.
- **`hd-idle`** spins down idle array HDDs after **30 minutes** (`1800s`) via ATA standby commands (`-c ata`), leaving NVMe SSDs and USB devices untouched (`-i 0`). Both `younix-fancontrol` (`hdparm -C` standby check before reading `drivetemp`) and `younix-leds` (`smartctl -n standby`) are standby-safe and will not wake sleeping drives.
- If you run a **manual Long SMART self-test** (`sudo smartctl -t long /dev/sdX`, ~8–9 h on 4 TB WD Red Plus), pause `hd-idle` while it runs so standby commands don't interrupt it:
  ```bash
  sudo systemctl stop hd-idle
  sudo smartctl -t long /dev/sdX
  # Once complete (check with `sudo smartctl -l selftest /dev/sdX`):
  sudo systemctl start hd-idle
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

## 3. Secrets Management (`sops-nix`)

Encrypted secrets live in `secrets/secrets.yaml` and are encrypted with `age` for two recipients listed in `.sops.yaml`:
- Your macOS admin key (`~/Library/Application Support/sops/age/keys.txt`) — used to view and edit secrets locally.
- `younix`'s host key (`/etc/keys/sops.key`) — used by `sops-nix` to decrypt secrets into in-memory `/run/secrets/<name>` at boot/activation.

### Day-to-Day: Adding or Editing Secrets (on macOS)

```bash
# Edit secrets/secrets.yaml in $EDITOR (decrypts locally, re-encrypts on save)
sops secrets/secrets.yaml

# Optional: inspect decrypted contents in your terminal without editing
sops --decrypt secrets/secrets.yaml
```

To expose a secret to a NixOS service:
1. Add the key/value inside `sops secrets/secrets.yaml`.
2. Declare it in the relevant module (e.g., `sops.secrets.<name> = { owner = "..."; };`) and point the service's `*File` / `environmentFile` option at `config.sops.secrets.<name>.path`.
3. Commit and push; verify on `younix` with `sudo ls -la /run/secrets/`.

### Re-keying After Rotating Keys

If you ever add or replace a public key in `.sops.yaml`, re-encrypt existing secret files from your Mac:

```bash
sops updatekeys secrets/secrets.yaml
```

---

## 4. Keyfile Recovery (If the 1 TB NVMe Is Reinstalled)

Both `/etc/keys/hdd.key` (LUKS2 HDD encryption) and `/etc/keys/sops.key` (`sops-nix` decryption) live on the 1 TB NVMe SSD and are backed up in your password manager. If you ever reinstall NixOS on a replacement NVMe SSD, restore both keyfiles from your password manager:

### Restore `/etc/keys/hdd.key` (before unlocking/mounting HDDs)

```bash
sudo install -d -m 0700 /etc/keys
echo '<BASE64_HDD_KEY_FROM_PASSWORD_MANAGER>' | base64 -d | sudo tee /etc/keys/hdd.key > /dev/null
sudo chmod 0400 /etc/keys/hdd.key

# Verify size is exactly 4096 bytes, then unlock & mount
sudo ls -l /etc/keys/hdd.key
sudo systemctl start systemd-cryptsetup@crypt_parity1 systemd-cryptsetup@crypt_data1
sudo systemctl start mnt-parity1.mount mnt-disk1.mount mnt-data.mount
```

### Restore `/etc/keys/sops.key` (for `/run/secrets/*` decryption)

```bash
sudo install -d -m 0700 /etc/keys
sudo install -m 0600 /dev/null /etc/keys/sops.key
sudo tee /etc/keys/sops.key > /dev/null <<'EOF'
<PASTE_FULL_SOPS_AGE_KEY_FROM_PASSWORD_MANAGER>
EOF
sudo chmod 0400 /etc/keys/sops.key

# Re-activate secrets (or reboot)
sudo /run/current-system/activate
sudo ls -la /run/secrets/
```

---

## 5. Drive Failure & Recovery Runbook

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

---

## 6. File Sharing (Samba)

SMB3 shares are managed declaratively in `modules/samba.nix` with macOS Finder optimizations (`vfs_fruit` + `streams_xattr`), Avahi/Bonjour discovery, WSDD (Windows discovery), and declarative password provisioning via `sops-nix`.

### Connecting from macOS

1. Open **Finder** → **Locations / Network** → **`younix`** (or press **`Cmd + K`** and enter `smb://younix.local`).
2. Connect as **Registered User** with your username (e.g. `ranil`) and the matching password under `samba_passwords.<username>` in `secrets/secrets.yaml`.

### Setting or Rotating a Samba Password

Edit `secrets/secrets.yaml` on your Mac and set/update the user's entry under `samba_passwords`:

```bash
sops secrets/secrets.yaml
```

```yaml
samba_passwords:
  ranil: your-strong-samba-password
```

Commit and push; when `comin` deploys, `sops-nix` automatically restarts `younix-samba-passwd.service` to update Samba's password database.

### Adding a New Share or Family Member

- **New shared folder:** Add an entry under `sharedFolders` in `modules/samba.nix` and include its name in each user's `shares` list under `sambaUsers` (its Unix group, `2770` directory permissions, and `smb.conf` section are created automatically).
- **New family member:** Define their NixOS account in `hosts/younix/configuration.nix`, add `samba_passwords.<name>` via `sops secrets/secrets.yaml`, and add them to `sambaUsers` in `modules/samba.nix` (set `personalShare = true` for a private `/mnt/data/users/<name>` folder).

### Diagnostics

```bash
# Check Samba, discovery, and setup services
systemctl status samba-smbd samba-wsdd younix-samba-dirs younix-samba-passwd

# Inspect effective Samba config and active client connections
testparm -s
sudo smbstatus

# Verify Samba user exists and check share directory permissions
sudo pdbedit -L
ls -ld /mnt/data/media /mnt/data/photos
```

---

## 7. Remote Access (Tailscale)

Remote access is provided by `modules/remote-access.nix` using **Tailscale** (outbound-only WireGuard mesh — zero router port-forwarding). To minimize the attack surface, `tailscale0` is **not** a trusted interface: a dedicated `younix-tailscale-in` firewall chain allows only explicitly allowlisted `tailscale0` ports (`22` for SSH, and `443` once `modules/proxy.nix` is deployed) plus ICMP echo, keeping LAN services (Samba `445/139`, WSDD, Avahi) unreachable over Tailscale.

### One-Time Enrollment (Interactive, No Auth Keys in Git)

After deploying `modules/remote-access.nix` to `younix`, authenticate interactively once over SSH:

```bash
sudo tailscale up --ssh=false --accept-routes=false --accept-dns=false
```

- `--ssh=false`: Keeps SSH strictly bound to OpenSSH + your `ed25519` key (a compromised Tailscale login alone cannot shell into `younix`).
- `--accept-routes=false`: Prevents other nodes from injecting routes into `younix`.
- `--accept-dns=false`: Keeps `younix`'s local DNS resolution untouched (important for LAN mDNS and Caddy DNS-01 queries).

Open the printed login URL in your browser to authorize `younix`, then record its private Tailscale IPv4 address:

```bash
tailscale status
tailscale ip -4
```

### Recommended Tailscale Admin Console Hardening

1. **Device Approval:** Enable *Device approval* under **Settings → Device management** so no new device can join your tailnet without explicit admin approval.
2. **Key Expiry:** Disable key expiry **only** on `younix` (so the headless NAS stays online unattended); keep key expiry enabled on personal laptops and phones.
3. **Least-Privilege ACLs / Grants:** Restrict access in **Access Controls** so only your admin Mac can reach `younix:22` (SSH), while phones/family devices can only reach `younix:443` (HTTPS). Keep **Tailscale Funnel** disabled.
4. **Tailnet Lock (Optional):** Enable Tailnet Lock for cryptographic node-key signing if you want zero trust in Tailscale's control plane.

### Diagnostics

```bash
# Check Tailscale daemon and peers
systemctl status tailscaled
tailscale status
tailscale ip -4

# Verify strict tailscale0 firewall chain (only allowlisted ports + ping)
sudo iptables -L younix-tailscale-in -n -v
sudo ip6tables -L younix-tailscale-in -n -v
```

---

## 8. Reverse Proxy & HTTPS (Caddy + deSEC DNS-01)

`modules/proxy.nix` runs **Caddy** built with `github.com/caddy-dns/desec` to serve all future web apps over HTTPS using a single wildcard Let's Encrypt certificate (`*.<domain>`):

- **Zero public ports:** DNS-01 validation updates `_acme-challenge` TXT records via the deSEC API; port `443` is exposed strictly on `tailscale0` (never LAN or WAN).
- **Private domain & credentials:** Both `caddy.domain` and `caddy.desec_token` live encrypted in `secrets/secrets.yaml` and are rendered at runtime into `/run/secrets/rendered/caddy.env`.
- **Adding a new service route:** Any NixOS service module simply declares `younix.proxy.routes.<subdomain>.upstream = "127.0.0.1:<port>";` (with optional `extraConfig`) to inherit the wildcard TLS cert and security headers automatically.

### Updating Caddy Secrets

```bash
sops secrets/secrets.yaml
```

```yaml
caddy:
  domain: <your-delegated-subdomain>
  desec_token: <your-desec-api-token>
```

Saving, committing, and pushing automatically restarts `caddy.service` once `comin` deploys.

### Diagnostics

```bash
# Check Caddy service and ACME DNS-01 certificate issuance logs
systemctl status caddy
journalctl -u caddy -n 50

# Verify wildcard HTTPS certificate & proxy routing from a Tailscale device
curl -i https://health.<your-delegated-subdomain>

# Confirm port 443 is allowed on tailscale0 (and NOT on LAN)
sudo iptables -L younix-tailscale-in -n -v
```
