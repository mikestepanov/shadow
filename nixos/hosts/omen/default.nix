{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "nixos";

  # Force disable PCIe ASPM - fixes MT7921e WiFi crashes
  # (BIOS doesn't give OS ASPM control, so driver can't disable it)
  boot.kernelParams = [ "pcie_aspm=off" ];

  # HP Omen 16-ap0xxx (board 8E35) internal mic fix
  # Adds quirk to acp6x driver for DMIC support
  boot.kernelPatches = [{
    name = "hp-omen-8E35-mic";
    patch = ../../hp-omen-mic.patch;
  }];

  # MT7921e WiFi stability fix - disable ASPM power management
  boot.extraModprobeConfig = ''
    options mt7921e disable_aspm=Y
    options mt7921_common power_save=0
    options mt792x_lib power_save=0
    blacklist snd_rpl_pci_acp6x
  '';
  # Also disable WiFi power save via NetworkManager
  networking.networkmanager.wifi.powersave = false;

  # NVIDIA RTX 5060 Mobile (proprietary drivers)
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia = {
    modesetting.enable = true;
    open = true;
    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.beta;
  };

  hardware.nvidia.prime = {
    sync.enable = true;
    nvidiaBusId = "PCI:1:0:0";
    amdgpuBusId = "PCI:6:0:0";
  };

  # Ollama with CUDA for this machine's NVIDIA GPU
  services.ollama.package = pkgs.ollama-cuda;

  # Wireplumber: disable UCM (needed for HP Omen audio)
  services.pipewire.wireplumber.extraConfig.no-ucm = {
    "monitor.alsa.properties" = {
      "alsa.use-ucm" = false;
    };
  };

  # WiFi Watchdog (auto-reconnect on mt7921 drops)
  systemd.services.wifi-watchdog = {
    description = "WiFi connection watchdog";
    after = [ "NetworkManager.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = pkgs.writeShellScript "wifi-watchdog" ''
        while true; do
          sleep 30
          if ! ${pkgs.iputils}/bin/ping -c 1 -W 5 1.1.1.1 > /dev/null 2>&1; then
            echo "WiFi down, reconnecting..."
            ${pkgs.networkmanager}/bin/nmcli connection down CenturyLink4882 2>/dev/null
            sleep 2
            ${pkgs.networkmanager}/bin/nmcli connection up CenturyLink4882
          fi
        done
      '';
      Restart = "always";
    };
  };

  system.stateVersion = "25.11";
}
