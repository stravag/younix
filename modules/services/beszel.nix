{ config, lib, pkgs, ... }:

let
  hubHost = "127.0.0.1";
  hubPort = 8090;
  agentHost = "127.0.0.1";
  agentPort = 45876;
  agentListen = "${agentHost}:${toString agentPort}";
  agentEnvDir = "/run/beszel-agent";
  agentEnvFile = "${agentEnvDir}/hub.env";

  # Work around a nixpkgs beszel packaging bug where the `testing` build tag is
  # enabled, causing beszel-hub's backgroundSmartFetchEnabled() to return false
  # and leaving the S.M.A.R.T. tab permanently empty.
  beszelPkg = pkgs.beszel.overrideAttrs (_: {
    doCheck = false;
    tags = [ ];
  });

  # Declarative systems list synced by beszel-hub on startup from beszel_data/config.yml.
  # Paired with SHARE_ALL_SYSTEMS=true so no personal email is needed in this
  # public repo (works with AUTO_LOGIN today and Pocket-ID OIDC later).
  hubConfigYml = pkgs.writeText "beszel-config.yml" ''
    systems:
      - name: younix
        host: ${agentHost}
        port: ${toString agentPort}
        users:
          - admin@younix.local
  '';

  # Wait for beszel-hub to generate its local Ed25519 keypair under /var/lib/beszel-hub
  # and write KEY="<pubkey>" into /run/beszel-agent/hub.env so the local agent pairs
  # automatically without manual key copy-pasting or committing keys to git.
  syncHubKeyScript = pkgs.writeShellScript "younix-beszel-agent-key" ''
    set -euo pipefail

    key=""
    for _ in $(${pkgs.coreutils}/bin/seq 1 30); do
      pub="$(${pkgs.findutils}/bin/find -L /var/lib/beszel-hub -maxdepth 3 -type f -name 'id_ed25519.pub' 2>/dev/null | ${pkgs.coreutils}/bin/head -n 1 || true)"
      if [ -n "$pub" ] && [ -s "$pub" ]; then
        key="$(${pkgs.coreutils}/bin/tr -d '\r\n' < "$pub")"
        break
      fi

      priv="$(${pkgs.findutils}/bin/find -L /var/lib/beszel-hub -maxdepth 3 -type f -name 'id_ed25519' 2>/dev/null | ${pkgs.coreutils}/bin/head -n 1 || true)"
      if [ -n "$priv" ] && [ -s "$priv" ]; then
        key="$(${pkgs.openssh}/bin/ssh-keygen -y -f "$priv" | ${pkgs.coreutils}/bin/tr -d '\r\n')"
        break
      fi

      ${pkgs.coreutils}/bin/sleep 1
    done

    if [ -z "$key" ]; then
      echo "ERROR: Timed out waiting for beszel-hub Ed25519 key under /var/lib/beszel-hub." >&2
      exit 1
    fi

    ${pkgs.coreutils}/bin/install -d -m 0700 -o root -g root ${lib.escapeShellArg agentEnvDir}
    tmp="${agentEnvFile}.tmp"
    ${pkgs.coreutils}/bin/rm -f "$tmp"
    (
      umask 0177
      printf 'KEY="%s"\n' "$key" > "$tmp"
    )
    ${pkgs.coreutils}/bin/mv -f "$tmp" ${lib.escapeShellArg agentEnvFile}
  '';
in
{
  # Lightweight system metrics & systemd service log dashboard (Beszel Hub + Agent).
  # Runs natively on the 1 TB NVMe with ~40 MB RAM footprint and zero login prompt
  # behind Tailscale-only Caddy HTTPS (https://status.<domain>).
  services.beszel.hub = {
    enable = true;
    package = beszelPkg;
    host = hubHost;
    port = hubPort;
    environment = {
      # Auto-authenticate the single local admin account since access is already
      # gated behind Tailscale + Caddy HTTPS (create this account on first visit).
      AUTO_LOGIN = "admin@younix.local";
      # Make declaratively provisioned systems visible to all authenticated users
      # (both admin@younix.local today and Pocket-ID OIDC users later).
      SHARE_ALL_SYSTEMS = "true";
    };
  };

  systemd.services.beszel-hub = {
    preStart = ''
      rm -f /var/lib/beszel-hub/config.yml
      mkdir -p /var/lib/beszel-hub/beszel_data
      ln -sfn ${hubConfigYml} /var/lib/beszel-hub/beszel_data/config.yml
    '';
    serviceConfig = {
      MemoryHigh = "128M";
      MemoryMax = "256M";
    };
  };

  systemd.services.younix-beszel-agent-key = {
    description = "Sync local Beszel Hub SSH public key for beszel-agent";
    after = [ "beszel-hub.service" ];
    requires = [ "beszel-hub.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${syncHubKeyScript}";
    };
  };

  services.beszel.agent = {
    enable = true;
    package = beszelPkg;
    openFirewall = false;
    environmentFile = agentEnvFile;
    # Enable standby-safe S.M.A.R.T. monitoring (Beszel invokes smartctl with
    # `-n standby` and serves cached data while HDDs are spun down).
    smartmon.enable = true;
    extraPath = [
      pkgs.intel-gpu-tools
      pkgs.systemd
    ];
    environment = {
      LISTEN = agentListen;
      # Monitor the MergerFS pool and individual array drives alongside NVMe root.
      # statfs() reads cached superblock metadata and does not wake sleeping HDDs.
      EXTRA_FILESYSTEMS = "/mnt/data__DataPool,/mnt/disk1__Disk1,/mnt/parity1__Parity1";
      SMART_INTERVAL = "1h";
    };
  };

  systemd.services.beszel-agent = {
    after = [
      "beszel-hub.service"
      "younix-beszel-agent-key.service"
      "mnt-data.mount"
    ];
    requires = [ "younix-beszel-agent-key.service" ];
    wants = [
      "beszel-hub.service"
      "mnt-data.mount"
    ];
    serviceConfig = {
      # Allow reading systemd-journal logs, Intel iGPU telemetry (intel_gpu_top),
      # and SATA/NVMe S.M.A.R.T. attributes (smartctl -n standby).
      SupplementaryGroups = [
        "systemd-journal"
        "video"
        "render"
        "disk"
      ];
      NoNewPrivileges = lib.mkForce false;
      PrivateUsers = lib.mkForce false;
      PrivateDevices = lib.mkForce false;
      DevicePolicy = lib.mkForce "auto";
      AmbientCapabilities = lib.mkForce [
        "CAP_PERFMON"
        "CAP_SYS_RAWIO"
        "CAP_SYS_ADMIN"
      ];
      CapabilityBoundingSet = lib.mkForce [
        "CAP_PERFMON"
        "CAP_SYS_RAWIO"
        "CAP_SYS_ADMIN"
      ];
      SystemCallFilter = lib.mkForce [ "@system-service" "perf_event_open" ];
      MemoryHigh = "128M";
      MemoryMax = "256M";
    };
  };

  # Expose Beszel dashboard over HTTPS at https://status.<domain> via Caddy (tailscale0-only).
  younix.proxy.routes.status = {
    upstream = "${hubHost}:${toString hubPort}";
  };
}
