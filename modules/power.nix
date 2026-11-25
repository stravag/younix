{ pkgs, ... }:

{
  # Idle power optimization for the UGREEN DXP4800 Plus (Intel Pentium Gold 8505).
  # Complements modules/thermals.nix (`powersave` governor + `thermald`) and
  # modules/storage.nix (`hd-idle` 30-min HDD spindown).

  # The DXP4800 Plus BIOS sets the ACPI FADT NO_ASPM flag, leaving PCIe ASPM
  # disabled across all root ports and endpoints (pinning Package C-states at C0/C1).
  # Override FADT with the conservative `powersave` policy (L0s/L1) so capable
  # devices can enter low-power link states and unlock Package C2-C8+.
  # (Takes effect after reboot; systemd-boot keeps previous generations as fallback.)
  boot.kernelParams = [
    "pcie_aspm=force"
    "pcie_aspm.policy=powersave"
  ];

  # Enable PCI and USB runtime power management so idle controllers — including
  # the unplugged Marvell 10GbE NIC (enp2s0) — drop into low-power D3 states.
  # Exclude USB HID devices so a recovery keyboard never sleeps during maintenance.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="pci", TEST=="power/control", ATTR{power/control}="auto"
    ACTION=="add", SUBSYSTEM=="usb", TEST=="power/control", ATTR{bDeviceClass}!="03", ATTR{power/control}="auto"
  '';

  # Bias Intel HWP (intel_pstate) from `balance_performance` to `balance_power`
  # so background tasks stay at lower voltages/clocks while still scaling under load.
  systemd.tmpfiles.rules = [
    "w /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference - - - - balance_power"
  ];

  # Useful for inspecting NIC link speeds, EEE, and Wake-on-LAN state
  environment.systemPackages = [
    pkgs.ethtool
  ];
}
