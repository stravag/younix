{ config, lib, ... }:

{
  assertions = [
    {
      assertion = config.hardware.graphics.enable;
      message = "modules/services/jellyfin.nix requires modules/graphics.nix (hardware.graphics.enable = true) for Intel QuickSync transcoding.";
    }
    {
      assertion = builtins.hasAttr "media" config.users.groups;
      message = "modules/services/jellyfin.nix expects the 'media' group (defined in modules/samba.nix) for access to /mnt/data/media.";
    }
  ];

  # Native Jellyfin media server with Intel Alder Lake QuickSync (QSV) hardware
  # transcoding, fast NVMe metadata/cache storage, and media stored on /mnt/data/media.
  services.jellyfin = {
    enable = true;

    # Open Jellyfin LAN ports (HTTP 8096 + UDP 7359/1900 LAN discovery) for
    # non-Tailscale home devices such as smart TVs. Tailscale traffic remains
    # strictly limited to HTTPS (443) via Caddy (enforced by modules/remote-access.nix).
    openFirewall = true;

    # Store SQLite database, metadata, trickplay images, and transcode temp files
    # on the fast 1 TB NVMe SSD rather than the spinning HDD array.
    dataDir = "/var/lib/jellyfin";
    configDir = "/var/lib/jellyfin/config";
    cacheDir = "/var/cache/jellyfin";
    logDir = "/var/lib/jellyfin/log";

    # Keep encoding.xml declaratively managed by NixOS as the single source of truth.
    forceEncodingConfig = true;

    # Intel Alder Lake (Pentium Gold 8505) QuickSync Video (QSV) via /dev/dri/renderD128.
    hardwareAcceleration = {
      enable = true;
      type = "qsv";
      device = "/dev/dri/renderD128";
    };

    transcoding = {
      enableHardwareEncoding = true;
      # HuC/GuC firmware is active on Alder Lake (verified in T-013), enabling
      # Intel's low-power H.264/HEVC encoders for lower CPU/GPU power draw.
      enableIntelLowPowerEncoding = true;
      # Hardware HDR-to-SDR tone-mapping via intel-compute-runtime (OpenCL).
      enableToneMapping = true;
      enableSubtitleExtraction = true;
      # Pause transcoding once buffered ahead so the iGPU and fans stay quiet.
      throttleTranscoding = true;

      # Hardware decode codecs supported by Intel Alder Lake UHD Graphics (48 EU).
      # (10-bit HEVC Main10 decode is enabled by default in Jellyfin; VC-1 is unsupported on Gen 12+.)
      hardwareDecodingCodecs = {
        h264 = true;
        hevc = true;
        hevcRExt10bit = true;
        hevcRExt12bit = true;
        vp8 = true;
        vp9 = true;
        av1 = true;
        vc1 = false;
      };

      # H.264 hardware encode is always enabled; Alder Lake supports HEVC encode (not AV1 encode).
      hardwareEncodingCodecs = {
        hevc = true;
        av1 = false;
      };
    };
  };

  # Grant Jellyfin access to /dev/dri/renderD128 (video, render) and /mnt/data/media (media).
  users.users.jellyfin.extraGroups = [
    "video"
    "render"
    "media"
  ];

  systemd.services.jellyfin = {
    # Wait for the MergerFS HDD pool and Samba share directory setup on boot so
    # Jellyfin does not scan an unmounted /mnt/data/media, while keeping `wants`
    # (not `requires`) so a degraded HDD array never blocks Jellyfin from starting.
    after = [
      "mnt-data.mount"
      "younix-samba-dirs.service"
    ];
    wants = [
      "mnt-data.mount"
      "younix-samba-dirs.service"
    ];

    # Ensure VA-API/oneVPL inside the systemd unit unambiguously selects Intel iHD.
    environment = {
      LIBVA_DRIVER_NAME = "iHD";
    };
  };

  # Expose Jellyfin over HTTPS at https://jellyfin.<domain> via Caddy (tailscale0-only).
  younix.proxy.routes.jellyfin = {
    upstream = "127.0.0.1:8096";
  };
}
