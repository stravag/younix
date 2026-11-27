{ config, lib, pkgs, ... }:

let
  nvmePgBackupDir = "/var/backup/postgresql";
  hddPgBackupDir = "/mnt/data/backups/postgres";
  nvmeJellyfinBackupDir = "/var/backup/jellyfin";
  nvmeArrBackupDir = "/var/backup/arr";

  hasArrSqliteServices =
    config.services.radarr.enable
    || config.services.sonarr.enable
    || config.services.prowlarr.enable;

  arrSqliteSources =
    lib.optional config.services.radarr.enable {
      name = "radarr";
      dir = config.services.radarr.dataDir;
    }
    ++ lib.optional config.services.sonarr.enable {
      name = "sonarr";
      dir = config.services.sonarr.dataDir;
    }
    ++ lib.optional config.services.prowlarr.enable {
      name = "prowlarr";
      dir = "/var/lib/private/prowlarr";
    };

  hasPersonalSambaShares = lib.any
    (s:
      let
        p = if builtins.isAttrs s && builtins.isString (s.path or null) then s.path else "";
      in
      lib.hasPrefix "/mnt/data/users/" p
    )
    (lib.attrValues (config.services.samba.settings or { }));

  # Mirror NVMe PostgreSQL dumps onto the MergerFS HDD pool when /mnt/data is mounted.
  # Keeping `services.postgresqlBackup.location` on NVMe avoids boot-time tmpfiles
  # races against LUKS/MergerFS (and `chattr +i /mnt/data`), while mirroring to
  # /mnt/data/backups/postgres gives SnapRAID parity protection, local HDD recovery
  # if the NVMe SSD ever fails, and offsite S3 backup inclusion.
  syncPostgresToHddScript = pkgs.writeShellScript "younix-postgres-hdd-sync" ''
    set -euo pipefail

    if ! ${pkgs.util-linux}/bin/mountpoint -q /mnt/data; then
      echo "Skipping ${hddPgBackupDir} sync: /mnt/data is not mounted."
      exit 0
    fi

    if [ ! -d ${lib.escapeShellArg nvmePgBackupDir} ]; then
      echo "No NVMe PostgreSQL backup directory at ${nvmePgBackupDir} yet; skipping."
      exit 0
    fi

    ${pkgs.coreutils}/bin/install -d -m 0700 -o root -g root ${lib.escapeShellArg hddPgBackupDir}

    copied=0
    shopt -s nullglob
    for dump in ${lib.escapeShellArg nvmePgBackupDir}/*.sql*; do
      base="$(${pkgs.coreutils}/bin/basename "$dump")"
      tmp="${hddPgBackupDir}/.''${base}.tmp"
      ${pkgs.coreutils}/bin/rm -f "$tmp"
      ${pkgs.coreutils}/bin/install -m 0600 -o root -g root "$dump" "$tmp"
      ${pkgs.coreutils}/bin/mv -f "$tmp" "${hddPgBackupDir}/$base"
      copied=$((copied + 1))
    done

    echo "Synced $copied PostgreSQL dump file(s) from ${nvmePgBackupDir} to ${hddPgBackupDir}."
  '';

  # Pre-backup preparation & safety checks run right before `restic backup`:
  # 1. Abort loudly (exit 1) if /mnt/data is unmounted so restic never records an
  #    incomplete snapshot or prunes healthy snapshots (and T-019 OnFailure alerts fire).
  # 2. Ensure expected HDD backup/document directories exist once /mnt/data is verified.
  # 3. Ensure a fresh PostgreSQL dump is mirrored to /mnt/data/backups/postgres.
  # 4. Snapshot live Jellyfin SQLite databases atomically via SQLite's online `.backup` API
  #    into /var/backup/jellyfin without stopping Jellyfin.
  resticPrepareScript = pkgs.writeShellScript "younix-restic-prepare" ''
    set -euo pipefail

    if ! ${pkgs.util-linux}/bin/mountpoint -q /mnt/data; then
      echo "ERROR: /mnt/data is not mounted; aborting offsite backup to protect snapshot history." >&2
      exit 1
    fi

    ${pkgs.coreutils}/bin/mkdir -p /mnt/data/documents
    ${pkgs.coreutils}/bin/install -d -m 0700 -o root -g root ${lib.escapeShellArg hddPgBackupDir}

    ${lib.optionalString config.services.postgresql.enable ''
      shopt -s nullglob
      existing_dumps=(${lib.escapeShellArg hddPgBackupDir}/*.sql*)
      if [ "''${#existing_dumps[@]}" -eq 0 ]; then
        echo "No PostgreSQL dumps found in ${hddPgBackupDir}; triggering postgresqlBackup.service first..."
        ${pkgs.systemd}/bin/systemctl start postgresqlBackup.service
      fi
      ${syncPostgresToHddScript}
    ''}

    ${lib.optionalString config.services.jellyfin.enable ''
      ${pkgs.coreutils}/bin/install -d -m 0700 -o root -g root ${lib.escapeShellArg nvmeJellyfinBackupDir}
      shopt -s nullglob
      for db in ${lib.escapeShellArg "${config.services.jellyfin.dataDir}/data"}/*.db; do
        name="$(${pkgs.coreutils}/bin/basename "$db")"
        tmp="${nvmeJellyfinBackupDir}/.''${name}.tmp"
        ${pkgs.coreutils}/bin/rm -f "$tmp"
        ${pkgs.sqlite}/bin/sqlite3 -cmd ".timeout 30000" "$db" ".backup '$tmp'"
        ${pkgs.coreutils}/bin/chmod 0600 "$tmp"
        ${pkgs.coreutils}/bin/mv -f "$tmp" "${nvmeJellyfinBackupDir}/$name"
      done
    ''}

    ${lib.concatMapStringsSep "\n" (src: ''
      if [ -d ${lib.escapeShellArg src.dir} ]; then
        ${pkgs.coreutils}/bin/install -d -m 0700 -o root -g root ${lib.escapeShellArg "${nvmeArrBackupDir}/${src.name}"}
        shopt -s nullglob
        for db in ${lib.escapeShellArg src.dir}/*.db; do
          name="$(${pkgs.coreutils}/bin/basename "$db")"
          case "$name" in
            logs.db) continue ;;
          esac
          tmp="${nvmeArrBackupDir}/${src.name}/.''${name}.tmp"
          ${pkgs.coreutils}/bin/rm -f "$tmp"
          ${pkgs.sqlite}/bin/sqlite3 -cmd ".timeout 30000" "$db" ".backup '$tmp'"
          ${pkgs.coreutils}/bin/chmod 0600 "$tmp"
          ${pkgs.coreutils}/bin/mv -f "$tmp" "${nvmeArrBackupDir}/${src.name}/$name"
        done
      fi
    '') arrSqliteSources}
  '';
in
{
  environment.systemPackages = [
    pkgs.restic
  ];

  # ---------------------------------------------------------------------------
  # 1. Local consistent PostgreSQL dumps (T-017)
  #
  # Automatically dumps all PostgreSQL databases, roles, and permissions
  # (`pg_dumpall`, covering Immich today and Paperless-ngx once T-016 is enabled)
  # nightly at 03:00 — ahead of 03:15 offsite restic and 04:00 SnapRAID sync.
  # ---------------------------------------------------------------------------
  services.postgresqlBackup = {
    enable = config.services.postgresql.enable;
    backupAll = true;
    location = nvmePgBackupDir;
    compression = "zstd";
    startAt = "*-*-* 03:00:00";
  };

  systemd.services.younix-postgres-hdd-sync = lib.mkIf config.services.postgresql.enable {
    description = "Mirror PostgreSQL SQL dumps from NVMe to /mnt/data/backups/postgres";
    after = [
      "postgresqlBackup.service"
      "mnt-data.mount"
    ];
    wants = [ "mnt-data.mount" ];
    wantedBy = [ "postgresqlBackup.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = syncPostgresToHddScript;
    };
  };

  # ---------------------------------------------------------------------------
  # 2. Encrypted S3 offsite backups via restic (T-018)
  #
  # Credentials and repository URL are kept out of this public repo via sops-nix
  # (`secrets/secrets.yaml` under `restic.*`). Every snapshot is client-side
  # encrypted with AES-256 / Poly1305-AES before leaving younix.
  # ---------------------------------------------------------------------------
  sops.secrets."restic/repository" = {
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."restic/password" = {
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."restic/aws_access_key_id" = {
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."restic/aws_secret_access_key" = {
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.templates."restic-offsite.env" = {
    owner = "root";
    group = "root";
    mode = "0400";
    content = ''
      AWS_ACCESS_KEY_ID=${config.sops.placeholder."restic/aws_access_key_id"}
      AWS_SECRET_ACCESS_KEY=${config.sops.placeholder."restic/aws_secret_access_key"}
    '';
  };

  services.restic.backups.offsite = {
    # Automatically initialize the remote S3 repository on the very first run.
    initialize = true;

    # Install `restic-offsite` CLI wrapper pre-wired with credentials & repo file.
    createWrapper = true;

    repositoryFile = config.sops.secrets."restic/repository".path;
    passwordFile = config.sops.secrets."restic/password".path;
    environmentFile = config.sops.templates."restic-offsite.env".path;

    backupPrepareCommand = "${resticPrepareScript}";

    # Back up all irreplaceable user data and non-declarative service/host state,
    # explicitly omitting bulk media (/mnt/data/media) and regenerable caches.
    paths =
      [
        "/mnt/data/photos"
        "/mnt/data/immich"
        "/mnt/data/documents"
        "/mnt/data/share"
        hddPgBackupDir
      ]
      ++ lib.optional hasPersonalSambaShares "/mnt/data/users"
      ++ lib.optional config.services.tailscale.enable "/var/lib/tailscale"
      ++ lib.optional config.services.caddy.enable "/var/lib/caddy"
      ++ lib.optionals config.services.jellyfin.enable [
        nvmeJellyfinBackupDir
        config.services.jellyfin.dataDir
      ]
      ++ lib.optional hasArrSqliteServices nvmeArrBackupDir
      ++ lib.optional config.services.radarr.enable config.services.radarr.dataDir
      ++ lib.optional config.services.sonarr.enable config.services.sonarr.dataDir
      ++ lib.optional config.services.prowlarr.enable "/var/lib/private/prowlarr"
      ++ lib.optional config.services.sabnzbd.enable config.services.sabnzbd.stateDir
      ++ lib.optional config.services.paperless.enable config.services.paperless.dataDir;

    exclude = [
      # Regenerable Immich derivatives (bind-mounted from NVMe inside immich-server,
      # empty on host HDD, excluded explicitly as defense-in-depth)
      "/mnt/data/immich/thumbs"
      "/mnt/data/immich/encoded-video"

      # Regenerable Jellyfin logs, transcode scratch, scraped artwork/metadata, and
      # live SQLite files (captured atomically in /var/backup/jellyfin instead)
      "/var/lib/jellyfin/log"
      "/var/lib/jellyfin/metadata"
      "/var/lib/jellyfin/transcodes"
      "/var/lib/jellyfin/data/*.db"
      "/var/lib/jellyfin/data/*.db-wal"
      "/var/lib/jellyfin/data/*.db-shm"

      # Regenerable *arr / SABnzbd logs, artwork caches, redundant zip backups, and
      # live SQLite files (captured atomically in /var/backup/arr instead)
      "/var/lib/radarr/**/logs"
      "/var/lib/radarr/**/MediaCover"
      "/var/lib/radarr/**/Backups"
      "/var/lib/radarr/**/*.db"
      "/var/lib/radarr/**/*.db-wal"
      "/var/lib/radarr/**/*.db-shm"
      "/var/lib/sonarr/**/logs"
      "/var/lib/sonarr/**/MediaCover"
      "/var/lib/sonarr/**/Backups"
      "/var/lib/sonarr/**/*.db"
      "/var/lib/sonarr/**/*.db-wal"
      "/var/lib/sonarr/**/*.db-shm"
      "/var/lib/private/prowlarr/logs"
      "/var/lib/private/prowlarr/Backups"
      "/var/lib/private/prowlarr/*.db"
      "/var/lib/private/prowlarr/*.db-wal"
      "/var/lib/private/prowlarr/*.db-shm"
      "/var/lib/sabnzbd/logs"

      # macOS Finder / SMB metadata clutter & partial sync files
      ".DS_Store"
      "._*"
      ".AppleDouble"
      ".Spotlight-V100"
      ".TemporaryItems"
      ".Trashes"
      "*.!sync"
    ];

    extraBackupArgs = [
      "--cleanup-cache"
    ];

    # Snapshot retention policy (`restic forget --prune`)
    pruneOpts = [
      "--keep-daily 7"
      "--keep-weekly 4"
      "--keep-monthly 12"
      "--keep-yearly 3"
    ];

    # Verify index/snapshot integrity plus a random 500 MB sample of remote pack
    # files after each run (~15 GB/month bounded S3 egress).
    checkOpts = [
      "--with-cache"
      "--read-data-subset=500M"
    ];

    # Run nightly at 03:15 (after 03:00 PostgreSQL dumps, aligned with the single
    # nightly HDD wake window ahead of 04:00 SnapRAID sync).
    timerConfig = {
      OnCalendar = "*-*-* 03:15:00";
      Persistent = true;
      RandomizedDelaySec = "5m";
    };
  };

  systemd.services.restic-backups-offsite = {
    after = [
      "mnt-data.mount"
      "network-online.target"
      "postgresqlBackup.service"
      "younix-postgres-hdd-sync.service"
    ];
    wants = [
      "mnt-data.mount"
      "network-online.target"
    ];
    environment = {
      # Keep Go's heap smoothly bounded on the 8 GB NAS during large photo uploads.
      GOMEMLIMIT = "1200MiB";
    };
    serviceConfig = {
      Nice = 10;
      IOSchedulingClass = "best-effort";
      IOSchedulingPriority = 7;
      CPUQuota = "200%";
      MemoryHigh = "1500M";
      MemoryMax = "2500M";
      OOMScoreAdjust = 300;
    };
  };
}
