# NixOS Configuration

Shared NixOS configuration synced across devices via GitHub.

## How This Works

- **Real config:** `/etc/nixos/configuration.nix` - The actual system config NixOS reads
- **Repo copy:** `~/Desktop/saber/nixos/configuration.nix` - Your editable copy synced to GitHub
- **Hardware config:** `/etc/nixos/hardware-configuration.nix` - Machine-specific (never synced)

### Workflow
1. Edit `~/Desktop/saber/nixos/configuration.nix`
2. Run `nxs` to copy to `/etc/nixos/` and rebuild system
3. Commit & push to GitHub when ready to sync to other machines

## Aliases

After running `nxs`, these shortcuts become available:

- **`ghc`** - Run GitHub Copilot CLI with all tools allowed
- **`cron`** - Open automation control panel (Textual TUI) for OpenClaw timers/crons
- **`nxs`** - Sync config to `/etc/nixos/` and rebuild system

`cron` runs:
```bash
nix-shell -p python313Packages.textual --run '~/Desktop/axon/scripts/automationctl'
```

## Setup on a New Machine

1. Clone this repo: 
   ```bash
   git clone https://github.com/mikestepanov/saber.git ~/Desktop/saber
   ```

2. Backup original config:
   ```bash
   sudo cp /etc/nixos/configuration.nix /etc/nixos/configuration.nix.backup
   ```

3. Apply the config:
   ```bash
   cd ~/Desktop/saber/nixos
   sudo cp configuration.nix /etc/nixos/configuration.nix
   sudo nixos-rebuild switch
   ```

4. Hardware config stays machine-specific (already in `/etc/nixos/hardware-configuration.nix`)

## Syncing Changes Across Machines

**On the machine where you made changes:**
```bash
cd ~/Desktop/saber/nixos
git add -A
git commit -m "Description of changes"
git push
```

**On other machines:**
```bash
cd ~/Desktop/saber/nixos
git pull
nxs  # or: sudo cp configuration.nix /etc/nixos/ && sudo nixos-rebuild switch
```

## Current Setup

- **Desktop Environment:** KDE Plasma 6
- **Display Manager:** SDDM
- **Power Settings:** Screen doesn't dim/sleep when plugged in
- **Packages:** Node.js 24, Git, GitHub CLI, GitHub Desktop, Copilot CLI
- **GPU:** NVIDIA RTX 5060 + AMD integrated (currently using nouveau driver)
