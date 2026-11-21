{ ... }:

{
  # Declarative secrets management via sops-nix (https://github.com/Mic92/sops-nix).
  # Encrypted files live under ../secrets/ (encrypted for both the macOS admin age key
  # and younix's host age key at /etc/keys/sops.key) and are decrypted into /run/secrets/
  # in tmpfs at boot/activation time.
  sops = {
    defaultSopsFile = ../secrets/secrets.yaml;
    defaultSopsFormat = "yaml";

    age = {
      keyFile = "/etc/keys/sops.key";
      sshKeyPaths = [ ];
      generateKey = false;
    };

    # Disable unused GPG/SSH-RSA fallback paths
    gnupg.sshKeyPaths = [ ];

    # Harmless test secret for verifying end-to-end decryption (/run/secrets/test_secret).
    # Service-specific secrets should be declared in their respective service modules.
    secrets.test_secret = { };
  };
}
