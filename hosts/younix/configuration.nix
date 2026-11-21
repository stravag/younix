{ config, lib, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  # Bootloader (UEFI on the 1 TB NixOS SSD; leaves the internal 128 GB UGOS SSD untouched)
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10;
  boot.loader.efi.canTouchEfiVariables = true;

  # Networking
  networking.hostName = "younix";
  networking.useDHCP = lib.mkDefault true;
  networking.firewall.enable = true;

  # mDNS so the NAS is reachable at younix.local from macOS/Linux
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
    publish = {
      enable = true;
      addresses = true;
      workstation = true;
    };
  };

  # Locale & Timezone
  time.timeZone = "Europe/Zurich";
  i18n.defaultLocale = "en_US.UTF-8";

  # User accounts (Samba share access & passwords are configured in modules/samba.nix)
  users.users.ranil = {
    isNormalUser = true;
    description = "Ranil";
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKCuWX/W66sjjNiDNuPpKgYO1xFqDoMJoeo5hz2LDNrF"
    ];
  };

  # Allow wheel users to run sudo without a password (avoids storing passwords in a public repo)
  security.sudo.wheelNeedsPassword = false;

  # SSH (key-only authentication, root login disabled)
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # Nix settings & automatic garbage collection
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  # Useful baseline tools for administration and hardware inspection
  environment.systemPackages = with pkgs; [
    git
    vim
    htop
    btop
    tmux
    curl
    efibootmgr
    smartmontools
    nvme-cli
    lm_sensors
    pciutils
    usbutils
  ];

  # Do not change this after initial install.
  # See https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion
  system.stateVersion = "26.05";
}
