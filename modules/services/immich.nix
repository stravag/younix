{ config, inputs, lib, pkgs, ... }:

let
  nvmeDir = "/var/lib/immich";
  hddDir = "/mnt/data/immich";
  externalPhotosDir = "/mnt/data/photos";

  immichDirsScript = pkgs.writeShellScript "younix-immich-dirs" ''
    set -euo pipefail

    # Always ensure fast NVMe directories for thumbnails and transcoded videos exist.
    ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg "${nvmeDir}/thumbs"} ${lib.escapeShellArg "${nvmeDir}/encoded-video"}
    ${pkgs.coreutils}/bin/chown immich:immich ${lib.escapeShellArg nvmeDir} ${lib.escapeShellArg "${nvmeDir}/thumbs"} ${lib.escapeShellArg "${nvmeDir}/encoded-video"}
    ${pkgs.coreutils}/bin/chmod 0750 ${lib.escapeShellArg nvmeDir} ${lib.escapeShellArg "${nvmeDir}/thumbs"} ${lib.escapeShellArg "${nvmeDir}/encoded-video"}

    for sub in thumbs encoded-video; do
      marker=${lib.escapeShellArg nvmeDir}/"$sub"/.immich
      if [ ! -e "$marker" ]; then
        ${pkgs.coreutils}/bin/touch "$marker"
        ${pkgs.coreutils}/bin/chown immich:immich "$marker"
        ${pkgs.coreutils}/bin/chmod 0640 "$marker"
      fi
    done

    # Never create directories under /mnt/data if the MergerFS HDD pool is unmounted.
    if ! ${pkgs.util-linux}/bin/mountpoint -q /mnt/data; then
      echo "Skipping ${hddDir}: /mnt/data is not mounted."
      exit 0
    fi

    ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg hddDir}
    ${pkgs.coreutils}/bin/chown immich:immich ${lib.escapeShellArg hddDir}
    ${pkgs.coreutils}/bin/chmod 0750 ${lib.escapeShellArg hddDir}

    for sub in library upload profile backups thumbs encoded-video; do
      ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg hddDir}/"$sub"
      ${pkgs.coreutils}/bin/chown immich:immich ${lib.escapeShellArg hddDir}/"$sub"
      ${pkgs.coreutils}/bin/chmod 0750 ${lib.escapeShellArg hddDir}/"$sub"
    done

    for sub in library upload profile backups; do
      marker=${lib.escapeShellArg hddDir}/"$sub"/.immich
      if [ ! -e "$marker" ]; then
        ${pkgs.coreutils}/bin/touch "$marker"
        ${pkgs.coreutils}/bin/chown immich:immich "$marker"
        ${pkgs.coreutils}/bin/chmod 0640 "$marker"
      fi
    done
  '';
in
{
  # Pull the Immich module & packages from nixpkgs-unstable so Immich runs a
  # supported v3.x release (26.05's immich-2.7.5 is EOL/insecure) while the
  # rest of younix remains on stable nixos-26.05.
  disabledModules = [ "services/web-apps/immich.nix" ];
  imports = [ "${inputs.nixpkgs-unstable}/nixos/modules/services/web-apps/immich.nix" ];

  nixpkgs.overlays = [
    (_final: prev:
      let
        pkgsUnstable = inputs.nixpkgs-unstable.legacyPackages.${prev.stdenv.hostPlatform.system};
      in
      { inherit (pkgsUnstable) immich; }
      // lib.optionalAttrs (pkgsUnstable ? immich-machine-learning) {
        inherit (pkgsUnstable) immich-machine-learning;
      }
    )
  ];

  assertions = [
    {
      assertion = config.hardware.graphics.enable;
      message = "modules/services/immich.nix requires modules/graphics.nix (hardware.graphics.enable = true) for Intel QuickSync transcoding.";
    }
    {
      assertion = builtins.hasAttr "photos" config.users.groups;
      message = "modules/services/immich.nix expects the 'photos' group (defined in modules/samba.nix) for External Library access to /mnt/data/photos.";
    }
  ];

  # Native Immich photo & video server with:
  # - Hybrid storage:
  #   * /mnt/data/photos  — Samba-managed family photo archive (read-only External Library)
  #   * /mnt/data/immich  — Immich-managed uploads, per-user libraries, and DB dumps on HDD
  #   * /var/lib/immich/{thumbs,encoded-video} — fast NVMe cache bind-mounted into immich-server
  #   * PostgreSQL, Valkey/Redis, and ML model cache on the 1 TB NVMe SSD
  # - Intel Alder Lake QuickSync (QSV) hardware transcoding via /dev/dri/renderD128
  # - HTTPS access via Caddy at https://photos.<domain> (LAN + tailscale0)
  services.immich = {
    enable = true;
    host = "127.0.0.1";
    port = 2283;
    openFirewall = false;

    mediaLocation = hddDir;

    # Grant immich-server access to the Intel Alder Lake DRM render node
    # (lifts systemd PrivateDevices for /dev/dri/renderD128).
    accelerationDevices = [ "/dev/dri/renderD128" ];

    # Native ML microservice (CLIP smart search, facial recognition, OCR) on NVMe.
    # Limit concurrency and give Gunicorn headroom so bulk jobs finish quietly
    # without spiking the Pentium Gold 8505 into 90C+ turbo / full-speed fan ramps.
    machine-learning = {
      enable = true;
      environment = {
        MACHINE_LEARNING_REQUEST_THREADS = "2";
        MACHINE_LEARNING_MODEL_INTER_OP_THREADS = "1";
        MACHINE_LEARNING_MODEL_INTRA_OP_THREADS = "2";
        MACHINE_LEARNING_MODEL_TTL = "180";
        MACHINE_LEARNING_WORKER_TIMEOUT = lib.mkForce "300";
      };
    };

    # Leave Immich system settings editable via the Admin Web UI (QuickSync QSV,
    # storage template, external libraries, backup schedule, etc.).
    settings = null;

    # Ensure VA-API/oneVPL unambiguously select Intel iHD inside immich-server.
    environment = {
      LIBVA_DRIVER_NAME = "iHD";
    };
  };

  # Grant Immich access to /dev/dri/renderD128 (video, render) and /mnt/data/photos (photos).
  users.users.immich.extraGroups = [
    "video"
    "render"
    "photos"
  ];

  # Provision NVMe derivative dirs and mount-safe HDD mediaLocation dirs before immich-server starts.
  systemd.services.younix-immich-dirs = {
    description = "Ensure Immich NVMe and HDD storage directories exist";
    after = [
      "mnt-data.mount"
      "younix-samba-dirs.service"
    ];
    wants = [
      "mnt-data.mount"
      "younix-samba-dirs.service"
    ];
    before = [ "immich-server.service" ];
    wantedBy = [
      "immich-server.service"
      "multi-user.target"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = immichDirsScript;
    };
  };

  systemd.services.immich-server = {
    after = [
      "mnt-data.mount"
      "younix-samba-dirs.service"
      "younix-immich-dirs.service"
    ];
    wants = [
      "mnt-data.mount"
      "younix-samba-dirs.service"
      "younix-immich-dirs.service"
    ];
    unitConfig = {
      # Skip starting immich-server if the MergerFS HDD pool is unmounted so a
      # degraded array never causes uploads to land on the root NVMe.
      ConditionPathIsMountPoint = "/mnt/data";
    };
    serviceConfig = {
      # Mount NVMe-backed thumbs & encoded-video into immich-server's mount namespace.
      # The underlying HDD directories remain empty (avoiding SnapRAID churn and
      # offsite backup bloat), and timeline browsing stays silent without waking HDDs.
      BindPaths = [
        "${nvmeDir}/thumbs:${hddDir}/thumbs"
        "${nvmeDir}/encoded-video:${hddDir}/encoded-video"
      ];
      # Expose the Samba-managed family photo archive strictly read-only to Immich
      # so it can be indexed as an External Library without risking accidental deletion.
      ReadOnlyPaths = [
        externalPhotosDir
      ];
      # Prevent bulk library scans/thumbnailing from starving SSH, Caddy, Samba, or Jellyfin.
      Nice = 10;
      IOSchedulingClass = "best-effort";
      IOSchedulingPriority = 7;
      CPUQuota = "400%";
      MemoryHigh = "2500M";
      MemoryMax = "3500M";
      OOMScoreAdjust = 300;
    };
  };

  systemd.services.immich-machine-learning = {
    serviceConfig = {
      # Keep CLIP/face-recognition/OCR bursts cool and quiet (150% CPU avoids 90C+
      # turbo spikes that slam the CPU fan to ~3500 RPM), while giving enough RAM
      # headroom (3G high / 4G max) so all 5 loaded models don't thrash MemoryHigh
      # and hit Gunicorn worker timeouts in a restart loop.
      Nice = 15;
      IOSchedulingClass = "idle";
      CPUQuota = "150%";
      MemoryHigh = "3G";
      MemoryMax = "4G";
      OOMScoreAdjust = 500;
    };
  };

  # Expose Immich over HTTPS at https://photos.<domain> via Caddy (LAN + tailscale0).
  # Caddy v2 has unlimited request body size, no read/write transport timeout, and
  # automatic WebSocket support by default for large mobile video uploads.
  younix.proxy.routes.photos = {
    upstream = "127.0.0.1:2283";
  };
}
