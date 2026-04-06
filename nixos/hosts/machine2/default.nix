{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "machine2";

  # TODO: add machine-specific config here
  # Generate hardware-configuration.nix on the machine with:
  #   nixos-generate-config --show-hardware-config > hardware-configuration.nix

  system.stateVersion = "25.11";
}
