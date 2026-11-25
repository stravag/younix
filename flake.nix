{
  description = "NixOS GitOps configuration for UGREEN DXP4800 Plus (younix)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    comin = {
      url = "github:nlewo/comin";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, comin, sops-nix, ... }@inputs: {
    nixosConfigurations = {
      younix = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          comin.nixosModules.comin
          sops-nix.nixosModules.sops
          ./hosts/younix/configuration.nix
          ./modules/gitops.nix
          ./modules/secrets.nix
          ./modules/thermals.nix
          ./modules/power.nix
          ./modules/leds.nix
          ./modules/graphics.nix
          ./modules/storage.nix
          ./modules/backups.nix
          ./modules/samba.nix
          ./modules/remote-access.nix
          ./modules/proxy.nix
          ./modules/services/jellyfin.nix
          ./modules/services/immich.nix
          ./modules/services/beszel.nix
        ];
      };
    };
  };
}
