{
  description = "Mikhail's NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    peon-ping.url = "github:PeonPing/peon-ping";
  };

  outputs = { self, nixpkgs, peon-ping, ... }: {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./common.nix
        ./hosts/omen/default.nix
        {
          environment.systemPackages = [
            peon-ping.packages.x86_64-linux.default
          ];
        }
      ];
    };

    # nixosConfigurations.machine2 = nixpkgs.lib.nixosSystem {
    #   system = "x86_64-linux";
    #   modules = [
    #     ./common.nix
    #     ./hosts/machine2/default.nix
    #   ];
    # };
  };
}
