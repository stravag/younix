{ config, lib, pkgs, ... }:

let
  # ---------------------------------------------------------------------------
  # 1. Samba users & their share permissions
  #
  # - Each user listed here gets a Samba login whose password is read from
  #   `secrets/secrets.yaml` as nested YAML (`samba_passwords: { <username>: ... }`).
  # - `shares` explicitly lists which shared folders this user can read & write
  #   (maps directly to Unix group membership).
  # - `personalShare = true` creates a private `/mnt/data/users/<username>`
  #   share accessible only by that user (`0700` dirs / `0600` files).
  #
  # To add a family member later:
  #   1. Define their NixOS account in `hosts/younix/configuration.nix`.
  #   2. Add `<name>: <password>` under `samba_passwords:` via `sops secrets/secrets.yaml`.
  #   3. Add an entry for them below.
  # ---------------------------------------------------------------------------
  sambaUsers = {
    ranil = {
      shares = [ "media" "photos" ];
      personalShare = false;
    };
    # Example:
    # alice = {
    #   shares = [ "media" "photos" ];
    #   personalShare = true;
    # };
  };

  # ---------------------------------------------------------------------------
  # 2. Shared folders
  #
  # Each share name doubles as its Unix group name (e.g. `media` -> group `media`).
  # Any user whose `shares` list above includes a folder gets full read/write
  # access, and future services (Jellyfin, Immich) can join the same group.
  # ---------------------------------------------------------------------------
  sharedFolders = {
    media = {
      path = "/mnt/data/media";
      comment = "Movies, TV, and music";
    };
    photos = {
      path = "/mnt/data/photos";
      comment = "Photo library";
    };
  };

  personalUsers = lib.filterAttrs (_: cfg: cfg.personalShare or false) sambaUsers;

  mkSharedFolder = name: share: {
    "path" = share.path;
    "comment" = share.comment;
    "browseable" = "yes";
    "read only" = "no";
    "guest ok" = "no";
    "valid users" = "@${name}";
    "force group" = name;
    "create mask" = "0660";
    "directory mask" = "2770";
    "force create mode" = "0660";
    "force directory mode" = "2770";
  };

  mkPersonalShare = user: {
    "path" = "/mnt/data/users/${user}";
    "comment" = "Personal folder for ${user}";
    "browseable" = "yes";
    "access based share enum" = "yes";
    "read only" = "no";
    "guest ok" = "no";
    "valid users" = user;
    "create mask" = "0600";
    "directory mask" = "0700";
    "force create mode" = "0600";
    "force directory mode" = "0700";
  };

  sambaDirsScript = pkgs.writeShellScript "younix-samba-dirs" ''
    set -euo pipefail

    data_mounted=0
    if ${pkgs.util-linux}/bin/mountpoint -q /mnt/data; then
      data_mounted=1
    fi

    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: share: ''
        path=${lib.escapeShellArg share.path}
        case "$path" in
          /mnt/data/*)
            if [ "$data_mounted" -ne 1 ]; then
              echo "Skipping $path: /mnt/data is not mounted."
            else
              ${pkgs.coreutils}/bin/mkdir -p "$path"
              ${pkgs.coreutils}/bin/chown ${lib.escapeShellArg "root:${name}"} "$path"
              ${pkgs.coreutils}/bin/chmod 2770 "$path"
            fi
            ;;
          *)
            ${pkgs.coreutils}/bin/mkdir -p "$path"
            ${pkgs.coreutils}/bin/chown ${lib.escapeShellArg "root:${name}"} "$path"
            ${pkgs.coreutils}/bin/chmod 2770 "$path"
            ;;
        esac
      '') sharedFolders
    )}

    ${lib.optionalString (personalUsers != { }) ''
      if [ "$data_mounted" -ne 1 ]; then
        echo "Skipping /mnt/data/users/*: /mnt/data is not mounted."
      else
        ${pkgs.coreutils}/bin/mkdir -p /mnt/data/users
        ${pkgs.coreutils}/bin/chmod 0755 /mnt/data/users
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (user: _: ''
            ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg "/mnt/data/users/${user}"}
            ${pkgs.coreutils}/bin/chown ${lib.escapeShellArg "${user}:"} ${lib.escapeShellArg "/mnt/data/users/${user}"}
            ${pkgs.coreutils}/bin/chmod 0700 ${lib.escapeShellArg "/mnt/data/users/${user}"}
          '') personalUsers
        )}
      fi
    ''}
  '';

  sambaPasswdScript = pkgs.writeShellScript "younix-samba-passwd" ''
    set -euo pipefail

    ${pkgs.coreutils}/bin/install -d -m 0700 /var/lib/samba/private

    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (user: _: ''
        secret_file=${lib.escapeShellArg config.sops.secrets."samba_passwords/${user}".path}
        if [ ! -r "$secret_file" ]; then
          echo "ERROR: Samba password secret for ${user} not found at $secret_file" >&2
          exit 1
        fi

        pw="$(< "$secret_file")"
        if [ -z "$pw" ]; then
          echo "ERROR: Samba password secret for ${user} at $secret_file is empty" >&2
          exit 1
        fi

        printf '%s\n%s\n' "$pw" "$pw" | ${config.services.samba.package}/bin/smbpasswd -s -a ${lib.escapeShellArg user}
      '') sambaUsers
    )}
  '';
in
{
  # Catch typos in `sambaUsers.<user>.shares` at evaluation time
  assertions = lib.concatLists (
    lib.mapAttrsToList (user: cfg:
      map (share: {
        assertion = builtins.hasAttr share sharedFolders;
        message = "modules/samba.nix: sambaUsers.${user}.shares references unknown share '${share}'.";
      }) cfg.shares
    ) sambaUsers
  );

  # Encrypted per-user Samba passwords managed via sops-nix (`samba_passwords.<user>` in
  # secrets/secrets.yaml). Rotating any password automatically re-runs younix-samba-passwd.
  sops.secrets = lib.mapAttrs' (user: _:
    lib.nameValuePair "samba_passwords/${user}" {
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = [ "younix-samba-passwd.service" ];
    }
  ) sambaUsers;

  # Create one Unix group per shared folder and assign each user's configured shares
  users.groups = lib.genAttrs (builtins.attrNames sharedFolders) (_: { });
  users.users = lib.mapAttrs (_: cfg: {
    extraGroups = cfg.shares;
  }) sambaUsers;

  # Samba file server (SMB3-only, authenticated, macOS Finder / vfs_fruit optimized)
  services.samba = {
    enable = true;
    openFirewall = true;
    # Modern SMB3 uses Avahi (macOS/Linux) and WSDD (Windows) instead of legacy NetBIOS.
    nmbd.enable = false;

    settings = {
      global = {
        "workgroup" = "WORKGROUP";
        "server string" = "younix";
        "netbios name" = "younix";
        "security" = "user";
        "server role" = "standalone server";
        "server min protocol" = "SMB3_00";
        "map to guest" = "never";
        "guest account" = "nobody";
        "invalid users" = [ "root" ];

        # Allow group members with write access to update mtimes on shared files
        "dos filetimes" = "yes";

        # Disable unused printing subsystem to avoid CUPS log noise
        "load printers" = "no";
        "printing" = "bsd";
        "printcap name" = "/dev/null";
        "disable spoolss" = "yes";

        # macOS / Apple SMB2+ extensions (vfs_fruit + streams_xattr).
        # Underlying ext4 branches support user_xattr natively through MergerFS.
        "ea support" = "yes";
        "vfs objects" = "fruit streams_xattr";
        "fruit:metadata" = "stream";
        "fruit:model" = "MacSamba";
        "fruit:posix_rename" = "yes";
        "fruit:veto_appledouble" = "no";
        "fruit:nfs_aces" = "no";
        "fruit:wipe_intentionally_left_blank_rfork" = "yes";
        "fruit:delete_empty_adfiles" = "yes";
      };
    }
    // (lib.mapAttrs mkSharedFolder sharedFolders)
    // (lib.mapAttrs (user: _: mkPersonalShare user) personalUsers);
  };

  # Windows 10/11 network discovery (modern replacement for NetBIOS/nmbd)
  services.samba-wsdd = {
    enable = true;
    openFirewall = true;
  };

  # Advertise SMB to macOS Finder via Avahi/Bonjour
  services.avahi = {
    publish.userServices = true;
    extraServiceFiles.smb = ''
      <?xml version="1.0" standalone='no'?>
      <!DOCTYPE service-group SYSTEM "avahi-service.dtd">
      <service-group>
        <name replace-wildcards="yes">%h</name>
        <service>
          <type>_smb._tcp</type>
          <port>445</port>
        </service>
        <service>
          <type>_device-info._tcp</type>
          <port>0</port>
          <txt-record>model=Xserve</txt-record>
        </service>
      </service-group>
    '';
  };

  # Ensure share directories exist with proper ownership/mode once /mnt/data is mounted
  systemd.services.younix-samba-dirs = {
    description = "Ensure Samba share directories and permissions exist";
    after = [ "mnt-data.mount" ];
    before = [ "samba-smbd.service" ];
    wantedBy = [ "samba-smbd.service" "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = sambaDirsScript;
    };
  };

  # Declaratively provision/update Samba passwords for all users in `sambaUsers` from sops-nix
  systemd.services.younix-samba-passwd = {
    description = "Sync declarative Samba user passwords from sops-nix";
    after = [ "local-fs.target" ];
    before = [ "samba-smbd.service" ];
    wantedBy = [ "samba-smbd.service" "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = sambaPasswdScript;
    };
  };

  systemd.services.samba-smbd = {
    after = [ "mnt-data.mount" "younix-samba-dirs.service" "younix-samba-passwd.service" ];
    wants = [ "mnt-data.mount" "younix-samba-dirs.service" "younix-samba-passwd.service" ];
  };
}
