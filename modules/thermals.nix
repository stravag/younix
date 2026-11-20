{ config, ... }:

{
  # Out-of-tree it87 driver for the UGREEN DXP4800 Plus's ITE IT8613E Super I/O fan controller,
  # plus drivetemp to expose SATA HDD temperatures via hwmon.
  boot.extraModulePackages = [ config.boot.kernelPackages.it87 ];
  boot.kernelModules = [
    "it87"
    "drivetemp"
  ];

  # Bypass ACPI resource conflict on the IT8613E without loosening ACPI globally
  boot.extraModprobeConfig = ''
    options it87 ignore_resource_conflict=1
  '';

  # Intel thermal management daemon (Alder Lake / Pentium Gold 8505)
  services.thermald.enable = true;
}
