{ pkgs, ... }:

{
  # Idle power optimization for the UGREEN DXP4800 Plus (Intel Pentium Gold 8505).
  # Complements modules/thermals.nix (`powersave` governor + `thermald`) and
  # modules/storage.nix (`hd-idle` 30-min HDD spindown).

  # Request the conservative `powersave` PCIe ASPM policy (L0s/L1) so capable
  # links enter low-power states and unlock Package C2-C8+ once Native/PCIe ASPM
  # is enabled in the UGREEN BIOS.
  boot.kernelParams = [
    "pcie_aspm.policy=powersave"
  ];

  # Enable PCI and USB runtime power management for idle controllers, while:
  # - Keeping SATA/AHCI controllers (PCI class 0x0106*) at `on`, since resuming
  #   the ASM1164 controller from PCI D3 resets SATA links and spins up sleeping
  #   HDDs without block I/O (leaving hd-idle thinking they are still in standby).
  # - Excluding USB HID devices so a recovery keyboard never sleeps.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="pci", ATTR{class}!="0x0106*", TEST=="power/control", ATTR{power/control}="auto"
    ACTION=="add|change", SUBSYSTEM=="pci", ATTR{class}=="0x0106*", TEST=="power/control", ATTR{power/control}="on"
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
