{ config, lib, pkgs, ... }:

let
  downloadsRoot = "/mnt/data/media/downloads";
  incompleteDir = "${downloadsRoot}/incomplete";
  completeDir = "${downloadsRoot}/complete";

  # Ensure download subdirectories exist with `root:media` + `2770` (setgid)
  # once /mnt/data is mounted, matching modules/samba.nix and FileBrowser so
  # SABnzbd, Radarr, Sonarr, Jellyfin, and Samba share seamless write access
  # and atomic moves across MergerFS.
  arrDirsScript = pkgs.writeShellScript "younix-arr-dirs" ''
    set -euo pipefail

    if ! ${pkgs.util-linux}/bin/mountpoint -q /mnt/data; then
      echo "Skipping ${downloadsRoot}: /mnt/data is not mounted."
      exit 0
    fi

    for dir in \
      ${lib.escapeShellArg downloadsRoot} \
      ${lib.escapeShellArg incompleteDir} \
      ${lib.escapeShellArg completeDir} \
      ${lib.escapeShellArg "${completeDir}/movies"} \
      ${lib.escapeShellArg "${completeDir}/shows"}; do
      ${pkgs.coreutils}/bin/mkdir -p "$dir"
      ${pkgs.coreutils}/bin/chown root:media "$dir"
      ${pkgs.coreutils}/bin/chmod 2770 "$dir"
    done
  '';
in
{
  assertions = [
    {
      assertion = builtins.hasAttr "media" config.users.groups;
      message = "modules/services/arr.nix expects the 'media' group (defined in modules/samba.nix) for access to /mnt/data/media.";
    }
    {
      assertion = config.services.caddy.enable;
      message = "modules/services/arr.nix requires modules/proxy.nix (services.caddy.enable = true) for HTTPS routing and sabnzbd host_whitelist.";
    }
  ];

  # SABnzbd depends on `unrar` (unfreeRedistributable) to unpack Usenet RAR
  # archives. Keep unfree packages tightly allowlisted to just `unrar`.
  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) [ "unrar" ];

  # Inject the encrypted Caddy base domain into SABnzbd's host_whitelist at
  # runtime via sops-nix so https://sabnzbd.<domain> works immediately without
  # committing personal domain names to this public repository.
  sops.templates."sabnzbd-host.ini" = {
    owner = config.services.sabnzbd.user;
    group = config.services.sabnzbd.group;
    mode = "0400";
    restartUnits = [ "sabnzbd.service" ];
    content = ''
      [misc]
      host_whitelist = sabnzbd.${config.sops.placeholder."caddy/domain"}, younix.local, localhost, 127.0.0.1
    '';
  };

  # Provision /mnt/data/media/downloads/{incomplete,complete/{movies,shows}} on boot
  systemd.services.younix-arr-dirs = {
    description = "Ensure *arr / SABnzbd download directories and permissions exist";
    after = [
      "mnt-data.mount"
      "younix-samba-dirs.service"
    ];
    wants = [
      "mnt-data.mount"
      "younix-samba-dirs.service"
    ];
    before = [
      "sabnzbd.service"
      "radarr.service"
      "sonarr.service"
    ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = arrDirsScript;
    };
  };

  # ---------------------------------------------------------------------------
  # 1. SABnzbd — Usenet download client (Eweka configured via Web UI)
  # ---------------------------------------------------------------------------
  services.sabnzbd = {
    enable = true;
    group = "media";
    openFirewall = false;

    # Allow persisting Usenet server (Eweka), API keys, and categories configured
    # through the Web UI while still merging declarative defaults + host_whitelist.
    allowConfigWrite = true;

    secretFiles = [
      config.sops.templates."sabnzbd-host.ini".path
    ];

    settings = {
      misc = {
        host = "127.0.0.1";
        port = 8080;
        download_dir = incompleteDir;
        complete_dir = completeDir;
        # Match Samba's group-writable 0660/2770 model for /mnt/data/media
        permissions = "660";
      };
    };
  };

  systemd.services.sabnzbd = {
    after = [
      "mnt-data.mount"
      "younix-samba-dirs.service"
      "younix-arr-dirs.service"
    ];
    wants = [
      "mnt-data.mount"
      "younix-samba-dirs.service"
      "younix-arr-dirs.service"
    ];
    serviceConfig = {
      UMask = lib.mkForce "0007";
      Nice = 5;
      IOSchedulingClass = "best-effort";
      IOSchedulingPriority = 6;
      MemoryHigh = "512M";
      MemoryMax = "1G";
    };
  };

  # ---------------------------------------------------------------------------
  # 2. Prowlarr — Indexer manager (syncs Usenet indexers to Radarr & Sonarr)
  # ---------------------------------------------------------------------------
  services.prowlarr = {
    enable = true;
    openFirewall = false;
    settings = {
      server = {
        bindaddress = "127.0.0.1";
        port = 9696;
      };
    };
  };

  systemd.services.prowlarr.serviceConfig = {
    MemoryHigh = "256M";
    MemoryMax = "512M";
  };

  # ---------------------------------------------------------------------------
  # 3. Radarr — Movie manager (/mnt/data/media/movies)
  # ---------------------------------------------------------------------------
  services.radarr = {
    enable = true;
    group = "media";
    openFirewall = false;
    settings = {
      server = {
        bindaddress = "127.0.0.1";
        port = 7878;
      };
    };
  };

  systemd.services.radarr = {
    after = [
      "mnt-data.mount"
      "younix-samba-dirs.service"
      "younix-arr-dirs.service"
    ];
    wants = [
      "mnt-data.mount"
      "younix-samba-dirs.service"
      "younix-arr-dirs.service"
    ];
    serviceConfig = {
      UMask = lib.mkForce "0007";
      MemoryHigh = "384M";
      MemoryMax = "768M";
    };
  };

  # ---------------------------------------------------------------------------
  # 4. Sonarr — TV show manager (/mnt/data/media/shows)
  # ---------------------------------------------------------------------------
  services.sonarr = {
    enable = true;
    group = "media";
    openFirewall = false;
    settings = {
      server = {
        bindaddress = "127.0.0.1";
        port = 8989;
      };
    };
  };

  systemd.services.sonarr = {
    after = [
      "mnt-data.mount"
      "younix-samba-dirs.service"
      "younix-arr-dirs.service"
    ];
    wants = [
      "mnt-data.mount"
      "younix-samba-dirs.service"
      "younix-arr-dirs.service"
    ];
    serviceConfig = {
      UMask = lib.mkForce "0007";
      MemoryHigh = "384M";
      MemoryMax = "768M";
    };
  };

  # ---------------------------------------------------------------------------
  # 5. Caddy HTTPS reverse-proxy routes (LAN + tailscale0, zero public ports)
  # ---------------------------------------------------------------------------
  younix.proxy.routes = {
    sabnzbd.upstream = "127.0.0.1:8080";
    prowlarr.upstream = "127.0.0.1:9696";
    radarr.upstream = "127.0.0.1:7878";
    sonarr.upstream = "127.0.0.1:8989";
  };
}
