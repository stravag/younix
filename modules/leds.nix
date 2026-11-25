{ config, lib, pkgs, ... }:

let
  ugreenLedsSrc = pkgs.fetchFromGitHub {
    owner = "miskcoo";
    repo = "ugreen_leds_controller";
    rev = "f0fcd8192abdd92244aba9f6f0d10572f5561380";
    hash = "sha256-rhU/1ZPoMvlK1uR0pceA3yLsGYWC6NmLel2Psysbh9c=";
  };

  # Out-of-tree led-ugreen kernel module for the UGREEN DXP4800 Plus front-panel
  # I2C LED controller (SMBus I801 @ 0x3a). Exposes /sys/class/leds/{power,netdev,disk1..disk4}.
  ledUgreenKmod = config.boot.kernelPackages.callPackage (
    { stdenv, kernel, kernelModuleMakeFlags }:
    stdenv.mkDerivation {
      pname = "led-ugreen";
      version = "0.1-unstable-f0fcd81";
      src = ugreenLedsSrc;
      sourceRoot = "${ugreenLedsSrc.name}/kmod";

      nativeBuildInputs = kernel.moduleBuildDependencies;
      hardeningDisable = [ "pic" "format" ];

      buildPhase = ''
        runHook preBuild
        make -C "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build" \
          M="$PWD" \
          ${lib.escapeShellArgs kernelModuleMakeFlags} \
          modules
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        make -C "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build" \
          M="$PWD" \
          ${lib.escapeShellArgs kernelModuleMakeFlags} \
          INSTALL_MOD_PATH="$out" \
          modules_install
        runHook postInstall
      '';
    }
  ) { };

  # Array mountpoints monitored for the degraded-array power LED warning.
  # Derived declaratively from modules/storage.nix so future disk expansions (T-009)
  # are tracked automatically without duplicating mount paths.
  arrayMountPoints = lib.unique (
    lib.optional (config.fileSystems ? "/mnt/data") "/mnt/data"
    ++ (config.fileSystems."/mnt/data".depends or [ ])
    ++ (map builtins.dirOf (config.services.snapraid.parityFiles or [ ]))
  );

  # Active front-panel LED controller for the UGREEN DXP4800 Plus:
  #   - Probes the I2C LED MCU (led-ugreen @ 0x3a on Intel SMBus I801)
  #   - Power LED: steady white when healthy, steady amber if any array mountpoint is missing
  #   - LAN LED: kernel `netdev` trigger bound to whichever NIC has link (solid on link, blinks on RX/TX)
  #   - Disk 1-4 LEDs: maps ata1..ata4 -> disk1..disk4; off for empty bays, white + I/O activity
  #     blinking via kernel `oneshot` trigger for active drives, dim blue for spun-down (standby)
  #     drives (via standby-safe `hdparm -C`), red on offline / SMART failure.
  ledControlScript = pkgs.writeScript "younix-leds" ''
    #!${pkgs.python3}/bin/python3
    import glob
    import os
    import re
    import signal
    import subprocess
    import sys
    import time

    POLL_INTERVAL = 0.25
    NET_CHECK_INTERVAL = 5.0
    ARRAY_CHECK_INTERVAL = 10.0
    POWER_CHECK_INTERVAL = 15.0
    SMART_CHECK_INTERVAL = 300.0

    # Brightness (0-255) and RGB colors ("R G B")
    BRIGHTNESS_POWER = 32
    BRIGHTNESS_NETDEV = 32
    BRIGHTNESS_DISK_ACTIVE = 32
    BRIGHTNESS_DISK_STANDBY = 32

    COLOR_POWER_OK = "255 255 255"
    COLOR_POWER_DEGRADED = "255 120 0"
    COLOR_NETDEV = "255 255 255"
    COLOR_DISK_ACTIVE = "255 255 255"
    COLOR_DISK_STANDBY = "0 180 255"
    COLOR_DISK_FAIL = "255 0 0"

    NETDEV_BLINK_INTERVAL_MS = 150
    DISK_BLINK_OFF_MS = 50
    DISK_BLINK_ON_MS = 50

    # DXP4800 Plus hardware mappings
    ATA_BAY_MAP = {
        "ata1": "disk1",
        "ata2": "disk2",
        "ata3": "disk3",
        "ata4": "disk4",
    }
    PREFERRED_NICS = ["enp2s0", "enp5s0"]
    ARRAY_MOUNTPOINTS = ${builtins.toJSON arrayMountPoints}

    LEDS_DIR = "/sys/class/leds"
    SMARTCTL = "${pkgs.smartmontools}/bin/smartctl"
    HDPARM = "${pkgs.hdparm}/bin/hdparm"

    running = True


    def handle_signal(signum, _frame):
        global running
        print(f"Received signal {signum}, stopping LED controller.", flush=True)
        running = False


    def read_text(path):
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()


    def write_text(path, value):
        with open(path, "w", encoding="utf-8") as f:
            f.write(f"{value}\n")


    def led_path(name, attr):
        return os.path.join(LEDS_DIR, name, attr)


    def probe_i2c_device():
        smbus = None
        for name_file in sorted(glob.glob("/sys/bus/i2c/devices/i2c-*/name")):
            try:
                if "SMBus I801 adapter" in read_text(name_file):
                    smbus = os.path.basename(os.path.dirname(name_file))
                    break
            except OSError:
                pass

        if not smbus:
            print("ERROR: SMBus I801 adapter not found under /sys/bus/i2c/devices.", flush=True)
            return False

        bus_num = smbus.removeprefix("i2c-")
        dev_dir = f"/sys/bus/i2c/devices/{smbus}/{bus_num}-003a"

        if not os.path.isdir(dev_dir):
            print(f"Probing led-ugreen at 0x3a on {smbus}...", flush=True)
            write_text(f"/sys/bus/i2c/devices/{smbus}/new_device", "led-ugreen 0x3a")
        else:
            driver_name = read_text(os.path.join(dev_dir, "name"))
            if driver_name != "led-ugreen":
                print(f"ERROR: {dev_dir} is already bound to '{driver_name}'.", flush=True)
                return False

        for _ in range(30):
            if os.path.isdir(os.path.join(LEDS_DIR, "power")):
                return True
            time.sleep(0.5)

        print("ERROR: Timed out waiting for /sys/class/leds/power.", flush=True)
        return False


    def reset_led(name):
        if not os.path.isdir(os.path.join(LEDS_DIR, name)):
            return
        write_text(led_path(name, "trigger"), "none")
        write_text(led_path(name, "blink_type"), "none")
        write_text(led_path(name, "brightness"), 0)


    def configure_power_led(degraded=False):
        if not os.path.isdir(os.path.join(LEDS_DIR, "power")):
            return
        color = COLOR_POWER_DEGRADED if degraded else COLOR_POWER_OK
        write_text(led_path("power", "trigger"), "none")
        write_text(led_path("power", "blink_type"), "none")
        write_text(led_path("power", "color"), color)
        write_text(led_path("power", "brightness"), BRIGHTNESS_POWER)


    def get_missing_array_mounts():
        if not ARRAY_MOUNTPOINTS:
            return ()
        mounted = set()
        try:
            with open("/proc/mounts", "r", encoding="utf-8") as f:
                for line in f:
                    parts = line.split()
                    if len(parts) >= 2:
                        mounted.add(parts[1].replace("\\040", " "))
        except OSError:
            return ()
        return tuple(mp for mp in ARRAY_MOUNTPOINTS if mp not in mounted)


    def find_active_nic():
        candidates = list(PREFERRED_NICS)
        for iface_dir in sorted(glob.glob("/sys/class/net/*")):
            iface = os.path.basename(iface_dir)
            if iface not in candidates and os.path.exists(os.path.join(iface_dir, "device")):
                candidates.append(iface)

        for iface in candidates:
            carrier_file = f"/sys/class/net/{iface}/carrier"
            if os.path.isfile(carrier_file):
                try:
                    if read_text(carrier_file) == "1":
                        return iface
                except OSError:
                    pass
        return None


    def configure_netdev_led(nic):
        if not os.path.isdir(os.path.join(LEDS_DIR, "netdev")):
            return
        if nic is None:
            reset_led("netdev")
            print("LAN LED: no active link (off)", flush=True)
            return

        write_text(led_path("netdev", "blink_type"), "none")
        write_text(led_path("netdev", "trigger"), "netdev")
        write_text(led_path("netdev", "device_name"), nic)
        write_text(led_path("netdev", "link"), 1)
        write_text(led_path("netdev", "rx"), 1)
        write_text(led_path("netdev", "tx"), 1)
        write_text(led_path("netdev", "interval"), NETDEV_BLINK_INTERVAL_MS)
        write_text(led_path("netdev", "color"), COLOR_NETDEV)
        write_text(led_path("netdev", "brightness"), BRIGHTNESS_NETDEV)
        print(f"LAN LED: bound to {nic} (netdev trigger: link + rx/tx)", flush=True)


    def discover_bay_disks():
        bays = {led: None for led in ATA_BAY_MAP.values()}
        for block_path in sorted(glob.glob("/sys/block/sd*")):
            real = os.path.realpath(block_path)
            match = re.search(r"/(ata\d+)/", real)
            if match and match.group(1) in ATA_BAY_MAP:
                bays[ATA_BAY_MAP[match.group(1)]] = os.path.basename(block_path)
        return bays


    def read_disk_io(dev):
        stat_file = f"/sys/block/{dev}/stat"
        parts = read_text(stat_file).split()
        if len(parts) < 9:
            return (0, 0)
        # (reads_completed + writes_completed, ios_in_progress)
        return (int(parts[0]) + int(parts[4]), int(parts[8]))


    def check_disk_healthy(dev):
        state_file = f"/sys/block/{dev}/device/state"
        if os.path.isfile(state_file):
            try:
                if read_text(state_file) != "running":
                    return False
            except OSError:
                return False

        # -n standby ensures sleeping HDDs are never spun up by health checks.
        # smartctl exit bit 3 (8) specifically indicates SMART health failure.
        try:
            proc = subprocess.run(
                [SMARTCTL, "-n", "standby", "-H", f"/dev/{dev}"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=10,
                check=False,
            )
            if proc.returncode & 8:
                return False
        except (OSError, subprocess.SubprocessError):
            pass
        return True


    def check_disk_power(dev):
        # `hdparm -C` issues ATA CHECK POWER MODE (0xE5), which never wakes sleeping drives.
        try:
            proc = subprocess.run(
                [HDPARM, "-C", f"/dev/{dev}"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=10,
                check=False,
            )
            for line in proc.stdout.splitlines():
                lower = line.lower()
                if "drive state is:" in lower:
                    if "standby" in lower or "sleeping" in lower:
                        return "standby"
                    return "active"
        except (OSError, subprocess.SubprocessError):
            pass
        return "active"


    def configure_disk_led(led, healthy, power):
        if not os.path.isdir(os.path.join(LEDS_DIR, led)):
            return
        if not healthy:
            write_text(led_path(led, "blink_type"), "none")
            write_text(led_path(led, "trigger"), "oneshot")
            write_text(led_path(led, "delay_on"), DISK_BLINK_ON_MS)
            write_text(led_path(led, "delay_off"), DISK_BLINK_OFF_MS)
            write_text(led_path(led, "invert"), 1)
            write_text(led_path(led, "color"), COLOR_DISK_FAIL)
            write_text(led_path(led, "brightness"), BRIGHTNESS_DISK_ACTIVE)
        elif power == "standby":
            write_text(led_path(led, "trigger"), "none")
            write_text(led_path(led, "blink_type"), "none")
            write_text(led_path(led, "color"), COLOR_DISK_STANDBY)
            write_text(led_path(led, "brightness"), BRIGHTNESS_DISK_STANDBY)
        else:
            write_text(led_path(led, "blink_type"), "none")
            write_text(led_path(led, "trigger"), "oneshot")
            write_text(led_path(led, "delay_on"), DISK_BLINK_ON_MS)
            write_text(led_path(led, "delay_off"), DISK_BLINK_OFF_MS)
            write_text(led_path(led, "invert"), 1)
            write_text(led_path(led, "color"), COLOR_DISK_ACTIVE)
            write_text(led_path(led, "brightness"), BRIGHTNESS_DISK_ACTIVE)


    def main():
        signal.signal(signal.SIGTERM, handle_signal)
        signal.signal(signal.SIGINT, handle_signal)

        if not probe_i2c_device():
            sys.exit(1)

        # Clear boot-time hardware blink on all LEDs first
        for name in ("power", "netdev", "disk1", "disk2", "disk3", "disk4"):
            try:
                reset_led(name)
            except OSError as exc:
                print(f"Warning: failed to reset {name}: {exc}", flush=True)

        active_nic = object()      # sentinel to force initial setup
        missing_mounts = object()  # sentinel to force initial setup
        last_net_check = -NET_CHECK_INTERVAL
        last_array_check = -ARRAY_CHECK_INTERVAL
        last_power_check = time.monotonic()
        last_smart_check = time.monotonic()

        # Per-bay state tracking
        bay_state = {}      # led -> (dev, healthy, power)
        prev_io = {}        # led -> total_ios
        disk_health = {}    # dev -> bool
        disk_power = {}     # dev -> "active" | "standby"

        while running:
            now = time.monotonic()

            # 1. Power LED: steady white when array is mounted, amber if degraded/unmounted
            if now - last_array_check >= ARRAY_CHECK_INTERVAL:
                try:
                    current_missing = get_missing_array_mounts()
                    if current_missing != missing_mounts:
                        degraded = bool(current_missing)
                        configure_power_led(degraded=degraded)
                        missing_mounts = current_missing
                        if degraded:
                            print(
                                f"Power LED: amber (degraded array — unmounted: {', '.join(current_missing)})",
                                flush=True,
                            )
                        else:
                            print("Power LED: steady white (array healthy)", flush=True)
                except OSError as exc:
                    print(f"Warning: Power LED update failed: {exc}", flush=True)
                last_array_check = now

            # 2. Keep LAN LED bound to whichever Ethernet interface has carrier
            if now - last_net_check >= NET_CHECK_INTERVAL:
                try:
                    nic = find_active_nic()
                    if nic != active_nic:
                        configure_netdev_led(nic)
                        active_nic = nic
                except OSError as exc:
                    print(f"Warning: LAN LED update failed: {exc}", flush=True)
                last_net_check = now

            # 3. Discover populated bays and refresh standby power / SMART health periodically
            bays = discover_bay_disks()
            present_devs = {dev for dev in bays.values() if dev}
            for stale in set(disk_health) - present_devs:
                disk_health.pop(stale, None)
            for stale in set(disk_power) - present_devs:
                disk_power.pop(stale, None)

            if now - last_power_check >= POWER_CHECK_INTERVAL:
                for dev in present_devs:
                    disk_power[dev] = check_disk_power(dev)
                last_power_check = now

            if now - last_smart_check >= SMART_CHECK_INTERVAL:
                for dev in present_devs:
                    disk_health[dev] = check_disk_healthy(dev)
                last_smart_check = now

            # 4. Update bay LEDs and pulse on disk I/O
            for led, dev in bays.items():
                try:
                    if dev is None:
                        if bay_state.get(led) != (None, None, None):
                            reset_led(led)
                            bay_state[led] = (None, None, None)
                            prev_io.pop(led, None)
                            print(f"{led}: empty bay (off)", flush=True)
                        continue

                    if dev not in disk_health:
                        disk_health[dev] = check_disk_healthy(dev)
                    if dev not in disk_power:
                        disk_power[dev] = check_disk_power(dev)
                    healthy = disk_health[dev]
                    power = disk_power[dev]

                    total_ios, in_progress = read_disk_io(dev)
                    last_ios = prev_io.get(led)
                    prev_io[led] = total_ios
                    io_active = (last_ios is not None and total_ios != last_ios) or in_progress > 0

                    # Switch out of standby immediately on I/O without waiting for the next hdparm poll
                    if io_active and power == "standby":
                        disk_power[dev] = "active"
                        power = "active"

                    if bay_state.get(led) != (dev, healthy, power):
                        configure_disk_led(led, healthy, power)
                        bay_state[led] = (dev, healthy, power)
                        status = "FAULT" if not healthy else power
                        print(f"{led}: /dev/{dev} ({status})", flush=True)

                    if io_active and (not healthy or power == "active"):
                        write_text(led_path(led, "shot"), 1)
                except OSError as exc:
                    print(f"Warning: {led} update failed: {exc}", flush=True)

            time.sleep(POLL_INTERVAL)


    if __name__ == "__main__":
        main()
  '';
in
{
  # Out-of-tree led-ugreen driver + I2C and Linux LED trigger modules
  boot.extraModulePackages = [ ledUgreenKmod ];
  boot.kernelModules = [
    "i2c-dev"
    "i2c-i801"
    "led-ugreen"
    "ledtrig-netdev"
    "ledtrig-oneshot"
  ];

  # Active front-panel LED controller daemon
  systemd.services.younix-leds = {
    description = "UGREEN DXP4800 Plus active front-panel LED controller";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" "network.target" "local-fs.target" ];
    serviceConfig = {
      ExecStart = "${ledControlScript}";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };
}
