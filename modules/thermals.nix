{ config, ... }:

let
  # Move the out-of-tree it87 module into `updates/` so depmod always prefers it
  # over the older in-tree kernel/drivers/hwmon/it87.ko.xz (which lacks IT8613E support).
  it87OutOfTree = config.boot.kernelPackages.it87.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      modDir="$out/lib/modules/${config.boot.kernelPackages.kernel.modDirVersion}"
      mkdir -p "$modDir/updates"
      find "$modDir" -maxdepth 4 -name 'it87.ko*' ! -path "$modDir/updates/*" -exec mv {} "$modDir/updates/" \;
    '';
  });
in
{
  # Out-of-tree it87 driver for read-only sensor visibility (fan RPMs, PWM %, board temps)
  # on the UGREEN DXP4800 Plus's ITE IT8613E Super I/O chip. Fan control itself is left to
  # the motherboard's native BIOS Smart Fan hardware controller (pwmX_enable = 2).
  boot.extraModulePackages = [ it87OutOfTree ];
  boot.kernelModules = [ "it87" ];

  # Bypass ACPI resource conflict on the IT8613E without loosening ACPI globally
  boot.extraModprobeConfig = ''
    options it87 ignore_resource_conflict=1
  '';

  # Tune the ITE IT8613E's built-in hardware Smart Fan curve once at boot (no daemon):
  # keeps BIOS hardware auto mode (pwmX_enable = 2), ramp slopes, and 85C/80C full-speed
  # failsafes untouched while lowering idle floors (CPU ~400 RPM, rear 140mm ~440 RPM)
  # and raising ramp-start thresholds (60C PECI / 45C board diode).
  services.udev.extraRules = ''
    ACTION=="add|change", SUBSYSTEM=="hwmon", ATTR{name}=="it8613", ATTR{pwm2_auto_start}="30", ATTR{pwm2_auto_point2_temp}="60000", ATTR{pwm3_auto_start}="42", ATTR{pwm3_auto_point2_temp}="45000"
  '';

  # Intel thermal management daemon & power-saving CPU frequency governor
  services.thermald.enable = true;
  powerManagement.cpuFreqGovernor = "powersave";
}
