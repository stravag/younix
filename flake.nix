{
  description = "NixOS GitOps configuration for UGREEN DXP4800 Plus (younix)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    comin = {
      url = "github:nlewo/comin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, comin, ... }@inputs: {
    nixosConfigurations = {
      younix = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          comin.nixosModules.comin
          ./hosts/younix/configuration.nix
          ./modules/gitops.nix
        ];
      };
    };
  };
}
