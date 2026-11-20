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
  # Out-of-tree it87 driver for the UGREEN DXP4800 Plus's ITE IT8613E Super I/O fan controller,
  # plus drivetemp to expose SATA HDD temperatures via hwmon.
  boot.extraModulePackages = [ it87OutOfTree ];
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
