{ pkgs, ... }:

{
  # Ensure redistributable Linux firmware (including Intel i915 GuC/HuC/DMC blobs
  # for Alder Lake hardware encoding and power management) is always installed.
  hardware.enableRedistributableFirmware = true;

  # Intel Alder Lake iGPU (Pentium Gold 8505 / UHD Graphics 48 EU) userspace stack
  # exposed via /dev/dri/renderD128 for native hardware transcoding (Jellyfin, Immich).
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver    # VA-API (iHD) driver for Gen 8+ / Alder Lake decode & encode
      vpl-gpu-rt            # Intel oneVPL GPU runtime for QuickSync (QSV) on Gen 12+
      intel-compute-runtime # OpenCL (NEO) & Level Zero runtime for HDR tone-mapping filters
    ];
  };

  # Point interactive VA-API tools (vainfo, ffmpeg) directly at the modern iHD driver.
  # Note: systemd services (Jellyfin, Immich) should also join `video` and `render` groups.
  environment.sessionVariables = {
    LIBVA_DRIVER_NAME = "iHD";
  };

  # Diagnostics & monitoring utilities for VA-API, OpenCL, and Intel GPU utilization
  environment.systemPackages = with pkgs; [
    libva-utils     # vainfo
    intel-gpu-tools # intel_gpu_top
    clinfo          # OpenCL platform/device verification
  ];
}
