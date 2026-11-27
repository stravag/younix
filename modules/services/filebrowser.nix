{ config, inputs, lib, pkgs, ... }:

let
  host = "127.0.0.1";
  port = 8095;
  stateDir = "/var/lib/filebrowser-quantum";
  cacheDir = "/var/cache/filebrowser-quantum";

  # Pull FileBrowser Quantum v2.x from nixpkgs-unstable (nixos-26.05 ships 1.5.x)
  # so we start directly on the v2 config schema and native OIDC support.
  unstablePkgs = import inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
    config = config.nixpkgs.config;
  };
  filebrowserPkg = unstablePkgs.filebrowser-quantum;

  yamlFormat = pkgs.formats.yaml { };

  # Disable background indexing per source (`folderPath: "/"`, `viewable: true`)
  # so FileBrowser Quantum never periodically crawls `/mnt/data/*` and wakes
  # spun-down HDDs managed by `hd-idle`.
  mkSource = name: path: {
    inherit name path;
    config = {
      defaultEnabled = true;
      rules = [
        {
          folderPath = "/";
          viewable = true;
        }
      ];
    };
  };

  configFile = yamlFormat.generate "filebrowser-quantum.yaml" {
    http = {
      listen = host;
      inherit port;
      trustProxyHeaders = true;
    };

    server = {
      database = {
        path = "${stateDir}/filebrowser.sqlite";
      };
      inherit cacheDir;
      # Match Samba's 0660/2770 group-writable permissions (FileBrowser Quantum
      # applies explicit chmod using these values, overriding systemd UMask).
      filesystem = {
        createFilePermission = "660";
        createDirectoryPermission = "2770";
      };
      sources = [
        (mkSource "Share" "/mnt/data/share")
        (mkSource "Media" "/mnt/data/media")
        (mkSource "Photos" "/mnt/data/photos")
      ];
    };

    auth = {
      methods = {
        # Passwordless access behind LAN + Tailscale Caddy HTTPS (same pattern as
        # Beszel). Switch to `oidc` once Pocket-ID is deployed.
        noauth = true;
      };
    };

    frontend = {
      name = "younix Files";
    };
  };
in
{
  users.groups.filebrowser = { };

  users.users.filebrowser = {
    isSystemUser = true;
    group = "filebrowser";
    # Join the Samba share groups so FileBrowser Quantum can read/write
    # `/mnt/data/{share,media,photos}` while preserving group ownership.
    extraGroups = [ "share" "media" "photos" ];
    home = stateDir;
  };

  systemd.services.filebrowser-quantum = {
    description = "FileBrowser Quantum Web File Manager";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network.target"
      "mnt-data.mount"
      "younix-samba-dirs.service"
    ];
    wants = [ "younix-samba-dirs.service" ];
    requires = [ "mnt-data.mount" ];

    path = [ pkgs.ffmpeg ];

    serviceConfig = {
      User = "filebrowser";
      Group = "filebrowser";
      # Match Samba's group-writable 0660/2770 model (combined with setgid on
      # `/mnt/data/{share,media,photos}`) so uploads stay writable via SMB.
      UMask = "0007";

      StateDirectory = "filebrowser-quantum";
      StateDirectoryMode = "0750";
      CacheDirectory = "filebrowser-quantum";
      CacheDirectoryMode = "0750";
      WorkingDirectory = stateDir;

      ExecStart = "${lib.getExe filebrowserPkg} -c ${configFile}";
      Restart = "on-failure";
      RestartSec = "5s";

      # Hardening
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      ReadWritePaths = [
        "/mnt/data/share"
        "/mnt/data/media"
        "/mnt/data/photos"
      ];

      # Resource limits (8 GB RAM NAS)
      MemoryHigh = "256M";
      MemoryMax = "512M";
    };
  };

  # Expose FileBrowser Quantum over HTTPS at https://files.<domain> via Caddy (LAN + tailscale0).
  younix.proxy.routes.files = {
    upstream = "${host}:${toString port}";
  };
}
