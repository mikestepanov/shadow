{ config, pkgs, ... }:

let
  pumble = pkgs.callPackage ./pumble.nix {};
  opencodePinned = pkgs.callPackage ./opencode-bin.nix {};
in
{
  imports = [
    ./hardware-configuration.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Force disable PCIe ASPM - fixes MT7921e WiFi crashes
  # (BIOS doesn't give OS ASPM control, so driver can't disable it)
  boot.kernelParams = [ "pcie_aspm=off" ];

  # HP Omen 16-ap0xxx (board 8E35) internal mic fix
  # Adds quirk to acp6x driver for DMIC support
  boot.kernelPatches = [{
    name = "hp-omen-8E35-mic";
    patch = ./hp-omen-mic.patch;
  }];

  networking.hostName = "nixos";
  networking.networkmanager.enable = true;
  networking.nameservers = [ "1.1.1.1" "8.8.8.8" ];
  services.resolved.enable = true;

  # MT7921e WiFi stability fix - disable ASPM power management
  boot.extraModprobeConfig = ''
    options mt7921e disable_aspm=Y
    options mt7921_common power_save=0
    options mt792x_lib power_save=0
    blacklist snd_rpl_pci_acp6x
  '';
  # Also disable WiFi power save via NetworkManager
  networking.networkmanager.wifi.powersave = false;

  time.timeZone = "America/Chicago";

  i18n.defaultLocale = "en_US.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT = "en_US.UTF-8";
    LC_MONETARY = "en_US.UTF-8";
    LC_NAME = "en_US.UTF-8";
    LC_NUMERIC = "en_US.UTF-8";
    LC_PAPER = "en_US.UTF-8";
    LC_TELEPHONE = "en_US.UTF-8";
    LC_TIME = "en_US.UTF-8";
  };

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

  # Enable OpenGL
  hardware.graphics.enable = true;

  services.xserver.enable = true;

  services.displayManager.sddm.enable = true;
  services.desktopManager.plasma6.enable = true;

  # Allow screen dimming but prevent sleep
  # (removed xset commands that were blocking dimming)

  # Enable power management (manual sleep allowed, no auto-suspend)
  powerManagement.enable = true;

  # Let powerdevil run (handles dimming), config below prevents auto-suspend

  # Disable automatic logout/lock screen on idle
  services.displayManager.sddm.autoLogin.relogin = false;

  # Disable logind idle actions and lid switch suspend
  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
    KillUserProcesses = false;
    IdleAction = "ignore";
    IdleActionSec = 0;
  };

  # Block automatic idle suspend (but allow manual suspend via slee/KDE menu)
  # Uses systemd-inhibit to hold an "idle" lock that blocks auto-suspend
  systemd.user.services.inhibit-idle-suspend = {
    description = "Prevent automatic idle suspend";
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.systemd}/bin/systemd-inhibit --what=idle --who=inhibit-idle-suspend --why='Prevent automatic suspend' --mode=block sleep infinity";
      Restart = "always";
    };
  };



  # Disable KDE screen locker via config file
  environment.etc."xdg/kscreenlockerrc".text = ''
    [Daemon]
    Autolock=false
    LockOnResume=false
    Timeout=0
  '';

  # KDE power management: allow dimming, no suspend, no DPMS (screen off)
  environment.etc."xdg/powermanagementprofilesrc".text = ''
    [AC][DimDisplay]
    idleTime=300000

    [AC][DPMSControl]
    idleTime=0

    [AC][SuspendSession]
    idleTime=0
    suspendType=0

    [Battery][DimDisplay]
    idleTime=120000

    [Battery][DPMSControl]
    idleTime=0

    [Battery][SuspendSession]
    idleTime=0
    suspendType=0
  '';

  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  # Disable DPMS at X server level (prevents screen from turning off)
  services.xserver.serverFlagsSection = ''
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime" "0"
    Option "BlankTime" "0"
  '';

  services.printing.enable = true;
  hardware.bluetooth.enable = true;
  hardware.bluetooth.powerOnBoot = true;

  services.syncthing = {
    enable = true;
    user = "mikhail";
    dataDir = "/home/mikhail/.syncthing";
    configDir = "/home/mikhail/.config/syncthing";
  };

  # Dropbox auto-start service
  systemd.user.services.dropbox = {
    description = "Dropbox file sync";
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.dropbox}/bin/dropbox";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # Auto-sync repos (axon + nixos-config) every 4 hours
  systemd.user.services.sync-repos = {
    description = "Sync nixos-config and axon repos";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "/home/mikhail/.openclaw/workspace/scripts/sync-repos";
    };
    path = [ pkgs.git pkgs.bash ];
  };

  systemd.user.timers.sync-repos = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "15min";
      OnUnitActiveSec = "4h";
      Persistent = true;
    };
  };

  # StartHub production website uptime monitor - pings every 5min, alerts via Telegram
  systemd.user.services.check-starthub-prod-website = {
    description = "Check starthub.academy production website status";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "/home/mikhail/scripts/check-starthub-prod-website.sh";
    };
    path = [ pkgs.bash pkgs.curl ];
  };

  systemd.user.timers.check-starthub-prod-website = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "5min";
    };
  };

  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    wireplumber.enable = true;
    wireplumber.extraConfig.no-ucm = {
      "monitor.alsa.properties" = {
        "alsa.use-ucm" = false;
      };
    };
  };

  # Enable xdg-desktop-portal for screen sharing, audio/video in browsers
  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.kdePackages.xdg-desktop-portal-kde ];
  };

  # Ollama (local LLM inference with GPU acceleration)
  services.ollama = {
    enable = true;
    package = pkgs.ollama-cuda;
  };

  # Docker for development
  virtualisation.docker.enable = true;

  users.users.mikhail = {
    isNormalUser = true;
    description = "Mikhail";
    extraGroups = [ "networkmanager" "wheel" "docker" ];
    packages = with pkgs; [
      kdePackages.kate
    ];
  };

  programs.firefox.enable = true;

  # Enable nix-ld to run unpatched dynamic binaries (npm packages like biome, esbuild, etc.)
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    # Playwright browser dependencies
    stdenv.cc.cc.lib
    libx11
    libxcomposite
    libxcursor
    libxdamage
    libxext
    libxfixes
    libxi
    libxrandr
    libxrender
    libxcb
    libxshmfence
    libxtst
    libxkbcommon
    gtk3
    pango
    cairo
    gdk-pixbuf
    glib
    dbus
    alsa-lib
    at-spi2-atk
    at-spi2-core
    cups
    libdrm
    expat
    mesa
    libgbm
    nspr
    nss
    freetype
    fontconfig
    # Voquill AppImage dependencies
    fribidi
    webkitgtk_4_1
    libsoup_3
    openssl
  ];

  # Voxtype voice-to-text (wtype for Wayland text insertion)
  environment.systemPackages = with pkgs; [
    wtype
    appimage-run
    nodejs_24
    # pnpm  # see "npm global packages" section below

    # Build tools for npm packages with native dependencies (openclaw, node-llama-cpp)
    gnumake
    cmake
    gcc
    pkg-config

    git
    gh
    github-desktop
    gitbutler
    google-chrome
    antigravity
    telegram-desktop
    mongodb-compass
    bitwarden-desktop
    figma-linux
    gemini-cli
    claude-code
    opencodePinned
    bubblewrap  # sandbox for codex (codex itself: see "npm global packages" section)
    keeweb
    onedrive
    dropbox
    kdePackages.kio-gdrive
    xdg-utils
    github-copilot-cli
    docker-compose
    pumble
    unzip
    tmux

    # AWS & Kubernetes & GCP & Infrastructure
    awscli2
    supabase-cli
    kubectl
    google-cloud-sdk
    keepassxc
    terraform

    # Terminal emulators
    kitty
    ghostty

    # Audio tools
    pavucontrol
    pulseaudio  # for pactl

    # Network/hardware diagnostics
    iw
    pciutils
    xset  # for DPMS control
  ];

  nixpkgs.config = {
    allowUnfree = true;
    allowUnfreePredicate = pkg:
      builtins.elem (pkgs.lib.getName pkg) [
        "github-copilot-cli"
        "google-chrome"
        "antigravity"
        "mongodb-compass"
      ];
  };

  # === npm global packages (not in nixpkgs, need manual install) ===
  # TODO: migrate to flake inputs or custom derivations when possible
  #   pnpm           — npm i -g pnpm (nixpkgs version built against wrong Node)
  #   openclaw       — npm i -g openclaw (or linked from ~/openclaw-dev)
  #   @openai/codex  — npm i -g @openai/codex
  #   @google/jules  — npm i -g @google/jules
  #   @playwright/cli — npm i -g @playwright/cli

  # Add ~/.local/bin and ~/.npm-global/bin to PATH
  environment.sessionVariables = {
    PATH = "$HOME/.npm-global/bin:$HOME/.local/bin:$PATH";
  };

  # Convenience aliases
  environment.shellAliases = {
    ghc = "copilot --allow-all-tools";
    cc = "claude --dangerously-skip-permissions";
    gem = "gemini --yolo";
    cdx = "codex --dangerously-bypass-approvals-and-sandbox";
    axh = "~/Desktop/shadow/scripts/healthcheck.sh";
    axr = "~/Desktop/shadow/scripts/recent.sh";
    cron = "nix-shell -p python313Packages.textual --run '~/Desktop/shadow/scripts/automationctl'";
    nxs = "sudo nixos-rebuild switch --flake ~/Desktop/shadow/nixos#nixos";
    k = "kitty --session ~/.config/kitty/startup-session.conf & disown";
    slee = "systemctl suspend";
  };

  # Disable DPMS on login (backup - runs xset to disable screen power off)
  environment.etc."xdg/autostart/disable-dpms.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Disable DPMS
    Exec=sh -c "xset s off; xset -dpms; xset s noblank"
    X-KDE-autostart-phase=1
  '';

  # Auto-start Kitty on login
  environment.etc."xdg/autostart/kitty-session.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Kitty Session
    Exec=kitty --session /home/mikhail/.config/kitty/startup-session.conf
    X-KDE-autostart-after=panel
  '';

  # Bash configuration for case-insensitive tab completion and cd
  programs.bash.interactiveShellInit = ''
    bind 'set completion-ignore-case on'

    # Case-insensitive cd (Windows-style)
    cd() {
      builtin cd "$@" 2>/dev/null && return
      # If exact path failed, try case-insensitive match
      local target="$1"
      [[ -z "$target" ]] && builtin cd && return
      local dir=$(dirname "$target")
      local base=$(basename "$target")
      [[ "$dir" == "." ]] && dir=""
      local match=$(find "''${dir:-.}" -maxdepth 1 -iname "$base" -type d 2>/dev/null | head -1)
      if [[ -n "$match" ]]; then
        builtin cd "$match"
      else
        builtin cd "$@"  # Let it fail with proper error
      fi
    }

    # Project tmux shortcuts
    starthub() {
      if tmux has-session -t starthub 2>/dev/null; then
        tmux attach -t starthub
      else
        tmux new-session -s starthub -c ~/Desktop/StartHub
      fi
    }

    nixelo() {
      if tmux has-session -t nixelo 2>/dev/null; then
        tmux attach -t nixelo
      else
        tmux new-session -s nixelo -c ~/Desktop/nixelo
      fi
    }
    
    # OpenClaw TUI
    axon() {
      openclaw tui
    }
  '';

  # Fonts
  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
  ];

  # === WiFi Watchdog (auto-reconnect on mt7921 drops) ===
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

  # === Memory Management (prevent OOM freezes) ===
  
  # Swap file - gives breathing room before OOM
  swapDevices = [{
    device = "/swapfile";
    size = 8192;  # 8GB
  }];

  # Early OOM killer - kills memory hogs BEFORE system freezes
  services.earlyoom = {
    enable = true;
    freeMemThreshold = 5;   # Trigger when <5% RAM free
    freeSwapThreshold = 10; # Trigger when <10% swap free
    enableNotifications = true;
  };

  # Kernel memory tuning
  boot.kernel.sysctl = {
    "vm.min_free_kbytes" = 524288;  # Reserve 512MB for kernel/UI
    "vm.oom_kill_allocating_task" = 1;  # Kill hogs faster
    "vm.swappiness" = 10;  # Prefer RAM over swap
  };

  # Chrome compatibility symlink for Playwright CLI
  # Playwright expects Chrome at /opt/google/chrome/chrome
  system.activationScripts.playwrightChrome = ''
    mkdir -p /opt/google/chrome
    ln -sf /run/current-system/sw/bin/google-chrome-stable /opt/google/chrome/chrome
  '';

  # Enable flakes and nix command
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  system.stateVersion = "25.11";
}
