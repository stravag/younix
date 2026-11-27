{ config, lib, pkgs, ... }:

let
  # Keyfile stored on the 1 TB NVMe for unattended Stage 2 LUKS2 unlock.
  # Protects against HDD RMA/disposal; keep an offline backup in a password manager.
  hddKeyFile = "/etc/keys/hdd.key";

  # Data drives pooled under /mnt/data via MergerFS and protected by SnapRAID.
  # To expand further, prepare new drives as LUKS-DATA4/DATA4, ... and append here.
  dataDisks = [
    {
      name = "d1";
      mapper = "crypt_data1";
      partLabel = "LUKS-DATA1";
      mountPoint = "/mnt/disk1";
    }
    {
      name = "d2";
      mapper = "crypt_data2";
      partLabel = "LUKS-DATA2";
      mountPoint = "/mnt/disk2";
    }
    {
      name = "d3";
      mapper = "crypt_data3";
      partLabel = "LUKS-DATA3";
      mountPoint = "/mnt/disk3";
    }
  ];

  # Parity drive(s) for SnapRAID (never included in the MergerFS pool).
  parityDisks = [
    {
      mapper = "crypt_parity1";
      partLabel = "LUKS-PARITY1";
      mountPoint = "/mnt/parity1";
      parityFile = "/mnt/parity1/snapraid.parity";
    }
  ];

  allDisks = parityDisks ++ dataDisks;
  allMountPoints = map (d: d.mountPoint) allDisks;

  # Abort automated nightly `snapraid sync` if more than this many files were
  # removed since the last sync, protecting parity against accidental mass deletion.
  maxDeletedFiles = 100;

  # Spin down idle array HDDs after 30 minutes of zero block I/O.
  hddSpindownSeconds = 1800;

  # Resolve each array disk's stable PARTLABEL to its parent whole-disk name (e.g. sda)
  # and exec hd-idle targeting only those HDDs (`-i 0` leaves NVMe SSDs and USB drives untouched).
  hdIdleStartScript = pkgs.writeShellScript "younix-hd-idle" ''
    set -euo pipefail

    args=(-i 0)
    seen=" "
    found=0

    for partlabel in ${lib.concatMapStringsSep " " (d: lib.escapeShellArg d.partLabel) allDisks}; do
      part="/dev/disk/by-partlabel/$partlabel"
      if [ ! -e "$part" ]; then
        echo "Warning: $part not present; skipping."
        continue
      fi

      disk="$(${pkgs.util-linux}/bin/lsblk -ndo pkname "$part")"
      if [ -z "$disk" ]; then
        echo "Warning: could not resolve parent disk for $part; skipping."
        continue
      fi

      case "$seen" in
        *" $disk "*) continue ;;
      esac
      seen="$seen$disk "

      echo "Managing spindown for /dev/$disk ($partlabel): ${toString hddSpindownSeconds}s (ATA)"
      args+=(-a "$disk" -i ${toString hddSpindownSeconds} -c ata)
      found=1
    done

    if [ "$found" -eq 0 ]; then
      echo "No array HDDs detected; exiting."
      exit 0
    fi

    exec ${pkgs.hd-idle}/bin/hd-idle "''${args[@]}"
  '';

  mkCrypttabLine = disk:
    "${disk.mapper} /dev/disk/by-partlabel/${disk.partLabel} ${hddKeyFile} luks,nofail";

  mkExt4Mount = disk: {
    device = "/dev/mapper/${disk.mapper}";
    fsType = "ext4";
    options = [
      "defaults"
      "noatime"
      "nofail"
      "x-systemd.device-timeout=30s"
    ];
  };

  snapraidPrecheckScript = pkgs.writeScript "younix-snapraid-precheck" ''
    #!${pkgs.python3}/bin/python3
    import os
    import re
    import subprocess
    import sys

    MOUNTPOINTS = ${builtins.toJSON allMountPoints}
    CONTENT_FILE = "/var/lib/snapraid/snapraid.content"
    MAX_DELETED = ${toString maxDeletedFiles}
    SNAPRAID = "${pkgs.snapraid}/bin/snapraid"

    missing = [mp for mp in MOUNTPOINTS if not os.path.ismount(mp)]
    if missing:
        print(f"ERROR: SnapRAID disk mountpoint(s) not mounted: {', '.join(missing)}", flush=True)
        print("Aborting automated sync to protect parity.", flush=True)
        sys.exit(1)

    if not os.path.isfile(CONTENT_FILE):
        print(
            f"No existing SnapRAID content file at {CONTENT_FILE}; "
            "skipping delete-threshold check (initial sync).",
            flush=True,
        )
        sys.exit(0)

    proc = subprocess.run(
        [SNAPRAID, "diff"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )

    # snapraid diff exit codes: 0 = no differences, 2 = differences found, 1 = error
    if proc.returncode not in (0, 2):
        print(proc.stdout, flush=True)
        print(f"ERROR: snapraid diff failed with exit code {proc.returncode}.", flush=True)
        sys.exit(1)

    summary_lines = [
        line
        for line in proc.stdout.splitlines()
        if re.match(r"^\s*\d+\s+(equal|added|removed|updated|moved|copied|restored)\s*$", line)
    ]
    for line in summary_lines:
        print(line, flush=True)

    match = re.search(r"^\s*(\d+)\s+removed\s*$", proc.stdout, re.MULTILINE)
    removed = int(match.group(1)) if match else 0

    if removed > MAX_DELETED:
        print(
            f"ERROR: {removed} files removed since last sync (threshold: {MAX_DELETED}). "
            "Aborting automated sync to protect parity.",
            flush=True,
        )
        print(
            "Inspect changes with 'sudo snapraid diff'; if intentional, run 'sudo snapraid sync' manually.",
            flush=True,
        )
        sys.exit(1)

    print(f"Pre-sync check passed (removed={removed} <= {MAX_DELETED}).", flush=True)
  '';
in
{
  # LUKS2, MergerFS & SnapRAID packages + FUSE support
  programs.fuse.userAllowOther = true;
  system.fsPackages = [ pkgs.mergerfs ];

  environment.systemPackages = with pkgs; [
    cryptsetup
    hd-idle
    hdparm
    mergerfs
    mergerfs-tools
    snapraid
    parted
  ];

  # Unlock LUKS2 HDDs in Stage 2 via systemd-cryptsetup-generator.
  # `nofail` ensures a missing or failed HDD never blocks boot or SSH access.
  environment.etc.crypttab = {
    mode = "0600";
    text = lib.concatMapStringsSep "\n" mkCrypttabLine allDisks + "\n";
  };

  # Underlying ext4 mounts (/mnt/parity1, /mnt/disk1, ...) + MergerFS pool (/mnt/data)
  fileSystems =
    lib.listToAttrs (
      map (d: lib.nameValuePair d.mountPoint (mkExt4Mount d)) allDisks
    )
    // {
      "/mnt/data" = {
        device = lib.concatMapStringsSep ":" (d: d.mountPoint) dataDisks;
        fsType = "fuse.mergerfs";
        depends = map (d: d.mountPoint) dataDisks;
        options = [
          "defaults"
          "allow_other"
          "nofail"
          "cache.files=partial"
          "dropcacheonclose=true"
          "category.create=mfs"
          "minfreespace=50G"
          "moveonenospc=true"
          "func.getattr=newest"
          "ignorepponrename=true"
          "fsname=younix-data"
        ];
      };
    };

  # Ensure NVMe directory for primary SnapRAID content file exists
  systemd.tmpfiles.rules = [
    "d /var/lib/snapraid 0750 root root -"
  ];

  # Scheduled SnapRAID parity sync (nightly) and bit-rot scrub (weekly)
  services.snapraid = {
    enable = true;

    dataDisks = lib.listToAttrs (
      map (d: lib.nameValuePair d.name d.mountPoint) dataDisks
    );

    parityFiles = map (p: p.parityFile) parityDisks;

    # Keep >= (parity count + 1) copies across separate physical drives:
    # 1 TB NVMe + each data HDD.
    contentFiles =
      [ "/var/lib/snapraid/snapraid.content" ]
      ++ map (d: "${d.mountPoint}/.snapraid.content") dataDisks;

    exclude = [
      "*.unrecoverable"
      "/tmp/"
      "/lost+found/"
      "/.snapraid.content*"
      "*.!sync"
      ".DS_Store"
      "._*"
      ".AppleDouble"
      ".Spotlight-V100"
      ".TemporaryItems"
      ".Trashes"
      "/timemachine/"
      "/media/downloads/"
    ];

    touchBeforeSync = true;

    # Save progress every 500 GB during large syncs (e.g. initial NAS migration)
    extraConfig = ''
      autosave 500
    '';

    sync.interval = "04:00";

    scrub = {
      interval = "Sun *-*-* 05:30:00";
      plan = 8;
      olderThan = 10;
    };
  };

  # Guard automated SnapRAID syncs against unmounted drives or accidental mass deletion
  systemd.services.snapraid-precheck = {
    description = "SnapRAID pre-sync mount and deletion-threshold check";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${snapraidPrecheckScript}";
    };
  };

  systemd.services.snapraid-sync = {
    requires = [ "snapraid-precheck.service" ];
    after = [ "snapraid-precheck.service" ];
  };

  systemd.services.snapraid-scrub = {
    after = [ "snapraid-sync.service" ];
  };

  # Proactive S.M.A.R.T. monitoring for SATA HDDs and NVMe SSDs.
  # - `-a`: monitor default SMART health, error logs, and attributes
  # - `-o on -S on`: enable automatic offline testing & attribute autosave (ATA/SATA; ignored on NVMe)
  # - `-n standby,q`: skip routine 30-min checks while HDDs are spun down (quietly, no log spam)
  # - `-s (...)`: weekly Short self-test (Sat 04:xx) & monthly Long self-test (1st of month 04:xx),
  #   aligned with the nightly 04:00 SnapRAID sync window while HDDs are already awake.
  services.smartd = {
    enable = true;
    autodetect = true;
    defaults.autodetected =
      "-a -o on -S on -n standby,q -s (S/../../6/04|L/../01/./04)"
      + lib.optionalString (config.younix.alerts.enable or false) " ${config.younix.alerts.smartdFlags}";
  };

  # Spin down idle array HDDs after inactivity for quieter acoustics & lower idle power.
  systemd.services.hd-idle = {
    description = "Spin down idle array HDDs after ${toString (hddSpindownSeconds / 60)} minutes";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${hdIdleStartScript}";
      Restart = "on-failure";
      RestartSec = "10s";
    };
  };
}
