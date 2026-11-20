{ config, pkgs, ... }:

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

  # Declarative, fail-safe fan controller for the UGREEN DXP4800 Plus (ITE IT8613E):
  #   - pwm2 / fan2: CPU fan (driven by Intel coretemp Package temp)
  #   - pwm3 / fan3: Rear 140mm chassis fan (driven by HDD drivetemp, NVMe, and CPU temps)
  # Restores hardware automatic mode (pwmX_enable = 2) on exit/failure.
  fanControlScript = pkgs.writeScript "younix-fancontrol" ''
    #!${pkgs.python3}/bin/python3
    import glob
    import os
    import signal
    import sys
    import time

    POLL_INTERVAL = 5
    FALLBACK_PWM = 128

    # Piecewise-linear curves: list of (temp_celsius, pwm_0_to_255)
    CPU_FAN_CURVE = [
        (48.0, 25),
        (55.0, 45),
        (65.0, 100),
        (75.0, 180),
        (82.0, 255),
    ]

    CHASSIS_HDD_CURVE = [
        (38.0, 25),
        (43.0, 60),
        (48.0, 140),
        (53.0, 255),
    ]

    CHASSIS_NVME_CURVE = [
        (50.0, 25),
        (65.0, 140),
        (75.0, 255),
    ]

    CHASSIS_CPU_CURVE = [
        (60.0, 25),
        (75.0, 150),
        (85.0, 255),
    ]

    running = True


    def handle_signal(signum, _frame):
        global running
        print(f"Received signal {signum}, restoring hardware auto fan control...", flush=True)
        running = False


    def read_text(path):
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()


    def write_text(path, value):
        with open(path, "w", encoding="utf-8") as f:
            f.write(f"{value}\n")


    def find_hwmons():
        hwmons = {}
        for path in sorted(glob.glob("/sys/class/hwmon/hwmon*")):
            name_file = os.path.join(path, "name")
            if os.path.isfile(name_file):
                try:
                    name = read_text(name_file)
                    hwmons.setdefault(name, []).append(path)
                except OSError:
                    pass
        return hwmons


    def read_temp_c(path):
        return int(read_text(path)) / 1000.0


    def interpolate(temp, curve):
        if temp <= curve[0][0]:
            return curve[0][1]
        for (t0, p0), (t1, p1) in zip(curve, curve[1:]):
            if temp <= t1:
                ratio = (temp - t0) / (t1 - t0)
                return int(round(p0 + ratio * (p1 - p0)))
        return curve[-1][1]


    def smooth_pwm(current, target):
        if current is None:
            return target
        # Ramp up promptly, ramp down gently to prevent audible pulsing
        if target > current:
            return min(target, current + max(10, (target - current + 1) // 2))
        if target < current:
            return max(target, current - max(3, (current - target) // 4))
        return current


    def get_temperatures(hwmons):
        cpu_temps = []
        for path in hwmons.get("coretemp", []):
            t = os.path.join(path, "temp1_input")
            if os.path.isfile(t):
                cpu_temps.append(read_temp_c(t))

        hdd_temps = []
        for path in hwmons.get("drivetemp", []):
            t = os.path.join(path, "temp1_input")
            if os.path.isfile(t):
                hdd_temps.append(read_temp_c(t))

        nvme_temps = []
        for path in hwmons.get("nvme", []):
            t = os.path.join(path, "temp1_input")
            if os.path.isfile(t):
                nvme_temps.append(read_temp_c(t))

        return (
            max(cpu_temps) if cpu_temps else None,
            max(hdd_temps) if hdd_temps else None,
            max(nvme_temps) if nvme_temps else None,
        )


    def restore_auto(it86_path):
        if not it86_path:
            return
        for ch in ("pwm2_enable", "pwm3_enable"):
            try:
                write_text(os.path.join(it86_path, ch), 2)
            except OSError as exc:
                print(f"Warning: failed to restore {ch}: {exc}", flush=True)


    def main():
        signal.signal(signal.SIGTERM, handle_signal)
        signal.signal(signal.SIGINT, handle_signal)

        it86_path = None
        for _ in range(30):
            hwmons = find_hwmons()
            if "it8613" in hwmons:
                it86_path = hwmons["it8613"][0]
                break
            time.sleep(1)

        if not it86_path:
            print("ERROR: it8613 hwmon device not found; leaving BIOS fan control active.", flush=True)
            sys.exit(1)

        print(f"Controlling fans via {it86_path} (pwm2=CPU, pwm3=Chassis)", flush=True)

        pwm2_enable = os.path.join(it86_path, "pwm2_enable")
        pwm3_enable = os.path.join(it86_path, "pwm3_enable")
        pwm2_file = os.path.join(it86_path, "pwm2")
        pwm3_file = os.path.join(it86_path, "pwm3")
        fan2_file = os.path.join(it86_path, "fan2_input")
        fan3_file = os.path.join(it86_path, "fan3_input")

        cur_pwm2 = None
        cur_pwm3 = None
        last_logged = (None, None)

        try:
            write_text(pwm2_enable, 1)
            write_text(pwm3_enable, 1)

            while running:
                try:
                    hwmons = find_hwmons()
                    cpu_t, hdd_t, nvme_t = get_temperatures(hwmons)

                    target_pwm2 = interpolate(cpu_t, CPU_FAN_CURVE) if cpu_t is not None else FALLBACK_PWM

                    chassis_demands = []
                    if hdd_t is not None:
                        chassis_demands.append(interpolate(hdd_t, CHASSIS_HDD_CURVE))
                    if nvme_t is not None:
                        chassis_demands.append(interpolate(nvme_t, CHASSIS_NVME_CURVE))
                    if cpu_t is not None:
                        chassis_demands.append(interpolate(cpu_t, CHASSIS_CPU_CURVE))
                    target_pwm3 = max(chassis_demands) if chassis_demands else FALLBACK_PWM

                    cur_pwm2 = smooth_pwm(cur_pwm2, target_pwm2)
                    cur_pwm3 = smooth_pwm(cur_pwm3, target_pwm3)

                    write_text(pwm2_file, cur_pwm2)
                    write_text(pwm3_file, cur_pwm3)

                    if (
                        last_logged[0] is None
                        or abs(cur_pwm2 - last_logged[0]) >= 5
                        or abs(cur_pwm3 - last_logged[1]) >= 5
                    ):
                        rpm2 = read_text(fan2_file) if os.path.isfile(fan2_file) else "?"
                        rpm3 = read_text(fan3_file) if os.path.isfile(fan3_file) else "?"
                        print(
                            f"temps(CPU={cpu_t}C HDD={hdd_t}C NVMe={nvme_t}C) -> "
                            f"pwm2={cur_pwm2} ({rpm2} RPM), pwm3={cur_pwm3} ({rpm3} RPM)",
                            flush=True,
                        )
                        last_logged = (cur_pwm2, cur_pwm3)
                except OSError as exc:
                    print(f"Sensor/PWM error ({exc}); setting safe fallback PWM {FALLBACK_PWM}", flush=True)
                    try:
                        write_text(pwm2_file, FALLBACK_PWM)
                        write_text(pwm3_file, FALLBACK_PWM)
                    except OSError:
                        pass

                time.sleep(POLL_INTERVAL)
        finally:
            restore_auto(it86_path)


    if __name__ == "__main__":
        main()
  '';
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

  # Intel thermal management daemon & power-saving CPU frequency governor
  services.thermald.enable = true;
  powerManagement.cpuFreqGovernor = "powersave";

  # Quiet, temperature-driven fan control daemon
  systemd.services.younix-fancontrol = {
    description = "UGREEN DXP4800 Plus quiet thermal fan controller";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];
    serviceConfig = {
      ExecStart = "${fanControlScript}";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };
}
